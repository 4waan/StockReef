// Prepare and drive the chain 46630 testnet (or a local fork of it) along the demo script.
//
//   npx tsx scripts/demo.ts status                 where the testnet clock, price and demo accounts are
//   npx tsx scripts/demo.ts prepare                Friday 13:00 open with a fresh price; borrower reset to 72 USDG debt and a funded 7 USDG plan
//   npx tsx scripts/demo.ts step <id>              move the testnet to a scripted step (prep, final, closed, wait, admit, credit)
//   npx tsx scripts/demo.ts price [--watch]        re-publish the current step's price (every 60 s with --watch)
//   npx tsx scripts/demo.ts run-buffer             execute the borrower's funded buffer (anyone may)
//
// Keys come only from the ignored ../.env.roles file (OPERATOR_KEY, BORROWER_KEY, LIQUIDATOR_KEY), as for
// scripts/seed-market.mjs. With --fork the script sends from the role addresses on a local anvil fork started with
// --auto-impersonate, and needs no keys: RPC_URL defaults to http://127.0.0.1:8545 there.
//
// The script publishes only the scripted prices of lib/script.ts. Everything else is the contracts' own rules.
import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { createPublicClient, createWalletClient, defineChain, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { demoAbi, erc20Abi, escrowAbi, gateAbi, lensAbi, marketAbi } from '../src/generated/abi'
import { STEPS, type StepId } from '../src/lib/script'
import { findAnchor, stepTime, type Anchor } from '../src/lib/scenario'

const args = process.argv.slice(2)
const fork = args.includes('--fork')
const rpc = process.env.RPC_URL ?? (fork ? 'http://127.0.0.1:8545' : 'https://rpc.testnet.chain.robinhood.com')
const chain = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
  contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } },
})
const a = JSON.parse(readFileSync(resolve(import.meta.dirname, '../../deployments/addresses.46630.json'), 'utf8'))
const roles = JSON.parse(readFileSync(resolve(import.meta.dirname, '../../evidence/public-market-46630.json'), 'utf8')).accounts
const client = createPublicClient({ chain, transport: http(rpc) })

type Role = 'operator' | 'borrower' | 'liquidator'
const roleAddress: Record<Role, Address> = { operator: roles.lenderAndOperator, borrower: roles.borrower, liquidator: roles.liquidator }

function keys(): Record<string, string> {
  const file = resolve(import.meta.dirname, '../../.env.roles')
  if (!existsSync(file)) return {}
  return Object.fromEntries(readFileSync(file, 'utf8').trim().split('\n').map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
}

function wallet(role: Role) {
  if (fork) return createWalletClient({ account: roleAddress[role], chain, transport: http(rpc) })
  const k = keys()[`${role.toUpperCase()}_KEY`]
  if (!/^0x[0-9a-fA-F]{64}$/.test(k ?? '')) throw new Error(`Missing ${role.toUpperCase()}_KEY in the ignored .env.roles`)
  return createWalletClient({ account: privateKeyToAccount(k as Hex), chain, transport: http(rpc) })
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function send(role: Role, call: any, label: string) {
  const w = wallet(role)
  await client.simulateContract({ ...call, account: w.account })
  const gas = await client.estimateContractGas({ ...call, account: w.account })
  const hash = await w.writeContract({ ...call, chain, account: w.account, gas: (gas * 13n) / 10n })
  const r = await client.waitForTransactionReceipt({ hash })
  if (r.status !== 'success') throw new Error(`${label} reverted: ${hash}`)
  console.log(`${label.padEnd(34)} ${hash}`)
  return hash
}

const clockAbi = [{ type: 'function', name: 'time', inputs: [], outputs: [{ type: 'uint64' }], stateMutability: 'view' }] as const
const now = async () => client.readContract({ address: a.clock, abi: clockAbi, functionName: 'time' })
const answer = (usd: number) => BigInt(Math.round(usd * 1e8))
const ny = (t: bigint) => new Date(Number(t) * 1000).toLocaleString('en-US', { timeZone: 'America/New_York', weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })

/** The weekend the script runs on: the one in progress (Friday to Monday close) or the next one. */
async function anchor(): Promise<Anchor> {
  const t = await now()
  const back = await findAnchor(client, a.calendar, t - 4n * 86_400n)
  return back.mon.close > t ? back : findAnchor(client, a.calendar, t)
}

async function stepTo(t: bigint, usd: number, label: string) {
  const at = await now()
  if (at > t) throw new Error(`The testnet clock (${ny(at)}) is already past ${ny(t)}; it never moves backwards. Run "prepare" for the next weekend.`)
  await send('operator', { address: a.demoController, abi: demoAbi, functionName: 'stepTo', args: [t, answer(usd)] }, label)
}

async function refresh(label = 'PriceGate.refresh') {
  await send('operator', { address: a.gate, abi: gateAbi, functionName: 'refresh', args: [] }, label)
}

async function status() {
  const an = await anchor()
  const m = await client.readContract({ address: a.lens, abi: lensAbi, functionName: 'marketView' })
  const v = await client.readContract({ address: a.lens, abi: lensAbi, functionName: 'accountView', args: [roleAddress.borrower] })
  console.log(`testnet clock   ${ny(await now())} ET · state ${m.policy.state} · price ${Number(m.valuationPriceWad) / 1e18} ${m.policy.reasons ? `(reasons ${m.policy.reasons})` : '(fresh)'}`)
  console.log(`script weekend  Fri ${ny(an.fri.open)} → Mon ${ny(an.mon.open)} (session ${an.fri.index})`)
  for (const s of STEPS) console.log(`  ${s.id.padEnd(7)} ${ny(stepTime(an, s))}  ${s.quote.toFixed(2)}`)
  console.log(`borrower        debt ${Number(v.debt) / 1e6} · collateral ${Number(v.collateral) / 1e18} TSLA · buffer ${Number(v.plan.balance) / 1e6} USDG, target ${Number(v.plan.targetWad) / 1e16}%, expires ${v.plan.expiry ? ny(v.plan.expiry) : '—'}`)
  console.log(`lender book     cash ${Number(m.cash) / 1e6} · debt ${Number(m.totalDebt) / 1e6} · bad debt ${Number(m.totalBadDebt) / 1e6}`)
}

/** Friday: admit the open at open + 5 minutes (as the script assumes), then 13:00 with a fresh price. */
async function prepare() {
  const open = STEPS.find(s => s.id === 'open')!
  let an = await anchor()
  let t = await now()
  // Within half an hour of Friday 13:00 the testnet is already at the opening step: only refresh the price.
  // Later than that the clock cannot return to it, so the next weekend is used.
  const atOpen = t >= stepTime(an, open) && t <= stepTime(an, open) + 1800n
  if (!atOpen && t > stepTime(an, open)) an = await findAnchor(client, a.calendar, an.mon.close)
  t = await now()
  if (atOpen) {
    await send('operator', { address: a.demoController, abi: demoAbi, functionName: 'push', args: [answer(open.quote)] }, 'Re-publish 400.00')
  } else {
    if (t < an.fri.open + 300n) {
      await stepTo(an.fri.open + 300n, 403.08, 'Friday 09:35: fresh price')
      await refresh('Friday 09:35: admit the reopening')
    }
    await stepTo(stepTime(an, open), open.quote, 'Friday 13:00: open at 400.00')
  }
  await resetBorrower(an)
  await status()
}

/**
 * The funded demo position every take starts from: about 72 USDG of debt on 0.25 TSLA (72% at 400.00) and a 7 USDG
 * buffer authorized toward 65% for 14 days. Tops up what an earlier take used: borrows back to 72 USDG, refunds the
 * escrow, re-authorizes. Approvals are for the exact amount.
 */
async function resetBorrower(an: Anchor) {
  const DEBT = 72_000_000n
  const BUFFER = 7_000_000n
  const borrower = roleAddress.borrower
  let v = await client.readContract({ address: a.lens, abi: lensAbi, functionName: 'accountView', args: [borrower] })
  if (v.debt + 10_000n < DEBT) {
    await send('borrower', { address: a.market, abi: marketAbi, functionName: 'borrow', args: [DEBT - v.debt, borrower] }, `Borrower: borrow back to 72 USDG`)
  }
  if (v.plan.balance < BUFFER) {
    const top = BUFFER - v.plan.balance
    await send('borrower', { address: a.loanToken, abi: erc20Abi, functionName: 'approve', args: [a.escrow, top] }, 'Borrower: approve exact buffer top-up')
    await send('borrower', { address: a.escrow, abi: escrowAbi, functionName: 'deposit', args: [top, borrower] }, 'Borrower: fund buffer to 7 USDG')
  }
  v = await client.readContract({ address: a.lens, abi: lensAbi, functionName: 'accountView', args: [borrower] })
  // The plan must still be active at Monday's recovery; a 14-day authorization from the testnet clock covers it.
  if (v.plan.targetWad === 0n || v.plan.expiry < an.next.open || v.plan.perSessionCap < BUFFER) {
    await send('borrower', { address: a.escrow, abi: escrowAbi, functionName: 'authorize', args: [650000000000000000n, BUFFER, (await now()) + 14n * 86_400n] }, 'Borrower: authorize 65% buffer plan')
  }
}

async function step(id: StepId) {
  const an = await anchor()
  const s = STEPS.find(x => x.id === id)
  if (!s) throw new Error(`Unknown step ${id}; one of ${STEPS.map(x => x.id).join(', ')}`)
  if (id === 'open') return prepare()
  await stepTo(stepTime(an, s), s.quote, `${s.label}: ${s.quote.toFixed(2)}`)
  if (id === 'admit') await refresh('Monday 09:35: admit the fresh price')
  await status()
}

async function price(watch: boolean) {
  const an = await anchor()
  for (;;) {
    const t = await now()
    const cur = [...STEPS].reverse().find(s => stepTime(an, s) <= t) ?? STEPS[0]
    await send('operator', { address: a.demoController, abi: demoAbi, functionName: 'push', args: [answer(cur.quote)] }, `Re-publish ${cur.quote.toFixed(2)} (${cur.label})`)
    if (!watch) return
    await new Promise(r => setTimeout(r, 60_000))
  }
}

async function runBuffer() {
  await send('liquidator', { address: a.escrow, abi: escrowAbi, functionName: 'executeBuffer', args: [roleAddress.borrower] }, 'Execute borrower buffer')
}

const [cmd, arg] = args.filter(x => !x.startsWith('--'))
const run: Record<string, () => Promise<unknown>> = {
  status,
  prepare,
  step: () => step(arg as StepId),
  price: () => price(args.includes('--watch')),
  'run-buffer': runBuffer,
}
if (!run[cmd]) {
  console.log('Usage: npx tsx scripts/demo.ts <status | prepare | step <id> | price [--watch] | run-buffer> [--fork]')
  process.exit(1)
}
await run[cmd]()
