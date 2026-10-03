import type { ReactNode } from 'react'
import { Header } from '@/components/Header'
import { SessionBar } from '@/components/SessionBar'

export default function ClassicLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <Header />
      <SessionBar />
      <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
      <footer className="mx-auto max-w-6xl px-4 pb-10 text-xs text-faint">
        Testnet product. Limits are illustrative fixtures, not calibrated safe values. The demo uses a labelled simulated clock and price.
      </footer>
    </>
  )
}
