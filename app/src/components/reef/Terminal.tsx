'use client'

import { useState, type ReactNode } from 'react'
import type { Abi } from 'viem'
import { useAccount } from 'wagmi'
import { escrowAbi, marketAbi } from '@/generated/abi'
import { chain, contracts } from '@/lib/chain'
import { useDesk, type Marker } from '@/lib/desk'
import { hhmm, nyClock, pct, pctOf, tokens, usdg } from '@/lib/format'
import { EXECUTION_KINDS, type HistoryItem } from '@/lib/history'
import { MARKET } from '@/lib/script'
import { exceeds, nextCloseLt, S, type Book, type Policy, type Position, type StepState } from '@/lib/scenario'
import { useBook, useSession } from '@/lib/session'
import { ClosedProtection, ControlledReopening, DebtReduction, FallingThreshold, FundedBuffer, PartialLiquidation } from './features'
import { OraclePill } from './Oracle'
import { SessionChart, type ChartMode } from './SessionChart'
import { SignAction, Ticket, type Action, type TicketCtx } from './Ticket'
import { KV, Loading, PhaseTag, Pop, Status, TabBar, TxRef, type Tone, toneText } from './ui'

/** The market bar, one row: identity, price, phase, clock, the two limits that move; the rest behind "Market". */
export function MarketBar({ cur, pol, book, steps }: { cur: StepState; pol: Policy; book: Book | undefined; steps: StepState[] }) {
  const s = cur.snapshot
  const quote = Number(cur.quoteWad) / 1e18
  const change = (quote / steps[0].step.quote - 1) * 100
  const milestone: [string, bigint] | undefined =
    s.phase === S.OPEN ? ['Ramp', s.prepAt] : s.phase === S.PRE_CLOSE ? ['Borrow stops', s.finalAt] : s.phase === S.FINAL_WINDOW ? ['Close', s.close] : s.phase === S.CLOSED ? ['Reopens', s.nextOpen] : s.phase === S.REOPEN_WAIT ? ['Admission', s.open + 300n] : s.phase === S.REOPEN_RECOVERY ? ['Credit', s.creditAt] : undefined
  const apr = (Number(pol.ratePerSecond) * 31_536_000) / 1e16
  return (
    <div className="flex h-12 items-center gap-5 overflow-x-auto border-b border-dk-line px-4 whitespace-nowrap">
      <span className="flex items-center gap-2">
        <img src={MARKET.logo} alt="" className="h-6 w-6 rounded-full bg-white p-1" />
        <span className="text-[15px] font-semibold">{MARKET.pair}</span>
      </span>
      <span className="num flex items-baseline gap-1.5">
        <span className={`text-lg font-semibold ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`}>{quote.toFixed(2)}</span>
        <span className={`text-xs ${change < 0 ? 'text-dk-down' : 'text-dk-up'}`}>
          {change >= 0 ? '+' : ''}
          {change.toFixed(2)}%
        </span>
        {!cur.step.accepted && <span className="text-[11px] text-dk-warn">not admitted</span>}
      </span>
      <PhaseTag state={s.state} />
      <Cell k={`${cur.step.day === 'mon' ? 'Mon' : 'Fri'} ET`} v={nyClock(cur.t)} />
      {milestone && <Cell k={milestone[0]} v={`in ${hhmm(Number(milestone[1] - cur.t))}`} />}
      <Cell k="Threshold" v={pct(s.ltWad, 2)} tone="warn" />
      <Cell k="Borrow limit" v={s.canBorrow ? pct(s.borrowLimitWad, 2) : 'locked'} tone={s.canBorrow ? 'ink' : 'muted'} />
      <span className="ml-auto">
        <Pop label="Market details" align="right" panelClass="w-72" trigger={<span className="rounded-md border border-dk-line px-2.5 py-1 text-xs text-dk-muted hover:border-dk-muted hover:text-dk-ink">Market ▾</span>}>
          <KV label="Collateral" value="TSLA" />
          <KV label="Loan asset" value="USDG" />
          <KV label="Liquidity" value={book ? `${usdg(book.cash)} USDG` : '—'} />
          <KV label="Utilization" value={book ? pct(book.utilizationWad, 1) : '—'} hint={`cap ${pct(pol.utilizationCap, 0)}`} />
          <KV label="Borrow rate" value={`${apr.toFixed(2)}% fixed`} />
          <KV label="Bonus" value={`${pct(pol.bonusScheduling, 0)} / ${pct(pol.bonusDistress, 0)}`} hint="scheduling / recovery" />
          <div className="mt-2">
            <OraclePill align="left" side="bottom" />
          </div>
        </Pop>
      </span>
    </div>
  )
}

function Cell({ k, v, tone = 'ink' }: { k: string; v: ReactNode; tone?: Tone }) {
  return (
    <span className="flex flex-col leading-tight">
      <span className="text-[10px] text-dk-muted uppercase">{k}</span>
      <span className={`num text-sm font-medium ${toneText[tone]}`}>{v}</span>
    </span>
  )
}

/** A tile: one label, one bold value, one short line; clicking opens the full control and its action. */
function Tile({ k, tone, head, sub, children }: { k: string; tone: Tone; head: ReactNode; sub: ReactNode; children: ReactNode }) {
  return (
    <Pop
      label={k}
      panelClass="w-[440px] max-w-[90vw] !p-0 !border-0 !bg-transparent"
      className="min-w-0"
      trigger={
        <span className="block h-full px-4 py-2.5 hover:bg-dk-raised">
          <span className="flex items-center justify-between">
            <span className="text-[10px] font-semibold tracking-[.12em] text-accent uppercase">{k}</span>
            <Status tone={tone}>{''}</Status>
          </span>
          <span className={`num mt-0.5 block truncate text-[15px] font-semibold ${tone === 'down' ? 'text-dk-down' : 'text-dk-ink'}`}>{head}</span>
          <span className="num block truncate text-[11px] text-dk-muted">{sub}</span>
        </span>
      }
    >
      {children}
    </Pop>
  )
}

/** The four controls that matter at this step: the close plan before the bell, protection and reopening after it. */
export function RiskTiles({ d, ctx }: { d: ReturnType<typeof useDesk>; ctx: TicketCtx }) {
  const p = d.position!
  const cur = d.current!
  const pol = d.policy!
  const steps = d.steps!
  const s = cur.snapshot
  const beforeClose = s.phase <= S.FINAL_WINDOW
  const need = p.repayToTarget >= 10_000n
  const above = exceeds(p.debt, p.value, s.ltWad)
  const nextT = d.at + 1 < steps.length ? Number(steps[d.at + 1].t) : Infinity
  const executed = d.markers.filter(m => m.item.kind === 'Buffer repaid' && m.t < nextT).at(-1)
  const monCredit = steps.find(x => x.step.id === 'admit')!.snapshot.creditAt
  const tiles = [
    beforeClose ? (
      <Tile key="close" k="Before the close" tone={need ? 'warn' : 'up'} head={need ? `Repay ${usdg(p.repayToTarget)}` : 'On plan'} sub={need ? `or +${tokens(p.addRawToTarget, 4)} TSLA by ${nyClock(s.phase === S.FINAL_WINDOW ? s.close : s.finalAt)}` : `≤ ${pct(p.planTargetWad, 0)} target`}>
        <DebtReduction p={p} cur={cur} />
      </Tile>
    ) : (
      <Tile key="protect" k="Protection" tone={s.canBorrow ? 'up' : 'muted'} head={s.canBorrow ? 'Credit open' : 'Credit locked'} sub="repay and add TSLA always work">
        <ClosedProtection cur={cur} />
      </Tile>
    ),
    beforeClose ? (
      <Tile key="lt" k="Threshold" tone={above ? 'down' : 'warn'} head={`${pct(s.ltWad, 2)} → ${pct(nextCloseLt(cur, pol), 0)}`} sub={`your LTV ${pct(p.ltvWad, 2)}`}>
        <FallingThreshold p={p} cur={cur} pol={pol} ltPath={d.ltPath} steps={steps} />
      </Tile>
    ) : (
      <Tile key="reopen" k="Reopening" tone={s.phase === S.REOPEN_WAIT ? 'warn' : s.phase === S.CLOSED ? 'muted' : 'up'} head={s.phase === S.CLOSED ? `Mon ${nyClock(s.nextOpen)}` : s.admissionAt ? `Admitted ${nyClock(s.admissionAt)}` : 'Awaiting price'} sub={`credit returns ${nyClock(monCredit)}`}>
        <ControlledReopening cur={cur} steps={steps} />
      </Tile>
    ),
    <Tile
      key="buffer"
      k="Funded buffer"
      tone={executed ? 'up' : p.bufferNow > 0n ? 'warn' : p.bufferNext > 0n ? 'up' : 'muted'}
      head={executed ? `Repaid ${usdg(executed.item.amount)}` : p.bufferNow > 0n ? `${usdg(p.bufferNow)} ready` : p.bufferNext > 0n ? `${usdg(p.bufferNext)} armed` : `${usdg(p.plan.balance)} funded`}
      sub={executed ? `confirmed ${nyClock(executed.t)}` : p.plan.targetWad > 0n ? `${pct(p.plan.targetWad, 0)} target · cap ${usdg(p.plan.perSessionCap)}` : 'not authorized'}
    >
      <FundedBuffer p={p} cur={cur} items={d.items} action={<RunBuffer ctx={ctx} p={p} />} />
    </Tile>,
    <Tile
      key="trim"
      k="Liquidation"
      tone={p.trimNow.eligible ? 'down' : p.trimAtFinal.eligible && beforeClose ? 'warn' : 'up'}
      head={p.trimNow.eligible ? `Eligible · ${usdg(p.trimNow.repaid)}` : 'Not eligible'}
      sub={p.trimNow.eligible ? `${pct(p.trimNow.bonusWad, 0)} bonus${p.trimNow.bufferPending ? ' · buffer first' : ''}` : 'only above threshold'}
    >
      <PartialLiquidation p={p} cur={cur} action={<SubmitTrim ctx={ctx} p={p} />} />
    </Tile>,
  ]
  return <div className="grid grid-cols-2 divide-x divide-dk-line border-b border-dk-line xl:grid-cols-4">{tiles}</div>
}

/** Anyone can execute a funded buffer once it is executable: the keeper normally does. */
function RunBuffer({ ctx, p }: { ctx: TicketCtx; p: Position }) {
  const call = ctx.account ? { address: contracts!.escrow, abi: escrowAbi as Abi, functionName: 'executeBuffer', args: [ctx.account] } : undefined
  return <SignAction label={`Run buffer · ${usdg(p.bufferNow)} USDG`} call={call} blocked={p.bufferNow === 0n ? 'Nothing executable now' : undefined} ctx={{ ...ctx, canSign: ctx.walletReady }} />
}

/** A liquidator trims an eligible loan with their own USDG; the bonus is paid in TSLA. */
function SubmitTrim({ ctx, p }: { ctx: TicketCtx; p: Position }) {
  const { chainTime } = useSession()
  const { address } = useAccount()
  const q = p.trimNow
  const call = ctx.account && chainTime !== undefined && q.repaid > 0n ? { address: contracts!.market, abi: marketAbi as Abi, functionName: 'trim', args: [ctx.account, q.repaid, (q.collateralOut * 99n) / 100n, chainTime + 900n] } : undefined
  const self = !!address && ctx.account?.toLowerCase() === address.toLowerCase()
  return (
    <SignAction
      label={`Trim as liquidator · ${usdg(q.repaid)} USDG`}
      call={call}
      approve={call ? { token: contracts!.loanToken, spender: contracts!.market, amount: q.repaid, symbol: 'USDG', decimals: 6 } : undefined}
      blocked={!q.eligible ? 'Not eligible now' : q.bufferPending ? 'Buffer must run first' : self ? 'Switch to a liquidator wallet' : undefined}
      ctx={{ ...ctx, canSign: ctx.walletReady }}
    />
  )
}

/** The last confirmed transaction for this account, as a state change: what moved, before → after, and the receipt. */
export function StateChange({ items }: { items: HistoryItem[] }) {
  const e = items.find(i => EXECUTION_KINDS.includes(i.kind) || i.kind === 'Collateral added' || i.kind === 'Collateral withdrawn')
  if (!e) return null
  const collChanged = e.collateralBefore !== e.collateralAfter
  return (
    <section className="border-t border-dk-line px-4 py-3" aria-label="Last state change">
      <div className="flex items-center gap-2">
        <span className="text-[11px] font-semibold tracking-[.12em] text-accent uppercase">State change</span>
        <span className="ml-auto text-[11px] text-dk-up">● confirmed</span>
      </div>
      <div className="num mt-1 text-[15px] font-semibold">
        {e.kind} {e.unit === 'USDG' ? `${usdg(e.amount)} USDG` : e.unit === 'TSLA' ? `${tokens(e.amount, 4)} TSLA` : ''}
      </div>
      <div className="mt-1">
        {e.debtBefore !== undefined && e.debtAfter !== undefined && <KV label="Debt" before={usdg(e.debtBefore)} value={usdg(e.debtAfter)} tone={e.debtAfter < e.debtBefore ? 'up' : 'ink'} />}
        {e.ltvBefore !== undefined && <KV label="LTV" before={pctOf(e.ltvBefore)} value={pctOf(e.ltvAfter)} tone={e.ltvAfter !== undefined && e.ltvAfter < e.ltvBefore ? 'up' : 'ink'} />}
        {collChanged && <KV label="TSLA" before={tokens(e.collateralBefore, 4)} value={tokens(e.collateralAfter, 4)} />}
        <KV label="Receipt" value={<TxRef hash={e.hash} />} />
      </div>
    </section>
  )
}

function PositionRow({ p, cur, label }: { p: Position; cur: StepState; label: string | undefined }) {
  const s = cur.snapshot
  const above = exceeds(p.debt, p.value, s.ltWad)
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[720px] text-sm">
        <thead>
          <tr className="text-left text-[11px] text-dk-muted">
            {['Market', 'Collateral', 'Value', 'Debt', 'LTV', 'Threshold', 'Buffer', 'Status'].map(h => (
              <th key={h} className="px-4 pt-2 pb-1.5 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="num">
          <tr className="border-t border-dk-line [&>td]:px-4 [&>td]:py-2">
            <td>
              {MARKET.pair} <span className="text-xs text-dk-faint">{label}</span>
            </td>
            <td>{tokens(p.collateral, 4)}</td>
            <td>
              {usdg(p.value)}
              {cur.indicative && <span className="ml-1 text-[11px] text-dk-warn">ind.</span>}
            </td>
            <td>{usdg(p.debt)}</td>
            <td className={above ? 'text-dk-down' : p.ltvWad > p.planTargetWad ? 'text-dk-warn' : 'text-dk-up'}>{p.debt ? pct(p.ltvWad, 2) : '—'}</td>
            <td className="text-dk-warn">{pct(s.ltWad, 2)}</td>
            <td>{usdg(p.plan.balance)}</td>
            <td>{p.trimNow.eligible ? <span className="text-dk-down">Trim eligible</span> : p.missed ? <span className="text-dk-down">Missed</span> : <span className="text-dk-up">Healthy</span>}</td>
          </tr>
        </tbody>
      </table>
    </div>
  )
}

function Activity({ items, markers }: { items: HistoryItem[]; markers: Marker[] }) {
  if (!items.length) return <p className="px-4 py-3 text-sm text-dk-muted">No transactions yet.</p>
  return (
    <div className="max-h-56 overflow-auto">
      <table className="w-full min-w-[640px] text-sm">
        <thead>
          <tr className="text-left text-[11px] text-dk-muted">
            {['Session time', 'Event', 'Amount', 'Debt after', 'Receipt'].map(h => (
              <th key={h} className="px-4 pt-2 pb-1.5 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="num">
          {items.slice(0, 20).map(e => {
            const m = markers.find(x => x.item.hash === e.hash && x.item.logIndex === e.logIndex)
            return (
              <tr key={e.hash + e.logIndex} className="border-t border-dk-line [&>td]:px-4 [&>td]:py-1.5">
                <td className="text-dk-muted">{m ? `${new Date(m.t * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short' })} ${nyClock(m.t)}` : '—'}</td>
                <td>{e.kind}</td>
                <td>{e.unit === 'TSLA' ? `${tokens(e.amount, 4)} TSLA` : e.unit === 'USDG' ? `${usdg(e.amount)} USDG` : '—'}</td>
                <td>{e.debtAfter !== undefined ? usdg(e.debtAfter) : '—'}</td>
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
  const { chainId, isConnected } = useAccount()
  const [mode, setMode] = useState<ChartMode>('ltv')
  const [tab, setTab] = useState<Action>('repay')
  const [below, setBelow] = useState<'position' | 'activity'>('position')
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (d.error) return <Loading>Could not read the scenario from the contracts: {d.error}</Loading>
  if (!d.anchor || !d.policy || !d.steps || !d.current) return <Loading />
  const cur = d.current
  const canSign = d.own && isConnected && chainId === chain.id
  const walletReady = isConnected && chainId === chain.id
  const signHint = !isConnected ? 'Connect wallet to sign' : chainId !== chain.id ? `Switch to chain ${chain.id}` : `Viewing ${d.label} · read only`
  const ctx: TicketCtx = { account: d.viewing, canSign, walletReady, signHint, p: d.position, cur, pol: d.policy, book }
  const p = d.position
  return (
    <div className="flex flex-1 flex-col">
      <MarketBar cur={cur} pol={d.policy} book={book} steps={d.steps} />
      <div className="grid flex-1 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="flex min-w-0 flex-col">
          {p ? <RiskTiles d={d} ctx={ctx} /> : <Loading>Reading the position…</Loading>}
          <div className="flex items-center justify-between px-4 pt-2">
            <span className="text-sm font-semibold">{mode === 'ltv' ? 'LTV vs threshold' : 'TSLA price'}</span>
            <div className="flex rounded-md border border-dk-line p-0.5 text-xs">
              {(['ltv', 'price'] as const).map(k => (
                <button key={k} type="button" aria-pressed={mode === k} onClick={() => setMode(k)} className={`rounded px-2.5 py-0.5 ${mode === k ? 'bg-dk-raised font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}>
                  {k === 'ltv' ? 'LTV' : 'Price'}
                </button>
              ))}
            </div>
          </div>
          <SessionChart anchor={d.anchor} steps={d.steps} at={d.at} obs={d.obs} ltPath={d.ltPath} markers={d.markers} collateral={p?.collateral} debt={p?.debt} target={p ? Number(p.planTargetWad) / 1e18 : undefined} mode={mode} height={320} />
          {p && (
            <section className="border-t border-dk-line">
              <TabBar
                tabs={[
                  { key: 'position', label: 'Position' },
                  { key: 'activity', label: `Activity (${d.items.length})` },
                ]}
                value={below}
                onChange={setBelow}
              />
              {below === 'position' ? <PositionRow p={p} cur={cur} label={d.label} /> : <Activity items={d.items} markers={d.markers} />}
            </section>
          )}
        </div>
        <aside className="border-dk-line lg:border-l">
          {d.viewing && !d.own && <p className="border-b border-dk-line px-4 py-1.5 text-[11px] text-dk-muted">Viewing {d.label} · read only</p>}
          <Ticket tab={tab} onTab={setTab} {...ctx} />
          <StateChange items={d.items} />
        </aside>
      </div>
    </div>
  )
}
