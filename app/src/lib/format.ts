import { formatUnits } from 'viem'

const WAD = 10n ** 18n

/** Loan-token base units (6 decimals) as USDG with two decimals. */
export function usdg(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return '—'
  const n = Number(formatUnits(v, 6))
  return n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

/** Raw 18-decimal token units as a token amount. */
export function tokens(v: bigint | undefined, digits = 4): string {
  if (v === undefined) return '—'
  const n = Number(formatUnits(v, 18))
  return n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

/** WAD ratio as a percentage. */
export function pct(v: bigint | undefined, digits = 2): string {
  if (v === undefined) return '—'
  if (v >= 10n ** 30n) return '∞'
  return `${(Number((v * 10000n) / WAD) / 100).toFixed(digits)}%`
}

/** WAD price (loan units per token) as a USDG price. */
export function price(v: bigint | undefined): string {
  if (v === undefined || v === 0n) return '—'
  return Number(formatUnits(v, 18)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export function short(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

const ny = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York',
  weekday: 'short',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
})
const local = new Intl.DateTimeFormat(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false })

/** A protocol time (UTC seconds) in New York time, e.g. "Fri 15:30". */
export function nyTime(t: bigint | number | undefined): string {
  if (t === undefined || Number(t) === 0) return '—'
  return ny.format(new Date(Number(t) * 1000))
}

export function localTime(t: bigint | number | undefined): string {
  if (t === undefined || Number(t) === 0) return '—'
  return local.format(new Date(Number(t) * 1000))
}

/** A duration in seconds as "2h 05m" or "4m 10s". */
export function duration(seconds: bigint | number): string {
  let s = Math.max(0, Number(seconds))
  const d = Math.floor(s / 86400)
  s -= d * 86400
  const h = Math.floor(s / 3600)
  s -= h * 3600
  const m = Math.floor(s / 60)
  const sec = Math.floor(s - m * 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m`
  return `${m}m ${String(sec).padStart(2, '0')}s`
}

const nyClockFmt = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hour12: false })
const nyClockSecFmt = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })

/** A protocol time as a New York wall clock, "14:32" or "14:30:08". */
export function nyClock(t: bigint | number | undefined, seconds = false): string {
  if (t === undefined || Number(t) === 0) return '—'
  return (seconds ? nyClockSecFmt : nyClockFmt).format(new Date(Number(t) * 1000))
}

/** A countdown as "01:28" (hours:minutes), or "3d 04h" beyond a day. */
export function hhmm(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  if (d > 0) return `${d}d ${String(h).padStart(2, '0')}h`
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`
}

/** A fraction (0.65) as a percentage ("65.0%"). */
export function pctOf(f: number | undefined, digits = 1): string {
  if (f === undefined || !Number.isFinite(f)) return '—'
  return `${(f * 100).toFixed(digits)}%`
}

/** A WAD ratio as a fraction. */
export function frac(v: bigint): number {
  return Number(v) / 1e18
}
