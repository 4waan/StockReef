// Stills for the demo and pitch videos: every scripted step of the terminal, portfolio, TSLA and lend pages at
// 1600×900 and 2× pixel density, plus close-ups of the elements the video zooms into (tiles, review, state change,
// oracle). Read-only: it signs nothing, so any public account can be shown.
//
//   npm run dev                                     (in another terminal; or point BASE_URL at the deployed app)
//   npm run capture                                 dark theme into media/stills/dark
//   THEME=light npm run capture                     light theme
//   BASE_URL=https://stock-reef.vercel.app npm run capture
//
// Chromium: PLAYWRIGHT_CHROMIUM (path) or Playwright's installed browser.
import { mkdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { chromium } from 'playwright-core'

const base = process.env.BASE_URL ?? 'http://localhost:3000'
const theme = process.env.THEME === 'light' ? 'light' : 'dark'
const out = resolve(import.meta.dirname, '../../media/stills', theme)
mkdirSync(out, { recursive: true })

const steps = ['open', 'prep', 'final', 'closed', 'wait', 'admit', 'credit']
const pages = [
  { path: '/trade', name: 'trade', zooms: ['Before the close', 'Threshold', 'Funded buffer', 'Liquidation', 'Protection', 'Reopening', 'Last state change'] },
  { path: '/portfolio', name: 'portfolio', zooms: [] },
  { path: '/markets/tsla', name: 'tsla', zooms: [] },
  { path: '/earn', name: 'lend', zooms: [] },
]

const browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM || undefined })
const page = await browser.newPage({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 2 })
await page.addInitScript(t => {
  try {
    localStorage.setItem('reef.theme', t)
  } catch {}
}, theme)

for (const p of pages) {
  for (const step of p.name === 'trade' || p.name === 'portfolio' ? steps : ['prep', 'admit']) {
    await page.goto(`${base}${p.path}?step=${step}`, { waitUntil: 'networkidle' })
    // Contract reads settle within a few polls.
    await page.waitForTimeout(6000)
    const file = `${p.name}-${step}.png`
    await page.screenshot({ path: resolve(out, file) })
    console.log(file)
    for (const label of p.zooms) {
      const el = label === 'Last state change' ? page.getByLabel(label) : page.getByRole('button', { name: label, exact: true })
      if ((await el.count()) === 0) continue
      const z = `${p.name}-${step}-${label.toLowerCase().replaceAll(' ', '-')}.png`
      await el.first().screenshot({ path: resolve(out, z) })
      console.log(`  ${z}`)
    }
  }
}
await browser.close()
