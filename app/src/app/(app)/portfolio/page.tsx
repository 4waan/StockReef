'use client'

import Link from 'next/link'
import { formatUnits } from 'viem'
import { useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { BottomTabs } from '@/components/terminal/BottomTabs'
import { Metric, Panel } from '@/components/terminal/kit'
import { chain, contracts, demoAccounts, ZERO } from '@/lib/chain'
import { nyTime, pct, tokens, usdg } from '@/lib/format'
import { useHistory } from '@/lib/history'
import { useAccountView, useMarketView, useTokenBalance } from '@/lib/hooks'
import { abovePlan } from '@/lib/policy'
import { useViewing } from '@/lib/viewing'

export default function PortfolioPage() {
  const { viewing, own, label, pick } = useViewing()
  const { data: m } = useMarketView()
  const { data: v } = useAccountView(viewing)
  const { data: history } = useHistory(viewing, v?.collateral)
  const { data: usdgWallet } = useTokenBalance(contracts?.loanToken, viewing)
  const { data: tslaWallet } = useTokenBalance(contracts?.collateralToken, viewing)
  const { data: shares } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'balanceOf',
    args: [viewing ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!contracts && !!viewing, refetchInterval: 2_000 },
  })
  const { data: lent } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'convertToAssets',
    args: [shares ?? 0n],
    chainId: chain.id,
    query: { enabled: !!contracts && shares !== undefined, refetchInterval: 2_000 },
  })

  if (!contracts) return <p className="px-5 py-10 text-dk-muted">No StockReef deployment is configured for {chain.name} yet.</p>
  if (!viewing)
    return (
      <div className="px-5 py-10">
        <p className="text-dk-muted">Connect a wallet to see your portfolio{demoAccounts.length > 0 && ', or open a demo account'}.</p>
        <div className="mt-4 flex flex-wrap gap-2">
          {demoAccounts.map(d => (
            <button key={d.address} type="button" onClick={() => pick(d.address)} className="rounded-md border border-dk-line px-3 py-1.5 text-sm hover:border-dk-muted">
              {d.label}
            </button>
          ))}
        </div>
      </div>
    )
  if (!m || !v) return <p className="px-5 py-10 text-dk-muted">Reading the account…</p>

  const s = m.policy
  const items = history?.items ?? []
  // Principal moved by the account's own events since deployment; whatever debt is above it is interest.
  const principal = items.reduce((sum, i) => {
    if (i.kind === 'Borrowed') return sum + i.amount
    if (i.kind === 'Repaid' || i.kind === 'Repaid from buffer' || i.kind === 'Buffer repaid' || i.kind === 'Trimmed' || i.kind === 'Written off') return sum - i.amount
    return sum
  }, 0n)
  const interest = v.debt > principal && principal > 0n ? v.debt - principal : 0n
  const hasLoan = v.debt > 0n || v.collateral > 0n
  const p = v.plan

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex h-10 items-center gap-4 overflow-x-auto border-b border-dk-line px-5 text-[15px] whitespace-nowrap">
        <span className="font-semibold">Portfolio</span>
        <span className="h-4 w-px bg-dk-line" />
        <span className="num text-dk-muted">
          {label}
          {!own && ' · read only'}
        </span>
        <Link href="/trade" className="ml-auto text-dk-up hover:underline">
          Open in Trade →
        </Link>
      </div>

      <div className="grid lg:grid-cols-3">
        <Panel title="Loan" className="lg:border-r">
          {hasLoan ? (
            <div className="grid grid-cols-2 gap-x-6 gap-y-4">
              <Metric big label="Debt" value={`${usdg(v.debt)} USDG`} sub="including interest" />
              <Metric
                big
                label="LTV"
                value={v.debt > 0n ? pct(v.ltvWad, 1) : '—'}
                tone={v.debt === 0n ? '' : v.ltvWad > s.ltWad ? 'text-dk-down' : abovePlan(v.repayToTarget) ? 'text-dk-warn' : 'text-dk-up'}
              />
              <Metric label="Collateral" value={`${tokens(v.collateral)} TSLA`} sub={`${usdg(v.collateralValue)} USDG`} />
              <Metric label="Threshold now" value={pct(s.ltWad, 1)} tone="text-dk-warn" sub={`plan ${pct(v.planTargetWad, 0)}`} />
              <Metric label="Interest accrued" value={`${usdg(interest)} USDG`} sub="debt above net principal borrowed" />
              <Metric label="Can borrow now" value={`${usdg(v.borrowCapacity)} USDG`} />
            </div>
          ) : (
            <p className="text-dk-muted">No loan.</p>
          )}
          {v.missedExecution && <p className="mt-3 text-sm text-dk-down">Missed execution: {usdg(v.exposure)} USDG exposed at the indicative valuation.</p>}
        </Panel>

        <Panel title="Buffer" className="lg:border-r" aside={<span className={`text-sm ${v.bufferCommitted ? 'text-dk-warn' : v.bufferActive ? 'text-dk-up' : 'text-dk-muted'}`}>{v.bufferCommitted ? 'Committed' : v.bufferActive ? 'Authorized' : 'Not set'}</span>}>
          <div className="grid grid-cols-2 gap-x-6 gap-y-4">
            <Metric big label="Escrowed" value={`${usdg(p.balance)} USDG`} sub="yours, earns no yield" />
            <Metric label="Target" value={p.targetWad > 0n ? pct(p.targetWad, 1) : '—'} />
            <Metric label="Cap per session" value={p.targetWad > 0n ? `${usdg(p.perSessionCap)} USDG` : '—'} />
            <Metric label="Expires" value={p.expiry > 0n ? `${nyTime(p.expiry)} ET` : '—'} />
          </div>
        </Panel>

        <Panel title="Lending and wallet">
          <div className="grid grid-cols-2 gap-x-6 gap-y-4">
            <Metric big label="Lent" value={`${usdg(lent as bigint | undefined)} USDG`} sub={shares ? `${formatUnits(shares, 12)} shares` : undefined} />
            <Metric label="Wallet USDG" value={usdg(usdgWallet)} />
            <Metric label="Wallet TSLA" value={tokens(tslaWallet)} />
          </div>
          <Link href="/earn" className="mt-4 inline-block text-sm text-dk-up hover:underline">
            Manage lending →
          </Link>
        </Panel>
      </div>

      <BottomTabs positions={hasLoan ? [v] : []} s={s} items={items} viewing={viewing} onView={pick} />
    </div>
  )
}
