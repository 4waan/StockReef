'use client'

import { useEffect, useState, type ReactNode } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { Logo } from '@/components/brand/Logo'
import { chain, demoAccounts, explorerAddress } from '@/lib/chain'
import { short } from '@/lib/format'
import { useTheme } from '@/lib/theme'
import { useViewing } from '@/lib/viewing'
import { Pop } from './ui'

const NAV: { label: string; href: string; icon: ReactNode }[] = [
  { label: 'Trade', href: '/trade', icon: <path d="M3 17l5-6 4 3 5-7 4 4M3 21h18" /> },
  { label: 'Portfolio', href: '/portfolio', icon: <path d="M12 3a9 9 0 109 9h-9V3zM15 3.5A9 9 0 0120.5 9H15V3.5z" /> },
  { label: 'TSLA', href: '/markets/tsla', icon: <path d="M4 6c5-2 11-2 16 0M12 6v14M8 8.5c2.5-.6 5.5-.6 8 0" /> },
  { label: 'Lend', href: '/earn', icon: <path d="M3 10l9-6 9 6M5 10v8M9.5 10v8M14.5 10v8M19 10v8M3 20h18" /> },
  { label: 'Operations', href: '/operations', icon: <path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M14 4v4M8 10v4M16 16v4" /> },
  { label: 'Evidence', href: '/evidence', icon: <path d="M6 3h9l4 4v14H6zM14 3v5h5M9 13l2 2 4-4" /> },
]

/** False during server render and hydration: wallet state exists only in the browser. */
function useMounted() {
  const [m, setM] = useState(false)
  useEffect(() => setM(true), [])
  return m
}

function Icon({ children, className = 'h-[18px] w-[18px]' }: { children: ReactNode; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {children}
    </svg>
  )
}

/** The app's left column: navigation on top; profile, wallet and theme at the bottom. A drawer on small screens. */
export function Sidebar() {
  const [open, setOpen] = useState(false)
  return (
    <>
      <div className="sticky top-0 z-40 flex items-center gap-3 border-b border-dk-line bg-dk-bg px-4 py-2.5 lg:hidden">
        <Link href="/" aria-label="StockReef home">
          <Logo markClassName="h-6 w-auto text-brand" wordClassName="text-lg" />
        </Link>
        <button type="button" onClick={() => setOpen(true)} aria-label="Open menu" className="ml-auto rounded-md border border-dk-line p-1.5 text-dk-ink">
          <Icon>
            <path d="M4 7h16M4 12h16M4 17h16" />
          </Icon>
        </button>
      </div>
      {open && <div className="fixed inset-0 z-40 bg-black/50 lg:hidden" onClick={() => setOpen(false)} aria-hidden />}
      <aside
        className={`fixed inset-y-0 left-0 z-50 flex w-[212px] flex-col border-r border-dk-line bg-dk-bg transition-transform lg:sticky lg:top-0 lg:z-20 lg:h-screen lg:translate-x-0 ${open ? 'translate-x-0' : '-translate-x-full'}`}
      >
        <Link href="/" className="flex items-center px-4 pt-4 pb-5" aria-label="StockReef home">
          <Logo markClassName="h-6 w-auto text-brand" wordClassName="text-lg" />
        </Link>
        <Nav onNavigate={() => setOpen(false)} />
        <div className="mt-auto space-y-2 border-t border-dk-line p-3">
          <Profile />
          <Wallet />
          <ThemeSwitch />
        </div>
      </aside>
    </>
  )
}

function Nav({ onNavigate }: { onNavigate: () => void }) {
  const path = usePathname()
  return (
    <nav aria-label="Main" className="space-y-0.5 px-2">
      {NAV.map(n => {
        const on = path === n.href || path.startsWith(`${n.href}/`)
        return (
          <Link
            key={n.href}
            href={n.href}
            onClick={onNavigate}
            aria-current={on ? 'page' : undefined}
            className={`flex items-center gap-3 rounded-md px-3 py-2 text-sm ${on ? 'bg-brand/12 font-semibold text-dk-ink' : 'text-dk-muted hover:bg-dk-raised hover:text-dk-ink'}`}
          >
            <span className={on ? 'text-brand' : ''}>
              <Icon>{n.icon}</Icon>
            </span>
            {n.label}
          </Link>
        )
      })}
    </nav>
  )
}

function Row({ children, hint }: { children: ReactNode; hint?: ReactNode }) {
  return (
    <span className="flex items-center justify-between gap-2 rounded-md border border-dk-line px-3 py-2 text-sm text-dk-ink hover:border-dk-muted">
      <span className="truncate">{children}</span>
      {hint && <span className="shrink-0 text-xs text-dk-faint">{hint}</span>}
    </span>
  )
}

/** Whose position the pages show: a public demo account or the connected wallet. */
function Profile() {
  const { viewing, label, own, pick } = useViewing()
  const { address } = useAccount()
  const mounted = useMounted()
  return (
    <Pop label="Choose account" side="right" panelClass="w-64" trigger={<Row hint="view">{!mounted ? 'Account' : own ? 'Your wallet' : (label ?? 'Account')}</Row>}>
      {close => (
        <div className="space-y-0.5">
          <div className="px-2 pb-1 text-[11px] font-semibold tracking-wider text-dk-faint uppercase">View account</div>
          {address && (
            <AccountItem on={own} onClick={() => (pick(address), close())} name="Your wallet" sub={short(address)} />
          )}
          {demoAccounts.map(d => (
            <AccountItem key={d.address} on={viewing?.toLowerCase() === d.address.toLowerCase() && !own} onClick={() => (pick(d.address), close())} name={d.label} sub={`${short(d.address)} · public`} />
          ))}
        </div>
      )}
    </Pop>
  )
}

function AccountItem({ on, onClick, name, sub }: { on: boolean; onClick: () => void; name: string; sub: string }) {
  return (
    <button type="button" onClick={onClick} className={`block w-full rounded-md px-2 py-1.5 text-left ${on ? 'bg-dk-raised' : 'hover:bg-dk-raised'}`}>
      <span className="block text-sm text-dk-ink">{name}</span>
      <span className="num block text-xs text-dk-faint">{sub}</span>
    </button>
  )
}

function Wallet() {
  const { address, isConnected, chainId } = useAccount()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChain } = useSwitchChain()
  const mounted = useMounted()
  if (!mounted || !isConnected || !address)
    return (
      <button
        type="button"
        disabled={isPending || connectors.length === 0}
        onClick={() => connect({ connector: connectors[0], chainId: chain.id })}
        className="w-full rounded-md bg-brand px-3 py-2 text-sm font-semibold text-white hover:bg-[#d36f39] disabled:opacity-40"
      >
        {connectors.length === 0 ? 'Install MetaMask' : 'Connect wallet'}
      </button>
    )
  if (chainId !== chain.id)
    return (
      <button type="button" onClick={() => switchChain({ chainId: chain.id })} className="w-full rounded-md border border-dk-down px-3 py-2 text-sm text-dk-down">
        Switch to chain {chain.id}
      </button>
    )
  return (
    <Pop label="Wallet" side="right" panelClass="w-56" trigger={<Row hint={<span className="h-2 w-2 rounded-full bg-dk-up inline-block" />}><span className="num">{short(address)}</span></Row>}>
      <div className="space-y-1 text-sm">
        <button type="button" onClick={() => navigator.clipboard?.writeText(address)} className="block w-full rounded px-2 py-1.5 text-left hover:bg-dk-raised">
          Copy address
        </button>
        <a href={explorerAddress(address)} target="_blank" rel="noreferrer" className="block rounded px-2 py-1.5 hover:bg-dk-raised">
          View on explorer ↗
        </a>
        <button type="button" onClick={() => disconnect()} className="block w-full rounded px-2 py-1.5 text-left text-dk-down hover:bg-dk-raised">
          Disconnect
        </button>
      </div>
    </Pop>
  )
}

/** Dark and light, both labelled, so the switch reads clearly in either theme. */
function ThemeSwitch() {
  const { theme, setTheme } = useTheme()
  return (
    <div role="radiogroup" aria-label="Theme" className="grid grid-cols-2 rounded-md border border-dk-line bg-dk-raised p-0.5 text-xs">
      {(['dark', 'light'] as const).map(t => (
        <button
          key={t}
          type="button"
          role="radio"
          aria-checked={theme === t}
          onClick={() => setTheme(t)}
          className={`flex items-center justify-center gap-1.5 rounded py-1.5 font-medium ${theme === t ? 'bg-dk-panel text-dk-ink shadow-sm ring-1 ring-dk-line' : 'text-dk-muted hover:text-dk-ink'}`}
        >
          <Icon className="h-3.5 w-3.5">
            {t === 'dark' ? <path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z" /> : <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5" /></>}
          </Icon>
          {t === 'dark' ? 'Dark' : 'Light'}
        </button>
      ))}
    </div>
  )
}
