'use client'

import { useState } from 'react'
import { evidence } from '@/generated/evidence'
import { Metric, Panel, Select } from '@/components/terminal/kit'
import { chain } from '@/lib/chain'
import { pct } from '@/lib/format'
import { useProtocolConstants } from '@/lib/hooks'

const g = evidence.golden
const runs = evidence.runs as Record<string, Record<string, unknown>>

const u = (base: string | number, digits = 2) => (Number(base) / 1e6).toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
const p = (wad: string | number, digits = 2) => `${(Number(wad) / 1e16).toFixed(digits)}%`

const FAILURES: [string, string][] = [
  ['No keeper or liquidator acts', 'Debt remains. The close still blocks new borrowing; the loan is reported as missed execution with its exposure.'],
  ['Buffer too small', 'It repays what is authorized and available; the remainder can still be trimmed once eligible.'],
  ['Token transfer frozen by the issuer', 'The transfer-dependent action reverts; balances are preserved.'],
  ['Price becomes stale before the close', 'Valuation-dependent actions stop; repaying and adding collateral stay available; no stale-price trim.'],
  ['Liquidator lacks a profitable exit', 'No trim is guaranteed; the position stays eligible while the policy allows.'],
  ['Transaction delayed past the close', 'A pre-close trim reverts at or after the close. Nothing is backdated.'],
  ['Extreme reopening gap', 'Recovery takes what collateral supports; a residual is written off only at zero collateral, and lenders see it in the share value first.'],
  ['Missing reopening price', 'The market waits, then turns guarded 30 minutes after the open. Elapsed time never makes an invalid quote acceptable.'],
]

export default function EvidencePage() {
  const { data: policy } = useProtocolConstants()
  const w = g.worked_example
  const demo = runs['demo-46630'] ?? runs['demo-31337']
  const scenarios = runs['scenarios'] as undefined | { rows?: Record<string, string>[] }
  const names = [...new Set(scenarios?.rows?.map(r => r.scenario) ?? [])]
  const [pick, setPick] = useState(() => names.find(n => n.includes('35%')) ?? names[0] ?? '')
  const rows = scenarios?.rows?.filter(r => r.scenario === pick) ?? []
  const gas = runs['gas'] as undefined | Record<string, number>
  const fork = runs['fork-4663'] as undefined | Record<string, string | number>
  const deploy = runs['deploy-46630'] as undefined | { sourceCommit?: string; transactions?: { contract: string; address: string; transactionHash: string; blockNumber: number }[] }
  const publicMarket = runs['public-market-46630'] as undefined | { accounts: Record<string, string>; setup: Record<string, string>; transactions: { action: string; hash: string }[] }
  const explorer = 'https://explorer.testnet.chain.robinhood.com'

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex h-10 items-center gap-4 overflow-x-auto border-b border-dk-line px-5 text-[15px] whitespace-nowrap">
        <span className="font-semibold">Evidence</span>
        <span className="h-4 w-px bg-dk-line" />
        <span className="text-dk-muted">Review contract receipts, calculations, and measured behavior on chain 46630.</span>
      </div>

      <div className="grid border-b border-dk-line md:grid-cols-4">
        <Panel className="border-b-0 md:border-r">
          <Metric big label="Test entry points" value="535" sub="unit, fuzz, property and invariant suites, including 4 mainnet fork tests" />
        </Panel>
        <Panel className="border-b-0 md:border-r">
          <Metric big label="Mainnet fork block" value={fork ? Number(fork.block).toLocaleString('en-US') : 'Unavailable'} sub="real TSLA Stock Token, Paxos USDG and Chainlink feeds" />
        </Panel>
        <Panel className="border-b-0 md:border-r">
          <Metric big label="Borrow gas at 32 accounts" value={gas ? `${Math.round(gas.borrowAt32 / 1000)}k` : 'Unavailable'} sub={gas ? `lender deposit ${Math.round(gas.lenderDepositAt32 / 1000)}k` : undefined} />
        </Panel>
        <Panel className="border-b-0">
          <Metric big label="Chain 46630 deployment" value={deploy?.transactions ? `${deploy.transactions.length} contracts` : 'not yet'} sub={deploy?.sourceCommit ? `from source ${deploy.sourceCommit}` : undefined} />
        </Panel>
      </div>

      <Panel title="Contract risk policy">
        <div role="region" aria-label="Overnight and extended closure policy" tabIndex={0} className="overflow-x-auto focus-visible:outline focus-visible:outline-2 focus-visible:outline-dk-up">
          <table className="w-full min-w-[560px] text-left text-sm">
            <thead><tr className="text-dk-muted"><th scope="col" className="pb-3 font-medium">Policy from the contract</th><th scope="col" className="pb-3 text-right font-medium">Overnight</th><th scope="col" className="pb-3 text-right font-medium">Weekend or holiday</th></tr></thead>
            <tbody>{([
              ['Open-session liquidation threshold', policy?.ltOpen, policy?.ltOpen],
              ['Threshold 30 minutes before close', policy?.ltFinalOvernight, policy?.ltFinalExtended],
              ['Target after a full solvent trim', policy?.targetOvernight, policy?.targetExtended],
              ['Open-session borrow limit', policy?.borrowOpen, policy?.borrowOpen],
            ] as [string, bigint | undefined, bigint | undefined][]).map(([label, overnight, extended]) => <tr key={label} className="border-t border-dk-line"><th scope="row" className="py-3 pr-4 font-normal">{label}</th><td className="num py-3 text-right font-semibold">{overnight === undefined ? 'Unavailable' : pct(overnight, 0)}</td><td className="num py-3 text-right font-semibold">{extended === undefined ? 'Unavailable' : pct(extended, 0)}</td></tr>)}</tbody>
          </table>
        </div>
        <p className="mt-2 text-xs text-dk-muted">The longer closure applies when the next scheduled open is at least 24 hours away.</p>
      </Panel>

      {publicMarket && <Panel title="Public market on Robinhood Chain 46630">
        <p className="text-sm text-dk-muted">The borrower posted {publicMarket.setup.borrowerCollateralTsla} TSLA, borrowed {publicMarket.setup.borrowedUsdg} USDG, and funded a {publicMarket.setup.borrowerBufferUsdg} USDG repayment buffer. The lender deposited {publicMarket.setup.lenderDepositUsdg} USDG. These setup amounts are recorded at the time of the transactions; current balances and debt are read in the app.</p>
        <div className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-sm">
          {Object.entries(publicMarket.accounts).map(([role, address]) => <a key={role} href={`${explorer}/address/${address}`} target="_blank" rel="noreferrer" className="text-dk-up hover:underline">{role.replace(/([A-Z])/g, ' $1')}: <span className="num">{address.slice(0, 10)}…</span></a>)}
        </div>
        <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-sm">
          {publicMarket.transactions.filter(t => ['deposit lender USDG', 'borrow USDG', 'fund repayment buffer', 'authorize repayment buffer'].includes(t.action)).map(t => <a key={t.hash} href={`${explorer}/tx/${t.hash}`} target="_blank" rel="noreferrer" className="text-dk-up hover:underline">{t.action} ↗</a>)}
        </div>
      </Panel>}

      <Panel title="A Friday close in numbers">
        <p className="text-[15px] text-dk-muted">
          {u(w.value_usdg)} USDG of TSLA collateral and {u(w.debt_usdg)} USDG of debt: 72% LTV. At 15:15 before a 16:00 extended close the threshold has fallen to {p(w.lt_at_1515_wad, 3)},
          so the loan is eligible for a trim.
        </p>
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[640px] text-[15px]">
            <thead>
              <tr className="text-left text-sm text-dk-muted">
                {['Route', 'Debt reduction', 'Collateral used', 'Result'].map(h => (
                  <th key={h} className="py-2 pr-4 font-normal">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="num">
              <tr className="border-t border-dk-line">
                <td className="py-2.5 pr-4 font-sans">Funded buffer</td>
                <td className="pr-4">{u(w.cash_required_usdg)} USDG from the borrower</td>
                <td className="pr-4">none</td>
                <td>65% LTV</td>
              </tr>
              <tr className="border-t border-dk-line">
                <td className="py-2.5 pr-4 font-sans">Partial trim at a 2% bonus</td>
                <td className="pr-4">{u(w.trim_repay_usdg)} USDG from a liquidator</td>
                <td className="pr-4">{Number(w.trim_seized_value_usdg_exact).toFixed(2)} USDG of TSLA</td>
                <td>{p(w.ltv_after_trim_wad_floor)} LTV</td>
              </tr>
              <tr className="border-t border-dk-line">
                <td className="py-2.5 pr-4 font-sans">Nobody executes</td>
                <td className="pr-4">none before the close</td>
                <td className="pr-4">none</td>
                <td className="font-sans">enters the closure unchanged; exposure reported</td>
              </tr>
            </tbody>
          </table>
        </div>
      </Panel>

      {demo && (
        <Panel title={`Recorded closure sequence (${runs['demo-46630'] ? 'chain 46630' : 'local chain'}, 1/100 scale)`}>
          <ul className="grid gap-3 text-[15px] md:grid-cols-2">
            <li>
              <b>A, funded buffer:</b> <span className="text-dk-muted">repaid</span> <span className="num">{u(demo.aliceBufferRepaidUsdg as number)} USDG</span>{' '}
              <span className="text-dk-muted">at preparation start, collateral untouched.</span>
            </li>
            <li>
              <b>B, no buffer:</b> <span className="text-dk-muted">a liquidator trimmed</span> <span className="num">{u(demo.bobTrimRepaidUsdg as number)} USDG</span>{' '}
              <span className="text-dk-muted">at 15:15.</span>
            </li>
            <li>
              <b>C, nobody acted:</b> <span className="text-dk-muted">missed execution {demo.carolMissedExecution ? 'flagged' : 'not flagged'} at the close, exposure</span>{' '}
              <span className="num">{u(demo.carolExposureUsdg as number)} USDG</span>.
            </li>
            <li>
              <b>Reopening, 6% lower:</b> <span className="text-dk-muted">recovery trim of</span> <span className="num">{u(demo.carolRecoveryTrimRepaidUsdg as number)} USDG</span>
              <span className="text-dk-muted">, written off</span> <span className="num">{u(demo.totalBadDebtUsdg as number)} USDG</span>.
            </li>
          </ul>
        </Panel>
      )}

      {rows.length > 0 && (
        <Panel title="Scenario harness" aside={<Select value={pick} onChange={setPick} options={names.map(n => ({ key: n, label: n }))} />}>
          <p className="mb-3 text-sm text-dk-muted">
            An economic model comparing fixed-limit lending, borrowing locks, buffers and trims under identical price paths, with a linear approximation for closure interest. Lower lender
            exposure does not remove risk for everyone: the liquidator holding trimmed collateral through a gap carries it.
          </p>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[900px] text-sm">
              <thead>
                <tr className="text-left text-dk-muted">
                  {Object.keys(rows[0])
                    .filter(k => k !== 'scenario')
                    .map(k => (
                      <th key={k} className="py-2 pr-3 font-normal">
                        {k}
                      </th>
                    ))}
                </tr>
              </thead>
              <tbody className="num">
                {rows.map((r, i) => (
                  <tr key={i} className="border-t border-dk-line">
                    {Object.entries(r)
                      .filter(([k]) => k !== 'scenario')
                      .map(([k, v]) => (
                        <td key={k} className={`py-2 pr-3 ${k === 'baseline' ? 'font-sans' : ''} ${k === 'lender loss' && v !== '0.00' ? 'text-dk-down' : ''}`}>
                          {v}
                        </td>
                      ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Panel>
      )}

      {deploy?.transactions && (
        <Panel title="Robinhood Chain 46630 deployment">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-sm">
              <thead>
                <tr className="text-left text-dk-muted">
                  {['Contract', 'Address', 'Block', 'Transaction'].map(h => (
                    <th key={h} className="py-2 pr-4 font-normal">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="num">
                {deploy.transactions.map(t => (
                  <tr key={t.transactionHash} className="border-t border-dk-line">
                    <td className="py-2 pr-4 font-sans">{t.contract}</td>
                    <td className="pr-4">
                      <a href={`${explorer}/address/${t.address}`} target="_blank" rel="noreferrer" className="text-dk-up hover:underline">
                        {t.address}
                      </a>
                    </td>
                    <td className="pr-4">{t.blockNumber.toLocaleString('en-US')}</td>
                    <td>
                      <a href={`${explorer}/tx/${t.transactionHash}`} target="_blank" rel="noreferrer" className="text-dk-up hover:underline">
                        {t.transactionHash.slice(0, 10)}…
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-xs text-dk-faint">The app reads Robinhood Chain {chain.id}. Paxos USDG and faucet TSLA are the assets; the stock price and market clock are set by the operator.</p>
        </Panel>
      )}

      <div className="grid md:grid-cols-2">
        <Panel title="When things go wrong" className="md:border-r">
          <dl className="space-y-3 text-[15px]">
            {FAILURES.map(([k, v]) => (
              <div key={k}>
                <dt className="font-semibold">{k}</dt>
                <dd className="text-dk-muted">{v}</dd>
              </div>
            ))}
          </dl>
        </Panel>
        <Panel title="Assumptions and limits">
          <ul className="list-disc space-y-1.5 pl-5 text-[15px] text-dk-muted">
            <li>The deployed thresholds, targets and bonuses are the contract values shown in the policy table.</li>
            <li>Execution needs a transaction. The team runs a keeper; anyone can execute buffers or trim with their own capital. Nothing guarantees a buyer for seized stock.</li>
            <li>Lender shares reflect cash plus recoverable loan value. A collateral shortfall lowers that recoverable value.</li>
            <li>At most 32 borrowers hold debt at once, which keeps the lender valuation bounded and tested.</li>
            <li>Price-dependent actions use regular-session prices only. That is a conservative policy, not a claim that off-hours prices are wrong.</li>
          </ul>
        </Panel>
      </div>
    </div>
  )
}
