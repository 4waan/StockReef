'use client'

import { useEffect, useState } from 'react'

export type Theme = 'dark' | 'light'
const KEY = 'reef.theme'

/** Runs before first paint (root layout): applies the stored theme so the page never flashes the other one. */
export const themeBootScript = `try{var t=localStorage.getItem('${KEY}');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}`

/** The app theme: dark by default, light on request; stored per browser. */
export function useTheme() {
  const [theme, setThemeState] = useState<Theme>('dark')
  useEffect(() => setThemeState(document.documentElement.dataset.theme === 'light' ? 'light' : 'dark'), [])
  const setTheme = (t: Theme) => {
    document.documentElement.dataset.theme = t
    setThemeState(t)
    try {
      localStorage.setItem(KEY, t)
    } catch {
      // Storage may be unavailable; the choice still applies to this page.
    }
  }
  return { theme, setTheme }
}
