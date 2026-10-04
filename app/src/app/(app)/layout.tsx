import { Suspense, type ReactNode } from 'react'
import { ModeFooter } from '@/components/terminal/ModeFooter'
import { SessionDock } from '@/components/reef/SessionDock'
import { Sidebar } from '@/components/reef/Sidebar'
import { SessionProvider } from '@/lib/session'
import { ViewingProvider } from '@/lib/viewing'

/** The app shell: the left column, then the page with the session bar, around one account choice and one scenario clock. */
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="terminal min-h-screen bg-dk-bg text-dk-ink lg:flex">
      <Suspense>
        <ViewingProvider>
          <SessionProvider>
            <Sidebar />
            <div className="flex min-h-screen min-w-0 flex-1 flex-col overflow-x-clip">
              <main className="flex flex-1 flex-col">{children}</main>
              <SessionDock />
              <ModeFooter />
            </div>
          </SessionProvider>
        </ViewingProvider>
      </Suspense>
    </div>
  )
}
