// Mirrors SessionRiskPolicy.State and Reasons.sol. Positions are part of the contract interface.
export const STATES = ['OPEN', 'PRE_CLOSE', 'FINAL_WINDOW', 'CLOSED', 'REOPEN_WAIT', 'REOPEN_RECOVERY', 'GUARDED'] as const
export type StateName = (typeof STATES)[number]

export const STATE_COPY: Record<StateName, { label: string; meaning: string; tone: 'ok' | 'prep' | 'final' | 'closed' | 'guarded' }> = {
  OPEN: { label: 'Open', meaning: 'Normal limits. Borrowing and lender windows are available.', tone: 'ok' },
  PRE_CLOSE: { label: 'Preparing for the close', meaning: 'Limits are tightening. Buffers execute; positions above the threshold can be trimmed.', tone: 'prep' },
  FINAL_WINDOW: { label: 'Final window', meaning: 'No new borrowing. Last chance for buffers and trims before the close.', tone: 'final' },
  CLOSED: { label: 'Market closed', meaning: 'No new borrowing and no price-dependent actions. Repay and add collateral any time.', tone: 'closed' },
  REOPEN_WAIT: { label: 'Waiting for a fresh price', meaning: 'Reopened. A regular-session price must arrive before anything price-dependent runs.', tone: 'closed' },
  REOPEN_RECOVERY: { label: 'Reopening recovery', meaning: 'Fresh price admitted. Funded buffers run first, then recovery trims may run; credit returns after the recovery window.', tone: 'final' },
  GUARDED: { label: 'Guarded', meaning: 'Price unusable, guardian stop, or outside the calendar. Repay and add collateral still work.', tone: 'guarded' },
}

const REASONS = [
  'stock feed unavailable',
  'stock answer out of range',
  'stock price has no timestamp',
  'stock price from the future',
  'stock price stale',
  'stock feed decimals changed',
  'USDG feed unavailable',
  'USDG answer out of range',
  'USDG price has no timestamp',
  'USDG price from the future',
  'USDG price stale',
  'USDG feed decimals changed',
  'issuer paused the token',
  'issuer pause flag unavailable',
  'token multiplier changed after the last price',
  'token multiplier unavailable',
  'sequencer down',
  'sequencer restarting',
  'guardian stop',
  'price outage this session',
  'recovery grace',
] as const

export function reasonList(bits: number): string[] {
  return REASONS.filter((_, i) => (bits >> i) & 1)
}

export function stateName(i: number): StateName {
  return STATES[i] ?? 'GUARDED'
}
