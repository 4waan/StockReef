# StockReef video plan

Draft for narration and screen timing. Trade, Earn, Portfolio, and Operations open in a shared staged scenario. The Live testnet switch on each page shows contract reads and real MetaMask actions. Explorer receipts and MetaMask confirmations are real Robinhood Chain testnet transactions.

## One-minute pitch

A borrower posts 0.25 TSLA at 400 USDG per token and borrows 72 USDG. If TSLA reopens at 340, collateral falls from 100 to 85 USDG. Debt stays above 72 with interest, pushing LTV above 84%. The stock market closed; the debt did not. That is the gap StockReef addresses. This is an illustrative price gap.

StockReef manages it before the market shuts. On Robinhood Chain, a falling threshold exposes risk before the close. Borrowers can fund USDG repayment buffers; liquidators can trim eligible loans with their own USDG. New borrowing locks during closure. Repayment and collateral deposits stay open. After reopening, a fresh accepted price and recovery window come before new credit. Lender shares reflect what outstanding loans can recover. Contract transactions and public receipts show what actually happened.

This is lending designed around the stock market's hours.

## Comfortable demo, target 3 minutes 15 seconds

| Time | Voiceover | Screen |
|---|---|---|
| 0:00 to 0:25 | A borrower posts a quarter of a TSLA token worth 100 USDG and borrows 72. If TSLA reopens at 340 instead of 400, the collateral is worth 85, while debt remains above 72 with interest. The stock market closed; the debt did not. That is the gap StockReef addresses. | Show the fixed-price position first, then the illustrative lower reopening price. Keep the screen still long enough to read the figures. |
| 0:25 to 0:45 | StockReef manages the debt before the gap and controls when lending starts again. Here is one borrower, one lender vault, and the rule that connects them. | Open the guided Trade view. Show 85 USDG in the vault, 0.25 TSLA collateral, 72 USDG debt, and the initial 72% LTV at the fixed 400 USDG reference price. |
| 0:45 to 1:15 | The borrower has already funded 7 USDG in a repayment buffer. Before the close, that money repays the loan first. Debt moves from 72 to 65 USDG, and LTV from 72% to 65%, without selling TSLA. If a position remains above the threshold, a liquidator can submit a partial trim with their own USDG. | Trigger the guided buffer step. Let debt, LTV, buffer balance, vault cash, and portfolio history change together. Show the alternate trim as eligible, without executing it in this route. |
| 1:15 to 1:35 | Trading closes. New borrowing and debt-backed TSLA withdrawals lock. A borrower can still repay USDG or add collateral. | Advance the guided session. Leave the two available actions visible. |
| 1:35 to 2:00 | At reopening, StockReef first needs a fresh accepted stock price. Eligible recovery trims get a window before new credit returns. Time alone never approves a bad price. | Admit the guided reopening price, show the recovery interval, then unlock new credit. Display a clearly labeled modeled price path. |
| 2:00 to 2:25 | The portfolio shows what changed: debt, LTV, buffer use, and the execution history. Lenders can see available cash and the recoverable value of outstanding loans. | Move between Portfolio and Earn. Keep each screen sparse and pause on the key change. |
| 2:25 to 3:00 | This is a working testnet market. Here is a real wallet confirmation and its transaction on the Robinhood explorer. The guided price path is a presentation scenario; the receipt is an actual contract call. | Connect MetaMask to the testnet wallet, sign one small action, wait for confirmation, then open the matching receipt. If the live transaction fails, use a previously confirmed receipt and state its recorded time. |
| 3:00 to 3:15 | StockReef makes market hours part of the lending rule, with a record of the actions that actually happened. | End on the risk-control sequence, app URL, and repository. |

## Guided scenario numbers

The funded public market has an 85 USDG lender deposit, 0.25 TSLA collateral, 72 USDG of original borrowing, and a 7 USDG buffer authorization. Its deployed operator-set reference price was 400 USDG per TSLA. The 72% and 65% LTV states in the guided pre-close sequence use that fixed price and ignore accrued interest, as the worked example does.

For a reopening illustration, the [TSLA close on 2 October 2026](https://stockanalysis.com/stocks/tsla/history/) was 370.59 USD. At that illustrative price, 0.25 TSLA is worth 92.6475 USDG under the 1 USDG = 1 USD reference. Debt of 65 USDG would have an LTV of about 70.16%. This is scenario arithmetic, not a Robinhood Chain accepted price or a promise of a live stock feed. A one-hour moving chart must be labeled as a guided replay, with modeled volume and a scenario clock.

## Real receipt options

1. Sign a small manual USDG repayment from the borrower wallet. It is allowed during closure and directly proves that the closed-session repay path works. This changes the real chain debt and produces a fresh explorer receipt.
2. Advance the operator-set clock into preparation, publish a usable price, then execute the funded buffer with a keeper or other caller. This directly proves the distinctive buffer path, but requires several on-chain steps and more time to stage.
3. Sign a small collateral deposit. This proves MetaMask signing and the position update, but says less about the market-close controls.

The chosen recording action is option 2. Keep option 1 as a fallback. The guided UI should never attach a real receipt to a modeled action that the receipt did not perform.

### Stage the buffer receipt before recording

1. In MetaMask, select the public lender and operator account `0x8A60820Ebbf9643F7b0B560a2FE6AFE666c2A87a` on Robinhood Chain testnet. The funded borrower is `0x05802c4E1921b24854D603A46951864ca97b8DAf`. Verify both addresses in the app before any signing.
2. In the live Operations view, read the borrower row and buffer status. Confirm that the authorization is still active, the escrow holds enough USDG, and the operator account has testnet ETH for gas.
3. If the operator-set clock is outside a preparation window, use the operator controls to move to a valid open session and then its preparation start. Each move is a real transaction. Publish a 400 USDG demo TSLA price and refresh the gate when needed. The feed has a 120-second maximum age, so refresh it immediately before the recorded action.
4. Open the live borrower Trade view. The `Run buffer now` control must show a positive executable amount before recording the click. With MetaMask still connected to the operator account, sign `executeBuffer` and wait for a successful receipt.
5. Show the changed on-chain debt, buffer balance, lender cash, and the exact transaction hash in the live app and explorer. Accrued interest can make the live result differ slightly from the fixed 72 to 65 presentation example. Read the live values rather than substituting the modeled ones.

These steps are conditional on the current contract state. If the authorization has expired or the feed cannot be made usable, renew or fund the plan through the borrower account before filming. Do not sign a call merely to produce a receipt when the contract reports it ineligible.

## Recording checklist

- Import the selected testnet account into MetaMask before recording. Confirm that it shows Robinhood Chain testnet and has gas and the asset needed for the chosen call.
- Use a clean browser profile, readable zoom, and a fixed window size. Mask secret recovery phrases and private keys; show only the MetaMask signing prompt and public address.
- Rehearse transaction approval, pending state, confirmation, and explorer opening. Leave enough time for the viewer to read the amount, network, and contract.
- Keep a visible testnet or guided-scenario cue whenever modeled numbers appear. Use the connected wallet indicator only when MetaMask is actually connected.
- Record the pitch separately. The pitch explains the user problem and Robinhood Chain value; the longer demo proves behavior.
