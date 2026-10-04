'use client'

import { useState } from 'react'
import { parseUnits, type Abi } from 'viem'
import { useAccount, useReadContract } from 'wagmi'
import { marketAbi } from '@/generated/abi'
import { chain, contracts, demoAccounts } from '@/lib/chain'
import { useDesk } from '@/lib/desk'
import { pct, short, tokens, usdg } from '@/lib/format'
import { useBook } from '@/lib/session'
import { LenderLoss } from './features'
import { SignAction } from './Ticket'
import { Fig } from './features'
import { Card, Info, KV, Loading, Status, TabBar } from './ui'

/** The lender book: what lenders own, valued by what loans can recover at the scenario price. */
export function LendPage() {
  const d = useDesk()
  const { data: book } = useBook()
  const { address, isConnected, chainId } = useAccount()
  const { data: haircut } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'RECOVERY_HAIRCUT', chainId: chain.id, query: { enabled: !!contracts, staleTime: Infinity } })
  const who = d.viewing
  const { data: shares } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'balanceOf', args: who ? [who] : undefined, chainId: chain.id, query: { enabled: !!contracts && !!who, refetchInterval: 4000 } })
  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit')
  const [text, setText] = useState('')
  let typed: bigint | undefined
  try {
    typed = text ? parseUnits(text, 6) : undefined
  } catch {
    typed = undefined
  }
  const { data: preview } = useReadContract({ address: contracts?.market, abi: marketAbi, functionName: 'previewDeposit', args: typed ? [typed] : undefined, chainId: chain.id, query: { enabled: !!contracts && !!typed } })
  if (!contracts) return <Loading>No StockReef deployment is configured for chain {chain.id}.</Loading>
  if (!d.current || !d.policy || !book || haircut === undefined) return <Loading />
  const cur = d.current
  const s = cur.snapshot
  const total = Number(book.lenderAssets + book.shortfall) || 1
  const mine = shares !== undefined ? (shares * book.shareValue) / 10n ** 12n : undefined
  const amount = typed
  const canSign = d.own && isConnected && chainId === chain.id
  // Slippage floor: at least 99% of the shares previewDeposit quotes now.
  const minShares = preview !== undefined ? (preview * 99n) / 100n : undefined
  const call = address && amount ? (tab === 'deposit' ? { address: contracts.market, abi: marketAbi as Abi, functionName: 'depositChecked', args: [amount, address, minShares ?? 0n] } : { address: contracts.market, abi: marketAbi as Abi, functionName: 'withdraw', args: [amount, address, address] }) : undefined
  const blocked = tab === 'deposit' && amount && minShares === undefined ? 'Quoting shares…' : !s.lenderOpen ? 'Lender window closed in this phase' : !amount ? 'Enter an amount' : tab === 'withdraw' && amount > book.cash ? `Only ${usdg(book.cash)} USDG of idle cash` : undefined
  return (
    <div className="w-full space-y-3 px-4 py-4 xl:px-6">
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-xl font-semibold">Lend</h1>
        <span className="text-sm text-dk-muted">USDG lender book</span>
        <span className="ml-auto">
          <Status tone={s.lenderOpen ? 'up' : 'muted'}>{s.lenderOpen ? 'Window open' : 'Window closed'}</Status>
        </span>
      </div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="space-y-4">
          <Card>
            <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <Fig k="Lender assets" v={usdg(book.lenderAssets)} sub="USDG" />
              <Fig k="Share value" v={(Number(book.shareValue) / 1e6).toFixed(4)} sub="per 1 USDG in" />
              <Fig k="Utilization" v={pct(book.utilizationWad, 1)} sub={`cap ${pct(d.policy.utilizationCap, 0)}`} />
              <Fig k="Idle cash" v={usdg(book.cash)} sub="withdrawable" />
            </div>
            <div className="mt-5">
              <div className="flex h-3 overflow-hidden rounded-full bg-dk-raised" role="img" aria-label="Lender book composition">
                <div className="bg-dk-up" style={{ width: `${(Number(book.cash) / total) * 100}%` }} />
                <div className="ml-0.5 bg-c-ltv" style={{ width: `${(Number(book.recoverable) / total) * 100}%` }} />
                {book.shortfall > 0n && <div className="ml-0.5 bg-dk-down" style={{ width: `${(Number(book.shortfall) / total) * 100}%` }} />}
              </div>
              <div className="mt-2 flex flex-wrap gap-4 text-xs text-dk-muted">
                <span className="inline-flex items-center gap-1.5">
                  <span className="h-2 w-2 rounded-sm bg-dk-up" />
                  Cash {usdg(book.cash)}
                </span>
                <span className="inline-flex items-center gap-1.5">
                  <span className="h-2 w-2 rounded-sm bg-c-ltv" />
                  Recoverable loans {usdg(book.recoverable)}
                </span>
                <span className="inline-flex items-center gap-1.5">
                  <span className="h-2 w-2 rounded-sm bg-dk-down" />
                  Recognized shortfall {usdg(book.shortfall)}
                </span>
              </div>
            </div>
          </Card>
          <LenderLoss book={book} cur={cur} haircut={haircut as bigint} />
          <Card kicker="Loans in the book">
            <div className="overflow-x-auto">
              <table className="w-full min-w-[620px] text-sm">
                <thead>
                  <tr className="text-left text-xs text-dk-muted">
                    {['Borrower', 'Collateral', 'Value', 'Debt', 'Recoverable', 'Shortfall'].map(h => (
                      <th key={h} className="pb-2 font-normal">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="num">
                  {book.loans.map(l => (
                    <tr key={l.account} className="border-t border-dk-line">
                      <td className="py-2">{demoAccounts.find(a => a.address.toLowerCase() === l.account.toLowerCase())?.label ?? short(l.account)}</td>
                      <td>{tokens(l.collateral, 4)} TSLA</td>
                      <td>{usdg(l.value)}</td>
                      <td>{usdg(l.debt)}</td>
                      <td>{usdg(l.recoverable)}</td>
                      <td className={l.debt > l.recoverable ? 'text-dk-down' : 'text-dk-muted'}>{usdg(l.debt - l.recoverable)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
        </div>
        <aside className="space-y-4">
          <Card pad={false}>
            <TabBar tabs={[{ key: 'deposit', label: 'Deposit' }, { key: 'withdraw', label: 'Withdraw' }]} value={tab} onChange={setTab} />
            <div className="p-4">
              <div className="flex items-center rounded-md border border-dk-line bg-dk-bg px-3">
                <input inputMode="decimal" aria-label="Amount in USDG" value={text} onChange={e => setText(e.target.value.replace(',', '.'))} placeholder="0.00" className="num w-full bg-transparent py-2.5 text-2xl outline-none placeholder:text-dk-faint" />
                <span className="text-sm text-dk-muted">USDG</span>
              </div>
              <div className="mt-4 rounded-md border border-dk-line px-3">
                <KV label="Your position" value={mine !== undefined ? `${usdg(mine)} USDG` : '—'} hint={who ? demoAccounts.find(a => a.address.toLowerCase() === who.toLowerCase())?.label : undefined} />
                <KV label="Share value" value={(Number(book.shareValue) / 1e6).toFixed(4)} />
                <KV label={<>Window <Info label="About the lender window">Deposits and withdrawals open in the normal open phase, after reopening recovery, and close when preparation begins. New lending stops while the book is impaired.</Info></>} value={s.lenderOpen ? 'open' : 'closed'} tone={s.lenderOpen ? 'up' : 'muted'} />
              </div>
              <SignAction
                label={tab === 'deposit' ? `Deposit ${amount ? usdg(amount) : ''} USDG` : `Withdraw ${amount ? usdg(amount) : ''} USDG`}
                call={call}
                approve={tab === 'deposit' && amount ? { token: contracts.loanToken, spender: contracts.market, amount, symbol: 'USDG', decimals: 6 } : undefined}
                blocked={blocked}
                ctx={{ account: address, canSign, walletReady: isConnected && chainId === chain.id, signHint: !isConnected ? 'Connect wallet to sign' : chainId !== chain.id ? `Switch to chain ${chain.id}` : 'Viewing another account: read only', p: d.position, cur, pol: d.policy, book }}
              />
            </div>
          </Card>
        </aside>
      </div>
    </div>
  )
}
