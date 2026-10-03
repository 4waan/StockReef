'use client'

import { useEffect, useRef, useState, type ReactNode } from 'react'
import { explorerTx } from '@/lib/chain'
import type { TxStatus } from '@/lib/hooks'

/** Size of an element, tracked with a ResizeObserver so charts draw at real pixel size. */
export function useWidth<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  const [size, setSize] = useState({ width: 0, height: 0 })
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const ro = new ResizeObserver(([e]) => setSize({ width: Math.floor(e.contentRect.width), height: Math.floor(e.contentRect.height) }))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  return { ref, ...size }
}

/** Underlined tab row, as in the mockup's ticket and bottom panel. */
export function Tabs<K extends string>({ tabs, value, onChange, className = '' }: { tabs: { key: K; label: ReactNode }[]; value: K; onChange: (k: K) => void; className?: string }) {
  return (
    <div className={`flex border-b border-dk-line ${className}`}>
      {tabs.map((t, i) => (
        <button
          key={t.key}
          type="button"
          onClick={() => onChange(t.key)}
          className={`relative px-5 py-3 text-[15px] ${i > 0 ? 'border-l border-dk-line/0' : ''} ${value === t.key ? 'font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}
        >
          {t.label}
          {value === t.key && <span className="absolute inset-x-3 -bottom-px h-0.5 bg-dk-up" />}
        </button>
      ))}
    </div>
  )
}

/** Two-option toggle (LTV | Price). */
export function Segmented<K extends string>({ options, value, onChange }: { options: { key: K; label: string }[]; value: K; onChange: (k: K) => void }) {
  return (
    <div className="flex rounded-md border border-dk-line p-0.5">
      {options.map(o => (
        <button
          key={o.key}
          type="button"
          onClick={() => onChange(o.key)}
          className={`rounded px-4 py-1 text-sm ${value === o.key ? 'bg-dk-raised font-medium text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

/** A native select styled as the mockup's dropdowns. */
export function Select<K extends string>({ value, options, onChange, label }: { value: K; options: { key: K; label: string }[]; onChange: (k: K) => void; label?: string }) {
  return (
    <label className="relative inline-flex items-center">
      {label && <span className="mr-2 text-sm text-dk-muted">{label}</span>}
      <select
        value={value}
        onChange={e => onChange(e.target.value as K)}
        className="appearance-none rounded-md border border-dk-line bg-dk-panel py-1.5 pr-8 pl-3 text-sm text-dk-ink outline-none focus:border-dk-muted"
      >
        {options.map(o => (
          <option key={o.key} value={o.key}>
            {o.label}
          </option>
        ))}
      </select>
      <Chevron className="pointer-events-none absolute right-2.5 h-3.5 w-3.5 text-dk-muted" />
    </label>
  )
}

export function Chevron({ className = 'h-3.5 w-3.5' }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" className={className} fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M4 6l4 4 4-4" />
    </svg>
  )
}

export function ExternalIcon({ className = 'h-3 w-3' }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" className={className} fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M6 3h7v7M13 3L5 11" />
    </svg>
  )
}

export function CheckCircle({ className = 'h-5 w-5' }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" className={className}>
      <circle cx="10" cy="10" r="9" fill="currentColor" />
      <path d="M6 10.2l2.6 2.6L14 7.4" fill="none" stroke="#0f1114" strokeWidth="2" />
    </svg>
  )
}

export function Dot({ tone }: { tone: 'up' | 'warn' | 'down' | 'muted' }) {
  const cls = { up: 'bg-dk-up', warn: 'bg-dk-warn', down: 'bg-dk-down', muted: 'bg-dk-faint' }[tone]
  return <span className={`inline-block h-2 w-2 shrink-0 rounded-full ${cls}`} />
}

export function Btn({
  children,
  onClick,
  disabled,
  variant = 'outline',
  className = '',
  title,
}: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  variant?: 'primary' | 'outline' | 'ghost' | 'danger'
  className?: string
  title?: string
}) {
  const styles = {
    primary: 'border border-dk-up bg-dk-up/15 text-dk-up hover:bg-dk-up/25',
    outline: 'border border-dk-line text-dk-ink hover:border-dk-muted',
    ghost: 'text-dk-muted hover:text-dk-ink',
    danger: 'border border-dk-down/60 text-dk-down hover:bg-dk-down/10',
  }[variant]
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      disabled={disabled}
      className={`rounded-md px-3 py-1.5 text-sm transition disabled:cursor-not-allowed disabled:opacity-40 ${styles} ${className}`}
    >
      {children}
    </button>
  )
}

/** A label and a right-aligned value, as in the ticket's summary rows. */
export function Line({ label, children, tone }: { label: ReactNode; children: ReactNode; tone?: 'up' | 'warn' | 'down' }) {
  const color = tone === 'up' ? 'text-dk-up' : tone === 'warn' ? 'text-dk-warn' : tone === 'down' ? 'text-dk-down' : 'text-dk-ink'
  return (
    <div className="flex items-center justify-between border-b border-dk-line py-2.5 text-[15px] last:border-0">
      <span className="text-dk-muted">{label}</span>
      <span className={`num ${color}`}>{children}</span>
    </div>
  )
}

export function TxLink({ hash, children }: { hash: string; children?: ReactNode }) {
  const url = explorerTx(hash)
  const text = children ?? `${hash.slice(0, 6)}…${hash.slice(-4)}`
  if (!url) return <span className="num text-dk-muted">{text}</span>
  return (
    <a href={url} target="_blank" rel="noreferrer" className="num inline-flex items-center gap-1 text-dk-up underline-offset-2 hover:underline">
      {text}
      <ExternalIcon />
    </a>
  )
}

/** The transaction's progress, under an action button. */
export function TxStatusLine({ status }: { status?: TxStatus }) {
  if (!status || status.state === 'idle') return null
  const text = {
    approving: 'Approving the token in your wallet…',
    pending: 'Waiting for confirmation…',
    mined: 'Confirmed',
    failed: `Failed: ${status.error ?? 'reverted'}`,
  }[status.state]
  const tone = status.state === 'failed' ? 'text-dk-down' : status.state === 'mined' ? 'text-dk-up' : 'text-dk-muted'
  return (
    <p className={`mt-2 text-sm ${tone}`}>
      {text}
      {status.hash && (
        <>
          {' · '}
          <TxLink hash={status.hash}>View tx</TxLink>
        </>
      )}
    </p>
  )
}

/** Round "nice" axis ticks between lo and hi. */
export function niceTicks(lo: number, hi: number, count = 4): number[] {
  const span = hi - lo
  if (span <= 0) return [lo]
  const raw = span / count
  const mag = 10 ** Math.floor(Math.log10(raw))
  const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => s >= raw) ?? raw
  const out: number[] = []
  for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-9; v += step) out.push(Number(v.toFixed(10)))
  return out
}

/** A titled block on the app's dark pages. */
export function Panel({ title, aside, children, className = '' }: { title?: ReactNode; aside?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`border-b border-dk-line px-5 py-4 ${className}`}>
      {(title || aside) && (
        <header className="mb-3 flex flex-wrap items-center justify-between gap-3">
          {title && <h2 className="text-lg font-semibold">{title}</h2>}
          {aside}
        </header>
      )}
      {children}
    </section>
  )
}

/** A labelled number, as in the trading view's KPI row. */
export function Metric({ label, value, sub, tone = '', big = false }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: string; big?: boolean }) {
  return (
    <div>
      <div className="text-sm text-dk-muted">{label}</div>
      <div className={`num mt-0.5 font-semibold ${big ? 'text-[28px] leading-tight' : 'text-lg'} ${tone}`}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-dk-faint">{sub}</div>}
    </div>
  )
}
