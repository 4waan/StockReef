'use client'

import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { maxUint256, type Address } from 'viem'
import { usePublicClient, useReadContract, useWriteContract, useAccount } from 'wagmi'
import { lensAbi, erc20Abi, marketAbi, escrowAbi, policyAbi, gateAbi, demoAbi } from '@/generated/abi'
import { chain, contracts, ZERO } from './chain'
import type { Snapshot } from './types'

const POLL = 2_000

export function useMarketView() {
  return useReadContract({
    address: contracts?.lens,
    abi: lensAbi,
    functionName: 'marketView',
    chainId: chain.id,
    query: { enabled: !!contracts, refetchInterval: POLL },
  })
}

export function useAccountView(account: Address | undefined) {
  return useReadContract({
    address: contracts?.lens,
    abi: lensAbi,
    functionName: 'accountView',
    args: [account ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!contracts && !!account, refetchInterval: POLL },
  })
}

export function useActiveAccounts() {
  return useReadContract({
    address: contracts?.lens,
    abi: lensAbi,
    functionName: 'activeAccountViews',
    chainId: chain.id,
    query: { enabled: !!contracts, refetchInterval: POLL },
  })
}

export function useTokenBalance(token: Address | undefined, owner: Address | undefined) {
  return useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [owner ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!token && !!owner, refetchInterval: POLL },
  })
}

/** Seconds of protocol time, ticking locally between polls so countdowns move smoothly. */
export function useProtocolNow(snapshotTime: bigint | undefined): number | undefined {
  const [now, setNow] = useState<number>()
  useEffect(() => {
    if (snapshotTime === undefined) return
    const base = Number(snapshotTime)
    const started = Date.now()
    setNow(base)
    const id = setInterval(() => setNow(base + Math.floor((Date.now() - started) / 1000)), 1000)
    return () => clearInterval(id)
  }, [snapshotTime])
  return now
}

export type TxStatus = { state: 'idle' | 'approving' | 'pending' | 'mined' | 'failed'; hash?: string; error?: string }

/**
 * Sends a contract call (after an approval when `approve` is given), waits for the receipt and refreshes
 * every read so the screen shows the result immediately.
 */
export function useTx() {
  const client = usePublicClient({ chainId: chain.id })
  const queryClient = useQueryClient()
  const { address } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const [status, setStatus] = useState<TxStatus>({ state: 'idle' })

  async function send(
    call: Parameters<typeof writeContractAsync>[0],
    approve?: { token: Address; spender: Address; amount: bigint },
  ) {
    try {
      if (approve && address && client) {
        const allowance = (await client.readContract({
          address: approve.token,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [address, approve.spender],
        })) as bigint
        if (allowance < approve.amount) {
          setStatus({ state: 'approving' })
          const h = await writeContractAsync({
            address: approve.token,
            abi: erc20Abi,
            functionName: 'approve',
            args: [approve.spender, maxUint256],
          })
          await client.waitForTransactionReceipt({ hash: h })
        }
      }
      setStatus({ state: 'pending' })
      const hash = await writeContractAsync(call)
      const receipt = await client!.waitForTransactionReceipt({ hash })
      setStatus({ state: receipt.status === 'success' ? 'mined' : 'failed', hash })
    } catch (error) {
      const e = error as { shortMessage?: string; message?: string }
      setStatus({ state: 'failed', error: (e.shortMessage ?? e.message ?? 'failed').split('\n')[0] })
    } finally {
      await queryClient.invalidateQueries()
    }
  }

  return { send, status, reset: () => setStatus({ state: 'idle' }) }
}

export interface Receipt {
  kind: 'Buffer repaid' | 'Trimmed' | 'Repaid' | 'Borrowed' | 'Written off'
  amount: bigint
  hash: string
  block: bigint
  detail?: string
}

/** Recent executions for an account: buffer repayments, trims, repayments and borrowing. */
export function useReceipts(account: Address | undefined) {
  const client = usePublicClient({ chainId: chain.id })
  const [receipts, setReceipts] = useState<Receipt[]>([])
  useEffect(() => {
    if (!client || !contracts || !account) return
    let alive = true
    const load = async () => {
      try {
        const head = await client.getBlockNumber()
        const fromBlock = head > 200_000n ? head - 200_000n : 0n
        const [trims, repays, borrows, buffers, writeOffs] = await Promise.all([
          client.getContractEvents({ address: contracts!.market, abi: marketAbi, eventName: 'Trimmed', args: { account }, fromBlock }),
          client.getContractEvents({ address: contracts!.market, abi: marketAbi, eventName: 'Repaid', args: { account }, fromBlock }),
          client.getContractEvents({ address: contracts!.market, abi: marketAbi, eventName: 'Borrowed', args: { account }, fromBlock }),
          client.getContractEvents({ address: contracts!.escrow, abi: escrowAbi, eventName: 'BufferExecuted', args: { account }, fromBlock }),
          client.getContractEvents({ address: contracts!.market, abi: marketAbi, eventName: 'BadDebtWrittenOff', args: { account }, fromBlock }),
        ])
        const bufferTx = new Set(buffers.map(b => b.transactionHash))
        const list: Receipt[] = [
          ...trims.map(e => ({ kind: 'Trimmed' as const, amount: e.args.repaid ?? 0n, hash: e.transactionHash, block: e.blockNumber, detail: `bonus ${(Number(e.args.bonusWad ?? 0n) / 1e16).toFixed(0)}%` })),
          ...buffers.map(e => ({ kind: 'Buffer repaid' as const, amount: e.args.repaid ?? 0n, hash: e.transactionHash, block: e.blockNumber })),
          ...repays
            .filter(e => !bufferTx.has(e.transactionHash))
            .map(e => ({ kind: 'Repaid' as const, amount: e.args.amount ?? 0n, hash: e.transactionHash, block: e.blockNumber })),
          ...borrows.map(e => ({ kind: 'Borrowed' as const, amount: e.args.amount ?? 0n, hash: e.transactionHash, block: e.blockNumber })),
          ...writeOffs.map(e => ({ kind: 'Written off' as const, amount: e.args.amount ?? 0n, hash: e.transactionHash, block: e.blockNumber })),
        ]
        list.sort((a, b) => Number(b.block - a.block))
        if (alive) setReceipts(list.slice(0, 8))
      } catch {
        // A public RPC may refuse wide log ranges; receipts are a convenience, the Lens remains the source.
      }
    }
    load()
    const id = setInterval(load, 4_000)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, [client, account])
  return receipts
}

export interface ProtocolConstants {
  ratePerSecond: bigint
  utilizationCap: bigint
  maxBufferTarget: bigint
  ltOpen: bigint
  ltFinalOvernight: bigint
  ltFinalExtended: bigint
  targetOpen: bigint
  targetOvernight: bigint
  targetExtended: bigint
  borrowOpen: bigint
  borrowGap: bigint
  bonusScheduling: bigint
  bonusDistress: bigint
}

/** Fixed policy, rate and cap constants, read once from the deployed contracts. */
export function useProtocolConstants() {
  const client = usePublicClient({ chainId: chain.id })
  return useQuery({
    queryKey: ['constants', chain.id],
    enabled: !!client && !!contracts,
    staleTime: Infinity,
    queryFn: async (): Promise<ProtocolConstants> => {
      const c = contracts!
      const p = (functionName: 'LT_OPEN' | 'LT_FINAL_OVERNIGHT' | 'LT_FINAL_EXTENDED' | 'TARGET_OPEN' | 'TARGET_OVERNIGHT' | 'TARGET_EXTENDED' | 'B_OPEN' | 'BORROW_GAP' | 'BONUS_SCHEDULING' | 'BONUS_DISTRESS') =>
        client!.readContract({ address: c.policy, abi: policyAbi, functionName }) as Promise<bigint>
      const [ratePerSecond, utilizationCap, maxBufferTarget, ltOpen, ltFinalOvernight, ltFinalExtended, targetOpen, targetOvernight, targetExtended, borrowOpen, borrowGap, bonusScheduling, bonusDistress] =
        await Promise.all([
          client!.readContract({ address: c.market, abi: marketAbi, functionName: 'RATE_PER_SECOND' }) as Promise<bigint>,
          client!.readContract({ address: c.market, abi: marketAbi, functionName: 'UTILIZATION_CAP' }) as Promise<bigint>,
          client!.readContract({ address: c.escrow, abi: escrowAbi, functionName: 'MAX_TARGET' }) as Promise<bigint>,
          p('LT_OPEN'),
          p('LT_FINAL_OVERNIGHT'),
          p('LT_FINAL_EXTENDED'),
          p('TARGET_OPEN'),
          p('TARGET_OVERNIGHT'),
          p('TARGET_EXTENDED'),
          p('B_OPEN'),
          p('BORROW_GAP'),
          p('BONUS_SCHEDULING'),
          p('BONUS_DISTRESS'),
        ])
      return { ratePerSecond, utilizationCap, maxBufferTarget, ltOpen, ltFinalOvernight, ltFinalExtended, targetOpen, targetOvernight, targetExtended, borrowOpen, borrowGap, bonusScheduling, bonusDistress }
    },
  })
}

/**
 * Liquidation threshold at each time of the session's pre-close ramp, from SessionRiskPolicy.ltAt. The ramp uses the
 * class of the coming closure, SessionRiskPolicy.classOf(nextOpen - close), which can differ from the class that
 * applies now while a reopening still runs at the previous closure's limits.
 */
export function useLtCurve(close: bigint | undefined, nextOpen: bigint | undefined, times: bigint[]) {
  const client = usePublicClient({ chainId: chain.id })
  return useQuery({
    queryKey: ['ltCurve', chain.id, close?.toString(), nextOpen?.toString(), times.map(String).join(',')],
    enabled: !!client && !!contracts && !!close && !!nextOpen && nextOpen > close && times.length > 0,
    staleTime: Infinity,
    queryFn: async () => {
      const cls = (await client!.readContract({ address: contracts!.policy, abi: policyAbi, functionName: 'classOf', args: [nextOpen! - close!] })) as number
      const lts = await Promise.all(
        times.map(t => client!.readContract({ address: contracts!.policy, abi: policyAbi, functionName: 'ltAt', args: [cls, t, close!] }) as Promise<bigint>),
      )
      return times.map((t, i) => ({ t: Number(t), lt: lts[i] }))
    },
  })
}

/**
 * Most collateral that can be withdrawn now, and why it is zero. Without debt it is all of it. With debt the market
 * requires borrowing to be open and no active buffer plan from preparation start (escrow.blocksBorrowing), and the
 * rest must keep the loan within the borrow limit: PriceGate.rawForValue(debt / B), rounded up, stays behind.
 */
export function useMaxCollateralWithdraw(account: Address | undefined, v: { debt: bigint; collateral: bigint } | undefined, s: Snapshot | undefined, priceWad: bigint | undefined) {
  const client = usePublicClient({ chainId: chain.id })
  return useQuery({
    queryKey: ['maxCollateralWithdraw', chain.id, account, v?.debt.toString(), v?.collateral.toString(), s?.time.toString(), priceWad?.toString()],
    enabled: !!client && !!contracts && !!v && !!s && !!account,
    queryFn: async (): Promise<{ max: bigint; blocked?: 'closed' | 'buffer' }> => {
      if (v!.debt === 0n) return { max: v!.collateral }
      if (!s!.canBorrow || !priceWad) return { max: 0n, blocked: 'closed' }
      const blocked = (await client!.readContract({ address: contracts!.escrow, abi: escrowAbi, functionName: 'blocksBorrowing', args: [account!, s!] })) as boolean
      if (blocked) return { max: 0n, blocked: 'buffer' }
      const needValue = (v!.debt * 10n ** 18n + s!.borrowLimitWad - 1n) / s!.borrowLimitWad
      const needRaw = (await client!.readContract({ address: contracts!.gate, abi: gateAbi, functionName: 'rawForValue', args: [needValue, priceWad, 1] })) as bigint
      return { max: v!.collateral > needRaw ? v!.collateral - needRaw : 0n }
    },
  })
}

/** The demo operator and whether the connected wallet is it. Undefined operator when the deployment has no demo. */
export function useDemoOperator() {
  const { address } = useAccount()
  const { data: operator } = useReadContract({
    address: contracts?.demoController,
    abi: demoAbi,
    functionName: 'operator',
    chainId: chain.id,
    query: { enabled: !!contracts && contracts.demoController !== ZERO, staleTime: Infinity },
  })
  return { operator, isOperator: !!address && !!operator && operator.toLowerCase() === address.toLowerCase() }
}
