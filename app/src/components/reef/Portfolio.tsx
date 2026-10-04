'use client'

import Link from 'next/link'
import { useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { chain, contracts, demoAccounts } from '@/lib/chain'
import { useDesk } from '@/lib/desk'
import { nyClock, pct, tokens, usdg } from '@/lib/format'
import { exceeds } from '@/lib/scenario'
import { useBook } from '@/lib/session'
import { ClosedProtection, ControlledReopening, DebtReduction, FallingThreshold, Fig, FundedBuffer, LenderLoss, PartialLiquidation, PositionMeter } from './features'
import { StateChange } from './Terminal'
import { Info, Loading, PhaseTag, Status } from './ui'

/** The portfolio: one account's position health, then each StockReef control as it applies to it at this step. */
export function PortfolioPage() {
  const d = useDesk()
  const { data: book } = useBook()
  const { data: haircut } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'RECOVERY_HAIRCUT', chainId: chain.id, query: { enabled: !!contracts, staleTime: Infinity } })
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (!d.viewing)
    return (
      <div className="flex gap-2 px-5 py-10">
        {demoAccounts.map(a => (
          <button key={a.address} type="button" onClick={() => d.pick(a.address)} className="rounded-md border border-dk-line px-3 py-1.5 text-sm hover:border-dk-muted">
            {a.label}
          </button>
        ))}
      </div>
    )
  if (d.error) return <Loading>Could not read the scenario: {d.error}</Loading>
  if (!d.current || !d.policy || !d.steps || !d.position) return <Loading />
  const p = d.position
  const cur = d.current
  const s = cur.snapshot
  const above = exceeds(p.debt, p.value, s.ltWad)
  const health = p.debt ? Number(s.ltWad) / Number(p.ltvWad) : undefined
  return (
    <div className="w-full space-y-3 px-4 py-4 xl:px-6">
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-semibold">Portfolio</h1>
        <span className="text-sm text-dk-muted">{d.label}</span>
        <PhaseTag state={s.state} />
        <span className="num text-sm text-dk-muted">
          {cur.step.day === 'mon' ? 'Mon' : 'Fri'} {nyClock(cur.t)} ET
        </span>
        <Link href="/trade" className="ml-auto rounded-md bg-brand px-3 py-1.5 text-sm font-semibold text-white hover:bg-[#d36f39]">
          Trade
        </Link>
      </div>

      <section className="grid gap-3 lg:grid-cols-[1.6fr_1fr]">
        <div className="rounded-lg border border-dk-line bg-dk-panel px-4 pt-3 pb-1">
          <div className="flex items-center gap-2">
            <span className="text-[11px] font-semibold tracking-[.12em] text-accent uppercase">Position health</span>
            <Info label="About position health">Health = threshold ÷ LTV. Below 1.00 the loan can be trimmed. The dashed marks are the closure target and the threshold the loan must clear at the close.</Info>
            <span className="ml-auto">
              <Status tone={above ? 'down' : p.ltvWad > p.planTargetWad ? 'warn' : 'up'}>{health ? `Health ${health.toFixed(2)}` : 'No debt'}</Status>
            </span>
          </div>
          <div className="mt-2 grid grid-cols-4 gap-3">
            <Fig k="Collateral" v={usdg(p.value)} sub={`${tokens(p.collateral, 4)} TSLA${cur.indicative ? ' · ind.' : ''}`} />
            <Fig k="Debt" v={usdg(p.debt)} sub="USDG" />
            <Fig k="LTV" v={p.debt ? pct(p.ltvWad, 2) : '—'} tone={above ? 'down' : p.ltvWad > p.planTargetWad ? 'warn' : 'up'} sub={`threshold ${pct(s.ltWad, 1)}`} />
            <Fig k="Wallet" v={usdg(p.wallet.usdg)} sub={`USDG · ${tokens(p.wallet.tsla, 2)} TSLA`} />
          </div>
          <PositionMeter p={p} cur={cur} pol={d.policy} />
        </div>
        <div className="rounded-lg border border-dk-line bg-dk-panel">
          <StateChange items={d.items} />
          {!d.items.length && <p className="px-4 py-3 text-sm text-dk-muted">No transactions yet.</p>}
        </div>
      </section>

      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        <DebtReduction p={p} cur={cur} />
        <FallingThreshold p={p} cur={cur} pol={d.policy} ltPath={d.ltPath} steps={d.steps} />
        <FundedBuffer p={p} cur={cur} items={d.items} />
        <PartialLiquidation p={p} cur={cur} />
        <ClosedProtection cur={cur} />
        <ControlledReopening cur={cur} steps={d.steps} />
      </div>
      {book && haircut !== undefined && <LenderLoss book={book} cur={cur} haircut={haircut as bigint} />}
    </div>
  )
}
