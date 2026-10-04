/**
 * The demo script: everything StockReef's presentation hard-codes, in one file.
 *
 * Hard-coded here:
 *   - one market, TSLA collateral against USDG, and its display identity
 *   - the TSLA price path from 400.00 to the scripted 376.00 reopening price
 *   - the session steps the presenter advances through (Friday 13:00 → Monday 09:45)
 *   - the fixed chart observations that match those prices
 *   - the funded public demo accounts (lib/chain.ts, demoAccounts)
 *
 * Not hard-coded (read from the deployed contracts for the scripted time and price): account and market balances,
 * collateral value and LTV, thresholds, borrow limits, targets and bonuses, trim and buffer amounts, lender book
 * valuation, and every transaction and receipt. See lib/scenario.ts.
 */

export const MARKET = {
  company: 'Tesla, Inc.',
  ticker: 'TSLA',
  pair: 'TSLA / USDG',
  listing: 'Nasdaq · regular session 09:30–16:00 ET',
  collateral: { symbol: 'TSLA', name: 'Tesla stock token', decimals: 18, note: 'Robinhood Chain testnet stock token' },
  loan: { symbol: 'USDG', name: 'Global Dollar', decimals: 6, note: 'Paxos USDG on Robinhood Chain testnet' },
  priceIndex: 'TSLA/USD regular-session price · operator-set demo feed (8 decimals)',
  logo: '/tesla-t.svg',
} as const

export type StepId = 'open' | 'prep' | 'final' | 'closed' | 'wait' | 'admit' | 'credit'

export interface Step {
  id: StepId
  /** Short timeline label. */
  label: string
  /** Which session of the script: the Friday session or the Monday that follows the weekend. */
  day: 'fri' | 'mon'
  /** Minutes after that session's 09:30 open. */
  minute: number
  /** Latest TSLA quote at this step, USD. */
  quote: number
  /** Whether that quote is accepted for valuation. Before admission the last accepted price is used, as indicative. */
  accepted: boolean
  /** One line for the presenter: what the step shows. */
  story: string
}

/**
 * The scripted session. Times are minutes after the session open on the deployment's calendar; the Friday is the
 * first Friday on the chain's calendar whose next open is at least 24 hours later (a weekend closure).
 */
export const STEPS: Step[] = [
  { id: 'open', label: 'Open', day: 'fri', minute: 210, quote: 400.0, accepted: true, story: 'Friday 13:00. Normal limits. The loan sits at 72% LTV against an 80% threshold.' },
  { id: 'prep', label: 'Preparation', day: 'fri', minute: 345, quote: 398.4, accepted: true, story: 'Friday 15:15. The threshold is falling toward the weekend limit. The loan needs to come down before 15:30.' },
  { id: 'final', label: 'Final window', day: 'fri', minute: 360, quote: 397.8, accepted: true, story: 'Friday 15:30. No new borrowing. Last window for the funded buffer or an eligible trim.' },
  { id: 'closed', label: 'Closed', day: 'fri', minute: 390, quote: 397.2, accepted: true, story: 'Friday 16:00. Trading closed. Borrowing and debt-backed withdrawals are locked; repaying and adding collateral still work.' },
  { id: 'wait', label: 'Reopen wait', day: 'mon', minute: 1, quote: 376.0, accepted: false, story: 'Monday 09:31. A fresh 376.00 quote arrives, but nothing price-dependent runs before 09:35.' },
  { id: 'admit', label: 'Price admitted', day: 'mon', minute: 5, quote: 376.0, accepted: true, story: 'Monday 09:35. The fresh price is admitted. Funded buffers, then recovery trims, may run. Borrowing stays closed.' },
  { id: 'credit', label: 'Credit returns', day: 'mon', minute: 15, quote: 377.1, accepted: true, story: 'Monday 09:45. Recovery window complete. New credit returns under the normal limits.' },
]

/** Minute of the scripted Friday session at which the gate admitted its opening price (open + 5 minutes). */
export const FRIDAY_ADMISSION_MINUTE = 5

/**
 * Fixed chart observations, [minutes after open, TSLA USD], matching the step quotes above.
 * Friday 09:30–16:00 every five minutes; Monday 09:31–10:00 every minute.
 */
export const FRIDAY_OBSERVATIONS: readonly (readonly [number, number])[] = [
  [0, 403.1], [5, 403.08], [10, 403.45], [15, 403.82], [20, 403.51], [25, 403.8], [30, 403.81], [35, 404.6], [40, 404.44], [45, 404.6],
  [50, 404.42], [55, 404.05], [60, 403.66], [65, 404.19], [70, 404.09], [75, 403.42], [80, 403.1], [85, 402.99], [90, 402.9], [95, 402.92],
  [100, 403.02], [105, 402.92], [110, 403.63], [115, 403.48], [120, 403.93], [125, 403.91], [130, 403.36], [135, 403.91], [140, 403.78], [145, 404.19],
  [150, 404.2], [155, 403.84], [160, 403.48], [165, 403.11], [170, 402.55], [175, 401.93], [180, 401.58], [185, 402.27], [190, 401.8], [195, 401.27],
  [200, 400.74], [205, 400.43], [210, 400.0], [215, 399.98], [220, 399.8], [225, 399.73], [230, 399.54], [235, 399.55], [240, 399.81], [245, 399.45],
  [250, 399.11], [255, 399.5], [260, 399.23], [265, 399.35], [270, 399.3], [275, 399.14], [280, 398.88], [285, 398.59], [290, 399.43], [295, 398.85],
  [300, 398.31], [305, 398.95], [310, 398.48], [315, 398.62], [320, 398.39], [325, 398.7], [330, 398.55], [335, 398.66], [340, 398.51], [345, 398.4],
  [350, 398.12], [355, 397.95], [360, 397.8], [365, 397.62], [370, 397.48], [375, 397.31], [380, 397.37], [385, 396.86], [390, 397.2],
]

export const MONDAY_OBSERVATIONS: readonly (readonly [number, number])[] = [
  [1, 376], [2, 375.82], [3, 376.21], [4, 375.93], [5, 376], [6, 376.08], [7, 376.45], [8, 376.53], [9, 376.63], [10, 376.85],
  [11, 376.97], [12, 377.07], [13, 377.02], [14, 377.1], [15, 377.1], [16, 377.24], [17, 377.45], [18, 377.28], [19, 377.46], [20, 377.6],
  [21, 377.69], [22, 377.78], [23, 377.6], [24, 377.93], [25, 377.88], [26, 378.16], [27, 378.14], [28, 377.97], [29, 378.14], [30, 378.2],
]

export const stepIndex = (id: StepId) => STEPS.findIndex(s => s.id === id)
