import { defineChain, type Address } from 'viem'
import { anvil } from 'viem/chains'
import { deployments } from '@/generated/deployments'

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://explorer.testnet.chain.robinhood.com' } },
  testnet: true,
})

export const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? robinhoodTestnet.id)
export const chain = chainId === anvil.id ? anvil : robinhoodTestnet
export const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL ?? chain.rpcUrls.default.http[0]

export interface Contracts {
  lens: Address
  market: Address
  escrow: Address
  gate: Address
  demoController: Address
  loanToken: Address
  collateralToken: Address
}

const raw = deployments[String(chainId)]
export const contracts: Contracts | undefined = raw
  ? {
      lens: raw.lens as Address,
      market: raw.market as Address,
      escrow: raw.escrow as Address,
      gate: raw.gate as Address,
      demoController: raw.demoController as Address,
      loanToken: raw.loanToken as Address,
      collateralToken: raw.collateralToken as Address,
    }
  : undefined

export const ZERO = '0x0000000000000000000000000000000000000000' as Address

export function explorerTx(hash: string): string | undefined {
  const url = chain.blockExplorers?.default.url
  return url ? `${url}/tx/${hash}` : undefined
}

/** Seeded demo accounts, labelled for quick viewing: NEXT_PUBLIC_DEMO_ACCOUNTS="A:0x..,B:0x..". */
export const demoAccounts: { label: string; address: Address }[] = (process.env.NEXT_PUBLIC_DEMO_ACCOUNTS ?? '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean)
  .map(s => {
    const [label, address] = s.split(':')
    return { label, address: address as Address }
  })
