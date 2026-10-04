# StockReef: pitch and demo video script

Two videos, built the way the Lemma submission videos were:

- **Visuals:** generated, not filmed. App stills are captured with Playwright, and the camera pans and zooms into one labelled element at a time.
- **Sound:** a very light music bed, with a two-voice voice-over recorded on top: **Aryan Singh Rathore** and **Awaan Mustafa Siddiqui**, co-founders. As in the Lemma videos, Aryan opens with the problem and the business case, and Awaan carries the product and the proof.
- **Structure:** every section opens with its question on screen, then the answer, one sentence at a time.

| | Pitch | Demo |
|---|---|---|
| Job | The business case | Proof that it works, on chain |
| Questions | Vision, problem, user, product, why now, model, growth, traction, team, ask | The Arbitrum judge's checklist: problem, user, gap, insight, why on chain, the transaction, the state change, a deliberate failure, durability, roadblocks, trade-offs, future |
| Length | 2:56 | Under 5:00 (HackQuest cap); this script runs 4:37 |
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
4. **Signed moments.** Record these live in a browser with MetaMask, or capture stills after each confirms. They are the buffer run (beat d7) and the stale-oracle rejection (d13). Every approval asks for the exact amount, and a call the contracts would refuse never reaches the wallet.
5. **Theme.** Both videos use the light theme throughout: graphics and app captures alike. The **Dark / Light** switch is at the bottom of the sidebar, and `media/videos/capture/pages.mjs` captures in light by default.

The rehearsal numbers below come from a full run on a fork of the chain 46630 deployment with the public borrower. Interest moves the debt slightly from day to day, so read the numbers off your own stills before recording.

---

## Part 1: Pitch (≈ 2:45)

Intro, 0:00–0:05, music only: the coral mark draws itself, then "StockReef", then "in ten questions", then the pill "Robinhood Chain · Paxos USDG · TSLA".

| # | Question on screen | Voice | Say | Show |
|---|---|---|---|---|
| Q1 | What's changing? | Aryan | Stocks now live on chain as tokens you can hold and borrow against at any hour. But the stock market behind them still closes every evening and every weekend. | TSLA asset page, then a zoom on "Stock token · Robinhood Chain" |
| Q2 | What's the problem? | Aryan | About a third of Tesla's price movement happens while its market is closed. Over five years it opened at least five percent away from Friday's close on one Monday in sixteen. | TSLA chart, Friday + reopening. Two stat cards: "33% of TSLA price variance happens while the market is closed" and "1 in 16 Mondays opens ≥ 5% from Friday's close". Caption: Yahoo Finance daily data, Oct 2021 to Oct 2026 |
| Q3 | Who feels it first? | Aryan | Holders of tokenized stocks who want dollars without selling, and the lenders who fund them. To stay safe through closures, lenders today keep stock loans at about half the collateral or less. | Portfolio health card, then the Lend page |
| Q4 | What is StockReef? | Awaan | StockReef lends up to seventy five percent and reduces the debt before the close, while a real price still exists. Then it locks new credit through the closure and reopens it carefully. | Terminal at 15:15: the four tiles, then the falling amber line |
| Q5 | Why now, and why Robinhood Chain? | Awaan | Robinhood Chain went live on mainnet in July with stock tokens and USDG side by side. Tokenized stocks have passed three billion dollars, but lending against them is still tiny. | TSLA token card. Stat cards: "Robinhood Chain mainnet · 1 Jul 2026", "$3.21B tokenized stocks", "≈$53M stock lending on Solana, the busiest market" |
| Q6 | How does it make money? | Aryan | Lenders earn the borrower's fixed rate, and StockReef will keep ten percent of that interest. It also keeps ten percent of each liquidation bonus, the same shares Aave takes. And the vault's USDG can earn Global Dollar partner rewards on top. | Card with three rows: "10% of borrower interest" (Aave USDC 10%), "10% of each liquidation bonus" (Aave WETH and WBTC 10%), "USDG partner rewards" (upside, terms by agreement). Then the Market pop-up: rate and utilization |
| Q7 | How does it grow? | Aryan | We start with Tesla against USDG and add stocks one market at a time. Every closure on the exchange calendar, holidays and early closes included, is already in the contracts. | TSLA page session schedule table |
| Q8 | What's real today? | Awaan | StockReef runs on Robinhood Chain testnet with a funded public market and real receipts. It's backed by five hundred thirty five tests, including fork tests against the live TSLA token. | Evidence page: 535 · mainnet fork block · 6 contracts |
| Q9 | Who's building it? | Awaan | Aryan and I built StockReef during this buildathon, from the contracts to the app. | Two founder cards: "Aryan Singh Rathore · Co-founder" and "Awaan Mustafa Siddiqui · Co-founder". Pill: "First commit 1 Oct 2026" |
| Q10 | What do we need? | Aryan | At Founder House we want an audit and our first lenders on Robinhood Chain mainnet. We also want a market maker for TSLA and a Global Dollar partnership for the vault. StockReef reduces stock-backed debt before the market closes. | Three ask lines tick in, then the closing line in large type |

Outro, 5 seconds: logo, closing line, `stock-reef.vercel.app` · `github.com/4waan/StockReef` · "Aryan Singh Rathore · Awaan Mustafa Siddiqui".

---

## Part 2: Demo (4:37)

Intro, 0:00–0:09: the **landing page** (stock-reef.vercel.app) in a browser frame. The camera starts on the hero, "Controlled risk for stock-backed lending.", and then pans down to "How StockReef controls risk" and its three phase cards. Above it are the mark and "the demo, in sixteen questions", plus the pills "Live contracts · Robinhood Chain testnet 46630" and "Scripted price and clock".

**Every core feature is on screen.** A strip under the progress dots names the feature each answer shows and ticks it off: 1 debt reduced before the close (d4, d6), 2 falling threshold (d4), 3 funded repayment buffer (d7, d8), 4 partial liquidation (d9), 5 closed-session protection (d10), 6 controlled reopening (d11), 7 lender loss accounting (d12). It reads 7/7 by d12.

### d1 · What's the problem? · Aryan
**Say.** A tokenized stock trades all weekend, but its real price stops on Friday at four. Over five years Tesla opened at least five percent away from Friday's close on one Monday in sixteen.
**Show.** `tsla-admit.png`, Friday + reopening chart. Zoom on the weekend band, then on the drop from 397.20 to 376.00.

### d2 · Who has it? · Aryan
**Say.** Our first user holds Tesla and borrows USDG against it at about seventy two percent. That's healthy on a Friday afternoon, and it's exactly the loan a weekend gap hurts.
**Show.** `trade-open.png`. Zoom on the market bar, then the Position row: 0.25 TSLA, 72.08 USDG debt, 72% LTV.

### d3 · What's missing today? · Aryan
**Say.** Lending markets treat stocks like crypto that never stops trading. A borrowing lock stops a loan from growing over the weekend, but it never makes the debt smaller.
**Show.** Comparison card (built in the video): Fixed-limit market / Borrowing lock / StockReef, with rows "Acts before the close", "Shrinks existing debt" and "Controlled reopening".

### d4 · What's our insight? · Aryan
**Say.** Reduce the debt before the close, while a usable price still exists. So the threshold falls through the afternoon, and the borrower sees an amount and a deadline.
**Show.** `trade-open-threshold.png`, then `trade-prep.png`. The amber line falls from 80% to 70%, and the tile reads 71.66% → 70%.

### d5 · Why on chain, why Robinhood Chain? · Awaan
**Say.** A rule a lender can rely on has to be enforced by the contract, not by a server. And Robinhood Chain is where the Tesla token and Paxos USDG already live.
**Show.** TSLA token card (contract link), then the oracle pill pop-up: price, age, "usable for 120 s".

### d6 · What does the borrower see at 15:15? · Awaan
**Say.** At 15:15 the threshold is down to seventy one point seven percent, and the loan sits just above it. The terminal turns that into one instruction, repay seven dollars thirty four by 15:30.
**Show.** `trade-prep-before-the-close.png` (Repay 7.34), then `trade-prep-liquidation.png` (Eligible · 21.79 · buffer first).

### d7 · Show the transaction · Awaan
**Say.** This borrower funded a repayment buffer in advance, so anyone can execute it now. We run it and sign, and no stock is sold and no bonus is paid.
**Show.** Click the **Funded buffer** tile. The pop-up shows Funded 7.00, Plan 65%, Runs now 7.00, then "✓ Testnet check passed" and **Run buffer · 7.00 USDG**. Sign in MetaMask, then show **Confirmed · receipt** and cut to the Blockscout transaction.

### d8 · Show the state change · Awaan
**Say.** The debt drops from seventy two to sixty five dollars, and the loan moves back under the falling threshold. The receipt sits on the chart where it happened.
**Show.** `trade-prep-last-state-change.png`: Debt 72.08 → 65.08, LTV 72.4% → 65.3%. Then the full chart, zoomed on the drop at the **Buffer repaid 7.00** marker. The Liquidation tile now reads **Not eligible**.

### d9 · What if nothing had executed? · Awaan
**Say.** Without the buffer, a liquidator could trim twenty one dollars of debt at a two percent bonus. The loan stays open, but the borrower pays for waiting.
**Show.** `trade-prep-liquidation.png` before the buffer ran: Debt cut 21.79, TSLA taken 0.0558, Bonus 2%, LTV after 65.0%.

### d10 · What happens over the weekend? · Aryan
**Say.** From 15:30 there's no new borrowing, and at four the market closes. Repaying and adding collateral still work, but the loan can only get smaller.
**Show.** `trade-closed-protection.png`. Repay and Add TSLA are available. Borrow, Withdraw, Buffer, Trim and Lend are locked.

### d11 · How does Monday reopen? · Awaan
**Say.** On Monday a fresh price of three seventy six arrives, but nothing runs on it until it's admitted five minutes after the open. Valued at that price this loan sits just under the seventy percent limit, because the buffer already ran.
**Show.** `trade-wait-reopening.png` (Awaiting price), then `trade-admit.png`: Admitted 09:35, Credit 09:45. The Monday LTV line sits just under the amber line at 69.3%.

### d12 · Who carries a loss? · Aryan
**Say.** Lenders see every loan valued at what it can actually recover. If Tesla fell to two twenty, this loan would leave a twelve dollar shortfall, and share value would drop to eighty five cents, so no lender can exit ahead of the loss.
**Show.** Lend page at Monday 09:35. The **Lender loss accounting** panel reads Recoverable 85.13, Shortfall 0.00, Fully covered. Then the what-if TSLA slider moves to 220: Recoverable 72.38, Shortfall 12.75 (0.25 TSLA after the 5% recovery bonus covers 52.38 of the 65.13 debt), share value 1.0016 → 0.8515.

### d13 · What happens when something goes wrong? · Awaan
**Say.** Here the price feed stops, and we try to borrow two minutes later. The contract refuses the stale price, so the wallet never even opens.
**Show.** Monday 09:45, Borrow tab, 1 USDG. The red card reads **Rejected by the contract · NotAllowedNow · Guarded · stock price stale**, and the oracle pill turns red: "stale". (To capture it, stop `price --watch` and wait 2 minutes.)

### d14 · Is it durable? · Aryan
**Say.** Five hundred thirty five tests cover the risky paths, including fork tests on the real Tesla token. And every number in this app matches the contract's own view, field by field.
**Show.** Evidence page, then a terminal replay of `npm run check-scenario -- admit`: twenty "same" lines.

### d15 · What roadblocks did we overcome? · Awaan
**Say.** A stale demo price made every screen read zero, so the contracts now value a scripted session directly. And MetaMask warned on unlimited approvals, so every approval is now exact and checked before signing.
**Show.** Two rows, each a red "✗ STUCK" card → arrow → green "✓ WHAT WE DID":
- "Stale oracle, empty screens" → "Contracts value the scripted step" · `lib/scenario.ts`
- "Unlimited approval warning" → "Exact approval + preflight" · `useTx`

### d16 · What did we trade off, and what's next? · Aryan
**Say.** On testnet the operator sets the price and clock, so we can show a weekend on demand. Next we calibrate the limits against real gaps and add more stocks, then get audited and launch on Robinhood Chain mainnet. StockReef reduces stock-backed debt before the market closes.
**Show.** Card "We chose / So that / Later": operator-set price and clock / show a weekend on demand / live stock feeds, already read in the fork tests. Then a four-phase roadmap: Calibrate thresholds against real gaps → More stocks → Audit → Robinhood Chain mainnet, with fees switched on (10% of interest and of liquidation bonuses). Then the closing line.

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

---

## Sources for the pitch numbers

These were checked on 4 Oct 2026. Read each figure off the source again on recording day.

**TSLA gaps**
- Yahoo Finance daily TSLA data, 2,955 sessions from 2 Jan 2015 to 2 Oct 2026, split-adjusted. Gap = open ÷ previous close − 1.
- Last five years (275 weekend or holiday closures, 225 of them Friday to Monday):
  - 14 of 225 Mondays opened at least 5% from Friday's close (6.2%, about 1 in 16). After ordinary weeknights the rate was 3.3%.
  - 33% of daily price variance came from the market-closed periods.
- Breaches at the reopen, from the same data:
  - A 72% loan passes 80% after a down-gap of more than 10%. That happened on 1 of 275 closures (5 Aug 2024, −10.8%).
  - At the 75% maximum it needs more than 6.25%, which happened on 3 of 275.
  - The worst weekend gap since 2015 was −14.9% (8 Sep 2020).

**Market**
- Tokenized stocks: $3.21B distributed value, from https://app.rwa.xyz/stocks (4 Oct 2026).
- Stock lending on Solana: an all-time high of about $53M, with Kamino at $31M, from https://solanacompass.com/news/kamino-lend-holds-826-of-solanas-tokenized-stock-lending-market-at-53m (11 Aug 2026).
- Kamino xStocks max LTV of about 35–50%. This comes from a secondary source, https://www.onchaintimes.com/stocks-arriving-on-chain/, so treat it as indicative.
- Robinhood Chain mainnet on 1 Jul 2026, with lending through Morpho and USDG liquidity, from https://forum.arbitrum.foundation/t/arbitrumdao-factsheet-robinhood-chain-mainnet-launch/31041 (6 Jul 2026).

**Fees**
- Aave v3 Ethereum, read on-chain on 4 Oct 2026:
  - reserve factor 10% on USDC and 15% on WETH;
  - liquidation protocol fee 10% on WETH and WBTC, 20% on USDC.
- Euler v2 default interest fee 10%, from https://docs.euler.finance/concepts/financial/interest-rates/.
- Morpho fee switch capped at 25%, not switched on, from https://docs.morpho.org/learn/governance/organization/.
- USDG Global Dollar Network partners receive up to 100% of reserve rewards, on terms set by agreement, from https://globaldollar.com/newsroom/150-partners (21 Jul 2026).

**Founder House Singapore**
- 23–25 Oct 2026, up to $300K in USDG.
- The prizes include a $60K Robinhood Chain Founder-in-Residence and a $30K Robinhood Chain Innovation Award.
- Winners join an 8-week mentorship with Robinhood Chain.
- Source: https://blog.arbitrum.foundation/founder-house-singapore-apply-now-to-launch-products-on-arbitrum-one-robinhood-chain/

The fees are a plan: the deployed contracts send all interest to lenders today. The pitch says "will" for that reason.
