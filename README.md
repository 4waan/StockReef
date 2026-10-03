# StockReef

**Stock markets close. Loans don't.**

StockReef is a pre-close loan manager for tokenized stocks on Robinhood Chain. Before each scheduled
market close it:

- tightens the market's published limits on a known schedule;
- repays debt from buffers that borrowers fund in advance;
- lets liquidators partially reduce positions still over the limit, at the current accepted price.

While the market is closed, new borrowing stops. When a fresh regular-session price arrives, recovery
liquidations run before any new credit opens.

> Testnet product built for the Arbitrum Open House Singapore buildathon. All risk parameters are
> illustrative test settings, not calibrated production limits.

## The problem

Tokenized stocks trade around the clock on-chain, but the price that matters comes from a market that
closes every afternoon and for whole weekends. A lending market that values stock collateral with one
threshold all week has two problems:

- **New debt at an unusable price.** Borrowing against a Friday price on a Sunday.
- **Old debt that nobody manages.** A 72% loan that was fine at 15:59 meets Monday's gap with no way to act in between.

Blocking prices during the closure answers the first problem. StockReef is built for the second: **how
much debt should a borrower carry into a closure, and who reduces it before the bell?**

## How a close works

| When (New York) | State | What happens |
|---|---|---|
| Open + 15 min until A = close − 2 h | OPEN | Normal limits: 80% liquidation threshold, 75% borrow limit. Lender deposits and withdrawals open. |
| A to F = close − 30 min | PRE_CLOSE | The threshold falls linearly to the closing level: 70% before weekends and holidays, 77% before an ordinary night. Funded buffers repay toward 65%. Positions above the falling threshold can be trimmed (2% bonus). |
| F to the close | FINAL_WINDOW | No new borrowing. Buffers and trims continue until the bell. |
| Closed | CLOSED | No borrowing, no price-dependent execution. Repay and add collateral at any time. Loans still above the closing threshold are flagged as missed execution, with their exposure. |
| Next open | REOPEN_WAIT, then REOPEN_RECOVERY | A price published after the open is admitted at open + 5 min; a Sunday-evening quote never qualifies. Recovery trims run (5% bonus) for at least 10 minutes before credit returns. |
| Any time | GUARDED | Unusable price, issuer pause, multiplier change, guardian stop or outside the calendar: nothing price-dependent runs. |

The sessions come from a committed NYSE calendar (holidays, early closes and DST), generated with pinned
timezone data and checked on-chain.

## What is built

| Part | Path | Notes |
|---|---|---|
| Contracts | `contracts/src` | SessionCalendar, PriceGate, SessionRiskPolicy, StockReefMarket (ERC-4626 lender shares), RepaymentEscrow, StockReefLens; demo clock and feed for the testnet |
| Tests | `contracts/test` | 535 tests: unit, fuzz and property tests, invariant suites for the market, escrow and gate, regression tests for every audit fix, and a fork suite against Robinhood Chain mainnet |
| Keeper | `ops/keeper` | Refreshes the gate, runs funded buffers, simulates and sends capital-funded trims, reports exposure |
| Web app | `app` | Next.js. My loan, Lend, Operations (with labelled demo controls), Evidence |
| Calendar and golden values | `tools/calendar`, `tools/golden` | Exact rational arithmetic, independent of the Solidity code |
| Scenario harness | `tools/scenarios` | Baselines against gaps, ramps and repeated sessions |
| Specification | `docs/SPEC.md` | The product decisions, with a reconciliation appendix |
| Security notes | `docs/SECURITY.md` | Trust boundaries, permission map, invariants, audit findings and fixes, mutation and Slither results |

## Evidence

Every number below is reproduced by a committed script or test.

- **Worked example** (`tools/golden`). Collateral 10,000 USDG, debt 7,200, Friday close. At 15:15 the threshold is 71.667%, so the loan is eligible. A funded buffer repays 700 USDG to reach 65%. A liquidator instead repays 2,077.15 and takes 2,118.69 of TSLA at a 2% bonus.
- **Scripted demonstration** (`contracts/script/DemoRun.s.sol`, `evidence/demo-31337.json`), at 1/100 scale:
  - A's buffer repays 7.00 USDG at preparation start.
  - B is trimmed by 20.78 USDG at 15:15.
  - C, which nobody touched, is flagged at the close with 7.01 USDG exposed.
  - After a 6% reopening gap, C is recovered and nothing is written off.
- **Scenarios** (`evidence/scenarios.json`). With a 35% weekend gap:
  - lender shortfall is 1,014.91 USDG when nobody acts;
  - 247.78 after a pre-close trim;
  - 314.38 after a funded buffer.

  The liquidator who held trimmed collateral through that gap loses 741.54, and the table shows it. On an unchanged weekend the unmanaged loan pays a 5% recovery bonus at the reopening, where a fixed 80% lender would not act. That is the cost of the policy, shown rather than hidden.
- **Mainnet fork** (`contracts/test/fork`, `evidence/fork-4663.json`). The real TSLA Stock Token, Paxos USDG and Chainlink feeds at a pinned block pass every gate check. Reopening admission works on a live round, and the real tokens move through the market with exact amounts.
- **Gas at the 32-account cap** (`evidence/gas.json`): borrowing about 470k, a lender deposit about 390k.

## Run it locally

Requires Foundry, Python 3.12 and Node 22.

```bash
git clone --recurse-submodules https://github.com/4waan/StockSmart && cd StockSmart

# Contracts and tests
cd contracts && forge build && forge test && cd ..

# A local chain with the full demo
anvil &
cd contracts
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key $(cast wallet private-key --mnemonic "test test test test test test test test test test test junk")
forge script script/DemoRun.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd ..

# Keeper (dry run; add --execute and keys to send)
cd ops/keeper && npm ci && RPC_URL=http://127.0.0.1:8545 npm run keeper -- once && cd ../..

# App
cd app && npm ci && NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545 npm run dev
```

Reproducibility checks:

```bash
python tools/calendar/gen_sessions.py --check
python tools/golden/golden.py --check
python tools/scenarios/run.py --check
```

## Robinhood Chain testnet

The testnet market lends real Paxos USDG against the faucet TSLA Stock Token. Chainlink stock feeds are
mainnet only, so the TSLA price and the clock on testnet are a labelled simulation driven by one demo
operator. To deploy:

1. Fund a deployer with testnet ETH, TSLA (faucet.testnet.chain.robinhood.com) and USDG (faucet.paxos.com).
2. Deploy:
   ```bash
   forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --slow \
     --gas-estimate-multiplier 300 --verify --verifier blockscout \
     --verifier-url https://explorer.testnet.chain.robinhood.com/api/
   ```
3. Open the demo positions with `DemoRun.s.sol`, using the `OPERATOR_KEY`, `ALICE_KEY`, `BOB_KEY`, `CAROL_KEY` and `LIQUIDATOR_KEY` environment variables.
4. Run the keeper in watch mode.
5. Deploy `app/` to Vercel with `NEXT_PUBLIC_CHAIN_ID=46630` after `npm run sync`.

Keys live in environment variables only; nothing secret is committed.

## Limits

- Thresholds, targets and bonuses are illustrative fixtures.
- Execution needs a transaction: the team runs a keeper, and anyone can run buffers or trim with their own capital. Nothing guarantees a buyer for collateral.
- At most 32 borrowers hold debt at once, which keeps the lender valuation bounded and tested.
- Price-dependent actions use regular-session prices only. That is a conservative policy, not a claim that off-hours prices are wrong.
- See `docs/SECURITY.md` for the full list.

## Repository layout

| Path | Contents |
|---|---|
| `contracts/` | Foundry project (Solidity 0.8.28, OpenZeppelin 5.4.0, Solady) |
| `abi/` | Exported contract ABIs |
| `app/` | Web app |
| `ops/keeper/` | Keeper |
| `deployments/` | Manifests and deployed addresses |
| `evidence/` | Outputs of the demo run, scenario harness, fork suite and gas measurement |
| `tools/` | Calendar generator, golden values, scenario harness, ABI export |
| `docs/` | Specification, security notes, pitch, review of the earlier GapGuard concept |
