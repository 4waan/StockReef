'use client'

import { usePathname } from 'next/navigation'
import { nyClock } from '@/lib/format'
import { STEPS } from '@/lib/script'
import { useSession } from '@/lib/session'
import { OraclePill } from './Oracle'
import { Info } from './ui'

/**
 * The presenter's session bar, one row: the scripted steps (also → / ← keys; H hides the bar), the testnet oracle
 * pill, and previous / next.
 */
export function SessionDock() {
  const path = usePathname()
  const { steps, at, go, next, prev, dock, setDock, current, restart, error } = useSession()
  if (path === '/evidence' || path === '/operations') return null
  if (!dock)
    return (
      <button type="button" onClick={() => setDock(true)} className="fixed right-4 bottom-4 z-40 rounded-full border border-dk-line bg-dk-panel px-3 py-1.5 text-xs text-dk-muted shadow-xl hover:text-dk-ink">
        {current ? `${current.step.day === 'mon' ? 'Mon' : 'Fri'} ${nyClock(current.t)}` : 'Session'} · H
      </button>
    )
  return (
    <div className="sticky bottom-0 z-30 flex items-center gap-3 border-t border-dk-line bg-dk-bg/95 px-3 py-1.5 backdrop-blur">
      <span className="hidden items-center gap-1.5 text-[11px] font-semibold tracking-[.12em] text-accent uppercase xl:flex">
        Scenario
        <Info label="About the scenario clock" side="top">
          Scripted: the clock and the TSLA price. Live: every balance, limit, amount and receipt, read from the contracts at that step. Keys: → next, ← back, H hide.
          <button type="button" onClick={restart} className="mt-2 block text-dk-up hover:underline">
            Restart on the next weekend
          </button>
        </Info>
      </span>
      <ol className="flex min-w-0 flex-1 items-center overflow-x-auto" aria-label="Session steps">
        {STEPS.map((s, i) => {
          const st = steps?.[i]
          const on = i === at
          const done = i < at
          return (
            <li key={s.id} className="flex shrink-0 items-center">
              {i > 0 && <span className={`mx-0.5 h-px ${s.day === 'mon' && STEPS[i - 1].day === 'fri' ? 'w-6 border-t border-dashed border-dk-faint' : `w-3 ${done || on ? 'bg-brand' : 'bg-dk-line'}`}`} />}
              <button type="button" onClick={() => go(i)} aria-current={on ? 'step' : undefined} title={s.story} className={`flex items-center gap-1.5 rounded px-1.5 py-1 ${on ? 'bg-brand/15' : 'hover:bg-dk-raised'}`}>
                <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${on ? 'bg-brand' : done ? 'bg-brand/60' : 'bg-dk-line'}`} />
                <span className={`num text-[11px] ${on ? 'font-semibold text-dk-ink' : 'text-dk-muted'}`}>
                  {s.day === 'mon' ? 'Mon ' : ''}
                  {st ? nyClock(st.t) : ''}
                </span>
                <span className={`hidden text-[11px] md:inline ${on ? 'text-dk-ink' : 'text-dk-faint'}`}>{s.label}</span>
              </button>
            </li>
          )
        })}
      </ol>
      {error && <span className="text-xs text-dk-down">{error}</span>}
      <span className="hidden sm:block">
        <OraclePill />
      </span>
      <div className="flex items-center gap-1">
        <button type="button" onClick={prev} disabled={at === 0} aria-label="Previous step" className="rounded-md border border-dk-line px-2 py-1 text-sm hover:border-dk-muted disabled:opacity-30">
          ←
        </button>
        <button type="button" onClick={next} disabled={at === STEPS.length - 1} className="rounded-md bg-brand px-3 py-1 text-sm font-semibold text-white hover:bg-[#d36f39] disabled:opacity-30">
          Next →
        </button>
        <button type="button" onClick={() => setDock(false)} aria-label="Hide session bar (H)" className="px-1 text-dk-faint hover:text-dk-ink">
          ×
        </button>
      </div>
    </div>
  )
}
