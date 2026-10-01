'use client'

import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { maxUint256, type Address } from 'viem'
import { usePublicClient, useReadContract, useWriteContract, useAccount } from 'wagmi'
import { lensAbi, erc20Abi, marketAbi, escrowAbi } from '@/generated/abi'
import { chain, contracts, ZERO } from './chain'

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
