import { maxUint256, parseAbi, parseUnits, type Address, type PublicClient } from 'viem'
import { escrowAbi, gateAbi, marketAbi, policyAbi } from '@/generated/abi'
import { FRIDAY_ADMISSION_MINUTE, STEPS, type Step, type StepId } from './script'

/**
 * The scripted session, valued by the deployed contracts.
 *
 * The script (lib/script.ts) supplies only a time and a TSLA price for each step. Everything a borrower or lender
 * sees is then read from the contracts at that time and price:
 *   - schedule and closure class: SessionCalendar.sessionAt, SessionRiskPolicy.classOf
 *   - thresholds, borrow limits, targets: SessionRiskPolicy.ltAt / borrowLimit / targetOf / ltFinalOf and constants
 *   - debt: StockReefMarket.debtAt(account, t), from the account's real debt shares
 *   - collateral and its value: StockReefMarket.collateralOf, PriceGate.valueOf at the step's accepted price
 *   - trims: StockReefMarket.quoteTrim(account, snapshot, max)
 *   - funded buffers: RepaymentEscrow.planOf and executableAmount(account, snapshot, debt, value)
 *   - lender book: cash, share supply, written-off debt and every active loan's recoverable value
 *
 * SessionRiskPolicy.evaluate reads reopening admissions from the gate's own record, which only exists for a session
 * the testnet has actually reached. For the scripted sessions, `phaseOf` applies the policy's phase order
 * (_phaseAndLimits / _permissions) with the scripted admission times; the limits inside each phase are still the
 * contract's.
 */

export const WAD = 10n ** 18n
const ROUND_CEIL = 1 // OpenZeppelin Math.Rounding.Ceil

// Mirrors SessionRiskPolicy.State and ClosureClass ordinals.
export const S = { OPEN: 0, PRE_CLOSE: 1, FINAL_WINDOW: 2, CLOSED: 3, REOPEN_WAIT: 4, REOPEN_RECOVERY: 5, GUARDED: 6 } as const
export const CLASS = { OVERNIGHT: 0, EXTENDED: 1 } as const
const STALE = 1 << 4 // Reasons: stock price stale
const FRESH_AFTER = 60n
const ADMIT_AFTER = 300n
const CREDIT_AFTER = 900n
const MIN_RECOVERY = 600n
const GUARD_AFTER = 1800n
const PREP = 7200n
const FINAL = 1800n

export const calendarAbi = parseAbi([
  'function sessionCount() view returns (uint256)',
  'function sessionAt(uint256 i) view returns (uint64 open, uint64 close)',
  'function context(uint64 t) view returns ((bool covered, bool inSession, uint256 index, uint64 open, uint64 close, uint64 prevClose, uint64 nextOpen))',
])

export interface Addresses {
  market: Address
  escrow: Address
  gate: Address
  policy: Address
  calendar: Address
}

export interface Session {
  index: number
  open: bigint
  close: bigint
}

/** The calendar sessions the script runs on: a Friday whose close is followed by a weekend, and the Monday after. */
export interface Anchor {
  prev: Session
  fri: Session
  mon: Session
  next: Session
}

export interface Snapshot {
  time: bigint
  state: number
  phase: number
  closureClass: number
  covered: boolean
  reasons: number
  priceWad: bigint
  priceUpdatedAt: bigint
  session: bigint
  open: bigint
  close: bigint
  prepAt: bigint
  finalAt: bigint
  nextOpen: bigint
  admissionAt: bigint
  creditAt: bigint
  guardAt: bigint
  ltWad: bigint
  borrowLimitWad: bigint
  targetWad: bigint
  canBorrow: boolean
  canTrim: boolean
  canBuffer: boolean
  lenderOpen: boolean
  windDown: boolean
}

export interface Policy {
  ltOpen: bigint
  bOpen: bigint
  targetOpen: bigint
  borrowGap: bigint
  ltFinalOvernight: bigint
  ltFinalExtended: bigint
  targetOvernight: bigint
  targetExtended: bigint
  bonusScheduling: bigint
  bonusDistress: bigint
  closing: number // class of the scripted Friday close
  mondayClosing: number // class of the Monday close
  ltFinal: bigint // ltFinalOf(closing)
  target: bigint // targetOf(closing)
  /** LT on the Friday ramp, every 5 minutes from A to F, from ltAt(closing, t, close). */
  ramp: { t: bigint; lt: bigint; b: bigint }[]
  ratePerSecond: bigint
  utilizationCap: bigint
  maxBufferTarget: bigint
  minLoan: bigint
  maxAccounts: bigint
}

export interface StepState {
  step: Step
  t: bigint
  snapshot: Snapshot
  /** Latest quote at the step (the scripted price), WAD. */
  quoteWad: bigint
  /** Price used for valuation: the quote once accepted, otherwise the last accepted price (indicative). */
  valuationWad: bigint
  indicative: boolean
  /** Closure-plan target: targetOf(the snapshot's closure class), as StockReefLens reports it. */
  planTargetWad: bigint
}

export interface Position {
  account: Address
  collateral: bigint // raw
  debt: bigint // at the step time, base units
  value: bigint // at the valuation price, base units
  ltvWad: bigint
  /** Repayment that reaches the plan target, and the collateral alternative. Zero at or below target. */
  repayToTarget: bigint
  addValueToTarget: bigint
  addRawToTarget: bigint
  /** Trim a liquidator could make now (current step snapshot), from quoteTrim. */
  trimNow: TrimQuote
  /** Trim a liquidator could make at the final window if nothing is done, from quoteTrim at F. */
  trimAtFinal: TrimQuote
  /** Buffer amount executeBuffer would repay now, and at the next window it may run. */
  bufferNow: bigint
  bufferNext: bigint
  bufferNextAt: StepId | undefined
  plan: Plan
  planTargetWad: bigint
  committed: boolean
  /** Debt and status at the close; set from the closed step on. */
  debtAtClose: bigint
  missed: boolean
  exposure: bigint
  wallet: { usdg: bigint; tsla: bigint }
}

export interface TrimQuote {
  eligible: boolean
  bufferPending: boolean
  debt: bigint
  value: bigint
  bonusWad: bigint
  repaid: bigint
  collateralOut: bigint
  fullFill: boolean
}

export interface Plan {
  balance: bigint
  targetWad: bigint
  perSessionCap: bigint
  expiry: bigint
  spentSession: number
  spent: bigint
}

export interface LoanValue {
  account: Address
  debt: bigint
  collateral: bigint
  value: bigint
  recoverable: bigint
}

export interface Book {
  cash: bigint
  totalShares: bigint
  totalBadDebt: bigint
  loans: LoanValue[]
  totalDebt: bigint
  recoverable: bigint
  shortfall: bigint
  lenderAssets: bigint
  /** USDG base units per 1e12 shares (one USDG of initial deposit), with ERC-4626 virtual offsets. */
  shareValue: bigint
  utilizationWad: bigint
}

// ------------------------------------------------------------------ math (mirrors StockReefMath)

export const ceilDiv = (a: bigint, b: bigint) => (a === 0n ? 0n : (a - 1n) / b + 1n)
export const exceeds = (debt: bigint, value: bigint, ratio: bigint) => debt * WAD > ratio * value
export const ltvUp = (debt: bigint, value: bigint) => (debt === 0n ? 0n : value === 0n ? maxUint256 : ceilDiv(debt * WAD, value))
export const repayToReachUp = (debt: bigint, value: bigint, ratio: bigint) => (exceeds(debt, value, ratio) ? ceilDiv(debt * WAD - ratio * value, WAD) : 0n)
export const valueForRatioUp = (debt: bigint, ratio: bigint) => ceilDiv(debt * WAD, ratio)
export const recoverableDown = (debt: bigint, value: bigint, haircut: bigint) => {
  const r = (value * WAD) / (WAD + haircut)
  return r < debt ? r : debt
}
/** Collateral value of `raw` stock units at `priceWad`, base units, rounded down (PriceGate.valueOf for 18 → 6 decimals). */
export const valueOfRaw = (raw: bigint, priceWad: bigint) => (raw * priceWad) / WAD / 10n ** 12n

export const usd = (n: number) => parseUnits(n.toFixed(2), 18)

// ------------------------------------------------------------------ reads

type Call = { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }

/** Many reads in one round trip when the chain has Multicall3, otherwise in parallel. */
export async function readAll<T extends unknown[]>(client: PublicClient, calls: Call[]): Promise<T> {
  if (client.chain?.contracts?.multicall3) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return (await client.multicall({ contracts: calls as any, allowFailure: false })) as T
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (await Promise.all(calls.map(c => client.readContract(c as any)))) as T
}

const nyWeekday = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', weekday: 'short' })

/** The first Friday session closing after `from` whose closure lasts at least 24 hours, with its neighbours. */
export async function findAnchor(client: PublicClient, calendar: Address, from: bigint): Promise<Anchor> {
  const [count, ctx] = await readAll<[bigint, { index: bigint }]>(client, [
    { address: calendar, abi: calendarAbi, functionName: 'sessionCount' },
    { address: calendar, abi: calendarAbi, functionName: 'context', args: [from] },
  ])
  const start = Number(ctx.index)
  const end = Math.min(Number(count) - 2, start + 12)
  const idx = Array.from({ length: end - start + 2 }, (_, k) => Math.max(0, start - 1) + k)
  const rows = await readAll<[bigint, bigint][]>(client, idx.map(i => ({ address: calendar, abi: calendarAbi, functionName: 'sessionAt', args: [BigInt(i)] })))
  const at = (i: number): Session => {
    const r = rows[idx.indexOf(i)]
    return { index: i, open: r[0], close: r[1] }
  }
  for (const i of idx) {
    if (i < 1 || i + 2 > Math.max(...idx)) continue
    const s = at(i)
    if (s.close <= from) continue
    const n = at(i + 1)
    if (nyWeekday.format(new Date(Number(s.open) * 1000)) === 'Fri' && n.open - s.close >= 86_400n) return { prev: at(i - 1), fri: s, mon: n, next: at(i + 2) }
  }
  throw new Error('No Friday session with a weekend closure in the next two weeks of the calendar')
}

export function stepTime(a: Anchor, step: Step): bigint {
  return (step.day === 'fri' ? a.fri.open : a.mon.open) + BigInt(step.minute) * 60n
}

/** Policy limits and constants from the deployed contracts, for the anchor's Friday ramp. */
export async function readPolicy(client: PublicClient, c: Addresses, a: Anchor): Promise<Policy> {
  const p = (functionName: string, args: readonly unknown[] = []) => ({ address: c.policy, abi: policyAbi as readonly unknown[], functionName, args })
  const consts = await readAll<bigint[]>(client, [
    p('LT_OPEN'), p('B_OPEN'), p('TARGET_OPEN'), p('BORROW_GAP'), p('LT_FINAL_OVERNIGHT'), p('LT_FINAL_EXTENDED'),
    p('TARGET_OVERNIGHT'), p('TARGET_EXTENDED'), p('BONUS_SCHEDULING'), p('BONUS_DISTRESS'),
    { address: c.market, abi: marketAbi, functionName: 'RATE_PER_SECOND' },
    { address: c.market, abi: marketAbi, functionName: 'UTILIZATION_CAP' },
    { address: c.escrow, abi: escrowAbi, functionName: 'MAX_TARGET' },
    { address: c.market, abi: marketAbi, functionName: 'minLoan' },
    { address: c.market, abi: marketAbi, functionName: 'MAX_ACCOUNTS' },
  ])
  const [closing, mondayClosing] = await readAll<number[]>(client, [p('classOf', [a.mon.open - a.fri.close]), p('classOf', [a.next.open - a.mon.close])])
  const prepAt = a.fri.close - PREP
  const finalAt = a.fri.close - FINAL
  const times: bigint[] = []
  for (let t = prepAt; t <= finalAt; t += 300n) times.push(t)
  const [ltFinal, target, ...lts] = await readAll<bigint[]>(client, [p('ltFinalOf', [closing]), p('targetOf', [closing]), ...times.map(t => p('ltAt', [closing, t, a.fri.close]))])
  const bs = await readAll<bigint[]>(client, lts.map(lt => p('borrowLimit', [lt])))
  const [ltOpen, bOpen, targetOpen, borrowGap, ltFinalOvernight, ltFinalExtended, targetOvernight, targetExtended, bonusScheduling, bonusDistress, ratePerSecond, utilizationCap, maxBufferTarget, minLoan, maxAccounts] = consts
  return {
    ltOpen, bOpen, targetOpen, borrowGap, ltFinalOvernight, ltFinalExtended, targetOvernight, targetExtended, bonusScheduling, bonusDistress,
    ratePerSecond, utilizationCap, maxBufferTarget, minLoan, maxAccounts,
    closing: Number(closing), mondayClosing: Number(mondayClosing), ltFinal, target,
    ramp: times.map((t, i) => ({ t, lt: lts[i], b: bs[i] })),
  }
}

/** LT on the Friday ramp at `t`, from the contract's ltAt values (the ramp is read at every step time). */
function ltOnRamp(pol: Policy, t: bigint): { lt: bigint; b: bigint } {
  const hit = pol.ramp.find(r => r.t === t)
  if (hit) return { lt: hit.lt, b: hit.b }
  throw new Error(`No contract LT read for ${t}`)
}

/**
 * The policy snapshot at a scripted step: SessionRiskPolicy's phase order with the scripted admissions (Friday
 * admitted at open + 5 minutes; Monday as the step says), and the contract's limits for that phase.
 */
export function phaseOf(a: Anchor, pol: Policy, step: Step): StepState {
  const t = stepTime(a, step)
  const s = step.day === 'fri' ? a.fri : a.mon
  const quoteWad = usd(step.quote)
  const lastFri = STEPS.filter(x => x.day === 'fri' && x.accepted).at(-1)!
  const admit = STEPS.find(x => x.id === 'admit')!
  const prepAt = s.close - PREP
  const finalAt = s.close - FINAL
  const nextOpen = step.day === 'fri' ? a.mon.open : a.next.open
  const closing = step.day === 'fri' ? pol.closing : pol.mondayClosing
  const opening = pol.closing // the closure before Monday's open is the scripted weekend

  let admissionAt = 0n
  if (step.day === 'fri') admissionAt = a.fri.open + BigInt(FRIDAY_ADMISSION_MINUTE) * 60n
  else if (step.accepted) admissionAt = a.mon.open + BigInt(admit.minute) * 60n
  // PriceGate admits only a quote stamped at or after open + 1 minute, at or after open + 5 minutes.
  if (admissionAt && (admissionAt < s.open + ADMIT_AFTER || t < s.open + FRESH_AFTER)) admissionAt = 0n
  const creditAt = admissionAt ? maxBig(s.open + CREDIT_AFTER, admissionAt + MIN_RECOVERY) : 0n

  const snap: Snapshot = {
    time: t, state: 0, phase: 0, closureClass: closing, covered: true, reasons: 0, priceWad: quoteWad, priceUpdatedAt: t,
    session: BigInt(s.index), open: s.open, close: s.close, prepAt, finalAt, nextOpen, admissionAt, creditAt, guardAt: s.open + GUARD_AFTER,
    ltWad: 0n, borrowLimitWad: 0n, targetWad: 0n, canBorrow: false, canTrim: false, canBuffer: false, lenderOpen: false, windDown: false,
  }
  const closedLimits = (c: number) => {
    snap.closureClass = c
    snap.ltWad = c === CLASS.EXTENDED ? pol.ltFinalExtended : pol.ltFinalOvernight
    snap.targetWad = c === CLASS.EXTENDED ? pol.targetExtended : pol.targetOvernight
  }
  if (t >= s.close) {
    snap.phase = S.CLOSED
    closedLimits(closing)
    snap.reasons = STALE
    snap.priceUpdatedAt = s.close
  } else if (admissionAt === 0n) {
    snap.phase = S.REOPEN_WAIT
    closedLimits(opening)
  } else if (t < creditAt) {
    snap.phase = S.REOPEN_RECOVERY
    closedLimits(opening)
  } else if (t < prepAt) {
    snap.phase = S.OPEN
    snap.ltWad = pol.ltOpen
    snap.borrowLimitWad = pol.bOpen
    snap.targetWad = pol.targetOpen
  } else if (t < finalAt) {
    snap.phase = S.PRE_CLOSE
    const r = ltOnRamp(pol, t)
    snap.ltWad = r.lt
    snap.borrowLimitWad = r.b
    snap.targetWad = pol.target
  } else {
    snap.phase = S.FINAL_WINDOW
    closedLimits(closing)
  }
  const st = snap.phase === S.REOPEN_WAIT && t >= snap.guardAt ? S.GUARDED : snap.phase
  snap.state = st
  snap.canBorrow = st === S.OPEN || st === S.PRE_CLOSE
  snap.canTrim = st === S.OPEN || st === S.PRE_CLOSE || st === S.FINAL_WINDOW || st === S.REOPEN_RECOVERY
  snap.canBuffer = st === S.PRE_CLOSE || st === S.FINAL_WINDOW || st === S.REOPEN_RECOVERY
  snap.lenderOpen = st === S.OPEN
  if (!snap.canBorrow) snap.borrowLimitWad = 0n

  const valuationWad = step.accepted ? quoteWad : usd(lastFri.quote)
  const planTargetWad = snap.closureClass === CLASS.EXTENDED ? pol.targetExtended : pol.targetOvernight
  return { step, t, snapshot: snap, quoteWad, valuationWad, indicative: !step.accepted || snap.phase === S.CLOSED, planTargetWad }
}

/** Every scripted step's snapshot; the Friday ramp is read at each step time so step LTs are the contract's. */
export function allSteps(a: Anchor, pol: Policy): StepState[] {
  return STEPS.map(step => phaseOf(a, pol, step))
}

const EMPTY_TRIM: TrimQuote = { eligible: false, bufferPending: false, debt: 0n, value: 0n, bonusWad: 0n, repaid: 0n, collateralOut: 0n, fullFill: false }

/** One account at a step: real balances and plan, valued and quoted by the contracts at the step's time and price. */
export async function readPosition(client: PublicClient, c: Addresses & { loanToken: Address; collateralToken: Address }, account: Address, steps: StepState[], at: number): Promise<Position> {
  const cur = steps[at]
  const final = steps.find(x => x.step.id === 'final')!
  const closed = steps.find(x => x.step.id === 'closed')!
  // The next window in which buffers run, from this step on.
  const next = steps.slice(at).find(x => x.snapshot.canBuffer)
  const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)'])
  const [collateral, debt, plan, committed, usdgW, tslaW, debtFinal, debtClose, debtNext] = await readAll<[bigint, bigint, Plan, boolean, bigint, bigint, bigint, bigint, bigint]>(client, [
    { address: c.market, abi: marketAbi, functionName: 'collateralOf', args: [account] },
    { address: c.market, abi: marketAbi, functionName: 'debtAt', args: [account, cur.t] },
    { address: c.escrow, abi: escrowAbi, functionName: 'planOf', args: [account] },
    { address: c.escrow, abi: escrowAbi, functionName: 'committed', args: [account] },
    { address: c.loanToken, abi: erc20, functionName: 'balanceOf', args: [account] },
    { address: c.collateralToken, abi: erc20, functionName: 'balanceOf', args: [account] },
    { address: c.market, abi: marketAbi, functionName: 'debtAt', args: [account, final.t] },
    { address: c.market, abi: marketAbi, functionName: 'debtAt', args: [account, closed.t] },
    { address: c.market, abi: marketAbi, functionName: 'debtAt', args: [account, (next ?? cur).t] },
  ])
  const [value, valueFinal, valueClose, valueNext] = await readAll<bigint[]>(client, [cur, final, closed, next ?? cur].map(x => ({ address: c.gate, abi: gateAbi, functionName: 'valueOf', args: [collateral, x.valuationWad] })))
  // As StockReefLens: the plan target is the target of the snapshot's closure class (65% before a weekend).
  const target = cur.planTargetWad
  const repayToTarget = repayToReachUp(debt, value, target)
  const addValueToTarget = exceeds(debt, value, target) ? valueForRatioUp(debt, target) - value : 0n
  const calls: Call[] = [
    { address: c.gate, abi: gateAbi, functionName: 'rawForValue', args: [addValueToTarget, cur.valuationWad, ROUND_CEIL] },
    { address: c.escrow, abi: escrowAbi, functionName: 'executableAmount', args: [account, cur.snapshot, debt, value] },
    { address: c.escrow, abi: escrowAbi, functionName: 'executableAmount', args: [account, (next ?? cur).snapshot, debtNext, valueNext] },
  ]
  const trimCalls: Call[] = [
    { address: c.market, abi: marketAbi, functionName: 'quoteTrim', args: [account, cur.snapshot, maxUint256] },
    { address: c.market, abi: marketAbi, functionName: 'quoteTrim', args: [account, final.snapshot, maxUint256] },
  ]
  const [addRaw, bufferNow, bufferNext] = await readAll<bigint[]>(client, calls)
  const [trimNow, trimAtFinal] = debt > 0n ? await readAll<TrimQuote[]>(client, trimCalls) : [EMPTY_TRIM, EMPTY_TRIM]
  // As StockReefLens: in the closure and the reopening wait, a loan still above the closure's LT at the close.
  const inGap = cur.snapshot.phase === S.CLOSED || cur.snapshot.phase === S.REOPEN_WAIT
  const missed = inGap && exceeds(debtClose, valueClose, closed.snapshot.ltWad)
  void valueFinal
  return {
    account, collateral, debt, value, ltvWad: ltvUp(debt, value), planTargetWad: target, repayToTarget, addValueToTarget, addRawToTarget: addValueToTarget ? addRaw : 0n,
    trimNow: cur.snapshot.canTrim ? trimNow : { ...trimNow, eligible: false }, trimAtFinal, bufferNow: cur.snapshot.canBuffer ? bufferNow : 0n,
    bufferNext: next ? bufferNext : 0n, bufferNextAt: next?.step.id, plan, committed, debtAtClose: debtClose, missed,
    exposure: missed ? repayToReachUp(debtClose, valueClose, closed.snapshot.targetWad) : 0n, wallet: { usdg: usdgW, tsla: tslaW },
  }
}

/** The lender book at a step: cash plus each active loan's recoverable value, min(debt, value / (1 + 5%)). */
export async function readBook(client: PublicClient, c: Addresses, step: StepState, haircut: bigint, utilizationCap?: bigint): Promise<Book> {
  const [cash, totalShares, totalBadDebt, accounts] = await readAll<[bigint, bigint, bigint, Address[]]>(client, [
    { address: c.market, abi: marketAbi, functionName: 'cash' },
    { address: c.market, abi: marketAbi, functionName: 'totalSupply' },
    { address: c.market, abi: marketAbi, functionName: 'totalBadDebt' },
    { address: c.market, abi: marketAbi, functionName: 'activeAccounts' },
  ])
  const rows = accounts.length
    ? await readAll<bigint[]>(client, accounts.flatMap(a => [
        { address: c.market, abi: marketAbi, functionName: 'debtAt', args: [a, step.t] },
        { address: c.market, abi: marketAbi, functionName: 'collateralOf', args: [a] },
      ]))
    : []
  const loans: LoanValue[] = accounts.map((account, i) => {
    const debt = rows[2 * i]
    const collateral = rows[2 * i + 1]
    const value = valueOfRaw(collateral, step.valuationWad)
    return { account, debt, collateral, value, recoverable: recoverableDown(debt, value, haircut) }
  })
  return bookFrom(cash, totalShares, totalBadDebt, loans, utilizationCap)
}

export function bookFrom(cash: bigint, totalShares: bigint, totalBadDebt: bigint, loans: LoanValue[], _cap?: bigint): Book {
  const totalDebt = loans.reduce((s, l) => s + l.debt, 0n)
  const recoverable = loans.reduce((s, l) => s + l.recoverable, 0n)
  const lenderAssets = cash + recoverable
  const shareValue = ((lenderAssets + 1n) * 10n ** 12n) / (totalShares + 10n ** 6n)
  const lendable = cash + totalDebt
  return { cash, totalShares, totalBadDebt, loans, totalDebt, recoverable, shortfall: totalDebt - recoverable, lenderAssets, shareValue, utilizationWad: lendable ? (totalDebt * WAD) / lendable : 0n }
}

/** The book revalued at another price (the lender page's what-if), with the same formula. */
export function bookAtPrice(b: Book, priceWad: bigint, haircut: bigint): Book {
  const loans = b.loans.map(l => {
    const value = valueOfRaw(l.collateral, priceWad)
    return { ...l, value, recoverable: recoverableDown(l.debt, value, haircut) }
  })
  return bookFrom(b.cash, b.totalShares, b.totalBadDebt, loans)
}

/**
 * LT of the next closure from a step: before the Friday close, the weekend limit the ramp reaches; during the
 * closure and the Monday reopening, the limit in force; once Monday credit returns, Monday's own close class.
 */
export function nextCloseLt(cur: StepState, pol: Policy): bigint {
  if (cur.snapshot.phase === S.CLOSED || cur.snapshot.phase === S.REOPEN_WAIT || cur.snapshot.phase === S.REOPEN_RECOVERY) return cur.snapshot.ltWad
  const cls = cur.step.day === 'fri' ? pol.closing : pol.mondayClosing
  return cls === CLASS.EXTENDED ? pol.ltFinalExtended : pol.ltFinalOvernight
}

function maxBig(a: bigint, b: bigint) {
  return a > b ? a : b
}
