import type { ReactNode } from 'react'
import { explorerAddress, explorerTx } from '@/lib/chain'
import { STATES, STATE_COPY, type StateName } from '@/lib/policy'

/**
 * The shared visual kit. One dark terminal theme for every page; structure borrows from the references (dense
 * market bar and side ticket, lending-market parameter grids, review panels, an asset identity header), the
 * look does not change between them. Numbers are text, never buttons; only real actions are buttons.
 */

export type Tone = 'up' | 'down' | 'warn' | 'brand' | 'muted' | 'ink'

export const toneText: Record<Tone, string> = {
  up: 'text-dk-up',
  down: 'text-dk-down',
  warn: 'text-dk-warn',
  brand: 'text-[#e88a5a]',
  muted: 'text-dk-muted',
  ink: 'text-dk-ink',
}

const toneDot: Record<Tone, string> = {
  up: 'bg-dk-up',
  down: 'bg-dk-down',
  warn: 'bg-dk-warn',
  brand: 'bg-brand',
  muted: 'bg-dk-faint',
  ink: 'bg-dk-ink',
}

/** A titled surface. `kicker` is the small label above the title (the feature it shows). */
export function Card({ kicker, title, aside, children, className = '', pad = true }: { kicker?: ReactNode; title?: ReactNode; aside?: ReactNode; children: ReactNode; className?: string; pad?: boolean }) {
  return (
    <section className={`rounded-lg border border-dk-line bg-dk-panel ${className}`}>
      {(kicker || title || aside) && (
        <header className="flex flex-wrap items-start justify-between gap-3 border-b border-dk-line px-4 py-3">
          <div className="min-w-0">
            {kicker && <div className="text-[11px] font-semibold tracking-[.14em] text-[#e88a5a] uppercase">{kicker}</div>}
            {title && <h2 className="mt-0.5 text-[15px] font-semibold text-dk-ink">{title}</h2>}
          </div>
          {aside}
        </header>
      )}
      <div className={pad ? 'p-4' : ''}>{children}</div>
    </section>
  )
}

/** A labelled figure. */
export function Stat({ label, value, sub, tone = 'ink', size = 'md' }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: Tone; size?: 'sm' | 'md' | 'lg' | 'xl' }) {
  const s = { sm: 'text-[15px]', md: 'text-lg', lg: 'text-2xl', xl: 'text-[34px] leading-none' }[size]
  return (
    <div className="min-w-0">
      <div className="text-xs text-dk-muted">{label}</div>
      <div className={`num mt-1 font-semibold ${s} ${toneText[tone]}`}>{value}</div>
      {sub && <div className="mt-1 text-xs text-dk-faint">{sub}</div>}
    </div>
  )
}

/** A label and a right-aligned value. `before` shows a change as "before → value". */
export function KV({ label, value, before, tone = 'ink', hint }: { label: ReactNode; value: ReactNode; before?: ReactNode; tone?: Tone; hint?: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-dk-line/70 py-2 text-sm last:border-0">
      <span className="text-dk-muted">
        {label}
        {hint && <span className="ml-1.5 text-xs text-dk-faint">{hint}</span>}
      </span>
      <span className={`num text-right ${toneText[tone]}`}>
        {before !== undefined && (
          <>
            <span className="text-dk-muted">{before}</span>
            <span className="mx-1.5 text-dk-faint">→</span>
          </>
        )}
        {value}
      </span>
    </div>
  )
}

/** A status label: a dot and text. Deliberately not shaped like a button. */
export function Status({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1.5 text-xs font-medium ${toneText[tone]}`}>
      <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${toneDot[tone]}`} />
      {children}
    </span>
  )
}

export const phaseTone = (state: number): Tone => {
  const t = STATE_COPY[STATES[state] ?? 'GUARDED'].tone
  return t === 'ok' ? 'up' : t === 'prep' ? 'warn' : t === 'final' ? 'brand' : t === 'closed' ? 'muted' : 'down'
}

export function phaseName(state: number): StateName {
  return STATES[state] ?? 'GUARDED'
}

/** The session phase as a tag with its colour. */
export function PhaseTag({ state, className = '' }: { state: number; className?: string }) {
  const tone = phaseTone(state)
  const ring = { up: 'border-dk-up/40 bg-dk-up/10', warn: 'border-dk-warn/40 bg-dk-warn/10', brand: 'border-brand/60 bg-brand/15', muted: 'border-dk-line bg-dk-raised', down: 'border-dk-down/50 bg-dk-down/10', ink: '' }[tone]
  return (
    <span className={`inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs font-semibold tracking-wide uppercase ${ring} ${toneText[tone]} ${className}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${toneDot[tone]}`} />
      {STATE_COPY[phaseName(state)].label}
    </span>
  )
}

/**
 * The position meter: LTV against the limits that apply to it. The bar fills to the LTV; ticks mark the plan
 * target, the borrow limit, the threshold now and the threshold at the close.
 */
export function Meter({ ltv, marks, max = 0.9, min = 0.5 }: { ltv: number | undefined; marks: { at: number; label: string; tone: Tone; dashed?: boolean }[]; max?: number; min?: number }) {
  const x = (f: number) => `${Math.max(0, Math.min(100, ((f - min) / (max - min)) * 100))}%`
  const above = ltv !== undefined && marks.some(m => m.tone === 'down' && ltv > m.at)
  return (
    <div className="pt-6 pb-5">
      <div className="relative h-2.5 rounded-full bg-dk-raised">
        {ltv !== undefined && <div className={`absolute inset-y-0 left-0 rounded-full ${above ? 'bg-dk-down' : 'bg-dk-up'}`} style={{ width: x(ltv) }} />}
        {marks.map(m => (
          <div key={m.label} className="absolute -top-1.5 -bottom-1.5" style={{ left: x(m.at) }}>
            <div className={`h-full w-0 border-l-2 ${m.dashed ? 'border-dashed' : ''} ${m.tone === 'down' ? 'border-dk-down' : m.tone === 'warn' ? 'border-dk-warn' : m.tone === 'brand' ? 'border-brand' : 'border-dk-muted'}`} />
          </div>
        ))}
      </div>
      <div className="relative mt-1 h-8 text-[10px] whitespace-nowrap">
        {marks.map((m, i) => (
          <span key={m.label} className={`num absolute -translate-x-1/2 ${toneText[m.tone]}`} style={{ left: x(m.at), top: i % 2 ? 14 : 0 }}>
            {m.label}
          </span>
        ))}
      </div>
    </div>
  )
}

/** A small explanatory paragraph. */
export function Note({ children, tone = 'muted' }: { children: ReactNode; tone?: Tone }) {
  return <p className={`text-xs leading-relaxed ${tone === 'muted' ? 'text-dk-faint' : toneText[tone]}`}>{children}</p>
}

export function ExtLink({ href, children }: { href: string | undefined; children: ReactNode }) {
  if (!href) return <span className="num text-dk-muted">{children}</span>
  return (
    <a href={href} target="_blank" rel="noreferrer" className="num inline-flex items-center gap-1 text-dk-up underline-offset-2 hover:underline">
      {children}
      <svg viewBox="0 0 16 16" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden>
        <path d="M6 3h7v7M13 3L5 11" />
      </svg>
    </a>
  )
}

export const TxRef = ({ hash, children }: { hash: string; children?: ReactNode }) => <ExtLink href={explorerTx(hash)}>{children ?? `${hash.slice(0, 6)}…${hash.slice(-4)}`}</ExtLink>
export const AddrRef = ({ address, children }: { address: string; children?: ReactNode }) => (
  <ExtLink href={explorerAddress(address)}>{children ?? `${address.slice(0, 6)}…${address.slice(-4)}`}</ExtLink>
)

/** An allowed / locked line for the action matrix. */
export function Permit({ label, on, why }: { label: string; on: boolean; why: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-dk-line/70 py-2 text-sm last:border-0">
      <div>
        <div className="text-dk-ink">{label}</div>
        <div className="mt-0.5 text-xs text-dk-faint">{why}</div>
      </div>
      <span className={`mt-0.5 inline-flex shrink-0 items-center gap-1 text-xs font-semibold ${on ? 'text-dk-up' : 'text-dk-muted'}`}>
        {on ? (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
            <path d="M3 8.5l3 3 7-7" />
          </svg>
        ) : (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden>
            <rect x="3.5" y="7" width="9" height="6.5" rx="1" />
            <path d="M5.5 7V5a2.5 2.5 0 015 0v2" />
          </svg>
        )}
        {on ? 'Available' : 'Locked'}
      </span>
    </div>
  )
}

/** Underlined tabs for panels. */
export function TabBar<K extends string>({ tabs, value, onChange, className = '' }: { tabs: { key: K; label: ReactNode }[]; value: K; onChange: (k: K) => void; className?: string }) {
  return (
    <div role="tablist" className={`flex overflow-x-auto border-b border-dk-line ${className}`}>
      {tabs.map(t => (
        <button
          key={t.key}
          type="button"
          role="tab"
          aria-selected={value === t.key}
          onClick={() => onChange(t.key)}
          className={`relative shrink-0 px-4 py-2.5 text-sm whitespace-nowrap ${value === t.key ? 'font-semibold text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}
        >
          {t.label}
          {value === t.key && <span className="absolute inset-x-3 -bottom-px h-0.5 bg-brand" />}
        </button>
      ))}
    </div>
  )
}

export function Loading({ children = 'Reading the contracts…' }: { children?: ReactNode }) {
  return <p className="px-5 py-10 text-sm text-dk-muted">{children}</p>
}
