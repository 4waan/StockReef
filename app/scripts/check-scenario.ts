import { createPublicClient, http, defineChain } from 'viem'
// Checks the scenario engine against the deployed Lens while the chain sits on a scripted step: every policy field,
// value, LTV, plan, trim and buffer amount must be identical.
//   npx tsx scripts/demo.ts step admit --fork && npx tsx scripts/check-scenario.ts admit
import { lensAbi } from '../src/generated/abi'
import { STEPS } from '../src/lib/script'
import { findAnchor, readPolicy, allSteps, readPosition } from '../src/lib/scenario'
const chain = defineChain({ id: 46630, name: 'rh', nativeCurrency: { name: 'E', symbol: 'E', decimals: 18 }, rpcUrls: { default: { http: [process.env.RPC_URL ?? 'http://127.0.0.1:8545'] } }, contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } } })
const client = createPublicClient({ chain, transport: http() }) as any
const c = { market: '0x75459B07b03F3Ea4768073854Ec06AA02DF9264F', escrow: '0xC4aD0B3D7319B35f4Db28099161dd54bD12471dF', gate: '0x1FEfE222c0006a235d706192F8E0efD3933cDE59', policy: '0x7F7B55235CD3E392394b140D36e53EDeb805532e', calendar: '0x1e61C3cC1FBecc2d3c19bFF44403c7Ecd69816D5', loanToken: '0x7E955252E15c84f5768B83c41a71F9eba181802F', collateralToken: '0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E' } as const
const borrower = '0x05802c4E1921b24854D603A46951864ca97b8DAf'
const lens = '0xBfbA1b11b35f65860F6b7B64aeBb310C99a347D0'
const m = await client.readContract({ address: lens, abi: lensAbi, functionName: 'marketView' })
const v = await client.readContract({ address: lens, abi: lensAbi, functionName: 'accountView', args: [borrower] })
const a = await findAnchor(client, c.calendar, m.policy.time - 4n * 86400n)
const pol = await readPolicy(client, c, a)
const steps = allSteps(a, pol)
const i = STEPS.findIndex(x => x.id === process.argv[2])
if (i < 0) throw new Error(`Step one of ${STEPS.map(x => x.id).join(', ')}`)
const st = steps[i]
const p = await readPosition(client, c, borrower, steps, i)
const s = st.snapshot, L = m.policy
const rows: [string, unknown, unknown][] = [
  ['phase', s.phase, L.phase], ['state', s.state, L.state], ['ltWad', s.ltWad, L.ltWad], ['borrowLimit', s.borrowLimitWad, L.borrowLimitWad], ['target', s.targetWad, L.targetWad],
  ['admissionAt', s.admissionAt, L.admissionAt], ['creditAt', s.creditAt, L.creditAt], ['canBorrow', s.canBorrow, L.canBorrow], ['canTrim', s.canTrim, L.canTrim], ['canBuffer', s.canBuffer, L.canBuffer], ['lenderOpen', s.lenderOpen, L.lenderOpen],
  ['value', p.value, v.collateralValue], ['planTarget', p.planTargetWad, v.planTargetWad], ['trimEligible', p.trimNow.eligible, v.trimNow.eligible], ['trimRepaid', p.trimNow.repaid, v.trimNow.repaid], ['bufferNow', p.bufferNow, v.bufferExecutableNow], ['missed', p.missed, v.missedExecution],
  ['debt (script t vs chain t)', p.debt, v.debt], ['ltv', p.ltvWad, v.ltvWad], ['repayToTarget', p.repayToTarget, v.repayToTarget],
]
console.log(`step ${st.step.id}: script t ${st.t} chain t ${L.time}`)
let diff = 0
for (const [k, x, y] of rows) {
  if (String(x) !== String(y)) diff++
  console.log(`${String(x) === String(y) ? 'same' : 'DIFF'}  ${k.padEnd(28)} ${x} | ${y}`)
}
if (L.time !== st.t) console.log('note: the chain is not exactly at the step time, so debt-dependent fields can differ by interest')
process.exit(diff ? 1 : 0)
