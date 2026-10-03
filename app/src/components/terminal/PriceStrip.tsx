'use client'

import { nyClock, price as fmtPrice } from '@/lib/format'
import type { PricePoint } from '@/lib/history'
import { niceTicks, useWidth } from './kit'

/** Time ticks between two protocol times: quarter hours for the pre-close window, hours for a whole day. New York
 * offsets are whole hours, so UTC quarters and hours align with New York ones. */
export function quarterTicks(x0: number, x1: number): number[] {
  const step = x1 - x0 > 4 * 3600 ? 3600 : x1 - x0 > 2.5 * 3600 ? 1800 : 900
  const out: number[] = []
  for (let t = Math.ceil(x0 / step) * step; t <= x1; t += step) out.push(t)
  return out
}

/** The demo feed's prices as a held step line, from the last price before the window to now. */
export function stepSeries(prices: PricePoint[], x0: number, end: number, current: number | undefined): PricePoint[] {
  const carry = [...prices].reverse().find(p => p.t <= x0)
  const inside = prices.filter(p => p.t > x0 && p.t <= end)
  const pts: PricePoint[] = []
  if (carry) pts.push({ t: x0, price: carry.price })
  else if (inside[0]) pts.push({ t: Math.max(x0, inside[0].t), price: inside[0].price })
  for (const p of inside) {
    if (pts.length) pts.push({ t: p.t, price: pts[pts.length - 1].price })
    pts.push(p)
  }
  if (current !== undefined && current > 0) {
    if (pts.length) pts.push({ t: end, price: pts[pts.length - 1].price })
    pts.push({ t: end, price: current })
  }
  return pts
}

const H = 128
const PAD = { l: 24, r: 64, t: 30, b: 26 }

export function PriceStrip({ prices, current, x0, x1, now, priceWad, indicative }: { prices: PricePoint[]; current: number; x0: number; x1: number; now: number; priceWad: bigint; indicative: boolean }) {
  const { ref, width } = useWidth<HTMLDivElement>()
  const end = Math.min(Math.max(now, x0), x1)
  const series = stepSeries(prices, x0, end, current)
  const values = series.map(p => p.price)
  const lo0 = values.length ? Math.min(...values) : current * 0.99
  const hi0 = values.length ? Math.max(...values) : current * 1.01
  const pad = Math.max((hi0 - lo0) * 0.15, current * 0.004)
  const ticks = niceTicks(lo0 - pad, hi0 + pad, 4)
  let lo = Math.min(lo0 - pad, ticks[0])
  let hi = Math.max(hi0 + pad, ticks[ticks.length - 1])
  // No price yet (or one flat value at zero): give the axis some height instead of dividing by zero.
  if (!(hi > lo)) {
    lo -= 1
    hi += 1
  }
  const w = Math.max(0, width - PAD.l - PAD.r)
  const x = (t: number) => PAD.l + ((t - x0) / (x1 - x0)) * w
  const y = (p: number) => PAD.t + (1 - (p - lo) / (hi - lo)) * (H - PAD.t - PAD.b)
  const line = series.map((p, i) => `${i ? 'L' : 'M'}${x(p.t).toFixed(1)},${y(p.price).toFixed(1)}`).join('')
  const area = series.length ? `${line}L${x(series[series.length - 1].t)},${H - PAD.b}L${x(series[0].t)},${H - PAD.b}Z` : ''
  const showNow = now >= x0 && now <= x1

  return (
    <div className="border-b border-dk-line px-5 pt-3">
      <div className="text-lg font-semibold">
        TSLA <span className="text-dk-muted">·</span> <span className="num">{fmtPrice(priceWad)} USDG</span>
        {indicative && <span className="ml-2 text-sm font-normal text-dk-warn">last accepted, indicative</span>}
      </div>
      <div ref={ref} className="relative">
        {width > 0 && (
          <svg width={width} height={H} className="block">
            <defs>
              <linearGradient id="price-fill" x1="0" x2="0" y1="0" y2="1">
                <stop offset="0" stopColor="#e8eaed" stopOpacity="0.22" />
                <stop offset="1" stopColor="#e8eaed" stopOpacity="0.02" />
              </linearGradient>
            </defs>
            <line x1={PAD.l} x2={width - PAD.r} y1={H - PAD.b} y2={H - PAD.b} stroke="#3a3f46" />
            <line x1={width - PAD.r + 8} x2={width - PAD.r + 8} y1={PAD.t - 6} y2={H - PAD.b} stroke="#3a3f46" />
            {series.length > 0 &&
              ticks.map(v => (
              <g key={v}>
                <line x1={width - PAD.r + 8} x2={width - PAD.r + 12} y1={y(v)} y2={y(v)} stroke="#3a3f46" />
                <text x={width - PAD.r + 16} y={y(v) + 4} className="num fill-dk-muted text-[11px]">
                  {v.toFixed(v < 100 ? 2 : 0)}
                </text>
              </g>
              ))}
            {quarterTicks(x0, x1).map(t => (
              <text key={t} x={x(t)} y={H - 6} textAnchor="middle" className="num fill-dk-muted text-[11px]">
                {nyClock(t)}
              </text>
            ))}
            {area && <path d={area} fill="url(#price-fill)" />}
            {line && <path d={line} fill="none" stroke="#e8eaed" strokeWidth="1.4" />}
            {showNow && (
              <g>
                <line x1={x(now)} x2={x(now)} y1={PAD.t - 4} y2={H - PAD.b} stroke="#e8eaed" strokeDasharray="3 3" strokeOpacity="0.7" />
                <text x={x(now)} y={PAD.t - 8} textAnchor="middle" className="num fill-dk-muted text-[11px]">
                  {nyClock(now)} ET
                </text>
                {current > 0 && <circle cx={x(now)} cy={y(current)} r="3.5" fill="#e8eaed" />}
              </g>
            )}
            {series.length === 0 && (
              <text x={PAD.l + w / 2} y={H / 2} textAnchor="middle" className="fill-dk-faint text-xs">
                No price history in this window
              </text>
            )}
          </svg>
        )}
      </div>
    </div>
  )
}
