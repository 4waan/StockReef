import type { ReactNode } from 'react'
import { nyClock, nyTime, pct, tokens, usdg } from '@/lib/format'
import { abovePlan, reasonList, stateName } from '@/lib/policy'
import type { AccountData, MarketData } from '@/lib/types'

type Tone = 'down' | 'warn' | 'muted'

/** One line per condition the borrower needs to know about now: what to do, by when, and what happens otherwise. */
export function Alerts({ m, v }: { m: MarketData; v: AccountData | undefined }) {
  const s = m.policy
  const state = stateName(s.state)
  const phase = stateName(s.phase)
  const beforeClose = phase === 'OPEN' || phase === 'PRE_CLOSE' || phase === 'FINAL_WINDOW'
  const lines: { tone: Tone; body: ReactNode }[] = []

  if (state === 'GUARDED') {
    const reasons = reasonList(Number(s.reasons))
    lines.push({ tone: 'down', body: <>Guarded: nothing price-dependent runs. {reasons.length > 0 && <>Why: {reasons.join(' · ')}.</>} Repaying and adding collateral still work.</> })
  }
  if (m.impaired) lines.push({ tone: 'down', body: 'The lender book is impaired: a loan’s debt is above what its collateral can recover. New borrowing is blocked.' })
  if (s.windDown) lines.push({ tone: 'warn', body: 'Wind-down: the loaded calendar has ended. Price-dependent actions have stopped; lenders can withdraw available cash.' })
  if (m.pendingMultiplier > 0n)
    lines.push({
      tone: 'warn',
      body: (
        <>
          The token’s multiplier changes to {(Number(m.pendingMultiplier) / 1e18).toString()} at {nyTime(m.multiplierEffectiveAt)} ET. Prices from before the change stop counting.
        </>
      ),
    })

  if (v && v.debt > 0n) {
    if (v.missedExecution) {
      lines.push({
        tone: 'down',
        body: (
          <>
            Missed execution: nobody reduced this loan before the close, and it entered the closure above the {pct(s.ltWad, 1)} threshold. Exposure:{' '}
            <b className="num">{usdg(v.exposure)} USDG</b>, the repayment needed to reach the {pct(v.planTargetWad, 0)} target at the indicative valuation. It is not a prediction of
            the reopening loss.
          </>
        ),
      })
    }
    if (v.trimNow.eligible) {
      lines.push({
        tone: 'down',
        body: (
          <>
            Eligible for a trim now: a liquidator may repay <b className="num">{usdg(v.trimNow.repaid)} USDG</b> and take <b className="num">{tokens(v.trimNow.collateralOut)} TSLA</b> (
            {pct(v.trimNow.bonusWad, 0)} bonus){v.trimNow.fullFill ? `, bringing the loan to ${pct(s.targetWad, 0)}` : ''}.
            {v.trimNow.bufferPending && ' Your funded buffer must run first.'}
          </>
        ),
      })
    }
    if (beforeClose && abovePlan(v.repayToTarget)) {
      lines.push({
        tone: 'warn',
        body: (
          <>
            Before the close: repay <b className="num">{usdg(v.repayToTarget)} USDG</b> or add <b className="num">{tokens(v.addCollateralRawToTarget)} TSLA</b> by{' '}
            <b className="num">{nyClock(s.finalAt)} ET</b> to reach the {pct(v.planTargetWad, 0)} plan.{' '}
            {v.trimmableAtFinal ? (
              <>
                If you do nothing, from the final window a liquidator may repay {usdg(v.trimAtFinalRepay)} USDG and take {tokens(v.trimAtFinalCollateral)} TSLA (
                {pct(v.trimAtFinalBonusWad, 0)} bonus).
              </>
            ) : (
              'At today’s price the loan stays under the closing threshold and enters the closure as it is.'
            )}{' '}
            If no transaction is submitted, debt does not shrink.
          </>
        ),
      })
    }
    if (beforeClose && v.trimmableAtReopen)
      lines.push({
        tone: 'muted',
        body: (
          <>
            At the reopening, interest brings the debt to <span className="num">{usdg(v.projectedDebtAtReopen)} USDG</span>, above the closing threshold at today’s price: a recovery trim
            at a 5% bonus could follow.
          </>
        ),
      })
  }

  if (!lines.length) return null
  return (
    <div className="border-b border-dk-line">
      {lines.map((l, i) => (
        <p
          key={i}
          className={`border-l-2 px-5 py-2 text-sm ${l.tone === 'down' ? 'border-dk-down text-dk-ink' : l.tone === 'warn' ? 'border-dk-warn text-dk-ink' : 'border-dk-faint text-dk-muted'} ${i ? 'border-t border-t-dk-line' : ''}`}
        >
          {l.body}
        </p>
      ))}
    </div>
  )
}
