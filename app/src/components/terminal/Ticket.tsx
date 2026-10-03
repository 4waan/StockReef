'use client'

import { useEffect, useState, type ReactNode } from 'react'
import { formatUnits, maxUint256, parseUnits, type Address } from 'viem'
import { escrowAbi, marketAbi } from '@/generated/abi'
import { contracts } from '@/lib/chain'
import { nyTime, pct, pctOf, tokens, usdg } from '@/lib/format'
import { useMaxCollateralWithdraw, useTx, type ProtocolConstants } from '@/lib/hooks'
import { abovePlan, stateName, STATE_COPY } from '@/lib/policy'
import type { AccountData, MarketData } from '@/lib/types'
import { Line, Segmented, Select, Tabs, TxStatusLine } from './kit'

export type TicketTab = 'borrow' | 'repay' | 'collateral' | 'buffer'

const WAD = 10n ** 18n

interface Ctx {
  account: Address | undefined
  canSign: boolean
  signHint: string
  v: AccountData | undefined
  m: MarketData
  k: ProtocolConstants | undefined
  now: number
  usdgWallet: bigint | undefined
  tslaWallet: bigint | undefined
}

export function Ticket({ tab, onTab, ...ctx }: Ctx & { tab: TicketTab; onTab: (t: TicketTab) => void }) {
  return (
    <div>
      <Tabs
        tabs={[
          { key: 'borrow', label: 'Borrow' },
          { key: 'repay', label: 'Repay' },
          { key: 'collateral', label: 'Collateral' },
          { key: 'buffer', label: 'Buffer' },
        ]}
        value={tab}
        onChange={onTab}
      />
      <div className="px-6 pt-5 pb-5">
        {tab === 'borrow' && <BorrowForm {...ctx} />}
        {tab === 'repay' && <RepayForm {...ctx} />}
        {tab === 'collateral' && <CollateralForm {...ctx} />}
        {tab === 'buffer' && <BufferForm {...ctx} />}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ shared pieces

function useAmount(decimals: number, mined?: string) {
  const [text, setText] = useState('')
  const [isMax, setIsMax] = useState(false)
  useEffect(() => {
    if (mined) {
      setText('')
      setIsMax(false)
    }
  }, [mined])
  let amount: bigint | undefined
  try {
    amount = text ? parseUnits(text, decimals) : undefined
  } catch {
    amount = undefined
  }
  return {
    text,
    amount,
    isMax,
    set: (t: string, max = false) => {
      setText(t.replace(',', '.'))
      setIsMax(max)
    },
    fill: (v: bigint, max = false) => {
      setText(trim(formatUnits(v, decimals), decimals === 6 ? 2 : 4))
      setIsMax(max)
    },
    clear: () => {
      setText('')
      setIsMax(false)
    },
  }
}

function trim(s: string, digits: number) {
  const [i, f = ''] = s.split('.')
  const cut = f.slice(0, digits).replace(/0+$/, '')
  return cut ? `${i}.${cut}` : i
}

function Head({ title, aside }: { title: string; aside?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between">
      <h3 className="text-2xl font-semibold">{title}</h3>
      {aside}
    </div>
  )
}

function AmountBox({ value, onChange, unit, disabled }: { value: string; onChange: (s: string) => void; unit: string; disabled?: boolean }) {
  return (
    <div className="flex items-center rounded-md border border-dk-line bg-dk-bg px-4 focus-within:border-dk-muted">
      <input
        inputMode="decimal"
        value={value}
        disabled={disabled}
        onChange={e => onChange(e.target.value)}
        placeholder="0.00"
        className="num w-full bg-transparent py-3.5 text-[28px] text-dk-ink outline-none placeholder:text-dk-faint disabled:opacity-50"
      />
      <span className="text-[15px] text-dk-ink">{unit}</span>
    </div>
  )
}

function Chips({ max, onPick, disabled }: { max: bigint; onPick: (v: bigint, isMax: boolean) => void; disabled?: boolean }) {
  return (
    <div className="mt-3 grid grid-cols-4 gap-2">
      {[25n, 50n, 75n, 100n].map(p => (
        <button
          key={String(p)}
          type="button"
          disabled={disabled || max === 0n}
          onClick={() => onPick((max * p) / 100n, p === 100n)}
          className="rounded-md border border-dk-line py-2 text-[15px] hover:border-dk-muted disabled:opacity-40"
        >
          {p === 100n ? 'MAX' : `${p}%`}
        </button>
      ))}
    </div>
  )
}

function Submit({ label, disabled, onClick }: { label: string; disabled: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      className="mt-4 w-full rounded-md border border-dk-up bg-dk-up/10 py-3 text-[17px] font-medium text-dk-up transition hover:bg-dk-up/20 disabled:cursor-not-allowed disabled:border-dk-up/40 disabled:bg-dk-up/5 disabled:text-dk-muted"
    >
      {label}
    </button>
  )
}

function Note({ children, tone }: { children: ReactNode; tone?: 'warn' | 'down' }) {
  const c = tone === 'warn' ? 'text-dk-warn' : tone === 'down' ? 'text-dk-down' : 'text-dk-faint'
  return <p className={`mt-2 text-sm ${c}`}>{children}</p>
}

function closingLimit(m: MarketData, k: ProtocolConstants | undefined) {
  if (!k) return undefined
  return m.policy.closureClass === 1 ? k.ltFinalExtended : k.ltFinalOvernight
}

function ltvAfter(debt: bigint, value: bigint): number | undefined {
  if (debt === 0n) return 0
  if (value === 0n) return undefined
  return Number(debt) / Number(value)
}

/** Red above the threshold now, amber above the plan target, green otherwise. */
function ltvTone(ltv: number | undefined, m: MarketData, v: AccountData | undefined): 'up' | 'warn' | 'down' | undefined {
  if (ltv === undefined || !v) return undefined
  if (ltv > Number(m.policy.ltWad) / 1e18) return 'down'
  if (ltv > Number(v.planTargetWad) / 1e18 + 0.0001) return 'warn'
  return 'up'
}

function arrow(before: string, after: string | undefined) {
  return after === undefined || after === before ? before : `${before} → ${after}`
}

function blockedReason(m: MarketData): string {
  const st = stateName(m.policy.state)
  if (m.impaired) return 'Borrowing is blocked while the lender book is impaired.'
  if (st === 'OPEN' && !m.policy.canBorrow) return 'Borrowing is not available right now.'
  return `${STATE_COPY[st].label}: ${STATE_COPY[st].meaning}`
}

// ------------------------------------------------------------------ Borrow

function BorrowForm({ account, canSign, signHint, v, m, k }: Ctx) {
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const s = m.policy
  const debt = v?.debt ?? 0n
  const capacity = v?.borrowCapacity ?? 0n
  const value = v?.collateralValue ?? 0n
  const newDebt = a.amount !== undefined ? debt + a.amount : undefined
  const after = newDebt !== undefined ? ltvAfter(newDebt, value) : undefined
  const slotsFull = debt === 0n && m.activeAccounts >= m.maxAccounts
  const apr = k ? (Number(k.ratePerSecond) * 31_536_000) / 1e18 : undefined

  let error: string | undefined
  if (a.amount !== undefined && a.amount > capacity) error = `At most ${usdg(capacity)} USDG now.`
  else if (a.amount !== undefined && debt === 0n && a.amount < m.minLoan) error = `The minimum loan is ${usdg(m.minLoan)} USDG.`

  // Why the Lens reports no capacity, checked in the order StockReefLens._borrowCapacity applies its rules.
  let none: string | undefined
  if (s.canBorrow && capacity === 0n) {
    const limit = (s.borrowLimitWad * value) / WAD
    const room = k ? (k.utilizationCap * (m.cash + m.totalDebt)) / WAD : undefined
    if (v?.bufferActive && s.time >= s.prepAt) none = 'Your active buffer plan blocks new borrowing from preparation start until the reopening. Cancel the plan during the open phase to borrow again.'
    else if (slotsFull) none = `All ${m.maxAccounts.toString()} borrower slots hold debt. A slot frees when a loan is repaid in full.`
    else if (m.impaired) none = 'Borrowing is blocked while the lender book is impaired.'
    else if (value === 0n) none = 'Add collateral to borrow against it.'
    else if (limit <= debt + 1n) none = `The loan is at the ${pct(s.borrowLimitWad, 1)} borrow limit.`
    else if (m.cash === 0n || (room !== undefined && room <= m.totalDebt)) none = 'The pool has no cash to lend below its utilization cap.'
    else none = `The amount available is below the ${usdg(m.minLoan)} USDG minimum loan.`
  }

  const label = !canSign
    ? signHint
    : !s.canBorrow
      ? 'Borrowing closed'
      : none
        ? 'Nothing to borrow now'
        : !a.amount
          ? 'Enter amount'
          : error
            ? 'Check amount'
            : `Borrow ${usdg(a.amount)} USDG`

  return (
    <>
      <Head title="Borrow" aside={<span className="text-sm text-dk-muted">USDG</span>} />
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" disabled={!s.canBorrow} />
      <p className="mt-2 text-[15px] text-dk-muted">
        Available: <span className="num">{usdg(capacity)} USDG</span>
      </p>
      <Chips max={capacity} onPick={(x, mx) => a.fill(x, mx)} disabled={!s.canBorrow} />
      <div className="mt-4">
        <Line label="Debt">{arrow(`${usdg(debt)} USDG`, newDebt !== undefined ? `${usdg(newDebt)} USDG` : undefined)}</Line>
        <Line label="LTV" tone={ltvTone(after ?? (debt > 0n ? Number(v!.ltvWad) / 1e18 : undefined), m, v)}>
          {arrow(debt > 0n ? pct(v!.ltvWad, 1) : '—', after !== undefined ? pctOf(after) : undefined)}
        </Line>
        <Line label="Borrow limit" tone="warn">
          {s.canBorrow ? pct(s.borrowLimitWad, 1) : 'closed'}
        </Line>
        <Line label="Rate (fixed)">{apr !== undefined ? `${(apr * 100).toFixed(2)}% a year` : '—'}</Line>
        <Line label="Pool utilization">
          {pct(m.utilizationWad, 1)} <span className="text-dk-faint">of {k ? pct(k.utilizationCap, 0) : '90%'} cap</span>
        </Line>
      </div>
      <Submit
        label={label}
        disabled={!canSign || !s.canBorrow || !!none || !a.amount || !!error || !contracts}
        onClick={() => contracts && account && a.amount && tx.send({ address: contracts.market, abi: marketAbi, functionName: 'borrow', args: [a.amount, account] })}
      />
      {error && !none && <Note tone="down">{error}</Note>}
      {!s.canBorrow && <Note tone="warn">{blockedReason(m)}</Note>}
      {none && <Note tone="warn">{none}</Note>}
      <Note>New borrowing stops 30 minutes before the close and stays closed until a fresh price and the recovery window after the reopening.</Note>
      <TxStatusLine status={tx.status} />
    </>
  )
}

// ------------------------------------------------------------------ Repay

function RepayForm({ account, canSign, signHint, v, m, k, usdgWallet }: Ctx) {
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const [asset, setAsset] = useState<'wallet' | 'buffer'>('wallet')
  const debt = v?.debt ?? 0n
  const balance = asset === 'wallet' ? (usdgWallet ?? 0n) : (v?.plan.balance ?? 0n)
  const max = balance < debt ? balance : debt
  const value = v?.collateralValue ?? 0n
  const paid = a.amount !== undefined ? (a.amount > debt ? debt : a.amount) : undefined
  const newDebt = paid !== undefined ? debt - paid : undefined
  const after = newDebt !== undefined ? ltvAfter(newDebt, value) : undefined
  const limit = closingLimit(m, k)

  let error: string | undefined
  if (a.amount !== undefined && a.amount > balance) error = `Your ${asset === 'wallet' ? 'wallet' : 'buffer'} holds ${usdg(balance)} USDG.`
  else if (asset === 'wallet' && newDebt !== undefined && newDebt > 0n && newDebt < m.minLoan) error = `Repay everything or leave at least ${usdg(m.minLoan)} USDG.`

  const label = !canSign ? signHint : debt === 0n ? 'No debt to repay' : !a.amount ? 'Enter amount' : error ? 'Check amount' : `Repay ${usdg(paid)} USDG`

  function submit() {
    if (!contracts || !account || !a.amount) return
    const c = contracts
    if (asset === 'buffer') {
      tx.send({ address: c.escrow, abi: escrowAbi, functionName: 'ownerRepay', args: [a.isMax ? maxUint256 : a.amount] })
    } else {
      // MAX with enough in the wallet sends the whole balance: the market takes only the debt accrued at execution.
      const amount = a.isMax && balance > debt ? balance : a.amount
      tx.send({ address: c.market, abi: marketAbi, functionName: 'repay', args: [amount, account] }, { token: c.loanToken, spender: c.market, amount })
    }
  }

  return (
    <>
      <Head
        title="Repay"
        aside={
          <Select
            label="Asset"
            value={asset}
            onChange={x => {
              setAsset(x)
              a.clear()
            }}
            options={[
              { key: 'wallet', label: 'USDG' },
              { key: 'buffer', label: 'Buffer' },
            ]}
          />
        }
      />
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" />
      <p className="mt-2 text-[15px] text-dk-muted">
        {asset === 'wallet' ? 'Balance' : 'Buffer balance'}: <span className="num">{usdg(balance)} USDG</span>
      </p>
      <Chips max={max} onPick={(x, mx) => a.fill(x, mx)} />
      {v && abovePlan(v.repayToTarget) && (
        <button type="button" onClick={() => a.fill(v.repayToTarget)} className="mt-2 text-sm text-dk-up hover:underline">
          Repay {usdg(v.repayToTarget)} USDG to reach the {pct(v.planTargetWad, 0)} plan
        </button>
      )}
      <div className="mt-4">
        <Line label="Debt">{arrow(`${usdg(debt)} USDG`, newDebt !== undefined ? `${usdg(newDebt)} USDG` : undefined)}</Line>
        <Line label="Collateral">{tokens(v?.collateral, 2)} TSLA</Line>
        <Line label="LTV" tone={ltvTone(after ?? (debt > 0n ? Number(v!.ltvWad) / 1e18 : undefined), m, v)}>
          {arrow(debt > 0n ? pct(v!.ltvWad, 1) : '—', after !== undefined ? pctOf(after) : undefined)}
        </Line>
        <Line label="Closing limit" tone="warn">
          {limit !== undefined ? pct(limit, 1) : '—'}
        </Line>
      </div>
      <Submit label={label} disabled={!canSign || debt === 0n || !a.amount || !!error || !contracts} onClick={submit} />
      {error && <Note tone="down">{error}</Note>}
      {asset === 'buffer' && <Note>Repaying from your buffer works even while it is committed. If it would leave less than the minimum loan, it stops at the minimum.</Note>}
      <TxStatusLine status={tx.status} />
    </>
  )
}

// ------------------------------------------------------------------ Collateral

function CollateralForm({ account, canSign, signHint, v, m, tslaWallet }: Ctx) {
  const tx = useTx()
  const a = useAmount(18, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const [mode, setMode] = useState<'add' | 'withdraw'>('add')
  const s = m.policy
  const { data: out } = useMaxCollateralWithdraw(account, v, s, m.valuationPriceWad)
  const maxOut = out?.max
  const debt = v?.debt ?? 0n
  const coll = v?.collateral ?? 0n
  const max = mode === 'add' ? (tslaWallet ?? 0n) : (maxOut ?? 0n)
  const newColl = a.amount !== undefined ? (mode === 'add' ? coll + a.amount : coll - (a.amount > coll ? coll : a.amount)) : undefined
  // Scale the Lens valuation (which applies the token multiplier); price it directly only from zero collateral.
  const newValue = newColl === undefined ? undefined : coll > 0n ? ((v?.collateralValue ?? 0n) * newColl) / coll : (newColl * m.valuationPriceWad) / WAD / 10n ** 12n
  const after = newValue !== undefined ? ltvAfter(debt, newValue) : undefined

  let error: string | undefined
  if (a.amount !== undefined && a.amount > max) error = mode === 'add' ? `Your wallet holds ${tokens(max)} TSLA.` : `At most ${tokens(max)} TSLA can be withdrawn now.`

  const label = !canSign ? signHint : !a.amount ? 'Enter amount' : error ? 'Check amount' : `${mode === 'add' ? 'Add' : 'Withdraw'} ${tokens(a.amount)} TSLA`

  function submit() {
    if (!contracts || !account || !a.amount) return
    const c = contracts
    if (mode === 'add') {
      tx.send({ address: c.market, abi: marketAbi, functionName: 'depositCollateral', args: [a.amount, account] }, { token: c.collateralToken, spender: c.market, amount: a.amount })
    } else {
      tx.send({ address: c.market, abi: marketAbi, functionName: 'withdrawCollateral', args: [a.amount, account] })
    }
  }

  return (
    <>
      <Head
        title="Collateral"
        aside={
          <Segmented
            options={[
              { key: 'add', label: 'Add' },
              { key: 'withdraw', label: 'Withdraw' },
            ]}
            value={mode}
            onChange={x => {
              setMode(x)
              a.clear()
            }}
          />
        }
      />
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="TSLA" />
      <p className="mt-2 text-[15px] text-dk-muted">
        {mode === 'add' ? 'Wallet' : 'Withdrawable now'}: <span className="num">{tokens(max)} TSLA</span>
      </p>
      <Chips max={max} onPick={(x, mx) => a.fill(x, mx)} />
      {mode === 'add' && v && abovePlan(v.repayToTarget) && v.addCollateralRawToTarget > 0n && (
        <button type="button" onClick={() => a.fill(v.addCollateralRawToTarget)} className="mt-2 text-sm text-dk-up hover:underline">
          Add {tokens(v.addCollateralRawToTarget)} TSLA to reach the {pct(v.planTargetWad, 0)} plan
        </button>
      )}
      <div className="mt-4">
        <Line label="Collateral">{arrow(`${tokens(coll, 4)} TSLA`, newColl !== undefined ? `${tokens(newColl, 4)} TSLA` : undefined)}</Line>
        <Line label="Value">{usdg(v?.collateralValue)} USDG</Line>
        <Line label="LTV" tone={ltvTone(debt > 0n ? (after ?? Number(v!.ltvWad) / 1e18) : undefined, m, v)}>
          {arrow(debt > 0n ? pct(v!.ltvWad, 1) : '—', debt > 0n && after !== undefined ? pctOf(after) : undefined)}
        </Line>
        <Line label={mode === 'add' ? 'Threshold now' : 'Borrow limit'} tone="warn">
          {mode === 'add' ? pct(s.ltWad, 1) : s.canBorrow ? pct(s.borrowLimitWad, 1) : 'closed'}
        </Line>
      </div>
      <Submit label={label} disabled={!canSign || !a.amount || !!error || !contracts} onClick={submit} />
      {error && <Note tone="down">{error}</Note>}
      <Note>
        {mode === 'add'
          ? 'Adding collateral works in every market state. It keeps your stock, unlike a trim.'
          : debt === 0n
            ? 'Without debt, a withdrawal needs no price and works in every state.'
            : out?.blocked === 'buffer'
              ? 'Your active buffer plan blocks withdrawals against debt from preparation start until the reopening.'
              : out?.blocked === 'closed'
                ? 'With debt, withdrawals need borrowing to be open.'
                : 'With debt, a withdrawal must keep the loan within the borrow limit.'}
      </Note>
      <TxStatusLine status={tx.status} />
    </>
  )
}

// ------------------------------------------------------------------ Buffer

function BufferForm({ account, canSign, signHint, v, m, k, now, usdgWallet }: Ctx) {
  const [mode, setMode] = useState<'fund' | 'plan' | 'withdraw'>('fund')
  const p = v?.plan
  const status = !v ? '—' : v.bufferCommitted ? 'Committed' : v.bufferActive ? 'Authorized' : p && p.targetWad > 0n ? 'Expired' : 'Not set'
  const spentNow = p && Number(p.spentSession) === Number(m.policy.session) + 1 ? p.spent : 0n
  return (
    <>
      <Head
        title="Buffer"
        aside={
          <span className={`text-sm ${v?.bufferCommitted ? 'text-dk-warn' : v?.bufferActive ? 'text-dk-up' : 'text-dk-muted'}`}>{status}</span>
        }
      />
      <div>
        <Line label="Escrowed">{usdg(p?.balance)} USDG</Line>
        <Line label="Target">{p && p.targetWad > 0n ? pct(p.targetWad, 1) : '—'}</Line>
        <Line label="Cap per session">{p && p.targetWad > 0n ? `${usdg(p.perSessionCap)} USDG` : '—'}</Line>
        <Line label="Spent this session">{usdg(spentNow)} USDG</Line>
        <Line label="Expires">{p && p.expiry > 0n ? `${nyTime(p.expiry)} ET` : '—'}</Line>
        <Line label="Would repay next window" tone="up">
          {usdg(v?.bufferCoverage)} USDG
        </Line>
        <Line label="Executable now">{usdg(v?.bufferExecutableNow)} USDG</Line>
      </div>
      <div className="mt-4 mb-3">
        <Segmented
          options={[
            { key: 'fund', label: 'Fund' },
            { key: 'plan', label: 'Authorize' },
            { key: 'withdraw', label: 'Withdraw' },
          ]}
          value={mode}
          onChange={setMode}
        />
      </div>
      {mode === 'fund' && <FundBuffer account={account} canSign={canSign} signHint={signHint} wallet={usdgWallet} />}
      {mode === 'plan' && <AuthorizeBuffer canSign={canSign} signHint={signHint} v={v} k={k} now={now} />}
      {mode === 'withdraw' && <WithdrawBuffer account={account} canSign={canSign} signHint={signHint} v={v} />}
      <Note>
        Escrow is your money, kept apart from lender liquidity. It earns no yield. During preparation anyone can run your plan, within its target and per-session cap. It repays debt
        without selling collateral or paying a bonus, and it runs before any trim.
      </Note>
      {v?.bufferCommitted && (
        <Note tone="warn">Committed: outside the normal open phase, funds stay locked while you have debt and an active plan. You can still repay with them (Repay → Buffer).</Note>
      )}
    </>
  )
}

function FundBuffer({ account, canSign, signHint, wallet }: { account: Address | undefined; canSign: boolean; signHint: string; wallet: bigint | undefined }) {
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const bal = wallet ?? 0n
  const error = a.amount !== undefined && a.amount > bal ? `Your wallet holds ${usdg(bal)} USDG.` : undefined
  return (
    <>
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" />
      <p className="mt-2 text-[15px] text-dk-muted">
        Balance: <span className="num">{usdg(bal)} USDG</span>
      </p>
      <Chips max={bal} onPick={(x, mx) => a.fill(x, mx)} />
      <Submit
        label={!canSign ? signHint : !a.amount ? 'Enter amount' : error ? 'Check amount' : `Fund buffer with ${usdg(a.amount)} USDG`}
        disabled={!canSign || !a.amount || !!error || !contracts}
        onClick={() =>
          contracts &&
          account &&
          a.amount &&
          tx.send({ address: contracts.escrow, abi: escrowAbi, functionName: 'deposit', args: [a.amount, account] }, { token: contracts.loanToken, spender: contracts.escrow, amount: a.amount })
        }
      />
      {error && <Note tone="down">{error}</Note>}
      <TxStatusLine status={tx.status} />
    </>
  )
}

function AuthorizeBuffer({ canSign, signHint, v, k, now }: { canSign: boolean; signHint: string; v: AccountData | undefined; k: ProtocolConstants | undefined; now: number }) {
  const tx = useTx()
  const cancel = useTx()
  const p = v?.plan
  const maxTarget = k?.maxBufferTarget
  const [target, setTarget] = useState('')
  const [cap, setCap] = useState('')
  const [days, setDays] = useState('30')
  // Start from the stored plan, or from the cap and the escrowed balance.
  useEffect(() => {
    if (target || !maxTarget) return
    setTarget(String(Number((p && p.targetWad > 0n ? p.targetWad : maxTarget) * 1000n / WAD) / 10))
  }, [maxTarget, p, target])
  useEffect(() => {
    if (cap || !p) return
    setCap(trim(formatUnits(p.perSessionCap > 0n ? p.perSessionCap : p.balance, 6), 2))
  }, [p, cap])

  let targetWad: bigint | undefined
  let capRaw: bigint | undefined
  try {
    targetWad = target ? (parseUnits(target, 18) / 100n) : undefined
    capRaw = cap ? parseUnits(cap, 6) : undefined
  } catch {
    targetWad = undefined
  }
  const d = Number(days)
  const expiry = Number.isFinite(d) && d > 0 ? BigInt(now + Math.round(d * 86400)) : undefined
  let error: string | undefined
  if (targetWad !== undefined && maxTarget !== undefined && targetWad > maxTarget) error = `The target can be at most ${pct(maxTarget, 0)}.`
  else if (targetWad === 0n) error = 'Set a target above zero.'
  else if (capRaw === 0n) error = 'Set a cap above zero.'
  else if (!expiry) error = 'Set how many days the plan lasts.'
  const committed = !!v?.bufferCommitted

  return (
    <>
      <div className="grid grid-cols-3 gap-2">
        <Field label="Target LTV" unit="%" value={target} onChange={setTarget} />
        <Field label="Cap per session" unit="USDG" value={cap} onChange={setCap} />
        <Field label="Lasts" unit="days" value={days} onChange={setDays} />
      </div>
      {expiry && <p className="mt-2 text-sm text-dk-muted">The plan ends {nyTime(expiry)} ET.</p>}
      <Submit
        label={!canSign ? signHint : committed ? 'Committed until the reopening' : error ? 'Check plan' : `Authorize ${target}% plan`}
        disabled={!canSign || committed || !!error || targetWad === undefined || capRaw === undefined || !expiry || !contracts}
        onClick={() => contracts && targetWad && capRaw && expiry && tx.send({ address: contracts.escrow, abi: escrowAbi, functionName: 'authorize', args: [targetWad, capRaw, expiry] })}
      />
      {error && <Note tone="down">{error}</Note>}
      <TxStatusLine status={tx.status} />
      <button
        type="button"
        disabled={!canSign || committed || !v?.bufferActive || !contracts}
        onClick={() => contracts && cancel.send({ address: contracts.escrow, abi: escrowAbi, functionName: 'cancel', args: [] })}
        className="mt-3 text-sm text-dk-down hover:underline disabled:text-dk-faint disabled:no-underline"
      >
        Cancel plan
      </button>
      <TxStatusLine status={cancel.status} />
    </>
  )
}

function WithdrawBuffer({ account, canSign, signHint, v }: { account: Address | undefined; canSign: boolean; signHint: string; v: AccountData | undefined }) {
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const bal = v?.plan.balance ?? 0n
  const committed = !!v?.bufferCommitted
  const error = a.amount !== undefined && a.amount > bal ? `The buffer holds ${usdg(bal)} USDG.` : undefined
  return (
    <>
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" disabled={committed} />
      <p className="mt-2 text-[15px] text-dk-muted">
        Escrowed: <span className="num">{usdg(bal)} USDG</span>
      </p>
      <Chips max={bal} onPick={(x, mx) => a.fill(x, mx)} disabled={committed} />
      <Submit
        label={!canSign ? signHint : committed ? 'Committed until the reopening' : !a.amount ? 'Enter amount' : error ? 'Check amount' : `Withdraw ${usdg(a.amount)} USDG`}
        disabled={!canSign || committed || !a.amount || !!error || !contracts}
        onClick={() => contracts && account && a.amount && tx.send({ address: contracts.escrow, abi: escrowAbi, functionName: 'withdraw', args: [a.amount, account] })}
      />
      {error && <Note tone="down">{error}</Note>}
      <TxStatusLine status={tx.status} />
    </>
  )
}

function Field({ label, unit, value, onChange }: { label: string; unit: string; value: string; onChange: (s: string) => void }) {
  return (
    <label className="block">
      <span className="text-sm text-dk-muted">{label}</span>
      <div className="mt-1 flex items-center rounded-md border border-dk-line bg-dk-bg px-2.5 focus-within:border-dk-muted">
        <input inputMode="decimal" value={value} onChange={e => onChange(e.target.value.replace(',', '.'))} className="num w-full bg-transparent py-2 text-[15px] outline-none" />
        <span className="text-xs text-dk-muted">{unit}</span>
      </div>
    </label>
  )
}
