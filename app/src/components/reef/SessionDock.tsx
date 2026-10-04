'use client'

import { usePathname } from 'next/navigation'
import { demoAbi, gateAbi } from '@/generated/abi'
import { contracts } from '@/lib/chain'
import { duration, nyClock } from '@/lib/format'
import { useDemoOperator, useMarketView, useTx } from '@/lib/hooks'
import { STATE_COPY, stateName } from '@/lib/policy'
import { STEPS } from '@/lib/script'
import { stepTime, type StepState } from '@/lib/scenario'
import { useSession } from '@/lib/session'
import { TxRef } from './ui'

/**
 * The presenter's session bar. The timeline moves the scenario clock (also → / ← keys; H hides the bar). The
 * right side reports the testnet's own clock and price, and lets the demo operator move the testnet to the
 * current step so transactions can execute there.
 */
export function SessionDock() {
  const path = usePathname()
  const { steps, at, go, next, prev, dock, setDock, current, restart, error } = useSession()
  if (path === '/evidence' || path === '/operations') return null
  if (!dock)
    return (
      <button type="button" onClick={() => setDock(true)} className="fixed right-4 bottom-4 z-40 rounded-full border border-dk-line bg-dk-panel/95 px-3 py-1.5 text-xs text-dk-muted shadow-xl backdrop-blur hover:text-dk-ink">
        Session {current ? `· ${current.step.day === 'mon' ? 'Mon' : 'Fri'} ${nyClock(current.t)}` : ''} · H
      </button>
    )
  return (
    <div className="sticky bottom-0 z-30 border-t border-dk-line bg-dk-bg/95 backdrop-blur">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2">
        <div className="min-w-0">
          <div className="text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">Scenario clock</div>
          <div className="hidden text-[11px] text-dk-faint sm:block">Scripted time and TSLA price · live balances, limits and receipts</div>
        </div>
        <ol className="flex min-w-0 flex-1 items-center overflow-x-auto" aria-label="Session steps">
          {STEPS.map((s, i) => {
            const st = steps?.[i]
            const done = i < at
            const on = i === at
            return (
              <li key={s.id} className="flex shrink-0 items-center">
                {i > 0 && <span className={`mx-1 h-px w-4 sm:w-6 ${done || on ? 'bg-brand' : 'bg-dk-line'} ${s.day === 'mon' && STEPS[i - 1].day === 'fri' ? 'w-8 border-t border-dashed border-dk-faint bg-transparent sm:w-10' : ''}`} />}
                <button type="button" onClick={() => go(i)} aria-current={on ? 'step' : undefined} className={`flex items-center gap-1.5 rounded px-1.5 py-1 text-left ${on ? 'bg-brand/15' : 'hover:bg-dk-raised'}`}>
                  <span className={`h-2 w-2 shrink-0 rounded-full ${on ? 'bg-brand ring-2 ring-brand/40' : done ? 'bg-brand/70' : 'bg-dk-line'}`} />
                  <span className="leading-tight">
                    <span className={`num block text-[11px] ${on ? 'text-dk-ink' : 'text-dk-muted'}`}>
                      {s.day === 'mon' ? 'Mon' : 'Fri'} {st ? nyClock(st.t) : ''}
                    </span>
                    <span className={`block text-xs ${on ? 'font-semibold text-dk-ink' : 'text-dk-muted'}`}>{s.label}</span>
                  </span>
                </button>
              </li>
            )
          })}
        </ol>
        <div className="flex items-center gap-1.5">
          <button type="button" onClick={prev} disabled={at === 0} className="rounded-md border border-dk-line px-2.5 py-1.5 text-sm hover:border-dk-muted disabled:opacity-30" aria-label="Previous step">
            ←
          </button>
          <button type="button" onClick={next} disabled={at === STEPS.length - 1} className="rounded-md bg-brand px-3 py-1.5 text-sm font-semibold text-white hover:bg-[#d36f39] disabled:opacity-30">
            Next step →
          </button>
          <button type="button" onClick={() => setDock(false)} className="px-1.5 text-xs text-dk-faint hover:text-dk-ink" title="Hide (H)">
            Hide
          </button>
        </div>
      </div>
      <div className="hidden flex-wrap items-center gap-x-4 gap-y-1 border-t border-dk-line/60 px-4 py-1.5 text-xs sm:flex">
        <span className="text-dk-muted">{current?.step.story}</span>
        <span className="ml-auto" />
        <Testnet current={current} />
        <button type="button" onClick={restart} className="text-dk-faint hover:text-dk-ink" title="Back to Friday 13:00 on the next weekend of the testnet calendar">
          Restart
        </button>
        {error && <span className="text-dk-down">{error}</span>}
      </div>
    </div>
  )
}

/** The testnet's own clock and price, and the operator's controls to align it with the current step. */
function Testnet({ current }: { current: StepState | undefined }) {
  const { data: m } = useMarketView()
  const { anchor, chainTime } = useSession()
  const { isOperator } = useDemoOperator()
  const step = useTx()
  const refresh = useTx()
  const c = contracts
  if (!m || !current || !anchor || !c) return null
  const s = m.policy
  const live = stateName(s.state)
  const age = chainTime !== undefined && s.priceUpdatedAt > 0n ? Number(chainTime - s.priceUpdatedAt) : undefined
  const fresh = s.reasons === 0
  const target = stepTime(anchor, current.step)
  const aligned = chainTime !== undefined && chainTime >= target && chainTime < target + 600n && s.state === current.snapshot.state
  const behind = chainTime !== undefined && chainTime < target
  const answer = BigInt(Math.round(current.step.quote * 1e8))
  return (
    <span className="flex flex-wrap items-center gap-x-3 gap-y-1">
      <span className="text-dk-faint">
        Testnet: <span className={aligned ? 'text-dk-up' : 'text-dk-muted'}>{STATE_COPY[live].label}</span>
        {chainTime !== undefined && <span className="num"> · {new Date(Number(chainTime) * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })} ET</span>}
        <span className={fresh ? 'text-dk-up' : 'text-dk-warn'}> · price {fresh ? 'fresh' : age !== undefined ? `${duration(age)} old` : 'stale'}</span>
        {aligned && <span className="text-dk-up"> · aligned with this step</span>}
      </span>
      {isOperator && (
        <>
          <button
            type="button"
            disabled={!behind || step.status.state === 'pending'}
            onClick={() => step.send({ address: c.demoController, abi: demoAbi, functionName: 'stepTo', args: [target, answer] })}
            title="DemoController.stepTo: moves the testnet clock to this step and publishes the step's price"
            className="rounded border border-brand/60 px-2 py-0.5 text-[#e88a5a] hover:bg-brand/10 disabled:opacity-30"
          >
            Move testnet to {nyClock(target)}
          </button>
          <button
            type="button"
            onClick={() => step.send({ address: c.demoController, abi: demoAbi, functionName: 'push', args: [answer] })}
            title="DemoController.push: re-publishes the step's price at the testnet's current time, so the 120-second price check passes"
            className="rounded border border-dk-line px-2 py-0.5 text-dk-muted hover:text-dk-ink"
          >
            Refresh price
          </button>
          <button type="button" onClick={() => refresh.send({ address: c.gate, abi: gateAbi, functionName: 'refresh', args: [] })} title="PriceGate.refresh: records a reopening admission once its rules are met" className="rounded border border-dk-line px-2 py-0.5 text-dk-muted hover:text-dk-ink">
            Refresh gate
          </button>
          {step.status.hash && <TxRef hash={step.status.hash}>step</TxRef>}
          {step.status.state === 'failed' && <span className="text-dk-down">{step.status.error}</span>}
          {refresh.status.state === 'failed' && <span className="text-dk-down">{refresh.status.error}</span>}
        </>
      )}
    </span>
  )
}
