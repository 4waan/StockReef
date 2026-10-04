'use client'

import { useSearchParams } from 'next/navigation'
import { GuidedExperience } from '@/components/guided/Experience'
import LiveTradePage from '@/components/live/TradePage'

export default function TradePage() {
  const live = useSearchParams().get('live') === '1'
  return live ? <LiveTradePage /> : <GuidedExperience view="trade" embedded />
}
