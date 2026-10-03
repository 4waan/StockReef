import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import { GeistSans } from 'geist/font/sans'
import { GeistMono } from 'geist/font/mono'
import { Providers } from '@/components/Providers'
import './globals.css'

// Vercel sets VERCEL_PROJECT_PRODUCTION_URL; locally the preview image resolves against localhost.
const site = process.env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : 'http://localhost:3000'

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: 'StockReef',
  description: 'Controlled risk for stock-backed lending. StockReef manages TSLA-backed USDG loans through market closures on Robinhood Chain 46630.',
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <body className="min-h-screen font-sans antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
