'use client'

import { useEffect, useRef, useState } from 'react'
import type { Address } from 'viem'
import { demoAbi, gateAbi } from '@/generated/abi'
import { contracts, demoAccounts } from '@/lib/chain'
import { duration, nyClock, nyTime, short } from '@/lib/format'
import type { GateEvent } from '@/lib/history'
import { useDemoOperator, useTx } from '@/lib/hooks'
import { reasonList } from '@/lib/policy'
import type { MarketData } from '@/lib/types'
import { Dot, Select, TxStatusLine } from './kit'

const SPEEDS = ['1', '10', '60'] as const
const TICK_MS = 15_000

/** Price feed health on the left; on the demo deployment, the scenario picker and the operator's clock controls. */
export function StatusBar({
  m,
  now,
  gate,
  feedDecimals,
  historyError,
  viewing,
  onView,
}: {
  m: MarketData
  now: number
  gate: GateEvent[]
  feedDecimals: number
  historyError: boolean
  viewing: Address | undefined
  onView: (a: Address) => void
}) {
  const s = m.policy
  const refresh = useTx()
  const demo = useTx()
  const { operator, isOperator } = useDemoOperator()
  const [playing, setPlaying] = useState(false)
  const [speed, setSpeed] = useState<(typeof SPEEDS)[number]>('1')
  const age = s.priceUpdatedAt > 0n ? now - Number(s.priceUpdatedAt) : undefined
  const usable = s.reasons === 0
  const answer = m.valuationPriceWad / 10n ** BigInt(18 - feedDecimals)

  // Next scheduled milestone after now, for "Advance session".
  const steps = [s.prepAt, s.close - 2700n, s.finalAt, s.close + 3600n, s.nextOpen + 60n, s.nextOpen + 300n, s.nextOpen + 900n, s.open + 300n, s.open + 900n]
  const next = steps.filter(t => Number(t) > now).sort((a, b) => Number(a - b))[0]

  // Auto-play: each tick moves the demo clock forward and republishes the current price, so it never goes stale.
  const send = useRef(demo.send)
  send.current = demo.send
  useEffect(() => {
    if (!playing || !contracts || !isOperator) return
    const id = setInterval(() => {
      send.current({ address: contracts!.demoController, abi: demoAbi, functionName: 'step', args: [BigInt((TICK_MS / 1000) * Number(speed)), answer] })
    }, TICK_MS)
    return () => clearInterval(id)
  }, [playing, speed, isOperator, answer])

  const scenario = demoAccounts.find(d => viewing && d.address.toLowerCase() === viewing.toLowerCase())?.address ?? ''

  return (
    <footer className="z-10 flex lg:sticky lg:bottom-0 flex-wrap items-center gap-x-4 gap-y-2 border-t border-dk-line bg-dk-bg px-5 py-2 text-sm">
      <details className="relative">
        <summary className="flex cursor-pointer list-none items-center gap-2">
          <Dot tone={usable ? 'up' : 'down'} />
          <span>{m.simulationClock ? 'Mock feed' : 'Chainlink feed'}</span>
          {age !== undefined && <span className="num text-dk-muted">· {age < 60 ? `${age}s` : duration(age)}</span>}
          {!usable && <span className="text-dk-down">· {reasonList(Number(s.reasons))[0]}</span>}
          {m.usesPeg && <span className="text-dk-muted">· {m.pegLabel || 'Test peg'}</span>}
          {historyError && <span className="text-dk-warn" title="The RPC refused a log read. Charts and tabs show the last history read; it retries every few seconds.">· history unavailable</span>}
        </summary>
        <div className="absolute bottom-full left-0 z-20 mb-2 w-96 rounded-md border border-dk-line bg-dk-panel p-4 shadow-xl">
          <div className="font-medium">Price gate</div>
          <p className="mt-1 text-dk-muted">
            {usable ? 'Price usable.' : `Not usable: ${reasonList(Number(s.reasons)).join(' · ')}.`} Last accepted {m.lastAcceptedAt > 0n ? `${duration(now - Number(m.lastAcceptedAt))} ago` : 'never'}.
            {s.admissionAt > 0n && ` Reopening admitted at ${nyClock(s.admissionAt)} ET.`}
          </p>
          {gate.length > 0 && (
            <ul className="mt-3 max-h-40 space-y-1 overflow-y-auto">
              {gate.slice(0, 12).map(g => (
                <li key={g.hash + g.kind} className="flex justify-between">
                  <span>{g.kind}</span>
                  <span className="num text-dk-muted">{nyTime(g.t)} ET</span>
                </li>
              ))}
            </ul>
          )}
          <button
            type="button"
            onClick={() => contracts && refresh.send({ address: contracts.gate, abi: gateAbi, functionName: 'refresh', args: [] })}
            className="mt-3 rounded-md border border-dk-line px-3 py-1.5 hover:border-dk-muted"
          >
            Refresh gate
          </button>
          <p className="mt-1 text-xs text-dk-faint">Anyone can refresh the gate. The keeper does it on every pass.</p>
          <TxStatusLine status={refresh.status} />
        </div>
      </details>

      {m.simulationClock && (
        <div className="ml-auto flex flex-wrap items-center gap-3">
          {demoAccounts.length > 0 && (
            <Select
              label="Scenario:"
              value={scenario}
              onChange={a => a && onView(a as Address)}
              options={[...(scenario ? [] : [{ key: '', label: 'Pick one' }]), ...demoAccounts.map(d => ({ key: d.address, label: d.label }))]}
            />
          )}
          <button
            type="button"
            disabled={!isOperator}
            onClick={() => setPlaying(p => !p)}
            title={isOperator ? undefined : `Only the demo operator (${operator ? short(operator) : '…'}) can move the clock`}
            className="flex items-center gap-2 rounded-md border border-dk-line px-3 py-1.5 hover:border-dk-muted disabled:opacity-40"
          >
            {playing ? <PauseIcon /> : <PlayIcon />}
            {playing ? 'Pause' : 'Play'}
          </button>
          <Select value={speed} onChange={setSpeed} options={SPEEDS.map(x => ({ key: x, label: `${x}x` }))} />
          <button
            type="button"
            disabled={!isOperator || !next || answer === 0n}
            onClick={() => contracts && next && demo.send({ address: contracts.demoController, abi: demoAbi, functionName: 'stepTo', args: [next, answer] })}
            title={next ? `Moves the demo clock to ${nyClock(next)} ET at the current price` : undefined}
            className="flex items-center gap-2 rounded-md border border-dk-line px-3 py-1.5 hover:border-dk-muted disabled:opacity-40"
          >
            Advance session →
          </button>
          {demo.status.state !== 'idle' && (
            <div className="[&>p]:mt-0">
              <TxStatusLine status={demo.status} />
            </div>
          )}
        </div>
      )}
    </footer>
  )
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="currentColor">
      <path d="M4 2.5v11l9-5.5z" />
    </svg>
  )
}

function PauseIcon() {
  return (
    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="currentColor">
      <path d="M4 2.5h3v11H4zM9 2.5h3v11H9z" />
    </svg>
  )
}
