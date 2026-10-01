import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Abi,
  type Address,
  type Chain,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { anvil } from 'viem/chains'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')

function abi(name: string): Abi {
  return JSON.parse(readFileSync(join(root, 'abi', `${name}.json`), 'utf8')) as Abi
}

export const abis = {
  gate: abi('PriceGate'),
  policy: abi('SessionRiskPolicy'),
  market: abi('StockReefMarket'),
  escrow: abi('RepaymentEscrow'),
  lens: abi('StockReefLens'),
  demo: abi('DemoController'),
  erc20: abi('MockUSDG'),
}

export interface Addresses {
  chainId: number
  gate: Address
  policy: Address
  market: Address
  escrow: Address
  lens: Address
  loanToken: Address
  collateralToken: Address
  demoController: Address
}

export function loadAddresses(chainId: number): Addresses {
  const file = join(root, 'deployments', `addresses.${chainId}.json`)
  return JSON.parse(readFileSync(file, 'utf8')) as Addresses
}

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://explorer.testnet.chain.robinhood.com' } },
})

export function chainFor(id: number): Chain {
  if (id === anvil.id) return anvil
  if (id === robinhoodTestnet.id) return robinhoodTestnet
  throw new Error(`unsupported chain ${id}`)
}

export function clients(rpcUrl: string, chain: Chain, key?: string) {
  const transport = http(rpcUrl)
  const publicClient = createPublicClient({ chain, transport })
  const wallet = key
    ? createWalletClient({ chain, transport, account: privateKeyToAccount(key as Hex) })
    : undefined
  return { publicClient, wallet }
}
