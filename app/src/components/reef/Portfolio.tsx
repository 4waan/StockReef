'use client'

import Link from 'next/link'
import { chain, contracts, demoAccounts } from '@/lib/chain'
import { useDesk } from '@/lib/desk'
import { nyClock, pct, tokens, usdg } from '@/lib/format'
import { MARKET } from '@/lib/script'
import { exceeds } from '@/lib/scenario'
import { useBook } from '@/lib/session'
import { useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { ClosedProtection, ControlledReopening, DebtReduction, FallingThreshold, FundedBuffer, LenderLoss, PartialLiquidation, PositionMeter } from './features'
import { Card, Loading, PhaseTag, Stat, Status, TxRef } from './ui'

/**
 * The portfolio: one account's position and how each StockReef control applies to it at the current step.
 * A dashboard that ties debt to position health, with every figure from the contracts at the scenario step.
 */
export function PortfolioPage() {
  const d = useDesk()
  const { data: book } = useBook()
  const { data: haircut } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'RECOVERY_HAIRCUT', chainId: chain.id, query: { enabled: !!contracts, staleTime: Infinity } })
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (!d.viewing)
    return (
      <div className="px-5 py-10">
        <p className="text-dk-muted">Connect a wallet, or open a public profile:</p>
        <div className="mt-4 flex gap-2">
          {demoAccounts.map(a => (
            <button key={a.address} type="button" onClick={() => d.pick(a.address)} className="rounded-md border border-dk-line px-3 py-1.5 text-sm hover:border-dk-muted">
              {a.label}
            </button>
          ))}
        </div>
      </div>
    )
  if (d.error) return <Loading>Could not read the scenario: {d.error}</Loading>
  if (!d.current || !d.policy || !d.steps || !d.position) return <Loading />
  const p = d.position
  const cur = d.current
  const s = cur.snapshot
  const above = exceeds(p.debt, p.value, s.ltWad)
  const health = p.debt ? Number(s.ltWad) / Number(p.ltvWad) : undefined
  const net = p.value - p.debt
  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 px-4 py-5">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="text-xs text-dk-muted">Portfolio · {d.label}</div>
          <h1 className="mt-1 text-2xl font-semibold">Your TSLA-backed loan at {cur.step.day === 'mon' ? 'Monday' : 'Friday'} {nyClock(cur.t)} ET</h1>
        </div>
        <div className="flex items-center gap-3">
          <PhaseTag state={s.state} />
          <Link href="/trade" className="rounded-md bg-brand px-3 py-1.5 text-sm font-semibold text-white hover:bg-[#d36f39]">
            Open terminal
          </Link>
        </div>
      </div>

      <section className="grid gap-4 lg:grid-cols-[1.3fr_1fr]">
        <Card kicker="Position health" title={above ? 'Above the liquidation threshold' : p.ltvWad > p.planTargetWad ? 'Healthy now, above the closure plan' : 'Healthy and on plan'} aside={<Status tone={above ? 'down' : p.ltvWad > p.planTargetWad ? 'warn' : 'up'}>{health ? `Health ${health.toFixed(2)}` : 'No debt'}</Status>}>
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <Stat size="lg" label="Collateral value" value={`${usdg(p.value)}`} sub={`${tokens(p.collateral, 4)} TSLA${cur.indicative ? ' · indicative' : ''}`} />
            <Stat size="lg" label="Debt" value={`${usdg(p.debt)}`} sub="USDG, interest included" />
            <Stat size="lg" label="LTV" value={p.debt ? pct(p.ltvWad, 2) : '—'} tone={above ? 'down' : p.ltvWad > p.planTargetWad ? 'warn' : 'up'} sub={`threshold ${pct(s.ltWad, 2)}`} />
            <Stat size="lg" label="Net value" value={`${usdg(net)}`} sub="collateral − debt, USDG" />
          </div>
          <PositionMeter p={p} cur={cur} pol={d.policy} />
          <p className="text-xs text-dk-faint">Health = threshold ÷ LTV; below 1.00 the loan can be trimmed. The dashed marks show the closure target and the threshold the loan must clear at the close.</p>
        </Card>
        <Card kicker="Wallet and history" title="Balances and confirmed transactions">
          <div className="grid grid-cols-3 gap-4">
            <Stat label="USDG wallet" value={usdg(p.wallet.usdg)} />
            <Stat label="TSLA wallet" value={tokens(p.wallet.tsla, 4)} />
            <Stat label="Buffer escrow" value={usdg(p.plan.balance)} />
          </div>
          <ul className="mt-4 max-h-44 space-y-1.5 overflow-y-auto text-sm">
            {d.items.slice(0, 8).map(e => (
              <li key={e.hash + e.logIndex} className="num flex justify-between gap-3 border-b border-dk-line/60 pb-1.5">
                <span>
                  {e.kind} <span className="text-dk-muted">{e.unit === 'USDG' ? `${usdg(e.amount)} USDG` : e.unit === 'TSLA' ? `${tokens(e.amount, 4)} TSLA` : ''}</span>
                </span>
                <TxRef hash={e.hash} />
              </li>
            ))}
            {!d.items.length && <li className="text-dk-muted">No transactions yet.</li>}
          </ul>
        </Card>
      </section>

      <div className="grid gap-4 lg:grid-cols-2">
        <DebtReduction p={p} cur={cur} steps={d.steps} />
        <FallingThreshold p={p} cur={cur} pol={d.policy} ltPath={d.ltPath} steps={d.steps} />
        <FundedBuffer p={p} cur={cur} items={d.items} />
        <PartialLiquidation p={p} cur={cur} />
        <ClosedProtection cur={cur} p={p} />
        <ControlledReopening cur={cur} steps={d.steps} />
      </div>
      {book && haircut !== undefined && <LenderLoss book={book} cur={cur} haircut={haircut as bigint} />}
      <p className="pb-2 text-xs text-dk-faint">
        {MARKET.pair}: scripted time and price; every balance, limit, amount and receipt from the {chain.name} contracts.
      </p>
    </div>
  )
}
