'use client'

import Link from 'next/link'
import { evidence } from '@/generated/evidence'
import { Logo } from '@/components/brand/Logo'
import { pct, price, usdg } from '@/lib/format'
import { useMarketView, useProtocolConstants } from '@/lib/hooks'
import { stateName, STATE_COPY } from '@/lib/policy'

const w = evidence.golden.worked_example
const usd = (base: string | number) => (Number(base) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function Landing() {
  return (
    <div className="min-h-screen bg-cream text-charcoal">
      <Nav />
      <main>
        <section className="mx-auto max-w-6xl px-5 pb-16 pt-16 md:pt-24">
          <p className="text-sm font-semibold uppercase tracking-[0.18em] text-brand">TSLA-backed loans · Robinhood Chain 46630</p>
          <h1 className="mt-5 max-w-5xl text-[clamp(42px,7vw,96px)] font-extrabold leading-[0.98] tracking-[-0.045em]">Controlled risk for stock-backed lending.</h1>
          <p className="mt-7 max-w-3xl text-xl leading-snug text-charcoal/75 md:text-2xl">
            StockReef helps reduce TSLA-backed debt before market closures and controls when new USDG credit can resume.
          </p>
          <div className="mt-10 flex flex-wrap gap-3">
            <Link href="/earn" className="rounded-md bg-charcoal px-6 py-3 text-lg font-semibold text-cream hover:bg-black">Lend USDG ↗</Link>
            <Link href="/trade" className="rounded-md border border-charcoal/30 px-6 py-3 text-lg font-semibold hover:border-charcoal">Borrow against TSLA ↗</Link>
          </div>
          <p className="mt-6 max-w-3xl text-sm leading-relaxed text-charcoal/65">
            On Robinhood Chain 46630, the market uses Paxos USDG, faucet TSLA, and an operator-set stock price and market clock. Balances and transactions in the app come from the deployed contracts.
          </p>
        </section>

        <MarketNow />

        <section id="controls" className="mx-auto max-w-6xl scroll-mt-20 px-5 py-20">
          <p className="text-sm font-bold uppercase tracking-[0.18em] text-brand">The control sequence</p>
          <h2 className="mt-3 text-[clamp(36px,6vw,72px)] font-extrabold leading-[1.02] tracking-tight">How StockReef controls risk</h2>
          <div className="mt-10 grid gap-4 md:grid-cols-3">
            <Stage number="01" title="Before the close">
              Borrowers can fund a USDG repayment before the close. If a loan rises above the falling threshold, a liquidator can repay part of it for TSLA.
            </Stage>
            <Stage number="02" title="While trading is closed">
              New borrowing and debt-backed TSLA withdrawals stop when trading closes. Borrowers can still repay USDG or add TSLA.
            </Stage>
            <Stage number="03" title="At reopening">
              A fresh TSLA price admits recovery trims. New borrowing resumes after the recovery interval if the market remains open.
            </Stage>
          </div>
          <p className="mt-6 max-w-3xl text-sm leading-relaxed text-charcoal/65">The borrower supplies USDG for a funded repayment. A liquidator supplies USDG for a partial trim. The contract checks eligibility and changes debt when a transaction succeeds.</p>
          <PolicyTable />
        </section>

        <section id="numbers" className="scroll-mt-20 bg-charcoal text-cream">
          <div className="mx-auto max-w-6xl px-5 py-20">
            <p className="text-sm font-bold uppercase tracking-[0.18em] text-[#e4a07a]">Friday example</p>
            <h2 className="mt-3 text-[clamp(36px,6vw,72px)] font-extrabold leading-[1.02] tracking-tight">One loan. Three paths into the close.</h2>
            <p className="mt-6 max-w-3xl text-lg text-cream/75">
              At a fixed price of 400 USDG per TSLA, {usd(w.value_usdg)} USDG of collateral secures {usd(w.debt_usdg)} USDG of debt. At 15:15, the falling threshold is about 71.667%, making this 72% LTV loan eligible for a trim.
            </p>
            <div className="mt-10 grid gap-px overflow-hidden rounded-lg bg-cream/15 md:grid-cols-3">
              <Outcome title="Borrower-funded repayment" amount={`${usd(w.cash_required_usdg)} USDG`} detail="Borrower USDG repays debt. TSLA stays in the loan." result="65% LTV after repayment" />
              <Outcome title="Liquidator-funded trim" amount={`${usd(w.trim_repay_usdg)} USDG`} detail={`Liquidator receives ${Number(w.trim_seized_value_usdg_exact).toFixed(2)} USDG of TSLA value.`} result="65% LTV after trim" />
              <Outcome title="No transaction" amount="0 USDG" detail="Debt carries into the closure with accrued interest." result="Remaining exposure stays visible" />
            </div>
            <p className="mt-5 text-sm text-cream/60">Rounded values from the fixed-price worked example, before additional interest. A trim repays more because it also removes collateral.</p>
            <div className="mt-8 grid gap-5 border-t border-cream/20 pt-6 text-sm leading-relaxed md:grid-cols-2">
              <p><strong>Lenders:</strong> If collateral later covers less than the remaining debt, lender shares reflect the amount recoverable from that loan.</p>
              <p><strong>Liquidators:</strong> A liquidator who holds seized TSLA carries its later price movement.</p>
            </div>
            <Link href="/evidence" className="mt-7 inline-block font-semibold text-[#e4a07a] underline underline-offset-4">See the calculations and receipts ↗</Link>
          </div>
        </section>

        <section className="mx-auto max-w-6xl px-5 py-20">
          <h2 className="text-[clamp(36px,6vw,68px)] font-extrabold leading-[1.02] tracking-tight">Use the market</h2>
          <div className="mt-10 grid gap-4 md:grid-cols-3">
            <UseCard title="Borrow" body="Post TSLA, borrow USDG, and see the repayment needed before the close." href="/trade" action="Open Trade" />
            <UseCard title="Lend" body="Deposit USDG and see vault cash, outstanding loans, and your share value." href="/earn" action="Open Earn" />
            <UseCard title="Operate" body="Review eligible repayments, trims, price status, and transaction receipts." href="/operations" action="Open Operations" />
          </div>
        </section>
      </main>

      <footer className="border-t border-charcoal/15 px-5 py-10 text-sm text-charcoal/65">
        <div className="mx-auto flex max-w-6xl flex-wrap items-start justify-between gap-8">
          <div>
            <Logo markClassName="h-5 w-auto text-brand" wordClassName="text-base" />
            <p className="mt-3 max-w-sm">TSLA-backed USDG lending on Robinhood Chain 46630. The stock price and market clock are set by the operator.</p>
          </div>
          <nav aria-label="Footer" className="flex max-w-xl flex-wrap gap-x-5 gap-y-2 font-medium">
            <Link href="/trade">Trade</Link><Link href="/earn">Earn</Link><Link href="/portfolio">Portfolio</Link><Link href="/operations">Operations</Link><Link href="/evidence">Evidence</Link>
            <a href="https://github.com/4waan/StockReef" target="_blank" rel="noreferrer">GitHub ↗</a>
          </nav>
        </div>
      </footer>
    </div>
  )
}

function Nav() {
  return (
    <header className="sticky top-0 z-20 border-b border-charcoal/10 bg-cream/95 backdrop-blur">
      <div className="mx-auto flex min-h-16 max-w-6xl flex-wrap items-center gap-x-6 gap-y-2 px-5 py-2">
        <Link href="/" aria-label="StockReef home"><Logo markClassName="h-7 w-auto text-charcoal" wordClassName="text-2xl" /></Link>
        <nav aria-label="Page sections" className="order-3 flex w-full flex-wrap gap-x-5 gap-y-1 text-sm font-medium md:order-2 md:ml-auto md:w-auto">
          <a href="#controls" className="hover:text-brand">Risk controls</a>
          <a href="#numbers" className="hover:text-brand">Friday example</a>
          <Link href="/evidence" className="hover:text-brand">Evidence</Link>
        </nav>
        <Link href="/trade" className="order-2 ml-auto rounded-md bg-charcoal px-4 py-2 text-sm font-semibold text-cream hover:bg-black md:order-3 md:ml-0">Open app</Link>
      </div>
    </header>
  )
}

function MarketNow() {
  const { data: m } = useMarketView()
  const state = m ? stateName(m.policy.state) : undefined
  return (
    <section className="bg-[#f1eee5]">
      <div className="mx-auto grid max-w-6xl gap-8 px-5 py-12 lg:grid-cols-[1fr_1.15fr]">
        <div>
          <h2 className="text-sm font-bold uppercase tracking-[0.18em] text-brand">Market now</h2>
          <dl className="mt-5 divide-y divide-charcoal/15 border-y border-charcoal/15">
            <MarketValue label="Session" value={state ? STATE_COPY[state].label : 'Unavailable'} />
            <MarketValue label="TSLA price" value={m && m.valuationPriceWad > 0n ? `${price(m.valuationPriceWad)} USDG` : 'Unavailable'} detail={m?.valuationIndicative ? 'Last accepted price, indicative' : 'Stock price feed'} />
            <MarketValue label="Lender assets" value={m ? `${usdg(m.totalAssets, 0)} USDG` : 'Unavailable'} />
          </dl>
          <p className="mt-4 text-xs text-charcoal/60">Values above are read from the deployed contracts on Robinhood Chain 46630.</p>
        </div>
        <div className="rounded-xl bg-charcoal p-6 text-cream md:p-8">
          <h2 className="text-sm font-bold uppercase tracking-[0.18em] text-[#e4a07a]">Friday example</h2>
          <p className="mt-3 text-xl font-semibold">A funded repayment reduces this loan before the close.</p>
          <div role="img" aria-label="At a 400 USDG TSLA price, a loan moves from 72% loan to value with 7,200 USDG debt to 65% loan to value with 6,500 USDG debt after a 700 USDG borrower repayment." className="mt-7 grid grid-cols-[1fr_auto_1fr] items-center gap-3">
            <div className="rounded-lg border border-cream/20 p-4"><div className="text-xs text-cream/60">Before</div><div className="mt-2 text-4xl font-bold">72%</div><div className="mt-2 text-xs text-cream/60">7,200 USDG debt</div></div>
            <span aria-hidden="true" className="text-2xl text-[#e4a07a]">→</span>
            <div className="rounded-lg border border-[#e4a07a]/60 p-4"><div className="text-xs text-cream/60">After repayment</div><div className="mt-2 text-4xl font-bold text-[#e4a07a]">65%</div><div className="mt-2 text-xs text-cream/60">6,500 USDG debt</div></div>
          </div>
          <p className="mt-4 text-xs text-cream/60">Fixed TSLA price: 400 USDG. Full calculation below.</p>
        </div>
      </div>
    </section>
  )
}

function MarketValue({ label, value, detail }: { label: string; value: string; detail?: string }) {
  return <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-4"><dt className="text-charcoal/65">{label}</dt><dd className="num text-xl font-bold">{value}</dd>{detail && <span className="w-full text-right text-xs text-charcoal/55">{detail}</span>}</div>
}

function Stage({ number, title, children }: { number: string; title: string; children: React.ReactNode }) {
  return <article className="rounded-lg border border-charcoal/15 bg-white p-6"><span className="num text-sm font-bold text-brand">{number}</span><h3 className="mt-4 text-2xl font-bold">{title}</h3><p className="mt-3 leading-relaxed text-charcoal/70">{children}</p></article>
}

function PolicyTable() {
  const { data: k } = useProtocolConstants()
  const f = (v: bigint | undefined) => v === undefined ? 'Unavailable' : pct(v, 0)
  const rows: [string, bigint | undefined, bigint | undefined][] = [
    ['Open-session liquidation threshold', k?.ltOpen, k?.ltOpen],
    ['Threshold 30 minutes before close', k?.ltFinalOvernight, k?.ltFinalExtended],
    ['Target after a full solvent trim', k?.targetOvernight, k?.targetExtended],
    ['Open-session borrow limit', k?.borrowOpen, k?.borrowOpen],
  ]
  return <div className="mt-12 overflow-x-auto"><table className="w-full min-w-[560px] text-left"><thead><tr className="text-sm text-charcoal/60"><th className="py-3 font-medium">Policy from the contract</th><th className="py-3 text-right font-medium">Overnight</th><th className="py-3 text-right font-medium">Weekend or holiday</th></tr></thead><tbody>{rows.map(([label, a, b]) => <tr key={label} className="border-t border-charcoal/15"><td className="py-3">{label}</td><td className="num py-3 text-right font-semibold">{f(a)}</td><td className="num py-3 text-right font-semibold">{f(b)}</td></tr>)}</tbody></table><p className="mt-3 text-sm text-charcoal/60">The longer closure applies when the next scheduled open is at least 24 hours away.</p></div>
}

function Outcome({ title, amount, detail, result }: { title: string; amount: string; detail: string; result: string }) {
  return <article className="bg-charcoal p-6"><h3 className="font-semibold text-[#e4a07a]">{title}</h3><div className="num mt-4 text-3xl font-extrabold">{amount}</div><p className="mt-2 min-h-12 text-sm text-cream/65">{detail}</p><p className="mt-5 border-t border-cream/20 pt-3 text-sm font-semibold">{result}</p></article>
}

function UseCard({ title, body, href, action }: { title: string; body: string; href: string; action: string }) {
  return <article className="flex min-h-60 flex-col rounded-lg border border-charcoal/15 bg-white p-6"><h3 className="text-3xl font-bold">{title}</h3><p className="mt-4 leading-relaxed text-charcoal/70">{body}</p><Link href={href} className="mt-auto pt-6 font-semibold text-brand underline underline-offset-4">{action} ↗</Link></article>
}
