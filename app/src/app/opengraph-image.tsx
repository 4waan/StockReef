import { ImageResponse } from 'next/og'
import { MARK_PATH, MARK_VIEWBOX } from '@/components/brand/Logo'

export const alt = 'StockReef: controlled risk for stock-backed lending on Robinhood Chain 46630.'
export const size = { width: 1200, height: 630 }
export const contentType = 'image/png'

export default function OpenGraphImage() {
  return new ImageResponse(
    (
      <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', justifyContent: 'center', padding: 80, background: '#2c2e32', color: '#fcfbf4' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 28 }}>
          <svg viewBox={MARK_VIEWBOX} width={150} height={130}>
            <path d={MARK_PATH} fill="#c56430" />
          </svg>
          <div style={{ fontSize: 110, fontWeight: 800, letterSpacing: -3 }}>StockReef</div>
        </div>
        <div style={{ marginTop: 48, fontSize: 48, fontWeight: 700 }}>Controlled risk for stock-backed lending.</div>
        <div style={{ marginTop: 16, fontSize: 30, color: '#b9b6ab' }}>TSLA-backed USDG loans on Robinhood Chain 46630.</div>
      </div>
    ),
    size,
  )
}
