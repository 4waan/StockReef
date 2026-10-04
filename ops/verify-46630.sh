#!/usr/bin/env bash
# Verify the chain 46630 StockReef contracts on the Robinhood testnet Blockscout explorer.
#
# Why: MetaMask's transaction security checks treat calls and token approvals to unverified contracts as higher
# risk. With verified source the explorer shows each contract's code and name, and wallets can decode the calls.
#
# Run from a full checkout (git clone --recurse-submodules) at the deployment's source commit or later: the
# contract sources and foundry.toml are unchanged since 0a80584 (evidence/deploy-46630.json, sourceCommit).
# Blockscout needs no API key. Constructor arguments are recovered from the creation transactions.
#
#   bash ops/verify-46630.sh
set -euo pipefail
cd "$(dirname "$0")/../contracts"

URL="https://explorer.testnet.chain.robinhood.com/api/"
RPC="https://rpc.testnet.chain.robinhood.com"
A="../deployments/addresses.46630.json"
addr() { python3 -c "import json,sys; print(json.load(open('$A'))['$1'])"; }

verify() {
  local address="$1" path="$2"
  echo "== $path at $address"
  forge verify-contract "$address" "$path" \
    --chain-id 46630 --rpc-url "$RPC" \
    --verifier blockscout --verifier-url "$URL" \
    --guess-constructor-args --watch || echo "   (failed; it may already be verified: check $URL../address/$address)"
}

forge build
verify "$(addr calendar)" src/SessionCalendar.sol:SessionCalendar
verify "$(addr demoController)" src/demo/DemoController.sol:DemoController
verify "$(addr clock)" src/clock/DemoClock.sol:DemoClock
verify "$(addr stockFeed)" src/mocks/MockAggregatorV3.sol:MockAggregatorV3
verify "$(addr gate)" src/PriceGate.sol:PriceGate
verify "$(addr policy)" src/SessionRiskPolicy.sol:SessionRiskPolicy
verify "$(addr market)" src/StockReefMarket.sol:StockReefMarket
verify "$(addr escrow)" src/RepaymentEscrow.sol:RepaymentEscrow
verify "$(addr lens)" src/StockReefLens.sol:StockReefLens
