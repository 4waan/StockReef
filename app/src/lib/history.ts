'use client'

import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { parseEventLogs, type Abi, type Address, type Log, type PublicClient } from 'viem'
import { usePublicClient } from 'wagmi'
import { demoAbi, escrowAbi, gateAbi, marketAbi } from '@/generated/abi'
import { chain, contracts, ZERO } from './chain'
import { nyClock } from './format'

/**
 * Event history for the trading view, read from logs. Protocol time is block time plus the demo clock's offset,
 * which every DemoController.Step reveals (Step carries the clock time it moved to). Without a demo controller the
 * clock is the block clock and the offset is zero.
 *
 * Logs of the market, escrow, gate and demo controller are read once from the deployment block, in chunks, then only
 * new blocks are read on each poll. Block times are fetched only for the account's events and the price step that
 * precedes each one.
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

export interface History {
  prices: PricePoint[]
  items: HistoryItem[]
  gate: GateEvent[]
  feedDecimals: number
}

// ------------------------------------------------------------------ log cache

interface Ev {
  address: string // lower case
  eventName: string
  args: Record<string, unknown>
  blockNumber: bigint
  logIndex: number
  transactionHash: `0x${string}`
}

const FIRST_CHUNK = 2_000_000n
const MIN_CHUNK = 2_000n

const caches = new Map<number, { next: bigint; span: bigint; events: Ev[] }>()
const blockTimes = new Map<string, number>()
let syncing: Promise<unknown> = Promise.resolve()

function decode(raw: Log[]): Ev[] {
  const c = contracts!
  const abis: [string, Abi][] = [
    [c.market.toLowerCase(), marketAbi as Abi],
    [c.escrow.toLowerCase(), escrowAbi as Abi],
    [c.gate.toLowerCase(), gateAbi as Abi],
    [c.demoController.toLowerCase(), demoAbi as Abi],
  ]
  const out: Ev[] = []
  for (const [address, abi] of abis) {
    const logs = raw.filter(l => l.address.toLowerCase() === address)
    for (const e of parseEventLogs({ abi, logs })) {
      out.push({ address, eventName: e.eventName, args: e.args as Record<string, unknown>, blockNumber: e.blockNumber!, logIndex: e.logIndex!, transactionHash: e.transactionHash! })
    }
  }
  return out
}

/** Reads every log from where the cache stopped to the head, halving the range whenever the RPC refuses one. */
async function catchUp(client: PublicClient): Promise<Ev[]> {
  const c = contracts!
  const head = await client.getBlockNumber()
  let entry = caches.get(chain.id)
  // A restarted local chain starts over below what was read.
  if (!entry || head + 1n < entry.next) entry = { next: c.deployBlock, span: FIRST_CHUNK, events: [] }
  caches.set(chain.id, entry)
  const addresses = [c.market, c.escrow, c.gate, ...(c.demoController !== ZERO ? [c.demoController] : [])]
  // The range the RPC last accepted is remembered, so later polls do not probe from the top again.
  while (entry.next <= head) {
    const span = entry.span
    const to = entry.next + span - 1n < head ? entry.next + span - 1n : head
    try {
      const raw = await client.getLogs({ address: addresses, fromBlock: entry.next, toBlock: to })
      const events = decode(raw)
      events.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1))
      entry.events.push(...events)
      entry.next = to + 1n
    } catch (error) {
      if (span <= MIN_CHUNK) throw error
      entry.span = span / 4n
    }
  }
  return entry.events
}

async function fetchBlockTimes(client: PublicClient, blocks: bigint[]) {
  const missing = [...new Set(blocks.map(String))].filter(b => !blockTimes.has(b))
  await Promise.all(
    missing.map(async b => {
      const block = await client.getBlock({ blockNumber: BigInt(b) })
      blockTimes.set(b, Number(block.timestamp))
    }),
  )
}

type Pos = { blockNumber: bigint; logIndex: number }
const atOrBefore = (a: Pos, b: Pos) => a.blockNumber < b.blockNumber || (a.blockNumber === b.blockNumber && a.logIndex <= b.logIndex)

/** The last element of a sorted list at or before a position, by binary search. */
function lastAtOrBefore<T extends Pos>(sorted: T[], at: Pos): T | undefined {
  let lo = 0
  let hi = sorted.length - 1
  let found: T | undefined
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (atOrBefore(sorted[mid], at)) {
      found = sorted[mid]
      lo = mid + 1
    } else hi = mid - 1
  }
  return found
}

const forAccount = (e: Ev, account: string) => typeof e.args.account === 'string' && e.args.account.toLowerCase() === account

// ------------------------------------------------------------------ derivation

function ltv(debt: bigint | undefined, collateral: bigint, price: number | undefined): number | undefined {
  if (debt === undefined || price === undefined || price <= 0) return undefined
  if (debt === 0n) return 0
  const value = (Number(collateral) / 1e18) * price
  return value > 0 ? Number(debt) / 1e6 / value : undefined
}

const big = (v: unknown) => (typeof v === 'bigint' ? v : 0n)

function derive(events: Ev[], account: Address | undefined, currentCollateral: bigint | undefined, feedDecimals: number): History {
  const c = contracts!
  const demo = c.demoController.toLowerCase()
  const gateAddr = c.gate.toLowerCase()
  const scale = 10 ** feedDecimals

  const steps = events.filter(e => e.address === demo && e.eventName === 'Step')
  const priceSteps = steps.filter(s => big(s.args.answer) !== 0n)
  const prices: PricePoint[] = priceSteps.map(s => ({ t: Number(big(s.args.time)), price: Number(big(s.args.answer)) / scale }))

  const gateKinds: Record<string, GateEvent['kind']> = {
    Admitted: 'Admitted',
    AdmissionReset: 'Admission reset',
    OutageDetected: 'Outage detected',
    RecoveryCheckpoint: 'Recovery checkpoint',
    Stopped: 'Stopped',
    ResumeRequested: 'Resume requested',
    Resumed: 'Resumed',
  }
  const gate: GateEvent[] = events
    .filter(e => e.address === gateAddr && gateKinds[e.eventName])
    .map(e => ({
      kind: gateKinds[e.eventName],
      hash: e.transactionHash,
      t: Number(e.eventName === 'Admitted' ? big(e.args.admissionAt) : big(e.args.at)),
      detail:
        e.eventName === 'Admitted'
          ? `price from ${nyClock(big(e.args.priceUpdatedAt))} ET`
          : e.eventName === 'ResumeRequested'
            ? `available ${nyClock(big(e.args.availableAt))} ET`
            : undefined,
    }))
    .reverse()

  if (!account) return { prices, items: [], gate, feedDecimals }
  const who = account.toLowerCase()
  const market = c.market.toLowerCase()
  const escrow = c.escrow.toLowerCase()
  const mine = events.filter(e => (e.address === market || e.address === escrow) && forAccount(e, who))

  // Buffer executions and owner repayments also emit Repaid from the market; fold those into one row.
  const repaidByTx = new Map(mine.filter(e => e.address === market && e.eventName === 'Repaid').map(r => [r.transactionHash, r]))
  const folded = new Set(mine.filter(e => e.address === escrow && (e.eventName === 'BufferExecuted' || e.eventName === 'OwnerRepaid')).map(e => e.transactionHash))

  type Raw = Omit<HistoryItem, 't' | 'collateralBefore' | 'collateralAfter' | 'price' | 'ltvBefore' | 'ltvAfter'> & { collateralDelta: bigint; collateralAfterExact?: bigint }
  const raw: Raw[] = []
  for (const e of mine) {
    const pos = { hash: e.transactionHash, block: e.blockNumber, logIndex: e.logIndex }
    const a = e.args
    const key = `${e.address === market ? 'm' : 'e'}:${e.eventName}`
    switch (key) {
      case 'm:CollateralDeposited':
        raw.push({ ...pos, kind: 'Collateral added', amount: big(a.amount), unit: 'TSLA', collateralDelta: big(a.amount) })
        break
      case 'm:CollateralWithdrawn':
        raw.push({ ...pos, kind: 'Collateral withdrawn', amount: big(a.amount), unit: 'TSLA', collateralDelta: -big(a.amount) })
        break
      case 'm:Borrowed':
        raw.push({ ...pos, kind: 'Borrowed', amount: big(a.amount), unit: 'USDG', debtAfter: big(a.debtAfter), debtBefore: big(a.debtAfter) - big(a.amount), collateralDelta: 0n })
        break
      case 'm:Repaid':
        if (!folded.has(e.transactionHash))
          raw.push({ ...pos, kind: 'Repaid', amount: big(a.amount), unit: 'USDG', debtAfter: big(a.debtAfter), debtBefore: big(a.debtAfter) + big(a.amount), collateralDelta: 0n })
        break
      case 'm:Trimmed':
        raw.push({
          ...pos,
          kind: 'Trimmed',
          amount: big(a.repaid),
          unit: 'USDG',
          detail: `${(Number(big(a.bonusWad)) / 1e16).toFixed(0)}% bonus · ${(Number(big(a.collateralOut)) / 1e18).toFixed(4)} TSLA out`,
          debtAfter: big(a.debtAfter),
          debtBefore: big(a.debtAfter) + big(a.repaid),
          collateralDelta: -big(a.collateralOut),
          collateralAfterExact: big(a.collateralAfter),
        })
        break
      case 'm:BadDebtWrittenOff':
        raw.push({ ...pos, kind: 'Written off', amount: big(a.amount), unit: 'USDG', debtBefore: big(a.amount), debtAfter: 0n, collateralDelta: 0n })
        break
      case 'e:Deposited':
        raw.push({ ...pos, kind: 'Buffer funded', amount: big(a.amount), unit: 'USDG', collateralDelta: 0n })
        break
      case 'e:Withdrawn':
        raw.push({ ...pos, kind: 'Buffer withdrawn', amount: big(a.amount), unit: 'USDG', collateralDelta: 0n })
        break
      case 'e:Authorized':
        raw.push({
          ...pos,
          kind: 'Buffer authorized',
          amount: big(a.perSessionCap),
          unit: 'USDG',
          detail: `target ${(Number(big(a.targetWad)) / 1e16).toFixed(1)}% · cap per session`,
          collateralDelta: 0n,
        })
        break
      case 'e:Cancelled':
        raw.push({ ...pos, kind: 'Buffer cancelled', amount: 0n, unit: '', collateralDelta: 0n })
        break
      case 'e:BufferExecuted':
        raw.push({ ...pos, kind: 'Buffer repaid', amount: big(a.repaid), unit: 'USDG', debtBefore: big(a.debtBefore), debtAfter: big(a.debtAfter), collateralDelta: 0n })
        break
      case 'e:OwnerRepaid': {
        const r = repaidByTx.get(e.transactionHash)
        const after = r ? big(r.args.debtAfter) : undefined
        raw.push({ ...pos, kind: 'Repaid from buffer', amount: big(a.repaid), unit: 'USDG', debtAfter: after, debtBefore: after !== undefined ? after + big(a.repaid) : undefined, collateralDelta: 0n })
        break
      }
    }
  }
  raw.sort((x, y) => (x.block === y.block ? x.logIndex - y.logIndex : x.block < y.block ? -1 : 1))

  // Events that do not move the debt carry the last debt an earlier event reported.
  let lastDebt: bigint | undefined
  for (const r of raw) {
    if (r.debtAfter === undefined) {
      r.debtBefore = lastDebt
      r.debtAfter = lastDebt
    } else lastDebt = r.debtAfter
  }

  // Walk backwards from today's collateral, so the earliest events need no starting balance.
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
    const lastStep = lastAtOrBefore(steps, at)
    const stepTime = lastStep ? blockTimes.get(String(lastStep.blockNumber)) : undefined
    const offset = lastStep && stepTime !== undefined ? Number(big(lastStep.args.time)) - stepTime : 0
    const t = (blockTimes.get(String(r.block)) ?? 0) + offset
    const lastPrice = lastAtOrBefore(priceSteps, at)
    const price = lastPrice ? Number(big(lastPrice.args.answer)) / scale : undefined
    const col = collateralAt.get(r)!
    const { collateralDelta: _d, collateralAfterExact: _x, ...rest } = r
    return { ...rest, t, collateralBefore: col.before, collateralAfter: col.after, price, ltvBefore: ltv(r.debtBefore, col.before, price), ltvAfter: ltv(r.debtAfter, col.after, price) }
  })
  items.reverse()
  return { prices, items, gate, feedDecimals }
}

// ------------------------------------------------------------------ hook

/**
 * Prices, the account's events (newest first) and gate events. Polls every few seconds for new blocks only. When a
 * read fails, the last good history stays on screen and `error` is set.
 */
export function useHistory(account: Address | undefined, currentCollateral: bigint | undefined) {
  const client = usePublicClient({ chainId: chain.id })
  const query = useQuery({
    queryKey: ['history', chain.id, account],
    enabled: !!client && !!contracts,
    refetchInterval: 4_000,
    retry: 1, // polling retries anyway; report a failure quickly so the status bar can say so
    structuralSharing: false,
    placeholderData: prev => prev,
    queryFn: async () => {
      const pc = client as PublicClient
      const c = contracts!
      // One catch-up at a time, so two views polling together never read the same range twice.
      const run = syncing.then(() => catchUp(pc))
      syncing = run.catch(() => undefined)
      const [events, feedDecimals] = await Promise.all([run, pc.readContract({ address: c.gate, abi: gateAbi, functionName: 'stockFeedDecimals' }).then(Number)])
      // Block times only for this account's events and the price step before each of them.
      if (account) {
        const who = account.toLowerCase()
        const market = c.market.toLowerCase()
        const escrow = c.escrow.toLowerCase()
        const demo = c.demoController.toLowerCase()
        const steps = events.filter(e => e.address === demo && e.eventName === 'Step')
        const mine = events.filter(e => (e.address === market || e.address === escrow) && forAccount(e, who))
        const needed = mine.flatMap(e => [e.blockNumber, ...(lastAtOrBefore(steps, e) ? [lastAtOrBefore(steps, e)!.blockNumber] : [])])
        await fetchBlockTimes(pc, needed)
      }
      return { events: events.slice(), feedDecimals }
    },
  })
  const data = useMemo(
    () => (query.data ? derive(query.data.events, account, currentCollateral, query.data.feedDecimals) : undefined),
    [query.data, account, currentCollateral],
  )
  return { data, error: query.error, isLoading: query.isLoading }
}
