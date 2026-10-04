# StockReef: pitch and demo video script

Two videos, built the way the Lemma submission videos were:

- **Visuals:** generated, not filmed. App stills are captured with Playwright, and the camera pans and zooms into one labelled element at a time.
- **Sound:** a very light music bed, with a two-voice voice-over (**A** and **B**) recorded on top.
- **Structure:** every section opens with its question on screen, then the answer, one sentence at a time.

| | Pitch | Demo |
|---|---|---|
| Job | The business case | Proof that it works, on chain |
| Questions | Vision, problem, user, product, why now, model, growth, traction, team, ask | The Arbitrum judge's checklist: problem, user, gap, insight, why on chain, the transaction, the state change, a deliberate failure, durability, roadblocks, trade-offs, future |
| Length | About 2:45 | Under 5:00 (HackQuest cap); this script runs about 4:40 |
| Shared | Only the closing line: **StockReef reduces stock-backed debt before the market closes.** | |

**Sentence style.** One flowing sentence of 8 to 16 words per idea, joined with *and*, *so* or *but*. There are no semicolons, colons or dashes. Say numbers aloud, as "seven dollars" or "seventy percent". One sentence is on screen at a time.

---

## Capture

1. **Contracts verified.** Once, from a full checkout: `bash ops/verify-46630.sh`.
2. **Testnet on the script.** From `app/`, with role keys in the ignored `.env.roles`:
   ```bash
   npm run demo -- prepare        # next weekend: Fri 13:00 at 400.00, borrower at 72 USDG debt, 7 USDG buffer at 65%
   npm run demo -- price --watch  # keeps the 120-second price window open; leave it running
   ```
   Step the testnet with the app (oracle pill → **Sync**, operator wallet) or `npm run demo -- step <id>`.
3. **Stills.** Run `npm run capture` (dark) and `THEME=light npm run capture` (light). Each run writes 1600×900 stills at 2× density to `media/stills/<theme>/`, one per page per step. It also writes close-ups of the zoom targets, named `trade-<step>-<element>.png`: before-the-close, threshold, funded-buffer, liquidation, protection, reopening, last-state-change.
4. **Signed moments.** Record these live in a browser with MetaMask, or capture stills after each confirms. They are the buffer run (beat d7) and the stale-oracle rejection (d12). Every approval asks for the exact amount, and a call the contracts would refuse never reaches the wallet.
5. **Theme.** Pick one theme for the whole video. The **Dark / Light** switch is at the bottom of the sidebar.

The rehearsal numbers below come from a full run on a fork of the chain 46630 deployment with the public borrower. Interest moves the debt slightly from day to day, so read the numbers off your own stills before recording.

---

## Part 1: Pitch (≈ 2:45)

Intro, 0:00–0:05, music only: the coral mark draws itself, then "StockReef", then "in ten questions", then the pill "Robinhood Chain · Paxos USDG · TSLA".

| # | Question on screen | Voice | Say | Show |
|---|---|---|---|---|
| Q1 | What's changing? | A | Stocks now live on chain as tokens that you can hold, move and borrow against at any hour. But the stock market still closes every evening and every weekend. | TSLA asset page, then a zoom on "Stock token · Robinhood Chain" |
| Q2 | What's the problem? | A | When the market closes the price stops, and on Monday it can open far away. A loan that was safe on Friday can be underwater before anyone can act. | TSLA chart, Friday + reopening: the line stops at 397.20 and reopens at 376.00 |
| Q3 | Who feels it first? | A | Holders of tokenized stocks who want dollars without selling, and the lenders who fund them. Lenders take the loss when a gap lands on a loan nobody reduced. | Portfolio health card, then the Lend page |
| Q4 | What is StockReef? | B | StockReef is a lending market that reduces stock-backed debt before the close, while a real price still exists. Then it locks new credit through the closure and reopens it carefully. | Terminal at 15:15: the four tiles, then the falling amber line |
| Q5 | Why now, and why Robinhood Chain? | B | Robinhood Chain brings real stock tokens and Paxos USDG to an Arbitrum chain. So the collateral, the dollars and the rules can finally live in one place. | TSLA token card: contract, issuer, price index |
| Q6 | How does it make money? | A | Borrowers pay a fixed rate that flows to lenders. **[Team to confirm the protocol fee before recording.]** | Market pop-up: rate and utilization |
| Q7 | How does it grow? | A | We start with Tesla against USDG and add stocks one market at a time. Every calendar of holidays and early closes is already built into the contracts. | TSLA page session schedule table |
| Q8 | What's real today? | B | StockReef is live on Robinhood Chain testnet with a funded public market. It's backed by five hundred thirty five tests, including fork tests against the real TSLA token and feeds. | Evidence page: 535 · mainnet fork block · 6 contracts |
| Q9 | Who's building it? | B | **[Team names and one line each.]** | Two founder cards |
| Q10 | What do we need? | A | **[The ask, for example Founder House and the path to Robinhood Chain mainnet.]** StockReef reduces stock-backed debt before the market closes. | Ask lines, then the closing line in large type |

Outro, 5 seconds: logo, closing line, `stock-reef.vercel.app` · `github.com/4waan/StockReef`.

---

## Part 2: Demo (≈ 4:40)

Intro, 0:00–0:05: the mark, then "StockReef", then "the demo, in fifteen questions". Pills: "Live on Robinhood Chain testnet 46630" and "Scripted price and clock · live contracts".

### d1 · What's the problem? · A
**Say.** A tokenized stock trades all weekend, but its real price stops on Friday at four. Any loan against it carries the whole weekend gap into Monday.
**Show.** `tsla-admit.png`, Friday + reopening chart. Zoom on the weekend band, then on the drop from 397.20 to 376.00.

### d2 · Who has it? · A
**Say.** Our first user holds TSLA and borrows USDG against it at about seventy two percent. That's healthy on a Friday afternoon, and it's exactly the loan a weekend gap hurts.
**Show.** `trade-open.png`. Zoom on the market bar, then the Position row: 0.25 TSLA, 72.08 USDG debt, 72% LTV.

### d3 · What's missing today? · A
**Say.** Lending markets treat stocks like crypto that never stops trading. A borrowing lock stops a loan from growing over the weekend, but it never makes the debt smaller.
**Show.** Comparison card (built in the video): Fixed-limit market / Borrowing lock / StockReef, with rows "Acts before the close", "Shrinks existing debt" and "Controlled reopening".

### d4 · What's our insight? · A
**Say.** Reduce the debt before the close while a usable price still exists. So the threshold falls through the afternoon, and the borrower sees an amount and a deadline.
**Show.** `trade-open-threshold.png`, then `trade-prep.png`. The amber line falls from 80% to 70%, and the tile reads 71.66% → 70%.

### d5 · Why on chain, why Robinhood Chain? · B
**Say.** A rule a lender can rely on has to be enforced by the contract, not by a server. And Robinhood Chain is where the TSLA token and Paxos USDG already live.
**Show.** TSLA token card (contract link), then the oracle pill pop-up: price, age, "usable for 120 s".

### d6 · What does the borrower see at 15:15? · B
**Say.** At 15:15 the threshold is down to seventy one point seven percent and the loan sits above it. The terminal turns that into one instruction: repay seven dollars thirty four by 15:30.
**Show.** `trade-prep-before-the-close.png` (Repay 7.34), then `trade-prep-liquidation.png` (Eligible · 21.79 · buffer first).

### d7 · Show the transaction · B
**Say.** This borrower funded a repayment buffer in advance, so anyone can execute it now. We run it and sign, and no stock is sold and no bonus is paid.
**Show.** Click the **Funded buffer** tile. The pop-up shows Funded 7.00, Plan 65%, Runs now 7.00, then "✓ Testnet check passed" and **Run buffer · 7.00 USDG**. Sign in MetaMask, then show **Confirmed · receipt** and cut to the Blockscout transaction.

### d8 · Show the state change · B
**Say.** The debt drops from seventy two to sixty five dollars, and the loan moves back under the falling threshold. The receipt is on the chart where it happened.
**Show.** `trade-prep-last-state-change.png`: Debt 72.08 → 65.08, LTV 72.4% → 65.3%. Then the full chart, zoomed on the drop at the **Buffer repaid 7.00** marker. The Liquidation tile now reads **Not eligible**.

### d9 · What if nothing had executed? · B
**Say.** Without the buffer, a liquidator could trim twenty one dollars of debt at a two percent bonus. The loan would stay open, but the borrower would pay for waiting.
**Show.** `trade-prep-liquidation.png` before the buffer ran: Debt cut 21.79, TSLA taken 0.0558, Bonus 2%, LTV after 65.0%.

### d10 · What happens over the weekend? · A
**Say.** From 15:30 no new borrowing, and at four the market closes. Repaying and adding collateral still work, but the loan can only get smaller.
**Show.** `trade-closed-protection.png`. Repay and Add TSLA are available. Borrow, Withdraw, Buffer, Trim and Lend are locked.

### d11 · How does Monday reopen? · B
**Say.** On Monday a fresh price of three seventy six arrives, but nothing runs on it until it's admitted five minutes after the open. Valued at that price this loan sits just under the seventy percent limit, because the buffer already ran.
**Show.** `trade-wait-reopening.png` (Awaiting price), then `trade-admit.png`: Admitted 09:35, Credit 09:45. The Monday LTV line sits just under the amber line at 69.3%.

### d12 · What happens when something goes wrong? · B
**Say.** Here we stop the price feed and try to borrow two minutes later. The contract refuses the stale price, so the wallet never even opens.
**Show.** Monday 09:45, Borrow tab, 1 USDG. The red card reads **Rejected by the contract · NotAllowedNow · Guarded · stock price stale**, and the oracle pill turns red: "stale". (To capture it, stop `price --watch` and wait 2 minutes.)

### d13 · Is it durable? · A
**Say.** Five hundred thirty five tests cover the risky paths, including fork tests on the real TSLA token. And every number in this app matches the contract's own view field by field.
**Show.** Evidence page, then a terminal replay of `npm run check-scenario -- admit`: twenty "same" lines.

### d14 · What roadblocks did we overcome? · B
**Say.** A stale demo price made every screen read zero, so the contracts now value a scripted session directly. And MetaMask warned on unlimited approvals, so every approval is now exact and checked before signing.
**Show.** Two rows, each a red "✗ STUCK" card → arrow → green "✓ WHAT WE DID":
- "Stale oracle, empty screens" → "Contracts value the scripted step" · `lib/scenario.ts`
- "Unlimited approval warning" → "Exact approval + preflight" · `useTx`

### d15 · What did we trade off, and what's next? · A
**Say.** On testnet the operator sets the price and clock, so we can show a weekend on demand. Next we calibrate the limits against real gaps, add more stocks, get audited and launch on Robinhood Chain. StockReef reduces stock-backed debt before the market closes.
**Show.** Card "We chose / So that / Later": operator-set price and clock / show a weekend on demand / live stock feeds, already read in the fork tests. Then a four-phase roadmap (Calibrate thresholds → More stocks → Audit → Robinhood Chain mainnet), and the closing line.

Outro, 5 seconds: the same as the pitch.

---

## If something goes wrong while recording

| What you see | Why | Fix |
|---|---|---|
| Oracle pill amber "not synced" | The testnet clock is not on this step | Oracle pill → **Sync to hh:mm** (operator wallet), or `npm run demo -- step <id>` |
| Oracle pill red "stale" | The 120-second price window passed | Keep `price --watch` running, or oracle pill → **Refresh price** |
| Red "Rejected by the contract" | The contracts would refuse it at the testnet's current state | Read the reason; sync the step or refresh the price |
| Funded buffer tile "Expired" | The plan ended before this weekend | `npm run demo -- prepare` resets and re-authorizes it |
| "already past …" from `demo step` | The testnet clock never moves backwards | `npm run demo -- prepare` moves to the next weekend; press **Restart** in the session bar's ⓘ |
