import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import { GeistSans } from 'geist/font/sans'
import { GeistMono } from 'geist/font/mono'
import { Providers } from '@/components/Providers'
import { Header } from '@/components/Header'
import { SessionBar } from '@/components/SessionBar'
import './globals.css'

export const metadata: Metadata = {
  title: 'StockReef',
  description: 'Stock markets close. Loans don’t. Pre-close loan management for tokenized stocks on Robinhood Chain.',
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <body className="min-h-screen font-sans antialiased">
        <Providers>
          <Header />
          <SessionBar />
          <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
          <footer className="mx-auto max-w-6xl px-4 pb-10 text-xs text-faint">
            Testnet product. Limits are illustrative fixtures, not calibrated safe values. The demo uses a labelled simulated clock and price.
          </footer>
        </Providers>
      </body>
    </html>
  )
}
