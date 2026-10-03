'use client'

import { Suspense, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { isAddress, type Address } from 'viem'
import { useAccount } from 'wagmi'
import { escrowAbi, marketAbi } from '@/generated/abi'
import { AmountAction } from '@/components/AmountAction'
import { Badge, Button, Card, Notice, Stat } from '@/components/ui'
import { contracts, demoAccounts, explorerTx } from '@/lib/chain'
import { nyTime, pct, short, tokens, usdg } from '@/lib/format'
import { useAccountView, useMarketView, useReceipts, useTokenBalance, useTx } from '@/lib/hooks'
import { stateName } from '@/lib/policy'

export default function Page() {
  return (
    <Suspense>
      <MyLoan />
    </Suspense>
  )
}

function MyLoan() {
  const { address } = useAccount()
  const params = useSearchParams()
  const fromQuery = params.get('account')
  const [picked, setPicked] = useState<Address>()
  const viewing: Address | undefined = picked ?? (fromQuery && isAddress(fromQuery) ? fromQuery : address)
  const own = !!address && viewing?.toLowerCase() === address.toLowerCase()

  return (
    <div className="space-y-5">
      <AccountPicker viewing={viewing} own={own} onPick={setPicked} you={address} />
      {viewing ? <LoanView account={viewing} own={own} /> : <Notice tone="closed">Connect a wallet, or pick a demo account, to see a loan.</Notice>}
    </div>
  )
}

function AccountPicker({ viewing, own, onPick, you }: { viewing?: Address; own: boolean; onPick: (a?: Address) => void; you?: Address }) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-sm">
      <span className="text-muted">Viewing</span>
      {you && (
        <button type="button" onClick={() => onPick(you)} className={`rounded-lg px-2.5 py-1 ${own ? 'bg-ink text-white' : 'border border-line'}`}>
          Your loan
        </button>
      )}
      {demoAccounts.map(d => (
        <button
          key={d.address}
          type="button"
          onClick={() => onPick(d.address)}
          className={`rounded-lg px-2.5 py-1 ${viewing?.toLowerCase() === d.address.toLowerCase() ? 'bg-ink text-white' : 'border border-line'}`}
        >
          {d.label}
        </button>
      ))}
      {viewing && !own && <span className="num text-xs text-faint">{short(viewing)} · read only</span>}
    </div>
  )
}

function LoanView({ account, own }: { account: Address; own: boolean }) {
  const { data: v } = useAccountView(account)
  const { data: m } = useMarketView()
  if (!v || !m) return <p className="text-sm text-muted">Reading the loan…</p>
  const s = m.policy
  const phase = stateName(s.phase)
  const hasDebt = v.debt > 0n

  return (
    <>
      {v.missedExecution && (
        <Notice tone="guarded">
          <b>Missed execution detected.</b> Nobody reduced this loan before the close: it entered the closure at {pct(v.ltvWad)}, above the {pct(s.ltWad)} closing threshold.
          Exposure still open: <b className="num">{usdg(v.exposure)} USDG</b> to reach the {pct(v.planTargetWad, 0)} plan. No protection badge applies.
        </Notice>
      )}

      <div className="grid gap-5 md:grid-cols-2">
        <Card title="Loan" aside={v.valuationIndicative ? <Badge tone="prep">Valuation indicative</Badge> : undefined}>
          <div className="grid grid-cols-2 gap-4">
            <Stat label="Debt, including interest" value={`${usdg(v.debt)} USDG`} big />
            <Stat label="Loan-to-value" value={hasDebt ? (v.valuationIndicative ? 'unknown now' : pct(v.ltvWad)) : '—'} big sub={v.valuationIndicative ? `${pct(v.ltvWad)} at the last accepted price` : undefined} />
            <Stat label="Collateral" value={`${tokens(v.collateral)} TSLA`} sub={`${usdg(v.collateralValue)} USDG`} />
            <Stat label="You can borrow now" value={`${usdg(v.borrowCapacity)} USDG`} sub={s.canBorrow ? `limit ${pct(s.borrowLimitWad)}` : 'borrowing is closed'} />
          </div>
          {hasDebt && <LtvBar ltv={v.ltvWad} b={s.borrowLimitWad} lt={s.ltWad} target={v.planTargetWad} />}
        </Card>

        <Card title="Before the close">
          <ClosurePlan v={v} s={s} phase={phase} />
        </Card>
      </div>

      <div className="grid gap-5 md:grid-cols-2">
        <BufferCard account={account} own={own} v={v} />
        <Receipts account={account} />
      </div>

      {own && <Actions account={account} v={v} canBorrow={s.canBorrow} />}
    </>
  )
}

type View = NonNullable<ReturnType<typeof useAccountView>['data']>
type Market = NonNullable<ReturnType<typeof useMarketView>['data']>

function ClosurePlan({ v, s, phase }: { v: View; s: Market['policy']; phase: string }) {
  if (v.debt === 0n) return <p className="text-sm text-muted">No debt: nothing to prepare.</p>
  const beforeClose = phase === 'OPEN' || phase === 'PRE_CLOSE' || phase === 'FINAL_WINDOW'
  const target = pct(v.planTargetWad, 0)
  return (
    <div className="space-y-4 text-sm">
      {v.repayToTarget > 0n ? (
        <div>
          <div className="text-xs text-muted">What to do</div>
          <p className="mt-1 text-base">
            Repay <b className="num">{usdg(v.repayToTarget)} USDG</b> or add <b className="num">{tokens(v.addCollateralRawToTarget)} TSLA</b> to reach the {target} plan
            {beforeClose && (
              <>
                {' '}by <b className="num">{nyTime(s.finalAt)}</b> New York
              </>
            )}
            .
          </p>
          <p className="mt-1 text-xs text-faint">
            Either keeps your collateral. A funded buffer can do the repayment for you during preparation or reopening recovery.
          </p>
        </div>
      ) : (
        <p>
          Your loan is at or under the <b>{target}</b> plan for this close. No action needed.
        </p>
      )}
      <div>
        <div className="text-xs text-muted">If you do nothing</div>
        {v.trimNow.eligible ? (
          <p className="mt-1">
            Eligible for a trim <b>now</b>: a liquidator may repay <b className="num">{usdg(v.trimNow.repaid)} USDG</b> and take{' '}
            <b className="num">{tokens(v.trimNow.collateralOut)} TSLA</b> ({pct(v.trimNow.bonusWad, 0)} bonus), leaving you at the target.
            {v.trimNow.bufferPending && ' Your funded buffer runs first.'}
          </p>
        ) : v.trimmableAtFinal ? (
          <p className="mt-1">
            From the final window a liquidator may repay <b className="num">{usdg(v.trimAtFinalRepay)} USDG</b> and take{' '}
            <b className="num">{tokens(v.trimAtFinalCollateral)} TSLA</b> ({pct(v.trimAtFinalBonusWad, 0)} bonus) at today’s price. Nobody is guaranteed to act; if nobody does, the loan enters the closure as it is.
          </p>
        ) : (
          <p className="mt-1">Your loan stays under the closing threshold at today’s price: it enters the closure as it is, with no trim.</p>
        )}
        {beforeClose && v.projectedDebtAtReopen > 0n && (
          <p className="mt-1 text-xs text-muted">
            At the reopening, interest brings the debt to <b className="num">{usdg(v.projectedDebtAtReopen)} USDG</b>
            {v.trimmableAtReopen ? ': above the closing threshold at today’s price, so a recovery trim could follow.' : ': still under the closing threshold at today’s price.'}
          </p>
        )}
      </div>
    </div>
  )
}

function LtvBar({ ltv, b, lt, target }: { ltv: bigint; b: bigint; lt: bigint; target: bigint }) {
  const scale = (x: bigint) => `${Math.min(100, (Number(x) / 1e18) * 100)}%`
  return (
    <div className="mt-5">
      <div className="relative h-2.5 rounded-full bg-canvas">
        <div className="absolute inset-y-0 left-0 rounded-full bg-ink/70" style={{ width: scale(ltv) }} />
        {[
          { at: target, label: 'plan', cls: 'bg-reef' },
          ...(b > 0n ? [{ at: b, label: 'B', cls: 'bg-prep' }] : []),
          { at: lt, label: 'LT', cls: 'bg-guarded' },
        ].map(mark => (
          <div key={mark.label} className={`absolute -top-1 h-4.5 w-0.5 ${mark.cls}`} style={{ left: scale(mark.at) }} title={`${mark.label} ${pct(mark.at)}`} />
        ))}
      </div>
      <div className="mt-1.5 flex gap-4 text-[11px] text-muted">
        <span><i className="mr-1 inline-block h-2 w-2 rounded-full bg-reef" />plan {pct(target, 0)}</span>
        {b > 0n && <span><i className="mr-1 inline-block h-2 w-2 rounded-full bg-prep" />borrow limit {pct(b)}</span>}
        <span><i className="mr-1 inline-block h-2 w-2 rounded-full bg-guarded" />liquidation threshold {pct(lt)}</span>
      </div>
    </div>
  )
}

function BufferCard({ account, own, v }: { account: Address; own: boolean; v: View }) {
  const tx = useTx()
  const { data: m } = useMarketView()
  const p = v.plan
  const expiry = (m?.policy.time ?? 0n) + 30n * 86400n // 30 days of protocol time
  return (
    <Card title="Repayment buffer" aside={v.bufferCommitted ? <Badge tone="prep">Committed</Badge> : v.bufferActive ? <Badge tone="ok">Authorized</Badge> : <Badge tone="closed">Not set</Badge>}>
      <div className="grid grid-cols-3 gap-4">
        <Stat label="Escrowed" value={`${usdg(p.balance)}`} sub="USDG, yours" />
        <Stat label="Would repay" value={`${usdg(v.bufferCoverage)}`} sub="USDG at the next window" />
        <Stat label="Target" value={p.targetWad > 0n ? pct(p.targetWad, 0) : '—'} sub={p.expiry > 0n ? `until ${nyTime(p.expiry)}` : undefined} />
      </div>
      <p className="mt-3 text-xs text-faint">
        The buffer repays debt, never sells collateral and pays nobody a bonus. From preparation start until a full reopening the funds stay committed while you have debt; you can always repay with them yourself.
      </p>
      {own && contracts && (
        <div className="mt-4 grid gap-3">
          <AmountAction
            label="Add to buffer"
            unit="USDG"
            decimals={6}
            action="Deposit"
            status={tx.status}
            onSubmit={amount => tx.send({ address: contracts!.escrow, abi: escrowAbi, functionName: 'deposit', args: [amount, account] }, { token: contracts!.loanToken, spender: contracts!.escrow, amount })}
          />
          <div className="flex flex-wrap gap-2">
            <Button
              variant="secondary"
              disabled={v.bufferCommitted}
              onClick={() =>
                tx.send({
                  address: contracts!.escrow,
                  abi: escrowAbi,
                  functionName: 'authorize',
                  args: [650000000000000000n, p.balance > 0n ? p.balance : 10_000_000n, expiry],
                })
              }
              title="Authorize repayment toward 65% during preparation and reopening recovery, for 30 days"
            >
              Authorize 65% plan
            </Button>
            <Button variant="secondary" disabled={v.bufferCommitted || !v.bufferActive} onClick={() => tx.send({ address: contracts!.escrow, abi: escrowAbi, functionName: 'cancel', args: [] })}>
              Cancel plan
            </Button>
            <Button variant="secondary" disabled={v.bufferCommitted || p.balance === 0n} onClick={() => tx.send({ address: contracts!.escrow, abi: escrowAbi, functionName: 'withdraw', args: [p.balance, account] })}>
              Withdraw all
            </Button>
          </div>
        </div>
      )}
    </Card>
  )
}

function Receipts({ account }: { account: Address }) {
  const receipts = useReceipts(account)
  return (
    <Card title="Did it execute?">
      {receipts.length === 0 ? (
        <p className="text-sm text-muted">No executions yet for this loan.</p>
      ) : (
        <ul className="divide-y divide-line">
          {receipts.map(r => (
            <li key={`${r.hash}-${r.kind}`} className="flex items-center justify-between py-2 text-sm">
              <span>
                <b>{r.kind}</b> {r.detail && <span className="text-xs text-muted">{r.detail}</span>}
              </span>
              <span className="flex items-center gap-3">
                <span className="num">{usdg(r.amount)} USDG</span>
                {explorerTx(r.hash) && (
                  <a href={explorerTx(r.hash)} target="_blank" rel="noreferrer" className="text-xs text-reef underline">
                    receipt
                  </a>
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}

function Actions({ account, v, canBorrow }: { account: Address; v: View; canBorrow: boolean }) {
  const collateral = useTx()
  const borrow = useTx()
  const repay = useTx()
  const withdraw = useTx()
  const { data: tslaBalance } = useTokenBalance(contracts?.collateralToken, account)
  const { data: usdgBalance } = useTokenBalance(contracts?.loanToken, account)
  if (!contracts) return null
  const c = contracts
  return (
    <Card title="Manage">
      <div className="grid gap-5 md:grid-cols-2">
        <AmountAction
          label="Add collateral (works in every state)"
          unit="TSLA"
          decimals={18}
          action="Add"
          hint={`Wallet: ${tokens(tslaBalance)} TSLA`}
          status={collateral.status}
          onSubmit={amount => collateral.send({ address: c.market, abi: marketAbi, functionName: 'depositCollateral', args: [amount, account] }, { token: c.collateralToken, spender: c.market, amount })}
        />
        <AmountAction
          label="Repay (works in every state)"
          unit="USDG"
          decimals={6}
          action="Repay"
          hint={`Wallet: ${usdg(usdgBalance)} USDG · repay all or leave at least 5 USDG`}
          status={repay.status}
          onSubmit={amount => repay.send({ address: c.market, abi: marketAbi, functionName: 'repay', args: [amount, account] }, { token: c.loanToken, spender: c.market, amount })}
        />
        <AmountAction
          label="Borrow"
          unit="USDG"
          decimals={6}
          action="Borrow"
          disabled={!canBorrow}
          hint={canBorrow ? `Up to ${usdg(v.borrowCapacity)} USDG now · minimum loan 5 USDG` : 'Borrowing is closed in this state'}
          status={borrow.status}
          onSubmit={amount => borrow.send({ address: c.market, abi: marketAbi, functionName: 'borrow', args: [amount, account] })}
        />
        <AmountAction
          label="Withdraw collateral"
          unit="TSLA"
          decimals={18}
          action="Withdraw"
          hint={v.debt > 0n ? 'With debt, this follows the borrow limit' : 'No debt: needs no price'}
          status={withdraw.status}
          onSubmit={amount => withdraw.send({ address: c.market, abi: marketAbi, functionName: 'withdrawCollateral', args: [amount, account] })}
        />
      </div>
    </Card>
  )
}
