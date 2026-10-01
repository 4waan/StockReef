// Mirrors contracts/src/libraries/Reasons.sol. Bit positions are part of the contract interface.
const NAMES = [
  'STOCK_FEED_UNAVAILABLE',
  'STOCK_BAD_ANSWER',
  'STOCK_NO_TIMESTAMP',
  'STOCK_FUTURE_TIMESTAMP',
  'STOCK_STALE',
  'STOCK_DECIMALS_CHANGED',
  'LOAN_FEED_UNAVAILABLE',
  'LOAN_BAD_ANSWER',
  'LOAN_NO_TIMESTAMP',
  'LOAN_FUTURE_TIMESTAMP',
  'LOAN_STALE',
  'LOAN_DECIMALS_CHANGED',
  'ISSUER_PAUSED',
  'PAUSE_FLAG_UNAVAILABLE',
  'MULTIPLIER_LAG',
  'MULTIPLIER_UNAVAILABLE',
  'SEQUENCER_DOWN',
  'SEQUENCER_GRACE',
  'STOPPED',
  'OUTAGE_UNRESOLVED',
  'RECOVERY_GRACE',
] as const

export function decodeReasons(bits: number): string[] {
  return NAMES.filter((_, i) => (bits >> i) & 1)
}

export const STATES = [
  'OPEN',
  'PRE_CLOSE',
  'FINAL_WINDOW',
  'CLOSED',
  'REOPEN_WAIT',
  'REOPEN_RECOVERY',
  'GUARDED',
] as const
