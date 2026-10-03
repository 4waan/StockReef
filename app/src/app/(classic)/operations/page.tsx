'use client'

import { useState } from 'react'
import { parseUnits, type Address } from 'viem'
import { useAccount, useReadContract } from 'wagmi'
import { demoAbi, escrowAbi, gateAbi, marketAbi } from '@/generated/abi'
import { TxLine } from '@/components/AmountAction'
import { Badge, Button, Card, Notice } from '@/components/ui'
import { chain, contracts, demoAccounts } from '@/lib/chain'
import { duration, nyTime, pct, price, short, tokens, usdg } from '@/lib/format'
import { useActiveAccounts, useMarketView, useProtocolNow, useTx } from '@/lib/hooks'
import { reasonList, stateName } from '@/lib/policy'

export default function OperationsPage() {
  const { data: m } = useMarketView()
  const { data: accounts } = useActiveAccounts()
  const now = useProtocolNow(m?.policy.time)
  const refresh = useTx()
  if (!m || !contracts) return <p className="text-sm text-muted">Reading the market…</p>
  const c = contracts
  const s = m.policy
  const acting = accounts?.filter(v => v.bufferExecutableNow > 0n || (v.trimNow.eligible && !v.trimNow.bufferPending)) ?? []
  const missed = accounts?.filter(v => v.missedExecution) ?? []
  const lastAcceptedAge = now !== undefined && m.lastAcceptedAt > 0n ? now - Number(m.lastAcceptedAt) : undefined

  return (
    <div className="space-y-5">
      <div className="grid gap-5 md:grid-cols-3">
        <Card title="Price gate">
          <p className="text-sm">
            {s.reasons === 0 ? <Badge tone="ok">Price usable</Badge> : <Badge tone="guarded">Price not usable</Badge>}
          </p>
          {s.reasons !== 0 && <p className="mt-2 text-xs text-guarded">{reasonList(Number(s.reasons)).join(' · ')}</p>}
          <p className="mt-2 text-xs text-muted">
            Last accepted <span className="num">{price(m.valuationPriceWad)} USDG</span>
            {lastAcceptedAge !== undefined && <> · {duration(lastAcceptedAge)} ago</>}
          </p>
          <p className="mt-1 text-xs text-muted">Reopening admission: {s.admissionAt > 0n ? <span className="num">{nyTime(s.admissionAt)}</span> : 'not yet this session'}</p>
          <div className="mt-3">
            <Button variant="secondary" onClick={() => refresh.send({ address: c.gate, abi: gateAbi, functionName: 'refresh', args: [] })}>
              Refresh gate
            </Button>
            <TxLine status={refresh.status} />
          </div>
        </Card>
        <Card title="Keeper queue">
          <p className="num text-3xl font-semibold">{acting.length}</p>
          <p className="text-xs text-muted">accounts with an executable buffer or trim now</p>
          <p className="mt-3 text-xs text-muted">The team keeper runs these automatically. Anyone can run buffers; trims need the caller’s own USDG.</p>
        </Card>
        <Card title="Missed execution">
          <p className="num text-3xl font-semibold">{missed.length}</p>
          <p className="text-xs text-muted">
            exposure <span className="num">{usdg(missed.reduce((a, v) => a + v.exposure, 0n))} USDG</span>
          </p>
          <p className="mt-3 text-xs text-muted">Accounts that entered a closure above the closing threshold because nobody acted.</p>
        </Card>
      </div>

      <Card title="Borrowers" aside={<span className="text-xs text-muted">{accounts?.length ?? 0} with debt</span>}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-muted">
              <tr>
                <th className="py-2 pr-3 font-medium">Account</th>
                <th className="py-2 pr-3 font-medium">Debt</th>
                <th className="py-2 pr-3 font-medium">LTV</th>
                <th className="py-2 pr-3 font-medium">To plan</th>
                <th className="py-2 pr-3 font-medium">Buffer now</th>
                <th className="py-2 pr-3 font-medium">Trim now</th>
                <th className="py-2 pr-3 font-medium">Status</th>
                <th className="py-2 font-medium" />
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {accounts?.map(v => <Row key={v.account} v={v} lt={s.ltWad} />)}
            </tbody>
          </table>
        </div>
      </Card>

      {m.simulationClock && <DemoControls s={s} />}
    </div>
  )
}

type AccountView = NonNullable<ReturnType<typeof useActiveAccounts>['data']>[number]

function label(address: Address): string {
  return demoAccounts.find(d => d.address.toLowerCase() === address.toLowerCase())?.label ?? short(address)
}

function Row({ v, lt }: { v: AccountView; lt: bigint }) {
  const buffer = useTx()
  const trim = useTx()
  const c = contracts!
  const status = v.missedExecution ? (
    <Badge tone="guarded">Missed · {usdg(v.exposure)} exposed</Badge>
  ) : v.ltvWad > lt ? (
    <Badge tone="final">Above threshold</Badge>
  ) : v.repayToTarget > 0n ? (
    <Badge tone="prep">Above plan</Badge>
  ) : (
    <Badge tone="ok">At or under plan</Badge>
  )
  return (
    <tr>
      <td className="num py-2 pr-3">{label(v.account)}</td>
      <td className="num py-2 pr-3">{usdg(v.debt)}</td>
      <td className="num py-2 pr-3">{pct(v.ltvWad)}</td>
      <td className="num py-2 pr-3">{usdg(v.repayToTarget)}</td>
      <td className="num py-2 pr-3">{v.bufferExecutableNow > 0n ? usdg(v.bufferExecutableNow) : '—'}</td>
      <td className="num py-2 pr-3">
        {v.trimNow.eligible ? `${usdg(v.trimNow.repaid)} for ${tokens(v.trimNow.collateralOut)} TSLA (${pct(v.trimNow.bonusWad, 0)})` : '—'}
      </td>
      <td className="py-2 pr-3">{status}</td>
      <td className="py-2">
        <div className="flex gap-2">
          {v.bufferExecutableNow > 0n && (
            <Button variant="secondary" onClick={() => buffer.send({ address: c.escrow, abi: escrowAbi, functionName: 'executeBuffer', args: [v.account] })}>
              Run buffer
            </Button>
          )}
          {v.trimNow.eligible && !v.trimNow.bufferPending && (
            <Button
              variant="secondary"
              onClick={() =>
                trim.send(
                  { address: c.market, abi: marketAbi, functionName: 'trim', args: [v.account, v.trimNow.repaid, (v.trimNow.collateralOut * 99n) / 100n, 2n ** 64n - 1n] },
                  { token: c.loanToken, spender: c.market, amount: v.trimNow.repaid },
                )
              }
            >
              Trim
            </Button>
          )}
        </div>
        <TxLine status={buffer.status.state !== 'idle' ? buffer.status : trim.status} />
      </td>
    </tr>
  )
}

type Snap = NonNullable<ReturnType<typeof useMarketView>['data']>['policy']

/** Labelled simulation controls: one transaction moves the demo clock and publishes the next demo price. */
function DemoControls({ s }: { s: Snap }) {
  const { address } = useAccount()
  const tx = useTx()
  const [answer, setAnswer] = useState(() => (s.priceWad > 0n ? (Number(s.priceWad) / 1e18).toFixed(2) : '400'))
  const { data: operator } = useReadContract({ address: contracts?.demoController, abi: demoAbi, functionName: 'operator', chainId: chain.id, query: { enabled: !!contracts } })
  const isOperator = !!address && !!operator && operator.toLowerCase() === address.toLowerCase()
  const phase = stateName(s.phase)
  const inSession = s.time >= s.open && s.time < s.close
  // Milestones of the current session while it is running, otherwise of the next one.
  const steps: { label: string; at: bigint }[] = inSession
    ? [
        { label: 'Preparation start (A)', at: s.prepAt },
        { label: '45 min before close', at: s.close - 2700n },
        { label: 'Final window (F)', at: s.finalAt },
        { label: 'Close + 1 h', at: s.close + 3600n },
      ]
    : [
        { label: 'Next open + 1 min', at: s.nextOpen + 60n },
        { label: 'Next open + 5 min (admission)', at: s.nextOpen + 300n },
        { label: 'Next open + 15 min (credit)', at: s.nextOpen + 900n },
      ]
  if (phase === 'REOPEN_WAIT' || phase === 'REOPEN_RECOVERY') {
    steps.unshift({ label: 'Open + 5 min (admission)', at: s.open + 300n }, { label: 'Open + 15 min (credit)', at: s.open + 900n })
  }
  let parsed: bigint | undefined
  try {
    parsed = parseUnits(answer || '0', 8)
  } catch {
    parsed = undefined
  }
  const c = contracts!
  return (
    <Card title="Demo controls" aside={<Badge tone="sim">Simulation: clock and price</Badge>}>
      <Notice tone="sim">
        These buttons move the labelled demo clock and publish the demo TSLA price in one transaction. Simulated time accrues interest like real time. Only the demo operator can use them;
        everything else on this page is the real protocol.
      </Notice>
      <div className="mt-4 flex flex-wrap items-end gap-3">
        <label className="text-xs text-muted">
          Demo price (USD)
          <input value={answer} onChange={e => setAnswer(e.target.value)} className="num mt-1 block w-28 rounded-lg border border-line px-3 py-2 text-sm" />
        </label>
        {[-6, -3, 3].map(d => (
          <Button key={d} variant="secondary" onClick={() => setAnswer(((Number(answer) * (100 + d)) / 100).toFixed(2))}>
            {d > 0 ? `+${d}%` : `${d}%`}
          </Button>
        ))}
        <Button variant="sim" disabled={!isOperator || !parsed} onClick={() => tx.send({ address: c.demoController, abi: demoAbi, functionName: 'push', args: [parsed!] })}>
          Publish price now
        </Button>
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        {steps
          .filter(st => st.at > s.time)
          .map(st => (
            <Button
              key={st.label}
              variant="sim"
              disabled={!isOperator || !parsed}
              onClick={() => tx.send({ address: c.demoController, abi: demoAbi, functionName: 'stepTo', args: [st.at, parsed!] })}
              title={nyTime(st.at)}
            >
              {st.label} · {nyTime(st.at)}
            </Button>
          ))}
      </div>
      {!isOperator && <p className="mt-2 text-xs text-faint">Connect the demo operator wallet ({operator ? short(operator) : '…'}) to use these.</p>}
      <TxLine status={tx.status} />
      <p className="mt-2 text-xs text-faint">The keeper (or the Refresh button) refreshes the gate after each step.</p>
    </Card>
  )
}
