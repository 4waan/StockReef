# StockReef demo video

The main video is a guided walkthrough of the staged website. Every modeled balance, price, status, and history entry is labeled as a scenario. The last segment switches to the live Robinhood Chain testnet view for a real MetaMask signature and explorer receipt. Record the one-minute pitch separately.

## Spoken walkthrough, about six minutes

### 0:00 to 0:35, the loan before the gap

A lender can fund a stock-backed loan on Friday, but the debt stays open after the stock market closes. Here is a small example. A borrower posts a quarter of a TSLA token worth 100 USDG at our fixed 400 USDG scenario price, then borrows 72 USDG. That is 72% loan to value. If the stock opens lower on Monday, the collateral changes value immediately. The amount owed does not disappear over the weekend.

### 0:35 to 1:20, build the position

I will build that position on StockReef. The lender deposits 85 USDG. The borrower posts 0.25 TSLA and borrows 72 USDG, leaving 13 USDG available in the vault. These three balances also appear in Portfolio and Operations. The borrower then moves 7 USDG from their wallet into a separate repayment escrow and authorizes a 65% LTV target with a 7 USDG spending cap. Funding the escrow sets money aside. It has not reduced the debt yet.

### 1:20 to 2:10, the close approaches

At 15:15 on this Friday, the weekend liquidation threshold has fallen to about 71.67%. This 72% loan is now eligible for action. The borrow limit falls with the threshold, and the lender entry window has closed. The funded buffer gets the first chance. When its transaction executes, 7 USDG goes from escrow to the vault. Debt falls from 72 to 65, cash rises from 13 to 20, and the borrower keeps all 0.25 TSLA. At the same fixed price, LTV falls from 72% to 65%. Those changes appear together in the portfolio and lender book. The buffer execution is a separate transaction; an authorization by itself does not do this.

### 2:10 to 2:55, the other two outcomes

Now replay the same loan without that buffer. A liquidator has 15 USDG, so this is a capital-limited partial trim. They repay 15 USDG and receive 0.03825 TSLA, including the 2% scheduling bonus. Debt falls to 57 USDG and the borrower keeps about 0.21175 TSLA. The liquidator now owns stock whose later sale price is uncertain. At our illustrative 370.59 price, that stock is worth about 14.18 USDG, less than the 15 USDG they supplied. The bonus is not a guaranteed profit.

Replay once more with nobody executing. The loan reaches the close with 72 USDG of principal. The app reports it as missed execution. Moving the clock does not repay debt. In the final 30 minutes new borrowing has already stopped. During closure, borrowing, debt-backed stock withdrawals, buffers, and trims are locked. Manual repayment and collateral deposits remain available.

### 2:55 to 3:45, reopening and price failure

On Monday, a new quote must arrive from the regular session and pass the price checks. Advancing the clock alone cannot make an old or invalid quote usable. Here I reject the price: price-dependent actions stop, while repayment and collateral top-ups remain possible. The guardian has a separate stop, with a 24-hour wait and recovery checks before resuming. Once a fresh price is accepted, StockReef gives eligible recovery trims a window before new credit returns. The recovery window allows action; it does not promise that every loan will be trimmed.

### 3:45 to 4:35, lender loss and the policy limits

The portfolio shows the difference between the executed routes and the loan that carried its full debt into the gap. At an illustrative 370.59 USDG reopening price, the untouched loan's LTV is about 77.7%, while the buffered loan's LTV is about 70.2%. For a more severe 250 USDG scenario, we admit the fresh quote before updating the lender book. The untouched collateral is then worth only 62.50 USDG. Recoverable loan value, allowing for the 5% recovery bonus, is about 59.52 USDG. With 13 USDG cash, lender assets fall to about 72.52 USDG from the original 85. The share value falls with that shortfall, and an impaired book blocks new lending.

The schedule treats ordinary nights and extended weekend or holiday closures differently. Their final thresholds are 77% and 70%, with trim targets of 72% and 65%. The calendar includes early closes and daylight-saving changes. A 90% utilization cap and available-cash withdrawal limit constrain the lender book even when the session is open.

### 4:35 to 5:25, a real signed action

Everything up to this point was the guided scenario. I am switching to the live Robinhood Chain testnet view now. This public borrower already has a funded and authorized buffer on-chain. I connect the operator wallet through MetaMask, check the executable amount shown by the contract, and choose Run buffer now. MetaMask displays the network, account, and contract call before I confirm. After the transaction is mined, the live app shows the actual amount repaid, changed debt and vault cash, and the matching explorer receipt. These live amounts include accrued interest, so I read the figures on screen rather than repeating the rounded scenario numbers.

## Screen sequence

1. Trade: select **Replay from zero**. Lend 85 USDG, post 0.25 TSLA, borrow 72 USDG, fund 7 USDG, authorize the buffer. Pause on the open lender window and the loan.
2. Move to 15:15. Show the falling threshold, the closed lender window, then execute the staged funded repayment. Visit Portfolio and Lend to show the linked debt, cash, collateral and history.
3. Return to Operations. Select **Try partial trim**, submit the staged 15 USDG trim, and show the liquidator stock inventory. Replay **Try no execution**, advance through the final window and close.
4. Open Monday. Reject a modeled price and show the lock. Restore it, show the guardian stop and modeled 24-hour resume rule, accept the fresh price, optionally submit a recovery trim, then complete the recovery interval.
5. Replay no execution, choose the severe 250 USDG gap, and admit that fresh price. Show lender recoverable value, share value, impaired-book status, and the other policy limits in Operations.
6. Switch to **Live testnet**. Connect MetaMask and perform `executeBuffer` only when the contract view reports a positive executable amount. Hold on the MetaMask confirmation, mined status, and exact explorer receipt.

## Real transaction preparation

The public market setup is in [evidence/public-market-46630.json](../evidence/public-market-46630.json). The borrower holds 0.25 TSLA collateral with 72 USDG of initial borrowing and 7 USDG in an authorized buffer. The lender deposited 85 USDG. The liquidator has 15 USDG. The deployed demo price was 400 USDG per TSLA. The live debt accrues interest.

Before recording, verify that the authorization is active, escrow contains USDG, the operator wallet has testnet ETH, the demo clock is in preparation or recovery, and the stock price feed is usable. Publish a fresh demo price and refresh the gate when needed. The feed's maximum age is 120 seconds. The live Trade view exposes **Run buffer now** only when the contract lens reports an executable amount. Sign with MetaMask and use the resulting transaction hash as the receipt. If the buffer is no longer executable, restage the authorization and clock before recording. Never present a staged history line as that receipt.

The [TSLA close on 2 October 2026](https://stockanalysis.com/stocks/tsla/history/) was 370.59 USD. The guided chart uses this number as a dated reopening reference; it is not a live Robinhood Chain feed price. The severe 250 USDG branch is hypothetical. The fixed 400 USDG setup and calculations omit interest, while the live contract does not.

## Separate one-minute pitch

A borrower can take a USDG loan against TSLA on Friday and still owe it when the stock market opens on Monday. The price may jump before anyone can adjust the loan. StockReef brings that adjustment forward. Its on-chain limits tighten before the close. Borrowers can pre-fund repayment; liquidators can reduce eligible debt with their own capital. New credit waits through the closure and reopening checks. Lenders see what the outstanding loans can actually recover. On Robinhood Chain testnet, the app ties those controls to transactions and public receipts. The point is practical: a stock-backed lending market should account for the hours when the stock itself cannot trade.
