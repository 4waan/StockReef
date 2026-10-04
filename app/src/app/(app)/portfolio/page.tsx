'use client'

import { useSearchParams } from 'next/navigation'
import { GuidedExperience } from '@/components/guided/Experience'
import LivePortfolioPage from '@/components/live/PortfolioPage'

export default function PortfolioPage() {
  const live = useSearchParams().get('live') === '1'
  return live ? <LivePortfolioPage /> : <GuidedExperience view="portfolio" embedded />
}
