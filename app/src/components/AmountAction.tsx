'use client'

import { useState } from 'react'
import { parseUnits } from 'viem'
import { explorerTx } from '@/lib/chain'
import type { TxStatus } from '@/lib/hooks'
import { Button } from './ui'

/** A labelled amount input with one action button and the transaction's status underneath. */
export function AmountAction({
  label,
  unit,
  decimals,
  action,
  onSubmit,
  status,
  disabled,
  hint,
  max,
}: {
  label: string
  unit: string
  decimals: number
  action: string
  onSubmit: (amount: bigint) => void
  status?: TxStatus
  disabled?: boolean
  hint?: string
  max?: string
}) {
  const [value, setValue] = useState('')
  let amount: bigint | undefined
  try {
    amount = value ? parseUnits(value, decimals) : undefined
  } catch {
    amount = undefined
  }
  return (
    <div>
      <label className="text-xs text-muted">{label}</label>
      <div className="mt-1 flex gap-2">
        <div className="flex flex-1 items-center rounded-lg border border-line bg-surface px-3 focus-within:border-reef">
          <input
            inputMode="decimal"
            value={value}
            onChange={e => setValue(e.target.value.replace(',', '.'))}
            placeholder="0.00"
            className="num w-full bg-transparent py-2 text-sm outline-none"
          />
          {max && (
            <button type="button" onClick={() => setValue(max)} className="mr-2 text-xs font-semibold text-reef">
              Max
            </button>
          )}
          <span className="text-xs text-faint">{unit}</span>
        </div>
        <Button disabled={disabled || !amount} onClick={() => amount && onSubmit(amount)}>
          {action}
        </Button>
      </div>
      {hint && <p className="mt-1 text-xs text-faint">{hint}</p>}
      <TxLine status={status} />
    </div>
  )
}

export function TxLine({ status }: { status?: TxStatus }) {
  if (!status || status.state === 'idle') return null
  const text = {
    approving: 'Approving the token…',
    pending: 'Waiting for confirmation…',
    mined: 'Confirmed',
    failed: `Failed: ${status.error ?? 'reverted'}`,
  }[status.state]
  const url = status.hash ? explorerTx(status.hash) : undefined
  return (
    <p className={`mt-1 text-xs ${status.state === 'failed' ? 'text-guarded' : status.state === 'mined' ? 'text-reef' : 'text-muted'}`}>
      {text}
      {url && (
        <>
          {' · '}
          <a href={url} target="_blank" rel="noreferrer" className="underline">
            receipt
          </a>
        </>
      )}
    </p>
  )
}
