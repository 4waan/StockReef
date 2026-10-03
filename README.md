# StockReef

## Problem

Tokenized stocks can move onchain while US stock markets are closed, but the regular-session price used to value them stops updating. A loan that meets its collateral limit on Friday can reopen undercollateralized on Monday. Blocking new borrowing during the closure does nothing to reduce debt that already exists.

## Solution

StockReef manages TSLA-backed USDG loans before each scheduled market close. It shows borrowers how much USDG to repay or TSLA to add, then lowers the permitted loan-to-value ratio as the close approaches. A borrower can fund a USDG repayment buffer in advance. If the loan still exceeds the current liquidation threshold, a liquidator can repay part of the debt and take collateral at the accepted price. Borrowing stops during the closure. After reopening, funded repayments and recovery liquidations get a window before new credit is allowed.

The contracts run on Robinhood Chain testnet with the faucet TSLA token and Paxos USDG. The testnet stock price and market clock are explicitly simulated. A keeper or another caller must submit each repayment or liquidation transaction.

## How it works

| Market phase | Rule | Borrowing |
|---|---|---|
| Regular session | Normal borrowing limit is 75% of collateral value. Liquidation starts above 80%. | Open |
| From 2 hours to 30 minutes before close | The liquidation threshold falls from 80% to 77% for an ordinary night or 70% for a weekend or holiday. Funded buffers repay first. Loans above the current threshold can be partially liquidated. | Limit falls with the threshold |
| Final 30 minutes | Buffers and eligible liquidations can still reduce debt before the bell. | Closed |
| Market closed | No price-dependent liquidation or buffer execution. Borrowers can still repay manually or add collateral. | Closed |
| Reopening | A stock quote must be published at least 1 minute after open and cannot be admitted before open + 5 minutes. Funded buffers run before eligible recovery liquidations. | Closed |
| Recovery complete | New credit can resume at the later of open + 15 minutes or 10 minutes after price admission, if the price and market pass the safety checks. | Open |

If the price is unusable or the guardian stops the market, price-dependent actions are blocked. A missing reopening price is flagged after 30 minutes; time alone never makes a stale price valid. If nobody submits a repayment or liquidation transaction, the debt remains.
