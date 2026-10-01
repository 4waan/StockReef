# Review of the GapGuard concept document

GapGuard was the first concept for this project ("Session-Aware Lending for Stock Tokens", 10 pages).
StockReef replaces it. This review tests every proposal in that document and records what
StockReef keeps, changes or drops under `docs/SPEC.md`.

Arithmetic below was recomputed independently. Market facts marked *research* are background notes
and are not used as evidence until a script reproduces them.

## 1. Arithmetic checks

| Claim in GapGuard | Check | Result |
|---|---|---|
| Closed threshold cap `LT ≤ (1 − g99)/(1 + b)` = 76.2% for g99 = 20%, b = 5% | 0.80 / 1.05 = 0.76190 | Arithmetic correct. But b must be the largest bonus paid at reopening; with the document's own 8% auction cap the bound is 0.80 / 1.08 = 74.07%. Interest during the closure and oracle deviation are also missing. |
| A position at 70% survives a 26.5% gap | 1 − 0.70 × 1.05 = 0.265 | Correct at a 5% bonus only. At 8% it is 24.4%. |
| Friday walkthrough: "around 3 p.m. the falling threshold crosses 70%" | Threshold falls linearly from 80% at 14:00 to 70% at 16:00, so it is 75% at 15:00 and reaches 70% exactly at 16:00 | **Wrong.** A 70% position becomes eligible only at the moment the market closes, so the flagship trim never happens. With strict ">" eligibility it never happens at all. |
| Trim to 65% at a 2% bonus: repay ≈ 1,484, take ≈ 1,513, leaving 5,516 on 8,487 | x = (7,000 − 6,500) / (1 − 0.65 × 1.02) = 1,483.68; collateral 1,513.35; 5,516.32 / 8,486.65 = 65.00% | Correct. The collateral-funded formula is kept in StockReef. |
| After a 15% reopening gap the trimmed position is 76.5%; at an 8% bonus the liquidator needs 82.6% of collateral | 0.65 / 0.85 = 76.47%; × 1.08 = 82.59% | Arithmetic correct, but the step contradicts the state machine: REOPEN hands over to EXTENDED with an 80% threshold, where a 76.47% position is healthy. |
| A fixed-limit lender at 75% facing a 20% gap reaches 93.75% and needs 98.4% | 0.75 / 0.80 = 93.75%; × 1.05 = 98.44% | Arithmetic correct, but the comparison uses a 20% gap for the fixed lender and a 15% gap for GapGuard. At the same 15% gap the fixed lender reaches 88.24% and needs 92.65%: no loss either. |
| Gap reserve funded by a closed-hours premium | 10 percentage points annualised on $1M of debt for 48 h = 1,000,000 × 0.10 × 48 / 8,760 = $547.95 | The premium is tiny relative to a single tail event. Dropped. |
| Reopen when 3 consecutive prices sit within 1% | Robinhood stock feeds update on roughly 0.5% moves (*research*), so two same-direction steps already span about 1% | Can stall indefinitely during a steady decline. "Stable" is not "valid". Dropped. |

## 2. Proposal by proposal

| # | GapGuard proposal | StockReef | Reason |
|---|---|---|---|
| 1 | Name "GapGuard" | Dropped | Another entry in this buildathon uses the name. Product is StockReef. |
| 2 | One-liner "Margin loans for stock tokens that know when Wall Street is closed" | Changed | Hook is now "Stock markets close. Loans don't." The pitch leads with managing debt that already exists. |
| 3 | Users: borrowers, lenders, liquidators | Kept | The team runs the first keeper; liquidators bring their own capital. |
| 4 | Lending market on Robinhood Chain testnet, borrowing USDG | Kept | One TSLA-token/USDG market. |
| 5 | Novelty: "the session-aware risk engine does not exist" | Changed | Too broad: StockGuard, Vigil and others in this round handle closures. The defensible claim is managing outstanding debt before the close and showing the transactions that reduced it. |
| 6 | Problem: Monday gap, thin exit at reopen, one number all week, stale-price borrowing | Kept, narrowed | All four are real; StockReef addresses existing debt before the close and blocks new debt while closed. It does not claim to remove gap risk. |
| 7 | Session-aware limits | Kept | SessionRiskPolicy: OPEN, PRE_CLOSE, FINAL_WINDOW, CLOSED, REOPEN_WAIT, REOPEN_RECOVERY, GUARDED. |
| 8 | Pre-close ramp over the last 2 h | Changed | Preparation starts 2 h before the close, but the ramp finishes **30 min before** it (F), leaving an execution window. Depth depends on closure class (spec appendix R1). |
| 9 | PRE_CLOSE only before closures longer than 12 h | Changed | Every weeknight is 17.5 h, so the rule is ambiguous. StockReef covers every scheduled close and sets depth by class: OVERNIGHT 80% → 77%, EXTENDED 80% → 70%. |
| 10 | Max borrow 75% open, 70% extended, 70% → 60% pre-close, 60% at reopen | Changed | `B(t) = min(75%, LT(t) − 5%)`; no new borrowing from F through the end of recovery. No borrowing on the first post-closure price. |
| 11 | Liquidation threshold 80% open/extended | Kept for OPEN | 80% in OPEN with a 5% bonus. Price-dependent actions only in the regular session. |
| 12 | Liquidations in extended hours with "extra price checks" | Dropped | StockReef acts only on regular-session prices. This is a conservative policy, not a claim that off-hours prices are false. |
| 13 | Partial liquidation down to 65% at a 2% bonus before the close | Kept, clarified | Target 65% (EXTENDED) or 72% (OVERNIGHT). 2% bonus for scheduling-only trims; 5% when the position is also above 80%. Eligibility is strictly greater than LT. |
| 14 | Closed-session lock: no new borrowing, no LTV-raising withdrawals; repay and add collateral open | Kept | Repay and add collateral never need a price. |
| 15 | Liquidations paused while closed | Kept | No price-dependent execution in CLOSED. |
| 16 | Reopen guard: no liquidation on the first print | Kept, mechanism replaced | Admission needs O + 5 min and a stock price updated at or after O + 1 min; then at least 10 min of recovery liquidations before new credit. The Sunday-evening quote can never qualify. GUARDED with an alert after O + 30 min; a deadline never makes stale data acceptable. |
| 17 | Convergence: 3 prices within 1% | Dropped | See §1. |
| 18 | Dutch auction 1% → 8% after reopening | Dropped | Fixed, disclosed bonuses instead (5% in recovery). |
| 19 | Gap reserve funded by a closed-hours rate premium and a cut of bonuses | Dropped | See §1. No reserve and no guaranteed collateral buyer in v1. |
| 20 | Unknown or stale price counts as closed | Changed | Calendar decides the session; price validity is a separate gate. Invalid, paused or stale prices put the market in GUARDED. Outside the loaded calendar the market fails closed. |
| 21 | Price sanity: zero or out-of-band mid | Kept | Rejects non-positive answers, zero or future timestamps, stale readings, wrong decimals and pause flags. |
| 22 | Bid-ask spread check | Dropped | Chainlink AggregatorV3 feeds expose no bid or ask. |
| 23 | Single-update circuit breaker | Dropped | A real gap must not freeze liquidation indefinitely; the guardian stop covers a suspected compromised source. |
| 24 | Oracle adapter mirroring Chainlink's 24/5 schema (`mid`, `marketStatus`, `lastSeenTimestampNs`) | Dropped | Those fields exist in Data Streams reports, not in the on-chain AggregatorV3 interface. StockReef uses an on-chain session calendar plus AggregatorV3 rounds. |
| 25 | Mock equity feed so the demo can fast-forward a weekend | Kept | MockAggregatorV3 plus a labelled DemoClock, allowlisted to local and Robinhood testnet chain IDs. |
| 26 | Weekend threshold sized as `(1 − g99)/(1 + b)` with g99 = 20% | Changed | Values are labelled illustrative fixtures. Research suggests 20% overstates a typical weekend p99 and understates earnings nights; calibration is future work. |
| 27 | Four contracts plus a test feed, one isolated market per stock | Changed | SessionCalendar, PriceGate, SessionRiskPolicy, StockReefMarket, RepaymentEscrow, StockReefLens. One market in v1. |
| 28 | GapGuardMarket as an ERC-4626 USDG vault | Kept, extended | Lender shares with withdrawal windows (OPEN only, before A) and mark-to-recoverable valuation so a known shortfall is not paid out at face value. |
| 29 | GapReserve contract | Dropped | See row 19. |
| 30 | MorphoSessionOracle stretch: price haircut "without migrating" | Dropped | A Morpho market's oracle is fixed at creation, and a haircut also changes liquidation pricing; it cannot reproduce separate borrow and liquidation rules. |
| 31 | OpenZeppelin ERC-4626, SafeERC20, ReentrancyGuard, Ownable2Step, CEI | Kept | Pinned OpenZeppelin v5.4.0. |
| 32 | Read token decimals, never hardcode | Kept | Decimals are checked against an immutable deployment manifest. |
| 33 | Session computed on every call, no keeper needed for correctness | Changed | Rules are enforced on every call, but debt only shrinks when someone submits a repayment or trim. Admission time is recorded by a permissionless refresh. |
| 34 | Foundry unit, fuzz and invariant tests; Slither | Kept | Golden values come from an independent Python calculation. |
| 35 | Contracts under about 300 lines | Changed | No arbitrary line targets; bytecode size checked early. |
| 36 | UI: session badge, countdown, weekend-safe line, admin feed panel | Kept, refocused | Four views. The borrower view answers: what must I repay or add, by when, what happens if I do nothing, and did it execute? |
| 37 | Liquidator bot trims in PRE_CLOSE and bids in REOPEN | Kept | Keeper runs funded buffers first, then liquidator mode with its own USDG. |
| 38 | Weekend walkthrough | Replaced | Spec §5 worked example and the three-outcome demo (buffer, liquidator trim, nobody acts). |
| 39 | Judging-criteria mapping | Changed | Evidence comes from the scenario harness and the testnet run, not from claims. |
| 40 | Build plan and cut order | Dropped | Not part of the product documentation. |
| 41 | Risks: mock feed, harsh trims, illustrative parameters, halts, splits, liquidator exits, admin powers, eligibility | Kept, expanded | Spec §8 failure table. Guardian can stop price-dependent actions; unpausing waits 24 h; no power over prices, escrow or thresholds. |
| 42 | Demo script: fast-forward a weekend, try to borrow on Saturday, Dutch auction on Sunday night | Replaced | Spec §11 three-minute demo; Sunday quotes never count. |

## 3. Factual corrections

| GapGuard statement | Correction |
|---|---|
| A session-aware lending engine for stock tokens does not exist | Several projects in this round handle market closures, including a drop-in Morpho oracle that refuses unsafe prices (StockGuard) and a Morpho layer with a calendar-timed pre-close unwind (Vigil). |
| Morbit is the closest direct competitor | Morbit prices collateral from owner-set values. Closer prior art includes StockGuard and Vigil. |
| The stock price feed exposes `marketStatus` | Not on-chain. The Robinhood Chain feeds are AggregatorV3 (`answer`, `updatedAt`); session status must come from a calendar. |
| The feed freezes at 8 p.m. Friday | 8 p.m. ET is the latest it stops; the first print after a weekend arrives Sunday evening in the thin overnight session (*research*). StockReef waits for the regular open. |
| Edel Finance lost $403K by pricing a tokenized Google wrapper from its share rate | Reported as a manipulation of a wrapper rate rather than a stale stock oracle (*research*). Not used. |
| Robinhood stock tokens are available on testnet via the Robinhood faucet; USDG via Paxos | Correct for the faucet tokens and Paxos USDG on chain 46630; Chainlink stock feeds are mainnet-only, so the testnet uses a labelled mock feed. |
