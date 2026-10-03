'use client'

import { createContext, useContext, useState, type ReactNode } from 'react'
import { useSearchParams } from 'next/navigation'
import { isAddress, type Address } from 'viem'
import { useAccount } from 'wagmi'
import { demoAccounts } from './chain'
import { short } from './format'

/**
 * Whose loan the app shows: a scenario picked in the status bar, else ?account= in the URL, else the connected
 * wallet. Shared by every app page so the trading view, the portfolio and the scenario picker agree.
 */
interface Viewing {
  viewing: Address | undefined
  own: boolean
  label: string | undefined
  pick: (a: Address | undefined) => void
}

const Ctx = createContext<Viewing>({ viewing: undefined, own: false, label: undefined, pick: () => {} })

export function ViewingProvider({ children }: { children: ReactNode }) {
  const { address } = useAccount()
  const params = useSearchParams()
  const fromQuery = params.get('account')
  const [picked, pick] = useState<Address>()
  const viewing: Address | undefined = picked ?? (fromQuery && isAddress(fromQuery) ? fromQuery : address ?? demoAccounts[0]?.address)
  const own = !!address && viewing?.toLowerCase() === address.toLowerCase()
  const demo = demoAccounts.find(d => viewing && d.address.toLowerCase() === viewing.toLowerCase())?.label
  const label = demo ?? (viewing ? short(viewing) : undefined)
  return <Ctx.Provider value={{ viewing, own, label, pick }}>{children}</Ctx.Provider>
}

export const useViewing = () => useContext(Ctx)
