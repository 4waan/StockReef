'use client'

import { duration, nyTime, localTime, pct, price } from '@/lib/format'
import { useMarketView, useProtocolNow } from '@/lib/hooks'
import { nextMilestone, reasonList, stateName, STATE_COPY } from '@/lib/policy'
import { contracts } from '@/lib/chain'
import { Badge, Notice } from './ui'

/** Where the market is in its session, what happens next and when. */
export function SessionBar() {
  const { data: m, isLoading } = useMarketView()
  const now = useProtocolNow(m?.policy.time)
  if (!contracts) return <div className="mx-auto max-w-6xl px-4 pt-6"><Notice tone="guarded">No StockReef deployment is configured for this chain yet.</Notice></div>
  if (isLoading || !m || now === undefined) return <div className="mx-auto max-w-6xl px-4 pt-6 text-sm text-muted">Reading the market…</div>

  const s = m.policy
  const state = stateName(s.state)
  const phase = stateName(s.phase)
  const copy = STATE_COPY[state]
  const next = nextMilestone(phase, s)
  const reasons = reasonList(Number(s.reasons))

  return (
    <div className="border-b border-line bg-surface/70">
      <div className="mx-auto grid max-w-6xl gap-4 px-4 py-4 md:grid-cols-[1.2fr_1fr]">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone={copy.tone}>{copy.label}</Badge>
            <span className="text-xs text-muted">
              Closure class <b className="text-ink">{s.closureClass === 1 ? 'Extended' : 'Overnight'}</b>
            </span>
          </div>
          <p className="mt-2 text-sm text-muted">{copy.meaning}</p>
          {state === 'GUARDED' && reasons.length > 0 && <p className="mt-1 text-xs text-guarded">Why: {reasons.join(' · ')}</p>}
          {next && (
            <p className="mt-3 text-sm">
              <span className="text-muted">{next.label}</span>{' '}
              <b className="num">{nyTime(next.at)} New York</b>
              <span className="text-faint"> ({localTime(next.at)} your time)</span>{' '}
              <span className="num rounded bg-canvas px-1.5 py-0.5 text-xs">in {duration(Number(next.at) - now)}</span>
            </p>
          )}
        </div>
        <div>
          <Timeline s={s} now={now} />
          <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-muted">
            <span>
              TSLA <b className="num text-ink">{price(m.valuationPriceWad)} USDG</b>
              {m.valuationIndicative && <span className="text-prep"> (last accepted, indicative)</span>}
            </span>
            <span>
              Threshold <b className="num text-ink">{pct(s.ltWad)}</b>
            </span>
            <span>
              Borrow limit <b className="num text-ink">{s.canBorrow ? pct(s.borrowLimitWad) : 'closed'}</b>
            </span>
            <span>
              Clock <b className="num text-ink">{nyTime(now)} NY</b>
            </span>
          </div>
        </div>
      </div>
    </div>
  )
}

type Snap = { open: bigint; close: bigint; prepAt: bigint; finalAt: bigint; nextOpen: bigint; creditAt: bigint; guardAt: bigint; covered: boolean }

function Timeline({ s, now }: { s: Snap; now: number }) {
  const open = Number(s.open)
  const close = Number(s.close)
  const span = close - open
  if (!s.covered || span <= 0) return null
  const pos = (t: number) => `${Math.min(100, Math.max(0, ((t - open) / span) * 100))}%`
  const inSession = now >= open && now < close
  return (
    <div>
      <div className="relative h-3 overflow-hidden rounded-full bg-closed-soft">
        <div className="absolute inset-y-0 bg-reef/70" style={{ left: 0, width: pos(Number(s.prepAt)) }} />
        <div className="absolute inset-y-0 bg-prep/60" style={{ left: pos(Number(s.prepAt)), width: `calc(${pos(Number(s.finalAt))} - ${pos(Number(s.prepAt))})` }} />
        <div className="absolute inset-y-0 bg-final/70" style={{ left: pos(Number(s.finalAt)), right: 0 }} />
        {inSession && <div className="absolute -top-0.5 h-4 w-1 rounded bg-ink" style={{ left: pos(now) }} />}
      </div>
      <div className="mt-1.5 flex justify-between text-[11px] text-muted">
        <span>Open {nyTime(s.open).split(' ')[1]}</span>
        <span>
          <i className="mr-1 inline-block h-2 w-2 rounded-full bg-prep/70" />A {nyTime(s.prepAt).split(' ')[1]}
        </span>
        <span>
          <i className="mr-1 inline-block h-2 w-2 rounded-full bg-final/80" />F {nyTime(s.finalAt).split(' ')[1]}
        </span>
        <span>Close {nyTime(s.close).split(' ')[1]}</span>
      </div>
      {!inSession && <div className="text-xs text-muted">Outside the session: the bar shows the last session.</div>}
    </div>
  )
}
