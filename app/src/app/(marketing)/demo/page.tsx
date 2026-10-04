'use client'

import { useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { useAccount, useConnect, useDisconnect } from 'wagmi'
import { Logo } from '@/components/brand/Logo'
import { short } from '@/lib/format'
import { chain, demoAccounts } from '@/lib/chain'

type View = 'trade' | 'earn' | 'portfolio' | 'operations'

const stages = [
  { label: 'Before close', time: 'Fri 15:15 ET', action: 'Show funded repayment' },
  { label: 'Buffer executed', time: 'Fri 15:30 ET', action: 'Close trading' },
  { label: 'Trading closed', time: 'Fri 16:00 ET', action: 'Accept reopening price' },
  { label: 'Reopening recovery', time: 'Mon 09:35 ET', action: 'Finish recovery' },
  { label: 'Credit eligible', time: 'Mon 09:45 ET', action: 'Restart scenario' },
] as const

const fmt = (n: number, digits = 2) => n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
const scenarioClock = (label: string, tick: number) => {
  const match = label.match(/^(\w+) (\d{2}):(\d{2}) ET$/)
  if (!match) return label
  const seconds = (Number(match[2]) * 3600 + Number(match[3]) * 60 + tick * 3) % 86400
  return `${match[1]} ${String(Math.floor(seconds / 3600)).padStart(2, '0')}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')} ET`
}

export default function DemoPage() {
  const [stage, setStage] = useState(0)
  const [view, setView] = useState<View>('trade')
  const [tick, setTick] = useState(0)
  const { address, isConnected } = useAccount()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()

  useEffect(() => {
    const id = window.setInterval(() => setTick(t => t + 1), 3000)
    return () => window.clearInterval(id)
  }, [])

  const basePrice = stage >= 3 ? 370.59 : 400
  const drift = stage === 2 ? 0 : Math.sin(tick * 0.63) * 0.42 + Math.sin(tick * 0.17) * 0.15
  const price = basePrice + drift
  const debt = stage >= 1 ? 65 : 72
  const collateral = 0.25
  const value = collateral * price
  const ltv = debt / value * 100
  const noBufferLtv = 72 / value * 100
  const vaultCash = 85 - debt
  const borrower = demoAccounts.find(a => a.label === 'Borrower')?.address

  const next = () => { setStage(s => s === stages.length - 1 ? 0 : s + 1); setTick(0) }

  return (
    <div className="flex min-h-screen flex-col bg-dk-bg text-dk-ink">
      <header className="border-b border-dk-line">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-4 px-5 py-4">
          <Link href="/" aria-label="StockReef home"><Logo markClassName="h-7 w-auto text-brand" wordClassName="text-2xl" /></Link>
          <span className="rounded border border-brand/60 px-2 py-1 text-xs font-semibold text-[#e4a07a]">Guided scenario</span>
          <nav aria-label="Scenario views" className="order-3 flex w-full gap-1 overflow-x-auto md:order-2 md:ml-6 md:w-auto">
            {(['trade', 'earn', 'portfolio', 'operations'] as const).map(v => <button key={v} type="button" onClick={() => setView(v)} aria-current={view === v ? 'page' : undefined} className={`whitespace-nowrap rounded px-3 py-2 text-sm font-medium ${view === v ? 'bg-dk-raised text-dk-up' : 'text-dk-muted hover:text-dk-ink'}`}>{v === 'earn' ? 'Lend' : v[0].toUpperCase() + v.slice(1)}</button>)}
          </nav>
          <div className="order-2 ml-auto flex items-center gap-3 md:order-3">
            <span className="hidden text-xs text-dk-muted lg:inline">Robinhood Chain testnet</span>
            {isConnected && address ? <button type="button" onClick={() => disconnect()} className="num rounded border border-dk-up px-3 py-2 text-sm text-dk-up" title="Disconnect wallet">{short(address)} ✓</button> : <button type="button" disabled={!connectors.length || isPending} onClick={() => connect({ connector: connectors[0], chainId: chain.id })} className="rounded border border-dk-up px-3 py-2 text-sm text-dk-up disabled:opacity-40">{isPending ? 'Connecting…' : 'Connect MetaMask'}</button>}
          </div>
        </div>
      </header>

      <main className="mx-auto w-full max-w-7xl flex-1 px-5 py-8">
        <div className="mb-7 flex flex-wrap items-center justify-between gap-4">
          <div>
            <p className="num text-xs font-semibold uppercase tracking-[0.18em] text-[#e4a07a]">{scenarioClock(stages[stage].time, tick)} · {stages[stage].label}</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight sm:text-4xl">{view === 'trade' ? 'TSLA-backed credit' : view === 'earn' ? 'USDG lender vault' : view === 'portfolio' ? 'Risk carried through the close' : 'Market controls'}</h1>
          </div>
          <button type="button" onClick={next} className="rounded-md bg-brand px-5 py-3 text-sm font-bold text-white hover:bg-[#a74f23] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand">{stages[stage].action} →</button>
        </div>

        <div className="mb-7 grid gap-2 sm:grid-cols-5" aria-label="Scenario sequence">
          {stages.map((s, i) => <button key={s.label} type="button" onClick={() => { setStage(i); setTick(0) }} aria-current={stage === i ? 'step' : undefined} className={`rounded-md border px-3 py-3 text-left text-sm ${i === stage ? 'border-brand bg-brand/10 text-dk-ink' : i < stage ? 'border-dk-up/40 bg-dk-up/5 text-dk-up' : 'border-dk-line text-dk-muted hover:border-dk-muted'}`}><span className="num mr-2 text-xs">0{i + 1}</span>{s.label}</button>)}
        </div>

        {view === 'trade' && <TradeScene stage={stage} tick={tick} price={price} debt={debt} collateral={collateral} value={value} ltv={ltv} borrower={borrower} />}
        {view === 'earn' && <EarnScene stage={stage} debt={debt} cash={vaultCash} />}
        {view === 'portfolio' && <PortfolioScene stage={stage} debt={debt} value={value} ltv={ltv} noBufferLtv={noBufferLtv} />}
        {view === 'operations' && <OperationsScene stage={stage} borrower={borrower} />}
      </main>

      <footer className="border-t border-dk-line px-5 py-4 text-xs text-dk-muted">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2"><span>Guided scenario: modeled prices and balances. Wallet connection and linked explorer receipts use Robinhood Chain testnet.</span><Link href="/evidence" className="text-dk-up hover:underline">Contract evidence ↗</Link></div>
      </footer>
    </div>
  )
}

function Box({ label, value, detail, tone = '' }: { label: string; value: string; detail?: string; tone?: string }) {
  return <div className="rounded-lg border border-dk-line bg-dk-panel p-5"><div className="text-sm text-dk-muted">{label}</div><div className={`num mt-3 text-3xl font-semibold tracking-tight ${tone}`}>{value}</div>{detail && <div className="mt-2 text-xs text-dk-muted">{detail}</div>}</div>
}

function PriceChart({ stage, tick, price }: { stage: number; tick: number; price: number }) {
  const closed = stage === 2
  const points = useMemo(() => Array.from({ length: 61 }, (_, i) => {
    const minute = i + (closed ? 0 : tick)
    const drift = Math.sin(minute * 0.33) * 0.65 + Math.sin(minute * 0.91) * 0.28 + Math.cos(minute * 0.13) * 0.32
    return price + drift - (Math.sin((60 + (closed ? 0 : tick)) * 0.33) * 0.65 + Math.sin((60 + (closed ? 0 : tick)) * 0.91) * 0.28 + Math.cos((60 + (closed ? 0 : tick)) * 0.13) * 0.32)
  }), [closed, price, tick])
  const min = Math.min(...points) - 0.5
  const max = Math.max(...points) + 0.5
  const path = points.map((v, i) => `${i ? 'L' : 'M'}${(i / 60 * 920).toFixed(1)},${(170 - (v - min) / (max - min) * 135).toFixed(1)}`).join(' ')
  const bars = points.map((_, i) => 7 + Math.abs(Math.sin((i + tick) * 1.71) * 19 + Math.cos(i * 0.43) * 8))
  return <section className="rounded-lg border border-dk-line bg-dk-panel p-5" aria-label="Modeled one-hour TSLA price and volume chart">
    <div className="flex flex-wrap items-start justify-between gap-3"><div><div className="flex items-center gap-2 text-sm text-dk-muted"><img src="https://upload.wikimedia.org/wikipedia/commons/b/bb/Tesla_T_symbol.svg" alt="Tesla" className="h-5 w-5 object-contain" onError={e => { e.currentTarget.style.display = 'none' }} />TSLA / USDG · one-hour price path</div><div className="num mt-1 text-4xl font-semibold">{fmt(price)} <span className="text-lg text-dk-muted">USDG</span></div></div><span className="rounded border border-dk-sim/40 px-2 py-1 text-xs text-dk-sim">Modeled chart</span></div>
    <svg viewBox="0 0 920 240" preserveAspectRatio="none" className="mt-7 h-56 w-full" role="img" aria-label={`Modeled one-hour price path ending at ${fmt(price)} USDG. ${closed ? 'The market is closed and the path is paused.' : 'The scenario path advances every three seconds.'}`}>
      {[35, 80, 125, 170].map(y => <line key={y} x1="0" x2="920" y1={y} y2={y} stroke="#30343a" strokeWidth="1" />)}
      <path d={`${path} L920,171 L0,171 Z`} fill="#3ecf8e" fillOpacity=".08" />
      <path d={path} fill="none" stroke="#3ecf8e" strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
      {bars.map((h, i) => <rect key={i} x={i * 15.1} y={236 - h} width="6" height={h} fill="#c56430" fillOpacity=".38" />)}
    </svg>
    <div className="flex justify-between text-xs text-dk-muted"><span>60 minutes ago</span><span>{closed ? 'Last accepted before close' : 'Scenario clock moving'} · modeled volume{stage >= 3 ? ' · 2 Oct close reference' : ''}</span><span>Now</span></div>
  </section>
}

function TradeScene({ stage, tick, price, debt, collateral, value, ltv, borrower }: { stage: number; tick: number; price: number; debt: number; collateral: number; value: number; ltv: number; borrower?: string }) {
  const closed = stage === 2
  const credit = stage === 4
  return <div className="grid gap-5 lg:grid-cols-[minmax(0,1.5fr)_minmax(300px,1fr)]"><div className="space-y-5"><PriceChart stage={stage} tick={tick} price={price} /><div className="grid gap-3 sm:grid-cols-3"><Box label="Collateral" value={`${fmt(collateral)} TSLA`} detail={`${fmt(value)} USDG at scenario price`} /><Box label="Debt" value={`${fmt(debt)} USDG`} detail={stage >= 1 ? '7 USDG buffer applied' : '7 USDG buffer funded'} /><Box label="Loan to value" value={`${fmt(ltv, 1)}%`} tone={stage >= 3 ? 'text-dk-warn' : 'text-dk-up'} detail={stage >= 3 ? 'Reopening price scenario' : 'Fixed 400 USDG price'} /></div></div><div className="space-y-5"><section className="rounded-lg border border-dk-line bg-dk-panel p-6"><div className="flex items-center justify-between"><h2 className="text-xl font-semibold">Borrower actions</h2><span className={`text-xs font-bold ${closed ? 'text-dk-warn' : 'text-dk-up'}`}>{closed ? 'CLOSED' : stage === 3 ? 'RECOVERY' : 'OPEN'}</span></div><div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-1"><Action label="Borrow USDG" active={credit} /><Action label="Withdraw TSLA" active={credit} /><Action label="Repay USDG" active /><Action label="Add TSLA" active /></div><div className="mt-6 border-t border-dk-line pt-5"><div className="flex justify-between text-sm"><span className="text-dk-muted">Borrower funded buffer</span><span className="num text-dk-up">{stage >= 1 ? '7 USDG repaid' : '7 USDG ready'}</span></div><div className="mt-3 h-2 rounded-full bg-dk-raised"><div className="h-2 rounded-full bg-dk-up transition-all duration-700" style={{ width: stage >= 1 ? '100%' : '48%' }} /></div></div></section><div className="rounded-lg border border-brand/40 bg-brand/5 p-5 text-sm text-dk-muted">{stage === 0 ? 'The funded buffer executes before an eligible liquidator trim.' : stage === 1 ? 'The borrower kept 0.25 TSLA while debt fell by 7 USDG.' : stage === 2 ? 'Repayment and TSLA deposits remain available during closure.' : stage === 3 ? 'Eligible recovery trims can be submitted before new credit returns.' : 'New credit is eligible after price admission and recovery.'}</div>{borrower && <Link href={`/trade?account=${borrower}`} className="inline-block text-sm font-semibold text-dk-up hover:underline">Open live borrower view ↗</Link>}</div></div>
}

function Action({ label, active }: { label: string; active: boolean }) {
  return <div className={`flex items-center justify-between rounded-md border px-4 py-3 text-sm font-medium ${active ? 'border-dk-up/40 bg-dk-up/5 text-dk-up' : 'border-dk-line bg-dk-raised text-dk-faint'}`}><span>{label}</span><span aria-hidden="true">{active ? '↗' : '×'}</span></div>
}

function EarnScene({ stage, debt, cash }: { stage: number; debt: number; cash: number }) {
  const open = stage === 4
  return <div className="grid gap-5 lg:grid-cols-[minmax(0,1.4fr)_minmax(300px,1fr)]"><section className="rounded-lg border border-dk-line bg-dk-panel p-6"><div className="flex items-center justify-between"><h2 className="text-xl font-semibold">The lender book</h2><span className={open ? 'text-sm text-dk-up' : 'text-sm text-dk-warn'}>{open ? 'Lending window open' : 'Lending window closed'}</span></div><div className="mt-7 grid gap-3 sm:grid-cols-3"><Box label="Lender assets" value="85.00 USDG" detail="Cash plus recoverable loans" /><Box label="Available cash" value={`${fmt(cash)} USDG`} detail={stage >= 1 ? '+7 from funded repayment' : '85 deposited, 72 borrowed'} /><Box label="Loans outstanding" value={`${fmt(debt)} USDG`} detail={stage >= 1 ? 'Debt fell by 7' : 'One TSLA-backed borrower'} /></div><div className="mt-8"><div className="flex justify-between text-sm text-dk-muted"><span>Vault composition</span><span className="num">{fmt(debt / 85 * 100, 1)}% deployed</span></div><div className="mt-3 flex h-4 overflow-hidden rounded-full bg-dk-raised"><div className="bg-dk-up transition-all duration-700" style={{ width: `${cash / 85 * 100}%` }} /><div className="bg-brand transition-all duration-700" style={{ width: `${debt / 85 * 100}%` }} /></div><div className="mt-3 flex gap-6 text-xs text-dk-muted"><span><b className="text-dk-up">●</b> Available USDG</span><span><b className="text-brand">●</b> Recoverable loans</span></div></div></section><section className="rounded-lg border border-dk-line bg-dk-panel p-6"><h2 className="text-xl font-semibold">Lender position</h2><div className="num mt-8 text-5xl font-semibold">85.00 <span className="text-xl text-dk-muted">USDG</span></div><p className="mt-3 text-sm text-dk-muted">The buffer repayment moves 7 USDG from outstanding debt into vault cash. Total lender assets stay 85 USDG in this fixed-price scenario.</p><div className="mt-8 grid grid-cols-2 gap-3"><Action label="Deposit" active={open} /><Action label="Withdraw" active={open} /></div><Link href="/earn" className="mt-6 inline-block text-sm font-semibold text-dk-up hover:underline">Open live lender view ↗</Link></section></div>
}

function PortfolioScene({ stage, debt, value, ltv, noBufferLtv }: { stage: number; debt: number; value: number; ltv: number; noBufferLtv: number }) {
  return <div className="space-y-5"><div className="grid gap-3 md:grid-cols-4"><Box label="Debt carried" value={`${fmt(debt)} USDG`} detail={stage >= 1 ? '7 USDG repaid before close' : 'Before buffer execution'} /><Box label="TSLA kept" value="0.25 TSLA" detail={`${fmt(value)} USDG at scenario price`} /><Box label="LTV now" value={`${fmt(ltv, 1)}%`} tone="text-dk-up" detail="Debt divided by collateral value" /><Box label="Without the buffer" value={`${fmt(noBufferLtv, 1)}%`} tone={stage >= 3 ? 'text-dk-warn' : ''} detail="Same price and collateral, 72 USDG debt" /></div><div className="grid gap-5 lg:grid-cols-[1.2fr_1fr]"><section className="rounded-lg border border-dk-line bg-dk-panel p-6"><h2 className="text-xl font-semibold">What the control changed</h2><div className="mt-7 space-y-5"><Comparison label="Debt before the close" before="72 USDG" after={stage >= 1 ? '65 USDG' : '72 USDG'} /><Comparison label="Borrower TSLA held" before="0.25 TSLA" after="0.25 TSLA" /><Comparison label="LTV at reopening price" before={stage >= 3 ? `${fmt(noBufferLtv, 1)}%` : 'Pending'} after={stage >= 3 ? `${fmt(ltv, 1)}%` : 'Pending'} /></div></section><section className="rounded-lg border border-dk-line bg-dk-panel p-6"><h2 className="text-xl font-semibold">Scenario history</h2><ol className="mt-7 space-y-5 text-sm"><li className="flex justify-between gap-3"><span>USDG lent; TSLA posted</span><span className="num text-dk-muted">85 / 0.25</span></li><li className="flex justify-between gap-3 border-t border-dk-line pt-5"><span>Borrowed against TSLA</span><span className="num text-dk-muted">72 USDG</span></li>{stage >= 1 && <li className="flex justify-between gap-3 border-t border-dk-line pt-5"><span>Funded buffer applied</span><span className="num text-dk-up">7 USDG</span></li>}{stage >= 2 && <li className="flex justify-between gap-3 border-t border-dk-line pt-5"><span>New credit locked</span><span className="text-dk-warn">Closed</span></li>}{stage >= 3 && <li className="flex justify-between gap-3 border-t border-dk-line pt-5"><span>Reopening price scenario</span><span className="num text-dk-up">{fmt(value / 0.25)}</span></li>}</ol><p className="mt-6 border-t border-dk-line pt-4 text-xs text-dk-muted">Modeled sequence. Confirmed transactions are shown in the live app and Evidence.</p></section></div></div>
}

function Comparison({ label, before, after }: { label: string; before: string; after: string }) {
  return <div><div className="text-sm text-dk-muted">{label}</div><div className="num mt-2 flex items-center gap-4 text-xl font-semibold"><span className="text-dk-faint">{before}</span><span className="text-brand">→</span><span className="text-dk-up">{after}</span></div></div>
}

function OperationsScene({ stage, borrower }: { stage: number; borrower?: string }) {
  return <div className="grid gap-5 lg:grid-cols-3"><Box label="Session" value={stages[stage].label} tone={stage === 2 || stage === 3 ? 'text-dk-warn' : 'text-dk-up'} detail={stages[stage].time} /><Box label="Funded repayment" value={stage === 0 ? '7 USDG ready' : '7 USDG applied'} tone="text-dk-up" detail="Authorized borrower USDG executes first" /><Box label="New credit" value={stage === 4 ? 'Eligible' : stage === 0 ? 'Restricted' : 'Locked'} tone={stage === 4 ? 'text-dk-up' : 'text-dk-warn'} detail={stage === 3 ? 'Recovery interval in progress' : 'Subject to contract checks'} /><section className="rounded-lg border border-dk-line bg-dk-panel p-6 lg:col-span-2"><h2 className="text-xl font-semibold">Action order</h2><div className="mt-6 grid gap-3 sm:grid-cols-3"><Action label="Funded buffer first" active={stage === 0} /><Action label="Eligible partial trim" active={stage === 3} /><Action label="Fresh price before credit" active={stage >= 3} /></div><p className="mt-6 text-sm text-dk-muted">A buffer or trim changes real debt only when a transaction is submitted and confirmed. The controls here advance a modeled presentation.</p></section><section className="rounded-lg border border-brand/40 bg-brand/5 p-6"><h2 className="text-xl font-semibold">Real contract action</h2><p className="mt-4 text-sm text-dk-muted">The public borrower has a funded buffer on Robinhood Chain testnet. Open the live view when the contract reports it executable, connect MetaMask, and sign the transaction.</p>{borrower && <Link href={`/trade?account=${borrower}`} className="mt-6 inline-block rounded-md border border-dk-up px-4 py-2 text-sm font-semibold text-dk-up hover:bg-dk-up/10">Open live buffer action ↗</Link>}</section></div>
}
