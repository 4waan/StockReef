'use client'

import Link from 'next/link'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { chain } from '@/lib/chain'
import { short } from '@/lib/format'
import { Chevron } from './kit'

// Labels as in the mockup. Only one market exists, so Markets and Lend both open the trading view for now.
const NAV = [
  { key: 'markets', label: 'Markets', href: '/trade' },
  { key: 'portfolio', label: 'Portfolio', href: '/' },
  { key: 'lend', label: 'Lend', href: '/trade' },
] as const

export function TopBar({ active, simulation }: { active: (typeof NAV)[number]['key']; simulation: boolean }) {
  return (
    <header className="flex min-h-12 flex-wrap items-stretch gap-y-2 border-b border-dk-line px-5 py-0 max-lg:py-2">
      <Link href="/" className="mr-10 flex items-center text-xl font-bold tracking-tight max-sm:mr-5">
        StockReef
      </Link>
      <nav className="flex items-stretch gap-8 max-sm:gap-4">
        {NAV.map(n => (
          <Link key={n.key} href={n.href} className={`relative flex items-center text-[15px] ${active === n.key ? 'text-dk-ink' : 'text-dk-muted hover:text-dk-ink'}`}>
            {n.label}
            {active === n.key && <span className="absolute inset-x-0 -bottom-px h-0.5 bg-dk-up" />}
          </Link>
        ))}
      </nav>
      <div className="ml-auto flex flex-wrap items-center gap-4 max-sm:gap-3">
        {simulation && <span className="rounded border border-dk-warn px-2.5 py-0.5 text-sm font-medium text-dk-warn">DEMO</span>}
        <Network />
        <span className="h-6 w-px bg-dk-line" />
        <Wallet />
      </div>
    </header>
  )
}

function Network() {
  const { chainId, isConnected } = useAccount()
  const { switchChain } = useSwitchChain()
  const wrong = isConnected && chainId !== chain.id
  return (
    <details className="relative">
      <summary className={`flex cursor-pointer list-none items-center gap-1.5 text-[15px] ${wrong ? 'text-dk-down' : ''}`}>
        {wrong ? 'Wrong network' : chain.name.replace('Chain ', '')}
        <Chevron />
      </summary>
      <div className="absolute right-0 z-20 mt-2 w-64 rounded-md border border-dk-line bg-dk-panel p-3 text-sm shadow-xl">
        <div className="text-dk-muted">This market runs on</div>
        <div className="mt-0.5 font-medium">{chain.name}</div>
        <div className="num text-dk-faint">chain id {chain.id}</div>
        {wrong && (
          <button type="button" onClick={() => switchChain({ chainId: chain.id })} className="mt-3 w-full rounded-md border border-dk-up py-1.5 text-dk-up">
            Switch to {chain.name}
          </button>
        )}
      </div>
    </details>
  )
}

function Wallet() {
  const { address, isConnected } = useAccount()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  if (!isConnected || !address) {
    return (
      <button
        type="button"
        disabled={isPending || connectors.length === 0}
        onClick={() => connect({ connector: connectors[0], chainId: chain.id })}
        className="rounded-md border border-dk-up px-3 py-1 text-[15px] text-dk-up disabled:opacity-40"
      >
        {connectors.length === 0 ? 'No wallet found' : 'Connect wallet'}
      </button>
    )
  }
  const explorer = chain.blockExplorers?.default.url
  return (
    <details className="relative">
      <summary className="flex cursor-pointer list-none items-center gap-2 text-[15px]">
        <WalletIcon />
        <span className="num">{short(address)}</span>
        <Chevron />
      </summary>
      <div className="absolute right-0 z-20 mt-2 w-48 rounded-md border border-dk-line bg-dk-panel py-1 text-sm shadow-xl">
        <button type="button" onClick={() => navigator.clipboard?.writeText(address)} className="block w-full px-3 py-2 text-left hover:bg-dk-raised">
          Copy address
        </button>
        {explorer && (
          <a href={`${explorer}/address/${address}`} target="_blank" rel="noreferrer" className="block px-3 py-2 hover:bg-dk-raised">
            View on explorer
          </a>
        )}
        <button type="button" onClick={() => disconnect()} className="block w-full px-3 py-2 text-left text-dk-down hover:bg-dk-raised">
          Disconnect
        </button>
      </div>
    </details>
  )
}

function WalletIcon() {
  return (
    <svg viewBox="0 0 20 20" className="h-4.5 w-4.5 text-dk-muted" fill="none" stroke="currentColor" strokeWidth="1.5">
      <rect x="2.5" y="4.5" width="15" height="11" rx="2" />
      <path d="M2.5 8h15M13 11.5h1.5" />
    </svg>
  )
}
