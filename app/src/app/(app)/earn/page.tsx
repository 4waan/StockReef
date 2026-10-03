'use client'

import { useState } from 'react'
import { formatUnits, type Address } from 'viem'
import { useAccount, useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { AmountBox, Chips, Note, Submit, useAmount } from '@/components/terminal/Ticket'
import { Line, Metric, Panel, Segmented, TxStatusLine } from '@/components/terminal/kit'
import { chain, contracts, ZERO } from '@/lib/chain'
import { duration, nyTime, pct, usdg } from '@/lib/format'
import { useMarketView, useProtocolConstants, useProtocolNow, useTokenBalance, useTx } from '@/lib/hooks'

const SLIPPAGE_BPS = 50n // deposits revert if they would mint more than 0.5% fewer shares than previewed

export default function EarnPage() {
  const { address, chainId, isConnected } = useAccount()
  const { data: m } = useMarketView()
  const { data: k } = useProtocolConstants()
  const now = useProtocolNow(m?.policy.time)
  const { data: shares } = useLenderRead('balanceOf', address)
  const { data: maxWithdraw } = useLenderRead('maxWithdraw', address)
  const { data: maxRedeem } = useLenderRead('maxRedeem', address)
  const { data: assets } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'convertToAssets',
    args: [shares ?? 0n],
    chainId: chain.id,
    query: { enabled: !!contracts && shares !== undefined, refetchInterval: 2_000 },
  })
  const { data: wallet } = useTokenBalance(contracts?.loanToken, address)
  const [mode, setMode] = useState<'deposit' | 'withdraw'>('deposit')

  if (!contracts) return <p className="px-5 py-10 text-dk-muted">No StockReef deployment is configured for chain {chain.id} yet.</p>
  if (!m || now === undefined) return <p className="px-5 py-10 text-dk-muted">Reading the market…</p>

  const s = m.policy
  const open = s.lenderOpen
  const allowance = m.totalDebt > m.recoverable ? m.totalDebt - m.recoverable : 0n
  const sharePrice = m.totalShares > 0n ? Number(formatUnits(m.totalAssets, 6)) / Number(formatUnits(m.totalShares, 12)) : 1
  const apr = k ? (Number(k.ratePerSecond) * 31_536_000) / 1e18 : undefined
  const canSign = isConnected && chainId === chain.id
  const signHint = !isConnected ? 'Connect wallet' : `Switch to chain ${chain.id}`
  const utilCap = k ? Number(k.utilizationCap) / 1e18 : 0.9
  const util = Number(m.utilizationWad) / 1e18

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex h-10 items-center gap-4 overflow-x-auto border-b border-dk-line px-5 text-[15px] whitespace-nowrap">
        <span className="font-semibold">USDG lender vault</span>
        <span className="h-4 w-px bg-dk-line" />
        {open ? (
          <span className="text-dk-up">
            WINDOW OPEN <span className="num text-dk-muted">until {nyTime(m.lenderWindowClosesAt)} ET · {duration(Number(m.lenderWindowClosesAt) - now)} left</span>
          </span>
        ) : s.windDown ? (
          <span className="text-dk-warn">WIND-DOWN</span>
        ) : (
          <span className="text-dk-muted">
            WINDOW CLOSED
            {m.lenderWindowOpensAt > 0n && <span className="num"> · next {nyTime(m.lenderWindowOpensAt)} ET (earliest)</span>}
          </span>
        )}
        <span className="h-4 w-px bg-dk-line" />
        <span className="num text-dk-muted">
          Utilization {pct(m.utilizationWad, 1)} of {k ? pct(k.utilizationCap, 0) : '90%'} cap
        </span>
        {m.valuationIndicative && <span className="text-sm text-dk-warn">valuation indicative</span>}
      </div>

      {m.impaired && (
        <p className="border-b border-l-2 border-dk-line border-l-dk-down px-5 py-2 text-sm">
          The book is impaired: a loan’s debt is above what its collateral can recover. New borrowing and deposits are paused until it is resolved.
        </p>
      )}

      <div className="grid flex-1 lg:grid-cols-[minmax(0,1fr)_440px]">
        <div className="min-w-0">
          <Panel title="Book">
            <div className="grid grid-cols-2 gap-x-6 gap-y-5 md:grid-cols-3">
              <Metric big label="Lender assets" value={`${usdg(m.totalAssets, 0)} USDG`} sub="cash plus recoverable loans" />
              <Metric label="Idle cash" value={`${usdg(m.cash)} USDG`} sub="what withdrawals draw on" />
              <Metric label="Loans outstanding" value={`${usdg(m.totalDebt)} USDG`} sub={`${m.activeAccounts.toString()} of ${m.maxAccounts.toString()} borrower slots`} />
              <Metric label="Recoverable" value={`${usdg(m.recoverable)} USDG`} sub="Σ min(debt, collateral ÷ 1.05)" />
              <Metric label="Known shortfall" value={`${usdg(allowance)} USDG`} tone={allowance > 0n ? 'text-dk-warn' : ''} sub="debt the collateral cannot recover" />
              <Metric label="Written off" value={`${usdg(m.totalBadDebt)} USDG`} tone={m.totalBadDebt > 0n ? 'text-dk-down' : ''} />
              <Metric label="Value per 1 USDG deposited" value={sharePrice.toFixed(6)} />
              <Metric label="Borrow rate" value={apr !== undefined ? `${(apr * 100).toFixed(2)}%` : 'Unavailable'} sub="fixed rate paid by borrowers" />
            </div>
            <div className="mt-5">
              <div className="flex justify-between text-sm text-dk-muted">
                <span>Utilization</span>
                <span className="num">
                  {(util * 100).toFixed(1)}% · cap {(utilCap * 100).toFixed(0)}%
                </span>
              </div>
              <div className="relative mt-1.5 h-2 rounded-full bg-dk-raised">
                <div className="absolute inset-y-0 left-0 rounded-full bg-dk-up" style={{ width: `${Math.min(100, util * 100)}%` }} />
                <div className="absolute -top-1 h-4 w-0.5 bg-dk-warn" style={{ left: `${utilCap * 100}%` }} title="Utilization cap" />
              </div>
            </div>
          </Panel>

          <Panel title="How lender value changes">
            <ul className="space-y-2 text-[15px] text-dk-muted">
              <li>
                <b className="text-dk-ink">Your vault shares represent available USDG plus the amount the market expects to recover from outstanding loans.</b>
              </li>
              <li>
                Borrower repayments and liquidator repayments return USDG to the vault. If collateral covers less than the debt, the recoverable amount and share value adjust with the accepted valuation.
              </li>
              <li>Deposits and withdrawals open after reopening recovery and close when preparation starts. Withdrawals use available vault cash.</li>
              <li>The displayed 10% rate is paid by borrowers. Lender returns depend on loans outstanding, idle cash and any collateral shortfall.</li>
            </ul>
          </Panel>
        </div>

        <aside className="border-dk-line lg:border-l">
          <Panel title="Your position">
            <div className="grid grid-cols-2 gap-4">
              <Metric big label="Value" value={address ? `${usdg(assets as bigint | undefined)} USDG` : 'Unavailable'} />
              <Metric label="Withdrawable now" value={address ? `${usdg(maxWithdraw)} USDG` : 'Unavailable'} sub={shares !== undefined && shares > 0n ? `${formatUnits(shares, 12)} shares` : undefined} />
            </div>
          </Panel>
          <div className="px-6 pt-4 pb-6">
            <Segmented
              options={[
                { key: 'deposit', label: 'Deposit' },
                { key: 'withdraw', label: 'Withdraw' },
              ]}
              value={mode}
              onChange={setMode}
            />
            <div className="mt-4">
              {mode === 'deposit' ? (
                <Deposit canSign={canSign} signHint={signHint} open={open && !m.impaired} reason={m.impaired ? 'Deposits are paused while the book is impaired.' : 'The lender window is closed.'} wallet={wallet} />
              ) : (
                <Withdraw canSign={canSign} signHint={signHint} open={open || s.windDown} maxWithdraw={maxWithdraw} maxRedeem={maxRedeem} />
              )}
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}

/** A per-lender read of the market's ERC-4626 share accounting, refreshed every two seconds. */
function useLenderRead(functionName: 'balanceOf' | 'maxWithdraw' | 'maxRedeem', owner: Address | undefined) {
  return useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName,
    args: [owner ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!contracts && !!owner, refetchInterval: 2_000 },
  }) as { data: bigint | undefined }
}

function Deposit({ canSign, signHint, open, reason, wallet }: { canSign: boolean; signHint: string; open: boolean; reason: string; wallet: bigint | undefined }) {
  const { address } = useAccount()
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const bal = wallet ?? 0n
  const { data: preview } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'previewDeposit',
    args: [a.amount ?? 0n],
    chainId: chain.id,
    query: { enabled: !!contracts && !!a.amount },
  })
  const minShares = preview !== undefined ? (preview * (10_000n - SLIPPAGE_BPS)) / 10_000n : undefined
  const error = a.amount !== undefined && a.amount > bal ? `Your wallet holds ${usdg(bal)} USDG.` : undefined
  const c = contracts!
  return (
    <>
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" disabled={!open} />
      <p className="mt-2 text-[15px] text-dk-muted">
        Balance: <span className="num">{usdg(bal)} USDG</span>
      </p>
      <Chips max={bal} onPick={(x, mx) => a.fill(x, mx)} disabled={!open} />
      <div className="mt-4">
        <Line label="Shares (preview)">{preview !== undefined ? formatUnits(preview, 12) : 'Unavailable'}</Line>
        <Line label="Least accepted">{minShares !== undefined ? `${formatUnits(minShares, 12)} (0.5% slippage)` : 'Unavailable'}</Line>
      </div>
      <Submit
        label={!canSign ? signHint : !open ? 'Window closed' : !a.amount ? 'Enter amount' : error ? 'Check amount' : `Deposit ${usdg(a.amount)} USDG`}
        disabled={!canSign || !open || !a.amount || !!error || minShares === undefined}
        onClick={() =>
          address && a.amount && minShares !== undefined && tx.send({ address: c.market, abi: marketAbi, functionName: 'depositChecked', args: [a.amount, address, minShares] }, { token: c.loanToken, spender: c.market, amount: a.amount })
        }
      />
      {error && <Note tone="down">{error}</Note>}
      {!open && <Note tone="warn">{reason}</Note>}
      <TxStatusLine status={tx.status} />
    </>
  )
}

function Withdraw({ canSign, signHint, open, maxWithdraw, maxRedeem }: { canSign: boolean; signHint: string; open: boolean; maxWithdraw: bigint | undefined; maxRedeem: bigint | undefined }) {
  const { address } = useAccount()
  const tx = useTx()
  const a = useAmount(6, tx.status.state === 'mined' ? tx.status.hash : undefined)
  const max = maxWithdraw ?? 0n
  const error = a.amount !== undefined && a.amount > max ? `At most ${usdg(max)} USDG can be withdrawn now.` : undefined
  const c = contracts!
  return (
    <>
      <AmountBox value={a.text} onChange={t => a.set(t)} unit="USDG" disabled={!open} />
      <p className="mt-2 text-[15px] text-dk-muted">
        Withdrawable now: <span className="num">{usdg(max)} USDG</span>
      </p>
      <Chips max={max} onPick={(x, mx) => a.fill(x, mx)} disabled={!open} />
      <Submit
        label={!canSign ? signHint : !open ? 'Window closed' : !a.amount ? 'Enter amount' : error ? 'Check amount' : a.isMax ? 'Withdraw all I can' : `Withdraw ${usdg(a.amount)} USDG`}
        disabled={!canSign || !open || !a.amount || !!error}
        onClick={() => {
          if (!address || !a.amount) return
          // MAX redeems the redeemable shares, so no dust of shares is left behind by rounding.
          if (a.isMax && maxRedeem) tx.send({ address: c.market, abi: marketAbi, functionName: 'redeem', args: [maxRedeem, address, address] })
          else tx.send({ address: c.market, abi: marketAbi, functionName: 'withdraw', args: [a.amount, address, address] })
        }}
      />
      {error && <Note tone="down">{error}</Note>}
      {!open && <Note tone="warn">The lender window is closed. Withdrawals reopen with it.</Note>}
      <Note>Withdrawals draw on idle cash; loans still out are not paid early to lenders who leave.</Note>
      <TxStatusLine status={tx.status} />
    </>
  )
}
