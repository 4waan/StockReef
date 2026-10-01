// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";

contract StockReefLensTest is MarketFixture {
    StockReefLens internal lens;

    function setUp() public {
        _setUpMarket();
        lens = new StockReefLens(market);
        _openFriday();
        _lend(100_000 * USDG);
    }

    function _fundBuffer(address who, uint256 amount, uint256 cap) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(amount, who);
        escrow.authorize(0.65e18, cap, uint64(MON_CLOSE));
        vm.stopPrank();
    }

    function test_market_reportsBookAndWindows() public {
        _workedExample(bob);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(uint256(m.policy.state), uint256(SessionRiskPolicy.State.OPEN));
        assertTrue(m.simulationClock);
        assertTrue(m.usesPeg);
        assertEq(m.pegLabel, "Test peg: 1 USDG = 1 USD");
        assertEq(m.cash, 92_800 * USDG);
        assertEq(m.activeAccounts, 1);
        assertEq(m.maxAccounts, 32);
        assertApproxEqAbs(m.utilizationWad, 0.072e18, 1e12);
        assertEq(m.lenderWindowOpensAt, 0, "open now");
        assertEq(m.lenderWindowClosesAt, FRI_CLOSE - 120 minutes);

        _tick(FRI_CLOSE - 60 minutes);
        m = lens.marketView();
        assertEq(m.lenderWindowOpensAt, MON_OPEN + 15 minutes, "earliest next window");
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes);
    }

    function test_market_flagsAPendingCorporateAction() public {
        tsla.scheduleMultiplier(1.01e18, block.timestamp + 1 days);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(m.pendingMultiplier, 1.01e18);
        assertEq(m.multiplierEffectiveAt, block.timestamp + 1 days);
    }

    function test_account_closurePlanForTheWorkedExample() public {
        _workedExample(bob);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertEq(v.collateralValue, 10_000 * USDG);
        assertApproxEqAbs(v.ltvWad, 0.72e18, 1e9);
        assertEq(v.planTargetWad, 0.65e18, "Friday's close is EXTENDED");
        assertApproxEqAbs(v.repayToTarget, _golden(".worked_example.cash_required_usdg"), 1);
        assertApproxEqAbs(v.addCollateralValueToTarget, _golden(".worked_example.add_collateral_value_usdg"), 2); // 1 unit / 0.65
        assertEq(v.addCollateralRawToTarget, gate.rawForValue(v.addCollateralValueToTarget, 400e18, Math.Rounding.Ceil));

        // If nothing is done, a liquidator can trim it at F: the worked example's 2,077.15 at 2%.
        assertTrue(v.trimmableAtFinal);
        assertApproxEqAbs(v.trimAtFinalRepay, _golden(".worked_example.trim_repay_usdg"), 3); // 1 unit of debt rounding / 0.337
        assertEq(v.trimAtFinalBonusWad, 0.02e18);
        assertFalse(v.trimNow.eligible, "72% is under the OPEN threshold");
        assertFalse(v.missedExecution);
    }

    function test_account_borrowCapacityMatchesWhatBorrowAccepts() public {
        _fundCollateral(alice, 25 * TOKEN);
        uint256 capacity = lens.accountView(alice).borrowCapacity;
        assertApproxEqAbs(capacity, 7_500 * USDG, 2);
        _borrow(alice, capacity);

        _tick(FRI_CLOSE - 30 minutes);
        assertEq(lens.accountView(alice).borrowCapacity, 0, "final window");
    }

    function test_account_bufferCoverageAndExecution() public {
        _workedExample(alice);
        _fundBuffer(alice, 1_000 * USDG, 1_000 * USDG);
        StockReefLens.AccountView memory v = lens.accountView(alice);
        assertTrue(v.bufferActive);
        assertFalse(v.bufferCommitted);
        assertApproxEqAbs(v.bufferCoverage, 700 * USDG, 1, "covers the plan");
        assertEq(v.bufferExecutableNow, 0, "not before A");

        _tick(FRI_CLOSE - 120 minutes);
        v = lens.accountView(alice);
        assertTrue(v.bufferCommitted);
        assertEq(v.bufferExecutableNow, v.bufferCoverage);
        assertGt(v.bufferExecutableNow, 0);
    }

    function test_account_missedExecutionIsDetectedAtTheClose() public {
        _workedExample(alice);
        _fundBuffer(alice, 1_000 * USDG, 1_000 * USDG);
        _workedExample(bob);
        _workedExample(carol);

        _tick(FRI_CLOSE - 45 minutes);
        escrow.executeBuffer(alice);
        vm.prank(liquidator);
        market.trim(bob, type(uint256).max, 0, block.timestamp);

        _tick(FRI_CLOSE + 1 hours);
        StockReefLens.AccountView[] memory all = lens.activeAccountViews();
        assertEq(all.length, 3);
        for (uint256 i; i < all.length; ++i) {
            if (all[i].account == carol) {
                assertTrue(all[i].missedExecution, "carol entered the closure above plan");
                assertApproxEqAbs(all[i].exposure, 700 * USDG, 2 * USDG);
            } else {
                assertFalse(all[i].missedExecution, "alice and bob reached 65%");
            }
        }
    }
}
