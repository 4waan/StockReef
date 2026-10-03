'use client'

import Link from 'next/link'
import type { ReactNode } from 'react'
import { evidence } from '@/generated/evidence'
import { Logo, Mark } from '@/components/brand/Logo'
import { chain } from '@/lib/chain'
import { hhmm, nyClock, pct, price, usdg } from '@/lib/format'
import { useMarketView, useProtocolConstants, useProtocolNow } from '@/lib/hooks'
import { nextMilestone, stateName, STATE_COPY } from '@/lib/policy'

const runs = evidence.runs as Record<string, Record<string, unknown>>
const w = evidence.golden.worked_example
const u = (base: string | number) => (Number(base) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** Lender loss and liquidator P&L for the 35% weekend gap, from the committed scenario harness output. */
function gapRows() {
  const rows = ((runs['scenarios'] as { rows?: Record<string, string>[] } | undefined)?.rows ?? []).filter(r => r.scenario.includes('35%'))
  const find = (b: string) => rows.find(r => r.baseline.includes(b))
  return { nobody: find('nobody acts'), buffer: find('buffer'), trim: find('trim') }
}

export default function Landing() {
  const g = gapRows()
  return (
    <div className="min-h-screen bg-cream text-charcoal">
      <Nav />

      <section className="mx-auto max-w-6xl px-5 pt-16 pb-14 md:pt-24">
        <p className="text-sm font-semibold tracking-[0.2em] text-brand uppercase">Tokenized stock lending · Robinhood Chain</p>
        <h1 className="mt-5 text-[clamp(48px,9vw,132px)] leading-[0.9] font-extrabold tracking-[-0.04em] uppercase">
          Stock markets close.
          <br />
          Loans don’t.
        </h1>
        <div className="mt-10 grid gap-6 border-t border-charcoal/15 pt-8 md:grid-cols-2">
          <p className="text-xl leading-snug text-charcoal/60 md:text-2xl">A borrowing lock can stop a loan from getting larger over the weekend.</p>
          <p className="text-xl leading-snug font-semibold md:text-2xl">StockReef makes the existing loan smaller, while a usable price still exists.</p>
        </div>
        <Ctas />
      </section>

      <LiveMarket />

      <section id="controls" className="mx-auto max-w-6xl px-5 py-20">
        <h2 className="text-[clamp(36px,6vw,84px)] leading-[0.95] font-extrabold tracking-[-0.03em] uppercase">
          Prepare before the bell.
          <br />
          <span className="text-charcoal/35">Recover before new credit.</span>
        </h2>
        <p className="mt-6 max-w-2xl text-lg text-charcoal/70">
          An automatic risk-control protocol for tokenized stock borrowers and USDG lenders. It reduces outstanding debt before market closures through borrower-funded repayments, a
          gradually tightening threshold and partial liquidation, then gives recovery priority when the market reopens.
        </p>
        <ol className="mt-12 divide-y divide-charcoal/15 border-y border-charcoal/15">
          <Control n="01" title="Carry less debt into the gap" fact="80% → 70% weekend · 77% overnight">
            Two hours before each scheduled close the liquidation threshold starts falling, and finishes 30 minutes before the bell. Weekends and holidays get a deeper adjustment than an
            ordinary night. The borrow limit falls with it, and new borrowing stops in the final 30 minutes.
          </Control>
          <Control n="02" title="Keep the stock you want to hold" fact="no bonus · no sale">
            A buffer the borrower funds in advance repays debt during preparation, within an authorized target, a cap per session and an expiry. It runs before any liquidator can trim, and
            it never sells collateral.
          </Control>
          <Control n="03" title="Reduce the position instead of closing it" fact="2% scheduling · 5% distress">
            Only a loan strictly above the current threshold can be trimmed. A liquidator repays part of the debt and takes collateral at the current accepted price plus a bonus, back to a
            published target. The rest of a solvent position stays.
          </Control>
          <Control n="04" title="Stop new risk while the market is closed" fact="repay and top up still work">
            While the market is closed, new borrowing and debt-backed withdrawals stop, and so do liquidations and buffers. The session calendar includes holidays, early closes and
            daylight-saving changes.
          </Control>
          <Control n="05" title="Recover before lending again" fact="admission ≥ open + 5 min">
            After the reopening, a price published after the open must be admitted before anything price-dependent runs. Recovery trims come first; credit returns only after a recovery
            window. Without admission within 30 minutes, the market turns guarded.
          </Control>
        </ol>
        <PolicyTable />
        <Ctas />
      </section>

      <section id="numbers" className="bg-charcoal text-cream">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <h2 className="text-[clamp(36px,6vw,84px)] leading-[0.95] font-extrabold tracking-[-0.03em] uppercase">A Friday close in numbers</h2>
          <p className="mt-6 max-w-2xl text-lg text-cream/70">
            {u(w.value_usdg)} USDG of TSLA collateral against {u(w.debt_usdg)} USDG of debt: 72% LTV. At 15:15 before a 16:00 weekend close, the threshold has fallen to about 71.667%, so the
            loan is eligible for a trim.
          </p>
          <div className="mt-10 grid gap-px overflow-hidden rounded-lg bg-cream/15 md:grid-cols-3">
            <Route title="Funded buffer" big={`${u(w.cash_required_usdg)} USDG`} line="repaid by the borrower" result="65% LTV · no collateral sold" />
            <Route title="Partial trim, 2% bonus" big={`${u(w.trim_repay_usdg)} USDG`} line={`repaid by a liquidator for ${Number(w.trim_seized_value_usdg_exact).toFixed(2)} USDG of TSLA`} result="65% LTV" />
            <Route title="Nobody executes" big="0 USDG" line="nothing moves before the close" result="enters the closure unchanged · exposure reported" />
          </div>
          <p className="mt-6 text-sm text-cream/50">Rounded golden values at a fixed price, before additional interest. The trim needs more repayment than the buffer because it removes collateral as well as debt.</p>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-5 py-20">
        <h2 className="text-[clamp(36px,6vw,84px)] leading-[0.95] font-extrabold tracking-[-0.03em] uppercase">
          Less exposure.
          <br />
          <span className="text-charcoal/35">Not zero risk.</span>
        </h2>
        <p className="mt-6 max-w-2xl text-lg text-charcoal/70">Modelled lender loss on the same loan through a 35% weekend gap. Lenders bear any shortfall left after collateral recovery; there is no reserve in this version.</p>
        <div className="mt-10 grid gap-6 md:grid-cols-4">
          <Stat value={g.nobody?.['lender loss']} label="lender loss when nobody acts" />
          <Stat value={g.buffer?.['lender loss']} label="after a funded buffer" accent />
          <Stat value={g.trim?.['lender loss']} label="after a pre-close trim" accent />
          <Stat value={g.trim?.['liquidator gap P&L']} label="carried by the liquidator holding trimmed stock through the gap" />
        </div>
        <p className="mt-6 text-sm text-charcoal/50">Scenario harness output, USDG. An economic model with a linear approximation for closure interest, not a replay of on-chain execution.</p>
      </section>

      <section className="border-y border-charcoal/15 bg-[#f4f2e8]">
        <div className="mx-auto grid max-w-6xl gap-8 px-5 py-14 md:grid-cols-4">
          <Fact value="535" label="test and invariant entry points, including four mainnet fork tests" />
          <Fact value="32" label="borrowers valued on every lender withdrawal, gas measured at the cap" />
          <Fact value="24 h" label="delay before a guardian stop can be resumed" />
          <Fact value="If no transaction is submitted, debt does not shrink." label="The keeper executes; anyone can. Nothing guarantees a buyer for seized stock." small />
        </div>
      </section>

      <section className="bg-charcoal text-cream">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <Mark className="h-14 w-auto text-brand" />
          <h2 className="mt-6 text-[clamp(36px,6vw,84px)] leading-[0.95] font-extrabold tracking-[-0.03em] uppercase">Watch a close happen.</h2>
          <p className="mt-6 max-w-2xl text-lg text-cream/70">
            Open the trading view on {chain.name}. The demo steps through a buffer repayment, a pre-close trim, a missed execution and a reopening recovery, with every receipt on-chain.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link href="/trade" className="rounded-md bg-cream px-6 py-3 text-lg font-semibold text-charcoal hover:bg-white">
              Launch app ↗
            </Link>
            <Link href="/evidence" className="rounded-md border border-cream/30 px-6 py-3 text-lg font-semibold hover:border-cream/60">
              See the evidence
            </Link>
          </div>
        </div>
      </section>

      <footer className="mx-auto max-w-6xl px-5 py-10 text-sm text-charcoal/55">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <Logo markClassName="h-5 w-auto text-brand" wordClassName="text-base" />
          <a href="https://github.com/4waan/StockSmart" target="_blank" rel="noreferrer" className="hover:text-charcoal">
            Source on GitHub ↗
          </a>
        </div>
        <p className="mt-4 max-w-3xl">
          Buildathon prototype. Risk parameters are illustrative test settings, not calibrated safety guarantees. On testnet the stock price and the market clock are simulated and labelled;
          USDG is real Paxos USDG.
        </p>
      </footer>
    </div>
  )
}

function Nav() {
  return (
    <header className="sticky top-0 z-20 border-b border-charcoal/10 bg-cream/90 backdrop-blur">
      <div className="mx-auto flex h-16 max-w-6xl items-center gap-6 px-5">
        <Link href="/" aria-label="StockReef home">
          <Logo markClassName="h-7 w-auto text-charcoal" wordClassName="text-2xl" />
        </Link>
        <nav className="ml-auto hidden items-center gap-6 text-[15px] font-medium md:flex" aria-label="Sections">
          <a href="#controls" className="hover:text-brand">
            How it works
          </a>
          <a href="#numbers" className="hover:text-brand">
            A Friday close
          </a>
          <Link href="/evidence" className="hover:text-brand">
            Evidence
          </Link>
        </nav>
        <Link href="/trade" className="rounded-md bg-charcoal px-4 py-2 text-[15px] font-semibold text-cream hover:bg-black max-md:ml-auto">
          Launch app
        </Link>
      </div>
    </header>
  )
}

function Ctas() {
  return (
    <div className="mt-10 flex flex-wrap gap-3">
      <Link href="/trade" className="rounded-md bg-charcoal px-6 py-3 text-lg font-semibold text-cream hover:bg-black">
        Borrow against TSLA ↗
      </Link>
      <Link href="/earn" className="rounded-md border border-charcoal/25 px-6 py-3 text-lg font-semibold hover:border-charcoal/60">
        Lend USDG ↗
      </Link>
    </div>
  )
}

/** The live market, read from the chain: price, session state, threshold now and at the close, and the countdown. */
function LiveMarket() {
  const { data: m } = useMarketView()
  const { data: k } = useProtocolConstants()
  const now = useProtocolNow(m?.policy.time)
  const s = m?.policy
  const state = s ? stateName(s.state) : undefined
  const next = s && now !== undefined ? nextMilestone(stateName(s.phase), s) : undefined
  const closing = s && k ? (s.closureClass === 1 ? k.ltFinalExtended : k.ltFinalOvernight) : undefined
  return (
    <section className="bg-charcoal text-cream">
      <div className="mx-auto grid max-w-6xl gap-px px-5 py-10 sm:grid-cols-2 lg:grid-cols-5">
        <Cell label="TSLA / USDG" value={m ? price(m.valuationPriceWad) : '—'} sub={m?.valuationIndicative ? 'last accepted, indicative' : m?.simulationClock ? 'simulated demo price' : undefined} />
        <Cell label="Session" value={state ? STATE_COPY[state].label : '—'} sub={now !== undefined ? `${nyClock(now)} New York` : undefined} />
        <Cell label="Threshold now → at close" value={s ? `${pct(s.ltWad, 1)} → ${closing !== undefined ? pct(closing, 0) : '—'}` : '—'} sub={s ? (s.closureClass === 1 ? 'weekend or holiday close' : 'overnight close') : undefined} />
        <Cell label={next ? next.label : 'Next milestone'} value={next && now !== undefined ? hhmm(Number(next.at) - now) : '—'} sub={next ? `${nyClock(next.at)} New York` : undefined} />
        <Cell label="Lender assets" value={m ? `${usdg(m.totalAssets, 0)} USDG` : '—'} sub={m ? `utilization ${pct(m.utilizationWad, 1)}` : undefined} />
      </div>
      <p className="mx-auto max-w-6xl px-5 pb-6 text-xs text-cream/45">Live from {chain.name}.</p>
    </section>
  )
}

function PolicyTable() {
  const { data: k } = useProtocolConstants()
  const f = (v: bigint | undefined) => (v === undefined ? '—' : pct(v, 0))
  const rows: [string, bigint | undefined, bigint | undefined][] = [
    ['Open-session liquidation threshold', k?.ltOpen, k?.ltOpen],
    ['Threshold at close − 30 minutes', k?.ltFinalOvernight, k?.ltFinalExtended],
    ['Target after a full solvent trim', k?.targetOvernight, k?.targetExtended],
    ['Open-session borrow limit', k?.borrowOpen, k?.borrowOpen],
  ]
  return (
    <div className="mt-12 overflow-x-auto">
      <table className="w-full min-w-[560px] text-left">
        <thead>
          <tr className="text-sm text-charcoal/55">
            <th className="py-2 font-medium">Current policy, read from the contract</th>
            <th className="py-2 text-right font-medium">Ordinary overnight</th>
            <th className="py-2 text-right font-medium">Weekend / holiday</th>
          </tr>
        </thead>
        <tbody className="text-lg">
          {rows.map(([label, a, b]) => (
            <tr key={label} className="border-t border-charcoal/15">
              <td className="py-3">{label}</td>
              <td className="num py-3 text-right font-semibold">{f(a)}</td>
              <td className="num py-3 text-right font-semibold">{f(b)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-2 text-sm text-charcoal/50">A closure is a weekend or holiday when the next open is at least 24 hours away. These are deployment fixtures, not calibrated safety guarantees.</p>
    </div>
  )
}

function Control({ n, title, fact, children }: { n: string; title: string; fact: string; children: ReactNode }) {
  return (
    <li className="grid gap-3 py-8 md:grid-cols-[80px_1fr_260px] md:gap-8">
      <span className="num text-sm font-semibold text-brand">{n}</span>
      <div>
        <h3 className="text-2xl font-bold tracking-tight md:text-3xl">{title}</h3>
        <p className="mt-2 text-[17px] leading-relaxed text-charcoal/70">{children}</p>
      </div>
      <p className="text-sm font-semibold tracking-wide text-charcoal/60 uppercase md:text-right">↗ {fact}</p>
    </li>
  )
}

function Route({ title, big, line, result }: { title: string; big: string; line: string; result: string }) {
  return (
    <div className="bg-charcoal p-6">
      <div className="text-sm font-semibold tracking-wide text-brand uppercase">{title}</div>
      <div className="num mt-3 text-4xl font-extrabold tracking-tight">{big}</div>
      <div className="mt-1 text-cream/60">{line}</div>
      <div className="mt-4 border-t border-cream/15 pt-3 text-sm">{result}</div>
    </div>
  )
}

function Stat({ value, label, accent }: { value: string | undefined; label: string; accent?: boolean }) {
  return (
    <div className="border-t-2 border-charcoal pt-4">
      <div className={`num text-4xl font-extrabold tracking-tight ${accent ? 'text-brand' : ''}`}>{value ?? '—'}</div>
      <div className="mt-1 text-charcoal/65">{label}</div>
    </div>
  )
}

function Fact({ value, label, small }: { value: string; label: string; small?: boolean }) {
  return (
    <div>
      <div className={`font-extrabold tracking-tight ${small ? 'text-xl leading-snug' : 'num text-5xl'}`}>{value}</div>
      <div className="mt-2 text-charcoal/65">{label}</div>
    </div>
  )
}

function Cell({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="border-cream/15 py-3 sm:pr-6 lg:border-r lg:last:border-r-0 lg:not-first:pl-6">
      <div className="text-sm text-cream/55">{label}</div>
      <div className="num mt-1 text-2xl font-bold">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-cream/45">{sub}</div>}
    </div>
  )
}
