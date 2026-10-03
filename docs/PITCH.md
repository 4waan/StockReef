# StockReef pitch pack

## One line

**Stock markets close. Loans don't.** StockReef manages stock-backed loans before every market close, with
borrower-funded repayments and partial liquidation, so outstanding debt is reduced while a usable price
still exists.

## 30 seconds

> Stock markets close. Loans don't. A Tesla token trades on-chain all weekend, but the price that matters
> stops at 4 p.m. on Friday, and a 72% loan that was fine at 3:59 meets Monday's gap with nobody able to
> act in between.
>
> StockReef prepares those loans before the bell. Every borrower sees exactly what to repay or add, and
> by when. A buffer they fund in advance repays automatically when preparation starts, and positions still
> over the limit are trimmed by liquidators at the current price. Borrowing stops while the market is closed,
> and credit returns only after a fresh price and a recovery window. Our demo shows the debt actually
> falling before the bell.

## 90 seconds

> Tokenized stocks are 24/7 assets with a 6.5-hour price. Lending markets value them with one threshold
> all week, so they face two problems. The first is new debt against a stale price, and blocking prices
> during the closure fixes that. The second is the debt that already exists. Nobody prepares it for the
> close, so the first moment anyone can act is Monday's open, after the gap, at the full penalty.
>
> StockReef manages that existing debt. Every session has a public schedule. Two hours before the close
> the liquidation threshold starts falling, deeper before weekends and holidays than before an ordinary
> night, and new borrowing tapers off.
>
> The borrower goes first: the app shows the exact repayment, the deadline, and what happens if they do
> nothing. Borrowers who pre-fund a buffer get repaid automatically at preparation start, with no
> penalty, and they keep all their collateral. Loans still over the falling line can be partially trimmed
> by any liquidator, at the current accepted price, back to a published target. That takes a 2% bonus
> instead of the 5% that a recovery after the gap costs. At the close, new borrowing stops. Any loan that
> nobody reduced is flagged with its exact exposure, not hidden behind a health badge.
>
> When the market reopens, a price must be published after the open before anything price-dependent runs.
> A Sunday-evening quote never qualifies. Recovery comes before new credit.
>
> It is built on Robinhood Chain:
> - a calendar of NYSE sessions verified on-chain;
> - Chainlink feeds checked for freshness, issuer pauses and stock-split multipliers;
> - real Paxos USDG on testnet;
> - 535 tests, including a fork of mainnet with the real Tesla token.
>
> Stock markets close. Loans don't. StockReef gets the debt ready before the bell.

## Three-minute demonstration

Setup before recording:
1. Testnet deployment.
2. Positions A, B and C opened by `DemoRun.s.sol` at 1/100 of the worked example.
3. The keeper running in watch mode.
4. One operator wallet connected.
5. The app with `NEXT_PUBLIC_DEMO_ACCOUNTS` set to A, B and C, so they appear in the status bar's scenario picker.

Every step on camera is one click in **Operations → Demo controls** (or **Advance session** in the status bar), which is labelled as simulation.

| Time | On screen | Say |
|---|---|---|
| 0:00 | Trade, scenario B. 72% LTV, OPEN, "RAMP" countdown to 14:00 | "Stock markets close. Loans don't. This Tesla-backed loan is at 72%. It's fine right now, and that's exactly the problem: in a few hours the price stops for a whole weekend." |
| 0:20 | The line under the ticker: "Before the close: repay 7.00 USDG or add 0.0269 TSLA by 15:30 ET" | "StockReef answers four questions. What do I repay or add? By when? What happens if I do nothing? And did it actually happen?" |
| 0:40 | Operations. Click **Preparation start (A)**. Account A's row: buffer executes; Trade → scenario A shows the *AUTO-REPAY* callout on the chart, collateral unchanged | "Two hours before the close, preparation starts. Alice funded a buffer. The keeper repays her to 65% straight away. No penalty, and she keeps every share." |
| 1:10 | Click **45 min before close**. B's row shows *Trim now*; the keeper trims; Trade → scenario B shows the *TRIM* callout and receipt | "Bob didn't prepare. The threshold has fallen past his loan, so a liquidator repays part of his debt at the current price and takes collateral with a 2% bonus. Bob is back at 65% before the bell." |
| 1:40 | Click **Close + 1 h**. State: Market closed. Borrow is disabled. Operations: *Missed execution: 1*. Trade → scenario C shows the missed-execution line with the exposure | "The market closes. New borrowing stops. Carol had no buffer and nobody acted, so StockReef detects it and reports the exact exposure. It doesn't paint a green badge on it." |
| 2:05 | Click **Next open + 1 min** (price −6%), then **+5 min**. State: waiting, then recovery; C's recovery trim lands | "Monday. The first price must be published after the open. Once it's admitted, recovery trims run before anyone can borrow again." |
| 2:30 | Click **+15 min**. State: Open. Evidence view | "Credit returns. Every number here comes from a committed script or test: 535 tests, a fork of mainnet with the real Tesla token, and a scenario harness against fixed-limit lenders." |
| 2:50 | Title card | "Stock markets close. Loans don't. StockReef." |

## Likely questions

**What if nobody runs the keeper?**
The rules are enforced on every call. Buffers are permissionless with no reward, and anyone with USDG can
trim. If nobody acts, the close still blocks borrowing and the loan is reported as missed execution with
its exposure.

**What if no liquidator shows up?**
Then there is no trim. That is why the buffer exists and why the plan is shown hours before the close. We
do not promise a buyer.

**Why not just pause the oracle while the market is closed?**
A pause prevents new debt at a stale price. It does nothing for debt already outstanding, which meets the
gap at the full penalty. StockReef handles the existing debt while a usable price still exists.

**Doesn't a falling threshold just liquidate people more often?**
Only above the published line, and only partially, back to a target. Ordinary weeknights use a shallow
ramp (77%), so a 75% loan is never trimmed on a Tuesday. The deep ramp (70%) applies before weekends and
holidays. The scenario harness shows the cost: one 2% trim a week for a borrower who re-borrows to 75%
every day.

**Where do the numbers come from?**
They are illustrative fixtures from the specification, not calibrated limits. Calibration against
historical gaps is the next milestone.

**Why only 32 borrowers?**
It keeps the lender valuation bounded and fully tested: every withdrawal marks every loan to what its
collateral can recover. We measured the gas at the cap.

**What's real on testnet?**
The real Paxos USDG and the faucet TSLA token. Chainlink stock feeds exist only on mainnet, so on testnet
the price and the clock are a labelled simulation driven by one operator. On mainnet, the fork suite runs
the same contracts against the real Tesla token and feeds.

## Never say

- "Every loan is ready."
- "No one needs to execute."
- "Zero risk."
- "Guaranteed profitable liquidation."
- "Guaranteed higher capital efficiency."
- "Production-safe thresholds."
- "Plug-and-play on existing Morpho markets."
