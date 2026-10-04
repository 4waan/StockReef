'use client'

import { useState } from 'react'
import { useReadContracts } from 'wagmi'
import { erc20Abi } from '@/generated/abi'
import { chain, contracts } from '@/lib/chain'
import { useDesk } from '@/lib/desk'
import { nyClock, pct, usdg } from '@/lib/format'
import { MARKET } from '@/lib/script'
import { useBook } from '@/lib/session'
import { SessionChart, type ChartRange } from './SessionChart'
import { AddrRef, Card, KV, Loading, PhaseTag, Stat } from './ui'

/**
 * The TSLA asset page: the stock's identity (company, ticker, token, price index) and its chart, then the lending
 * market organised by collateral, loan asset, liquidation limits, borrow limit, liquidity and rate.
 */
export function AssetPage() {
  const d = useDesk()
  const { data: book } = useBook()
  const [range, setRange] = useState<ChartRange>('day')
  const { data: tokenMeta } = useReadContracts({
    contracts: contracts
      ? [
          { address: contracts.collateralToken, abi: erc20Abi, functionName: 'name', chainId: chain.id },
          { address: contracts.collateralToken, abi: erc20Abi, functionName: 'symbol', chainId: chain.id },
          { address: contracts.loanToken, abi: erc20Abi, functionName: 'name', chainId: chain.id },
          { address: contracts.loanToken, abi: erc20Abi, functionName: 'symbol', chainId: chain.id },
        ]
      : [],
    query: { enabled: !!contracts, staleTime: Infinity },
  })
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (!d.anchor || !d.policy || !d.steps || !d.current) return <Loading />
  const cur = d.current
  const pol = d.policy
  const s = cur.snapshot
  const quote = Number(cur.quoteWad) / 1e18
  const first = d.obs[0]?.price ?? quote
  const change = quote - first
  const apr = (Number(pol.ratePerSecond) * 31_536_000) / 1e16
  const [tName, tSym, lName, lSym] = (tokenMeta ?? []).map(r => (r.status === 'success' ? String(r.result) : undefined))
  const totalSupplied = book ? book.lenderAssets : undefined
  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 px-4 py-5">
      <header className="flex flex-wrap items-center gap-4">
        <img src={MARKET.logo} alt="Tesla" className="h-14 w-14 rounded-full bg-white p-3" />
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-3xl font-semibold">{MARKET.company}</h1>
            <span className="rounded bg-dk-raised px-2 py-0.5 text-xs font-semibold text-dk-ink">{MARKET.ticker}</span>
            <span className="rounded border border-dk-line px-2 py-0.5 text-xs text-dk-muted">Stock token · {chain.name}</span>
          </div>
          <div className="mt-1 text-sm text-dk-muted">{MARKET.listing}</div>
        </div>
        <div className="ml-auto text-right">
          <div className="num text-3xl font-semibold">${quote.toFixed(2)}</div>
          <div className={`num text-sm ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`}>
            {change >= 0 ? '+' : ''}
            {change.toFixed(2)} ({((change / first) * 100).toFixed(2)}%) since Friday open · {cur.step.day === 'mon' ? 'Mon' : 'Fri'} {nyClock(cur.t)} ET
          </div>
        </div>
      </header>

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
        <section className="rounded-lg border border-dk-line bg-dk-panel">
          <div className="flex items-center justify-between border-b border-dk-line px-4 py-2">
            <div className="flex items-center gap-3">
              <span className="text-sm font-semibold">TSLA / USD</span>
              <PhaseTag state={s.state} />
            </div>
            <div className="flex rounded-md border border-dk-line p-0.5 text-xs">
              {(['day', 'focus'] as const).map(k => (
                <button key={k} type="button" aria-pressed={range === k} onClick={() => setRange(k)} className={`rounded px-3 py-1 ${range === k ? 'bg-dk-raised font-semibold' : 'text-dk-muted hover:text-dk-ink'}`}>
                  {k === 'day' ? 'Friday + reopening' : 'Close + reopening'}
                </button>
              ))}
            </div>
          </div>
          <SessionChart anchor={d.anchor} steps={d.steps} at={d.at} obs={d.obs} ltPath={d.ltPath} markers={[]} collateral={undefined} debt={undefined} target={undefined} mode="price" range={range} height={360} />
        </section>
        <Card kicker="Token identity" title={`${tName ?? MARKET.collateral.name} (${tSym ?? MARKET.ticker})`}>
          <KV label="Token contract" value={<AddrRef address={contracts.collateralToken} />} />
          <KV label="Decimals" value={MARKET.collateral.decimals} />
          <KV label="Issuer" value={MARKET.collateral.note} />
          <KV label="Price index" value="TSLA/USD" hint="regular session" />
          <div className="mt-2 text-xs text-dk-faint">{MARKET.priceIndex}. The price gate accepts a quote for 120 seconds and only inside the session calendar.</div>
          <div className="mt-4 border-t border-dk-line pt-3">
            <KV label="Loan asset" value={`${lName ?? MARKET.loan.name} (${lSym ?? 'USDG'})`} />
            <KV label="Loan token" value={<AddrRef address={contracts.loanToken} />} />
            <KV label="USDG reference" value="1 USDG = 1 USD" hint="test peg" />
          </div>
        </Card>
      </div>

      <section className="grid gap-4 lg:grid-cols-3">
        <Card kicker="Market" title="TSLA collateral → USDG loans" className="lg:col-span-2">
          <div className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
            <Stat label="Collateral" value="TSLA" sub="stock token, 18 decimals" />
            <Stat label="Loan asset" value="USDG" sub="Paxos Global Dollar" />
            <Stat label="Liquidation threshold" value={pct(s.ltWad, 2)} tone="warn" sub={`${pct(pol.ltOpen, 0)} open → ${pct(pol.ltFinalExtended, 0)} weekend · ${pct(pol.ltFinalOvernight, 0)} overnight`} />
            <Stat label="Borrow limit" value={s.canBorrow ? pct(s.borrowLimitWad, 2) : 'Locked'} sub={`${pct(pol.bOpen, 0)} open; threshold − ${pct(pol.borrowGap, 0)} while it falls`} />
            <Stat label="Total supplied" value={totalSupplied !== undefined ? usdg(totalSupplied) : '—'} sub="lender assets, USDG" />
            <Stat label="Total borrowed" value={book ? usdg(book.totalDebt) : '—'} sub={`${book?.loans.length ?? 0} active loans`} />
            <Stat label="Available liquidity" value={book ? usdg(book.cash) : '—'} sub={book ? `utilization ${pct(book.utilizationWad, 1)} of ${pct(pol.utilizationCap, 0)} cap` : undefined} />
            <Stat label="Borrow rate" value={`${apr.toFixed(2)}%`} sub="fixed, continuously compounded" />
          </div>
        </Card>
        <Card kicker="Liquidation" title="Partial, never all at once">
          <KV label="Trim target" value={`${pct(pol.targetExtended, 0)} weekend · ${pct(pol.targetOvernight, 0)} overnight`} />
          <KV label="Scheduling bonus" value={pct(pol.bonusScheduling, 0)} hint="preparation, LTV ≤ 80%" />
          <KV label="Distress / recovery bonus" value={pct(pol.bonusDistress, 0)} />
          <KV label="Recovery haircut" value="value ÷ 1.05" hint="lender valuation" />
          <KV label="Buffer target cap" value={pct(pol.maxBufferTarget, 0)} />
        </Card>
      </section>

      <Card kicker="Session schedule" title="Limits by session phase, from the deployed policy">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-sm">
            <thead>
              <tr className="text-left text-xs text-dk-muted">
                {['Phase', 'Scripted time', 'Threshold', 'Borrow limit', 'Target', 'Borrow', 'Buffers', 'Trims'].map(h => (
                  <th key={h} className="pb-2 font-normal">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="num">
              {d.steps.map((x, i) => (
                <tr key={x.step.id} className={`border-t border-dk-line ${i === d.at ? 'bg-brand/10' : ''}`}>
                  <td className="py-2">
                    <PhaseTag state={x.snapshot.state} />
                  </td>
                  <td>
                    {x.step.day === 'mon' ? 'Mon' : 'Fri'} {nyClock(x.t)}
                  </td>
                  <td className="text-dk-warn">{pct(x.snapshot.ltWad, 2)}</td>
                  <td>{x.snapshot.canBorrow ? pct(x.snapshot.borrowLimitWad, 2) : '—'}</td>
                  <td>{pct(x.planTargetWad, 0)}</td>
                  <td>{x.snapshot.canBorrow ? 'yes' : 'locked'}</td>
                  <td>{x.snapshot.canBuffer ? 'run' : '—'}</td>
                  <td>{x.snapshot.canTrim ? 'above threshold' : 'paused'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-3 text-xs text-dk-faint">
          Calendar: Friday {d.anchor ? new Date(Number(d.anchor.fri.open) * 1000).toLocaleDateString('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric' }) : ''} session {d.anchor.fri.index} of the deployed SessionCalendar,
          closing into a weekend. Limits: SessionRiskPolicy constants, ltAt and borrowLimit.
        </p>
      </Card>
    </div>
  )
}
