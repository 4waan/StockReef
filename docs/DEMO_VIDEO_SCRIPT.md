# StockReef: pitch and demo video script

Two videos, both in StockReef's light theme on a burnt orange grid, with original music (`media/videos/scripts/music.mjs`: a closing bell, a countdown clock and a confirmation chime cued to the picture).

- **Pitch:** a generated explainer, one question per section, with app captures and real market data.
- **Demo:** one continuous run of the deployed app on the public Robinhood Chain testnet, driven with a visible cursor. Real wallets sign real transactions, and the receipts open on the Robinhood Chain explorer. Chapter titles name what is happening rather than asking questions.
- **Voices:** **Aryan Singh Rathore** carries the problem, the market and the business; **Awaan Mustafa Siddiqui** carries the product and the proof.

| | Pitch | Demo |
|---|---|---|
| Job | The business case | Proof that it works, on chain |
| Sections | Vision, what breaks at the close, user, product, why now, RWA lending gap and fix, model, growth, traction, team, Open House Singapore plan, ask | The landing page, the problem, the market today (real data), the live loan book, the countdown, a funded repayment and its state change, a partial trim, the weekend and Monday, lender protection, a deliberate failure, the test run, next for StockReef |
| Length | 3:51 | Under 5:00 (HackQuest cap); this cut runs 4:42.2 |
| Shared | Only the closing line: **StockReef: borrow against your stocks, safely, even when the market is closed.** | |

**Sentence style.** One flowing sentence of 8 to 16 words per idea, joined with *and*, *so* or *but*. There are no semicolons, colons or dashes. Say numbers aloud, as "seven dollars" or "seventy percent". One sentence is on screen at a time.

---

## Capture

1. **Keys.** `OPERATOR_KEY`, `BORROWER_KEY` and `LIQUIDATOR_KEY` in the ignored `.env.roles` at the repository root. `capture/book-live.sh` appends keys for the book accounts it creates (Treasury, Ava, Ben, Cleo) to the same file.
2. **Testnet weekend.** From `app/`: `npx tsx scripts/demo.ts prepare` (Friday 13:00 at 400.00, borrower at 72 USDG with a funded 7 USDG buffer), then `bash ../media/videos/capture/book-live.sh` for the rest of the book.
3. **Record.** From `media/videos/`: `NODE_USE_ENV_PROXY=1 node capture/record.mjs` records the chapters in order against stock-reef.vercel.app, stepping the testnet between them (prep, closed, wait, admit, credit). It signs in the browser with the role keys, waits 150 s without a price before the failure chapter, and writes `public/rec/<clip>/`. Then run `node capture/build-clips.mjs`.
4. **Cut.** `demo.json` lists each chapter's clip slices (speed-ups only over block waits and page loads), the address bar and the narration; `npm run render:demo` builds the timeline and music and renders.
5. **The clock only moves forward.** A failed take needs `prepare` again, which moves to the next weekend in the calendar.

---

## Part 1: Pitch (3:51)

Intro, 0:00–0:05, music only: the logo, "StockReef", "in twelve questions", and "Built on Robinhood Chain · Paxos USDG · TSLA".

Plain words, short sentences: each answer is two to four sentences anyone can follow.

| # | Question on screen | Voice | Time | Say | Show |
|---|---|---|---|---|---|
| Q1 | What's changing? | Aryan | 0:05–0:24 | Stocks are moving on chain. You can now hold Tesla as a token and borrow dollars against it at any time of day. But the real stock market still closes every night and every weekend. I'm Aryan, co-founder of StockReef. | "Stocks are moving on chain. The market still closes." A week timeline: the Tesla stock token trades every hour; Nasdaq only on weekdays, closed all weekend. |
| Q2 | What goes wrong on weekends? | Aryan | 0:24–0:50 | Your loan stays open, but the stock market is shut. Nobody knows Tesla's real price until Monday morning. If it opens much lower, your loan is suddenly unsafe, and it's too late to do anything. This isn't rare. About once every four months, Tesla opens on Monday at least five percent away from its Friday price. | Real Tesla candles around one weekend: −10.8% at Monday's open. Cards: "65.5 hours" with no real price, "Every ~4 months" Tesla opens Monday 5%+ away from Friday. |
| Q3 | Who feels it first? | Aryan | 0:50–1:10 | People who own stock tokens and want cash without selling, and the lenders who give them that cash. To protect themselves, lenders today only lend about half of what the stock is worth, or they don't lend at all. | Cards "Own stock tokens" and "Give them the cash"; a bar: lenders lend about half, or nothing. |
| Q4 | What is StockReef? | Awaan | 1:10–1:36 | I'm Awaan. StockReef is a lending app that gets loans ready for the weekend. Before the market closes, it asks risky borrowers to pay a little back while there's still a real price. Over the weekend, no new borrowing. On Monday, it reopens step by step. So people can safely borrow up to seventy five percent. | The app at 15:15, then the buffer cutting debt 72 → 65. "Lends up to 75%" and three steps: pay a little back, no new borrowing over the weekend, reopen step by step. |
| Q5 | Why now, and why Robinhood Chain? | Awaan | 1:36–1:54 | Robinhood Chain just went live with real stock tokens and USDG, a digital dollar, in one place. Over three billion dollars of stocks are already on chain, but almost none of it is used to borrow against. | "Mainnet live" and "Stock tokens · USDG, a digital dollar". Bars: $3.21B of stocks on chain, ≈$53M borrowed against them. |
| Q6 | How does StockReef change that? | Awaan | 1:54–2:15 | Lenders stay away because weekends are a blind spot. StockReef removes that blind spot with clear rules, written into the smart contract, that run before every close. With weekends handled, a hundred dollars of stock can borrow seventy five dollars instead of fifty. | "Weekends are a blind spot" next to "Clear rules in the smart contract". What $100 of Tesla stock can borrow: $50 today, $75 with StockReef. |
| Q7 | How does it make money? | Aryan | 2:15–2:32 | Borrowers pay interest, and lenders earn it. StockReef keeps ten percent of that interest, plus ten percent of the small bonus paid when a risky loan is trimmed. That's the same cut Aave takes. | Two bars: interest and trim bonus, 90% to lenders or trimmers, 10% to StockReef. "The same cut Aave takes." |
| Q8 | How does it grow? | Aryan | 2:32–2:47 | We start with Tesla, then add more stocks one at a time. Every holiday and early close is already built in, so each new stock works from day one. | TSLA / USDG, then "next stock" tiles; weekends, holidays, early closes; "Works from day one". |
| Q9 | What's real today? | Awaan | 2:47–3:03 | StockReef is live on Robinhood Chain testnet, with real loans and real transactions you can check on the explorer. And five hundred thirty five automated tests check the risky parts. | The Evidence page zooming to 535 tests; pills: live on testnet, real loans, real transactions, 535 automated tests. |
| Q10 | Who's building it? | Awaan | 3:03–3:14 | Aryan and I. We built all of StockReef, from the smart contracts to the app, during this buildathon. | Two founder cards; Contracts · Keeper · App · Built during the buildathon. |
| Q11 | What will we do at Open House Singapore? | Aryan | 3:14–3:31 | At Open House Singapore, we'll launch StockReef on Robinhood Chain mainnet with a small Tesla market and our first lenders. And we'll run a live Friday close in front of real stock token holders. | "Open House Singapore": Launch on Robinhood Chain mainnet, seed our first lenders, show a live Friday close. |
| Q12 | What do we need? | Aryan | 3:31–3:45 | We need a security audit, a trading partner for Tesla, and a partnership for USDG. StockReef: borrow against your stocks, safely, even when the market is closed. | Three asks tick in, then the closing line. |

Outro, 5 seconds: logo, "Borrow against your stocks, safely, even when the market is closed.", `stock-reef.vercel.app` · `github.com/4waan/StockReef` · "Aryan Singh Rathore · Awaan Mustafa Siddiqui".

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
| 12 | Next for StockReef | 4:20.2–4:37.2 | Aryan | Next for StockReef, we calibrate the limits against real gaps, add stock RWAs one market at a time, get audited, and launch on Robinhood Chain mainnet. StockReef: borrow against your stocks, safely, even when the market is closed. | Four steps: calibrate, more stock RWAs, audit, Robinhood Chain mainnet. Then the closing line. |

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
