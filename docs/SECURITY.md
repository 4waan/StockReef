# StockReef security notes

What the contracts trust, who can do what, what was checked, and what is knowingly out of scope. This is a
testnet product: limits are illustrative fixtures and nothing here claims production safety.

## Trust boundaries

| Component | Trusted for | Not trusted for |
|---|---|---|
| Chainlink TSLA/USD and USDG/USD feeds (mainnet) | Answer and timestamp, within the gate's checks: positive, below a per-feed ceiling, timestamped, not from the future, not older than `maxAge`, expected decimals | Session status: the feeds have none, so the calendar decides |
| Demo feed (testnet) | Nothing beyond the same checks; it is a labelled simulation driven by the demo operator | Real prices |
| Stock token issuer | Transfers, the `oraclePaused` flag and ERC-8056 multiplier getters | Overriding transfer restrictions: a frozen transfer reverts the action |
| Session calendar | NYSE regular sessions, holidays and early closes from a committed generator with pinned tzdata | Unscheduled halts (guardian stop) and anything after its last loaded session (wind-down, R17) |
| Keeper | Nothing on-chain: it only submits permissionless transactions | Prices, parameters or balances |

## Who can do what

Every state-changing entry point, grouped by who may call it.

| Contract | Anyone | Restricted |
|---|---|---|
| PriceGate | `refresh` | Guardian (two-step owner): `stop` (immediate), `requestResume`, `resume` (24 h after the request). Ownership cannot be renounced. |
| StockReefMarket | `depositCollateral`, `repay` (for any account), `trim` (with own USDG), ERC-4626 `deposit`/`mint`/`withdraw`/`redeem` and the `…Checked` variants | Borrower only: `borrow`, `withdrawCollateral` (own account) |
| RepaymentEscrow | `deposit` (for any account), `executeBuffer` (no reward) | Owner of the plan: `authorize`, `cancel`, `withdraw`, `ownerRepay` |
| DemoController (testnet only) | none | Demo operator: `step`, `stepTo`, `advance`, `push`, limited to 7-day steps inside calendar coverage |
| SessionCalendar, SessionRiskPolicy, StockReefLens | none (view-only or immutable) | none |

The guardian cannot set prices, thresholds, balances or escrow, cannot forgive debt and cannot change the
calendar. Escrow commitment follows the schedule phase, so a guardian stop or a price outage never freezes
escrowed funds before preparation starts. The demo operator controls the labelled demo clock and price on
the testnet deployment only. `DemoClock` refuses any chain other than 31337 and 46630, and the 1:1 USDG peg
is only accepted on those chains.

## Invariants under test

- **Conservation:** the market's USDG balance equals lender cash; its TSLA balance equals the sum of account collateral; escrow balances add up to its USDG.
- **Debt accounting:** total debt shares equal the sum of account shares; the active set holds exactly the indebted accounts and never more than 32.
- **Action windows:** borrowing only in OPEN or PRE_CLOSE before F; trims only with a usable price and before the close; buffers only in PRE_CLOSE and FINAL_WINDOW; lender entry and exit only in OPEN (or exit-only in wind-down); no collateral leaves in a trim without a matching repayment.
- **Valuation:** lender assets never exceed cash plus debt.
- **Rounding:** borrowing and repaying cannot create profit (fuzzed over amounts and up to 400 days).

The invariant handler drives borrowers, lenders, a keeper and a liquidator across real sessions, crossing
closes with reopening gaps. It logs how many actions succeeded so that an empty run is visible.

## Static analysis (Slither 0.11.6)

Run: `slither contracts --filter-paths "lib/|test/|script/|mocks/" --exclude-dependencies`.
Result: 40 findings, none of high impact. Triage:

| Detector | Count | Finding | Disposition |
|---|---:|---|---|
| reentrancy-no-eth | 0 (was 2) | Escrow wrote balances after `market.repay` | Fixed: repayments are capped at the current debt and balances are updated before the call |
| unused-return | 5 | Ignored round id from `feed.push` (demo); try/catch destructuring of `latestRoundData` | Intended: only the named fields are needed |
| uninitialized-local | 2 | `prev` and `lo` in SessionCalendar start at zero | Intended |
| calls-loop | 18 | Lens and valuation loops call trusted contracts | Bounded by the 32-account cap; gas measured below |
| reentrancy-benign / reentrancy-events | 7 | State written after calls to the trusted gate, policy or demo clock | Trusted, immutable contracts; every state-changing market and escrow entry point is `nonReentrant` |
| missing-zero-check | 2 | Demo operator address | Demo-only; a zero operator only disables the demo controls |
| dead-code | 2 | `_deposit` / `_withdraw` | False positive: ERC-4626 hooks called by OpenZeppelin |
| naming-convention, timestamp, cyclomatic-complexity | 4 | Style; the demo clock compares times by design | Accepted |

## Measured gas at the account cap

From `test_gas_fullCapValuation` (cold storage, 32 indebted accounts), written to `evidence/gas.json`:
borrowing about 470k gas, a lender deposit about 520k, and the full valuation read about 294k.

## Spec compliance

Trail of Bits' spec-to-code-compliance workflow checked 8 mandatory requirements from `docs/SPEC.md`
against `contracts/src`. All 8 hold. Its reverse sweep found four behaviors the documents did not
describe. Each was resolved:

| Finding | Resolution |
|---|---|
| Escrow could be frozen by a guardian stop or price outage | Code changed |
| Lender capital had no exit after the calendar ends | Code changed; documented as R17 |
| Demo clock steps were unbounded | Code changed; documented as R18 |
| Dust debt could hold one of the 32 slots | Code changed; documented as R16 |

Requirements below the run's cut were not checked by that workflow. They are covered by the test suites
listed in the README.

## Known limits

- Thresholds, targets and bonuses are illustrative fixtures, not calibrated against historical gaps.
- A trim needs a liquidator with capital; nothing guarantees one or an exit for the collateral.
- On a quiet open the first post-open feed update can lag (0.5% deviation trigger, 24 h heartbeat). The market waits, then is guarded; it never admits a stale price.
- Chainlink lists no L2 sequencer uptime feed for Robinhood Chain. The gate has an optional slot for one (R14) that is empty today.
- Lender valuation loops over at most 32 accounts; a permissionless, unbounded design is future work.
- No upgrade path: a different policy or an extended calendar is a new deployment.
