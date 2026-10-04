'use client'

import { useState } from 'react'
import { parseUnits, type Address } from 'viem'
import { useAccount, useConnect, useReadContract } from 'wagmi'
import { demoAbi, escrowAbi, gateAbi, marketAbi } from '@/generated/abi'
import { Btn, Dot, Metric, Panel, TxStatusLine } from '@/components/terminal/kit'
import { Info } from '@/components/reef/ui'
import { chain, contracts, demoAccounts } from '@/lib/chain'
import { duration, nyClock, nyTime, pct, price, short, tokens, usdg } from '@/lib/format'
import { useHistory } from '@/lib/history'
import { useActiveAccounts, useDemoOperator, useMarketView, useProtocolNow, useTx } from '@/lib/hooks'
import { reasonList, stateName, STATE_COPY } from '@/lib/policy'
import type { AccountData, Snapshot } from '@/lib/types'
import { useViewing } from '@/lib/viewing'

export default function OperationsPage() {
  const { isConnected } = useAccount()
  const { connect, connectors } = useConnect()
  const { data: m } = useMarketView()
  const { data: accounts } = useActiveAccounts()
  const now = useProtocolNow(m?.policy.time)
  const { data: history } = useHistory(undefined, undefined)
  const refresh = useTx()

  if (!contracts) return <p className="px-5 py-10 text-dk-muted">No StockReef deployment is configured for chain {chain.id} yet.</p>
  if (!m || now === undefined) return <p className="px-5 py-10 text-dk-muted">Reading the market…</p>
  const s = m.policy
  const state = stateName(s.state)
  const queue = accounts?.filter(v => v.bufferExecutableNow > 0n || (v.trimNow.eligible && !v.trimNow.bufferPending)) ?? []
  const missed = accounts?.filter(v => v.missedExecution) ?? []
  const exposure = missed.reduce((a, v) => a + v.exposure, 0n)
  const reasons = reasonList(Number(s.reasons))

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex h-10 items-center gap-4 overflow-x-auto border-b border-dk-line px-5 text-[15px] whitespace-nowrap">
        <span className="font-semibold">Operations</span>
        <span className="h-4 w-px bg-dk-line" />
        <span className="text-dk-muted">{STATE_COPY[state].label}</span>
        <span className="h-4 w-px bg-dk-line" />
        <span className="num text-dk-muted">{nyTime(now)} ET</span>
      </div>

      <div className="grid border-b border-dk-line md:grid-cols-3">
        <Panel className="border-b-0 md:border-r">
          <Metric big label="Actions ready" value={queue.length} sub="funded repayments or trims eligible now" />
          <div className="mt-1"><Info label="About actions ready">The team keeper runs these. Anyone can run a funded buffer; trims need the caller’s own USDG.</Info></div>
        </Panel>
        <Panel className="border-b-0 md:border-r">
          <Metric big label="Loans needing recovery" value={missed.length} tone={missed.length ? 'text-dk-down' : ''} sub={`${usdg(exposure)} USDG to reach target`} />
          <div className="mt-1"><Info label="About loans needing recovery">These loans crossed the closing threshold and carried excess debt into the closure. The USDG amount is the repayment needed to reach the target at the last accepted price.</Info></div>
        </Panel>
        <Panel className="border-b-0">
          <div className="flex items-center gap-2">
            <Dot tone={s.reasons === 0 ? 'up' : 'down'} />
            <span className="font-medium">Stock price status: {s.reasons === 0 ? 'accepted' : 'action needed'}</span>
          </div>
          {reasons.length > 0 && <p className="mt-1 text-sm text-dk-down">{reasons.join(' · ')}</p>}
          <p className="mt-2 text-sm text-dk-muted">
            Last accepted <span className="num text-dk-ink">{price(m.valuationPriceWad)} USDG</span>
            {m.lastAcceptedAt > 0n && <> · {duration(now - Number(m.lastAcceptedAt))} ago</>}
            <br />
            Reopening admission: {s.admissionAt > 0n ? <span className="num text-dk-ink">{nyTime(s.admissionAt)} ET</span> : 'none this session'}
          </p>
          <Btn className="mt-3" disabled={!isConnected && connectors.length === 0} onClick={() => isConnected ? refresh.send({ address: contracts!.gate, abi: gateAbi, functionName: 'refresh', args: [] }) : connect({ connector: connectors[0], chainId: chain.id })}>
            {isConnected ? 'Refresh gate' : 'Connect to refresh'}
          </Btn>
          <TxStatusLine status={refresh.status} />
        </Panel>
      </div>

      <Panel title="Borrowers" aside={<span className="text-sm text-dk-muted">{accounts?.length ?? 0} with debt</span>}>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[900px] text-[15px]">
            <thead>
              <tr className="text-left text-sm text-dk-muted">
                {['Account', 'Debt', 'LTV', 'To plan', 'Buffer now', 'Trim now', 'Status', ''].map(h => (
                  <th key={h} className="py-2 pr-4 font-normal">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {accounts?.length === 0 && (
                <tr className="border-t border-dk-line">
                  <td colSpan={8} className="py-4 text-dk-faint">
                    No borrower holds debt.
                  </td>
                </tr>
              )}
              {accounts?.map(v => <Row key={v.account} v={v} s={s} now={now} />)}
            </tbody>
          </table>
        </div>
      </Panel>

      <div className="grid md:grid-cols-2">
        <Guardian now={now} />
        {m.simulationClock && <DemoControls s={s} now={now} feedDecimals={history?.feedDecimals ?? 8} />}
      </div>

      <Panel title="Price gate log">
        {(history?.gate.length ?? 0) === 0 ? (
          <p className="text-dk-faint">No admissions, outages or stops recorded since deployment.</p>
        ) : (
          <ul className="divide-y divide-dk-line">
            {history!.gate.slice(0, 20).map(g => (
              <li key={g.hash + g.kind + g.t} className="flex justify-between py-2 text-[15px]">
                <span>
                  {g.kind} {g.detail && <span className="text-dk-faint">{g.detail}</span>}
                </span>
                <span className="num text-dk-muted">{nyTime(g.t)} ET</span>
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </div>
  )
}

function label(a: Address) {
  return demoAccounts.find(d => d.address.toLowerCase() === a.toLowerCase())?.label ?? short(a)
}

function Row({ v, s, now }: { v: AccountData; s: Snapshot; now: number }) {
  const buffer = useTx()
  const trim = useTx()
  const { pick } = useViewing()
  const c = contracts!
  const status = v.missedExecution ? (
    <span className="text-dk-down">Missed · {usdg(v.exposure)} exposed</span>
  ) : v.ltvWad > s.ltWad ? (
    <span className="text-dk-down">Above threshold</span>
  ) : v.repayToTarget >= 10_000n ? (
    <span className="text-dk-warn">Above plan</span>
  ) : (
    <span className="text-dk-up">At or under plan</span>
  )
  return (
    <tr className="border-t border-dk-line align-top">
      <td className="py-2.5 pr-4">
        <a href={`/trade?account=${v.account}`} onClick={() => pick(v.account)} className="num text-dk-ink hover:underline">
          {label(v.account)}
        </a>
      </td>
      <td className="num py-2.5 pr-4">{usdg(v.debt)}</td>
      <td className="num py-2.5 pr-4">{pct(v.ltvWad, 1)}</td>
      <td className="num py-2.5 pr-4">{v.repayToTarget >= 10_000n ? usdg(v.repayToTarget) : 'Unavailable'}</td>
      <td className="num py-2.5 pr-4">{v.bufferExecutableNow > 0n ? usdg(v.bufferExecutableNow) : 'Unavailable'}</td>
      <td className="num py-2.5 pr-4">{v.trimNow.eligible ? `${usdg(v.trimNow.repaid)} for ${tokens(v.trimNow.collateralOut)} TSLA (${pct(v.trimNow.bonusWad, 0)})` : 'Unavailable'}</td>
      <td className="py-2.5 pr-4">{status}</td>
      <td className="py-2.5">
        <div className="flex gap-2">
          {v.bufferExecutableNow > 0n && (
            <Btn onClick={() => buffer.send({ address: c.escrow, abi: escrowAbi, functionName: 'executeBuffer', args: [v.account] })}>Run buffer</Btn>
          )}
          {v.trimNow.eligible && !v.trimNow.bufferPending && (
            <Btn
              variant="danger"
              title="Repays part of the debt with your USDG and takes collateral at the current price plus the bonus. Accepts at least 99% of the quoted collateral, within 10 minutes of protocol time."
              onClick={() =>
                trim.send(
                  { address: c.market, abi: marketAbi, functionName: 'trim', args: [v.account, v.trimNow.repaid, (v.trimNow.collateralOut * 99n) / 100n, BigInt(now + 600)] },
                  { token: c.loanToken, spender: c.market, amount: v.trimNow.repaid },
                )
              }
            >
              Trim
            </Btn>
          )}
        </div>
        <TxStatusLine status={buffer.status.state !== 'idle' ? buffer.status : trim.status} />
      </td>
    </tr>
  )
}

/** The guardian's stop and the 24-hour delayed resume. Only the gate owner can act; everyone sees the state. */
function Guardian({ now }: { now: number }) {
  const { address } = useAccount()
  const tx = useTx()
  const c = contracts!
  const q = { address: c.gate, abi: gateAbi, chainId: chain.id, query: { refetchInterval: 4_000 } } as const
  const { data: owner } = useReadContract({ ...q, functionName: 'owner' })
  const { data: stopped } = useReadContract({ ...q, functionName: 'stopped' })
  const { data: resumeAt } = useReadContract({ ...q, functionName: 'resumeAvailableAt' })
  const isOwner = !!address && !!owner && owner.toLowerCase() === address.toLowerCase()
  const waiting = !!resumeAt && resumeAt > 0n
  const ready = waiting && now >= Number(resumeAt)
  return (
    <Panel
      title={
        <span className="inline-flex items-center gap-2">
          Guardian
          <Info label="About the guardian">A guardian stop halts everything price-dependent at once. Resuming needs a request, a 24-hour wait and the gate’s recovery conditions. Repaying and adding collateral keep working throughout.</Info>
        </span>
      }
      className="md:border-r"
      aside={<span className={`text-sm ${stopped ? 'text-dk-down' : 'text-dk-up'}`}>{stopped ? 'Stopped' : 'Running'}</span>}
    >
      {stopped && waiting && (
        <p className="mt-2 text-sm">
          Resume available {nyTime(resumeAt!)} ET{!ready && <span className="num text-dk-muted"> · in {duration(Number(resumeAt) - now)}</span>}
        </p>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        <Btn variant="danger" disabled={!isOwner || !!stopped} onClick={() => tx.send({ address: c.gate, abi: gateAbi, functionName: 'stop', args: [] })}>
          Stop
        </Btn>
        <Btn disabled={!isOwner || !stopped || waiting} onClick={() => tx.send({ address: c.gate, abi: gateAbi, functionName: 'requestResume', args: [] })}>
          Request resume
        </Btn>
        <Btn disabled={!isOwner || !stopped || !ready} onClick={() => tx.send({ address: c.gate, abi: gateAbi, functionName: 'resume', args: [] })}>
          Resume
        </Btn>
      </div>
      {!isOwner && <p className="mt-2 text-xs text-dk-faint">Only the guardian ({owner ? short(owner) : '…'}) can use these.</p>}
      <TxStatusLine status={tx.status} />
    </Panel>
  )
}

/** Labelled simulation: one transaction moves the demo clock and publishes the demo TSLA price. Operator only. */
function DemoControls({ s, now, feedDecimals }: { s: Snapshot; now: number; feedDecimals: number }) {
  const tx = useTx()
  const { operator, isOperator } = useDemoOperator()
  const [answer, setAnswer] = useState(() => (s.priceWad > 0n ? (Number(s.priceWad) / 1e18).toFixed(2) : '400'))
  const c = contracts!
  let parsed: bigint | undefined
  try {
    parsed = answer ? parseUnits(answer, feedDecimals) : undefined
  } catch {
    parsed = undefined
  }
  const inSession = now >= Number(s.open) && now < Number(s.close)
  const steps: { label: string; at: bigint }[] = [
    ...(inSession
      ? [
          { label: 'Preparation start', at: s.prepAt },
          { label: '45 min before close', at: s.close - 2700n },
          { label: 'Final window', at: s.finalAt },
          { label: 'Close + 1 h', at: s.close + 3600n },
        ]
      : []),
    { label: 'Open + 5 min (admission)', at: (inSession ? s.open : s.nextOpen) + 300n },
    { label: 'Open + 15 min (credit)', at: (inSession ? s.open : s.nextOpen) + 900n },
    ...(!inSession ? [{ label: 'Next open + 1 min', at: s.nextOpen + 60n }] : []),
  ]
    .filter(st => Number(st.at) > now)
    .sort((a, b) => Number(a.at - b.at))
  return (
    <Panel title="Market clock and stock price" aside={<span className="text-sm text-dk-sim">Operator controls</span>}>
      
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-sm text-dk-muted">
          TSLA price (USD)
          <input
            value={answer}
            onChange={e => setAnswer(e.target.value.replace(',', '.'))}
            inputMode="decimal"
            className="num mt-1 block w-28 rounded-md border border-dk-line bg-dk-bg px-3 py-1.5 text-dk-ink outline-none focus:border-dk-muted"
          />
        </label>
        {[-6, -3, 3].map(d => (
          <Btn key={d} onClick={() => setAnswer(((Number(answer) * (100 + d)) / 100).toFixed(2))}>
            {d > 0 ? `+${d}%` : `${d}%`}
          </Btn>
        ))}
        <Btn variant="primary" disabled={!isOperator || !parsed} onClick={() => parsed && tx.send({ address: c.demoController, abi: demoAbi, functionName: 'push', args: [parsed] })}>
          Publish price
        </Btn>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        {steps.map(st => (
          <Btn key={st.label} disabled={!isOperator || !parsed} onClick={() => parsed && tx.send({ address: c.demoController, abi: demoAbi, functionName: 'stepTo', args: [st.at, parsed] })}>
            {st.label} · {nyClock(st.at)}
          </Btn>
        ))}
      </div>
      {!isOperator && <p className="mt-2 text-xs text-dk-faint">Connect the clock operator ({operator ? short(operator) : '…'}) to use these.</p>}
      <TxStatusLine status={tx.status} />
    </Panel>
  )
}
