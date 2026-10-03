'use client'

import { nyClock, pctOf, usdg } from '@/lib/format'
import type { HistoryItem, PricePoint } from '@/lib/history'
import type { AccountData, Snapshot } from '@/lib/types'
import { niceTicks, Segmented, Select, useWidth } from './kit'
import { quarterTicks, stepSeries } from './PriceStrip'

export type ChartMode = 'ltv' | 'price'
export type ChartWindow = 'preclose' | 'session'

const MIN_H = 360
const PAD = { l: 52, r: 74, t: 30, b: 50 }
const AMBER = '#f2b84b'
const GREEN = '#3ecf8e'
const INK = '#e8eaed'
const GRID = '#23272d'

const CALLOUT: Partial<Record<HistoryItem['kind'], string>> = {
  'Buffer repaid': 'AUTO-REPAY',
  Trimmed: 'TRIM',
  Repaid: 'REPAY',
  'Repaid from buffer': 'BUFFER REPAY',
  Borrowed: 'BORROW',
  'Written off': 'WRITE-OFF',
}

/** Threshold at t, interpolated between ltAt samples taken at the ramp's corners (it is linear in between). */
function ltAtTime(curve: { t: number; lt: bigint }[], t: number): number | undefined {
  if (!curve.length) return undefined
  const pts = curve.map(p => ({ t: p.t, lt: Number(p.lt) / 1e18 }))
  if (t <= pts[0].t) return pts[0].lt
  for (let i = 1; i < pts.length; i++) {
    if (t <= pts[i].t) {
      const a = pts[i - 1]
      const b = pts[i]
      return b.t === a.t ? b.lt : a.lt + ((b.lt - a.lt) * (t - a.t)) / (b.t - a.t)
    }
  }
  return pts[pts.length - 1].lt
}

export function ExposureChart({
  s,
  v,
  now,
  x0,
  x1,
  curve,
  items,
  prices,
  currentPrice,
  mode,
  onMode,
  win,
  onWin,
}: {
  s: Snapshot
  v: AccountData | undefined
  now: number
  x0: number
  x1: number
  curve: { t: number; lt: bigint }[]
  items: HistoryItem[]
  prices: PricePoint[]
  currentPrice: number
  mode: ChartMode
  onMode: (m: ChartMode) => void
  win: ChartWindow
  onWin: (w: ChartWindow) => void
}) {
  const { ref, width, height } = useWidth<HTMLDivElement>()
  const H = Math.max(MIN_H, height)
  const end = Math.min(Math.max(now, x0), x1)
  const hasDebt = !!v && v.debt > 0n
  const target = v ? Number(v.planTargetWad) / 1e18 : Number(s.targetWad) / 1e18
  const ltvNow = hasDebt ? Number(v!.ltvWad) / 1e18 : undefined
  const debt = v ? Number(v.debt) / 1e6 : 0
  const coll = v ? Number(v.collateral) / 1e18 : 0

  // Samples of the threshold across the window: the window's ends, the ramp's corners and every curve point.
  const lts = [...new Set([x0, Number(s.prepAt), Number(s.finalAt), x1, ...curve.map(p => p.t)])].filter(t => t >= x0 && t <= x1).sort((a, b) => a - b)
  const ltPts = lts.map(t => ({ t, lt: ltAtTime(curve, t) })).filter((p): p is { t: number; lt: number } => p.lt !== undefined)
  const ltClose = ltAtTime(curve, x1)

  // Position history in the window. LTV moves when the debt or collateral changes (events) and when the price
  // changes (demo feed pushes), so both are replayed in time order; the last point is the Lens value now.
  const asc = [...items].reverse()
  const carried = [...asc].reverse().find(i => i.t <= x0)
  const inWindow = asc.filter(i => i.t > x0 && i.t <= end)
  const position: { t: number; v: number }[] = []
  if (hasDebt || inWindow.some(i => i.ltvAfter !== undefined)) {
    let d = carried ? carried.debtAfter : (inWindow[0]?.debtBefore ?? v?.debt)
    let c = carried ? carried.collateralAfter : (inWindow[0]?.collateralBefore ?? v?.collateral)
    let p = [...prices].reverse().find(q => q.t <= x0)?.price ?? currentPrice
    const ltvOf = () => (d === undefined || c === undefined || c === 0n || p <= 0 ? undefined : d === 0n ? 0 : Number(d) / 1e6 / ((Number(c) / 1e18) * p))
    const push = (t: number) => {
      const val = ltvOf()
      if (val === undefined) return
      if (position.length) position.push({ t, v: position[position.length - 1].v })
      position.push({ t, v: val })
    }
    push(x0)
    const changes = [
      ...inWindow.map(e => ({ t: e.t, apply: () => ((d = e.debtAfter ?? d), (c = e.collateralAfter)) })),
      ...prices.filter(q => q.t > x0 && q.t <= end).map(q => ({ t: q.t, apply: () => (p = q.price) })),
    ].sort((a, b) => a.t - b.t)
    for (const ch of changes) {
      ch.apply()
      push(ch.t)
    }
    if (ltvNow !== undefined) {
      if (position.length) position.push({ t: end, v: position[position.length - 1].v })
      position.push({ t: end, v: ltvNow })
    }
  }
  const callouts = inWindow.filter(e => CALLOUT[e.kind] && e.ltvAfter !== undefined)

  // Price mode: prices against the liquidation price debt / (collateral × LT(t)) for today's debt and collateral.
  const priceSeries = stepSeries(prices, x0, end, currentPrice)
  const liqPrice = (lt: number) => (coll > 0 && lt > 0 ? debt / (coll * lt) : undefined)
  const liqPts = hasDebt ? ltPts.map(p => ({ t: p.t, v: liqPrice(p.lt)! })).filter(p => p.v !== undefined) : []
  const targetPrice = hasDebt ? liqPrice(target) : undefined

  // Vertical domain.
  let lo: number
  let hi: number
  let ticks: number[]
  if (mode === 'ltv') {
    const vals = [target, ...ltPts.map(p => p.lt), ...position.map(p => p.v).filter(x => x < 1.5)].map(x => x * 100)
    lo = Math.floor((Math.min(...vals) - 2.5) / 5) * 5
    hi = Math.ceil((Math.max(...vals) + 2.5) / 5) * 5
    ticks = niceTicks(lo, hi, Math.min(6, (hi - lo) / 5))
  } else {
    const vals = [...priceSeries.map(p => p.price), ...liqPts.map(p => p.v), ...(targetPrice ? [targetPrice] : [])].filter(x => x > 0)
    const a = vals.length ? Math.min(...vals) : currentPrice * 0.9
    const b = vals.length ? Math.max(...vals) : currentPrice * 1.1
    const pad = Math.max((b - a) * 0.12, currentPrice * 0.01)
    ticks = niceTicks(a - pad, b + pad, 5)
    lo = Math.min(a - pad, ticks[0])
    hi = Math.max(b + pad, ticks[ticks.length - 1])
  }

  if (!(hi > lo)) {
    lo -= 1
    hi += 1
  }
  const w = Math.max(0, width - PAD.l - PAD.r)
  const ih = H - PAD.t - PAD.b
  const x = (t: number) => PAD.l + ((t - x0) / (x1 - x0)) * w
  const yv = (val: number) => PAD.t + (1 - (val - lo) / (hi - lo)) * ih
  const y = (f: number) => yv(mode === 'ltv' ? f * 100 : f)
  const path = (pts: { t: number; v: number }[]) => pts.map((p, i) => `${i ? 'L' : 'M'}${x(p.t).toFixed(1)},${y(p.v).toFixed(1)}`).join('')

  const thresholdLine = mode === 'ltv' ? ltPts.map(p => ({ t: p.t, v: p.lt })) : liqPts
  const solid = thresholdLine.filter(p => p.t <= end)
  const nowLt = ltAtTime(curve, end)
  const nowThreshold = mode === 'ltv' ? nowLt : nowLt !== undefined ? liqPrice(nowLt) : undefined
  if (nowThreshold !== undefined && solid.length && solid[solid.length - 1].t < end) solid.push({ t: end, v: nowThreshold })
  const dashed = nowThreshold !== undefined ? [{ t: end, v: nowThreshold }, ...thresholdLine.filter(p => p.t > end)] : []
  // Liquidation-eligible area: above the threshold in LTV terms, below the liquidation price in price terms.
  const edge = mode === 'ltv' ? PAD.t : PAD.t + ih
  const area = thresholdLine.length ? `${path(thresholdLine)}L${x(thresholdLine[thresholdLine.length - 1].t)},${edge}L${x(thresholdLine[0].t)},${edge}Z` : ''
  const targetVal = mode === 'ltv' ? target : targetPrice
  const closeTag = mode === 'ltv' ? ltClose : ltClose !== undefined ? liqPrice(ltClose) : undefined
  const fmt = (val: number) => (mode === 'ltv' ? pctOf(val) : val.toFixed(2))
  const showNow = now >= x0 && now <= x1
  const marks = [
    { t: Number(s.open), label: 'Open' },
    { t: Number(s.prepAt), label: 'Ramp' },
    { t: Number(s.finalAt), label: 'Borrow lock' },
    { t: Number(s.close), label: 'Close' },
  ]
    .filter(mk => mk.t >= x0 && mk.t <= x1)
    // Drop a label that would collide with the next one; the close always stays.
    .filter((mk, i, all) => i === all.length - 1 || ((all[i + 1].t - mk.t) / (x1 - x0)) * w > 130)

  return (
    <section className="flex flex-1 flex-col border-b border-dk-line">
      <div className="flex flex-wrap items-center gap-4 px-5 pt-3">
        <h2 className="text-xl font-semibold">Exposure</h2>
        <Segmented
          options={[
            { key: 'ltv', label: 'LTV' },
            { key: 'price', label: 'Price' },
          ]}
          value={mode}
          onChange={onMode}
        />
        <span className="h-6 w-px bg-dk-line" />
        <Select
          value={win}
          onChange={onWin}
          options={[
            { key: 'preclose', label: 'Session' },
            { key: 'session', label: 'Full day' },
          ]}
        />
        <div className="ml-auto flex flex-wrap items-center gap-x-5 gap-y-1 text-sm text-dk-muted">
          <Legend stroke={INK}>{mode === 'ltv' ? 'Position' : 'Price'}</Legend>
          <Legend stroke={AMBER}>{mode === 'ltv' ? 'Liquidation' : 'Liquidation price'}</Legend>
          <Legend stroke={INK} dashed>
            {mode === 'ltv' ? 'Target' : 'Target price'}
          </Legend>
        </div>
      </div>

      <div ref={ref} className="relative mt-1 min-h-[360px] flex-1">
        {width > 0 && (
          <svg width={width} height={H} className="absolute inset-0 block">
            <defs>
              <clipPath id="plot">
                <rect x={PAD.l} y={PAD.t} width={w} height={ih} />
              </clipPath>
            </defs>
            <rect x={PAD.l} y={PAD.t} width={w} height={ih} fill="#15181c" />
            {ticks.map(tk => (
              <g key={tk}>
                <line x1={PAD.l} x2={PAD.l + w} y1={yv(tk)} y2={yv(tk)} stroke={GRID} />
                <text x={PAD.l - 10} y={yv(tk) + 4} textAnchor="end" className="num fill-dk-muted text-[12px]">
                  {mode === 'ltv' ? `${tk}%` : tk.toFixed(tk < 100 ? 2 : 0)}
                </text>
              </g>
            ))}
            {quarterTicks(x0, x1).map(t => (
              <g key={t}>
                <line x1={x(t)} x2={x(t)} y1={PAD.t} y2={PAD.t + ih} stroke={GRID} />
                <text x={x(t)} y={PAD.t + ih + 18} textAnchor="middle" className="num fill-dk-muted text-[12px]">
                  {nyClock(t)}
                </text>
              </g>
            ))}
            <line x1={PAD.l} x2={PAD.l} y1={PAD.t} y2={PAD.t + ih} stroke="#3a3f46" />
            <line x1={PAD.l} x2={PAD.l + w} y1={PAD.t + ih} y2={PAD.t + ih} stroke="#3a3f46" />
            {marks.map((mk, i) => (
              <text
                key={mk.label}
                x={x(mk.t)}
                y={PAD.t + ih + 36}
                textAnchor={i === 0 && mk.t === x0 ? 'start' : mk.t === x1 ? 'end' : 'middle'}
                className="num fill-dk-muted text-[11px]"
              >
                {nyClock(mk.t)} {mk.label}
              </text>
            ))}

            <g clipPath="url(#plot)">
              {area && <path d={area} fill={AMBER} fillOpacity="0.09" />}
              {targetVal !== undefined && <line x1={PAD.l} x2={PAD.l + w} y1={y(targetVal)} y2={y(targetVal)} stroke={INK} strokeOpacity="0.55" strokeDasharray="6 5" />}
              {solid.length > 1 && <path d={path(solid)} fill="none" stroke={AMBER} strokeWidth="2" />}
              {dashed.length > 1 && <path d={path(dashed)} fill="none" stroke={AMBER} strokeWidth="2" strokeDasharray="6 5" />}
              {mode === 'ltv' && position.length > 1 && <path d={path(position)} fill="none" stroke={INK} strokeWidth="2.5" />}
              {mode === 'price' && priceSeries.length > 1 && <path d={path(priceSeries.map(p => ({ t: p.t, v: p.price })))} fill="none" stroke={INK} strokeWidth="2" />}
              {mode === 'ltv' && ltvNow !== undefined && showNow && <line x1={x(end)} x2={x(x1)} y1={y(ltvNow)} y2={y(ltvNow)} stroke={INK} strokeOpacity="0.6" strokeWidth="2" strokeDasharray="7 6" />}
              {mode === 'price' && currentPrice > 0 && showNow && <line x1={x(end)} x2={x(x1)} y1={y(currentPrice)} y2={y(currentPrice)} stroke={INK} strokeOpacity="0.6" strokeWidth="2" strokeDasharray="7 6" />}
            </g>

            {area && (
              <text x={PAD.l + w - 10} y={mode === 'ltv' ? PAD.t + 22 : PAD.t + ih - 24} textAnchor="end" fill={AMBER} fillOpacity="0.85" className="text-[12px]">
                <tspan x={PAD.l + w - 10}>Liquidation</tspan>
                <tspan x={PAD.l + w - 10} dy="15">
                  eligible area
                </tspan>
              </text>
            )}
            {showNow && (mode === 'ltv' ? ltvNow : currentPrice) !== undefined && (
              <text x={(x(end) + x(x1)) / 2} y={y(mode === 'ltv' ? ltvNow! : currentPrice) - 9} textAnchor="middle" className="fill-dk-muted text-[12px]">
                Projected
              </text>
            )}

            {showNow && (
              <g>
                <line x1={x(now)} x2={x(now)} y1={PAD.t - 6} y2={PAD.t + ih} stroke={INK} strokeOpacity="0.6" strokeDasharray="3 4" />
                <text x={x(now)} y={PAD.t - 18} textAnchor="middle" className="num fill-dk-muted text-[11px]">
                  {nyClock(now)} ET
                </text>
                <text x={x(now)} y={PAD.t - 6} textAnchor="middle" className="fill-dk-ink text-[11px]">
                  NOW
                </text>
              </g>
            )}

            {mode === 'ltv' &&
              placeCallouts(callouts.map(e => ({ e, cx: x(e.t), cy: y(e.ltvAfter!) })), PAD.l + w, PAD.t, PAD.t + ih).map(({ e, cx, cy, bx, by, bw, left }) => (
                <g key={e.hash + e.kind}>
                  <line x1={cx} y1={cy} x2={left ? bx + bw : bx} y2={by + 22} stroke={GREEN} strokeOpacity="0.7" />
                  <circle cx={cx} cy={cy} r="5" fill={GREEN} />
                  <rect x={bx} y={by} width={bw} height={44} rx="3" fill="#0f1114" stroke={GREEN} strokeOpacity="0.8" />
                  <text x={bx + 10} y={by + 18} className="num fill-dk-up text-[12px] font-semibold">
                    {CALLOUT[e.kind]} {usdg(e.amount, 0)} USDG
                  </text>
                  <text x={bx + 10} y={by + 35} className="num fill-dk-ink text-[12px]">
                    {pctOf(e.ltvBefore)} → {pctOf(e.ltvAfter)}
                  </text>
                </g>
              ))}

            {closeTag !== undefined && <Tag x={PAD.l + w + 6} y={y(closeTag)} fill={AMBER} text={fmt(closeTag)} />}
            {targetVal !== undefined && <Tag x={PAD.l + w + 6} y={y(targetVal)} fill={GREEN} text={fmt(targetVal)} />}

            {!hasDebt && (
              <text x={PAD.l + w / 2} y={PAD.t + ih / 2} textAnchor="middle" className="fill-dk-faint text-[13px]">
                {v ? 'No open position' : 'Connect a wallet or pick a scenario to see a position'}
              </text>
            )}
            {!s.covered && (
              <text x={PAD.l + w / 2} y={PAD.t + ih / 2 + 20} textAnchor="middle" className="fill-dk-down text-[13px]">
                Outside the loaded calendar: no session schedule
              </text>
            )}
          </svg>
        )}
      </div>
      <p className="px-5 pb-2 text-xs text-dk-faint">
        Forecast: flat price, accrued interest excluded.
        {mode === 'ltv' ? ' History: on-chain events valued at the demo feed price of the moment.' : ' Liquidation price uses today’s debt and collateral.'}
      </p>
    </section>
  )
}

function Legend({ stroke, dashed, children }: { stroke: string; dashed?: boolean; children: string }) {
  return (
    <span className="flex items-center gap-2">
      <svg width="28" height="6">
        <line x1="0" x2="28" y1="3" y2="3" stroke={stroke} strokeWidth="2" strokeDasharray={dashed ? '5 4' : undefined} />
      </svg>
      {children}
    </span>
  )
}

function Tag({ x, y, fill, text }: { x: number; y: number; fill: string; text: string }) {
  return (
    <g>
      <rect x={x} y={y - 11} width="60" height="22" rx="2" fill={fill} fillOpacity="0.2" stroke={fill} />
      <text x={x + 30} y={y + 4} textAnchor="middle" fill={fill} className="num text-[12px] font-semibold">
        {text}
      </text>
    </g>
  )
}

/** Puts each callout box above and to the right of its point, moving it until it overlaps no earlier box. */
function placeCallouts<T>(points: { e: T; cx: number; cy: number }[], right: number, top: number, bottom: number) {
  const bw = 168
  const bh = 44
  const placed: { e: T; cx: number; cy: number; bx: number; by: number; bw: number; left: boolean }[] = []
  for (const p of points) {
    const left = p.cx + 30 + bw > right
    const bx = left ? p.cx - 30 - bw : p.cx + 30
    let by = p.cy - 62
    const hits = (y: number) => placed.some(q => Math.abs(q.bx - bx) < bw && Math.abs(q.by - y) < bh + 6)
    while (hits(by) && by > top) by -= bh + 8
    if (by < top) {
      by = p.cy + 20
      while (hits(by) && by + bh < bottom) by += bh + 8
    }
    placed.push({ ...p, bx, by, bw, left })
  }
  return placed
}
