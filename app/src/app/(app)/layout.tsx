import { Suspense, type ReactNode } from 'react'
import { ModeFooter } from '@/components/terminal/ModeFooter'
import { TopBar } from '@/components/terminal/TopBar'
import { ViewingProvider } from '@/lib/viewing'

/** The app shell: top bar, the page, and the status bar, around one shared choice of whose loan is shown. */
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="terminal flex min-h-screen flex-col overflow-x-clip bg-dk-bg text-dk-ink">
      <Suspense>
        <ViewingProvider>
          <TopBar />
          <main className="flex flex-1 flex-col">{children}</main>
          <ModeFooter />
        </ViewingProvider>
      </Suspense>
    </div>
  )
}
