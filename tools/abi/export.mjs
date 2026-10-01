#!/usr/bin/env node
// Copies contract ABIs from Foundry's build output into abi/, which the keeper and the app import.
// Run after `forge build` in contracts/:  node tools/abi/export.mjs [--check]
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const contracts = [
  ['PriceGate.sol', 'PriceGate'],
  ['SessionRiskPolicy.sol', 'SessionRiskPolicy'],
  ['StockReefMarket.sol', 'StockReefMarket'],
  ['RepaymentEscrow.sol', 'RepaymentEscrow'],
  ['StockReefLens.sol', 'StockReefLens'],
  ['SessionCalendar.sol', 'SessionCalendar'],
  ['DemoController.sol', 'DemoController'],
  ['DemoClock.sol', 'DemoClock'],
  ['MockUSDG.sol', 'MockUSDG'],
  ['MockStockToken.sol', 'MockStockToken'],
]

const check = process.argv.includes('--check')
let stale = false
for (const [file, name] of contracts) {
  const artifact = join(root, 'contracts', 'out', file, `${name}.json`)
  if (!existsSync(artifact)) throw new Error(`missing ${artifact}; run forge build first`)
  const abi = JSON.parse(readFileSync(artifact, 'utf8')).abi
  const out = join(root, 'abi', `${name}.json`)
  const text = JSON.stringify(abi, null, 1) + '\n'
  if (check) {
    if (!existsSync(out) || readFileSync(out, 'utf8') !== text) {
      console.error(`abi/${name}.json is out of date`)
      stale = true
    }
  } else {
    writeFileSync(out, text)
  }
}
if (check && stale) process.exit(1)
console.log(check ? 'abi/ is up to date' : `wrote ${contracts.length} ABIs to abi/`)
