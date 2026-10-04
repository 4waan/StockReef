import { Suspense, type ReactNode } from 'react'
import { ModeFooter } from '@/components/terminal/ModeFooter'
import { SessionDock } from '@/components/reef/SessionDock'
import { SessionProvider } from '@/lib/session'
import { TopBar } from '@/components/terminal/TopBar'
import { ViewingProvider } from '@/lib/viewing'

/** The app shell: top bar, the page, the session bar and the live status bar, around one shared choice of whose loan is shown and one scenario clock. */
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="terminal flex min-h-screen flex-col overflow-x-clip bg-dk-bg text-dk-ink">
      <Suspense>
        <ViewingProvider>
          <SessionProvider>
            <TopBar />
            <main className="flex flex-1 flex-col">{children}</main>
            <SessionDock />
            <ModeFooter />
          </SessionProvider>
        </ViewingProvider>
      </Suspense>
    </div>
  )
}
