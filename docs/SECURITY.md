# StockReef security notes

What the contracts trust, who can do what, what was checked, and what is knowingly out of scope. This is a
testnet product: limits are illustrative fixtures and nothing here claims production safety.

## Trust boundaries

| Component | Trusted for | Not trusted for |
|---|---|---|
| Chainlink TSLA/USD and USDG/USD feeds (mainnet) | Answer and timestamp, within the gate's checks: positive, below a per-feed ceiling and a price ceiling, timestamped, not from the future, not older than `maxAge`, expected decimals | Session status: the feeds have none, so the calendar decides |
| Demo feed (testnet) | Nothing beyond the same checks; it is a labelled simulation driven by the demo operator | Real prices |
| Stock token issuer | Transfers, the `oraclePaused` flag and ERC-8056 multiplier getters | Overriding transfer restrictions: a frozen transfer reverts the action |
| USDG issuer (Paxos) | Transfers of the loan token | Freezes or an upgrade of USDG can block repayment, buffers, trims and lender exits; balances are checked by delta, so a short transfer reverts |
| Session calendar | NYSE regular sessions, holidays and early closes from a committed generator with pinned tzdata | Unscheduled halts (guardian stop) and anything after its last loaded session (wind-down, R17, R19) |
| Keeper | Nothing on-chain: it only submits permissionless transactions | Prices, parameters or balances |

## Who can do what

Every state-changing entry point, grouped by who may call it.

| Contract | Anyone | Restricted |
|---|---|---|
| PriceGate | `refresh` | Guardian (two-step owner): `stop` (immediate), `requestResume`, `resume` (24 h after the request), `transferOwnership`; the pending owner: `acceptOwnership`. Ownership cannot be renounced. |
| StockReefMarket | `depositCollateral` (for any non-zero account), `repay` (for any account), `trim` (with own USDG), ERC-4626 `deposit`/`mint`/`withdraw`/`redeem` and the `…Checked` variants; lender-share `transfer`, `approve`, `transferFrom` (plain ERC-20) | Borrower only: `borrow`, `withdrawCollateral` (own account) |
| RepaymentEscrow | `deposit` (for any non-zero account), `executeBuffer` (no reward) | Owner of the plan: `authorize`, `cancel`, `withdraw`, `ownerRepay` (up to an amount; the largest amount means all) |
| DemoController (testnet only) | none | Demo operator: `step`, `stepTo`, `advance`, `push`, limited to 7-day steps inside calendar coverage |
| Mock tokens (local chain and testnet only) | none | Their issuer: `mint`, freeze, pause flag and multiplier setters. `Deploy.s.sol` refuses to deploy them on any other chain (R22). |
| SessionCalendar, SessionRiskPolicy, StockReefLens | none (view-only or immutable) | none |

The guardian cannot set prices, thresholds, balances or escrow, cannot forgive debt and cannot change the
calendar. Escrow commitment follows the schedule phase, so a guardian stop or a price outage never freezes
escrowed funds before preparation starts. In wind-down, lender exits are paid from idle cash only, so a stop
does not change what an exit pays (R19). The demo operator controls the labelled demo clock and price on the
testnet deployment only. `DemoClock` refuses any chain other than 31337 and 46630, and the 1:1 USDG peg is only
accepted on those chains.

Every market and escrow function that moves tokens holds the contract's reentrancy lock (OpenZeppelin's
transient-storage guard). The `…Checked` wrappers delegate to locked functions; escrow `authorize` and `cancel`
write only the caller's own plan and make static calls only; share transfers are plain ERC-20. Every call the
gate makes to a feed, token flag, clock or calendar is a static call.

## Invariants under test

The audit listed 224 invariants across the gate, policy, calendar, market, escrow, lens and demo contracts; each
is covered by a unit, fuzz, property or invariant test, or recorded as out of scope. The main ones:

- **Conservation:** the market's USDG balance is at least lender cash and its TSLA balance at least the sum of account collateral (equal unless tokens are sent to it directly); the escrow holds at least the sum of plan balances, and USDG leaves it only to the plan owner's receiver or into the market for that owner's debt.
- **Debt accounting:** total debt shares equal the sum of account shares; the active set holds exactly the indebted accounts and never more than 32.
- **Action windows:** borrowing only in OPEN or PRE_CLOSE before F, and never in the last covered session (R19); trims only with a usable price and before the close or in reopening recovery; buffers only in PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY (R20); lender entry only in OPEN with an unimpaired book (R21), exits in OPEN or in wind-down; no collateral leaves in a trim without a matching repayment.
- **Valuation:** lender assets never exceed cash plus debt, and are cash only in wind-down (R19).
- **Gate:** every refresh and guardian call matches a reference model of admission, outage, checkpoint and grace; reason bits keep their positions; no answer, however large, makes a read revert (R22).
- **Calendar:** lookups match a linear scan over every committed session and over arbitrary calendars.
- **Rounding:** borrowing and repaying cannot create profit (fuzzed over amounts and up to 400 days).

Suites: `test/unit` (one per contract plus `AuditFixes.t.sol`, the regression tests for the fixes below),
`test/properties` (calendar, gate arithmetic, policy model, lens, market accounting, ERC-4626 properties) and
`test/invariant` (market, escrow, gate). Each invariant handler logs how many actions succeeded, so an empty
run is visible.

## Audit

A full review of the contracts covered invariants, arithmetic bounds (gate overflow, calendar integers),
escrow fund flows, cross-contract ordering and good practice against audited references (Morpho Blue,
Euler, Aave v3, Compound III, the a16z ERC-4626 properties). Every finding was reproduced by a proof-of-concept
test before being counted. None was critical or high. The fixes keep the decision spec and are recorded in its
appendix (R16, R19 to R22); a separate read-only review confirmed that every core line of the spec still holds.

| Finding | Severity | Outcome |
|---|---|---|
| The last covered close used the mild OVERNIGHT class, and loans open in wind-down could never be liquidated | Medium | Fixed: that close is EXTENDED and gives no new credit (R19) |
| Wind-down counted uncollectable collateral in lender assets, so the first exiter took more | Medium | Fixed: wind-down lender assets are idle cash only (R19) |
| A liquidator earns 5% by waiting until the reopening instead of 2% before the close | Medium | Kept as specified (§3, §6 recovery bonus); a funded buffer now runs first in recovery too (R20) |
| Loan-feed heartbeat jitter recorded as an outage | Low | Fixed: mainnet `maxAge` is the heartbeat plus one hour (R22) |
| Unvalidated decimals and answer bounds could overflow or price at zero | Low | Fixed: decimals at most 18, loan bound keeps the price at least one wei, prices above 10^36 are bad answers (R22) |
| The Lens showed buffer coverage and hid missed execution in wind-down | Low | Fixed in the Lens |
| Buffer funds committed through closure and recovery without any execution window | Low | Narrowed: buffers now execute in reopening recovery (R20); commitment through the closure stays as in §4 |
| `ownerRepay` had no "repay all" | Low | Fixed: the amount is a cap, the largest amount means all, with the minimum-loan rule (R16) |
| A one-unit dust position marked the book impaired and could not be trimmed | Low | Fixed: worthless dust is swept for one base unit and the rest written off (§5, R16) |
| Lenders could enter while the book was impaired | Low | Fixed: deposits and mints close while impaired (R21) |
| Closure interest alone made a position look like a missed execution | Low | Fixed in the Lens (judged at the debt at the close); the reopening projection is shown before the close |
| Buffer coverage ignored a plan that expires before preparation | Low | Fixed in the Lens: coverage is sized at the next execution window |
| A guardian stop chose the wind-down exit price | Low | Fixed: wind-down exits do not depend on price (R19) |
| `Deploy.s.sol` would deploy deployer-issued mock tokens on any chain | Low | Fixed: mock tokens only on 31337 and 46630 (R22) |

Informational findings (31): zero-address credits and the Lens window off-by-one were fixed; the rest are
documented behaviour or accepted limits (listed under Known limits), such as gas-heavy or reverting price
sources, the absence of a floor on the stablecoin answer, the 90% utilization cap being a funding constraint
rather than a solvency check, and the demo operator's control of price and time.

**Mutation testing.** A mutant counts as killed when any test fails. The audit's own mutants were run first on
the code as it was, with the tests before and after the test-writing pass; then a fresh sample of operator
mutants (comparisons, logic, arithmetic, rounding, booleans, deleted guards) was run on the final code.

| Area | Audit mutants, original tests | Audit mutants, new tests | Final code, new mutants |
|---|---:|---:|---:|
| PriceGate | 14 / 30 | 30 / 30 | 30 / 30 |
| RepaymentEscrow | 17 / 31 | 31 / 31 | 28 / 30 (the 2 survivors are equivalent) |
| StockReefMarket and StockReefMath | 32 / 50 | 49 / 50 | 40 / 40 |
| SessionCalendar | 19 / 32 | 32 / 32 | 28 / 28 |
| SessionRiskPolicy | 21 / 28 | 28 / 28 | |
| StockReefLens and demo | 28 / 42 | 40 / 42 | |

The remaining audit-set survivors are the TargetMissed post-check, which only an unreachable rounding case could
trip, and two Lens mutants of code the fixes replaced.

**Refactor.** Shared formulas moved into `StockReefMath` and the session rules into `SessionRules`; the gate,
market, escrow and lens were split into named steps; the lender book is valued once per ERC-4626 call; the
reentrancy lock uses transient storage. The scripted demonstration on a fresh chain produced the same 72 event
logs, evidence and addresses before and after the refactor, and again with every fix applied; apart from the
fixes' additions, no ABI changed. Packing `Account` into one slot
was tried and dropped: at 1e18 debt shares per base unit, 128 bits would cap an 18-decimal loan token's debt at a
few hundred tokens.

## Static analysis (Slither 0.11.6)

Run: `slither contracts --filter-paths "lib/|test/|script/|mocks/" --exclude-dependencies`.
Result: 50 findings, none of high impact. Triage:

| Detector | Count | Finding | Disposition |
|---|---:|---|---|
| reentrancy-no-eth | 4 | ERC-4626 `deposit`, `mint`, `withdraw` and `redeem` update `cash` after refreshing the gate and evaluating the policy | False positive: the callees are the immutable gate and policy, whose feed and token reads are static calls, and every entry point holds the market's lock. The escrow finding of this kind was fixed earlier: balances are updated before `market.repay` |
| unused-return | 9 | Ignored round id from `feed.push` (demo); try/catch destructuring of `latestRoundData`; tuple reads of `accountOf` and `sessionAt` that need two of their three fields | Intended |
| uninitialized-local | 2 | `prev` and `lo` in SessionCalendar start at zero | Intended |
| calls-loop | 15 | Lens and valuation loops call trusted contracts | Bounded by the 32-account cap; gas measured below |
| reentrancy-benign / reentrancy-events | 7 | State written or events emitted after calls to the trusted gate, policy or demo clock | Trusted, immutable contracts; locked entry points |
| missing-zero-check | 2 | Demo operator address | Demo-only; a zero operator only disables the demo controls |
| naming-convention, timestamp, cyclomatic-complexity | 11 | Private immutables named in capitals; the demo clock compares times by design | Accepted |

## Measured gas at the account cap

From `test_gas_fullCapValuation` (cold storage, 32 indebted accounts), written to `evidence/gas.json`:
borrowing about 469k gas, a lender deposit about 388k (the book is now valued once per ERC-4626 call, down from
about 520k), and the full valuation read about 298k.

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

After the audit fixes, an independent review checked the nine core lines of the spec (regular-session
pricing, the ramp, borrower-first execution, target-limited trims at the execution price, the closed-session
lock, reopening admission and recovery, lender accounting, no pools or auctions, and the bonuses) against the
final code. All hold; R16 and R19 to R22 are implemented as written, and the spec sentences they extend are
named in the appendix.

## Known limits

- Thresholds, targets and bonuses are illustrative fixtures, not calibrated against historical gaps.
- A trim needs a liquidator with capital; nothing guarantees one or an exit for the collateral.
- On a quiet open the first post-open feed update can lag (0.5% deviation trigger, 24 h heartbeat). The market waits, then is guarded; it never admits a stale price.
- Chainlink lists no L2 sequencer uptime feed for Robinhood Chain. The gate has an optional slot for one (R14) that is empty today.
- The stablecoin feed has a ceiling but no floor: a valid but extreme USDG/USD answer would overvalue collateral until the guardian stops the gate.
- A price source that reverts with malformed data or burns all gas makes reads revert instead of setting a reason; feeds are vetted per deployment.
- The guardian's stop timestamps its event with the clock, so a clock that reverts (only possible for a demo clock near the end of 64-bit time) would also block the stop.
- Lender valuation loops over at most 32 accounts; a permissionless, unbounded design is future work.
- No upgrade path: a different policy or an extended calendar is a new deployment.
