'use client'

import { useQuery } from '@tanstack/react-query'
import type { Address, PublicClient } from 'viem'
import { usePublicClient } from 'wagmi'
import { demoAbi, escrowAbi, gateAbi, marketAbi } from '@/generated/abi'
import { chain, contracts, ZERO } from './chain'

/**
 * Event history for the trading view, read from logs. Protocol time is block time plus the demo clock's offset,
 * which every DemoController.Step reveals (Step carries the clock time it moved to). Without a demo controller the
 * clock is the block clock and the offset is zero.
 */

export type HistoryKind =
  | 'Buffer repaid'
  | 'Trimmed'
  | 'Repaid'
  | 'Repaid from buffer'
  | 'Borrowed'
  | 'Written off'
  | 'Collateral added'
  | 'Collateral withdrawn'
  | 'Buffer funded'
  | 'Buffer withdrawn'
  | 'Buffer authorized'
  | 'Buffer cancelled'

/** Kinds that change the debt, listed under Executions. */
export const EXECUTION_KINDS: HistoryKind[] = ['Buffer repaid', 'Trimmed', 'Repaid', 'Repaid from buffer', 'Borrowed', 'Written off']

export interface HistoryItem {
  kind: HistoryKind
  hash: string
  block: bigint
  logIndex: number
  t: number // protocol time, UTC seconds
  amount: bigint // loan-token base units, or raw collateral for collateral kinds
  unit: 'USDG' | 'TSLA' | ''
  detail?: string
  debtBefore?: bigint
  debtAfter?: bigint
  collateralBefore: bigint
  collateralAfter: bigint
  price?: number // demo feed price at that time, USD
  ltvBefore?: number // fraction, from the event's debt and collateral at that price
  ltvAfter?: number
}

export interface PricePoint {
  t: number
  price: number
}

export interface GateEvent {
  kind: 'Admitted' | 'Admission reset' | 'Outage detected' | 'Recovery checkpoint' | 'Stopped' | 'Resume requested' | 'Resumed'
  hash: string
  t: number
  detail?: string
}

const LOOKBACK = 200_000n
const blockTimes = new Map<string, number>()

async function timestamps(client: PublicClient, blocks: bigint[]) {
  const missing = [...new Set(blocks.map(String))].filter(b => !blockTimes.has(b))
  await Promise.all(
    missing.map(async b => {
      const block = await client.getBlock({ blockNumber: BigInt(b) })
      blockTimes.set(b, Number(block.timestamp))
    }),
  )
}

type Pos = { blockNumber: bigint; logIndex: number }
const before = (a: Pos, b: Pos) => a.blockNumber < b.blockNumber || (a.blockNumber === b.blockNumber && a.logIndex <= b.logIndex)

function ltv(debt: bigint | undefined, collateral: bigint, price: number | undefined): number | undefined {
  if (debt === undefined || price === undefined || price <= 0) return undefined
  if (debt === 0n) return 0
  const value = (Number(collateral) / 1e18) * price
  return value > 0 ? Number(debt) / 1e6 / value : undefined
}

export interface History {
  prices: PricePoint[]
  items: HistoryItem[]
  gate: GateEvent[]
  feedDecimals: number
}

async function load(client: PublicClient, account: Address | undefined, currentCollateral: bigint | undefined, feedDecimals: number): Promise<History> {
  const c = contracts!
  const head = await client.getBlockNumber()
  const fromBlock = head > LOOKBACK ? head - LOOKBACK : 0n
  const hasDemo = c.demoController !== ZERO
  const acct = account ? { account } : undefined

  const [steps, admitted, reset, outage, checkpoint, stopped, resumeRequested, resumed] = await Promise.all([
    hasDemo ? client.getContractEvents({ address: c.demoController, abi: demoAbi, eventName: 'Step', fromBlock }) : Promise.resolve([]),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'Admitted', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'AdmissionReset', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'OutageDetected', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'RecoveryCheckpoint', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'Stopped', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'ResumeRequested', fromBlock }),
    client.getContractEvents({ address: c.gate, abi: gateAbi, eventName: 'Resumed', fromBlock }),
  ])

  const scale = 10 ** feedDecimals
  const prices: PricePoint[] = steps.filter(s => (s.args.answer ?? 0n) !== 0n).map(s => ({ t: Number(s.args.time ?? 0n), price: Number(s.args.answer!) / scale }))

  const gate: GateEvent[] = [
    ...admitted.map(e => ({ kind: 'Admitted' as const, hash: e.transactionHash, t: Number(e.args.admissionAt ?? 0n), detail: `price from ${Number(e.args.priceUpdatedAt ?? 0n)}` })),
    ...reset.map(e => ({ kind: 'Admission reset' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n) })),
    ...outage.map(e => ({ kind: 'Outage detected' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n) })),
    ...checkpoint.map(e => ({ kind: 'Recovery checkpoint' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n) })),
    ...stopped.map(e => ({ kind: 'Stopped' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n) })),
    ...resumeRequested.map(e => ({ kind: 'Resume requested' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n), detail: `available ${Number(e.args.availableAt ?? 0n)}` })),
    ...resumed.map(e => ({ kind: 'Resumed' as const, hash: e.transactionHash, t: Number(e.args.at ?? 0n) })),
  ].sort((a, b) => b.t - a.t)

  if (!account) return { prices, items: [], gate, feedDecimals }

  const [colIn, colOut, borrows, repays, trims, writeOffs, funded, withdrawn, authorized, cancelled, buffers, ownerRepays] = await Promise.all([
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'CollateralDeposited', args: acct, fromBlock }),
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'CollateralWithdrawn', args: acct, fromBlock }),
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'Borrowed', args: acct, fromBlock }),
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'Repaid', args: acct, fromBlock }),
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'Trimmed', args: acct, fromBlock }),
    client.getContractEvents({ address: c.market, abi: marketAbi, eventName: 'BadDebtWrittenOff', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'Deposited', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'Withdrawn', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'Authorized', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'Cancelled', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'BufferExecuted', args: acct, fromBlock }),
    client.getContractEvents({ address: c.escrow, abi: escrowAbi, eventName: 'OwnerRepaid', args: acct, fromBlock }),
  ])

  // Buffer executions and owner repayments also emit Repaid from the market; fold those into one row.
  const repaidByTx = new Map(repays.map(r => [r.transactionHash, r]))
  const folded = new Set([...buffers, ...ownerRepays].map(e => e.transactionHash))

  type Raw = Omit<HistoryItem, 't' | 'collateralBefore' | 'collateralAfter' | 'price' | 'ltvBefore' | 'ltvAfter'> & { collateralDelta: bigint; collateralAfterExact?: bigint }
  const pos = (e: { transactionHash: `0x${string}`; blockNumber: bigint; logIndex: number }) => ({ hash: e.transactionHash, block: e.blockNumber, logIndex: e.logIndex })
  const raw: Raw[] = [
    ...colIn.map(e => ({ ...pos(e), kind: 'Collateral added' as const, amount: e.args.amount ?? 0n, unit: 'TSLA' as const, collateralDelta: e.args.amount ?? 0n })),
    ...colOut.map(e => ({ ...pos(e), kind: 'Collateral withdrawn' as const, amount: e.args.amount ?? 0n, unit: 'TSLA' as const, collateralDelta: -(e.args.amount ?? 0n) })),
    ...borrows.map(e => ({
      ...pos(e),
      kind: 'Borrowed' as const,
      amount: e.args.amount ?? 0n,
      unit: 'USDG' as const,
      debtAfter: e.args.debtAfter,
      debtBefore: (e.args.debtAfter ?? 0n) - (e.args.amount ?? 0n),
      collateralDelta: 0n,
    })),
    ...repays
      .filter(e => !folded.has(e.transactionHash))
      .map(e => ({
        ...pos(e),
        kind: 'Repaid' as const,
        amount: e.args.amount ?? 0n,
        unit: 'USDG' as const,
        debtAfter: e.args.debtAfter,
        debtBefore: (e.args.debtAfter ?? 0n) + (e.args.amount ?? 0n),
        collateralDelta: 0n,
      })),
    ...trims.map(e => ({
      ...pos(e),
      kind: 'Trimmed' as const,
      amount: e.args.repaid ?? 0n,
      unit: 'USDG' as const,
      detail: `${(Number(e.args.bonusWad ?? 0n) / 1e16).toFixed(0)}% bonus · ${(Number(e.args.collateralOut ?? 0n) / 1e18).toFixed(4)} TSLA out`,
      debtAfter: e.args.debtAfter,
      debtBefore: (e.args.debtAfter ?? 0n) + (e.args.repaid ?? 0n),
      collateralDelta: -(e.args.collateralOut ?? 0n),
      collateralAfterExact: e.args.collateralAfter,
    })),
    ...writeOffs.map(e => ({ ...pos(e), kind: 'Written off' as const, amount: e.args.amount ?? 0n, unit: 'USDG' as const, debtBefore: e.args.amount, debtAfter: 0n, collateralDelta: 0n })),
    ...funded.map(e => ({ ...pos(e), kind: 'Buffer funded' as const, amount: e.args.amount ?? 0n, unit: 'USDG' as const, collateralDelta: 0n })),
    ...withdrawn.map(e => ({ ...pos(e), kind: 'Buffer withdrawn' as const, amount: e.args.amount ?? 0n, unit: 'USDG' as const, collateralDelta: 0n })),
    ...authorized.map(e => ({
      ...pos(e),
      kind: 'Buffer authorized' as const,
      amount: e.args.perSessionCap ?? 0n,
      unit: 'USDG' as const,
      detail: `target ${(Number(e.args.targetWad ?? 0n) / 1e16).toFixed(1)}% · cap per session`,
      collateralDelta: 0n,
    })),
    ...cancelled.map(e => ({ ...pos(e), kind: 'Buffer cancelled' as const, amount: 0n, unit: '' as const, collateralDelta: 0n })),
    ...buffers.map(e => ({
      ...pos(e),
      kind: 'Buffer repaid' as const,
      amount: e.args.repaid ?? 0n,
      unit: 'USDG' as const,
      debtBefore: e.args.debtBefore,
      debtAfter: e.args.debtAfter,
      collateralDelta: 0n,
    })),
    ...ownerRepays.map(e => {
      const r = repaidByTx.get(e.transactionHash)
      return {
        ...pos(e),
        kind: 'Repaid from buffer' as const,
        amount: e.args.repaid ?? 0n,
        unit: 'USDG' as const,
        debtAfter: r?.args.debtAfter,
        debtBefore: r?.args.debtAfter !== undefined ? r.args.debtAfter + (e.args.repaid ?? 0n) : undefined,
        collateralDelta: 0n,
      }
    }),
  ]
  raw.sort((a, b) => (a.block === b.block ? a.logIndex - b.logIndex : a.block < b.block ? -1 : 1))

  // Events that do not move the debt carry the last debt an earlier event reported.
  let lastDebt: bigint | undefined
  for (const r of raw) {
    if (r.debtAfter === undefined) {
      r.debtBefore = lastDebt
      r.debtAfter = lastDebt
    } else lastDebt = r.debtAfter
  }

  await timestamps(client, [...raw.map(r => r.block), ...steps.map(s => s.blockNumber)])

  // Walk backwards from today's collateral, so history outside the lookback window does not matter.
  let collateral = currentCollateral ?? 0n
  const collateralAt = new Map<Raw, { before: bigint; after: bigint }>()
  for (let i = raw.length - 1; i >= 0; i--) {
    const r = raw[i]
    const after = r.collateralAfterExact ?? collateral
    const prior = after - r.collateralDelta
    collateralAt.set(r, { before: prior, after })
    collateral = prior
  }

  const items: HistoryItem[] = raw.map(r => {
    const at: Pos = { blockNumber: r.block, logIndex: r.logIndex }
    const lastStep = [...steps].reverse().find(s => before(s, at))
    const offset = lastStep ? Number(lastStep.args.time ?? 0n) - (blockTimes.get(String(lastStep.blockNumber)) ?? 0) : 0
    const t = (blockTimes.get(String(r.block)) ?? 0) + offset
    const lastPrice = [...steps].reverse().find(s => before(s, at) && (s.args.answer ?? 0n) !== 0n)
    const price = lastPrice ? Number(lastPrice.args.answer!) / scale : undefined
    const col = collateralAt.get(r)!
    const { collateralDelta: _d, collateralAfterExact: _x, ...rest } = r
    return {
      ...rest,
      t,
      collateralBefore: col.before,
      collateralAfter: col.after,
      price,
      ltvBefore: ltv(r.debtBefore, col.before, price),
      ltvAfter: ltv(r.debtAfter, col.after, price),
    }
  })
  items.reverse()
  return { prices, items, gate, feedDecimals }
}

/** Prices, the account's events (newest first) and gate events, refreshed every few seconds. */
export function useHistory(account: Address | undefined, currentCollateral: bigint | undefined) {
  const client = usePublicClient({ chainId: chain.id })
  return useQuery({
    queryKey: ['history', chain.id, account, currentCollateral?.toString()],
    enabled: !!client && !!contracts,
    refetchInterval: 4_000,
    placeholderData: prev => prev,
    queryFn: async () => {
      const c = contracts!
      const feedDecimals = Number(await client!.readContract({ address: c.gate, abi: gateAbi, functionName: 'stockFeedDecimals' }))
      return load(client as PublicClient, account, currentCollateral, feedDecimals)
    },
  })
}
