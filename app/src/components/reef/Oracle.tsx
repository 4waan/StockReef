'use client'

import { demoAbi, gateAbi } from '@/generated/abi'
import { contracts } from '@/lib/chain'
import { duration, nyClock, price } from '@/lib/format'
import { useHistory } from '@/lib/history'
import { useDemoOperator, useMarketView, useTx } from '@/lib/hooks'
import { reasonList, STATE_COPY, stateName } from '@/lib/policy'
import { stepTime } from '@/lib/scenario'
import { useSession } from '@/lib/session'
import { KV, Pop, TxRef } from './ui'

/**
 * The testnet price feed and clock as one compact pill. The pop-up holds the detail: feed age and checks, the
 * gate's last acceptance and admission, recent gate events, and (for the demo operator) the controls that keep
 * the testnet on the scripted step.
 */
export function OraclePill({ scripted = true, align = 'right', side = 'top' }: { scripted?: boolean; align?: 'left' | 'right'; side?: 'top' | 'bottom' }) {
  const { data: m } = useMarketView()
  const { anchor, current, chainTime } = useSession()
  const { isOperator } = useDemoOperator()
  const { data: history } = useHistory(undefined, undefined)
  const step = useTx()
  const refresh = useTx()
  const c = contracts
  if (!m || !c) return null
  const s = m.policy
  const now = chainTime ?? s.time
  const fresh = s.reasons === 0
  const age = s.priceUpdatedAt > 0n ? Number(now - s.priceUpdatedAt) : undefined
  const target = scripted && anchor && current ? stepTime(anchor, current.step) : undefined
  const aligned = target !== undefined && current !== undefined && now >= target && now < target + 600n && s.state === current.snapshot.state
  const behind = target !== undefined && now < target
  const answer = current ? BigInt(Math.round(current.step.quote * 1e8)) : 0n
  const tone = fresh ? (scripted && !aligned ? 'bg-dk-warn' : 'bg-dk-up') : 'bg-dk-down'
  const reasons = reasonList(Number(s.reasons))

  return (
    <Pop
      label="Testnet oracle and clock"
      align={align}
      side={side}
      panelClass="w-80"
      trigger={
        <span className="inline-flex items-center gap-2 rounded-full border border-dk-line px-2.5 py-1 text-xs text-dk-muted hover:border-dk-muted hover:text-dk-ink">
          <span className={`h-2 w-2 rounded-full ${tone}`} />
          <span className="num">Oracle {price(m.valuationPriceWad)}</span>
          <span className="text-dk-faint">{fresh ? (scripted ? (aligned ? 'synced' : 'not synced') : 'fresh') : 'stale'}</span>
        </span>
      }
    >
      <div className="mb-2 flex items-center justify-between">
        <span className="font-semibold">Testnet oracle</span>
        <span className={`text-xs ${fresh ? 'text-dk-up' : 'text-dk-down'}`}>{fresh ? 'Price usable' : 'Price not usable'}</span>
      </div>
      <KV label="TSLA price" value={price(m.valuationPriceWad)} />
      <KV label="Age" value={age === undefined ? '—' : age < 60 ? `${age}s` : duration(age)} hint="usable for 120 s" tone={fresh ? 'ink' : 'down'} />
      {!fresh && <KV label="Why" value={reasons[0] ?? '—'} tone="down" />}
      <KV label="Testnet phase" value={STATE_COPY[stateName(s.state)].label} />
      <KV label="Testnet clock" value={`${new Date(Number(now) * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })} ET`} />
      {s.admissionAt > 0n && <KV label="Admitted" value={`${nyClock(s.admissionAt)} ET`} />}
      {scripted && <KV label="Scenario step" value={aligned ? 'in sync' : behind ? 'testnet behind' : 'testnet elsewhere'} tone={aligned ? 'up' : 'warn'} />}
      {m.usesPeg && <KV label="USDG" value="1 USDG = 1 USD" hint="test peg" />}
      {history?.gate && history.gate.length > 0 && (
        <details className="mt-2 text-xs">
          <summary className="cursor-pointer text-dk-muted">Gate events</summary>
          <ul className="mt-1 max-h-28 space-y-0.5 overflow-y-auto">
            {history.gate.slice(0, 8).map(g => (
              <li key={g.hash + g.kind} className="flex justify-between">
                <span>{g.kind}</span>
                <TxRef hash={g.hash} />
              </li>
            ))}
          </ul>
        </details>
      )}
      <div className="mt-3 flex flex-wrap gap-1.5">
        {isOperator && scripted && current && (
          <>
            <Act disabled={!behind} onClick={() => target && step.send({ address: c.demoController, abi: demoAbi, functionName: 'stepTo', args: [target, answer] })}>
              Sync to {nyClock(target)}
            </Act>
            <Act onClick={() => step.send({ address: c.demoController, abi: demoAbi, functionName: 'push', args: [answer] })}>Refresh price</Act>
          </>
        )}
        <Act onClick={() => refresh.send({ address: c.gate, abi: gateAbi, functionName: 'refresh', args: [] })}>Refresh gate</Act>
      </div>
      {[step.status, refresh.status].map((st, i) =>
        st.state === 'failed' ? (
          <p key={i} className="mt-1 text-xs text-dk-down">
            {st.error}
          </p>
        ) : st.hash ? (
          <p key={i} className="mt-1 text-xs text-dk-up">
            Confirmed · <TxRef hash={st.hash}>receipt</TxRef>
          </p>
        ) : null,
      )}
    </Pop>
  )
}

function Act({ children, onClick, disabled }: { children: React.ReactNode; onClick: () => void; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled} className="rounded-md border border-dk-line px-2 py-1 text-xs text-dk-ink hover:border-dk-muted disabled:opacity-30">
      {children}
    </button>
  )
}
