'use client'

import { useState, type ReactNode } from 'react'
import type { HistoryItem } from '@/lib/history'
import { duration, nyClock, pct, tokens, usdg } from '@/lib/format'
import { ltAtTime } from '@/lib/desk'
import { bookAtPrice, exceeds, ltvUp, nextCloseLt, S, usd, valueOfRaw, type Book, type Policy, type Position, type StepState } from '@/lib/scenario'
import { Info, Meter, Status, TxRef, type Tone, toneText } from './ui'

/**
 * The seven StockReef controls as compact panels: a one-line header (name, explanation pop-up, status), then two to
 * four figures with one short line each. Every figure is the contracts' answer at the current scenario step. The
 * terminal opens them from its tiles; the portfolio lays them out as a dashboard.
 */

const f = (w: bigint) => Number(w) / 1e18

export function Feature({ name, status, tone, info, children, className = '' }: { name: string; status: ReactNode; tone: Tone; info: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`rounded-lg border border-dk-line bg-dk-panel ${className}`}>
      <header className="flex items-center gap-2 px-3.5 pt-3">
        <h3 className="text-[11px] font-semibold tracking-[.12em] text-accent uppercase">{name}</h3>
        <Info label={`About ${name.toLowerCase()}`}>{info}</Info>
        <span className="ml-auto">
          <Status tone={tone}>{status}</Status>
        </span>
      </header>
      <div className="px-3.5 pt-2.5 pb-3.5">{children}</div>
    </section>
  )
}

/** A figure: small label, bold value, optional one short line. */
export function Fig({ k, v, sub, tone = 'ink' }: { k: ReactNode; v: ReactNode; sub?: ReactNode; tone?: Tone }) {
  return (
    <div className="min-w-0">
      <div className="text-[11px] text-dk-muted">{k}</div>
      <div className={`num mt-0.5 truncate text-[17px] leading-tight font-semibold ${toneText[tone]}`}>{v}</div>
      {sub && <div className="num mt-0.5 truncate text-[11px] text-dk-faint">{sub}</div>}
    </div>
  )
}

const Grid = ({ children, cols = 3 }: { children: ReactNode; cols?: 2 | 3 | 4 }) => <div className={`grid gap-3 ${cols === 4 ? 'grid-cols-2 sm:grid-cols-4' : cols === 3 ? 'grid-cols-3' : 'grid-cols-2'}`}>{children}</div>

// ------------------------------------------------------------------ 1. Debt reduction before closure

export function DebtReduction({ p, cur }: { p: Position; cur: StepState }) {
  const s = cur.snapshot
  const beforeClose = s.phase <= S.FINAL_WINDOW
  const deadline = s.phase === S.FINAL_WINDOW ? s.close : s.finalAt
  const need = p.repayToTarget >= 10_000n
  return (
    <Feature
      name="Before the close"
      tone={!need ? 'up' : p.trimNow.eligible ? 'down' : 'warn'}
      status={!beforeClose ? (p.missed ? 'Missed' : 'Closed on plan') : need ? 'Action needed' : 'On plan'}
      info={
        <>
          Reach the {pct(p.planTargetWad, 0)} weekend target before {nyClock(s.finalAt)} ET by repaying or adding TSLA. Debt from StockReefMarket.debtAt at the scenario time; value from
          PriceGate.valueOf. Repaying pays no bonus; adding TSLA keeps your stock.
          {p.trimAtFinal.eligible && beforeClose && <> If nothing executes, a liquidator may repay {usdg(p.trimAtFinal.repaid)} USDG from {nyClock(s.finalAt)}.</>}
        </>
      }
    >
      <Grid>
        <Fig k="Deadline" v={beforeClose ? `${nyClock(deadline)} ET` : '—'} sub={beforeClose ? (deadline > cur.t ? `in ${duration(Number(deadline - cur.t))}` : 'passed') : 'market closed'} tone={beforeClose && deadline - cur.t < 1800n ? 'warn' : 'ink'} />
        <Fig k="Repay" v={need ? `${usdg(p.repayToTarget)}` : '0.00'} sub={`USDG to ${pct(p.planTargetWad, 0)}`} tone={need ? 'warn' : 'up'} />
        <Fig k="Or add" v={need ? tokens(p.addRawToTarget, 4) : '0'} sub="TSLA collateral" />
      </Grid>
    </Feature>
  )
}

// ------------------------------------------------------------------ 2. Falling threshold

export function FallingThreshold({ p, cur, pol, ltPath, steps }: { p: Position; cur: StepState; pol: Policy; ltPath: { t: number; lt: number }[]; steps: StepState[] }) {
  const s = cur.snapshot
  const atClose = nextCloseLt(cur, pol)
  const ltv = f(p.ltvWad)
  const above = exceeds(p.debt, p.value, s.ltWad)
  const fri = steps[0].snapshot
  const W = 300
  const H = 64
  const t0 = Number(fri.prepAt) - 3600
  const t1 = Number(fri.close)
  const X = (t: number) => ((t - t0) / (t1 - t0)) * W
  const Y = (v: number) => H - ((v - 0.6) / 0.24) * H
  const pts = [{ t: t0, lt: ltAtTime(ltPath, t0) }, ...ltPath.filter(q => q.t > t0 && q.t <= t1)]
  const nowT = Math.min(Number(cur.t), t1)
  return (
    <Feature
      name="Falling threshold"
      tone={above ? 'down' : 'up'}
      status={above ? 'Above threshold' : 'Below threshold'}
      info={<>From 2 hours before the close the liquidation threshold falls from {pct(pol.ltOpen, 0)} to {pct(atClose, 0)} by 30 minutes before it (SessionRiskPolicy.ltAt). The borrow limit falls with it.</>}
    >
      <Grid>
        <Fig k="Threshold now" v={pct(s.ltWad, 2)} tone="warn" />
        <Fig k="At the close" v={pct(atClose, 0)} sub={atClose === pol.ltFinalExtended ? 'weekend' : 'overnight'} />
        <Fig k="Your LTV" v={p.debt ? pct(p.ltvWad, 2) : '—'} tone={above ? 'down' : ltv > f(atClose) ? 'warn' : 'up'} />
      </Grid>
      <svg viewBox={`0 0 ${W} ${H + 12}`} className="mt-3 h-[76px] w-full" role="img" aria-label="Threshold schedule against your LTV">
        <path d={pts.map((q, i) => `${i ? 'L' : 'M'}${X(q.t).toFixed(1)},${Y(q.lt).toFixed(1)}`).join(' ')} fill="none" stroke="var(--color-c-lt)" strokeWidth="2" />
        <line x1="0" x2={W} y1={Y(ltv)} y2={Y(ltv)} stroke="var(--color-c-ltv)" strokeWidth="2" />
        <circle cx={X(nowT)} cy={Y(ltAtTime(ltPath, nowT))} r="3.5" fill="var(--color-c-mark)" />
        {(
          [
            [t0, nyClock(t0), 'start'],
            [Number(fri.finalAt), nyClock(fri.finalAt), 'middle'],
            [t1, 'close', 'end'],
          ] as const
        ).map(([t, l, a]) => (
          <text key={l} x={X(t)} y={H + 11} fontSize="9" fill="var(--color-c-axis)" textAnchor={a}>
            {l}
          </text>
        ))}
      </svg>
    </Feature>
  )
}

// ------------------------------------------------------------------ 3. Funded repayment buffer

export function FundedBuffer({ p, cur, items, action }: { p: Position; cur: StepState; items: HistoryItem[]; action?: ReactNode }) {
  const plan = p.plan
  const active = plan.targetWad > 0n && plan.expiry > cur.t
  const expired = plan.targetWad > 0n && plan.expiry <= cur.t
  const repaid = items.filter(i => i.kind === 'Buffer repaid')
  const status: [Tone, string] = p.bufferNow > 0n ? ['warn', 'Ready to run'] : active && p.bufferNext > 0n ? ['up', 'Armed'] : expired ? ['down', 'Expired'] : active ? ['muted', 'Idle'] : ['muted', 'Not authorized']
  return (
    <Feature
      name="Funded buffer"
      tone={status[0]}
      status={status[1]}
      info={
        <>
          Your own USDG in a separate escrow repays debt during preparation and recovery, before any trim, with no stock sold and no bonus. Anyone may execute it within its target and
          per-session cap. Amounts from RepaymentEscrow.executableAmount.
          {expired && <> The authorization ended before this session: re-authorize it in Buffer → Authorize while the market is open.</>}
        </>
      }
    >
      <Grid cols={4}>
        <Fig k="Funded" v={usdg(plan.balance)} sub="USDG escrow" />
        <Fig k="Plan" v={plan.targetWad > 0n ? pct(plan.targetWad, 0) : '—'} sub={plan.targetWad > 0n ? `cap ${usdg(plan.perSessionCap)}` : 'not set'} tone={expired ? 'down' : 'ink'} />
        <Fig k={p.bufferNow > 0n ? 'Runs now' : 'Runs next'} v={usdg(p.bufferNow > 0n ? p.bufferNow : p.bufferNext)} sub={p.bufferNow > 0n ? 'executable' : p.bufferNextAt ? `at ${p.bufferNextAt}` : '—'} tone={p.bufferNow > 0n ? 'warn' : 'ink'} />
        <Fig k="Repaid" v={repaid.length ? usdg(repaid.reduce((a, r) => a + r.amount, 0n)) : '—'} sub={repaid[0] ? <TxRef hash={repaid[0].hash}>receipt</TxRef> : 'no receipt yet'} tone={repaid.length ? 'up' : 'ink'} />
      </Grid>
      {action}
    </Feature>
  )
}

// ------------------------------------------------------------------ 4. Partial liquidation

export function PartialLiquidation({ p, cur, action }: { p: Position; cur: StepState; action?: ReactNode }) {
  const q = p.trimNow.eligible ? p.trimNow : p.trimAtFinal
  const now = p.trimNow.eligible
  const afterDebt = q.debt - q.repaid
  const afterColl = p.collateral - q.collateralOut
  const afterLtv = ltvUp(afterDebt, valueOfRaw(afterColl, cur.valuationWad))
  const beforeClose = cur.snapshot.phase <= S.FINAL_WINDOW
  return (
    <Feature
      name="Partial liquidation"
      tone={now ? (q.bufferPending ? 'warn' : 'down') : q.eligible && beforeClose ? 'warn' : 'up'}
      status={now ? (q.bufferPending ? 'Buffer first' : 'Eligible') : q.eligible && beforeClose ? `From ${nyClock(cur.snapshot.finalAt)}` : 'Not eligible'}
      info={
        <>
          Only a loan strictly above the threshold can be trimmed. A liquidator repays part of the debt and takes TSLA at the accepted price plus a bonus: 2% for a scheduling trim, 5% in distress
          or recovery. A full fill reaches the target; the rest of the position stays open. From StockReefMarket.quoteTrim.
        </>
      }
    >
      {q.eligible && (now || beforeClose) ? (
        <Grid cols={4}>
          <Fig k="Debt cut" v={usdg(q.repaid)} sub="USDG" />
          <Fig k="TSLA taken" v={tokens(q.collateralOut, 4)} sub={`${usdg(valueOfRaw(q.collateralOut, cur.valuationWad))} USDG`} />
          <Fig k="Bonus" v={pct(q.bonusWad, 0)} />
          <Fig k="LTV after" v={pct(afterLtv, 1)} tone="up" />
        </Grid>
      ) : (
        <Grid cols={2}>
          <Fig k="Your LTV" v={p.debt ? pct(p.ltvWad, 2) : '—'} tone={exceeds(p.debt, p.value, cur.snapshot.ltWad) ? 'down' : 'up'} />
          <Fig k="Threshold" v={pct(cur.snapshot.ltWad, 2)} tone="warn" />
        </Grid>
      )}
      {action}
    </Feature>
  )
}

// ------------------------------------------------------------------ 5. Closed-session protection

export function ClosedProtection({ cur }: { cur: StepState }) {
  const s = cur.snapshot
  const items: [string, boolean][] = [
    ['Repay', true],
    ['Add TSLA', true],
    ['Borrow', s.canBorrow],
    ['Withdraw', s.canBorrow],
    ['Buffer', s.canBuffer],
    ['Trim', s.canTrim],
    ['Lend', s.lenderOpen],
  ]
  return (
    <Feature
      name="Protection"
      tone={s.canBorrow ? 'up' : 'muted'}
      status={s.canBorrow ? `Borrow to ${pct(s.borrowLimitWad, 1)}` : s.phase === S.REOPEN_RECOVERY ? `Credit ${nyClock(s.creditAt)}` : 'Credit locked'}
      info={<>New borrowing stops 30 minutes before the close and stays off until the reopening recovery ends. Withdrawals against debt need borrowing open. Repaying and adding collateral work in every state. Permissions from the session snapshot.</>}
    >
      <div className="flex flex-wrap gap-1.5">
        {items.map(([k, on]) => (
          <span key={k} className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 text-xs ${on ? 'border-dk-up/40 bg-dk-up/10 text-dk-up' : 'border-dk-line text-dk-faint'}`}>
            {on ? (
              <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
                <path d="M3 8.5l3 3 7-7" />
              </svg>
            ) : (
              <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden>
                <rect x="3.5" y="7" width="9" height="6.5" rx="1" />
                <path d="M5.5 7V5a2.5 2.5 0 015 0v2" />
              </svg>
            )}
            {k}
            <span className="sr-only">{on ? 'available' : 'locked'}</span>
          </span>
        ))}
      </div>
    </Feature>
  )
}

// ------------------------------------------------------------------ 6. Controlled reopening

export function ControlledReopening({ cur, steps }: { cur: StepState; steps: StepState[] }) {
  const monOpen = steps.find(x => x.step.day === 'mon')!.snapshot.open
  const creditAt = steps.find(x => x.step.id === 'admit')!.snapshot.creditAt
  const reached = cur.t >= monOpen
  const s = cur.snapshot
  const admitted = reached && s.admissionAt > 0n
  const progress = admitted ? Math.min(1, Number(cur.t - s.admissionAt) / Number(creditAt - s.admissionAt)) : 0
  return (
    <Feature
      name="Reopening"
      tone={!reached ? 'muted' : !admitted ? 'warn' : cur.t >= creditAt ? 'up' : 'brand'}
      status={!reached ? 'Monday' : !admitted ? 'Awaiting price' : cur.t >= creditAt ? 'Credit open' : 'Recovering'}
      info={
        <>
          A fresh quote must be stamped at least 1 minute after the open and is admitted no earlier than 5 minutes after it. Buffers, then recovery trims, run; credit returns at the later of open + 15
          minutes and admission + 10. Without a price by open + 30 minutes the market is guarded.
        </>
      }
    >
      <Grid>
        <Fig k="Fresh quote" v={reached ? (Number(cur.quoteWad) / 1e18).toFixed(2) : '—'} sub={reached ? 'TSLA / USD' : 'after the open'} />
        <Fig k="Admitted" v={admitted ? nyClock(s.admissionAt) : `≥ ${nyClock(monOpen + 300n)}`} tone={admitted ? 'up' : 'ink'} />
        <Fig k="Credit returns" v={nyClock(creditAt)} />
      </Grid>
      <div className="mt-3 h-1.5 rounded-full bg-dk-raised" role="progressbar" aria-valuenow={Math.round(progress * 100)} aria-label="Recovery progress">
        <div className="h-1.5 rounded-full bg-brand" style={{ width: `${progress * 100}%` }} />
      </div>
    </Feature>
  )
}

// ------------------------------------------------------------------ 7. Lender loss accounting

export function LenderLoss({ book, cur, haircut }: { book: Book; cur: StepState; haircut: bigint }) {
  const [stress, setStress] = useState<number>()
  const price = stress ?? Number(cur.valuationWad) / 1e18
  const b = stress === undefined ? book : bookAtPrice(book, usd(stress), haircut)
  return (
    <Feature
      name="Lender loss accounting"
      tone={b.shortfall > 0n ? 'down' : 'up'}
      status={b.shortfall > 0n ? 'Shortfall' : 'Fully covered'}
      info={<>Lender assets = cash + Σ min(debt, collateral value ÷ 1.05). A shortfall lowers share value as soon as the accepted price shows it, before any collateral runs out. Written-off debt is totalBadDebt.</>}
    >
      <Grid cols={4}>
        <Fig k="Recoverable" v={usdg(b.lenderAssets)} sub="USDG" />
        <Fig k="Shortfall" v={usdg(b.shortfall)} tone={b.shortfall > 0n ? 'down' : 'ink'} sub="recognized" />
        <Fig k="Written off" v={usdg(b.totalBadDebt)} sub="USDG" />
        <Fig k="Share value" v={(Number(b.shareValue) / 1e6).toFixed(4)} tone={b.shortfall > 0n ? 'down' : 'ink'} />
      </Grid>
      <label className="mt-3 flex items-center gap-3 text-[11px] text-dk-muted">
        <span className="shrink-0">What-if TSLA</span>
        <input type="range" min={150} max={420} step={1} value={Math.round(price)} onChange={e => setStress(Number(e.target.value))} className="w-full accent-brand" aria-label="What-if TSLA price" />
        <span className="num w-12 shrink-0 text-right text-dk-ink">{price.toFixed(0)}</span>
        {stress !== undefined && (
          <button type="button" onClick={() => setStress(undefined)} className="shrink-0 text-dk-up hover:underline">
            reset
          </button>
        )}
      </label>
    </Feature>
  )
}

/** The position meter with the limits that apply to it. */
export function PositionMeter({ p, cur, pol }: { p: Position; cur: StepState; pol: Policy }) {
  const s = cur.snapshot
  const next = nextCloseLt(cur, pol)
  const marks = [
    { at: f(p.planTargetWad), label: `Target ${pct(p.planTargetWad, 0)}`, tone: 'muted' as Tone, dashed: true },
    ...(s.canBorrow ? [{ at: f(s.borrowLimitWad), label: `Borrow ${pct(s.borrowLimitWad, 1)}`, tone: 'brand' as Tone }] : []),
    { at: f(s.ltWad), label: `Threshold ${pct(s.ltWad, 1)}`, tone: 'down' as Tone },
    ...(s.ltWad !== next ? [{ at: f(next), label: `At close ${pct(next, 0)}`, tone: 'warn' as Tone, dashed: true }] : []),
  ]
  return <Meter ltv={p.debt ? f(p.ltvWad) : undefined} marks={marks} min={0.55} max={0.85} />
}
