'use client'

import Link from 'next/link'
import { usePathname, useSearchParams } from 'next/navigation'
import { StatusBar } from './StatusBar'

export function ModeFooter() {
  const path = usePathname()
  const live = useSearchParams().get('live') === '1'
  if (live || path === '/evidence') return <StatusBar />
  return <footer className="border-t border-dk-line px-5 py-4 text-xs text-dk-muted"><div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2"><span>Guided scenario: modeled prices and balances. Wallet connection is real.</span><Link href="/evidence" className="text-dk-up hover:underline">Contract evidence ↗</Link></div></footer>
}
