'use client'

import { hhmm, nyClock, price } from '@/lib/format'
import type { PricePoint } from '@/lib/history'
import { nextMilestone, PHASE_TICKER, stateName } from '@/lib/policy'
import type { MarketData } from '@/lib/types'

/** Accepted price, change since the previous session's last price, state, New York clock and countdown. */
export function Ticker({ m, now, prices }: { m: MarketData; now: number; prices: PricePoint[] }) {
  const s = m.policy
  const state = stateName(s.state)
  const next = nextMilestone(stateName(s.phase), s)
  const current = Number(m.valuationPriceWad) / 1e18
  const prevClose = [...prices].reverse().find(p => p.t < Number(s.open))?.price
  const change = prevClose && current ? (current / prevClose - 1) * 100 : undefined
  const tone = state === 'GUARDED' ? 'text-dk-down' : state === 'OPEN' ? 'text-dk-up' : state === 'CLOSED' || state === 'REOPEN_WAIT' ? 'text-dk-muted' : 'text-dk-warn'
  return (
    <div className="flex h-10 items-center gap-4 overflow-x-auto border-b border-dk-line px-5 text-[15px] whitespace-nowrap">
      <span className="num font-medium">{price(m.valuationPriceWad)}</span>
      {m.valuationIndicative && <span className="text-sm text-dk-warn">indicative</span>}
      {change !== undefined && (
        <>
          <Sep />
          <span className={`num ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`} title="Since the previous session's last stock price">
            {change >= 0 ? '+' : ''}
            {change.toFixed(2)}%
          </span>
        </>
      )}
      <Sep />
      <span className={`text-sm tracking-wide ${tone}`}>{PHASE_TICKER[state]}</span>
      <Sep />
      <span className="num text-dk-muted">{nyClock(now)} ET</span>
      {next && (
        <>
          <Sep />
          <span className="num text-dk-muted" title={`${next.label} at ${nyClock(next.at)} ET`}>
            {next.short} {hhmm(Number(next.at) - now)}
          </span>
        </>
      )}
    </div>
  )
}

function Sep() {
  return <span className="h-4 w-px bg-dk-line" />
}
