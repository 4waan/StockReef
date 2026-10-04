'use client'

import { usePathname } from 'next/navigation'
import { StatusBar } from './StatusBar'

/** Operations and Evidence show the testnet as it is now, with its own clock and price feed. */
export function ModeFooter() {
  const path = usePathname()
  if (path === '/operations' || path === '/evidence') return <StatusBar />
  return null
}
