# StockReef: pitch and demo video script

Two videos, both in StockReef's light theme on a burnt orange grid, with original music (`media/videos/scripts/music.mjs`: a closing bell, a countdown clock and a confirmation chime cued to the picture).

- **Pitch:** a generated explainer, one question per section, with app captures and real market data.
- **Demo:** one continuous run of the deployed app on the public Robinhood Chain testnet, driven with a visible cursor. Real wallets sign real transactions, and the receipts open on the Robinhood Chain explorer. Chapter titles name what is happening rather than asking questions.
- **Voices:** **Aryan Singh Rathore** carries the problem, the market and the business; **Awaan Mustafa Siddiqui** carries the product and the proof.

| | Pitch | Demo |
|---|---|---|
| Job | The business case | Proof that it works, on chain |
| Sections | Vision, what breaks at the close, user, product, why now, RWA lending gap and fix, model, growth, traction, team, Open House Singapore plan, ask | The landing page, the problem, the market today (real data), the live loan book, the countdown, a funded repayment and its state change, a partial trim, the weekend and Monday, lender protection, a deliberate failure, the test run, next for StockReef |
| Length | 3:33 | Under 5:00 (HackQuest cap); this cut runs 4:42.2 |
| Shared | Only the closing line: **StockReef reduces stock-backed debt before the market closes.** | |

**Sentence style.** One flowing sentence of 8 to 16 words per idea, joined with *and*, *so* or *but*. There are no semicolons, colons or dashes. Say numbers aloud, as "seven dollars" or "seventy percent". One sentence is on screen at a time.

---

## Capture

1. **Keys.** `OPERATOR_KEY`, `BORROWER_KEY` and `LIQUIDATOR_KEY` in the ignored `.env.roles` at the repository root. `capture/book-live.sh` appends keys for the book accounts it creates (Treasury, Ava, Ben, Cleo) to the same file.
2. **Testnet weekend.** From `app/`: `npx tsx scripts/demo.ts prepare` (Friday 13:00 at 400.00, borrower at 72 USDG with a funded 7 USDG buffer), then `bash ../media/videos/capture/book-live.sh` for the rest of the book.
3. **Record.** From `media/videos/`: `NODE_USE_ENV_PROXY=1 node capture/record.mjs` records the chapters in order against stock-reef.vercel.app, stepping the testnet between them (prep, closed, wait, admit, credit). It signs in the browser with the role keys, waits 150 s without a price before the failure chapter, and writes `public/rec/<clip>/`. Then run `node capture/build-clips.mjs`.
4. **Cut.** `demo.json` lists each chapter's clip slices (speed-ups only over block waits and page loads), the address bar and the narration; `npm run render:demo` builds the timeline and music and renders.
5. **The clock only moves forward.** A failed take needs `prepare` again, which moves to the next weekend in the calendar.

---

## Part 1: Pitch (3:33)

Intro, 0:00–0:05, music only: the coral mark draws itself, then "StockReef", then "in twelve questions", then the pill "Robinhood Chain · Paxos USDG · TSLA".

No calendar dates appear on screen or in the narration. "RWA" is used throughout. Q6 explains why RWA lending is small and how StockReef fixes it, and Q11 is the Open House Singapore plan.

| # | Question on screen | Voice | Say | Show |
|---|---|---|---|---|
| Q1 | What's changing? | Aryan | Stocks now live on chain as real-world asset tokens, RWAs you can hold and borrow against at any hour. But the stock market behind them still closes every evening and every weekend. I'm Aryan, co-founder of StockReef. | Headline "Stock RWAs live on chain. The market still closes." A week timeline: the TSLA RWA token trades every hour, while Nasdaq opens only on weekday sessions and is "Closed all weekend". Pill: Aryan Singh Rathore · Co-founder |
| Q2 | What breaks when Wall Street closes? | Aryan | When Nasdaq closes on Friday, Tesla's real price stops until Monday, but every loan backed by Tesla tokens stays open. One Monday in sixteen opens five percent or more away from Friday, so a loan can be underwater before anyone is able to act. | Real TSLA daily candles around one weekend gap: "−10.8% at Monday's open" (Fri close 207.67 → Mon open 185.22). Stat cards "65.5 hours" without a real price and "1 in 16". Source line: Yahoo Finance daily data, last five years |
| Q3 | Who feels it first? | Aryan | Holders of stock RWAs who want dollars without selling, and the lenders who fund them. To stay safe through closures, lenders keep loans at about half the collateral or less. | Cards "Holders · Own stock RWAs" and "Lenders · Supply USDG". A bar: "How much you can borrow against a stock RWA today", at about half the collateral or less |
| Q4 | What is StockReef? | Awaan | I'm Awaan. StockReef lends up to seventy five percent against stock RWAs, and cuts the debt before the close while a real price exists. Then it locks new credit through the closure and reopens it carefully. | Terminal at 15:15: the tiles and the falling threshold, then the buffer cutting debt 72 → 65 USDG. Cards: "Lends up to 75%" and three steps. Pill: Awaan Mustafa Siddiqui · Co-founder |
| Q5 | Why now, and why Robinhood Chain? | Awaan | Robinhood Chain is now live on mainnet with stock RWAs and USDG side by side. Tokenized stocks have passed three billion dollars, but lending against these RWAs is still tiny. | Cards "Robinhood Chain · Mainnet live · an Arbitrum chain" and "Side by side: Stock RWAs · USDG by Paxos". Bars: tokenized stock RWAs $3.21B against ≈$53M of lending in the busiest market. Sources: rwa.xyz · Solana Compass |
| Q6 | Why is RWA lending so small, and how do we fix it? | Awaan | RWA lending stays small because no lender can price the weekend gap. StockReef turns that gap into rules the contract enforces before every close, on chain. So lenders can safely offer up to seventy five percent, and a stock RWA becomes collateral worth borrowing against. | "Today: no lender can price the weekend gap" against "With StockReef: rules the contract enforces before every close", with four rule pills (falling threshold, funded repayment buffer, credit locked while closed, reopen on a fresh price). Bars "Credit from $100 of TSLA RWA": $50 today → $75 with StockReef. Pill: "+50% more credit from the same RWA" |
| Q7 | How does it make money? | Aryan | Lenders earn the borrower's fixed rate, and StockReef keeps ten percent of that interest. It also keeps ten percent of each liquidation bonus, the same shares Aave takes. Vault USDG can also earn Global Dollar rewards. | Two fee bars: 10% of borrower interest (Aave USDC reserve factor 10%) and 10% of each liquidation bonus (Aave WETH/WBTC 10%). Pill: USDG partner rewards, as upside |
| Q8 | How does it grow? | Aryan | We start with Tesla against USDG and add stock RWAs one market at a time. Every closure on the exchange calendar, holidays and early closes included, is already in the contracts. | The TSLA / USDG tile, then "next stock RWA" tiles. Calendar cards: weekends, holidays, early closes. Pill: "587 market sessions already loaded in the deployed SessionCalendar" |
| Q9 | What's real today? | Awaan | StockReef runs on Robinhood Chain testnet with a funded public market and real receipts. It's backed by five hundred thirty five tests, including fork tests against the live TSLA token. | Evidence page: deployment on 46630, 535 tests, mainnet fork block |
| Q10 | Who's building it? | Awaan | Aryan and I built StockReef during this buildathon, from the contracts to the app. | Two founder cards. Pills: Contracts · Keeper · App · Built during the buildathon |
| Q11 | What will we do at Open House Singapore? | Aryan | At Open House Singapore we'll launch on Robinhood Chain mainnet with a capped Tesla market and our first lenders. We'll run a live Friday close with RWA holders in the room, and tune the thresholds with the Robinhood Chain team. | "Open House Singapore · Founder House week" with four plan cards: 01 Launch on Robinhood Chain mainnet (a capped TSLA / USDG market), 02 Seed our first lenders, 03 Show a live Friday close with RWA holders in the room, 04 Tune the thresholds with the Robinhood Chain team |
| Q12 | What do we need? | Aryan | We need an audit and a market maker for Tesla, and a Global Dollar partnership for the vault. StockReef reduces stock-backed debt before the market closes. | "To launch on mainnet": an audit, a market maker for TSLA, and a Global Dollar partnership tick in. Then the closing line in large type |

Outro, 5 seconds: logo, closing line, `stock-reef.vercel.app` · `github.com/4waan/StockReef` · "Aryan Singh Rathore · Awaan Mustafa Siddiqui".

---

## Part 2: Demo (4:42.2)

A continuous recording of the deployed app on the **public Robinhood Chain testnet**, driven with a visible cursor (media/videos/capture/record.mjs). Every transaction in it was signed in the app and confirmed on chain; the hashes and explorer links are in [evidence/demo-live-46630.json](../evidence/demo-live-46630.json). Only waits for blocks and page loads are sped up or cut.

A strip at the top right ticks off the seven core features as each is shown: 1 debt reduced before the close and 2 falling threshold (chapter 05), 3 funded repayment buffer (06), 4 partial liquidation (07), 5 closed-session protection and 6 controlled reopening (08), 7 lender loss accounting (09).

| # | Chapter | Time | Voice | Say | Show |
|---|---|---|---|---|---|
| 01 | StockReef, live on Robinhood Chain testnet | 0:00.0–0:16.7 | Aryan | This is StockReef, live on Robinhood Chain testnet. It lets you borrow dollars against tokenized Tesla stock, and it manages the moment other lenders ignore, when the stock market closes for the weekend. | The real landing page at stock-reef.vercel.app: hero, a scroll to "How StockReef controls risk", then **Borrow against TSLA** opens the app. |
| 02 | What breaks when Wall Street closes | 0:16.7–0:32.3 | Aryan | Tesla's token trades all weekend, but its real price stops at four on Friday. One Monday in sixteen opens five percent or more away, and a loan can't react in between. | The TSLA page on the live testnet: the chart with Friday's close, the empty weekend and Monday's 376.00 reopening, then the session schedule. |
| 03 | Lending today ignores the clock | 0:32.3–0:48.3 | Aryan | Three billion dollars of stock RWAs are on chain, but lending against them is tiny, because markets keep one fixed limit around the clock. In a deep weekend gap, that costs lenders four times more. | Real numbers: $3.21B of stock RWAs on chain against ≈$53M lent (rwa.xyz, Solana Compass); one fixed limit all week against StockReef's falling limit; modeled lender loss in a 35% gap, 1,014.91 against 247.78 USDG (evidence/scenarios.json). |
| 04 | A real loan book on testnet | 0:48.3–1:17.7 | Awaan | I connect the borrower's wallet to the live app on testnet, and the portfolio shows the whole loan and every protection. Lenders see a real book of four loans and what each is worth, and operations lists who needs to act before the close. | Connect wallet (the borrower), the Portfolio, then Lend with four real loans and Operations listing who must act. Book built on testnet by capture/book-live.sh. |
| 05 | Two hours before the bell | 1:17.7–1:38.0 | Awaan | Two hours before the bell, StockReef starts lowering the safe limit, from eighty percent down to seventy. At quarter past three this loan is just over the line, so the app shows exactly what to do, repay seven dollars thirty four by half past three. | Trade at Friday 15:15 on the live testnet: the threshold line falling from 80% to 70%, the tiles reading Repay 7.34 by 15:30. |
| 06 | Pay it down before the bell | 1:38.0–2:09.4 | Awaan | This borrower funded a repayment buffer in advance. I run it, and a real transaction goes to Robinhood Chain. Confirmed in seconds, the debt drops from seventy two to sixty five dollars. The loan is back under the line, with nothing sold and no penalty paid. And here's the receipt on the Robinhood Chain explorer. | Funded buffer → **Run buffer · 7.00 USDG** → signed and confirmed on testnet (0x4c3711ce…21fe) → state change 72.08 → 65.08 → the receipt on the Robinhood Chain explorer. |
| 07 | A partial trim, not a wipe-out | 2:09.4–2:36.0 | Awaan | Ben has no buffer, and at seventy four percent he's over the line. A liquidator trims part of his loan now, for a small two percent bonus. His debt falls to eighteen dollars, and the loan stays open at sixty five percent. Both transactions are on chain. | Operations as the liquidator → **Trim** on Ben's loan (exact approval, then the trim, 0x83ec266c…4793) → Ben's view: 29.60 → 18.61 USDG, 74.3% → 65.0% → the explorer. |
| 08 | Closed for the weekend, reopened with care | 2:36.0–3:30.7 | Aryan | At four the market closes and new borrowing locks. Paying down still works, so the borrower repays a dollar on chain. On Monday a fresh price of three seventy six arrives, but nothing trusts it until it's admitted five minutes after the open. Cleo's loan crossed seventy percent at the new price, so a recovery trim brings it back before new credit returns. | 16:00 closed: Protection shows credit locked; a real 1 USDG repayment while closed (0x1c1b3981…8e74). Monday 09:31 fresh price waiting, 09:35 admitted, then the liquidator's recovery trim of Cleo (0x855d5856…90da). |
| 09 | Lenders see losses before they happen | 3:30.7–3:47.9 | Aryan | Lenders are protected by design. Their shares always reflect what the loans can really recover, so if Tesla fell to two twenty, the shortfall shows today and is shared fairly. Nobody finds it after a default. | Lend after the reopening: 225 USDG book, four loans; the what-if slider dragged to TSLA 220: shortfall 19.88, share value 0.9132. |
| 10 | When the price feed goes quiet | 3:47.9–4:05.2 | Awaan | Now a deliberate failure. The price feed has been quiet for two minutes. I try to borrow one dollar, and the contract refuses the stale price before my wallet is even asked to sign. | 150 s without a price, then Borrow 1 USDG: **Rejected by the contract · NotAllowedNow · Guarded · stock price stale**. Nothing reaches the wallet. |
| 11 | Built to hold up | 4:05.2–4:20.2 | Awaan | Under the app, five hundred thirty one tests run in about a minute, covering the risky paths with fuzz, property and invariant suites. Four more run against Robinhood Chain mainnet. | The real `forge test` run streaming: 531 passed, 0 failed, 33 suites, 68.5 s; plus 4 mainnet fork tests. |
| 12 | Next for StockReef | 4:20.2–4:37.2 | Aryan | Next for StockReef, we calibrate the limits against real gaps, add stock RWAs one market at a time, get audited, and launch on Robinhood Chain mainnet. StockReef reduces stock-backed debt before the market closes. | Four steps: calibrate, more stock RWAs, audit, Robinhood Chain mainnet. Then the closing line. |

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
