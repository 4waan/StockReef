'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { chain } from '@/lib/chain'
import { short } from '@/lib/format'
import { useMarketView } from '@/lib/hooks'
import { Badge } from './ui'

const NAV = [
  { href: '/', label: 'My loan' },
  { href: '/lend', label: 'Lend' },
  { href: '/operations', label: 'Operations' },
  { href: '/evidence', label: 'Evidence' },
]

export function Header() {
  const path = usePathname()
  const { data: m } = useMarketView()
  return (
    <header className="border-b border-line bg-surface">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-3 px-4 py-3">
        <Link href="/" className="flex items-center gap-2">
          <span className="grid h-7 w-7 place-items-center rounded-lg bg-reef text-sm font-bold text-white">S</span>
          <span className="text-base font-semibold">StockReef</span>
        </Link>
        <nav className="flex gap-1">
          {NAV.map(n => (
            <Link
              key={n.href}
              href={n.href}
              className={`rounded-lg px-3 py-1.5 text-sm font-medium ${path === n.href ? 'bg-canvas text-ink' : 'text-muted hover:text-ink'}`}
            >
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          <Badge tone="closed">{chain.name}</Badge>
          {m?.simulationClock && <Badge tone="sim">Simulated clock</Badge>}
          {m?.usesPeg && <Badge tone="sim">Test peg</Badge>}
          <Connect />
        </div>
      </div>
    </header>
  )
}

function Connect() {
  const { address, chainId, isConnected } = useAccount()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChain } = useSwitchChain()
  if (!isConnected) {
    return (
      <button
        type="button"
        disabled={isPending || connectors.length === 0}
        onClick={() => connect({ connector: connectors[0], chainId: chain.id })}
        className="rounded-lg bg-ink px-3.5 py-1.5 text-sm font-semibold text-white disabled:opacity-40"
      >
        {connectors.length === 0 ? 'No wallet found' : 'Connect wallet'}
      </button>
    )
  }
  if (chainId !== chain.id) {
    return (
      <button type="button" onClick={() => switchChain({ chainId: chain.id })} className="rounded-lg bg-final px-3.5 py-1.5 text-sm font-semibold text-white">
        Switch to {chain.name}
      </button>
    )
  }
  return (
    <button type="button" onClick={() => disconnect()} title="Disconnect" className="num rounded-lg border border-line px-3 py-1.5 text-sm">
      {short(address!)}
    </button>
  )
}
