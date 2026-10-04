'use client'

import { useSearchParams } from 'next/navigation'
import { GuidedExperience } from '@/components/guided/Experience'
import LiveOperationsPage from '@/components/live/OperationsPage'

export default function OperationsPage() {
  const live = useSearchParams().get('live') === '1'
  return live ? <LiveOperationsPage /> : <GuidedExperience view="operations" embedded />
}
