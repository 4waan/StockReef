import type { NextConfig } from 'next'

const config: NextConfig = {
  reactStrictMode: true,
  // next dev otherwise writes AGENTS.md and CLAUDE.md into app/ on every start.
  agentRules: false,
  // No dev-mode badge: it overlaps the sidebar's theme switch in screen recordings.
  devIndicators: false,
  // The lender view moved from /lend to /earn; keep old links working.
  async redirects() {
    return [{ source: '/lend', destination: '/earn', permanent: false }]
  },
}

export default config
