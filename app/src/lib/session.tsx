'use client'

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { Address, PublicClient } from 'viem'
import { usePublicClient, useReadContract } from 'wagmi'
import { demoAbi, marketAbi } from '@/generated/abi'
import { chain, contracts } from './chain'
import { STEPS, type StepId } from './script'
import { allSteps, findAnchor, readBook, readPolicy, readPosition, type Anchor, type Book, type Policy, type Position, type StepState } from './scenario'

/**
 * The presentation clock. The presenter moves through the scripted steps (buttons in the session dock, or the
 * arrow keys); every page then shows the deployed contracts' answers at that step's time and price for the real
 * accounts. A confirmed transaction is remembered with the step it was signed in, so the chart can mark it there.
 */

export interface LocalReceipt {
  hash: string
  step: StepId
  label: string
}

interface Ctx {
  anchor: Anchor | undefined
  policy: Policy | undefined
  steps: StepState[] | undefined
  at: number
  current: StepState | undefined
  go: (i: number) => void
  next: () => void
  prev: () => void
  restart: () => void
  dock: boolean
  setDock: (v: boolean) => void
  receipts: LocalReceipt[]
  record: (r: LocalReceipt) => void
  chainTime: bigint | undefined
  error: string | undefined
}

const SessionCtx = createContext<Ctx | null>(null)
const KEY = `reef.session.${chain.id}`

function load(): { at: number; from?: string; receipts: LocalReceipt[] } {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? '{}')
    return { at: Number(v.at) || 0, from: typeof v.from === 'string' ? v.from : undefined, receipts: Array.isArray(v.receipts) ? v.receipts : [] }
  } catch {
    return { at: 0, receipts: [] }
  }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const client = usePublicClient({ chainId: chain.id }) as PublicClient | undefined
  const [at, setAt] = useState(0)
  const [from, setFrom] = useState<string>()
  const [receipts, setReceipts] = useState<LocalReceipt[]>([])
  const [dock, setDock] = useState(true)
  const [ready, setReady] = useState(false)

  // The demo clock's time on chain: picks which calendar Friday the script runs on.
  const { data: clockAddr } = useReadContract({ address: contracts?.demoController, abi: demoAbi, functionName: 'clock', chainId: chain.id, query: { enabled: !!contracts, staleTime: Infinity } })
  const { data: chainTime } = useQuery({
    queryKey: ['chainTime', chain.id, clockAddr],
    enabled: !!client && !!clockAddr,
    refetchInterval: 15_000,
    queryFn: async () => (await client!.readContract({ address: clockAddr as Address, abi: [{ type: 'function', name: 'time', inputs: [], outputs: [{ type: 'uint64' }], stateMutability: 'view' }] as const, functionName: 'time' })) as bigint,
  })

  useEffect(() => {
    const s = load()
    const q = new URLSearchParams(window.location.search).get('step')
    const fromUrl = STEPS.findIndex(x => x.id === q)
    setAt(fromUrl >= 0 ? fromUrl : Math.min(s.at, STEPS.length - 1))
    setFrom(s.from)
    setReceipts(s.receipts)
    setReady(true)
  }, [])
  useEffect(() => {
    if (!ready) return
    try {
      localStorage.setItem(KEY, JSON.stringify({ at, from, receipts: receipts.slice(-40) }))
    } catch {
      // Storage can be unavailable; the session still works for this visit.
    }
  }, [at, from, receipts, ready])

  // Without a stored choice: the weekend in progress (Friday to the Monday close), else the next one.
  const anchorFrom = useMemo(() => (from ? BigInt(from) : chainTime), [from, chainTime])
  const anchorQ = useQuery({
    queryKey: ['anchor', chain.id, from ?? 'auto', from ? '' : String(chainTime ? chainTime / 3600n : '')],
    enabled: !!client && !!contracts && anchorFrom !== undefined && ready,
    staleTime: Infinity,
    queryFn: async () => {
      if (from) return findAnchor(client!, contracts!.calendar, BigInt(from))
      const back = await findAnchor(client!, contracts!.calendar, anchorFrom! - 4n * 86_400n)
      return back.mon.close > anchorFrom! ? back : findAnchor(client!, contracts!.calendar, anchorFrom!)
    },
  })
  const anchor = anchorQ.data
  const policyQ = useQuery({
    queryKey: ['scriptPolicy', chain.id, anchor?.fri.index],
    enabled: !!client && !!contracts && !!anchor,
    staleTime: Infinity,
    queryFn: () => readPolicy(client!, contracts!, anchor!),
  })
  const policy = policyQ.data
  const steps = useMemo(() => (anchor && policy ? allSteps(anchor, policy) : undefined), [anchor, policy])

  const go = useCallback((i: number) => setAt(Math.max(0, Math.min(STEPS.length - 1, i))), [])
  const next = useCallback(() => setAt(i => Math.min(STEPS.length - 1, i + 1)), [])
  const prev = useCallback(() => setAt(i => Math.max(0, i - 1)), [])
  const restart = useCallback(() => {
    setAt(0)
    setReceipts([])
    setFrom(chainTime !== undefined ? String(chainTime) : undefined)
  }, [chainTime])
  const record = useCallback((r: LocalReceipt) => setReceipts(list => (list.some(x => x.hash === r.hash) ? list : [...list, r])), [])

  // Presenter keys: → or . next step, ← or , previous step, H hides the session dock.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable)) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key === 'ArrowRight' || e.key === '.') next()
      else if (e.key === 'ArrowLeft' || e.key === ',') prev()
      else if (e.key === 'h' || e.key === 'H') setDock(d => !d)
      else return
      e.preventDefault()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [next, prev])

  const error = (anchorQ.error ?? policyQ.error)?.message
  const value: Ctx = { anchor, policy, steps, at, current: steps?.[at], go, next, prev, restart, dock, setDock, receipts, record, chainTime, error }
  return <SessionCtx.Provider value={value}>{children}</SessionCtx.Provider>
}

export function useSession() {
  const v = useContext(SessionCtx)
  if (!v) throw new Error('SessionProvider is required')
  return v
}

/** One account at the current step, from the contracts; refreshed every few seconds and after transactions. */
export function usePosition(account: Address | undefined, stepIndex?: number) {
  const client = usePublicClient({ chainId: chain.id }) as PublicClient | undefined
  const { steps, at, anchor } = useSession()
  const i = stepIndex ?? at
  return useQuery<Position>({
    queryKey: ['position', chain.id, account, anchor?.fri.index, i],
    enabled: !!client && !!contracts && !!steps && !!account,
    refetchInterval: 4_000,
    placeholderData: prev => prev,
    queryFn: () => readPosition(client!, contracts!, account!, steps!, i),
  })
}

/** The lender book at the current step: cash plus each loan's recoverable value at the step's price. */
export function useBook(stepIndex?: number) {
  const client = usePublicClient({ chainId: chain.id }) as PublicClient | undefined
  const { steps, at, anchor } = useSession()
  const i = stepIndex ?? at
  const { data: haircut } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'RECOVERY_HAIRCUT', chainId: chain.id, query: { enabled: !!contracts, staleTime: Infinity } })
  return useQuery<Book>({
    queryKey: ['book', chain.id, anchor?.fri.index, i, haircut?.toString()],
    enabled: !!client && !!contracts && !!steps && haircut !== undefined,
    refetchInterval: 4_000,
    placeholderData: prev => prev,
    queryFn: () => readBook(client!, contracts!, steps![i], haircut as bigint),
  })
}
