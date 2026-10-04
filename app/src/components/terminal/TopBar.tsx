'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { chain, demoAccounts } from '@/lib/chain'
import { short } from '@/lib/format'
import { useViewing } from '@/lib/viewing'
import { Logo } from '@/components/brand/Logo'
import { Chevron } from './kit'

const NAV = [
  { label: 'Trade', href: '/trade' },
  { label: 'Earn', href: '/earn' },
  { label: 'Portfolio', href: '/portfolio' },
  { label: 'Operations', href: '/operations' },
  { label: 'Evidence', href: '/evidence' },
] as const

export function TopBar() {
  const path = usePathname()
  return (
    <header className="relative z-30 flex min-w-0 flex-wrap items-center gap-x-5 gap-y-2 border-b border-dk-line px-4 py-2 lg:px-5">
      <Link href="/" className="flex shrink-0 items-center" aria-label="StockReef home">
        <Logo markClassName="h-6 w-auto text-brand" wordClassName="text-xl" />
      </Link>
      <nav className="hidden items-center gap-5 text-sm xl:flex xl:flex-1" aria-label="Main">
        {NAV.map(n => {
          const active = path === n.href || path.startsWith(`${n.href}/`)
          return (
            <Link key={n.href} href={n.href} aria-current={active ? 'page' : undefined} className={`border-b-2 py-1 whitespace-nowrap ${active ? 'border-dk-up text-dk-ink' : 'border-transparent text-dk-muted hover:text-dk-ink'}`}>
              {n.label}
            </Link>
          )
        })}
      </nav>
      <div className="ml-auto flex min-w-0 flex-wrap items-center justify-end gap-2 text-sm lg:gap-4">
        <ProfileMenu />
        <Network />
        <span className="hidden h-6 w-px bg-dk-line sm:block" />
        <Wallet />
        <details className="relative xl:hidden">
          <summary className="flex cursor-pointer list-none items-center rounded-md border border-dk-line px-3 py-2 font-medium">Menu <Chevron /></summary>
          <nav aria-label="Main menu" className="absolute right-0 top-full z-40 mt-2 w-56 rounded-lg border border-dk-line bg-dk-panel p-2 shadow-xl">
            {NAV.map(n => <Link key={n.href} href={n.href} aria-current={path === n.href ? 'page' : undefined} className={`block rounded-md px-4 py-3 ${path === n.href ? 'bg-dk-raised text-dk-up' : 'text-dk-ink hover:bg-dk-raised'}`}>{n.label}</Link>)}
          </nav>
        </details>
      </div>
    </header>
  )
}

function ProfileMenu() {
  const { viewing, label, own, pick } = useViewing()
  return <details className="relative">
    <summary className="flex max-w-48 cursor-pointer list-none items-center gap-1 rounded-md border border-dk-line px-3 py-2 text-dk-ink hover:border-dk-muted" aria-label="Choose public profile">
      <span className="truncate">{own ? 'Your account' : label ?? 'Profiles'}</span><Chevron />
    </summary>
    <div className="absolute right-0 top-full z-40 mt-2 w-72 rounded-lg border border-dk-line bg-dk-panel p-3 shadow-xl">
      <div className="px-2 pb-2 text-xs font-semibold uppercase tracking-wide text-dk-muted">Public accounts</div>
      {demoAccounts.map(d => <button type="button" key={d.address} onClick={() => pick(d.address)} aria-current={viewing?.toLowerCase() === d.address.toLowerCase() ? 'true' : undefined} className="block w-full rounded-md px-3 py-3 text-left hover:bg-dk-raised"><span className="block font-medium text-dk-ink">{d.label}</span><span className="num mt-1 block text-xs text-dk-muted">{short(d.address)} · read-only view</span></button>)}
      {demoAccounts.length === 0 && <p className="px-2 py-3 text-sm text-dk-muted">Profiles will appear after accounts are funded.</p>}
    </div>
  </details>
}

function Network() {
  const { chainId, isConnected } = useAccount()
  const { switchChain } = useSwitchChain()
  const wrong = isConnected && chainId !== chain.id
  if (!wrong) return null
  return (
    <details className="relative">
      <summary className={`flex cursor-pointer list-none items-center gap-1.5 text-[15px] ${wrong ? 'text-dk-down' : ''}`}>
        Wrong network
        <Chevron />
      </summary>
      <div className="absolute right-0 z-20 mt-2 w-64 rounded-md border border-dk-line bg-dk-panel p-3 text-sm shadow-xl">
        <div className="text-dk-muted">This market runs on</div>
        <div className="mt-0.5 font-medium">Robinhood Chain {chain.id}</div>
        <button type="button" onClick={() => switchChain({ chainId: chain.id })} className="mt-3 w-full rounded-md border border-dk-up py-1.5 text-dk-up">
          Switch to Robinhood testnet
        </button>
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
