# StockReef: pitch and demo video script

Two recordings from one app session:

- **Pitch** (about 2 minutes): the problem, the idea, and the seven controls, with app footage.
- **Demo** (about 4½ minutes): one TSLA-backed loan carried from Friday 13:00 to Monday 09:45, with real wallet signatures and explorer receipts.

The figures below come from a full rehearsal on a fork of the chain 46630 deployment, using the public borrower: 0.25 TSLA of collateral, about 72.08 USDG of debt, and a 7 USDG funded buffer. Interest moves the debt slightly from day to day, so read the numbers off the screen rather than from this page.

## What is scripted and what is live

| Scripted (lib/script.ts) | Live (the deployed contracts) |
|---|---|
| One market: TSLA collateral, USDG loans | Account and market balances, buffer escrow and plan |
| The TSLA path: 400.00 → 398.40 → 397.80 → 397.20, then reopening at 376.00 → 377.10 | Collateral value (`PriceGate.valueOf`) and LTV |
| Seven session steps, advanced with **Next step** or the → key | Threshold, borrow limit, target and bonus (`SessionRiskPolicy.ltAt`, `borrowLimit`, constants) |
| The funded public accounts (borrower, lender, liquidator) | Trim and buffer amounts (`StockReefMarket.quoteTrim`, `RepaymentEscrow.executableAmount`) |
| The reopening price, 376.00 | Admission and recovery timing, from the gate's rules and, once aligned, `PriceGate.refresh` |
| Fixed chart observations matching those prices | Wallet connection, signing, confirmations and Blockscout receipts on the chart |

At any aligned step, `scripts/check-scenario.ts` checks the scripted view against the deployed Lens field by field. At Monday 09:35 every field matched: phase, threshold, admission and credit times, permissions, value, LTV, repayment, trim and buffer amounts.

## Before recording

1. **Contracts verified.** Run `bash ops/verify-46630.sh` once from a full checkout. With verified source, MetaMask and Blockscout show the contract names and calls.
2. **Testnet on the script.** From `app/`, with the role keys in the ignored `.env.roles`:
   ```bash
   npx tsx scripts/demo.ts prepare      # Friday 09:35 admission, Friday 13:00 at 400.00, borrower plan re-authorized
   npx tsx scripts/demo.ts status       # check: state 0 (open), price fresh, buffer 7 USDG, target 65%
   ```
3. **Price kept fresh.** The gate accepts a price for 120 seconds. Leave this running in a second terminal during each take:
   ```bash
   npx tsx scripts/demo.ts price --watch
   ```
4. **MetaMask.** Import the public borrower account, add Robinhood Chain Testnet (46630), and have a little testnet ETH for gas. Every approval asks for the exact amount of the action. The app checks each transaction against the chain before MetaMask opens.
5. **Browser.** 1440×900 or larger, zoom 100%. Open `/trade?step=open`. Press **H** to hide the session bar when you want a clean frame; use → and ← to move between steps.

To show the scripted session without signing anything, skip steps 2–4: every page still renders from the contracts at the scripted time and price. Signing then fails its testnet check and shows the contract's reason.

---

## Part 1: Pitch (≈ 2:00)

| Time | Screen | Voice-over |
|---|---|---|
| 0:00 | Landing page, coral logo | "Tokenized stocks trade around the clock on-chain. The stock market doesn't. Every Friday at four, the price stops, and on Monday it can open somewhere else entirely." |
| 0:12 | `/markets/tsla`, Friday + reopening chart: the line ends at 397.20, the weekend band, then 376.00 | "That gap is where stock-backed lending breaks. A loan that's fine on Friday can be under water on Monday, and there's nothing anyone can do in between." |
| 0:25 | `/trade` at Fri 13:00, LTV chart | "Most protocols answer with a borrowing lock. That stops a loan getting bigger over the weekend. It doesn't make the existing debt any smaller." |
| 0:35 | Step → 15:15; amber threshold line falling | "StockReef moves the decision forward. Two hours before the close, the liquidation threshold starts to fall toward a weekend limit, so risk is reduced while there's still a usable price." |
| 0:50 | Tiles: Before the close · Falling threshold · Funded buffer · Partial liquidation | "The borrower sees an amount and a deadline: repay this, or add that much TSLA, by 15:30. A funded buffer can do it automatically. If it doesn't, a liquidator can trim part of the loan, not close the whole position." |
| 1:10 | Step → 16:00, Protection & reopening tab | "While the market is closed, new credit is locked and price-dependent actions pause. Repaying and adding collateral still work." |
| 1:20 | Step → Mon 09:31 → 09:35 | "On Monday, nothing runs on a fresh price until it's admitted, five minutes after the open. Then a recovery window, and only then does credit return." |
| 1:35 | `/earn`, slide the what-if price down to 250 | "Lenders hold shares valued at what each loan can actually recover, so a shortfall shows up in share value before collateral runs out." |
| 1:48 | `/evidence` | "It's live on Robinhood Chain testnet with Paxos USDG and TSLA, backed by 535 tests and invariants. StockReef: controlled risk for stock-backed lending." |

---

## Part 2: Demo (≈ 4:30)

The demo follows one loan through one weekend. Each beat names the step, what to show, what to say, and the number to point at.

### Beat 1: the position at Friday 13:00 · *Open* (0:00–0:40)

**Screen.** `/trade?step=open`. Show the market bar, then the four tiles, then the chart in **LTV** mode.

**Say.** "This is the StockReef terminal: one TSLA/USDG market. The price and the clock follow the script; everything else comes from the deployed contracts. This borrower has 0.25 TSLA against about 72 USDG of debt: 72% LTV against an 80% threshold. That's healthy for an ordinary afternoon."

**Point at.** The amber line: flat at 80% now, already scheduled to fall from 14:00 to the 70% weekend limit by 15:30. The *Before the close* tile already shows the repayment that reaches the 65% weekend target.

### Beat 2: the falling threshold · *Preparation*, Fri 15:15 (0:40–1:30)

**Do.** Press **Next step**.

**Say.** "15:15. The threshold has fallen to 71.67% and keeps falling. Our 72.37% LTV is now above it, so the loan is eligible for a partial liquidation. The terminal turns that into an instruction: repay 7.34 USDG, or add 0.0284 TSLA, by 15:30."

**Point at.**
- Market bar: *Borrowing stops 15:30 · in 00:15*; the borrow limit has fallen to 66.66%.
- *Partial liquidation* tile: **Eligible · 21.79 USDG**, 0.05579 TSLA at a 2% bonus, **buffer first**.
- Open the **Partial liquidation** tab: debt reduction, collateral taken, bonus, and the resulting position at 65%.

**Say.** "If nothing changed, a liquidator could repay 21.79 USDG and take TSLA at a 2% bonus. But this borrower funded a buffer, and a funded buffer always runs first."

### Beat 3: funded buffer, signed live (1:30–2:30)

**Screen.** **Funded buffer** tab: funded 7.00 USDG, 65% target authorization, 7.00 cap, 7.00 executable.

**Do.** Connect MetaMask with any funded wallet. In the *Execute the plan* card, click **Run buffer · 7.00 USDG**. Note the *Testnet check passed* line, sign in MetaMask, and wait for **Confirmed on chain · receipt**.

**Say.** "Anyone can execute a funded plan. Usually it's our keeper; here I'll do it myself. No stock is sold and no bonus is paid. The borrower's own USDG repays the debt."

**Point at.**
- The chart: the blue LTV line drops from 72.3% to **65.3%** under the threshold at the **Buffer repaid 7.00** marker.
- The *Funded buffer* tile now reads **Repaid 7.00 USDG**, with a receipt link. Click it to show Blockscout.
- *Partial liquidation*: **Not eligible**.

### Beat 4: a borrower action with review (2:30–3:05) · optional

**Do.** In the ticket, choose **Repay** and click the *To 65% plan* fill. Read the **Review before signing** panel, then sign.

**Say.** "Every borrower action is reviewed before signing: debt, LTV, the threshold now, the plan target, and whether the loan stays out of liquidation. The approval is for this exact amount, never unlimited."

**Point at.** *Approve exactly … USDG for this action, not an unlimited allowance*, then the second marker on the chart.

### Beat 5: closed-session protection · *Final window* → *Closed* (3:05–3:35)

**Do.** **Next step** twice (15:30, then 16:00). Open **Protection & reopening**.

**Say.** "From 15:30 no new borrowing. At 16:00 the market closes. Borrowing and withdrawing collateral against debt are locked. Buffers and trims pause because there's no usable price. Repaying and adding collateral stay open. The loan can only get smaller."

**Point at.** The action matrix: *Repay USDG* and *Add TSLA collateral* available; borrowing, withdrawals against debt, buffer execution, trims and lender moves locked. The *Before the close* tile: **Entered the closure on plan**.

### Beat 6: controlled reopening · Mon 09:31 → 09:35 → 09:45 (3:35–4:15)

**Do.** **Next step** (09:31).

**Say.** "Monday. TSLA opens about 5% lower at 376. The quote is fresh, but nothing price-dependent runs on it until it has been admitted, five minutes after the open. Until then, valuations stay on Friday's last accepted price."

**Do.** **Next step** (09:35).

**Say.** "09:35: the price is admitted. Funded buffers, then recovery trims, may run, and credit stays locked for a ten-minute recovery window. Valued at 376, this loan is at 69.3%: just under the 70% weekend threshold. The buffer on Friday is the reason it isn't being liquidated now."

**Point at.** *Controlled reopening*: fresh price 376.00, admission 09:35, credit returns 09:45, guarded by 10:00. On the chart, the Monday segment sits just under the amber line.

**Do.** **Next step** (09:45). "Recovery complete. Credit returns under normal limits."

### Beat 7: lenders and close (4:15–4:30)

**Do.** Open `/earn`, then drag the what-if price down.

**Say.** "For lenders, each loan counts only at what its collateral can recover, after a 5% recovery allowance. Push the price low enough and the shortfall is recognized in share value right away, before anything is written off. That's StockReef: debt reduced before the close, credit locked through it, and a controlled reopening after it."

---

## Alternate take: the trim path

To show a partial liquidation instead of the buffer, skip Beat 3. At 15:15 or 15:30, switch MetaMask to the public **liquidator** (15 USDG). In **Partial liquidation → Liquidator action**, approve the exact repayment and sign **Trim**. The chart marks **Trimmed**. The remaining loan stays open at the 65% target, and the liquidator receives TSLA at a 2% bonus.

The trim only executes while no executable buffer exists. If the borrower's plan is still authorized and funded, the testnet check reports `BufferPending`.

## If something goes wrong on camera

| Symptom | Cause | Fix |
|---|---|---|
| "The testnet would reject this now: … stale" | The 120-second price window passed | Keep `demo.ts price --watch` running, or as the operator press **Refresh price** in the session bar |
| "…NotAllowedNow" or "…BorrowingClosed" | The testnet clock is not at this step | `npx tsx scripts/demo.ts step <id>`, or **Move testnet to …** in the session bar (operator wallet) |
| "Authorization expired" on the buffer tile | The plan ended before this weekend | `demo.ts prepare` re-authorizes it; or sign **Buffer → Authorize** in the open market |
| "already past …" from `demo.ts step` | The testnet clock never moves backwards | Run `demo.ts prepare`: once the testnet is past this Friday's 13:00 it moves to the next weekend on the calendar, and the app follows it (press **Restart** in the session bar) |
