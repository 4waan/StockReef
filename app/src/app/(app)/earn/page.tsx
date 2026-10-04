'use client'

import { useSearchParams } from 'next/navigation'
import { GuidedExperience } from '@/components/guided/Experience'
import LiveEarnPage from '@/components/live/EarnPage'

export default function EarnPage() {
  const live = useSearchParams().get('live') === '1'
  return live ? <LiveEarnPage /> : <GuidedExperience view="earn" embedded />
}
