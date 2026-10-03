// Populate the public Robinhood Chain 46630 market with one lender, borrower, and funded repayment plan.
// Keys come only from an ignored local file. No credential is accepted on the command line or written to output.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { createPublicClient, createWalletClient, defineChain, http, parseEther, parseUnits } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { demoAbi, erc20Abi, escrowAbi, gateAbi, lensAbi, marketAbi } from '../src/generated/abi.ts'

const chain = defineChain({
  id: 46630,
  name: 'Robinhood Chain 46630',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
})
const rpc = 'https://rpc.testnet.chain.robinhood.com'
const a = JSON.parse(readFileSync(resolve(import.meta.dirname, '../../deployments/addresses.46630.json'), 'utf8'))
const rows = Object.fromEntries(readFileSync(resolve(import.meta.dirname, '../../.env.roles'), 'utf8').trim().split('\n').map(line => {
  const at = line.indexOf('=')
  return [line.slice(0, at), line.slice(at + 1)]
}))
const key = name => {
  const value = rows[name]
  if (!/^0x[0-9a-fA-F]{64}$/.test(value ?? '')) throw new Error(`Missing valid ${name} in ignored .env.roles`)
  return privateKeyToAccount(value)
}
const operator = key('OPERATOR_KEY')
const borrower = key('BORROWER_KEY')
const liquidator = key('LIQUIDATOR_KEY')
const client = createPublicClient({ chain, transport: http(rpc) })
const wallet = account => createWalletClient({ account, chain, transport: http(rpc) })
const receipts = []
const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args })
async function send(account, address, abi, functionName, args) {
  const call = { account, address, abi, functionName, args, chain }
  await client.simulateContract(call)
  const hash = await wallet(account).writeContract(call)
  const receipt = await client.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted: ${hash}`)
  receipts.push({ action: functionName, from: account.address, hash, block: receipt.blockNumber.toString() })
  console.log(`${functionName}: ${hash}`)
}
async function transferEth(to, amount) {
  const hash = await wallet(operator).sendTransaction({ account: operator, chain, to, value: amount })
  const receipt = await client.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`ETH transfer reverted: ${hash}`)
  receipts.push({ action: 'fund gas', from: operator.address, to, hash, block: receipt.blockNumber.toString() })
  console.log(`fund gas: ${hash}`)
}
const usd = n => parseUnits(String(n), 6)
const tsla = n => parseUnits(String(n), 18)
async function main() {
  if (await client.getChainId() !== 46630) throw new Error('Wrong chain')
  const controllerOperator = await read(a.demoController, demoAbi, 'operator')
  if (operator.address.toLowerCase() !== controllerOperator.toLowerCase()) throw new Error('Operator key does not match deployment')
  const m = await read(a.lens, lensAbi, 'marketView')
  const b = await read(a.lens, lensAbi, 'accountView', [borrower.address])
  if (m.totalAssets !== 0n || b.debt !== 0n) throw new Error('Market or borrower already funded; inspect before adding more')
  const operatorUsdg = await read(a.loanToken, erc20Abi, 'balanceOf', [operator.address])
  const operatorTsla = await read(a.collateralToken, erc20Abi, 'balanceOf', [operator.address])
  if (operatorUsdg < usd(100) || operatorTsla < tsla('0.25')) throw new Error('Operator needs at least 100 USDG and 0.25 TSLA')

  for (const account of [borrower, liquidator]) {
    if (await client.getBalance({ address: account.address }) < parseEther('0.0005')) await transferEth(account.address, parseEther('0.001'))
  }
  await send(operator, a.collateralToken, erc20Abi, 'transfer', [borrower.address, tsla('0.25')])
  await send(operator, a.loanToken, erc20Abi, 'transfer', [liquidator.address, usd(15)])

  // Move the operator-set clock into the next lending window and admit a current 400 USDG stock price.
  const firstOpen = m.policy.nextOpen
  const p = parseUnits('400', 8)
  await send(operator, a.demoController, demoAbi, 'stepTo', [firstOpen + 300n, p])
  await send(operator, a.gate, gateAbi, 'refresh', [])
  await send(operator, a.demoController, demoAbi, 'stepTo', [firstOpen + 900n, p])
  await send(operator, a.gate, gateAbi, 'refresh', [])
  const ready = await read(a.lens, lensAbi, 'marketView')
  if (BigInt(ready.policy.reasons) !== 0n || ready.valuationPriceWad === 0n) throw new Error('Price gate is not ready')

  await send(operator, a.loanToken, erc20Abi, 'approve', [a.market, usd(85)])
  await send(operator, a.market, marketAbi, 'deposit', [usd(85), operator.address])
  await send(borrower, a.collateralToken, erc20Abi, 'approve', [a.market, tsla('0.25')])
  await send(borrower, a.market, marketAbi, 'depositCollateral', [tsla('0.25'), borrower.address])
  await send(borrower, a.market, marketAbi, 'borrow', [usd(72), borrower.address])
  await send(borrower, a.loanToken, erc20Abi, 'approve', [a.escrow, usd(7)])
  await send(borrower, a.escrow, escrowAbi, 'deposit', [usd(7), borrower.address])
  const after = await read(a.lens, lensAbi, 'marketView')
  await send(borrower, a.escrow, escrowAbi, 'authorize', [parseUnits('0.65', 18), usd(7), after.policy.nextOpen + 86400n])
  const final = await read(a.lens, lensAbi, 'accountView', [borrower.address])
  console.log(JSON.stringify({
    chainId: 46630,
    accounts: { borrower: borrower.address, lender: operator.address, liquidator: liquidator.address },
    borrowerDebt: final.debt.toString(),
    borrowerCollateral: final.collateral.toString(),
    bufferBalance: final.plan.balance.toString(),
    receipts,
  }, null, 2))
}
main().catch(e => { console.error(e.shortMessage ?? e.message); process.exitCode = 1 })
