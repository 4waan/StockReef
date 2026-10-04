'use client'

import { useMemo, useState } from 'react'
import { useWidth } from '@/components/terminal/kit'
import { ltAtTime, type Marker, type Obs } from '@/lib/desk'
import { nyClock, pctOf, usdg } from '@/lib/format'
import type { Anchor, StepState } from '@/lib/scenario'
import { S } from '@/lib/scenario'

export type ChartMode = 'price' | 'ltv'
export type ChartRange = 'focus' | 'day'

// Series colors are theme tokens (globals.css), each pair validated against its theme's panel with the dataviz checker.
const C = { ltv: 'var(--color-c-ltv)', lt: 'var(--color-c-lt)', price: 'var(--color-c-price)', target: 'var(--color-c-target)', grid: 'var(--color-c-grid)', axis: 'var(--color-c-axis)', now: 'var(--color-c-mark)', panel: 'var(--color-dk-panel)', down: 'var(--color-dk-down)' }

interface Props {
  anchor: Anchor
  steps: StepState[]
  at: number
  obs: Obs[]
  ltPath: { t: number; lt: number }[]
  markers: Marker[]
  /** Collateral (raw) and debt (base units) now; with markers they give the LTV at every observation. */
  collateral: bigint | undefined
  debt: bigint | undefined
  target: number | undefined
  mode: ChartMode
  range?: ChartRange
  height?: number
}

/**
 * The scripted session on one time axis: Friday, a compressed weekend, and the Monday reopening. Observations
 * after the current step are not drawn. Price mode plots the fixed observations; LTV mode plots the borrower's
 * LTV at each observation against the contract's threshold path. Confirmed transactions are marked where they
 * happened on the session clock.
 */
export function SessionChart({ anchor, steps, at, obs, ltPath, markers, collateral, debt, target, mode, range = 'focus', height = 340 }: Props) {
  const { ref, width } = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number>()
  const now = Number(steps[at].t)
  const friStart = Number(anchor.fri.open) + (range === 'focus' ? 180 * 60 : 0)
  const friEnd = Number(anchor.fri.close)
  const monStart = Number(anchor.mon.open)
  const monEnd = monStart + 30 * 60

  const pad = { l: 8, r: 58, t: 18, b: 30 }
  const W = Math.max(320, width)
  const plotW = W - pad.l - pad.r
  const H = height
  const plotH = H - pad.t - pad.b
  const friW = plotW * (range === 'focus' ? 0.68 : 0.76)
  const gapW = plotW * 0.06
  const monW = plotW - friW - gapW

  const x = (t: number) => {
    if (t <= friEnd) return pad.l + ((Math.max(t, friStart) - friStart) / (friEnd - friStart)) * friW
    if (t < monStart) return pad.l + friW + gapW / 2
    return pad.l + friW + gapW + ((Math.min(t, monEnd) - monStart) / (monEnd - monStart)) * monW
  }

  // Debt and collateral as of time t: the state after the last marker at or before t; before the first marker,
  // that marker's "before" state; with no markers, the current position.
  const asOf = useMemo(() => {
    const sorted = [...markers].sort((a, b) => a.t - b.t)
    return (t: number) => {
      const past = sorted.filter(m => m.t <= t).at(-1)
      if (past) return { debt: past.item.debtAfter ?? debt ?? 0n, coll: past.item.collateralAfter }
      const first = sorted[0]
      if (first && first.t > t) return { debt: first.item.debtBefore ?? debt ?? 0n, coll: first.item.collateralBefore }
      return { debt: debt ?? 0n, coll: collateral ?? 0n }
    }
  }, [markers, debt, collateral])

  // A transaction signed during this step lands a few seconds after the step's time on the testnet clock: the
  // step lasts until the next one, so the chart runs to the latest such receipt.
  const nextT = at + 1 < steps.length ? Number(steps[at + 1].t) : monEnd + 1
  const shown = markers.filter(m => m.t >= friStart && m.t < nextT)
  const tail = Math.max(now, ...shown.map(m => m.t))
  const visible = obs.filter(o => o.t >= friStart && o.t <= now)
  const last = visible.at(-1)
  if (last && tail > last.t) visible.push({ t: tail, price: Number(steps[at].quoteWad) / 1e18, day: last.day })
  // Until Monday's admission the gate values collateral at Friday's last accepted price, not the fresh quote.
  const admitT = Number(steps.find(x => x.step.id === 'admit')!.t)
  const lastAccepted = Number(steps.find(x => x.step.id === 'closed')!.valuationWad) / 1e18
  const series = visible.map(o => {
    const p = asOf(o.t)
    const valuation = o.t >= monStart && o.t < admitT ? lastAccepted : o.price
    const value = (Number(p.coll) / 1e18) * valuation
    return { ...o, ltv: value > 0 ? Number(p.debt) / 1e6 / value : undefined, lt: ltAtTime(ltPath, o.t) }
  })

  // Y scale: one measure per mode, never two axes.
  const allPrices = obs.filter(o => o.t >= friStart).map(o => o.price)
  const [lo, hi] = mode === 'price' ? [Math.floor(Math.min(...allPrices) - 2), Math.ceil(Math.max(...allPrices) + 2)] : [0.6, 0.84]
  const y = (v: number) => pad.t + plotH - ((v - lo) / (hi - lo)) * plotH
  const ticks = mode === 'price' ? niceRange(lo, hi, 5) : [0.6, 0.65, 0.7, 0.75, 0.8]

  const path = (pts: { x: number; y: number }[]) => pts.map((p, i) => `${i ? 'L' : 'M'}${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')
  const segment = (day: 'fri' | 'mon', pick: (s: (typeof series)[number]) => number | undefined) =>
    path(series.filter(s => s.day === day && pick(s) !== undefined).map(s => ({ x: x(s.t), y: y(pick(s)!) })))

  // Session bands from the scripted steps' phases.
  const bands: { from: number; to: number; tone: string; label: string }[] = [
    { from: Number(steps.find(s => s.step.id === 'prep')!.snapshot.prepAt), to: Number(steps[0].snapshot.finalAt), tone: 'color-mix(in oklab, var(--color-dk-warn) 8%, transparent)', label: 'Preparation' },
    { from: Number(steps[0].snapshot.finalAt), to: friEnd, tone: 'color-mix(in oklab, var(--color-c-price) 12%, transparent)', label: 'Final' },
    { from: monStart, to: Number(steps.find(s => s.step.id === 'admit')!.snapshot.creditAt), tone: 'color-mix(in oklab, var(--color-dk-muted) 10%, transparent)', label: 'Reopening' },
  ]
  // The threshold schedule is drawn in full (it is known in advance), starting at the left edge of the window.
  const ltVisible = [{ t: friStart, lt: ltAtTime(ltPath, friStart) }, ...ltPath.filter(p => (p.t > friStart && p.t <= friEnd) || (p.t >= monStart && p.t <= monEnd))]

  const hovered = hover !== undefined ? series.reduce((best, s) => (Math.abs(x(s.t) - hover) < Math.abs(x(best.t) - hover) ? s : best), series[0]) : series.at(-1)
  const nowX = x(Math.min(now, now >= monStart ? monEnd : friEnd))
  const xTicks = range === 'focus' ? [13, 14, 15, 16].map(h => friStart + (h - 12.5) * 3600) : [10, 12, 14, 16].map(h => Number(anchor.fri.open) + (h - 9.5) * 3600)

  return (
    <div className="relative">
      <div className="flex flex-wrap items-center gap-x-5 gap-y-1 px-4 pt-3 text-xs text-dk-muted">
        {hovered && (
          <span className="num text-dk-ink">
            {hovered.day === 'mon' ? 'Mon' : 'Fri'} {nyClock(hovered.t)} ET
            <span className="mx-2 text-dk-faint">·</span>
            {mode === 'price' ? (
              <>TSLA {hovered.price.toFixed(2)}</>
            ) : (
              <>
                LTV {pctOf(hovered.ltv)} <span className="mx-1 text-dk-faint">vs</span> threshold {pctOf(hovered.lt)}
              </>
            )}
          </span>
        )}
        <span className="ml-auto flex items-center gap-4" aria-label="Legend">
          {mode === 'price' ? (
            <Legend color={C.price} label="TSLA / USD, scripted observations" />
          ) : (
            <>
              <Legend color={C.ltv} label="Your LTV" />
              <Legend color={C.lt} label="Liquidation threshold (contract)" />
              <Legend color={C.target} dashed label="Closure target" />
            </>
          )}
          <Legend color={C.now} dot label="Confirmed transaction" />
        </span>
      </div>
      <div ref={ref} className="w-full">
        {width > 0 && (
          <svg
            width={W}
            height={H}
            role="img"
            aria-label={mode === 'price' ? 'TSLA price over the scripted session' : 'Loan LTV against the falling liquidation threshold over the scripted session'}
            onMouseMove={e => setHover(e.clientX - e.currentTarget.getBoundingClientRect().left)}
            onMouseLeave={() => setHover(undefined)}
            className="block select-none"
          >
            {bands.map(b => (
              <g key={b.label}>
                <rect x={x(b.from)} y={pad.t} width={Math.max(0, x(b.to) - x(b.from))} height={plotH} fill={b.tone} />
                <text x={x(b.from) + 4} y={pad.t + 11} fontSize="10" fill={C.axis}>
                  {b.label}
                </text>
              </g>
            ))}
            {/* weekend break */}
            <rect x={pad.l + friW} y={pad.t} width={gapW} height={plotH} fill="url(#hatch)" />
            <defs>
              <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
                <line x1="0" y1="0" x2="0" y2="6" stroke={C.grid} strokeWidth="2" />
              </pattern>
            </defs>
            <text x={pad.l + friW + gapW / 2} y={pad.t + plotH / 2} fontSize="10" fill={C.axis} textAnchor="middle" transform={`rotate(-90 ${pad.l + friW + gapW / 2} ${pad.t + plotH / 2})`}>
              Weekend closed
            </text>

            {ticks.map(v => (
              <g key={v}>
                <line x1={pad.l} x2={W - pad.r} y1={y(v)} y2={y(v)} stroke={C.grid} />
                <text x={W - pad.r + 8} y={y(v) + 3.5} fontSize="11" fill={C.axis} className="num">
                  {mode === 'price' ? v.toFixed(0) : `${Math.round(v * 100)}%`}
                </text>
              </g>
            ))}
            {[...xTicks, monStart, monStart + 900].map(t => (
              <text key={t} x={x(t)} y={H - 10} fontSize="11" fill={C.axis} textAnchor="middle" className="num">
                {t >= monStart ? `Mon ${nyClock(t)}` : nyClock(t)}
              </text>
            ))}

            {mode === 'ltv' && (
              <>
                {['fri', 'mon'].map(day => {
                  const pts = ltVisible.filter(p => (day === 'fri' ? p.t <= friEnd : p.t >= monStart))
                  return <path key={day} d={path(pts.map(p => ({ x: x(p.t), y: y(Math.max(lo, Math.min(hi, p.lt))) })))} fill="none" stroke={C.lt} strokeWidth="2" />
                })}
                {target !== undefined && <line x1={pad.l} x2={W - pad.r} y1={y(target)} y2={y(target)} stroke={C.target} strokeDasharray="4 4" strokeWidth="1.5" />}
                <text x={W - pad.r - 4} y={y(ltAtTime(ltPath, friEnd)) - 6} fontSize="11" fill={C.axis} textAnchor="end">
                  Threshold {pctOf(ltAtTime(ltPath, friEnd))} through the weekend
                </text>
                <path d={segment('fri', s => s.ltv)} fill="none" stroke={C.ltv} strokeWidth="2" />
                <path d={segment('mon', s => s.ltv)} fill="none" stroke={C.ltv} strokeWidth="2" />
                {series
                  .filter(s => s.ltv !== undefined && s.ltv > s.lt)
                  .map(s => (
                    <circle key={s.t} cx={x(s.t)} cy={y(Math.min(hi, s.ltv!))} r="2.5" fill={C.down} />
                  ))}
              </>
            )}
            {mode === 'price' && (
              <>
                {(['fri', 'mon'] as const).map(day => {
                  const d = segment(day, s => s.price)
                  const pts = series.filter(s => s.day === day)
                  if (!pts.length) return null
                  return (
                    <g key={day}>
                      <path d={`${d} L${x(pts.at(-1)!.t).toFixed(1)},${pad.t + plotH} L${x(pts[0].t).toFixed(1)},${pad.t + plotH} Z`} fill={C.price} fillOpacity="0.08" />
                      <path d={d} fill="none" stroke={C.price} strokeWidth="2" />
                    </g>
                  )
                })}
              </>
            )}

            {/* Confirmed transactions on the session clock */}
            {shown.map((m, i) => {
                // Transactions within a few minutes share one label: the latest, with a count.
                const later = shown.slice(i + 1).filter(n => n.t - m.t < 600)
                if (later.length) return null
                const group = shown.filter(n => m.t - n.t < 600 && n.t <= m.t).length
                const o = series.reduce((b, s) => (Math.abs(s.t - m.t) < Math.abs(b.t - m.t) ? s : b), series[0])
                const v = mode === 'price' ? o?.price : o?.ltv
                if (v === undefined) return null
                return (
                  <g key={m.item.hash + m.item.logIndex}>
                    <line x1={x(m.t)} x2={x(m.t)} y1={pad.t} y2={pad.t + plotH} stroke={C.now} strokeOpacity="0.25" />
                    <circle cx={x(m.t)} cy={y(Math.max(lo, Math.min(hi, v)))} r="5" fill={C.now} stroke={C.panel} strokeWidth="2" />
                    <text x={x(m.t) + 8} y={y(Math.max(lo, Math.min(hi, v))) - 8} fontSize="11" fill={C.now}>
                      {m.item.kind} {m.item.unit === 'USDG' ? usdg(m.item.amount) : ''}
                      {group > 1 ? ` +${group - 1}` : ''}
                    </text>
                  </g>
                )
              })}

            {/* Now */}
            <line x1={nowX} x2={nowX} y1={pad.t} y2={pad.t + plotH} stroke={C.now} strokeDasharray="2 3" strokeOpacity="0.6" />
            <rect x={nowX - 22} y={pad.t + plotH + 2} width="44" height="14" rx="3" fill={C.now} />
            <text x={nowX} y={pad.t + plotH + 12.5} fontSize="10" fontWeight="600" fill={C.panel} textAnchor="middle" className="num">
              {nyClock(now)}
            </text>
            {hover !== undefined && hovered && <line x1={x(hovered.t)} x2={x(hovered.t)} y1={pad.t} y2={pad.t + plotH} stroke={C.axis} strokeOpacity="0.5" />}
          </svg>
        )}
      </div>
      {steps[at].snapshot.phase === S.REOPEN_WAIT && (
        <p className="px-4 pb-2 text-xs text-dk-warn">The 09:31 quote is fresh but not yet admitted: valuations stay on Friday&apos;s last accepted price until 09:35.</p>
      )}
    </div>
  )
}

function Legend({ color, label, dashed, dot }: { color: string; label: string; dashed?: boolean; dot?: boolean }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      {dot ? (
        <span className="h-2.5 w-2.5 rounded-full border-2 border-dk-panel" style={{ background: color }} />
      ) : (
        <svg width="18" height="6" aria-hidden>
          <line x1="0" x2="18" y1="3" y2="3" stroke={color} strokeWidth="2" strokeDasharray={dashed ? '4 3' : undefined} />
        </svg>
      )}
      {label}
    </span>
  )
}

function niceRange(lo: number, hi: number, n: number) {
  const step = Math.max(1, Math.round((hi - lo) / n))
  const out: number[] = []
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) out.push(v)
  return out
}
