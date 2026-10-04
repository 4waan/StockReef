'use client'

import { useEffect, useRef, useState, type ReactNode } from 'react'

const finalSteps = [5, 2, 3] as const

function useScene(index: 0 | 1 | 2) {
  const ref = useRef<HTMLElement>(null)
  const [step, setStep] = useState(0)

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches || !('IntersectionObserver' in window)) {
      setStep(finalSteps[index])
      return
    }
    const timers: number[] = []
    let started = false
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting || started) return
      started = true
      observer.disconnect()
      const stagger = window.innerWidth >= 1024 ? index * 350 : 0
      for (let next = 1; next <= finalSteps[index]; next++) {
        timers.push(window.setTimeout(() => setStep(next), stagger + next * 800))
      }
    }, { threshold: 0.4 })
    if (ref.current) observer.observe(ref.current)
    return () => {
      observer.disconnect()
      timers.forEach(window.clearTimeout)
    }
  }, [index])

  return { ref, step }
}

function SceneCard({ index, title, summary, children }: { index: 0 | 1 | 2; title: string; summary: string; children: (step: number) => ReactNode }) {
  const { ref, step } = useScene(index)
  return (
    <article ref={ref} className="flex min-w-0 flex-col rounded-xl border border-charcoal/15 bg-white p-4 shadow-sm sm:p-5">
      <div className="mb-4 flex items-center justify-between gap-3">
        <h3 className="text-lg font-bold text-charcoal"><span aria-hidden="true" className="num mr-2 text-sm text-brand">0{index + 1}</span>{title}</h3>
        <span aria-hidden="true" className="h-2 w-2 rounded-full bg-brand" />
      </div>
      <p className="sr-only">{summary}</p>
      <div aria-hidden="true" className="flex min-h-[340px] flex-1 flex-col overflow-hidden rounded-lg border border-dk-line bg-dk-bg text-dk-ink shadow-inner">
        {children(step)}
      </div>
    </article>
  )
}

function ScreenBar({ view, status, tone = 'text-dk-up' }: { view: string; status: string; tone?: string }) {
  return <div className="flex items-center justify-between gap-2 border-b border-dk-line bg-dk-panel px-4 py-3 text-[11px] font-semibold tracking-wide"><span><span className="text-brand">◈</span> StockReef <span className="ml-1 font-normal text-dk-muted">/ {view}</span></span><span className={`num ${tone}`}>{status}</span></div>
}

function TinyMetric({ label, value, active, tone = 'text-dk-ink' }: { label: string; value: string; active: boolean; tone?: string }) {
  return <div className={`min-w-0 rounded border border-dk-line bg-dk-raised px-2 py-3 transition-all duration-500 ${active ? 'opacity-100' : 'opacity-30'}`}><span className="block text-[10px] uppercase tracking-wide text-dk-muted">{label}</span><span className={`num mt-1 block whitespace-nowrap text-[13px] font-bold ${tone}`}>{value}</span></div>
}

function BeforeClose({ step }: { step: number }) {
  const repaid = step >= 5
  return <>
    <ScreenBar view="Trade" status="PREP" tone="text-dk-warn" />
    <div className="flex flex-1 flex-col p-4">
      <div className="grid grid-cols-3 gap-2">
        <TinyMetric label="Lender vault" value="85 USDG" active={step >= 1} tone="text-dk-up" />
        <TinyMetric label="Collateral" value="0.25 TSLA" active={step >= 2} />
        <TinyMetric label="Borrowed" value="72 USDG" active={step >= 3} />
      </div>
      <div className="mt-5 flex items-end justify-between gap-2">
        <div><span className="text-[11px] uppercase tracking-wide text-dk-muted">Loan LTV</span><div className={`num mt-1 text-5xl font-bold leading-none transition-all duration-700 ${step < 3 ? 'opacity-30' : 'opacity-100'} ${repaid ? 'text-dk-up' : 'text-dk-warn'}`}>{repaid ? '65%' : '72%'}</div></div>
        <div className={`num rounded border px-2 py-1 text-xs font-semibold transition-all duration-500 ${step >= 4 ? 'border-dk-up text-dk-up opacity-100' : 'border-dk-line text-dk-muted opacity-40'}`}>7 USDG BUFFER</div>
      </div>
      <div className="mt-4 h-2 overflow-hidden rounded-full bg-dk-raised"><div className={`h-full rounded-full transition-all duration-700 ${repaid ? 'bg-dk-up' : 'bg-dk-warn'}`} style={{ width: repaid ? '65%' : '72%' }} /></div>
      <div className="mt-3 flex items-center justify-between text-xs"><span className="text-dk-muted">Debt</span><span className={`num font-semibold transition-colors duration-700 ${repaid ? 'text-dk-up' : 'text-dk-ink'}`}>{repaid ? '65 USDG' : '72 USDG'}</span></div>
      <div className="mt-auto flex items-center justify-between gap-2 border-t border-dk-line pt-3 text-[10px] font-semibold tracking-wide"><span className={step >= 4 ? 'text-dk-up' : 'text-dk-muted'}>BUFFER FIRST</span><span className="text-dk-faint">┄┄</span><span className="text-dk-warn">TRIM IF ELIGIBLE</span></div>
    </div>
  </>
}

function ActionTile({ label, active, locked }: { label: string; active: boolean; locked?: boolean }) {
  return <div className={`flex min-h-14 items-center justify-between gap-2 rounded border px-3 text-xs font-semibold transition-all duration-700 ${locked ? 'border-dk-line bg-dk-panel text-dk-faint' : active ? 'border-dk-up/60 bg-dk-up/10 text-dk-up' : 'border-dk-line bg-dk-raised text-dk-ink'}`}><span>{label}</span><span className="text-base" aria-hidden="true">{locked ? '×' : active ? '↗' : '·'}</span></div>
}

function TradingClosed({ step }: { step: number }) {
  const closed = step >= 1
  return <>
    <ScreenBar view="Trade" status={closed ? 'CLOSED' : 'OPEN'} tone={closed ? 'text-dk-warn' : 'text-dk-up'} />
    <div className="flex flex-1 flex-col p-4">
      <div className="flex items-center justify-between border-b border-dk-line pb-3"><span className="text-xs text-dk-muted">TSLA / USDG</span><span className={`num text-sm font-semibold ${closed ? 'text-dk-warn' : 'text-dk-up'}`}>{closed ? 'MARKET CLOSED' : 'MARKET OPEN'}</span></div>
      <div className="mt-5 grid grid-cols-2 gap-2"><ActionTile label="Borrow USDG" active={!closed} locked={closed} /><ActionTile label="Withdraw TSLA" active={!closed} locked={closed} /><ActionTile label="Repay USDG" active={step >= 2} /><ActionTile label="Add TSLA" active={step >= 2} /></div>
      <div className="mt-auto border-t border-dk-line pt-4"><div className="flex justify-between text-[11px] text-dk-muted"><span>New credit</span><span className={closed ? 'text-dk-warn' : 'text-dk-up'}>{closed ? 'LOCKED' : 'AVAILABLE'}</span></div><div className="mt-2 h-1.5 rounded-full bg-dk-raised"><div className={`h-full rounded-full transition-all duration-700 ${closed ? 'w-0 bg-dk-warn' : 'w-full bg-dk-up'}`} /></div></div>
    </div>
  </>
}

function Reopening({ step }: { step: number }) {
  const admitted = step >= 1
  const recovered = step >= 3
  return <>
    <ScreenBar view="Operations" status={recovered ? 'OPEN' : admitted ? 'RECOVERY' : 'REOPEN WAIT'} tone={recovered ? 'text-dk-up' : 'text-dk-warn'} />
    <div className="flex flex-1 flex-col p-4">
      <div className="text-[11px] uppercase tracking-wide text-dk-muted">TSLA price</div>
      <div className={`num mt-1 text-4xl font-bold transition-colors duration-700 ${admitted ? 'text-dk-ink' : 'text-dk-faint'}`}>{admitted ? '400 USDG' : 'Pending'}</div>
      <div className={`mt-2 text-xs font-semibold transition-opacity duration-500 ${admitted ? 'text-dk-up opacity-100' : 'text-dk-muted opacity-40'}`}>● FRESH PRICE ACCEPTED</div>
      <div className="mt-6 flex items-center justify-between text-[11px]"><span className="text-dk-muted">Recovery</span><span className={recovered ? 'text-dk-up' : 'text-dk-warn'}>{recovered ? 'COMPLETE' : admitted ? 'IN PROGRESS' : 'WAITING'}</span></div>
      <div className="mt-2 h-2 overflow-hidden rounded-full bg-dk-raised"><div className="h-full rounded-full bg-dk-up transition-[width] duration-1000" style={{ width: recovered ? '100%' : step >= 2 ? '62%' : '0%' }} /></div>
      <div className={`mt-4 flex items-center justify-between rounded border px-3 py-2 text-[11px] font-semibold transition-all duration-500 ${admitted && !recovered ? 'border-dk-up/60 text-dk-up opacity-100' : 'border-dk-line text-dk-faint opacity-60'}`}><span>RECOVERY TRIM</span><span>{recovered ? 'WINDOW ENDED' : 'TX REQUIRED'}</span></div>
      <div className={`mt-auto rounded border px-3 py-3 text-center text-sm font-bold transition-all duration-700 ${recovered ? 'border-dk-up bg-dk-up/10 text-dk-up' : 'border-dk-line bg-dk-raised text-dk-faint'}`}>{recovered ? 'NEW CREDIT ELIGIBLE' : 'NEW CREDIT LOCKED'}</div>
    </div>
  </>
}

export function RiskScenes() {
  return <div className="mt-10 grid gap-4 lg:grid-cols-3">
    <SceneCard index={0} title="Before close" summary="A lender deposits 85 USDG. A borrower posts 0.25 TSLA and borrows 72 USDG. A funded 7 USDG buffer executes first, reducing debt to 65 USDG and loan to value from 72% to 65%. A liquidator trim is an alternate action only if debt remains eligible.">{step => <BeforeClose step={step} />}</SceneCard>
    <SceneCard index={1} title="Trading closed" summary="When trading closes, new borrowing and debt-backed TSLA withdrawals lock. Manual USDG repayment and TSLA deposits stay available.">{step => <TradingClosed step={step} />}</SceneCard>
    <SceneCard index={2} title="Reopening" summary="A fresh 400 USDG TSLA price is accepted. A liquidator can submit an eligible recovery trim. After the recovery interval, new credit becomes eligible if the market remains open and the lender book is unimpaired.">{step => <Reopening step={step} />}</SceneCard>
  </div>
}
