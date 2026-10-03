'use client'

import { useState } from 'react'
import type { Address } from 'viem'
import { demoAccounts } from '@/lib/chain'
import { nyClock, pct, pctOf, short, tokens, usdg } from '@/lib/format'
import { EXECUTION_KINDS, type HistoryItem } from '@/lib/history'
import { abovePlan } from '@/lib/policy'
import type { AccountData, Snapshot } from '@/lib/types'
import { Dot, Tabs, TxLink } from './kit'

type Key = 'positions' | 'executions' | 'history'

const label = (a: Address) => demoAccounts.find(d => d.address.toLowerCase() === a.toLowerCase())?.label ?? short(a)

/** Positions, executions and the account's full event history, with the latest execution underneath. */
export function BottomTabs({ positions, s, items, viewing, onView }: { positions: readonly AccountData[]; s: Snapshot; items: HistoryItem[]; viewing: Address | undefined; onView: (a: Address) => void }) {
  const [tab, setTab] = useState<Key>('positions')
  const executions = items.filter(i => EXECUTION_KINDS.includes(i.kind))
  const latest = executions[0]
  const lastAction = (a: Address) => (viewing && a.toLowerCase() === viewing.toLowerCase() ? executions[0] : undefined)

  return (
    <section className="border-t border-dk-line">
      <Tabs
        tabs={[
          { key: 'positions', label: `Positions (${positions.length})` },
          { key: 'executions', label: 'Executions' },
          { key: 'history', label: 'History' },
        ]}
        value={tab}
        onChange={setTab}
      />
      <div className="overflow-x-auto">
        {tab === 'positions' && (
          <Table head={['Market', 'Collateral', 'Debt', 'LTV', 'Threshold', 'Buffer', 'Last action']}>
            {positions.length === 0 && <Empty cols={7}>No open position.</Empty>}
            {positions.map(p => {
              const act = lastAction(p.account)
              const mine = viewing?.toLowerCase() === p.account.toLowerCase()
              return (
                <tr key={p.account} onClick={() => onView(p.account)} className={`cursor-pointer border-t border-dk-line hover:bg-dk-raised ${mine ? '' : 'text-dk-muted'}`}>
                  <Td>
                    TSLA / USDG {positions.length > 1 && <span className="ml-1 text-xs text-dk-faint">{label(p.account)}</span>}
                  </Td>
                  <Td num>{tokens(p.collateral, 2)} TSLA</Td>
                  <Td num>{usdg(p.debt)} USDG</Td>
                  <Td num tone={p.ltvWad > s.ltWad ? 'text-dk-down' : abovePlan(p.repayToTarget) ? 'text-dk-warn' : 'text-dk-up'}>
                    {p.debt > 0n ? pct(p.ltvWad, 1) : '—'}
                  </Td>
                  <Td num tone="text-dk-warn">
                    {pct(s.ltWad, 1)}
                  </Td>
                  <Td num>{usdg(p.plan.balance)} USDG</Td>
                  <Td>{act ? `${act.kind} ${usdg(act.amount, 0)}` : p.missedExecution ? <span className="text-dk-down">Missed execution</span> : '—'}</Td>
                </tr>
              )
            })}
          </Table>
        )}
        {tab === 'executions' && (
          <Table head={['Time (ET)', 'Action', 'Amount', 'LTV', 'Detail', 'Transaction']}>
            {executions.length === 0 && <Empty cols={6}>No executions yet for this loan.</Empty>}
            {executions.map(e => (
              <tr key={e.hash + e.kind} className="border-t border-dk-line">
                <Td num>{nyClock(e.t, true)}</Td>
                <Td>{e.kind}</Td>
                <Td num>{usdg(e.amount)} USDG</Td>
                <Td num>{e.ltvBefore !== undefined ? `${pctOf(e.ltvBefore)} → ${pctOf(e.ltvAfter)}` : '—'}</Td>
                <Td tone="text-dk-muted">{e.detail ?? ''}</Td>
                <Td>
                  <TxLink hash={e.hash} />
                </Td>
              </tr>
            ))}
          </Table>
        )}
        {tab === 'history' && (
          <Table head={['Time (ET)', 'Event', 'Amount', 'Debt after', 'Collateral after', 'Transaction']}>
            {items.length === 0 && <Empty cols={6}>No activity yet.</Empty>}
            {items.map(e => (
              <tr key={e.hash + e.kind + e.logIndex} className="border-t border-dk-line">
                <Td num>{nyClock(e.t, true)}</Td>
                <Td>
                  {e.kind}
                  {e.detail && <span className="ml-2 text-dk-faint">{e.detail}</span>}
                </Td>
                <Td num>{e.unit === 'TSLA' ? `${tokens(e.amount)} TSLA` : e.unit === 'USDG' ? `${usdg(e.amount)} USDG` : '—'}</Td>
                <Td num>{e.debtAfter !== undefined ? `${usdg(e.debtAfter)} USDG` : '—'}</Td>
                <Td num>{tokens(e.collateralAfter, 4)} TSLA</Td>
                <Td>
                  <TxLink hash={e.hash} />
                </Td>
              </tr>
            ))}
          </Table>
        )}
      </div>
      {latest && (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-dk-line px-5 py-2.5 text-sm">
          <Dot tone="up" />
          <span className="num">{nyClock(latest.t, true)}</span>
          <span className="text-dk-up">Confirmed</span>
          <Bar />
          <span className="num">
            {usdg(latest.amount, 0)} USDG {latest.kind.toLowerCase()}
          </span>
          {latest.ltvBefore !== undefined && (
            <>
              <Bar />
              <span className="num">
                {pctOf(latest.ltvBefore)} → {pctOf(latest.ltvAfter)}
              </span>
            </>
          )}
          <Bar />
          <TxLink hash={latest.hash}>View tx</TxLink>
        </div>
      )}
    </section>
  )
}

function Bar() {
  return <span className="h-4 w-px bg-dk-line" />
}

function Table({ head, children }: { head: string[]; children: React.ReactNode }) {
  return (
    <table className="w-full min-w-[760px] text-[15px]">
      <thead>
        <tr className="text-left text-sm text-dk-muted">
          {head.map(h => (
            <th key={h} className="px-5 py-2 font-normal">
              {h}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>{children}</tbody>
    </table>
  )
}

function Td({ children, num, tone = '' }: { children: React.ReactNode; num?: boolean; tone?: string }) {
  return <td className={`px-5 py-2.5 ${num ? 'num' : ''} ${tone}`}>{children}</td>
}

function Empty({ cols, children }: { cols: number; children: React.ReactNode }) {
  return (
    <tr className="border-t border-dk-line">
      <td colSpan={cols} className="px-5 py-4 text-dk-faint">
        {children}
      </td>
    </tr>
  )
}
