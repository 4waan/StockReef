import { evidence } from '@/generated/evidence'
import { Card, Notice } from '@/components/ui'

const g = evidence.golden

function u(base: string | number, digits = 2): string {
  return (Number(base) / 1e6).toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

function p(wad: string | number, digits = 2): string {
  return `${(Number(wad) / 1e16).toFixed(digits)}%`
}

const FAILURES: [string, string][] = [
  ['No keeper or liquidator acts', 'Debt remains. The close still blocks new borrowing; the loan is reported as missed execution with its exposure.'],
  ['Buffer too small', 'Repays what is authorized and available, then shows the remaining amount and eligibility.'],
  ['Token transfer frozen by the issuer', 'The transfer-dependent action reverts; balances are preserved.'],
  ['Price becomes stale before the close', 'Valuation-dependent actions stop; repay and add collateral stay available; no stale-price trim.'],
  ['Liquidator lacks a profitable exit', 'No guaranteed trim; the position stays eligible while policy allows.'],
  ['Transaction delayed past the close', 'A pre-close trim reverts at or after the close. Nothing is backdated.'],
  ['Extreme reopening gap', 'Recovery takes what collateral supports; the residual is written off only at zero collateral and lenders see it in valuation.'],
  ['Missing reopening price', 'The market stays waiting, then guarded after 30 minutes. A deadline never makes stale data acceptable.'],
]

export default function EvidencePage() {
  const w = g.worked_example
  const runs = evidence.runs as Record<string, Record<string, unknown>>
  const demo = runs['demo-46630'] ?? runs['demo-31337']
  const scenarios = runs['scenarios'] as undefined | { rows?: Record<string, string | number>[] }
  return (
    <div className="space-y-5">
      <Notice tone="closed">
        Every figure on this page is reproduced by a committed script: exact rational arithmetic in <code>tools/golden</code>, the scripted demo in <code>contracts/script/DemoRun.s.sol</code>, and the scenario
        harness in <code>tools/scenarios</code>. Limits are illustrative fixtures, not calibrated safe values.
      </Notice>

      <Card title="Worked example: a 72% loan before a weekend close">
        <p className="text-sm text-muted">
          Collateral {u(w.value_usdg)} USDG, debt {u(w.debt_usdg)} USDG. Friday 16:00 close (extended class): the threshold falls from 80% at 14:00 to 70% at 15:30. At 15:15 it is {p(w.lt_at_1515_wad, 3)}, so
          the loan is eligible; at equality it would not be.
        </p>
        <table className="mt-4 w-full text-sm">
          <thead className="text-left text-xs text-muted">
            <tr>
              <th className="py-2 font-medium">Path</th>
              <th className="py-2 font-medium">Debt repaid</th>
              <th className="py-2 font-medium">Collateral taken</th>
              <th className="py-2 font-medium">Result</th>
            </tr>
          </thead>
          <tbody className="num divide-y divide-line">
            <tr>
              <td className="py-2 font-sans">Repay yourself or a funded buffer</td>
              <td>{u(w.cash_required_usdg)} USDG</td>
              <td>none</td>
              <td>65%</td>
            </tr>
            <tr>
              <td className="py-2 font-sans">Liquidator trim at a 2% bonus</td>
              <td>{u(w.trim_repay_usdg)} USDG</td>
              <td>{Number(w.trim_seized_value_usdg_exact).toFixed(2)} USDG of TSLA</td>
              <td>{p(w.ltv_after_trim_wad_floor)}</td>
            </tr>
          </tbody>
        </table>
        <p className="mt-4 text-sm">
          With a hypothetical 35% gap and a 5% recovery bonus, the trimmed loan leaves about <b className="num">{w.gap35_shortfall_trimmed_usdg_2dp} USDG</b> of lender shortfall; the unmanaged loan leaves about{' '}
          <b className="num">{w.gap35_shortfall_unmanaged_usdg_2dp} USDG</b>. Simplified model outcomes, not historical performance.
        </p>
      </Card>

      {demo && (
        <Card title="Scripted demonstration, end to end">
          <ul className="grid gap-3 text-sm md:grid-cols-2">
            <li>
              <b>A, funded buffer:</b> repaid <span className="num">{u(demo.aliceBufferRepaidUsdg as number)} USDG</span> at preparation start, collateral untouched.
            </li>
            <li>
              <b>B, no buffer:</b> a liquidator trimmed <span className="num">{u(demo.bobTrimRepaidUsdg as number)} USDG</span> at 15:15 to reach 65%.
            </li>
            <li>
              <b>C, nobody acted:</b> missed execution {demo.carolMissedExecution ? 'detected' : 'not detected'} at the close, exposure <span className="num">{u(demo.carolExposureUsdg as number)} USDG</span>.
            </li>
            <li>
              <b>Reopening:</b> waiting for a fresh price, recovery trim of <span className="num">{u(demo.carolRecoveryTrimRepaidUsdg as number)} USDG</span>, then open. Written off:{' '}
              <span className="num">{u(demo.totalBadDebtUsdg as number)} USDG</span>.
            </li>
          </ul>
        </Card>
      )}

      {scenarios?.rows && (
        <Card title="Scenarios against baselines">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-muted">
                <tr>
                  {Object.keys(scenarios.rows[0]).map(k => (
                    <th key={k} className="py-2 pr-3 font-medium">
                      {k}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="num divide-y divide-line">
                {scenarios.rows.map((r, i) => (
                  <tr key={i}>
                    {Object.values(r).map((v, j) => (
                      <td key={j} className="py-1.5 pr-3">
                        {String(v)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      <Card title="When things go wrong">
        <dl className="grid gap-x-6 gap-y-3 text-sm md:grid-cols-2">
          {FAILURES.map(([k, v]) => (
            <div key={k}>
              <dt className="font-semibold">{k}</dt>
              <dd className="text-muted">{v}</dd>
            </div>
          ))}
        </dl>
      </Card>

      <Card title="Assumptions and limits">
        <ul className="list-disc space-y-1 pl-5 text-sm text-muted">
          <li>Testnet market lending real Paxos USDG at 1/100 of the worked example. The TSLA price and the clock are labelled simulations, because Chainlink stock feeds are mainnet only.</li>
          <li>Limits (80% open threshold, 70% or 77% at the close, 65% or 72% targets, 2% and 5% bonuses) are illustrative fixtures, not calibrated safe values.</li>
          <li>Execution needs a transaction: the team runs a keeper, and anyone can execute buffers or trim with their own capital. Nothing guarantees a buyer for collateral.</li>
          <li>At most 32 borrowers hold debt at once, so the lender valuation is bounded and tested.</li>
          <li>Price-dependent actions use regular-session prices only. That is a conservative policy, not a claim that off-hours prices are false.</li>
        </ul>
      </Card>
    </div>
  )
}
