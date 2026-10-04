'use client'

import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { formatUnits, parseUnits, type Abi, type Address } from 'viem'
import { useAccount, usePublicClient } from 'wagmi'
import { erc20Abi, escrowAbi, marketAbi } from '@/generated/abi'
import { chain, contracts } from '@/lib/chain'
import { nyClock, pct, tokens, usdg } from '@/lib/format'
import { revertReason, useTx, type TxStatus } from '@/lib/hooks'
import { ceilDiv, exceeds, ltvUp, S, valueOfRaw, WAD, type Book, type Policy, type Position, type StepState } from '@/lib/scenario'
import { useSession } from '@/lib/session'
import { KV, Note, TabBar, TxRef, type Tone } from './ui'

export type Action = 'repay' | 'collateral' | 'borrow' | 'buffer'

interface Ctx {
  account: Address | undefined
  /** The viewed account is the connected wallet, on the right chain. */
  canSign: boolean
  /** A wallet is connected on the right chain (for permissionless actions on someone else's loan). */
  walletReady: boolean
  signHint: string
  p: Position | undefined
  cur: StepState
  pol: Policy
  book: Book | undefined
}

type Call = { address: Address; abi: Abi; functionName: string; args: readonly unknown[] }
type Approve = { token: Address; spender: Address; amount: bigint; symbol: string; decimals: number }

/**
 * The action ticket: one tab per borrower action. Each shows a review of the result before signing (debt, LTV,
 * threshold and liquidation status after the action, at the scenario price), which session rules apply, and a
 * preflight of the exact transaction against the testnet. Approvals are for the exact amount only.
 */
export function Ticket({ tab, onTab, ...ctx }: Ctx & { tab: Action; onTab: (a: Action) => void }) {
  return (
    <div>
      <TabBar
        tabs={[
          { key: 'repay', label: 'Repay' },
          { key: 'collateral', label: 'Collateral' },
          { key: 'borrow', label: 'Borrow' },
          { key: 'buffer', label: 'Buffer' },
        ]}
        value={tab}
        onChange={onTab}
      />
      <div className="p-4">
        {!ctx.p ? (
          <p className="text-sm text-dk-muted">Reading the position…</p>
        ) : (
          <>
            {tab === 'repay' && <Repay {...ctx} p={ctx.p} />}
            {tab === 'collateral' && <Collateral {...ctx} p={ctx.p} />}
            {tab === 'borrow' && <Borrow {...ctx} p={ctx.p} />}
            {tab === 'buffer' && <Buffer {...ctx} p={ctx.p} />}
          </>
        )}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ shared

function parse(text: string, decimals: number): bigint | undefined {
  try {
    return text ? parseUnits(text.replace(',', '.'), decimals) : undefined
  } catch {
    return undefined
  }
}

const fmt = (v: bigint, decimals: number, digits: number) => {
  const [i, fr = ''] = formatUnits(v, decimals).split('.')
  const cut = fr.slice(0, digits).replace(/0+$/, '')
  return cut ? `${i}.${cut}` : i
}

function Amount({ value, onChange, unit, fills }: { value: string; onChange: (s: string) => void; unit: string; fills: { label: string; v: string }[] }) {
  return (
    <div>
      <div className="flex items-center rounded-md border border-dk-line bg-dk-bg px-3 focus-within:border-dk-muted">
        <input inputMode="decimal" aria-label={`Amount in ${unit}`} value={value} onChange={e => onChange(e.target.value)} placeholder="0.00" className="num w-full bg-transparent py-2.5 text-2xl text-dk-ink outline-none placeholder:text-dk-faint" />
        <span className="text-sm font-medium text-dk-muted">{unit}</span>
      </div>
      {fills.length > 0 && (
        <div className="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-xs">
          {fills.map(fl => (
            <button key={fl.label} type="button" onClick={() => onChange(fl.v)} className="text-dk-muted underline-offset-2 hover:text-dk-ink hover:underline">
              {fl.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function ltvTone(ltv: bigint, s: StepState['snapshot'], target: bigint): Tone {
  if (ltv > s.ltWad) return 'down'
  if (ltv > target) return 'warn'
  return 'up'
}

/** The review: position after the action at the scenario price, rule checks, and the testnet preflight. */
function Review({
  p,
  cur,
  debt,
  collateral,
  checks,
  extra,
}: {
  p: Position
  cur: StepState
  debt: bigint
  collateral: bigint
  checks: { ok: boolean; text: ReactNode }[]
  extra?: ReactNode
}) {
  const s = cur.snapshot
  const value = valueOfRaw(collateral, cur.valuationWad)
  const ltv = ltvUp(debt, value)
  const changed = debt !== p.debt || collateral !== p.collateral
  const eligibleBefore = exceeds(p.debt, p.value, s.ltWad)
  const eligibleAfter = exceeds(debt, value, s.ltWad)
  return (
    <div className="mt-4 rounded-md border border-dk-line bg-dk-bg/50">
      <div className="border-b border-dk-line px-3 py-2 text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">Review before signing</div>
      <div className="px-3">
        <KV label="Debt" before={changed && debt !== p.debt ? usdg(p.debt) : undefined} value={`${usdg(debt)} USDG`} />
        <KV label="Collateral" before={changed && collateral !== p.collateral ? tokens(p.collateral, 4) : undefined} value={`${tokens(collateral, 4)} TSLA`} />
        <KV label="LTV" before={changed && p.debt ? pct(p.ltvWad, 2) : undefined} value={debt ? pct(ltv, 2) : '—'} tone={debt ? ltvTone(ltv, s, p.planTargetWad) : 'ink'} />
        <KV label="Threshold now" value={pct(s.ltWad, 2)} tone="warn" hint={s.phase === S.PRE_CLOSE ? 'falling' : undefined} />
        <KV label={`Plan target`} value={pct(p.planTargetWad, 0)} tone={debt && ltv <= p.planTargetWad ? 'up' : 'muted'} hint={debt && ltv <= p.planTargetWad ? 'reached' : undefined} />
        <KV label="Partial liquidation" before={changed ? (eligibleBefore ? 'eligible' : 'not eligible') : undefined} value={eligibleAfter ? 'eligible' : 'not eligible'} tone={eligibleAfter ? 'down' : 'up'} />
        {extra}
      </div>
      <ul className="space-y-1 border-t border-dk-line px-3 py-2 text-xs">
        {checks.map((c, i) => (
          <li key={i} className={`flex gap-2 ${c.ok ? 'text-dk-muted' : 'text-dk-warn'}`}>
            <span aria-hidden className={c.ok ? 'text-dk-up' : 'text-dk-warn'}>
              {c.ok ? '✓' : '!'}
            </span>
            <span>{c.text}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/** Simulates the exact call against the testnet from the connected wallet, after checking the exact allowance. */
function usePreflight(call: Call | undefined, approve: Approve | undefined, enabled: boolean) {
  const client = usePublicClient({ chainId: chain.id })
  const { address } = useAccount()
  return useQuery({
    queryKey: ['preflight', address, call?.address, call?.functionName, JSON.stringify(call?.args ?? [], (_, v) => (typeof v === 'bigint' ? v.toString() : v)), approve?.amount.toString()],
    enabled: enabled && !!client && !!address && !!call,
    refetchInterval: 6_000,
    retry: false,
    queryFn: async (): Promise<{ ok: boolean; needsApproval: boolean; reason?: string }> => {
      if (approve) {
        const allowance = (await client!.readContract({ address: approve.token, abi: erc20Abi, functionName: 'allowance', args: [address!, approve.spender] })) as bigint
        if (allowance < approve.amount) return { ok: true, needsApproval: true }
      }
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        await client!.simulateContract({ ...(call as any), account: address })
        return { ok: true, needsApproval: false }
      } catch (e) {
        return { ok: false, needsApproval: false, reason: revertReason(e) }
      }
    },
  })
}

/** The sign button with the approval step, the testnet preflight, and the receipt. */
function Sign({ label, call, approve, blocked, ctx, onDone }: { label: string; call: Call | undefined; approve?: Approve; blocked?: string; ctx: Ctx; onDone?: () => void }) {
  const { record, current } = useSession()
  const tx = useTx(hash => {
    if (current) record({ hash, step: current.step.id, label })
    onDone?.()
  })
  const pre = usePreflight(call, approve, ctx.canSign && !blocked)
  const busy = tx.status.state === 'checking' || tx.status.state === 'approving' || tx.status.state === 'pending'
  const willApprove = pre.data?.needsApproval && approve
  const text = !ctx.canSign ? ctx.signHint : blocked ? blocked : busy ? 'Waiting for the wallet…' : willApprove ? `Approve ${fmt(approve.amount, approve.decimals, 4)} ${approve.symbol}, then ${label.charAt(0).toLowerCase()}${label.slice(1)}` : label
  return (
    <div className="mt-4">
      {willApprove && (
        <ol className="mb-2 space-y-0.5 text-xs text-dk-muted">
          <li>1. Approve exactly {fmt(approve.amount, approve.decimals, 6)} {approve.symbol} for this action, not an unlimited allowance</li>
          <li>2. {label}</li>
        </ol>
      )}
      <button
        type="button"
        disabled={!ctx.canSign || !!blocked || !call || busy || (pre.data && !pre.data.ok)}
        onClick={() => call && tx.send(call as never, approve)}
        className="w-full rounded-md bg-brand py-2.5 text-[15px] font-semibold text-white transition hover:bg-[#d36f39] disabled:cursor-not-allowed disabled:bg-dk-raised disabled:text-dk-muted"
      >
        {text}
      </button>
      {ctx.canSign && !blocked && pre.data && !pre.data.ok && (
        <p className="mt-2 text-xs text-dk-warn">
          The testnet would reject this now: <span className="num">{pre.data.reason}</span>. Nothing was sent. If the testnet is not on this step, the operator can move it there from the session bar.
        </p>
      )}
      {ctx.canSign && !blocked && pre.data?.ok && !pre.data.needsApproval && <p className="mt-2 text-xs text-dk-up">Testnet check passed: this exact transaction succeeds now.</p>}
      <StatusLine status={tx.status} />
    </div>
  )
}

function StatusLine({ status }: { status: TxStatus }) {
  if (status.state === 'idle') return null
  const text = {
    checking: 'Checking the transaction against the chain…',
    approving: 'Approve the exact amount in your wallet…',
    pending: 'Sign in your wallet, then waiting for the block…',
    mined: 'Confirmed on chain',
    rejected: 'Cancelled in the wallet. Nothing was sent.',
    failed: `Not sent: ${status.error}`,
  }[status.state]
  return (
    <p className={`mt-2 text-xs ${status.state === 'mined' ? 'text-dk-up' : status.state === 'failed' ? 'text-dk-down' : 'text-dk-muted'}`}>
      {text}
      {status.approvalHash && (
        <>
          {' · '}
          <TxRef hash={status.approvalHash}>approval</TxRef>
        </>
      )}
      {status.hash && (
        <>
          {' · '}
          <TxRef hash={status.hash}>receipt</TxRef>
        </>
      )}
    </p>
  )
}

// ------------------------------------------------------------------ Repay

function Repay(ctx: Ctx & { p: Position }) {
  const { p, cur, account, pol } = ctx
  const [text, setText] = useState('')
  const [from, setFrom] = useState<'wallet' | 'buffer'>('wallet')
  const amount = parse(text, 6)
  const source = from === 'wallet' ? p.wallet.usdg : p.plan.balance
  const paid = amount === undefined ? 0n : amount > p.debt ? p.debt : amount
  const debt = p.debt - paid
  const max = source < p.debt ? source : p.debt
  let blocked: string | undefined
  if (p.debt === 0n) blocked = 'No debt to repay'
  else if (!amount) blocked = 'Enter an amount'
  else if (amount > source) blocked = `Only ${usdg(source)} USDG in your ${from}`
  else if (debt > 0n && debt < pol.minLoan) blocked = `Leave at least ${usdg(pol.minLoan)} USDG or repay all`
  const c = contracts!
  // A full repayment sends a little more than the debt now, since interest accrues until the block; the market takes only what is owed.
  const sendAmount = amount && amount >= p.debt && from === 'wallet' ? (source < p.debt + 10_000n ? source : p.debt + 10_000n) : amount
  const call: Call | undefined = !account || !sendAmount ? undefined : from === 'wallet' ? { address: c.market, abi: marketAbi as Abi, functionName: 'repay', args: [sendAmount, account] } : { address: c.escrow, abi: escrowAbi as Abi, functionName: 'ownerRepay', args: [sendAmount] }
  return (
    <>
      <div className="mb-2 flex items-center justify-between text-xs">
        <span className="text-dk-muted">Repay from</span>
        <span className="flex gap-3">
          {(['wallet', 'buffer'] as const).map(k => (
            <button key={k} type="button" aria-pressed={from === k} onClick={() => setFrom(k)} className={from === k ? 'font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}>
              {k === 'wallet' ? `Wallet · ${usdg(p.wallet.usdg)}` : `Buffer · ${usdg(p.plan.balance)}`}
            </button>
          ))}
        </span>
      </div>
      <Amount
        value={text}
        onChange={setText}
        unit="USDG"
        fills={[
          ...(p.repayToTarget > 0n ? [{ label: `To ${pct(p.planTargetWad, 0)} plan · ${usdg(p.repayToTarget)}`, v: fmt(p.repayToTarget, 6, 6) }] : []),
          { label: `Max · ${usdg(max)}`, v: fmt(max, 6, 6) },
        ]}
      />
      <Review
        p={p}
        cur={cur}
        debt={debt}
        collateral={p.collateral}
        checks={[
          { ok: true, text: 'Repaying works in every session state, including while the market is closed.' },
          { ok: from === 'wallet' || p.plan.balance > 0n, text: from === 'buffer' ? 'Repaying from your own buffer works even while it is committed.' : 'Pays from your wallet; the market takes only the debt owed.' },
        ]}
      />
      <Sign label={`Repay ${amount ? usdg(paid) : ''} USDG`} call={call} approve={from === 'wallet' && sendAmount ? { token: c.loanToken, spender: c.market, amount: sendAmount, symbol: 'USDG', decimals: 6 } : undefined} blocked={blocked} ctx={ctx} onDone={() => setText('')} />
    </>
  )
}

// ------------------------------------------------------------------ Collateral

function Collateral(ctx: Ctx & { p: Position }) {
  const { p, cur, account } = ctx
  const s = cur.snapshot
  const [mode, setMode] = useState<'add' | 'withdraw'>('add')
  const [text, setText] = useState('')
  const amount = parse(text, 18)
  // Withdrawal with debt must keep debt within the borrow limit: collateral worth debt / B stays behind.
  const keepRaw = p.debt === 0n ? 0n : s.borrowLimitWad === 0n ? p.collateral : ceilDiv(ceilDiv(p.debt * WAD, s.borrowLimitWad) * 10n ** 30n, cur.valuationWad)
  const maxOut = p.collateral > keepRaw ? p.collateral - keepRaw : 0n
  const coll = amount === undefined ? p.collateral : mode === 'add' ? p.collateral + amount : p.collateral - (amount > p.collateral ? p.collateral : amount)
  let blocked: string | undefined
  if (!amount) blocked = 'Enter an amount'
  else if (mode === 'add' && amount > p.wallet.tsla) blocked = `Only ${tokens(p.wallet.tsla, 4)} TSLA in your wallet`
  else if (mode === 'withdraw' && p.debt > 0n && !s.canBorrow) blocked = 'Locked: withdrawals against debt need borrowing open'
  else if (mode === 'withdraw' && amount > maxOut) blocked = `At most ${tokens(maxOut, 4)} TSLA now`
  const c = contracts!
  const call: Call | undefined = !account || !amount ? undefined : mode === 'add' ? { address: c.market, abi: marketAbi as Abi, functionName: 'depositCollateral', args: [amount, account] } : { address: c.market, abi: marketAbi as Abi, functionName: 'withdrawCollateral', args: [amount, account] }
  return (
    <>
      <div className="mb-2 flex gap-3 text-xs">
        {(['add', 'withdraw'] as const).map(k => (
          <button key={k} type="button" aria-pressed={mode === k} onClick={() => setMode(k)} className={mode === k ? 'font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}>
            {k === 'add' ? `Add · wallet ${tokens(p.wallet.tsla, 4)}` : `Withdraw · ${tokens(maxOut, 4)} free`}
          </button>
        ))}
      </div>
      <Amount
        value={text}
        onChange={setText}
        unit="TSLA"
        fills={
          mode === 'add'
            ? [...(p.addRawToTarget > 0n ? [{ label: `To ${pct(p.planTargetWad, 0)} plan · ${tokens(p.addRawToTarget, 4)}`, v: fmt(p.addRawToTarget, 18, 6) }] : []), { label: 'Max', v: fmt(p.wallet.tsla, 18, 6) }]
            : [{ label: 'Max', v: fmt(maxOut, 18, 6) }]
        }
      />
      <Review
        p={p}
        cur={cur}
        debt={p.debt}
        collateral={coll}
        extra={<KV label="Collateral value" value={`${usdg(valueOfRaw(coll, cur.valuationWad))} USDG`} hint={cur.indicative ? 'indicative' : `at ${(Number(cur.valuationWad) / 1e18).toFixed(2)}`} />}
        checks={
          mode === 'add'
            ? [{ ok: true, text: 'Adding collateral works in every state and keeps your stock, unlike a trim.' }]
            : [
                { ok: p.debt === 0n || s.canBorrow, text: p.debt === 0n ? 'Without debt, a withdrawal needs no price.' : s.canBorrow ? `Must stay within the ${pct(s.borrowLimitWad, 1)} borrow limit.` : 'Debt-backed withdrawals are locked in this phase.' },
              ]
        }
      />
      <Sign label={`${mode === 'add' ? 'Add' : 'Withdraw'} ${amount ? tokens(amount, 4) : ''} TSLA`} call={call} approve={mode === 'add' && amount ? { token: c.collateralToken, spender: c.market, amount, symbol: 'TSLA', decimals: 18 } : undefined} blocked={blocked} ctx={ctx} onDone={() => setText('')} />
    </>
  )
}

// ------------------------------------------------------------------ Borrow

function Borrow(ctx: Ctx & { p: Position }) {
  const { p, cur, account, pol, book } = ctx
  const s = cur.snapshot
  const [text, setText] = useState('')
  const amount = parse(text, 6)
  const limit = (s.borrowLimitWad * p.value) / WAD
  const room = book ? (pol.utilizationCap * (book.cash + book.totalDebt)) / WAD - book.totalDebt : 0n
  const caps = [limit > p.debt ? limit - p.debt - 1n : 0n, book?.cash ?? 0n, room > 0n ? room : 0n]
  const capacity = s.canBorrow ? caps.reduce((a, b) => (b < a ? b : a)) : 0n
  const debt = p.debt + (amount ?? 0n)
  const apr = (Number(pol.ratePerSecond) * 31_536_000) / 1e18
  let blocked: string | undefined
  if (!s.canBorrow) blocked = s.phase === S.REOPEN_RECOVERY ? `Borrowing returns at ${nyClock(s.creditAt)} ET` : 'Borrowing is locked in this phase'
  else if (!amount) blocked = 'Enter an amount'
  else if (amount > capacity) blocked = `At most ${usdg(capacity)} USDG now`
  else if (p.debt === 0n && amount < pol.minLoan) blocked = `Minimum loan ${usdg(pol.minLoan)} USDG`
  const call: Call | undefined = account && amount ? { address: contracts!.market, abi: marketAbi as Abi, functionName: 'borrow', args: [amount, account] } : undefined
  return (
    <>
      <div className="mb-2 flex justify-between text-xs text-dk-muted">
        <span>Available now</span>
        <span className="num text-dk-ink">{usdg(capacity)} USDG</span>
      </div>
      <Amount value={text} onChange={setText} unit="USDG" fills={capacity > 0n ? [{ label: 'Max', v: fmt(capacity, 6, 6) }] : []} />
      <Review
        p={p}
        cur={cur}
        debt={debt}
        collateral={p.collateral}
        extra={
          <>
            <KV label="Borrow limit" value={s.canBorrow ? pct(s.borrowLimitWad, 2) : 'locked'} tone="brand" hint={s.phase === S.PRE_CLOSE ? 'threshold − 5 pp' : undefined} />
            <KV label="Rate" value={`${(apr * 100).toFixed(2)}% fixed`} />
            <KV label="Liquidity" value={`${usdg(book?.cash)} USDG`} hint={book ? `${pct(book.utilizationWad, 1)} used, ${pct(pol.utilizationCap, 0)} cap` : undefined} />
          </>
        }
        checks={[
          { ok: s.canBorrow, text: s.canBorrow ? 'Borrowing is open in this phase.' : s.phase === S.FINAL_WINDOW ? 'New borrowing stops 30 minutes before the close.' : s.phase === S.REOPEN_RECOVERY ? `New credit waits for the recovery window, until ${nyClock(s.creditAt)} ET.` : 'New credit is locked while the market is closed.' },
          { ok: !p.plan.targetWad || s.phase === S.OPEN || p.plan.expiry <= cur.t, text: 'An active buffer plan blocks new borrowing from preparation until the reopening.' },
        ]}
      />
      <Sign label={`Borrow ${amount ? usdg(amount) : ''} USDG`} call={call} blocked={blocked} ctx={ctx} onDone={() => setText('')} />
    </>
  )
}

// ------------------------------------------------------------------ Buffer

function Buffer(ctx: Ctx & { p: Position }) {
  const { p, cur, account, pol } = ctx
  const [mode, setMode] = useState<'fund' | 'authorize' | 'withdraw'>(p.plan.balance > 0n && (p.plan.targetWad === 0n || p.plan.expiry <= cur.t) ? 'authorize' : 'fund')
  const [text, setText] = useState('')
  const [target, setTarget] = useState(String(Number(pol.maxBufferTarget) / 1e16))
  const [cap, setCap] = useState(fmt(p.plan.perSessionCap > 0n ? p.plan.perSessionCap : p.plan.balance > 0n ? p.plan.balance : 7_000_000n, 6, 2))
  const [days, setDays] = useState('14')
  const amount = parse(text, 6)
  const c = contracts!
  // The plan must outlast the scenario's Monday recovery; expiry is counted from the testnet clock.
  const { chainTime } = useSession()
  const expiry = chainTime !== undefined ? chainTime + BigInt(Math.round(Number(days) * 86400)) : undefined
  const targetWad = parse(target, 16)
  const capRaw = parse(cap, 6)
  const committed = p.committed
  let blocked: string | undefined
  let call: Call | undefined
  let approve: Approve | undefined
  if (mode === 'fund') {
    if (!amount) blocked = 'Enter an amount'
    else if (amount > p.wallet.usdg) blocked = `Only ${usdg(p.wallet.usdg)} USDG in your wallet`
    if (account && amount) {
      call = { address: c.escrow, abi: escrowAbi as Abi, functionName: 'deposit', args: [amount, account] }
      approve = { token: c.loanToken, spender: c.escrow, amount, symbol: 'USDG', decimals: 6 }
    }
  } else if (mode === 'authorize') {
    if (committed) blocked = 'Committed until the reopening; change it while the market is open'
    else if (!targetWad || targetWad > pol.maxBufferTarget) blocked = `Target up to ${pct(pol.maxBufferTarget, 0)}`
    else if (!capRaw) blocked = 'Set a cap'
    else if (!expiry || Number(days) <= 0) blocked = 'Set how long it lasts'
    if (targetWad && capRaw && expiry) call = { address: c.escrow, abi: escrowAbi as Abi, functionName: 'authorize', args: [targetWad, capRaw, expiry] }
  } else {
    if (committed) blocked = 'Committed: use Repay → Buffer instead'
    else if (!amount) blocked = 'Enter an amount'
    else if (amount > p.plan.balance) blocked = `The buffer holds ${usdg(p.plan.balance)} USDG`
    if (account && amount) call = { address: c.escrow, abi: escrowAbi as Abi, functionName: 'withdraw', args: [amount, account] }
  }
  return (
    <>
      <div className="mb-3 flex gap-3 text-xs">
        {(['fund', 'authorize', 'withdraw'] as const).map(k => (
          <button key={k} type="button" aria-pressed={mode === k} onClick={() => setMode(k)} className={mode === k ? 'font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}>
            {k === 'fund' ? 'Fund' : k === 'authorize' ? 'Authorize' : 'Withdraw'}
          </button>
        ))}
      </div>
      {mode !== 'authorize' ? (
        <Amount value={text} onChange={setText} unit="USDG" fills={[{ label: `Max · ${usdg(mode === 'fund' ? p.wallet.usdg : p.plan.balance)}`, v: fmt(mode === 'fund' ? p.wallet.usdg : p.plan.balance, 6, 6) }, ...(mode === 'fund' && p.repayToTarget > p.plan.balance ? [{ label: `Cover the plan · ${usdg(p.repayToTarget - p.plan.balance)}`, v: fmt(p.repayToTarget - p.plan.balance, 6, 6) }] : [])]} />
      ) : (
        <div className="grid grid-cols-3 gap-2">
          <Field label="Target LTV" unit="%" value={target} onChange={setTarget} />
          <Field label="Cap / session" unit="USDG" value={cap} onChange={setCap} />
          <Field label="Lasts" unit="days" value={days} onChange={setDays} />
        </div>
      )}
      <div className="mt-4 rounded-md border border-dk-line bg-dk-bg/50 px-3">
        <div className="-mx-3 border-b border-dk-line px-3 py-2 text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">Review before signing</div>
        <KV label="Escrowed" before={mode !== 'authorize' && amount ? usdg(p.plan.balance) : undefined} value={`${usdg(mode === 'fund' ? p.plan.balance + (amount ?? 0n) : mode === 'withdraw' ? p.plan.balance - (amount && amount <= p.plan.balance ? amount : 0n) : p.plan.balance)} USDG`} />
        <KV label="Target" before={mode === 'authorize' && p.plan.targetWad ? pct(p.plan.targetWad, 0) : undefined} value={mode === 'authorize' && targetWad ? pct(targetWad, 0) : p.plan.targetWad ? pct(p.plan.targetWad, 0) : '—'} />
        <KV label="Cap per session" value={mode === 'authorize' && capRaw ? `${usdg(capRaw)} USDG` : p.plan.targetWad ? `${usdg(p.plan.perSessionCap)} USDG` : '—'} />
        <KV label="Plan needs" value={`${usdg(p.repayToTarget)} USDG`} hint={`to ${pct(p.planTargetWad, 0)}`} />
        <KV label="Would run" value={`${usdg(p.bufferNow || p.bufferNext)} USDG`} hint={p.bufferNow ? 'now' : p.bufferNextAt ? 'at the next window' : undefined} tone={p.bufferNow || p.bufferNext ? 'up' : 'muted'} />
      </div>
      <div className="mt-2">
        <Note>Your money in a separate escrow, never lender liquidity, earning nothing. From preparation, anyone can run it within your target and cap; it repays before any trim. Committed funds still repay through Repay → Buffer.</Note>
      </div>
      <Sign label={mode === 'fund' ? `Fund buffer ${amount ? usdg(amount) : ''} USDG` : mode === 'authorize' ? `Authorize ${target}% plan` : `Withdraw ${amount ? usdg(amount) : ''} USDG`} call={call} approve={approve} blocked={blocked} ctx={ctx} onDone={() => setText('')} />
    </>
  )
}

function Field({ label, unit, value, onChange }: { label: string; unit: string; value: string; onChange: (s: string) => void }) {
  return (
    <label className="block">
      <span className="text-xs text-dk-muted">{label}</span>
      <span className="mt-1 flex items-center rounded-md border border-dk-line bg-dk-bg px-2 focus-within:border-dk-muted">
        <input inputMode="decimal" value={value} onChange={e => onChange(e.target.value.replace(',', '.'))} className="num w-full bg-transparent py-1.5 text-sm outline-none" />
        <span className="text-[11px] text-dk-muted">{unit}</span>
      </span>
    </label>
  )
}

export { Sign as SignAction, type Call as TxCall, type Approve as TxApprove, type Ctx as TicketCtx }
