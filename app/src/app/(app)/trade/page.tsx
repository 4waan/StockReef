'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import { Alerts } from '@/components/terminal/Alerts'
import { Automation } from '@/components/terminal/Automation'
import { BottomTabs } from '@/components/terminal/BottomTabs'
import { ExposureChart, type ChartMode, type ChartWindow } from '@/components/terminal/ExposureChart'
import { Kpis } from '@/components/terminal/Kpis'
import { PriceStrip } from '@/components/terminal/PriceStrip'
import { Ticker } from '@/components/terminal/Ticker'
import { Ticket, type TicketTab } from '@/components/terminal/Ticket'
import { chain, contracts } from '@/lib/chain'
import { useHistory } from '@/lib/history'
import { stateName } from '@/lib/policy'
import { useViewing } from '@/lib/viewing'
import { useAccountView, useActiveAccounts, useDemoOperator, useLtCurve, useMarketView, useProtocolConstants, useProtocolNow, useTokenBalance } from '@/lib/hooks'

export default function TradePage() {
  const { address, chainId, isConnected } = useAccount()
  const { viewing, own, label, pick } = useViewing()

  const { data: m } = useMarketView()
  const { data: v } = useAccountView(viewing)
  const { data: active } = useActiveAccounts()
  const { isOperator } = useDemoOperator()
  const { data: k } = useProtocolConstants()
  const now = useProtocolNow(m?.policy.time)
  const { data: history } = useHistory(viewing, v?.collateral)
  const { data: usdgWallet } = useTokenBalance(contracts?.loanToken, own ? address : undefined)
  const { data: tslaWallet } = useTokenBalance(contracts?.collateralToken, own ? address : undefined)

  const [tab, setTab] = useState<TicketTab>('repay')
  const [mode, setMode] = useState<ChartMode>('ltv')
  const [pickedWin, setWin] = useState<ChartWindow>()

  const s = m?.policy
  // Until the user picks, show the pre-close window once it is close, and the whole day before that.
  const win: ChartWindow = pickedWin ?? (s && now !== undefined && now < Number(s.prepAt) - 3600 ? 'session' : 'preclose')
  const x0 = s ? Number(win === 'preclose' ? s.prepAt : s.open) : 0
  const x1 = s ? Number(s.close) : 0
  const samples = s ? [...new Set([x0, Number(s.prepAt), Number(s.finalAt), x1])].filter(t => t >= x0 && t <= x1).sort((a, b) => a - b).map(BigInt) : []
  const { data: ramp } = useLtCurve(s?.close, s?.nextOpen, samples)
  // While the market reopens, the previous closure's threshold (the snapshot's LT) holds until credit returns.
  const phase = s ? stateName(s.phase) : undefined
  const reopening = phase === 'REOPEN_WAIT' || phase === 'REOPEN_RECOVERY'
  const reopenUntil = s && reopening ? Math.max(Number(s.creditAt), now ?? 0, Number(s.open) + 900) : undefined
  const curve = reopenUntil !== undefined && ramp && s ? [{ t: x0, lt: s.ltWad }, { t: reopenUntil, lt: s.ltWad }, { t: reopenUntil + 1, lt: ramp.find(p => p.t > reopenUntil)?.lt ?? ramp[0].lt }, ...ramp.filter(p => p.t > reopenUntil + 1)] : ramp

  if (!contracts) return <p className="px-5 py-10 text-dk-muted">No StockReef deployment is configured for chain {chain.id} yet.</p>
  if (!m || !s || now === undefined) return <p className="px-5 py-10 text-dk-muted">Reading the market…</p>

  const canSign = own && isConnected && chainId === chain.id
  const signHint = !isConnected ? 'Connect wallet' : chainId !== chain.id ? `Switch to chain ${chain.id}` : `Read-only: viewing ${label ?? ''}`
  const items = history?.items ?? []
  const prices = history?.prices ?? []
  const current = Number(m.valuationPriceWad) / 1e18
  // The operator sees every open position; a borrower sees their own.
  const positions = isOperator && active ? active : v && (v.debt > 0n || v.collateral > 0n) ? [v] : []

  return (
    <div className="flex flex-1 flex-col">
      <Ticker m={m} now={now} prices={prices} />
      <Alerts m={m} v={v} />
      <div className="grid flex-1 lg:grid-cols-[minmax(0,1fr)_440px]">
        <div className="flex min-w-0 flex-col">
          <PriceStrip prices={prices} current={current} x0={x0} x1={x1} now={now} priceWad={m.valuationPriceWad} indicative={m.valuationIndicative} />
          <Kpis v={v} s={s} />
          <ExposureChart
            s={s}
            v={v}
            now={now}
            x0={x0}
            x1={x1}
            curve={curve ?? []}
            items={items}
            prices={prices}
            currentPrice={current}
            mode={mode}
            onMode={setMode}
            win={win}
            onWin={setWin}
          />
        </div>
        <aside className="relative border-dk-line lg:border-l">
          <div className="lg:absolute lg:inset-0 lg:overflow-y-auto">
          {viewing && !own && (
            <p className="border-b border-dk-line px-6 py-2 text-sm text-dk-muted">
              Viewing {label} · read only
              {address && (
                <button type="button" onClick={() => pick(address)} className="ml-2 text-dk-up hover:underline">
                  Back to your loan
                </button>
              )}
            </p>
          )}
          <Ticket tab={tab} onTab={setTab} account={viewing} canSign={canSign} signHint={signHint} v={v} m={m} k={k} now={now} usdgWallet={usdgWallet} tslaWallet={tslaWallet} />
          <Automation account={viewing} v={v} s={s} items={items} onFund={() => setTab('buffer')} />
          </div>
        </aside>
      </div>
      <BottomTabs positions={positions} s={s} items={items} viewing={viewing} onView={pick} />
    </div>
  )
}
