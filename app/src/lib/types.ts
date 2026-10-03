import type { useAccountView, useMarketView } from './hooks'

export type MarketData = NonNullable<ReturnType<typeof useMarketView>['data']>
export type Snapshot = MarketData['policy']
export type AccountData = NonNullable<ReturnType<typeof useAccountView>['data']>
