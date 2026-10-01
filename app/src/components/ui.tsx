import type { ReactNode } from 'react'

export function Card({ title, aside, children, className = '' }: { title?: ReactNode; aside?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`rounded-2xl border border-line bg-surface p-5 shadow-[0_1px_2px_rgba(15,23,42,0.04)] ${className}`}>
      {(title || aside) && (
        <header className="mb-4 flex items-baseline justify-between gap-3">
          {title && <h2 className="text-sm font-semibold tracking-wide text-muted uppercase">{title}</h2>}
          {aside}
        </header>
      )}
      {children}
    </section>
  )
}

export function Stat({ label, value, sub, big = false }: { label: string; value: ReactNode; sub?: ReactNode; big?: boolean }) {
  return (
    <div>
      <div className="text-xs text-muted">{label}</div>
      <div className={`num mt-0.5 ${big ? 'text-3xl font-semibold' : 'text-lg font-medium'}`}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-faint">{sub}</div>}
    </div>
  )
}

const TONES = {
  ok: 'bg-reef-soft text-reef',
  prep: 'bg-prep-soft text-prep',
  final: 'bg-final-soft text-final',
  closed: 'bg-closed-soft text-closed',
  guarded: 'bg-guarded-soft text-guarded',
  sim: 'bg-sim-soft text-sim',
} as const

export function Badge({ tone, children }: { tone: keyof typeof TONES; children: ReactNode }) {
  return <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold ${TONES[tone]}`}>{children}</span>
}

export function Notice({ tone, children }: { tone: keyof typeof TONES; children: ReactNode }) {
  return <div className={`rounded-xl px-4 py-3 text-sm ${TONES[tone]}`}>{children}</div>
}

export function Button({
  children,
  onClick,
  disabled,
  variant = 'primary',
  title,
}: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  variant?: 'primary' | 'secondary' | 'sim'
  title?: string
}) {
  const styles = {
    primary: 'bg-reef text-white hover:brightness-110',
    secondary: 'border border-line bg-surface text-ink hover:bg-canvas',
    sim: 'border border-sim/30 bg-sim-soft text-sim hover:brightness-95',
  }[variant]
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      disabled={disabled}
      className={`rounded-lg px-3.5 py-2 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-40 ${styles}`}
    >
      {children}
    </button>
  )
}
