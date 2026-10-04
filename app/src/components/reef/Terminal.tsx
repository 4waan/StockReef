'use client'

import { useState } from 'react'
import type { Abi } from 'viem'
import { useAccount } from 'wagmi'
import { escrowAbi, marketAbi } from '@/generated/abi'
import { chain, contracts } from '@/lib/chain'
import { useDesk, type Marker } from '@/lib/desk'
import { hhmm, nyClock, pct, short, tokens, usdg } from '@/lib/format'
import type { HistoryItem } from '@/lib/history'
import { MARKET } from '@/lib/script'
import { exceeds, nextCloseLt, S, type Book, type Policy, type Position, type StepState } from '@/lib/scenario'
import { useBook, useSession } from '@/lib/session'
import { ClosedProtection, ControlledReopening, DebtReduction, FallingThreshold, FundedBuffer, PartialLiquidation, PositionMeter } from './features'
import { SessionChart, type ChartMode } from './SessionChart'
import { SignAction, Ticket, type Action, type TicketCtx } from './Ticket'
import { Loading, PhaseTag, Stat, Status, TabBar, TxRef, type Tone } from './ui'

/** The market bar: asset identity, scenario price, phase, clock and the market's contract limits. */
export function MarketBar({ cur, pol, book, steps }: { cur: StepState; pol: Policy; book: Book | undefined; steps: StepState[] }) {
  const s = cur.snapshot
  const quote = Number(cur.quoteWad) / 1e18
  const open = steps[0].step.quote
  const change = (quote / open - 1) * 100
  const milestone =
    s.phase === S.OPEN ? { label: 'Ramp starts', at: s.prepAt } : s.phase === S.PRE_CLOSE ? { label: 'Borrowing stops', at: s.finalAt } : s.phase === S.FINAL_WINDOW ? { label: 'Close', at: s.close } : s.phase === S.CLOSED ? { label: 'Reopens Mon', at: s.nextOpen } : s.phase === S.REOPEN_WAIT ? { label: 'Admission from', at: s.open + 300n } : s.phase === S.REOPEN_RECOVERY ? { label: 'Credit returns', at: s.creditAt } : undefined
  const apr = (Number(pol.ratePerSecond) * 31_536_000) / 1e16
  return (
    <div className="flex items-stretch gap-0 overflow-x-auto border-b border-dk-line whitespace-nowrap">
      <div className="flex items-center gap-3 border-r border-dk-line px-4 py-2">
        <img src={MARKET.logo} alt="" className="h-7 w-7 rounded-full bg-white p-1.5" />
        <div>
          <div className="text-[15px] font-semibold">{MARKET.pair}</div>
          <div className="text-[11px] text-dk-muted">{MARKET.company}</div>
        </div>
      </div>
      <Cell label={cur.step.accepted ? 'TSLA price' : 'Fresh quote (not admitted)'}>
        <span className={`text-[17px] ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`}>{quote.toFixed(2)}</span>
        <span className={`ml-2 text-xs ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`}>
          {change >= 0 ? '+' : ''}
          {change.toFixed(2)}%
        </span>
      </Cell>
      <Cell label="Session">
        <PhaseTag state={s.state} />
      </Cell>
      <Cell label="Scenario clock">
        {cur.step.day === 'mon' ? 'Mon' : 'Fri'} {nyClock(cur.t)} ET
      </Cell>
      {milestone && (
        <Cell label={milestone.label}>
          {nyClock(milestone.at)} <span className="text-dk-muted">· in {hhmm(Number(milestone.at - cur.t))}</span>
        </Cell>
      )}
      <Cell label="Liquidation threshold">
        <span className="text-dk-warn">{pct(s.ltWad, 2)}</span>
      </Cell>
      <Cell label="Borrow limit">{s.canBorrow ? pct(s.borrowLimitWad, 2) : <span className="text-dk-muted">locked</span>}</Cell>
      <Cell label="Available liquidity">{book ? `${usdg(book.cash)} USDG` : '—'}</Cell>
      <Cell label="Borrow rate">{apr.toFixed(2)}% fixed</Cell>
    </div>
  )
}

function Cell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col justify-center border-r border-dk-line/60 px-4 py-2 last:border-r-0">
      <div className="text-[11px] text-dk-muted">{label}</div>
      <div className="num mt-0.5 text-sm font-medium">{children}</div>
    </div>
  )
}

/** Four tiles: what the borrower must know about the position right now. */
export function RiskTiles({ p, cur, pol, markers }: { p: Position; cur: StepState; pol: Policy; markers: Marker[] }) {
  const s = cur.snapshot
  // A buffer repayment confirmed this weekend, at or before the scenario step.
  const executed = markers.filter(m => m.item.kind === 'Buffer repaid' && m.t <= Number(cur.t) + 3600).at(-1)
  const beforeClose = s.phase <= S.FINAL_WINDOW
  const need = p.repayToTarget >= 10_000n
  const above = exceeds(p.debt, p.value, s.ltWad)
  const tiles: { k: string; tone: Tone; head: React.ReactNode; body: React.ReactNode }[] = [
    {
      k: 'Before the close',
      tone: need && beforeClose ? 'warn' : 'up',
      head: !beforeClose ? 'Closure under way' : need ? `Repay ${usdg(p.repayToTarget)} USDG` : 'On plan',
      body: !beforeClose ? (p.missed ? `Missed: ${usdg(p.exposure)} USDG above plan` : 'Entered the closure on plan') : need ? `or add ${tokens(p.addRawToTarget, 4)} TSLA by ${nyClock(s.phase === S.FINAL_WINDOW ? s.close : s.finalAt)} ET` : `at or below ${pct(p.planTargetWad, 0)}`,
    },
    {
      k: 'Falling threshold',
      tone: above ? 'down' : 'warn',
      head: `${pct(s.ltWad, 2)} now → ${pct(nextCloseLt(cur, pol), 0)}`,
      body: `Your LTV ${pct(p.ltvWad, 2)} · ${above ? 'above' : 'below'} the threshold`,
    },
    executed ? {
      k: 'Funded buffer',
      tone: 'up',
      head: `Repaid ${usdg(executed.item.amount)} USDG`,
      body: <>confirmed at {nyClock(executed.t)} ET · <TxRef hash={executed.item.hash}>receipt</TxRef></>,
    } : {
      k: 'Funded buffer',
      tone: p.bufferNow > 0n ? 'warn' : p.bufferNext > 0n ? 'up' : p.plan.targetWad > 0n && p.plan.expiry <= cur.t ? 'down' : 'muted',
      head: p.bufferNow > 0n ? `${usdg(p.bufferNow)} USDG executable now` : p.bufferNext > 0n ? `${usdg(p.bufferNext)} USDG armed` : p.plan.targetWad > 0n && p.plan.expiry <= cur.t ? 'Authorization expired' : `${usdg(p.plan.balance)} USDG funded`,
      body: p.plan.targetWad > 0n ? `target ${pct(p.plan.targetWad, 0)} · cap ${usdg(p.plan.perSessionCap)} / session` : 'not authorized',
    },
    {
      k: 'Partial liquidation',
      tone: p.trimNow.eligible ? 'down' : p.trimAtFinal.eligible && beforeClose ? 'warn' : 'up',
      head: p.trimNow.eligible ? `Eligible · ${usdg(p.trimNow.repaid)} USDG` : p.trimAtFinal.eligible && beforeClose ? `Eligible from ${nyClock(s.finalAt)}` : 'Not eligible',
      body: p.trimNow.eligible ? `${tokens(p.trimNow.collateralOut, 5)} TSLA at ${pct(p.trimNow.bonusWad, 0)} bonus${p.trimNow.bufferPending ? ' · buffer first' : ''}` : 'only above the threshold',
    },
  ]
  return (
    <div className="grid grid-cols-2 border-b border-dk-line xl:grid-cols-4">
      {tiles.map((t, i) => (
        <div key={t.k} className={`px-4 py-3 ${i % 2 ? 'border-l' : ''} ${i >= 2 ? 'border-t xl:border-t-0' : ''} ${i === 2 ? 'xl:border-l' : ''} border-dk-line`}>
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-semibold tracking-[.12em] text-[#e88a5a] uppercase">{t.k}</span>
            <Status tone={t.tone}>{''}</Status>
          </div>
          <div className="num mt-1 text-[15px] font-semibold">{t.head}</div>
          <div className="num mt-0.5 text-xs text-dk-muted">{t.body}</div>
        </div>
      ))}
    </div>
  )
}

type Panel = 'position' | 'plan' | 'buffer' | 'liquidation' | 'protection' | 'activity'

/** Below the chart: the position and each feature in detail, and the account's receipts. */
export function PositionPanels({ d, ctx }: { d: ReturnType<typeof useDesk>; ctx: TicketCtx }) {
  const [tab, setTab] = useState<Panel>('position')
  const p = d.position!
  const cur = d.current!
  const pol = d.policy!
  return (
    <section className="border-t border-dk-line">
      <TabBar
        tabs={[
          { key: 'position', label: 'Position' },
          { key: 'plan', label: 'Closure plan' },
          { key: 'buffer', label: 'Funded buffer' },
          { key: 'liquidation', label: 'Partial liquidation' },
          { key: 'protection', label: 'Protection & reopening' },
          { key: 'activity', label: `Activity (${d.items.length})` },
        ]}
        value={tab}
        onChange={setTab}
      />
      <div className="p-4">
        {tab === 'position' && <PositionTable p={p} cur={cur} label={d.label} />}
        {tab === 'plan' && (
          <div className="grid gap-4 xl:grid-cols-2">
            <DebtReduction p={p} cur={cur} steps={d.steps!} />
            <FallingThreshold p={p} cur={cur} pol={pol} ltPath={d.ltPath} steps={d.steps!} />
          </div>
        )}
        {tab === 'buffer' && (
          <div className="grid gap-4 xl:grid-cols-[1.4fr_1fr]">
            <FundedBuffer p={p} cur={cur} items={d.items} />
            <RunBuffer ctx={ctx} p={p} />
          </div>
        )}
        {tab === 'liquidation' && (
          <div className="grid gap-4 xl:grid-cols-[1.4fr_1fr]">
            <PartialLiquidation p={p} cur={cur} />
            <SubmitTrim ctx={ctx} p={p} />
          </div>
        )}
        {tab === 'protection' && (
          <div className="grid gap-4 xl:grid-cols-2">
            <ClosedProtection cur={cur} p={p} />
            <ControlledReopening cur={cur} steps={d.steps!} />
          </div>
        )}
        {tab === 'activity' && <Activity items={d.items} markers={d.markers} />}
      </div>
    </section>
  )
}

function PositionTable({ p, cur, label }: { p: Position; cur: StepState; label: string | undefined }) {
  const s = cur.snapshot
  const head = ['Market', 'Collateral', 'Value', 'Debt', 'LTV', 'Threshold', 'Plan', 'Buffer', 'Status']
  const above = exceeds(p.debt, p.value, s.ltWad)
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[820px] text-sm">
        <thead>
          <tr className="text-left text-xs text-dk-muted">
            {head.map(h => (
              <th key={h} className="pb-2 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="num">
          <tr className="border-t border-dk-line">
            <td className="py-2.5">
              {MARKET.pair} <span className="ml-1 text-xs text-dk-faint">{label}</span>
            </td>
            <td>{tokens(p.collateral, 4)} TSLA</td>
            <td>
              {usdg(p.value)} USDG{cur.indicative && <span className="ml-1 text-xs text-dk-warn">indicative</span>}
            </td>
            <td>{usdg(p.debt)} USDG</td>
            <td className={above ? 'text-dk-down' : p.ltvWad > p.planTargetWad ? 'text-dk-warn' : 'text-dk-up'}>{p.debt ? pct(p.ltvWad, 2) : '—'}</td>
            <td className="text-dk-warn">{pct(s.ltWad, 2)}</td>
            <td>{p.repayToTarget >= 10_000n ? `repay ${usdg(p.repayToTarget)}` : 'on plan'}</td>
            <td>{usdg(p.plan.balance)} USDG</td>
            <td>{p.trimNow.eligible ? <span className="text-dk-down">Trim eligible</span> : p.missed ? <span className="text-dk-down">Missed execution</span> : above ? <span className="text-dk-down">Above threshold</span> : <span className="text-dk-up">Healthy</span>}</td>
          </tr>
        </tbody>
      </table>
      <p className="mt-3 text-xs text-dk-faint">Debt from StockReefMarket.debtAt at the scenario time; collateral and plan from the chain; value from PriceGate.valueOf at the scenario price.</p>
    </div>
  )
}

/** Anyone can execute a funded buffer once it is executable: the keeper normally does. */
function RunBuffer({ ctx, p }: { ctx: TicketCtx; p: Position }) {
  const call = ctx.account ? { address: contracts!.escrow, abi: escrowAbi as Abi, functionName: 'executeBuffer', args: [ctx.account] } : undefined
  return (
    <div className="rounded-lg border border-dk-line bg-dk-panel p-4">
      <div className="text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">Execute the plan</div>
      <p className="mt-1 text-sm text-dk-muted">Permissionless: any wallet may submit it. It repays from the borrower&apos;s escrow and pays no reward.</p>
      <div className="mt-3">
        <Stat label="Executable now" value={`${usdg(p.bufferNow)} USDG`} tone={p.bufferNow ? 'warn' : 'muted'} sub="RepaymentEscrow.executableAmount at this step" />
      </div>
      <SignAction label={`Run buffer · ${usdg(p.bufferNow)} USDG`} call={call} blocked={p.bufferNow === 0n ? 'Nothing executable at this step' : undefined} ctx={{ ...ctx, canSign: ctx.walletReady }} />
    </div>
  )
}

/** A liquidator trims an eligible loan with their own USDG; the bonus is paid in TSLA. */
function SubmitTrim({ ctx, p }: { ctx: TicketCtx; p: Position }) {
  const { chainTime } = useSession()
  const { address } = useAccount()
  const q = p.trimNow
  const call =
    ctx.account && chainTime !== undefined && q.repaid > 0n
      ? { address: contracts!.market, abi: marketAbi as Abi, functionName: 'trim', args: [ctx.account, q.repaid, (q.collateralOut * 99n) / 100n, chainTime + 900n] }
      : undefined
  const self = !!address && ctx.account?.toLowerCase() === address.toLowerCase()
  return (
    <div className="rounded-lg border border-dk-line bg-dk-panel p-4">
      <div className="text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">Liquidator action</div>
      <p className="mt-1 text-sm text-dk-muted">The liquidator supplies USDG, the loan shrinks, and they receive TSLA at the accepted price plus the bonus. Switch the wallet to the liquidator profile to sign.</p>
      <div className="mt-3 grid grid-cols-2 gap-3">
        <Stat label="Repays" value={`${usdg(q.repaid)} USDG`} />
        <Stat label="Receives" value={`${tokens(q.collateralOut, 5)} TSLA`} sub="1% slippage floor" />
      </div>
      <SignAction
        label={`Trim · repay ${usdg(q.repaid)} USDG`}
        call={call}
        approve={call ? { token: contracts!.loanToken, spender: contracts!.market, amount: q.repaid, symbol: 'USDG', decimals: 6 } : undefined}
        blocked={!q.eligible ? 'Not eligible at this step' : q.bufferPending ? 'The funded buffer must run first' : self ? 'Use a liquidator wallet, not the borrower' : undefined}
        ctx={{ ...ctx, canSign: ctx.walletReady }}
      />
    </div>
  )
}

function Activity({ items, markers }: { items: HistoryItem[]; markers: ReturnType<typeof useDesk>['markers'] }) {
  if (!items.length) return <p className="text-sm text-dk-muted">No transactions for this account yet.</p>
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[720px] text-sm">
        <thead>
          <tr className="text-left text-xs text-dk-muted">
            {['Testnet time (ET)', 'Event', 'Amount', 'Debt after', 'Collateral after', 'On the session chart', 'Receipt'].map(h => (
              <th key={h} className="pb-2 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="num">
          {items.slice(0, 30).map(e => {
            const m = markers.find(x => x.item.hash === e.hash && x.item.logIndex === e.logIndex)
            return (
              <tr key={e.hash + e.logIndex} className="border-t border-dk-line">
                <td className="py-2">{new Date(e.t * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })}</td>
                <td>
                  {e.kind}
                  {e.detail && <span className="ml-2 text-xs text-dk-faint">{e.detail}</span>}
                </td>
                <td>{e.unit === 'TSLA' ? `${tokens(e.amount, 4)} TSLA` : e.unit === 'USDG' ? `${usdg(e.amount)} USDG` : '—'}</td>
                <td>{e.debtAfter !== undefined ? `${usdg(e.debtAfter)} USDG` : '—'}</td>
                <td>{tokens(e.collateralAfter, 4)} TSLA</td>
                <td className="text-dk-muted">{m ? `${nyClock(m.t)}${m.placed ? ' (signed at this step)' : ''}` : '—'}</td>
                <td>
                  <TxRef hash={e.hash} />
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

/** The trading terminal: chart in the main area, persistent ticket on the right, position and activity below. */
export function TerminalPage() {
  const d = useDesk()
  const { data: book } = useBook()
  const { address, chainId, isConnected } = useAccount()
  const [mode, setMode] = useState<ChartMode>('ltv')
  const [tab, setTab] = useState<Action>('repay')
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (d.error) return <Loading>Could not read the scenario from the contracts: {d.error}</Loading>
  if (!d.anchor || !d.policy || !d.steps || !d.current) return <Loading />
  const cur = d.current
  const canSign = d.own && isConnected && chainId === chain.id
  const signHint = !isConnected ? 'Connect wallet to sign' : chainId !== chain.id ? `Switch to chain ${chain.id}` : `Viewing ${d.label}: read only`
  const walletReady = isConnected && chainId === chain.id
  const ctx: TicketCtx = { account: d.viewing, canSign, walletReady, signHint, p: d.position, cur, pol: d.policy, book }
  const p = d.position
  return (
    <div className="flex flex-1 flex-col">
      <MarketBar cur={cur} pol={d.policy} book={book} steps={d.steps} />
      <div className="grid flex-1 lg:grid-cols-[minmax(0,1fr)_380px]">
        <div className="flex min-w-0 flex-col">
          {p ? <RiskTiles p={p} cur={cur} pol={d.policy} markers={d.markers} /> : <Loading>Reading the position…</Loading>}
          <div className="flex items-center justify-between border-b border-dk-line px-4 py-2">
            <div className="flex items-center gap-3 text-sm">
              <span className="font-semibold">{mode === 'ltv' ? 'LTV against the falling threshold' : 'TSLA price'}</span>
              <span className="text-xs text-dk-faint">Friday close → Monday reopening</span>
            </div>
            <div className="flex rounded-md border border-dk-line p-0.5 text-xs">
              {(['ltv', 'price'] as const).map(k => (
                <button key={k} type="button" aria-pressed={mode === k} onClick={() => setMode(k)} className={`rounded px-3 py-1 ${mode === k ? 'bg-dk-raised font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}>
                  {k === 'ltv' ? 'LTV' : 'Price'}
                </button>
              ))}
            </div>
          </div>
          <SessionChart anchor={d.anchor} steps={d.steps} at={d.at} obs={d.obs} ltPath={d.ltPath} markers={d.markers} collateral={p?.collateral} debt={p?.debt} target={p ? Number(p.planTargetWad) / 1e18 : undefined} mode={mode} />
          {p && (
            <div className="border-t border-dk-line px-4">
              <PositionMeter p={p} cur={cur} pol={d.policy} />
            </div>
          )}
        </div>
        <aside className="border-dk-line lg:border-l">
          {d.viewing && !d.own && (
            <p className="border-b border-dk-line px-4 py-2 text-xs text-dk-muted">
              Viewing {d.label} ({d.viewing ? short(d.viewing) : ''}) · read only
              {address && (
                <button type="button" onClick={() => d.pick(address)} className="ml-2 text-dk-up hover:underline">
                  Your wallet
                </button>
              )}
            </p>
          )}
          <Ticket tab={tab} onTab={setTab} {...ctx} />
        </aside>
      </div>
      {p && <PositionPanels d={d} ctx={ctx} />}
    </div>
  )
}

