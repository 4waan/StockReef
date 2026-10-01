> **Naming.** This product was previously called StockSmart. Apart from the rename and the *Reconciliation*
> appendix at the end, this is the decision specification as agreed.

# StockReef: pre-close loan management

Decision specification v1.0

StockReef remains the working name; GapGuard is the earlier concept. This document specifies a testnet product, not a production-ready lending protocol. It fixes the core product choices while separating illustrative settings from deployment evidence that still needs verification.

## 1. Product and promise

**StockReef is a pre-close loan manager for tokenized stocks. It helps borrowers repay or add collateral before scheduled market closures and permits partial liquidation of positions that exceed the market's published limits.**

**Hook:** Stock markets close. Loans don't.

**Short pitch:** StockReef prepares stock-backed loans for market closures. Before the close, it tightens risk limits, uses borrower-funded repayment buffers, and enables partial liquidation of positions that remain over the limit. During closure it blocks new borrowing, and when eligible pricing returns it resumes liquidations before opening new credit.

**Core distinction:** managing debt already outstanding before a closure, in addition to preventing new borrowing against unusable prices.

The contract enforces rules whenever called. A keeper or another participant must submit a transaction to execute a repayment or liquidation. No claim of keeper-free execution, universal solvency, or protection against every gap is permitted. Say “designed to” until the described behavior is built and demonstrated.

## 2. Fixed product decisions

| Decision | v1 commitment |
|---|---|
| Product form | A reusable session policy contract, enforced by one reference lending market. The app lets users borrow and manage that market's loans. |
| First market | One TSLA-token/USDG testnet market on the intended Robinhood testnet; verify network and token addresses before deployment. |
| Users | Borrowers, USDG lenders, and independent liquidators. The team operates the initial automation service. |
| Prospective distribution | Demonstrate the reference market to lending-market operators. An operator integration is a later business route, not claimed current adoption. |
| Closures covered | Every scheduled regular-session close, including ordinary overnights, weekends, holidays and early closes. |
| Trading-hours policy | Price-dependent actions only during supported regular sessions, even if the selected oracle publishes extended-hours data. This is our conservative policy, not a claim that all off-hours prices are false. |
| Debt management | Manual repayment/top-up; explicitly authorized prefunded USDG buffer; capital-funded partial liquidation. |
| Actual settlement | At the transaction's execution time, using the current accepted token/loan price. |
| Outside capital | No reserved Buyers' Pool, no guaranteed collateral buyer, no gap reserve. A liquidator supplies its own repayment capital and takes inventory risk. |
| Compensation | Fixed disclosed liquidation bonuses; no bonus for spending the borrower's buffer. The team sponsors buffer-keeper gas for the demo. |
| Parameters | Immutable per demo deployment. A different policy requires a new deployment. |
| Governance | Emergency stop for price-dependent operations; no ability to edit prices, seize escrow, forgive selected debt, or alter active thresholds. |
| Portfolio size | At most 32 approved borrower accounts in the reference demo. This makes portfolio valuation bounded and testable; it is not a permissionless, scalable market claim. |
| Commercial claim | Hypothesis: better closure preparation is useful to borrowers and lenders. No claimed customer demand or willingness to pay without interviews. |

**Removed:** deferred Friday-price purchases, pool reservations and pool shares, earnings-specific risk classes, mandatory wallet allowances, rate-funded protection reserve, dynamic liquidation auction, multiple collateral markets, historical closing-round search, and a Morpho enforcement adapter.

**Preserved:** session calendar, token/feed checks, the pre-close ramp, a visible repayment plan, borrower buffer, partial liquidation, closed-session lock, controlled reopening, failure-case evidence and a polished demo.

## 3. Session policy and demo settings

All values below are illustrative product fixtures. They are not empirically calibrated safe limits or recommended production parameters.

Let O be a scheduled regular-session open and C its close. Let A = C minus 120 minutes and F = C minus 30 minutes. A starts preparation; F ends the ramp and starts the final execution window. Schedule timestamps are UTC; the UI displays America/New_York and the user's local time.

| State | Timing | Borrow/collateral withdrawal with debt | Liquidation threshold | Target after liquidation | Bonus |
|---|---|---|---:|---:|---:|
| OPEN | After reopening is complete, until A | Allowed within borrow limit and liquidity cap | 80% | 75% | 5% |
| PRE_CLOSE | A <= t < F | Allowed only within the declining borrow limit | Linear 80% to 70% | 65% | 2% for scheduling-only trims; 5% for positions also above 80% |
| FINAL_WINDOW | F <= t < C | No new borrowing or debt-backed collateral withdrawal | 70% | 65% | Same distinction as PRE_CLOSE |
| CLOSED | C until next O | Blocked | Closure policy remains 70%; displayed valuations may be stale | No price-dependent execution | None |
| REOPEN_WAIT | From next O until valid reopening conditions | Blocked | 70% | No liquidation before price admission | None |
| REOPEN_RECOVERY | From recorded price admission until max(O + 15 minutes, admissionAt + 10 minutes) | Blocked | 70% | 65% | 5% |
| GUARDED | Invalid price, source failure, pause or unknown calendar | Blocked | No action using invalid price | Manual debt repayment remains available | None |

A position is liquidation-eligible only when accrued D/V is **strictly greater** than the current liquidation threshold. Equality is not eligible. The 65% target is a destination after a permitted trim, not an instruction to liquidate every loan above 65%. A 68% position can enter a closure without forced liquidation under these fixtures.

During PRE_CLOSE:

`LT(t) = 0.80 - 0.10 * (t - A) / (F - A)`

Before F, new borrowing and collateral withdrawals with debt must leave:

`D/V <= B(t) = min(0.75, LT(t) - 0.05)`

In OPEN, B = 75%. In PRE_CLOSE, B falls from 75% to 65%. From F onward, new borrowing is disabled rather than relying on a last-second limit change. Existing loans do not become liquidatable just because they exceed B; liquidation uses LT.

The same closure threshold applies to overnight and multi-day windows in v1. Longer windows accrue more interest and can be worse economically. Window-specific calibration is future work. Earnings and unscheduled halts are not predicted by the calendar.

### Calendar implementation

Generate a finite list of regular sessions off-chain with a timezone-aware library; commit the source calendar, generation script, timezone-data version and generated UTC sessions. Store an immutable ordered session list with binary lookup. Do not implement a bespoke five-year DST engine for this version.

Use the reference calendar for general US regular-session scheduling, and verify the selected stock's primary-venue exceptions before a real deployment. The published NYSE calendar documents regular hours and scheduled early closures [S1]. A holiday closes a session; it must not create a phantom reopen on Saturday or Sunday.

Outside the loaded schedule, fail closed. Emergency closure uses the guardian stop; it cannot create retroactive pre-close protection. Test early-close days, DST boundaries and the end of calendar coverage.

## 4. Borrower-first execution

### Manual actions

Repay debt and add collateral without requiring an oracle. A borrower with zero debt can withdraw collateral without a price. Token transfer restrictions may still prevent an otherwise permitted action.

Every borrower screen shows current debt including interest, collateral value with timestamp, B, LT, the closure target, and exact current repayment/top-up estimates. Show “unknown” if valuation is unavailable; never display a reassuring green health indicator from a stale quote.

### Prefunded buffer

A separate RepaymentEscrow holds borrower-owned USDG. It is neither lender liquidity nor collateral, and earns no yield in v1. An approval is not a funded balance.

The borrower authorizes a policy containing market, account, target LTV, maximum spending per session, and expiry. For the standard closure plan the target is 65%. The user may authorize a lower target; the demo rejects a higher one for this closure plan.

Anyone can call `executeBuffer(account)` during PRE_CLOSE or FINAL_WINDOW with a valid price. The function recomputes debt and valuation, repays no more than the amount needed to reach the authorized target, and is capped by escrow balance and the remaining session allowance. It emits the actual debt reduction. It does not sell collateral or charge a liquidation bonus.

The UI identifies this as an authorization to reduce debt during preparation, even if the position is not yet liquidation-eligible. Borrowing from A onward is rejected while a closure-buffer authorization is active, to prevent borrowing and auto-repaying the same debt repeatedly. To use intraday credit without this restriction, do not activate the buffer plan.

Buffer cancellation and withdrawal are allowed before A or after a valid full reopening. During preparation, closure and reopening recovery, authorized buffer funds remain committed while debt exists; full debt repayment releases them. Disclose this before activation. Depositing additional buffer is allowed at any time, but an oracle-dependent target execution still needs valid pricing and a permitted session.

The owner may explicitly repay a fixed amount from escrow at any time, including CLOSED or GUARDED, because reducing a debt balance does not require valuing collateral. No external keeper may invent that amount without a valid authorization. An expired execution authorization does not block the owner's direct repayment or eventual withdrawal.

### Ordering with liquidation

Before liquidating during preparation, check for any presently executable buffer repayment. If one exists, reject the trim with `BufferPending`; the caller first executes the buffer in a **separate transaction**, then recomputes liquidation eligibility.

This avoids a failed later liquidation rolling back a successful buffer repayment. Do not use an all-or-nothing batch that reverses earlier progress. A permissionless buffer call has no reward, so no caller can farm penalties by splitting it.

If escrow transfers fail due to a genuine token restriction, mark the account as blocked in off-chain monitoring. Do not claim that allowance, balance or authorization overrides the token issuer. This demo accepts that issuer restrictions can prevent execution and does not silently bypass buffer priority.

## 5. Liquidation arithmetic and limits

Let D be accrued debt and V the accepted collateral value, both in loan-asset units. Let T be the target LTV and b the applicable liquidation bonus.

For repayment with no collateral removal:

`cashRequired = max(0, D - T * V)`

For adding collateral with no repayment:

`additionalCollateralValue = max(0, D/T - V)`

For a liquidator who repays x and receives collateral worth x(1+b):

`D_after = D - x`

`V_after = V - x(1+b)`

Solving D_after/V_after = T gives:

`xRequired = (D - T*V) / (1 - T*(1+b))`

Require a positive denominator. The repay amount is not simply D minus T*V because the liquidator takes collateral away. For partial fills, return remaining excess rather than claiming the target was achieved.

`trim(account, maxRepay, minCollateralOut, deadline)` is permissionless but requires the liquidator to provide USDG. The market transfers collateral directly to the liquidator at the current accepted price; no DEX exit is promised. The caller can independently hedge or sell it. A price quote is not proof of sale depth.

Use exact mulDiv integer arithmetic with explicit units. Round required repayment upward; collateral value/borrow capacity downward; collateral seized downward subject to checking the resulting debt/target relationship. Reject zero-effect operations. Partial repayment is limited by caller maximum, outstanding debt, required target amount and available collateral. Only actual delivered USDG reduces debt. Define an integer tolerance of one USDG base unit for the target check; do not hide material residual debt in a “dust tolerance.”

For a position with D/V >= 1/(1+b), the ordinary trim cannot improve its LTV. Route it to collateral-exhaustion recovery, do not assert that every liquidation improves LTV. Repay against remaining collateral at the allowed bonus, exhaust collateral where necessary, and recognize residual bad debt. A valid claim of zero collateral or economically worthless dust is required before a write-off; valuable residual collateral must not become a free borrower withdrawal after forgiving debt.

### Worked example, ignoring interest and integer rounding

Position: V = 10,000 USDG, D = 7,200 USDG, LTV = 72%.

On a 16:00 close, A = 14:00 and F = 15:30. At 15:15, LT is approximately 71.667%, so the position is eligible. It is not eligible when LT merely equals 72%.

| Path | USDG debt repaid | Collateral taken at current value | Remaining debt | Remaining collateral | LTV |
|---|---:|---:|---:|---:|---:|
| Manual or funded buffer | 700.00 | 0.00 | 6,500.00 | 10,000.00 | 65% |
| Partial liquidation at 2% | 2,077.151335 | 2,118.694362 | 5,122.848665 | 7,881.305638 | 65% |

The collateral sold is the price of deleveraging; the bonus portion is approximately 41.54 USDG, before gas and trading costs. Describe both so the borrower sees the full consequence.

The 65% target is based on the current price and debt, not a promise that the same ratio persists through closure. Interest and price changes continue. With a hypothetical 35% gap and a 5% recovery bonus, this trimmed example still has about 243.95 USDG of lender shortfall; the unmanaged example has about 1,009.52. These are simplified model outcomes, not historical performance.

## 6. Prices, token identity and reopening

### Adapter contract

Use a single internal quote shape: `priceLoanPerTokenWad, roundId, updatedAt, status, reason`. The reference implementation consumes AggregatorV3-style feeds. That interface exposes round data and timestamps; it does not supply a marketStatus field [S2]. Calendar policy and feed validity are separate inputs.

Configure token address, stock feed address, loan-token conversion feed or explicitly labelled test peg, decimals and adapter type by an immutable deployment manifest. Token symbol text alone is not authentication. Deployment checks compare the selected addresses with issuer/oracle documentation and verify their code and interfaces.

Chainlink's Robinhood documentation describes token feeds as total-return values that already incorporate the token multiplier, and describes the issuer's `oraclePaused()` flag [S3]. Therefore use raw token units with the matching token-price feed; do not multiply by uiMultiplier again. Test pause/unpause and multiplier changes against the actual supported token interface. If a required flag call fails, fail closed.

Value collateral in **USDG units**, not silently in dollars: use token/USD divided by USDG/USD, with decimals normalized. A constant USDG = USD assumption is permitted only in a clearly labelled demo adapter. Production conversion availability and depeg handling remain a deployment gate.

Reject nonpositive answers, zero/future timestamps, stale readings, incorrect decimals/configuration, unsupported interfaces, oracle pause and broken conversions. Set feed-specific maxAge from verified operating parameters; the mock fixture uses 120 seconds. A larger price move alone is not invalid: a real gap must not freeze liquidation indefinitely. v1 trusts its vetted feed within these validity checks; the guardian can stop operations if the source is suspected compromised.

### Reopening decision

Remove the three-prices-within-1% convergence condition. Replace it with time and freshness admission:

1. Wait until O + 5 minutes.
2. Require all relevant price inputs to be otherwise valid, and the stock feed's updatedAt to be at or after O + 1 minute. Repeating the prior close is not sufficient merely because the UI has been refreshed.
3. Once admitted, permit recovery liquidations at LT = 70%, T = 65%, bonus = 5%.
4. Record `admissionAt` in a permissionless refresh transaction the first time this session qualifies. Permit new credit only after `max(O + 15 minutes, admissionAt + 10 minutes)`, with valid current pricing. A late first price therefore still gets a ten-minute recovery window. The normal OPEN limits then apply.
5. If price admission has not occurred by O + 30 minutes, label the market GUARDED and alert the operator. A later qualifying refresh starts recovery; the deadline does **not** authorize stale-price liquidation.

All price-dependent entry points refresh this gate before evaluating permissions. The first qualifying call may establish admission, but cannot bypass the ten-minute recovery period. If it reverts for another reason, its checkpoint reverts too; the keeper should use the standalone refresh call. Interrupted recovery restarts its admission timer after the source is valid again. No unseen transaction history is fabricated.

Freshness does not independently prove that the source reflects an economically executable stock price. A real deployment must verify feed semantics. No default fresh-quote path may use a Sunday quote for Monday admission.

On recovery from a mid-session source outage or guardian stop, record a permissionless recovery checkpoint and require a five-minute observation grace with a fresh quote after that checkpoint. Price-dependent actions remain stopped during grace. Manual repayment/top-up stay permitted. This applies once per detected recovery, not on every normal call.

Guardian unpause has a 24-hour delay and cannot override validity or calendar checks. A testnet demonstration may advance DemoClock to demonstrate the delay; that must be labelled simulation.

## 7. Lender accounting and withdrawal policy

This reference market is a real accounting exercise even on testnet. Use ERC-4626 lender shares with explicitly separate borrower collateral and repayment escrow. OpenZeppelin documents share-rounding and inflation risks and provides virtual-share/asset protections [S4]. Pin an exact dependency release; virtual offsets alone do not replace slippage and accounting tests.

**v1 decision:** lender deposits, mints, withdrawals and redemptions are allowed only in OPEN, before A, with valid pricing. They are blocked throughout preparation, closure and recovery. This is a published scheduled-liquidity product, not instant-access yield. Idle liquidity is also a bound on withdrawals. Disclose this policy prominently; it is an adoption cost.

Loans and escrow repayment can continue to update balances while lender share conversions are locked. For authorized deposits of collateral and debt repayments, token transfers must succeed; flags do not override issuer controls.

Debt uses a deterministic global index and debt shares. Fix the testnet nominal annual rate at 10%, with per-second compounding and a 365-day year. Use a pinned, tested fixed-point exponentiation library, with index computed from a fixed deployment epoch so extra checkpoint calls do not change the chosen compounding convention. This is a demo interest policy, not an optimized commercial rate model. Specify borrow/repay share rounding and repay-all separately.

For the bounded 32-account demo, compute lender assets using one consistent accepted price snapshot and all active positions:

`recoverable_i = min(accruedDebt_i, collateralValue_i / 1.05)`

`lenderAssets = marketUSDGCash + sum(recoverable_i)`

The 5% recovery haircut is a conservative valuation convention. It is not a guaranteed executable bid and does not include every possible exit cost. Collateral and escrow USDG are not additionally counted. A valuation allowance is not debt forgiveness: borrowers still owe their full debt until repayment or a valid write-off.

This prevents a known shortfall from remaining at face value while the first lender exits. All four share-entry/exit functions must refresh the same portfolio valuation inside their transaction before converting shares. Views may show the last accepted price during a lock, but must flag that valuation as indicative. `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` return zero when locked. ERC-4626 conversion/preview behavior must remain standard-compatible rather than reverting solely on session state.

The account bound must be enforced when borrowing begins, not by an unbounded account list; remove zero-debt accounts. The demo uses approved test accounts to avoid cap exhaustion by dust borrowers. Publish measured gas for the full-cap valuation. A scalable permissionless replacement requires further design and is outside this release.

New borrowing is also capped at 90% book utilization using cash plus total accrued debt; this is a funding constraint, not proof of solvency. A known impairment (any debt above recoverable value) blocks new borrowing until resolved. If vault assets become zero while shares remain, stop deposits and enter run-off; do not recapitalize through an arbitrary ERC-4626 conversion.

## 8. Automation and failure behavior

The team runs a keeper that watches sessions and borrower events, simulates transactions, applies funded buffers, and identifies eligible trims. It is not an oracle and cannot choose prices or risk parameters. Buffer execution is permissionless; liquidation additionally requires capital. Third parties can act if the team keeper stops.

Operational order: refresh source status; execute funded buffers; re-read positions; simulate trims; send capital-funded transactions; verify receipts; report remaining exposure. Use bounded batches with independent transactions, nonce handling, deadlines and retry limits. Failure for one account must not stop other accounts. Logs distinguish attempted, reverted, mined and target-reached actions.

| Failure | Required behavior |
|---|---|
| No keeper or liquidator acts | Debt remains. Closing still blocks new borrowing; report missed execution without a protection badge. |
| Buffer too small | Repay what is authorized and available, then show residual amount/eligibility. |
| Token transfer frozen | Revert the transfer-dependent action; preserve balances; report issuer restriction. |
| Price becomes stale before C | Stop valuation-dependent actions; allow manual repayment/top-up; no stale-price emergency trim. |
| Liquidator lacks a profitable exit | No guaranteed trim; keep the position eligible while policy allows. |
| Sudden intraday crash | Apply the regular distress bonus if over the OPEN threshold, with current valid pricing; bad debt can still occur. |
| Early/unannounced venue shutdown | Fail closed once detected; no assertion that earlier preparation took place. |
| Chain outage or transaction delay past C | Pre-close trim reverts at/after C. Do not backdate execution. |
| Extreme reopening gap | Recover what collateral supports, recognize residual loss in lender value and accounting. |
| Missing reopening data | Remain GUARDED even after the timeout; surface an incident. |

The product measures execution coverage and residual exposure, not just the number of healthy-looking positions. Do not call a loan “protected” merely because it has a configured buffer or a keeper job.

## 9. Contract and app boundaries

| Component | Responsibility |
|---|---|
| SessionCalendar | Immutable UTC session schedule and next-session lookup. |
| PriceGate | Vetted feeds, conversion, pause/freshness checks and recovery checkpoints. |
| SessionRiskPolicy | Pure/view session limits, target, applicable bonus and action permissions. |
| StockReefMarket | Loan accounting, collateral, ERC-4626 shares, repayment, trimming, bad debt and valuation. |
| RepaymentEscrow | Segregated USDG balances, bounded authorizations and market-only debt payment. |
| StockReefLens | Current action eligibility, borrower plan and risk summaries. |
| Keeper | Transaction discovery/execution, logs and operator alerts. |

Use OpenZeppelin SafeERC20, ReentrancyGuard and appropriate access control. Use a real block clock outside the demo; DemoClock is permitted only on an explicit test-chain allowlist, not simply every chain except one mainnet ID. No upgrade proxy in v1. Split market code if necessary for clarity/size without inventing arbitrary line-count targets. Check deployment bytecode limits early.

Recompute policy on every state-changing entry point, including ERC-4626 mint/redeem and collateral withdrawals. Check zero debt before requiring a collateral price. Reject unsupported fee-on-transfer/rebasing assets in the deployment manifest and verify token balance deltas for supported transfers. Token metadata alone does not prove these properties.

Four UI views are sufficient:

- **Borrow / My loan:** live session, current debt, exact closure plan, buffer funding, manual actions, liquidation consent and missed-execution status.
- **Lend:** deposits/withdrawals, next allowed exit window, idle liquidity, known valuation allowance and testnet label.
- **Operations:** eligible accounts, buffer execution, trims, blocked reasons, keeper status and receipts.
- **Evidence:** comparative scenarios, assumptions, borrower costs, liquidator exposure and failure cases.

No generic risk score. The main interface answers: “What must I repay or add, by when, what can happen if I do nothing, and has the action actually executed?”

## 10. Evidence and verification gates

Use four baselines with identical starting debt, collateral, price path and interest settings:

1. Fixed-threshold lender with borrowing available under its stated oracle policy.
2. Same lender with a closed-session borrowing lock.
3. StockReef with execution disabled.
4. StockReef with successful buffer repayment or capital-funded trim.

Add a fifth **static conservative-limit** case at the 65% borrow limit. Compare that case separately because its opening loan amount differs. It is necessary to ask whether daily higher credit is worth forced-trim costs; do not pretend all baselines extend the same credit.

For every scenario show initial/remaining debt, collateral retained, borrower external USDG contributed, liquidation bonus, liquidation notional, liquidator capital, inventory P&L/exit assumptions, lender loss, gas and unexecuted exposure. Model funded-buffer cash as extra borrower capital. If a liquidator holds stock through the gap, include its loss; do not imply risk vanished because the lender was repaid.

Required scenarios: unchanged prices over five sessions; moderate drop; severe gap beyond the chosen target; rally; real-time decline during the ramp; absent keeper; unfunded liquidator; partial buffer; corporate-action pause; USDG conversion failure; holiday/early close; missing opening quote. The unchanged-price repeated-session case exposes the cost of repeatedly borrowing at 75% and trimming back toward 65%.

Required arithmetic/property tests:

- Ramp starts/ends exactly as specified; threshold eligibility uses strict greater-than; F starts the borrow lock before C.
- Borrowing and debt-backed collateral withdrawal never pass above B or outside allowed states.
- No pre-close trim executes at/after C; closure does not magically reduce debt.
- Buffer payments respect owner, market, target, expiry and remaining session allowance; escrow is never counted as lender cash before repayment.
- Separate successful buffer transaction remains committed if a later trim fails.
- For solvent trim conditions, LTV falls and full fills reach target within documented rounding tolerance; insolvent recovery takes its separate branch.
- USDG and collateral conservation; no bonus without actual capital repayment; no unbounded withdrawal after write-off.
- All ERC-4626 entry and exit paths enforce the same locks, current valuation and slippage limits.
- Interest value is invariant to extra accounting-only checkpoints; rounding cannot create borrow/repay profit.
- Invalid feeds, unsupported calls, future timestamps, token freezes, decimals mismatch, loan-token depeg and multiplier changes exercise explicit failure modes.
- Reopening freshness requirements reject prior-session data without requiring prices to remain within an arbitrary percentage band.
- No borrower/keeper action bypasses recovery grace or guardian restrictions.

Use independent decimal/rational arithmetic to validate golden examples, not the same Solidity implementation as its own oracle. Run unit/fuzz/invariant tests, bytecode-size checks, gas-at-cap checks and Slither with reviewed findings. Store actual results; do not prewrite passing test counts.

For integration evidence, pin chain ID, block number/hash, token/feed addresses and decimals. Fork tests validate actual interfaces and feed behavior; they do not establish production economic safety. Do not use market statistics, historical tail figures or malformed-round claims in the pitch until the underlying records and scripts are available and reproduced.


## 11. Pitch pack and demo

### One sentence

StockReef manages stock-backed loans before market closures, using borrower-funded repayments and partial liquidation to reduce outstanding exposure while eligible pricing is available.

### 30-second pitch

Stock markets close. Loans don't. StockReef helps borrowers prepare their stock-backed loans before that happens. It shows exactly what to repay or add, can execute repayments from a buffer the borrower funds in advance, and lets liquidators reduce positions that remain above the published limits. Borrowing stops during closure, and recovery starts when eligible prices return. Our demo shows the debt actually falling before the bell—and what happens when execution fails.

### Longer explanation

A borrowing lock can prevent a new loan during a closure, but an existing loan still carries exposure. StockReef addresses that existing debt. Its reference market publishes a preparation schedule, gives borrowers a penalty-free repayment route, and allows target-limited partial liquidation before the close. We settle at the current accepted price, so there is no hidden promise that another pool will buy at yesterday's value. The system is designed to reduce closure exposure; transactions, liquidity and usable price data still matter. We show lender outcomes alongside borrower costs and liquidator exposure, including severe gaps and failed execution.

### Three-minute demonstration

- 0:00–0:20: Hook and a 72%-LTV loan. Distinguish current debt from the new-borrow limit.
- 0:20–0:45: Display the scheduled preparation window and the current 700 USDG repayment plan for 10,000 collateral / 7,200 debt.
- 0:45–1:15: Execute a funded buffer repayment on account A. Show transaction receipt, debt reduction and unchanged collateral.
- 1:15–1:45: Account B has no buffer. Advance to 15:15 on the labelled demo clock and trim it at the accepted execution-time price. Show 2,077.15 repayment, 2,118.69 collateral transfer and approximately 65% final LTV.
- 1:45–2:05: Advance to closure. New borrowing fails. Account C, whose keeper never acted, still has its old debt and a missed-execution warning.
- 2:05–2:35: Reopen with a fresh gapped quote. Show recovery before new credit, lender valuation and residual loss if the shock exceeds the fixture's capacity.
- 2:35–3:00: Display the comparison, borrower costs, liquidator inventory assumptions and verified test/deployment evidence. State the mock feed and testnet limitations.

Never say: every loan is ready; no one needs to execute; zero risk; guaranteed profitable liquidation; guaranteed higher capital efficiency; production-safe thresholds; plug-and-play enforcement on existing Morpho markets. Existing Morpho oracle addresses are immutable [S5], and a price interface alone cannot implement this market's separate action permissions.

## 12. Decision log and remaining evidence

The product decisions are fixed above. The following are evidence gates, not invitations to keep adding features:

- Exact testnet token/chain addresses and transfer/issuer restrictions.
- Actual feed semantics, heartbeat, normalization and stock/USDG conversion availability.
- Reproducible calendar and pinned dependency versions.
- Correct accounting and action behavior under the named failure cases.
- Realistic liquidation exit costs; until measured, use explicit scenarios.
- Customer response to daily preparation, prefunding and scheduled lender withdrawals.

The main commercial test is whether borrowers value the extra intraday credit enough to accept repayment preparation and whether lenders value the risk controls enough to accept the exit policy. A successful technical demo does not settle that question.

## Sources and scope

These sources support interface, calendar and implementation facts; they do not validate our chosen numerical risk settings. All unlabeled product rules in this document are new design decisions.

- [S1: NYSE holidays and regular-session hours](https://www.nyse.com/trade/hours-calendars)
- [S2: Chainlink Data Feeds API](https://docs.chain.link/data-feeds/api-reference)
- [S3: Chainlink Robinhood tokenized equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
- [S4: OpenZeppelin ERC-4626 implementation considerations](https://docs.openzeppelin.com/contracts/5.x/erc4626)
- [S5: Morpho oracle interface and immutability](https://docs.morpho.org/learn/concepts/oracle/)


## Appendix: Reconciliation

Where this appendix conflicts with the body, the appendix wins.

### R1. Ramp depth by closure class

The body applies one closure threshold to every close (§3). StockReef v1 instead uses two classes, chosen
from the scheduled gap to the next open. All values remain illustrative fixtures.

| Class | Applies when | LT at A → at F | Target after trim | Bonus |
|---|---|---|---:|---:|
| OVERNIGHT | Next scheduled open is less than 24 hours after C | 80% → 77% | 72% | 2% scheduling-only, 5% if also above 80% |
| EXTENDED | Next scheduled open is 24 hours or more after C (weekends, holidays, multi-day) | 80% → 70% | 65% | 2% scheduling-only, 5% if also above 80% |

- `LT(t) = 0.80 − (0.80 − LT_F) · (t − A) / (F − A)` during PRE_CLOSE, where LT_F is the class value.
- `B(t) = min(0.75, LT(t) − 0.05)` in both classes; new borrowing is disabled from F.
- CLOSED, REOPEN_WAIT and REOPEN_RECOVERY use the closing class's LT_F and target.
- The worked example in §5 (a Friday 16:00 close) is an EXTENDED close and is unchanged.

Reason: ordinary weeknights carry much smaller close-to-open moves than weekends and holidays. Applying the
weekend threshold every night would make the market a 70% market with a trim every afternoon.

### R2. Buffer target

An authorized buffer target must be at most 65% (the deepest plan target). `executeBuffer` repays toward
the borrower's authorized target, subject to the caps in §4.

### R3. Price freshness

The mock feed fixture keeps `maxAge = 120 s`, so live demos need a labelled feed pusher (the keeper's
`feed` mode). Fork tests against a real Chainlink feed use a feed-specific `maxAge` derived from that
feed's documented heartbeat.

### R4. Issuer pause flag

The deployment manifest declares, per token, whether the issuer pause flag is required. If it is required
and the call fails, PriceGate fails closed. If a token version does not implement the flag, the manifest
must say so explicitly and the app labels it.

### R5. Evidence in the pitch

Market statistics from earlier research (stale-price borrowing, feed gaps, malformed rounds) enter the
pitch only when a committed script in `tools/evidence/` reproduces them from pinned chain data.

### R6. Demo controls

DemoClock advances and mock-feed pushes live in the Operations view and are labelled as simulation.
DemoClock is allowlisted to chain IDs 31337 (local) and 46630 (Robinhood Chain testnet).

### R7. Loan asset and demo scale

The testnet market lends **real Paxos USDG** (Robinhood Chain testnet). Because the public faucet is
rate-limited, demo positions are the §5 worked example scaled by 1/100: 100 USDG of collateral value,
72 USDG of debt, a 7 USDG buffer repayment, or a 20.77 USDG trim. The arithmetic is identical at both
scales; `tools/golden/golden.json` carries both.

### R8. Borrower access

Borrowing is open to any wallet while fewer than 32 accounts hold debt. A minimum loan of 5 USDG stops dust
positions from filling the cap. Accounts leave the active set when their debt returns to zero.

### R9. Demo time control

On the demo deployment a single DemoController transaction advances the DemoClock and publishes the next
mock price, so each demo step is one action. Only the demo operator key can call it. It is labelled as
simulation in the app.

### R10. Hosting

The web app is a Next.js project deployed on Vercel.

### R11. Token multiplier changes

ERC-8056 tokens publish `uiMultiplier`, `newUIMultiplier` and `effectiveAt`. Dividends and splits change the
multiplier, and the stock feed already reflects it. If `effectiveAt` is non-zero and has passed, and the stock
feed's `updatedAt` is earlier than `effectiveAt`, the price is invalid (`MULTIPLIER_LAG`) until the feed
publishes again. Manual repayment and top-up stay available.

The check compares timestamps only, so it needs no size threshold and no stored multiplier. Robinhood pauses
an affected token from the early morning of the effective date until about the US open, and reopening
admission already requires a stock update at or after O + 1 minute, so an ordinary dividend adds no wait. The
check matters when a change takes effect during a session. It never fires for a token whose `effectiveAt` is
zero, such as the testnet faucet token.

### R12. Answer ceiling

Each feed has an `answerBound` in its own decimals (the mock stock feed uses 1e14, i.e. 1,000,000 USD at 8
decimals). Answers above it are rejected as malformed. It is a magnitude check, not a price band: a real gap
of any size below the bound is accepted.

### R13. Demonstration framing

In the three-minute demonstration, account C shows missed-execution detection: the app raises the alert and
states the exact debt and exposure still open at the close. Quantified gap scenarios, residual-loss figures and
testnet limitations are presented in the Evidence view and the README.

### R14. Robinhood Chain specifics

- **Sequencer uptime.** Robinhood's documentation recommends checking an L2 sequencer uptime feed before
  trusting a price; Chainlink lists none for Robinhood Chain. PriceGate accepts an optional uptime feed and
  grace period from the manifest. When configured, a down sequencer (`SEQUENCER_DOWN`) or a restart inside the
  grace period (`SEQUENCER_GRACE`) invalidates prices. The manifests leave it unset.
- **Quiet opens.** The Robinhood stock feeds publish on a 0.5% deviation or a 24-hour heartbeat. On a quiet
  open the first stock update after O + 1 minute can arrive late. Admission waits for it; after O + 30 minutes
  the market is GUARDED (§6), with no new credit and no liquidation until a qualifying price arrives.
- **Ordering.** The sequencer orders transactions first come, first served; a higher fee does not move a
  transaction ahead. Buffer executions and trims compete on arrival time, not gas price.

### R15. Demo operation

Demo positions are opened by a committed script before recording. On camera, one operator wallet advances
the labelled demo clock (R9); the keeper runs in watch mode and executes funded buffers and capital-funded
trims on its own, and the app shows each receipt as it lands. No borrower or liquidator key is held by the
web app.

### R16. Minimum loan on repayment

A repayment must clear the loan or leave at least the minimum loan (R8), so dust cannot hold one of the 32
active slots. A buffer execution that would leave less repays in full when the escrow allows, otherwise it
stops at the minimum. Trims and collateral-exhaustion recovery are not limited by this rule.

### R17. After the calendar ends

The calendar is immutable and finite. From the open of the last loaded session the market fails closed
(§3) and enters wind-down: no borrowing, trims, buffers or deposits; lenders may withdraw against idle cash
at the last accepted valuation; repayments keep adding to that cash; buffer plans are released. A
continuing market is a new deployment with an extended calendar.

### R18. Demo clock bounds

A demo step moves the simulated clock at most seven days and never past the open of the last loaded
session. Simulated time accrues interest exactly as real time does; the app labels it.
