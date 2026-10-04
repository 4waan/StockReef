import { defineChain, type Address } from 'viem'
import { anvil } from 'viem/chains'
import { deployments } from '@/generated/deployments'

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://explorer.testnet.chain.robinhood.com' } },
  contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } },
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
  policy: Address
  calendar: Address
  demoController: Address
  loanToken: Address
  collateralToken: Address
  deployBlock: bigint // first deployment block; logs are read from here
}

const raw = deployments[String(chainId)]
export const contracts: Contracts | undefined = raw
  ? {
      lens: raw.lens as Address,
      market: raw.market as Address,
      escrow: raw.escrow as Address,
      gate: raw.gate as Address,
      policy: raw.policy as Address,
      calendar: raw.calendar as Address,
      demoController: raw.demoController as Address,
      loanToken: raw.loanToken as Address,
      collateralToken: raw.collateralToken as Address,
      deployBlock: BigInt(raw.deployBlock ?? 0),
    }
  : undefined

export const ZERO = '0x0000000000000000000000000000000000000000' as Address

export function explorerTx(hash: string): string | undefined {
  const url = chain.blockExplorers?.default.url
  return url ? `${url}/tx/${hash}` : undefined
}

export function explorerAddress(address: string): string | undefined {
  const url = chain.blockExplorers?.default.url
  return url ? `${url}/address/${address}` : undefined
}

/** Public role accounts. Override with NEXT_PUBLIC_DEMO_ACCOUNTS="Borrower:0x..,Lender:0x..". */
const configuredDemoAccounts: { label: string; address: Address }[] = (process.env.NEXT_PUBLIC_DEMO_ACCOUNTS ?? '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean)
  .map(s => {
    const [label, address] = s.split(':')
    return { label, address: address as Address }
  })

// Public, read-only accounts. Balances and positions are fetched from the chain.
export const demoAccounts = configuredDemoAccounts.length
  ? configuredDemoAccounts
  : chainId === robinhoodTestnet.id
    ? [
        { label: 'Borrower', address: '0x05802c4E1921b24854D603A46951864ca97b8DAf' as Address },
        { label: 'Lender', address: '0x8A60820Ebbf9643F7b0B560a2FE6AFE666c2A87a' as Address },
        { label: 'Liquidator', address: '0xD41ECc5dd9993B0F67d15dCD0916E73E03bEaA67' as Address },
      ]
    : []
