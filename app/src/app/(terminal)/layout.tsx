import type { ReactNode } from 'react'

export default function TerminalLayout({ children }: { children: ReactNode }) {
  return <div className="terminal min-h-screen overflow-x-clip bg-dk-bg text-dk-ink">{children}</div>
}
