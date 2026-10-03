import { pct, usdg } from '@/lib/format'
import { abovePlan } from '@/lib/policy'
import type { AccountData, Snapshot } from '@/lib/types'

/** LTV, liquidation threshold now, headroom between them, and debt including interest. */
export function Kpis({ v, s }: { v: AccountData | undefined; s: Snapshot }) {
  const hasDebt = !!v && v.debt > 0n
  const headroom = hasDebt ? (Number(s.ltWad) - Number(v!.ltvWad)) / 1e16 : undefined
  const ltvTone = !hasDebt ? '' : v!.ltvWad > s.ltWad ? 'text-dk-down' : abovePlan(v!.repayToTarget) ? 'text-dk-warn' : 'text-dk-up'
  return (
    <div className="grid grid-cols-2 border-b border-dk-line md:grid-cols-4">
      <Kpi label="LTV" value={hasDebt ? pct(v!.ltvWad, 1) : '—'} tone={ltvTone} sub={v?.valuationIndicative && hasDebt ? 'at the last accepted price' : undefined} />
      <Kpi label="Threshold" value={pct(s.ltWad, 1)} tone="text-dk-warn" />
      <Kpi label="Headroom" value={headroom === undefined ? '—' : `${headroom.toFixed(1)} pp`} tone={headroom !== undefined && headroom < 0 ? 'text-dk-down' : ''} />
      <Kpi label="Debt" value={v ? `${usdg(v.debt, 0)} USDG` : '—'} sub={v && v.debt > 0n ? 'including interest' : undefined} />
    </div>
  )
}

function Kpi({ label, value, tone = '', sub }: { label: string; value: string; tone?: string; sub?: string }) {
  return (
    <div className="border-dk-line px-5 py-3 not-first:md:border-l">
      <div className="text-[15px] text-dk-muted">{label}</div>
      <div className={`num mt-0.5 text-[28px] leading-tight font-semibold ${tone}`}>{value}</div>
      {sub && <div className="text-xs text-dk-faint">{sub}</div>}
    </div>
  )
}
