#!/usr/bin/env bash
# The demo's loan book on the PUBLIC chain 46630 testnet, sized from what the role accounts actually hold.
# Run right after `npm run demo -- prepare` (Friday 13:00, lender window open, fresh price).
#
#   bash media/videos/capture/book-live.sh
#
# Keys: OPERATOR_KEY, BORROWER_KEY, LIQUIDATOR_KEY from the ignored .env.roles. The book accounts (Treasury, Ava,
# Ben, Cleo) are generated once and their keys appended to the same ignored file. Nothing here prints a key.
set -euo pipefail
cd "$(dirname "$0")/../../.."
C=~/.foundry/bin/cast
R=${RPC_URL:-https://rpc.testnet.chain.robinhood.com}
ENV=.env.roles
git check-ignore -q "$ENV" || { echo "$ENV must be git-ignored" >&2; exit 1; }

MARKET=0x75459B07b03F3Ea4768073854Ec06AA02DF9264F
TSLA=0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E
USDG=0x7E955252E15c84f5768B83c41a71F9eba181802F
DEMO=0xe7F80950f96E8c51578bC546b580dAe7cfe01Be6

for name in TREASURY AVA BEN CLEO; do
	grep -q "^${name}_KEY=" "$ENV" || echo "${name}_KEY=$($C wallet new --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["private_key"])')" >>"$ENV"
done
key() { grep "^$1_KEY=" "$ENV" | cut -d= -f2; }
addr() { $C wallet address --private-key "$(key "$1")"; }
send() { local who=$1 label=$2; shift 2; local h; h=$($C send --private-key "$(key "$who")" --rpc-url "$R" --json "$@" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["transactionHash"], d["status"])'); echo "$(printf '%-34s' "$label") $h"; }

OPERATOR=$(addr OPERATOR); BORROWER=$(addr BORROWER); LIQUIDATOR=$(addr LIQUIDATOR)
TREASURY=$(addr TREASURY)
echo "Treasury $TREASURY"

# Gas for the new accounts, from the operator (0.01 gwei gas: 0.0003 ETH covers about a hundred calls).
for who in TREASURY AVA BEN CLEO; do send OPERATOR "Gas for $who" "$(addr $who)" --value 0.0003ether; done
# Keep the 13:00 price fresh while the book is built.
send OPERATOR "Re-publish 400.00" "$DEMO" 'push(int256)' 40000000000

# A second lender: Treasury supplies 140 USDG.
send BORROWER "Fund Treasury with 140 USDG" "$USDG" 'transfer(address,uint256)' "$TREASURY" 140000000
send TREASURY "Treasury: approve exactly 140 USDG" "$USDG" 'approve(address,uint256)' "$MARKET" 140000000
send TREASURY "Treasury: deposit 140 USDG" "$MARKET" 'deposit(uint256,address)' 140000000 "$TREASURY"
# The liquidator holds USDG for Friday's trim and Monday's recovery.
send BORROWER "Top up liquidator with 10 USDG" "$USDG" 'transfer(address,uint256)' "$LIQUIDATOR" 10000000

# name TSLA(wei) debt(USDG, 6 decimals)
for row in "AVA 300000000000000000 66000000" "BEN 100000000000000000 29600000" "CLEO 100000000000000000 27000000"; do
	read -r who tsla debt <<<"$row"
	a=$(addr "$who")
	send OPERATOR "TSLA to $who" "$TSLA" 'transfer(address,uint256)' "$a" "$tsla"
	send "$who" "$who: approve exact TSLA" "$TSLA" 'approve(address,uint256)' "$MARKET" "$tsla"
	send "$who" "$who: deposit collateral" "$MARKET" 'depositCollateral(uint256,address)' "$tsla" "$a"
	send OPERATOR "Re-publish 400.00" "$DEMO" 'push(int256)' 40000000000
	send "$who" "$who: borrow" "$MARKET" 'borrow(uint256,address)' "$debt" "$a"
	echo "$who $a"
done
