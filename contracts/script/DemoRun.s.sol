// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";
import {PriceGate} from "../src/PriceGate.sol";
import {SessionRiskPolicy} from "../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../src/RepaymentEscrow.sol";
import {StockReefLens} from "../src/StockReefLens.sol";
import {DemoController} from "../src/demo/DemoController.sol";

/// @notice The three-outcome demonstration on a deployed demo market (docs/SPEC.md §11, appendix R7, R13), at
/// 1/100 of the worked example: 0.25 TSLA at 400 USDG, 72 USDG of debt per borrower.
///
///   A (alice) funded a buffer: it repays to 65% when preparation starts.
///   B (bob) has no buffer: a liquidator trims it at 15:15 on the demo clock.
///   C (carol): nobody acts; at the close the Lens reports missed execution and the open exposure.
///   Reopening: a fresh, gapped price is admitted, recovery trims run, then credit returns.
///
/// Signers: OPERATOR_KEY (demo operator, lender, keeper), ALICE_KEY, BOB_KEY, CAROL_KEY, LIQUIDATOR_KEY. On a
/// local chain they default to the standard test mnemonic. Results go to ../evidence/demo-<chainid>.json with
/// times as offsets from the session, never as dates.
contract DemoRun is Script {
    uint256 internal constant USDG = 1e6;
    int256 internal constant PRICE = 400e8;
    int256 internal constant REOPEN_PRICE = 376e8; // a 6% gap at the reopening
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";

    struct Actors {
        uint256 operator;
        uint256 alice;
        uint256 bob;
        uint256 carol;
        uint256 liquidator;
    }

    DemoController internal demo;
    SessionCalendar internal calendar;
    PriceGate internal gate;
    SessionRiskPolicy internal policy;
    StockReefMarket internal market;
    RepaymentEscrow internal escrow;
    StockReefLens internal lens;
    IERC20 internal usdg;
    IERC20 internal tsla;
    string internal out = "demo";

    function run() external {
        _load();
        Actors memory k = _actors();
        (uint64 open, uint64 close, uint64 nextOpen) = _nextExtendedSession();

        // Reopening of a session that is followed by a weekend: admit a fresh price, then credit returns.
        _step(k, open + 5 minutes, PRICE);
        _step(k, open + 15 minutes, PRICE);
        _record("open", open, uint64(open + 15 minutes));

        // A lender funds the market; three borrowers take the worked example at 1/100.
        _fund(k);
        vm.startBroadcast(k.operator);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(1_000 * USDG, vm.addr(k.operator));
        vm.stopBroadcast();
        _borrow(k.alice);
        _borrow(k.bob);
        _borrow(k.carol);

        vm.startBroadcast(k.alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(10 * USDG, vm.addr(k.alice));
        escrow.authorize(0.65e18, 10 * USDG, nextOpen + 1 days);
        vm.stopBroadcast();

        // A = C - 120 min: the keeper executes Alice's buffer.
        _step(k, close - 120 minutes, PRICE);
        vm.broadcast(k.operator);
        uint256 bufferRepaid = escrow.executeBuffer(vm.addr(k.alice));
        vm.serializeUint(out, "aliceBufferRepaidUsdg", bufferRepaid);

        // 15:15 for a 16:00 close: Bob is above the falling threshold; a liquidator trims him.
        _step(k, close - 45 minutes, PRICE);
        vm.startBroadcast(k.liquidator);
        usdg.approve(address(market), type(uint256).max);
        (uint256 trimRepaid, uint256 trimCollateral) =
            market.trim(vm.addr(k.bob), type(uint256).max, 0, close - 30 minutes);
        vm.stopBroadcast();
        vm.serializeUint(out, "bobTrimRepaidUsdg", trimRepaid);
        vm.serializeUint(out, "bobTrimCollateralRaw", trimCollateral);

        // Closed: no new borrowing; Carol's missed execution is reported.
        vm.broadcast(k.operator);
        demo.stepTo(close + 1 hours, PRICE);
        StockReefLens.AccountView memory c = lens.accountView(vm.addr(k.carol));
        vm.serializeBool(out, "carolMissedExecution", c.missedExecution);
        vm.serializeUint(out, "carolExposureUsdg", c.exposure);
        _accounts("atClose", k);

        // Reopening with a gap: wait, admission, recovery trim of Carol, then OPEN.
        _step(k, nextOpen + 1 minutes, REOPEN_PRICE);
        _record("reopenWait", nextOpen, uint64(nextOpen + 1 minutes));
        _step(k, nextOpen + 5 minutes, REOPEN_PRICE);
        _record("recovery", nextOpen, uint64(nextOpen + 5 minutes));
        vm.broadcast(k.liquidator);
        (uint256 recoveryRepaid,) = market.trim(vm.addr(k.carol), type(uint256).max, 0, nextOpen + 15 minutes);
        vm.serializeUint(out, "carolRecoveryTrimRepaidUsdg", recoveryRepaid);
        _step(k, nextOpen + 15 minutes, REOPEN_PRICE);
        _record("reopened", nextOpen, uint64(nextOpen + 15 minutes));
        _accounts("afterReopen", k);

        string memory json = vm.serializeUint(out, "totalBadDebtUsdg", market.totalBadDebt());
        string memory path = string.concat("../evidence/demo-", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("written", path);
    }

    // ---------------------------------------------------------------- steps

    /// @dev One demo step: move the clock, publish the price, refresh the gate (as the keeper does).
    function _step(Actors memory k, uint64 t, int256 answer) internal {
        vm.startBroadcast(k.operator);
        demo.stepTo(t, answer);
        gate.refresh();
        vm.stopBroadcast();
    }

    function _borrow(uint256 key) internal {
        vm.startBroadcast(key);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(0.25e18, vm.addr(key));
        market.borrow(72 * USDG, vm.addr(key));
        vm.stopBroadcast();
    }

    /// @dev Local mocks: the deployer holds every token, so hand the actors what they need.
    function _fund(Actors memory k) internal {
        if (block.chainid != 31337) return; // on the testnet each wallet uses the faucets
        vm.startBroadcast(k.operator);
        uint256[4] memory keys = [k.alice, k.bob, k.carol, k.liquidator];
        for (uint256 i; i < keys.length; ++i) {
            tsla.transfer(vm.addr(keys[i]), 1e18);
            usdg.transfer(vm.addr(keys[i]), 500 * USDG);
        }
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------- records

    function _record(string memory label, uint64 anchor, uint64 t) internal {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        string memory key = string.concat(label, ".state");
        vm.serializeUint(out, key, uint256(s.state));
        vm.serializeUint(out, string.concat(label, ".ltWad"), s.ltWad);
        vm.serializeUint(out, string.concat(label, ".secondsFromOpen"), t - anchor);
    }

    function _accounts(string memory label, Actors memory k) internal {
        address[3] memory who = [vm.addr(k.alice), vm.addr(k.bob), vm.addr(k.carol)];
        string[3] memory names = ["alice", "bob", "carol"];
        for (uint256 i; i < 3; ++i) {
            StockReefLens.AccountView memory v = lens.accountView(who[i]);
            vm.serializeUint(out, string.concat(label, ".", names[i], ".debtUsdg"), v.debt);
            vm.serializeUint(out, string.concat(label, ".", names[i], ".ltvWad"), v.ltvWad);
        }
    }

    // ---------------------------------------------------------------- setup

    function _load() internal {
        string memory a = vm.readFile(string.concat("../deployments/addresses.", vm.toString(block.chainid), ".json"));
        demo = DemoController(vm.parseJsonAddress(a, ".demoController"));
        require(address(demo) != address(0), "not a demo deployment");
        calendar = SessionCalendar(vm.parseJsonAddress(a, ".calendar"));
        gate = PriceGate(vm.parseJsonAddress(a, ".gate"));
        policy = SessionRiskPolicy(vm.parseJsonAddress(a, ".policy"));
        market = StockReefMarket(vm.parseJsonAddress(a, ".market"));
        escrow = RepaymentEscrow(vm.parseJsonAddress(a, ".escrow"));
        lens = StockReefLens(vm.parseJsonAddress(a, ".lens"));
        usdg = IERC20(vm.parseJsonAddress(a, ".loanToken"));
        tsla = IERC20(vm.parseJsonAddress(a, ".collateralToken"));
    }

    function _actors() internal view returns (Actors memory k) {
        bool local = block.chainid == 31337;
        k.operator = local ? vm.deriveKey(MNEMONIC, 0) : vm.envUint("OPERATOR_KEY");
        k.alice = local ? vm.deriveKey(MNEMONIC, 1) : vm.envUint("ALICE_KEY");
        k.bob = local ? vm.deriveKey(MNEMONIC, 2) : vm.envUint("BOB_KEY");
        k.carol = local ? vm.deriveKey(MNEMONIC, 3) : vm.envUint("CAROL_KEY");
        k.liquidator = local ? vm.deriveKey(MNEMONIC, 4) : vm.envUint("LIQUIDATOR_KEY");
    }

    /// @dev The next session after the demo clock's current time whose close starts a closure of 24 hours or
    /// more (the worked example is a Friday close).
    function _nextExtendedSession() internal view returns (uint64 open, uint64 close, uint64 nextOpen) {
        SessionCalendar.Context memory c = calendar.context(demo.clock().time());
        for (uint256 i = c.index + 1; i + 1 < calendar.sessionCount(); ++i) {
            (open, close) = calendar.sessionAt(i);
            (nextOpen,) = calendar.sessionAt(i + 1);
            if (nextOpen - close >= 24 hours && close - open == 390 minutes) return (open, close, nextOpen);
        }
        revert("no extended session left in the calendar");
    }
}
