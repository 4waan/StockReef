import type { NextConfig } from 'next'

const config: NextConfig = {
  reactStrictMode: true,
  // next dev otherwise writes AGENTS.md and CLAUDE.md into app/ on every start.
  agentRules: false,
}

export default config
