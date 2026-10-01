'use client'

import { formatUnits } from 'viem'
import { useAccount, useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { AmountAction } from '@/components/AmountAction'
import { Badge, Card, Notice, Stat } from '@/components/ui'
import { chain, contracts, ZERO } from '@/lib/chain'
import { localTime, nyTime, pct, usdg } from '@/lib/format'
import { useMarketView, useTokenBalance, useTx } from '@/lib/hooks'

export default function LendPage() {
  const { data: m } = useMarketView()
  const { address } = useAccount()
  const deposit = useTx()
  const withdraw = useTx()
  const { data: shares } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'balanceOf',
    args: [address ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!contracts && !!address, refetchInterval: 2_000 },
  })
  const { data: assets } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'convertToAssets',
    args: [shares ?? 0n],
    chainId: chain.id,
    query: { enabled: !!contracts && shares !== undefined, refetchInterval: 2_000 },
  })
  const { data: maxWithdraw } = useReadContract({
    address: contracts?.market,
    abi: marketAbi,
    functionName: 'maxWithdraw',
    args: [address ?? ZERO],
    chainId: chain.id,
    query: { enabled: !!contracts && !!address, refetchInterval: 2_000 },
  })
  const { data: wallet } = useTokenBalance(contracts?.loanToken, address)
  if (!m || !contracts) return <p className="text-sm text-muted">Reading the market…</p>
  const c = contracts

  const open = m.policy.lenderOpen
  const windDown = m.policy.windDown
  const allowance = m.totalDebt > m.recoverable ? m.totalDebt - m.recoverable : 0n
  const sharePrice = m.totalShares > 0n ? Number(formatUnits(m.totalAssets, 6)) / Number(formatUnits(m.totalShares, 12)) : 1

  return (
    <div className="space-y-5">
      <Notice tone={open ? 'ok' : windDown ? 'prep' : 'closed'}>
        {open ? (
          <>
            <b>Lender window open</b> until <b className="num">{nyTime(m.lenderWindowClosesAt)}</b> New York ({localTime(m.lenderWindowClosesAt)} your time). Deposits and withdrawals use the current
            valuation.
          </>
        ) : windDown ? (
          <>
            <b>Wind-down.</b> The loaded calendar has ended: withdraw against idle cash at the last accepted valuation. Repayments keep adding to that cash.
          </>
        ) : (
          <>
            <b>Lender window closed.</b> Deposits and withdrawals happen only in the open session before preparation starts.
            {m.lenderWindowOpensAt > 0n && (
              <>
                {' '}Next window: <b className="num">{nyTime(m.lenderWindowOpensAt)}</b> to <b className="num">{nyTime(m.lenderWindowClosesAt)}</b> New York (earliest).
              </>
            )}
          </>
        )}
      </Notice>

      <div className="grid gap-5 md:grid-cols-3">
        <Card title="Book" className="md:col-span-2" aside={m.valuationIndicative ? <Badge tone="prep">Indicative valuation</Badge> : undefined}>
          <div className="grid grid-cols-2 gap-4 md:grid-cols-3">
            <Stat label="Lender assets" value={`${usdg(m.totalAssets)} USDG`} big />
            <Stat label="Idle cash" value={`${usdg(m.cash)} USDG`} sub="what withdrawals can draw on" />
            <Stat label="Loans outstanding" value={`${usdg(m.totalDebt)} USDG`} sub={`utilization ${pct(m.utilizationWad)} (cap 90%)`} />
            <Stat label="Known valuation allowance" value={`${usdg(allowance)} USDG`} sub="debt above min(debt, collateral ÷ 1.05)" />
            <Stat label="Written off" value={`${usdg(m.totalBadDebt)} USDG`} />
            <Stat label="Value per 1 USDG deposited" value={sharePrice.toFixed(6)} sub={`${m.activeAccounts.toString()} of ${m.maxAccounts.toString()} borrower slots used`} />
          </div>
          <p className="mt-4 text-xs text-faint">
            Loans are valued at what the collateral can recover, never above the debt, so a known shortfall is not paid out at face value to whoever exits first. {m.impaired && 'The book is impaired: new borrowing is blocked until it is resolved.'}
          </p>
        </Card>

        <Card title="Your position">
          <div className="space-y-3">
            <Stat label="Value" value={`${usdg(assets)} USDG`} big />
            <Stat label="Withdrawable now" value={`${usdg(maxWithdraw)} USDG`} />
          </div>
        </Card>
      </div>

      {address && (
        <Card title="Deposit or withdraw">
          <div className="grid gap-5 md:grid-cols-2">
            <AmountAction
              label="Deposit USDG"
              unit="USDG"
              decimals={6}
              action="Deposit"
              disabled={!open}
              hint={`Wallet: ${usdg(wallet)} USDG`}
              status={deposit.status}
              onSubmit={amount => deposit.send({ address: c.market, abi: marketAbi, functionName: 'deposit', args: [amount, address] }, { token: c.loanToken, spender: c.market, amount })}
            />
            <AmountAction
              label="Withdraw USDG"
              unit="USDG"
              decimals={6}
              action="Withdraw"
              disabled={!open && !windDown}
              max={maxWithdraw !== undefined ? formatUnits(maxWithdraw, 6) : undefined}
              status={withdraw.status}
              onSubmit={amount => withdraw.send({ address: c.market, abi: marketAbi, functionName: 'withdraw', args: [amount, address, address] })}
            />
          </div>
          <p className="mt-3 text-xs text-faint">Testnet market lending real Paxos USDG at demo scale. This is a scheduled-liquidity product, not instant-access yield.</p>
        </Card>
      )}
    </div>
  )
}
