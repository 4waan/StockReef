'use client'

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export const stages = [
  { label: 'Before close', time: 'Fri 15:15 ET', action: 'Show funded repayment' },
  { label: 'Buffer executed', time: 'Fri 15:30 ET', action: 'Close trading' },
  { label: 'Trading closed', time: 'Fri 16:00 ET', action: 'Accept reopening price' },
  { label: 'Reopening recovery', time: 'Mon 09:35 ET', action: 'Finish recovery' },
  { label: 'Credit eligible', time: 'Mon 09:45 ET', action: 'Restart scenario' },
] as const

type Guided = {
  stage: number
  tick: number
  price: number
  debt: number
  collateral: number
  value: number
  ltv: number
  noBufferLtv: number
  vaultCash: number
  setStage: (stage: number) => void
  next: () => void
}

const Context = createContext<Guided | null>(null)

export function GuidedProvider({ children }: { children: ReactNode }) {
  const [stage, setRawStage] = useState(0)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    const id = window.setInterval(() => setTick(t => t + 1), 3000)
    return () => window.clearInterval(id)
  }, [])

  const setStage = (nextStage: number) => {
    setRawStage(Math.max(0, Math.min(stages.length - 1, nextStage)))
    setTick(0)
  }
  const next = () => setStage(stage === stages.length - 1 ? 0 : stage + 1)

  const value = useMemo(() => {
    const basePrice = stage >= 3 ? 370.59 : 400
    const drift = stage === 2 ? 0 : Math.sin(tick * 0.63) * 0.42 + Math.sin(tick * 0.17) * 0.15
    const price = basePrice + drift
    const debt = stage >= 1 ? 65 : 72
    const collateral = 0.25
    const value = collateral * price
    return { price, debt, collateral, value, ltv: debt / value * 100, noBufferLtv: 72 / value * 100, vaultCash: 85 - debt }
  }, [stage, tick])

  return <Context.Provider value={{ stage, tick, ...value, setStage, next }}>{children}</Context.Provider>
}

export function useGuided() {
  const value = useContext(Context)
  if (!value) throw new Error('GuidedProvider is required')
  return value
}
