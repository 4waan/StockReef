// StockReef keeper (docs/SPEC.md §8). Operational order on every pass:
//   1. refresh the price gate (records reopening admission and recovery checkpoints)
//   2. execute funded buffers, one independent transaction per account
//   3. re-read positions
//   4. simulate trims, then send the ones that still simulate, with the liquidator's own USDG
//   5. verify receipts and report remaining exposure and missed execution
// It never chooses prices or parameters. Without --execute it only simulates.
//
//   npm run keeper -- once [--execute]
//   npm run keeper -- watch [--execute] [--interval 30]
//   npm run keeper -- feed --price 400 [--interval 60]      (demo deployments: keeps the mock feed fresh)
import { formatUnits, parseUnits, type Address } from 'viem'
import { abis, chainFor, clients, loadAddresses } from './chain.js'
import { decodeReasons, STATES } from './reasons.js'

type Log = { kind: 'attempted' | 'simulated' | 'reverted' | 'mined' | 'target-reached' | 'info'; [k: string]: unknown }

const args = process.argv.slice(2)
const mode = args[0] ?? 'once'
const execute = args.includes('--execute')
const flag = (name: string, fallback: string) => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}

const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545'
const usd = (v: bigint) => formatUnits(v, 6)
const pct = (wad: bigint) => (wad >= 10n ** 30n ? 'inf' : `${(Number(wad) / 1e16).toFixed(2)}%`)

function emit(entry: Log) {
  console.log(JSON.stringify(entry, (_, v) => (typeof v === 'bigint' ? v.toString() : v)))
}

async function main() {
  const probe = clients(rpcUrl, chainFor(31337))
  const chainId = await probe.publicClient.getChainId()
  const chain = chainFor(chainId)
  const addr = loadAddresses(chainId)
  const keeper = clients(rpcUrl, chain, process.env.KEEPER_KEY || undefined)
  const liquidator = clients(rpcUrl, chain, process.env.LIQUIDATOR_KEY || process.env.KEEPER_KEY || undefined)

  if (mode === 'feed') return feed(chain, addr.demoController)
  if (mode === 'once') return pass(keeper, liquidator, addr)
  if (mode === 'watch') {
    const interval = Number(flag('interval', '30')) * 1000
    for (;;) {
      try {
        await pass(keeper, liquidator, addr)
      } catch (error) {
        emit({ kind: 'info', error: String(error) })
      }
      await new Promise(r => setTimeout(r, interval))
    }
  }
  throw new Error(`unknown mode ${mode}`)
}

type Clients = ReturnType<typeof clients>

async function send(
  c: Clients,
  label: string,
  request: { address: Address; abi: typeof abis.market; functionName: string; args: readonly unknown[] },
): Promise<boolean> {
  emit({ kind: 'attempted', action: label })
  const account = c.wallet?.account
  try {
    const sim = await c.publicClient.simulateContract({ ...request, account } as never)
    emit({ kind: 'simulated', action: label, result: (sim as { result: unknown }).result })
    if (!execute || !c.wallet) return false
    const hash = await c.wallet.writeContract((sim as unknown as { request: never }).request)
    const receipt = await c.publicClient.waitForTransactionReceipt({ hash })
    emit({ kind: receipt.status === 'success' ? 'mined' : 'reverted', action: label, tx: hash })
    return receipt.status === 'success'
  } catch (error) {
    emit({ kind: 'reverted', action: label, stage: 'simulation', error: shortError(error) })
    return false
  }
}

async function pass(keeper: Clients, liquidator: Clients, addr: ReturnType<typeof loadAddresses>) {
  // 1. Refresh source status.
  await send(keeper, 'refresh', { address: addr.gate, abi: abis.gate, functionName: 'refresh', args: [] })

  // 2. Funded buffers first, each its own transaction.
  let views = await readViews(keeper, addr)
  for (const v of views) {
    if (v.bufferExecutableNow > 0n) {
      await send(keeper, `buffer ${v.account} (${usd(v.bufferExecutableNow)} USDG)`, {
        address: addr.escrow,
        abi: abis.escrow,
        functionName: 'executeBuffer',
        args: [v.account],
      })
    }
  }

  // 3. Re-read; 4. trims with the liquidator's capital.
  views = await readViews(keeper, addr)
  const market = (await keeper.publicClient.readContract({
    address: addr.lens,
    abi: abis.lens,
    functionName: 'marketView',
  })) as { policy: { time: bigint; state: number; reasons: number } }
  for (const v of views) {
    const q = v.trimNow
    if (!q.eligible || q.bufferPending || q.repaid === 0n) continue
    if (liquidator.wallet && execute) await ensureAllowance(liquidator, addr, q.repaid)
    const minOut = (q.collateralOut * 99n) / 100n
    const deadline = market.policy.time + 300n
    const ok = await send(liquidator, `trim ${v.account} (${usd(q.repaid)} USDG)`, {
      address: addr.market,
      abi: abis.market,
      functionName: 'trim',
      args: [v.account, q.repaid, minOut, deadline],
    })
    if (ok && q.fullFill) emit({ kind: 'target-reached', account: v.account })
  }

  // 5. Report.
  views = await readViews(keeper, addr)
  emit({
    kind: 'info',
    state: STATES[market.policy.state],
    reasons: decodeReasons(market.policy.reasons),
    accounts: views.map(v => ({
      account: v.account,
      debt: usd(v.debt),
      ltv: pct(v.ltvWad),
      repayToTarget: usd(v.repayToTarget),
      missedExecution: v.missedExecution,
      exposure: usd(v.exposure),
    })),
  })
}

interface AccountView {
  account: Address
  debt: bigint
  ltvWad: bigint
  repayToTarget: bigint
  bufferExecutableNow: bigint
  missedExecution: boolean
  exposure: bigint
  trimNow: { eligible: boolean; bufferPending: boolean; repaid: bigint; collateralOut: bigint; fullFill: boolean }
}

async function readViews(c: Clients, addr: ReturnType<typeof loadAddresses>): Promise<AccountView[]> {
  return (await c.publicClient.readContract({
    address: addr.lens,
    abi: abis.lens,
    functionName: 'activeAccountViews',
  })) as AccountView[]
}

async function ensureAllowance(c: Clients, addr: ReturnType<typeof loadAddresses>, amount: bigint) {
  const owner = c.wallet!.account!.address
  const allowance = (await c.publicClient.readContract({
    address: addr.loanToken,
    abi: abis.erc20,
    functionName: 'allowance',
    args: [owner, addr.market],
  })) as bigint
  if (allowance >= amount) return
  const hash = await c.wallet!.writeContract({
    address: addr.loanToken,
    abi: abis.erc20,
    functionName: 'approve',
    args: [addr.market, 2n ** 256n - 1n],
    chain: c.wallet!.chain,
    account: c.wallet!.account!,
  })
  await c.publicClient.waitForTransactionReceipt({ hash })
}

/// Demo deployments only: republish the current simulated price before the mock feed's 120-second maxAge.
async function feed(chain: ReturnType<typeof chainFor>, demo: Address) {
  const operator = clients(rpcUrl, chain, process.env.OPERATOR_KEY || undefined)
  if (!operator.wallet) throw new Error('feed mode needs OPERATOR_KEY (the DemoController operator)')
  const answer = parseUnits(flag('price', '400'), 8)
  const interval = Number(flag('interval', '60')) * 1000
  for (;;) {
    await send(operator, `feed ${formatUnits(answer, 8)}`, {
      address: demo,
      abi: abis.demo,
      functionName: 'push',
      args: [answer],
    })
    if (!execute) return
    await new Promise(r => setTimeout(r, interval))
  }
}

function shortError(error: unknown): string {
  const e = error as { shortMessage?: string; message?: string }
  return (e.shortMessage ?? e.message ?? String(error)).split('\n')[0]
}

main().catch(error => {
  console.error(error)
  process.exit(1)
})
