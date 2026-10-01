import { createConfig, http } from 'wagmi'
import { injected } from 'wagmi/connectors'
import { anvil } from 'viem/chains'
import type { Chain, Transport } from 'viem'
import { chain, rpcUrl, robinhoodTestnet } from './chain'

// The configured chain comes first; every read also names it explicitly.
const chains = (chain.id === anvil.id ? [anvil, robinhoodTestnet] : [robinhoodTestnet, anvil]) as unknown as readonly [
  Chain,
  ...Chain[],
]
const transports: Record<number, Transport> = {
  [robinhoodTestnet.id]: http(chain.id === robinhoodTestnet.id ? rpcUrl : undefined),
  [anvil.id]: http(chain.id === anvil.id ? rpcUrl : undefined),
}

export const wagmiConfig = createConfig({ chains, connectors: [injected()], transports, ssr: true })
