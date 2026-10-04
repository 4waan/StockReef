'use client'

import { createContext, useContext, useEffect, useMemo, useReducer, useState, type ReactNode } from 'react'

export type Phase = 'open' | 'prep' | 'final' | 'closed' | 'wait' | 'recovery' | 'credit'
export type Route = 'setup' | 'buffer' | 'trim' | 'missed'
export type Gate = 'usable' | 'invalid' | 'stopped'
export type ScenarioAction =
  | 'reset' | 'funded' | 'deposit' | 'collateral' | 'borrow' | 'fundBuffer' | 'authorize'
  | 'prepare' | 'finalWindow' | 'buffer' | 'trimRoute' | 'missedRoute' | 'trim' | 'close' | 'reopen'
  | 'invalidPrice' | 'restorePrice' | 'stop' | 'resume' | 'admit' | 'recoveryTrim' | 'credit'
  | 'severeGap' | 'repay' | 'addCollateral'

export type Scenario = {
  phase: Phase
  route: Route
  gate: Gate
  price: number
  acceptedPrice: number
  cash: number
  debt: number
  collateral: number
  buffer: number
  authorized: boolean
  lenderDeposited: number
  liquidatorCash: number
  liquidatorStock: number
  lenderWalletUsdg: number
  borrowerWalletUsdg: number
  borrowerWalletTsla: number
  missed: boolean
  admitted: boolean
  recoveryTrimmed: boolean
  clockOverride: string
  events: string[]
}

export const emptyScenario: Scenario = {
  phase: 'open', route: 'setup', gate: 'usable', price: 400, acceptedPrice: 400,
  cash: 0, debt: 0, collateral: 0, buffer: 0, authorized: false,
  lenderDeposited: 0, liquidatorCash: 15, liquidatorStock: 0,
  lenderWalletUsdg: 85, borrowerWalletUsdg: 0, borrowerWalletTsla: 0.26,
  missed: false, admitted: false, recoveryTrimmed: false, clockOverride: '', events: [],
}

export const fundedScenario: Scenario = {
  ...emptyScenario, cash: 13, debt: 72, collateral: 0.25, buffer: 7,
  authorized: true, lenderDeposited: 85,
  lenderWalletUsdg: 0, borrowerWalletUsdg: 65, borrowerWalletTsla: 0.01,
  events: ['85 USDG deposited', '0.25 TSLA posted', '72 USDG borrowed', '7 USDG buffer funded and authorized'],
}

const record = (s: Scenario, message: string): Scenario => ({ ...s, events: [...s.events, message] })
const collateralValue = (s: Scenario) => s.collateral * s.price
const ltv = (s: Scenario) => collateralValue(s) ? s.debt / collateralValue(s) * 100 : 0

export function reduceGuided(s: Scenario, action: ScenarioAction): Scenario {
  if (action === 'reset') return emptyScenario
  if (action === 'funded') return fundedScenario
  if (action === 'deposit' && s.phase === 'open' && s.lenderDeposited === 0 && s.lenderWalletUsdg >= 85) return record({ ...s, cash: 85, lenderDeposited: 85, lenderWalletUsdg: s.lenderWalletUsdg - 85 }, '85 USDG deposited')
  if (action === 'collateral' && s.phase === 'open' && s.cash === 85 && s.collateral === 0 && s.borrowerWalletTsla >= 0.25) return record({ ...s, collateral: 0.25, borrowerWalletTsla: s.borrowerWalletTsla - 0.25 }, '0.25 TSLA posted')
  if (action === 'borrow' && s.phase === 'open' && s.collateral === 0.25 && s.cash === 85) return record({ ...s, cash: 13, debt: 72, borrowerWalletUsdg: s.borrowerWalletUsdg + 72 }, '72 USDG borrowed')
  if (action === 'fundBuffer' && s.phase === 'open' && s.debt > 0 && s.buffer === 0 && s.borrowerWalletUsdg >= 7) return record({ ...s, buffer: 7, borrowerWalletUsdg: s.borrowerWalletUsdg - 7 }, '7 USDG deposited in borrower escrow')
  if (action === 'authorize' && s.phase === 'open' && s.buffer === 7 && !s.authorized) return record({ ...s, authorized: true }, 'Buffer authorized: 65% target, 7 USDG cap')
  if (action === 'prepare' && s.phase === 'open' && s.debt > 0) return record({ ...s, phase: 'prep' }, 'Preparation began; lender window closed')
  if (action === 'finalWindow' && s.phase === 'prep') return record({ ...s, phase: 'final' }, 'Final 30 minutes: new borrowing stopped')
  if (action === 'buffer' && (s.phase === 'prep' || s.phase === 'final') && s.gate === 'usable' && s.authorized && s.buffer > 0) {
    const amount = Math.min(s.buffer, Math.max(0, s.debt - s.collateral * s.price * 0.65))
    if (!amount) return s
    return record({ ...s, route: 'buffer', debt: s.debt - amount, cash: s.cash + amount, buffer: s.buffer - amount }, `${amount.toFixed(2)} USDG buffer repayment executed`)
  }
  if (action === 'trimRoute') return { ...fundedScenario, phase: 'prep', route: 'trim', buffer: 0, authorized: false, borrowerWalletUsdg: 72, events: [...fundedScenario.events.slice(0, 3), 'Alternate path: no funded buffer'] }
  if (action === 'missedRoute') return { ...fundedScenario, phase: 'prep', route: 'missed', buffer: 0, authorized: false, borrowerWalletUsdg: 72, events: [...fundedScenario.events.slice(0, 3), 'Alternate path: no execution'] }
  if (action === 'trim' && (s.phase === 'prep' || s.phase === 'final') && s.route === 'trim' && s.gate === 'usable' && s.debt > 0 && ltv(s) > (s.phase === 'prep' ? 71.666 : 70)) {
    const repay = Math.min(15, s.liquidatorCash)
    const stock = repay * 1.02 / s.price
    return record({ ...s, debt: s.debt - repay, cash: s.cash + repay, collateral: s.collateral - stock, liquidatorCash: s.liquidatorCash - repay, liquidatorStock: s.liquidatorStock + stock }, `${repay.toFixed(2)} USDG partial trim; ${stock.toFixed(5)} TSLA to liquidator`)
  }
  if (action === 'close' && s.phase === 'final') return record({ ...s, phase: 'closed', missed: s.debt / (s.collateral * s.price) > 0.7 }, 'Trading closed; new credit locked')
  if (action === 'reopen' && s.phase === 'closed') return record({ ...s, phase: 'wait', price: 370.59 }, 'New session; waiting for a fresh accepted price')
  if (action === 'invalidPrice' && (s.phase === 'wait' || s.phase === 'recovery' || s.phase === 'prep' || s.phase === 'final')) return record({ ...s, phase: s.phase === 'recovery' ? 'wait' : s.phase, gate: 'invalid', admitted: false }, 'Stock price rejected; price-dependent actions stopped')
  if (action === 'restorePrice' && s.gate === 'invalid') return record({ ...s, gate: 'usable' }, 'New valid stock price published')
  if (action === 'stop') return record({ ...s, gate: 'stopped', admitted: false }, 'Guardian stopped price-dependent actions')
  if (action === 'resume' && s.gate === 'stopped') return record({ ...s, gate: 'usable', clockOverride: 'Later session after modeled 24-hour wait' }, 'Modeled 24-hour wait and recovery checks completed')
  if (action === 'severeGap' && s.phase === 'wait') return record({ ...s, price: 250 }, 'Illustrative severe gap: TSLA price 250 USDG')
  if (action === 'admit' && s.phase === 'wait' && s.gate === 'usable') return record({ ...s, phase: 'recovery', admitted: true, acceptedPrice: s.price }, s.clockOverride ? 'Fresh price admitted after guardian recovery' : 'Fresh price admitted at 09:35 ET')
  if (action === 'recoveryTrim' && s.phase === 'recovery' && s.gate === 'usable' && !s.recoveryTrimmed && s.liquidatorCash > 0 && ltv(s) > 70) {
    const repay = Math.min(15, s.liquidatorCash, s.debt)
    const stock = Math.min(s.collateral, repay * 1.05 / s.price)
    return record({ ...s, debt: s.debt - repay, cash: s.cash + repay, collateral: s.collateral - stock, liquidatorCash: s.liquidatorCash - repay, liquidatorStock: s.liquidatorStock + stock, recoveryTrimmed: true }, `${repay.toFixed(2)} USDG recovery trim; ${stock.toFixed(5)} TSLA to liquidator`)
  }
  if (action === 'credit' && s.phase === 'recovery' && s.gate === 'usable' && s.admitted) return record({ ...s, phase: 'credit' }, s.clockOverride ? 'Recovery interval completed; credit still subject to book and loan checks' : 'Recovery interval completed at 09:45 ET; credit still subject to book and loan checks')
  if (action === 'repay' && s.debt >= 1 && s.borrowerWalletUsdg >= 1) return record({ ...s, debt: s.debt - 1, cash: s.cash + 1, borrowerWalletUsdg: s.borrowerWalletUsdg - 1 }, '1 USDG manual repayment')
  if (action === 'addCollateral' && s.debt > 0 && s.borrowerWalletTsla >= 0.01) return record({ ...s, collateral: s.collateral + 0.01, borrowerWalletTsla: s.borrowerWalletTsla - 0.01 }, '0.01 TSLA added as collateral')
  return s
}

type Guided = {
  state: Scenario
  tick: number
  send: (action: ScenarioAction) => void
  value: number
  ltv: number
  recoverable: number
  lenderAssets: number
  shareValue: number
  impaired: boolean
  borrowAllowed: boolean
  lenderOpen: boolean
}
const Context = createContext<Guided | null>(null)

export function GuidedProvider({ children }: { children: ReactNode }) {
  const [state, send] = useReducer(reduceGuided, fundedScenario)
  const [tick, setTick] = useState(0)
  useEffect(() => { const id = window.setInterval(() => setTick(t => t + 1), 3000); return () => window.clearInterval(id) }, [])
  const derived = useMemo(() => {
    const value = collateralValue(state)
    const acceptedValue = state.collateral * state.acceptedPrice
    const recoverable = Math.min(state.debt, acceptedValue / 1.05)
    const lenderAssets = state.cash + recoverable
    const impaired = recoverable + 0.000001 < state.debt
    const borrowLimit = state.phase === 'prep' ? 0.66667 : 0.75
    return { value, ltv: ltv(state), recoverable, lenderAssets, shareValue: state.lenderDeposited ? lenderAssets / state.lenderDeposited : 0, impaired, borrowAllowed: (state.phase === 'open' || state.phase === 'prep' || state.phase === 'credit') && state.gate === 'usable' && !impaired && !(state.phase === 'prep' && state.authorized) && state.collateral > 0 && state.cash > 0 && state.debt / Math.max(value, 1) < borrowLimit && state.debt / Math.max(state.debt + state.cash, 1) < 0.9, lenderOpen: (state.phase === 'open' || state.phase === 'credit') && state.gate === 'usable' && !impaired }
  }, [state])
  return <Context.Provider value={{ state, tick, send, ...derived }}>{children}</Context.Provider>
}

export function useGuided() {
  const value = useContext(Context)
  if (!value) throw new Error('GuidedProvider is required')
  return value
}
