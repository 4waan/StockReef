'use client'

import { useState } from 'react'
import type { HistoryItem } from '@/lib/history'
import { duration, nyClock, pct, tokens, usdg } from '@/lib/format'
import { ltAtTime } from '@/lib/desk'
import { bookAtPrice, exceeds, ltvUp, nextCloseLt, S, usd, valueOfRaw, type Book, type Policy, type Position, type StepState } from '@/lib/scenario'
import { Card, Meter, Note, Permit, Stat, Status, TxRef, type Tone } from './ui'

/**
 * The seven StockReef features, each as a panel that reads the contract-valued position at the current step.
 * The terminal shows them as tabs and compact tiles; the portfolio shows them as a dashboard.
 */

const f = (w: bigint) => Number(w) / 1e18
const day = (t: bigint | number, mon: bigint) => `${BigInt(t) >= mon ? 'Mon' : 'Fri'} ${nyClock(t)}`

/** Seconds to go, as "15m 00s" or "2h 30m". */
const left = (from: bigint, to: bigint) => (to > from ? duration(Number(to - from)) : 'passed')

// ------------------------------------------------------------------ 1. Debt reduction before closure

export function DebtReduction({ p, cur, steps, compact }: { p: Position; cur: StepState; steps: StepState[]; compact?: boolean }) {
  const s = cur.snapshot
  const beforeClose = s.phase === S.OPEN || s.phase === S.PRE_CLOSE || s.phase === S.FINAL_WINDOW
  const deadline = s.phase === S.FINAL_WINDOW ? s.close : s.finalAt
  const need = p.repayToTarget >= 10_000n
  const mon = steps.find(x => x.step.day === 'mon')!.snapshot.open
  const tone: Tone = !need ? 'up' : p.trimNow.eligible ? 'down' : 'warn'
  return (
    <Card
      kicker="Debt reduction before closure"
      title={beforeClose ? `Bring the loan to ${pct(p.planTargetWad, 0)} before ${nyClock(deadline)} ET` : `Plan for the closure that ${s.phase === S.CLOSED ? 'is under way' : 'just ended'}`}
      aside={<Status tone={tone}>{need ? 'Action needed' : 'On plan'}</Status>}
    >
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Stat label="Next deadline" value={beforeClose ? `${day(deadline, mon)} ET` : '—'} sub={s.phase === S.FINAL_WINDOW ? 'Market close' : 'Final window starts'} />
        <Stat label="Time remaining" value={beforeClose ? left(cur.t, deadline) : 'Closed'} tone={beforeClose && deadline - cur.t < 1800n ? 'warn' : 'ink'} sub={`Scenario clock ${nyClock(cur.t)} ET`} />
        <Stat label="Required repayment" value={need ? `${usdg(p.repayToTarget)} USDG` : 'None'} tone={need ? 'warn' : 'up'} sub={`reaches the ${pct(p.planTargetWad, 0)} target`} />
        <Stat label="Or add collateral" value={need ? `${tokens(p.addRawToTarget, 4)} TSLA` : 'None'} sub={need ? `${usdg(p.addValueToTarget)} USDG of value` : 'keeps your stock'} />
      </div>
      {!compact && (
        <div className="mt-4 space-y-1.5">
          <Note>
            Computed from your debt at the scenario time (StockReefMarket.debtAt) and your collateral valued at {usdg(cur.valuationWad / 10n ** 12n)} USDG per TSLA (PriceGate.valueOf). The
            repayment uses no liquidation bonus; adding collateral keeps the stock exposure.
          </Note>
          {p.trimAtFinal.eligible && beforeClose && (
            <Note tone="warn">
              If nothing executes by {nyClock(s.finalAt)} ET, a liquidator may repay {usdg(p.trimAtFinal.repaid)} USDG and take {tokens(p.trimAtFinal.collateralOut)} TSLA at a{' '}
              {pct(p.trimAtFinal.bonusWad, 0)} bonus. If no transaction is submitted, the debt does not shrink.
            </Note>
          )}
        </div>
      )}
    </Card>
  )
}

// ------------------------------------------------------------------ 2. Falling threshold

export function FallingThreshold({ p, cur, pol, ltPath, steps }: { p: Position; cur: StepState; pol: Policy; ltPath: { t: number; lt: number }[]; steps: StepState[] }) {
  const s = cur.snapshot
  const atClose = nextCloseLt(cur, pol)
  const ltv = f(p.ltvWad)
  const fri = steps[0].snapshot
  const W = 300
  const H = 92
  const t0 = Number(fri.prepAt) - 3600
  const t1 = Number(fri.close)
  const X = (t: number) => ((t - t0) / (t1 - t0)) * W
  const Y = (v: number) => H - ((v - 0.6) / 0.24) * H
  const pts = [{ t: t0, lt: ltAtTime(ltPath, t0) }, ...ltPath.filter(q => q.t > t0 && q.t <= t1)]
  const nowT = Math.min(Number(cur.t), t1)
  return (
    <Card kicker="Falling threshold" title="The liquidation threshold tightens before the close" aside={<Status tone={exceeds(p.debt, p.value, s.ltWad) ? 'down' : 'up'}>{exceeds(p.debt, p.value, s.ltWad) ? 'Above threshold' : 'Below threshold'}</Status>}>
      <div className="grid grid-cols-3 gap-4">
        <Stat label="Threshold now" value={pct(s.ltWad, 2)} tone="warn" />
        <Stat label="At the next closure" value={pct(atClose, 2)} sub={atClose === pol.ltFinalExtended ? 'weekend limit' : 'overnight limit'} />
        <Stat label="Your LTV" value={p.debt ? pct(p.ltvWad, 2) : '—'} tone={ltv > f(s.ltWad) ? 'down' : ltv > f(atClose) ? 'warn' : 'up'} sub={`headroom ${p.debt ? ((f(s.ltWad) - ltv) * 100).toFixed(2) : '—'} pp`} />
      </div>
      <svg viewBox={`0 0 ${W} ${H + 16}`} className="mt-4 h-28 w-full" role="img" aria-label="Scheduled threshold curve against your LTV">
        {[0.7, 0.8].map(v => (
          <g key={v}>
            <line x1="0" x2={W} y1={Y(v)} y2={Y(v)} stroke="#23272d" />
            <text x={W} y={Y(v) - 3} fontSize="9" fill="#6b727b" textAnchor="end">
              {Math.round(v * 100)}%
            </text>
          </g>
        ))}
        <path d={pts.map((q, i) => `${i ? 'L' : 'M'}${X(q.t).toFixed(1)},${Y(q.lt).toFixed(1)}`).join(' ')} fill="none" stroke="#b87d22" strokeWidth="2" />
        <line x1="0" x2={W} y1={Y(ltv)} y2={Y(ltv)} stroke="#3a86cc" strokeWidth="2" />
        <circle cx={X(nowT)} cy={Y(ltAtTime(ltPath, nowT))} r="3.5" fill="#e8eaed" />
        <text x="2" y={H + 13} fontSize="9" fill="#6b727b">
          {nyClock(t0)}
        </text>
        <text x={X(Number(fri.prepAt))} y={H + 13} fontSize="9" fill="#6b727b" textAnchor="middle">
          {nyClock(fri.prepAt)} ramp
        </text>
        <text x={X(Number(fri.finalAt))} y={H + 13} fontSize="9" fill="#6b727b" textAnchor="middle">
          {nyClock(fri.finalAt)}
        </text>
        <text x={W} y={H + 13} fontSize="9" fill="#6b727b" textAnchor="end">
          close
        </text>
      </svg>
      <div className="mt-1 flex gap-4 text-[11px] text-dk-muted">
        <span className="inline-flex items-center gap-1.5">
          <span className="h-0.5 w-4 bg-[#b87d22]" />
          Threshold, SessionRiskPolicy.ltAt
        </span>
        <span className="inline-flex items-center gap-1.5">
          <span className="h-0.5 w-4 bg-[#3a86cc]" />
          Your LTV now
        </span>
      </div>
    </Card>
  )
}

// ------------------------------------------------------------------ 3. Funded repayment buffer

export function FundedBuffer({ p, cur, items, compact }: { p: Position; cur: StepState; items: HistoryItem[]; compact?: boolean }) {
  const plan = p.plan
  const active = plan.targetWad > 0n && plan.expiry > cur.t
  const expiredBefore = plan.targetWad > 0n && plan.expiry <= cur.t
  const repaid = items.filter(i => i.kind === 'Buffer repaid')
  const status: { tone: Tone; text: string } = p.bufferNow > 0n
    ? { tone: 'warn', text: 'Executable now' }
    : active && p.bufferNext > 0n
      ? { tone: 'up', text: 'Armed' }
      : active
        ? { tone: 'muted', text: 'Nothing to repay' }
        : expiredBefore
          ? { tone: 'down', text: 'Authorization expired' }
          : { tone: 'muted', text: 'Not authorized' }
  const cover = p.repayToTarget > 0n ? Number(p.bufferNext) / Number(p.repayToTarget) : undefined
  return (
    <Card kicker="Funded repayment buffer" title="Your USDG repays first: no stock sold, no bonus paid" aside={<Status tone={status.tone}>{status.text}</Status>}>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <Stat label="Funded" value={`${usdg(plan.balance)} USDG`} sub="borrower escrow, not lender cash" />
        <Stat label="Authorization" value={plan.targetWad > 0n ? `${pct(plan.targetWad, 0)} target` : 'None'} sub={plan.expiry > 0n ? `${expiredBefore ? 'expired' : 'until'} ${new Date(Number(plan.expiry) * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false })} ET` : 'not set'} tone={expiredBefore ? 'down' : 'ink'} />
        <Stat label="Spending cap" value={plan.targetWad > 0n ? `${usdg(plan.perSessionCap)} USDG` : '—'} sub="per session" />
        <Stat label="Coverage" value={cover === undefined ? '—' : `${Math.min(100, cover * 100).toFixed(0)}%`} sub={p.bufferNextAt ? `of the ${usdg(p.repayToTarget)} USDG plan` : 'no buffer window left'} tone={cover !== undefined && cover >= 0.999 ? 'up' : 'warn'} />
        <Stat label="Executable" value={`${usdg(p.bufferNow > 0n ? p.bufferNow : p.bufferNext)} USDG`} sub={p.bufferNow > 0n ? 'now (RepaymentEscrow.executableAmount)' : p.bufferNextAt ? `at the ${p.bufferNextAt === 'prep' ? '15:15 preparation' : p.bufferNextAt} window` : '—'} tone={p.bufferNow > 0n ? 'warn' : 'ink'} />
        <Stat label="Confirmed repayments" value={repaid.length ? `${usdg(repaid.reduce((a, r) => a + r.amount, 0n))} USDG` : 'None yet'} sub={repaid[0] ? <TxRef hash={repaid[0].hash}>latest receipt</TxRef> : 'receipts appear here'} tone={repaid.length ? 'up' : 'ink'} />
      </div>
      {!compact && (
        <div className="mt-3 space-y-1.5">
          {expiredBefore && <Note tone="down">The authorization ends before this session. Re-authorize it during the open market (Buffer → Authorize) so it can run at the close.</Note>}
          <Note>During preparation and reopening recovery anyone may execute the plan, within its target and per-session cap. An executable buffer must run before any trim.</Note>
        </div>
      )}
    </Card>
  )
}

// ------------------------------------------------------------------ 4. Partial liquidation

export function PartialLiquidation({ p, cur, compact }: { p: Position; cur: StepState; compact?: boolean }) {
  const q = p.trimNow.eligible ? p.trimNow : p.trimAtFinal
  const now = p.trimNow.eligible
  const s = cur.snapshot
  const afterDebt = q.debt - q.repaid
  const afterColl = p.collateral - q.collateralOut
  const afterValue = valueOfRaw(afterColl, cur.valuationWad)
  const afterLtv = ltvUp(afterDebt, afterValue)
  const tone: Tone = now ? (q.bufferPending ? 'warn' : 'down') : q.eligible ? 'warn' : 'up'
  return (
    <Card
      kicker="Partial liquidation"
      title={now ? 'Eligible now: a liquidator may trim part of the loan' : q.eligible ? 'Not eligible yet; eligible at the final window if nothing changes' : 'Not eligible'}
      aside={<Status tone={tone}>{now ? (q.bufferPending ? 'Buffer runs first' : 'Eligible') : q.eligible ? `From ${nyClock(s.finalAt)}` : 'Safe'}</Status>}
    >
      {q.eligible ? (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
          <Stat label="Debt reduction" value={`${usdg(q.repaid)} USDG`} sub="paid by the liquidator" />
          <Stat label="Collateral taken" value={`${tokens(q.collateralOut, 5)} TSLA`} sub={`${usdg(valueOfRaw(q.collateralOut, cur.valuationWad))} USDG of value`} />
          <Stat label="Bonus" value={pct(q.bonusWad, 0)} sub={f(q.bonusWad) < 0.03 ? 'scheduling trim' : 'distress or recovery'} />
          <Stat label="Resulting position" value={pct(afterLtv, 2)} sub={`${usdg(afterDebt)} USDG on ${tokens(afterColl, 4)} TSLA`} tone="up" />
        </div>
      ) : (
        <p className="text-sm text-dk-muted">
          The loan is at or below the threshold ({pct(p.ltvWad, 2)} vs {pct(s.ltWad, 2)}), so no one can trim it. A target alone never triggers a trim.
        </p>
      )}
      {!compact && (
        <div className="mt-3 space-y-1.5">
          <Note>From StockReefMarket.quoteTrim at the scenario snapshot: eligible only when LTV is strictly above the threshold; a full fill reaches the {pct(p.planTargetWad, 0)} target and leaves the rest of the position in place.</Note>
          {q.bufferPending && <Note tone="warn">Your funded buffer is executable, so a trim reverts until the buffer has run.</Note>}
        </div>
      )}
    </Card>
  )
}

// ------------------------------------------------------------------ 5. Closed-session protection

export function ClosedProtection({ cur, p }: { cur: StepState; p: Position | undefined }) {
  const s = cur.snapshot
  const name = ['open', 'preparation', 'final window', 'closed market', 'reopening wait', 'reopening recovery', 'guarded market'][s.state]
  const hasDebt = !!p && p.debt > 0n
  return (
    <Card kicker="Closed-session protection" title={s.canBorrow ? 'New credit is available' : 'New credit is locked'} aside={<Status tone={s.canBorrow ? 'up' : 'muted'}>{s.canBorrow ? `Borrow limit ${pct(s.borrowLimitWad, 1)}` : 'Borrowing locked'}</Status>}>
      <Permit label="Borrow USDG" on={s.canBorrow} why={s.canBorrow ? `Up to ${pct(s.borrowLimitWad, 1)} LTV` : s.phase === S.FINAL_WINDOW ? 'Stops 30 minutes before the close' : s.phase === S.REOPEN_RECOVERY ? `Returns at ${nyClock(s.creditAt)} ET` : `Locked in the ${name}`} />
      <Permit label="Withdraw TSLA against debt" on={s.canBorrow} why={s.canBorrow ? 'Must stay within the borrow limit' : 'Needs borrowing to be open'} />
      <Permit label="Repay USDG" on why="Every state, no price needed" />
      <Permit label="Add TSLA collateral" on why="Every state, no price needed" />
      <Permit label="Funded buffer execution" on={s.canBuffer} why={s.canBuffer ? 'Preparation, final window and recovery' : 'Paused while the market is closed'} />
      <Permit label="Partial liquidation" on={s.canTrim} why={s.canTrim ? 'Loans strictly above the threshold' : 'Paused while the market is closed'} />
      <Permit label="Lender deposits and withdrawals" on={s.lenderOpen} why={s.lenderOpen ? 'Normal open phase' : 'Window closed from preparation to credit return'} />
      {hasDebt && !s.canBorrow && <div className="mt-3"><Note>Your loan cannot grow while new credit is locked. It can only be reduced.</Note></div>}
    </Card>
  )
}

// ------------------------------------------------------------------ 6. Controlled reopening

export function ControlledReopening({ cur, steps }: { cur: StepState; steps: StepState[] }) {
  const monOpen = steps.find(x => x.step.day === 'mon')!.snapshot.open
  const admit = steps.find(x => x.step.id === 'admit')!
  const wait = steps.find(x => x.step.id === 'wait')!
  const reached = cur.t >= monOpen
  const s = cur.snapshot
  const admitted = reached && s.admissionAt > 0n
  const creditAt = admit.snapshot.creditAt
  const progress = admitted ? Math.min(1, Number(cur.t - s.admissionAt) / Number(creditAt - s.admissionAt)) : 0
  const tone: Tone = !reached ? 'muted' : !admitted ? 'warn' : cur.t >= creditAt ? 'up' : 'brand'
  return (
    <Card
      kicker="Controlled reopening"
      title={!reached ? 'Monday: fresh price first, then recovery, then credit' : !admitted ? 'Waiting for a fresh price to be admitted' : cur.t >= creditAt ? 'Recovery complete: credit has returned' : 'Recovery window: buffers, then trims'}
      aside={<Status tone={tone}>{!reached ? 'After the weekend' : !admitted ? 'Price not admitted' : cur.t >= creditAt ? 'Credit open' : 'Recovering'}</Status>}
    >
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Stat label="Fresh price" value={reached ? `${(Number(cur.quoteWad) / 1e18).toFixed(2)}` : '—'} sub={reached ? `stamped ${nyClock(wait.t)}; must be ≥ ${nyClock(monOpen + 60n)}` : 'quote must follow the open'} />
        <Stat label="Admission" value={admitted ? `${nyClock(s.admissionAt)} ET` : `from ${nyClock(monOpen + 300n)} ET`} sub="not before open + 5 minutes" tone={admitted ? 'up' : 'ink'} />
        <Stat label="Credit returns" value={`${nyClock(creditAt)} ET`} sub="later of open + 15 min, admission + 10 min" />
        <Stat label="Guarded if no price by" value={`${nyClock(monOpen + 1800n)} ET`} sub="elapsed time never admits a bad quote" />
      </div>
      <div className="mt-4">
        <div className="flex justify-between text-xs text-dk-muted">
          <span>Recovery progress</span>
          <span className="num">{admitted ? `${Math.round(progress * 100)}%` : '—'}</span>
        </div>
        <div className="mt-1.5 h-2 rounded-full bg-dk-raised">
          <div className="h-2 rounded-full bg-brand" style={{ width: `${progress * 100}%` }} />
        </div>
      </div>
    </Card>
  )
}

// ------------------------------------------------------------------ 7. Lender loss accounting

export function LenderLoss({ book, cur, haircut, pol }: { book: Book; cur: StepState; haircut: bigint; pol?: Policy }) {
  const [stress, setStress] = useState<number>()
  const price = stress ?? Number(cur.valuationWad) / 1e18
  const b = stress === undefined ? book : bookAtPrice(book, usd(stress), haircut)
  const base = book.shareValue
  const delta = Number(b.shareValue - base) / 1e6
  void pol
  return (
    <Card
      kicker="Lender loss accounting"
      title="Share value counts only what loans can recover"
      aside={<Status tone={b.shortfall > 0n ? 'down' : 'up'}>{b.shortfall > 0n ? 'Shortfall recognized' : 'Fully recoverable'}</Status>}
    >
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Stat label="Recoverable assets" value={`${usdg(b.lenderAssets)} USDG`} sub={`${usdg(b.cash)} cash + ${usdg(b.recoverable)} loans`} />
        <Stat label="Recognized shortfall" value={`${usdg(b.shortfall)} USDG`} tone={b.shortfall > 0n ? 'down' : 'ink'} sub="debt above value ÷ 1.05" />
        <Stat label="Debt written off" value={`${usdg(b.totalBadDebt)} USDG`} sub="since deployment (totalBadDebt)" />
        <Stat label="Share value" value={`${(Number(b.shareValue) / 1e6).toFixed(4)}`} sub={stress === undefined ? 'USDG per 1 USDG deposited' : `${delta >= 0 ? '+' : ''}${delta.toFixed(4)} vs scenario price`} tone={b.shortfall > 0n ? 'down' : 'ink'} />
      </div>
      <div className="mt-4 rounded-md border border-dk-line bg-dk-bg/60 p-3">
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
          <label htmlFor="stress" className="text-dk-muted">
            What-if TSLA price <span className="text-dk-faint">(same formula, not part of the script)</span>
          </label>
          <span className="num text-dk-ink">
            {price.toFixed(2)} USDG
            {stress !== undefined && (
              <button type="button" onClick={() => setStress(undefined)} className="ml-3 text-dk-up hover:underline">
                Back to scenario price
              </button>
            )}
          </span>
        </div>
        <input id="stress" type="range" min={150} max={420} step={1} value={Math.round(price)} onChange={e => setStress(Number(e.target.value))} className="mt-2 w-full accent-[#c56430]" />
        <p className="mt-1 text-xs text-dk-faint">
          lender assets = cash + Σ min(debt, collateral value ÷ 1.05). A shortfall lowers share value as soon as the accepted price shows it, before any collateral runs out.
        </p>
      </div>
      {cur.indicative && <div className="mt-2"><Note tone="warn">Valued at the last accepted price, indicative until a fresh price is admitted.</Note></div>}
    </Card>
  )
}

/** The position meter with the limits that apply to it. */
export function PositionMeter({ p, cur, pol }: { p: Position; cur: StepState; pol: Policy }) {
  const s = cur.snapshot
  const marks = [
    { at: f(p.planTargetWad), label: `Target ${pct(p.planTargetWad, 0)}`, tone: 'muted' as Tone, dashed: true },
    ...(s.canBorrow ? [{ at: f(s.borrowLimitWad), label: `Borrow ${pct(s.borrowLimitWad, 1)}`, tone: 'brand' as Tone }] : []),
    { at: f(s.ltWad), label: `Threshold ${pct(s.ltWad, 1)}`, tone: 'down' as Tone },
    ...(s.ltWad !== nextCloseLt(cur, pol) ? [{ at: f(nextCloseLt(cur, pol)), label: `At close ${pct(nextCloseLt(cur, pol), 0)}`, tone: 'warn' as Tone, dashed: true }] : []),
  ]
  return <Meter ltv={p.debt ? f(p.ltvWad) : undefined} marks={marks} min={0.55} max={0.85} />
}

