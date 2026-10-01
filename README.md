# StockReef

**Stock markets close. Loans don't.**

StockReef is a pre-close loan manager for tokenized stocks on Robinhood Chain. Before each scheduled
market close it tightens the market's published limits, repays debt from buffers that borrowers fund in
advance, and lets liquidators partially reduce positions that remain over the limit, at the current
accepted price. While the market is closed, new borrowing stops; when eligible prices return, recovery
liquidations run before new credit opens.

> Status: under active development for the Arbitrum Open House Singapore buildathon. Testnet only.
> All risk parameters are illustrative test settings, not calibrated production limits.

## Layout

| Path | Contents |
|---|---|
| `contracts/` | Foundry project (Solidity 0.8.28) |
| `docs/` | Product specification and a review of the earlier GapGuard concept |
| `tools/` | Calendar generator and independently computed golden values |
| `ops/keeper/` | Execution service (buffer repayments, liquidations, demo feed) |
| `app/` | Web app: Borrow, Lend, Operations, Evidence |

## Build

```bash
git clone --recurse-submodules https://github.com/4waan/StockSmart
cd StockSmart/contracts
forge build
forge test
```
