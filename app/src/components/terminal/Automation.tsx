'use client'

import type { Address } from 'viem'
import { escrowAbi } from '@/generated/abi'
import { contracts } from '@/lib/chain'
import { nyClock, nyTime, pct, usdg } from '@/lib/format'
import type { HistoryItem } from '@/lib/history'
import { useTx } from '@/lib/hooks'
import type { AccountData, Snapshot } from '@/lib/types'
import { CheckCircle, TxLink, TxStatusLine } from './kit'

/** What the funded buffer did, or will do, for this loan. */
export function Automation({ account, v, s, items, onFund }: { account: Address | undefined; v: AccountData | undefined; s: Snapshot; items: HistoryItem[]; onFund: () => void }) {
  const run = useTx()
  const last = items.find(i => i.kind === 'Buffer repaid' && i.t >= Number(s.open))
  const p = v?.plan
  let status: { text: string; tone: string; check?: boolean }
  if (!v) status = { text: '—', tone: 'text-dk-muted' }
  else if (v.bufferExecutableNow > 0n) status = { text: 'Ready to run', tone: 'text-dk-warn' }
  else if (last) status = { text: 'Executed', tone: 'text-dk-up', check: true }
  else if (v.bufferCommitted) status = { text: 'Committed', tone: 'text-dk-warn' }
  else if (v.bufferActive) status = { text: 'Armed', tone: 'text-dk-up' }
  else status = { text: 'Not set', tone: 'text-dk-muted' }

  return (
    <div className="border-t border-dk-line px-6 py-4">
      <div className="flex items-center gap-3">
        <h3 className="text-xl font-semibold">Automation</h3>
        <span className={`flex items-center gap-1.5 text-[15px] ${status.tone}`}>
          {status.check && <CheckCircle className="h-5 w-5 text-dk-up" />}
          {status.text}
        </span>
      </div>

      {last ? (
        <div className="mt-3 space-y-1.5 text-[15px]">
          <div className="flex justify-between">
            <span className="text-dk-muted">Repaid</span>
            <span className="num">{usdg(last.amount)} USDG</span>
          </div>
          <div className="flex justify-between">
            <span className="num text-dk-muted">{nyClock(last.t, true)} ET</span>
            <TxLink hash={last.hash} />
          </div>
        </div>
      ) : v && v.bufferActive ? (
        <p className="mt-3 text-[15px] text-dk-muted">
          Would repay <span className="num text-dk-ink">{usdg(v.bufferCoverage)} USDG</span> toward {pct(p!.targetWad, 0)} at the next window, capped at{' '}
          <span className="num">{usdg(p!.perSessionCap)}</span> a session, until {nyTime(p!.expiry)} ET.
        </p>
      ) : (
        <p className="mt-3 text-[15px] text-dk-muted">No plan. A funded buffer repays debt during preparation, before any trim, without selling stock.</p>
      )}

      {v && v.bufferExecutableNow > 0n && (
        <div className="mt-3">
          <button
            type="button"
            onClick={() => contracts && account && run.send({ address: contracts.escrow, abi: escrowAbi, functionName: 'executeBuffer', args: [account] })}
            className="w-full rounded-md border border-dk-warn py-2 text-[15px] text-dk-warn hover:bg-dk-warn/10"
          >
            Run buffer now · {usdg(v.bufferExecutableNow)} USDG
          </button>
          <p className="mt-1 text-xs text-dk-faint">Anyone can run a funded plan; the keeper normally does. It pays no reward.</p>
          <TxStatusLine status={run.status} />
        </div>
      )}

      <div className="mt-3 flex items-center justify-between">
        <span className="text-[15px] text-dk-muted">Buffer remaining</span>
        <div className="flex items-center gap-4">
          <span className="num text-[15px]">{usdg(p?.balance)} USDG</span>
          <button type="button" onClick={onFund} className="rounded-md border border-dk-up/70 px-4 py-1.5 text-sm text-dk-up hover:bg-dk-up/10">
            Fund buffer
          </button>
        </div>
      </div>
    </div>
  )
}
