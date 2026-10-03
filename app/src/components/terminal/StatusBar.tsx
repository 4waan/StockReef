'use client'

import { useAccount, useConnect } from 'wagmi'
import { demoAbi, gateAbi } from '@/generated/abi'
import { chain, contracts } from '@/lib/chain'
import { duration, nyClock, nyTime, short } from '@/lib/format'
import { useHistory } from '@/lib/history'
import { useDemoOperator, useMarketView, useProtocolNow, useTx } from '@/lib/hooks'
import { reasonList } from '@/lib/policy'
import { Dot, TxStatusLine } from './kit'

/** Price feed health on the left; on the demo deployment, the scenario picker and the operator's clock step. */
export function StatusBar() {
  const { isConnected } = useAccount()
  const { connect, connectors } = useConnect()
  const { data: m } = useMarketView()
  const now = useProtocolNow(m?.policy.time)
  const { data: history, error } = useHistory(undefined, undefined)
  const refresh = useTx()
  const demo = useTx()
  const { operator, isOperator } = useDemoOperator()
  if (!m || now === undefined) return null
  const s = m.policy
  const gate = history?.gate ?? []
  const feedDecimals = history?.feedDecimals ?? 8
  const historyError = !!error
  const age = s.priceUpdatedAt > 0n ? now - Number(s.priceUpdatedAt) : undefined
  const usable = s.reasons === 0
  const answer = m.valuationPriceWad / 10n ** BigInt(18 - feedDecimals)

  // Next scheduled milestone after now, for "Advance session".
  const steps = [s.prepAt, s.close - 2700n, s.finalAt, s.close + 3600n, s.nextOpen + 60n, s.nextOpen + 300n, s.nextOpen + 900n, s.open + 300n, s.open + 900n]
  const next = steps.filter(t => Number(t) > now).sort((a, b) => Number(a - b))[0]

  return (
    <footer className="z-10 flex lg:sticky lg:bottom-0 flex-wrap items-center gap-x-4 gap-y-2 border-t border-dk-line bg-dk-bg px-5 py-2 text-sm">
      <details className="relative">
        <summary className="flex cursor-pointer list-none items-center gap-2">
          <Dot tone={usable ? 'up' : 'down'} />
          <span>Stock price feed</span>
          {age !== undefined && <span className="num text-dk-muted">· {age < 60 ? `${age}s` : duration(age)}</span>}
          {!usable && <span className="text-dk-down">· {reasonList(Number(s.reasons))[0]}</span>}
          {m.usesPeg && <span className="text-dk-muted">· 1 USDG = 1 USD reference</span>}
          {historyError && <span className="text-dk-warn" title="The RPC refused a log read. Charts and tabs show the last history read; it retries every few seconds.">· history unavailable</span>}
        </summary>
        <div className="absolute bottom-full left-0 z-20 mb-2 w-96 rounded-md border border-dk-line bg-dk-panel p-4 shadow-xl">
          <div className="font-medium">Price gate</div>
          <p className="mt-1 text-dk-muted">
            {usable ? 'Price usable.' : `Not usable: ${reasonList(Number(s.reasons)).join(' · ')}.`} Last accepted {m.lastAcceptedAt > 0n ? `${duration(now - Number(m.lastAcceptedAt))} ago` : 'never'}.
            {s.admissionAt > 0n && ` Reopening admitted at ${nyClock(s.admissionAt)} ET.`}
          </p>
          {gate.length > 0 && (
            <ul className="mt-3 max-h-40 space-y-1 overflow-y-auto">
              {gate.slice(0, 12).map(g => (
                <li key={g.hash + g.kind} className="flex justify-between">
                  <span>{g.kind}</span>
                  <span className="num text-dk-muted">{nyTime(g.t)} ET</span>
                </li>
              ))}
            </ul>
          )}
          <button
            type="button"
            disabled={!isConnected && connectors.length === 0}
            onClick={() => isConnected ? contracts && refresh.send({ address: contracts.gate, abi: gateAbi, functionName: 'refresh', args: [] }) : connect({ connector: connectors[0], chainId: chain.id })}
            className="mt-3 rounded-md border border-dk-line px-3 py-1.5 hover:border-dk-muted disabled:cursor-not-allowed disabled:opacity-40"
          >
            {isConnected ? 'Refresh gate' : 'Connect to refresh'}
          </button>
          <p className="mt-1 text-xs text-dk-faint">{isConnected ? 'Anyone can refresh the gate. The keeper does it on every pass.' : 'Connect a wallet to submit a refresh.'}</p>
          <TxStatusLine status={refresh.status} />
        </div>
      </details>

      {m.simulationClock && (
        <div className="ml-auto flex flex-wrap items-center gap-3">
          <button
            type="button"
            disabled={!isOperator || !next || answer === 0n}
            onClick={() => contracts && next && demo.send({ address: contracts.demoController, abi: demoAbi, functionName: 'stepTo', args: [next, answer] })}
            title={!isOperator ? `Only the clock operator (${operator ? short(operator) : '…'}) can move the clock` : next ? `Moves the market clock to ${nyClock(next)} ET at the current price` : undefined}
            className="flex items-center gap-2 rounded-md border border-dk-line px-3 py-1.5 hover:border-dk-muted disabled:opacity-40"
          >
            Move market clock →
          </button>
          {demo.status.state !== 'idle' && (
            <div className="[&>p]:mt-0">
              <TxStatusLine status={demo.status} />
            </div>
          )}
        </div>
      )}
    </footer>
  )
}
