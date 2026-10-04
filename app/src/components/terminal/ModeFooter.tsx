'use client'

import { usePathname } from 'next/navigation'
import { OraclePill } from '@/components/reef/Oracle'

/** Operations and Evidence show the testnet as it is now: its oracle pill sits at the bottom right. */
export function ModeFooter() {
  const path = usePathname()
  if (path !== '/operations' && path !== '/evidence') return null
  return (
    <div className="sticky bottom-0 z-30 flex justify-end border-t border-dk-line bg-dk-bg/95 px-3 py-1.5 backdrop-blur">
      <OraclePill scripted={false} />
    </div>
  )
}
