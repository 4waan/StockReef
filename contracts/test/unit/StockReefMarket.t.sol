// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

contract StockReefMarketTest is MarketFixture {
    function setUp() public {
        _setUpMarket();
    }

    // ================================================================ golden trim arithmetic

    function _snapFor(uint256 targetWad, uint256 priceWad) internal pure returns (SessionRiskPolicy.Snapshot memory s) {
        s.targetWad = targetWad;
        s.priceWad = priceWad;
    }

    function test_trimMath_matchesGoldenWorkedExample() public view {
        (uint256 repaid, uint256 out, bool full) = market.trimAmounts(
            _golden(".worked_example.collateral_raw"),
            _golden(".worked_example.debt_usdg"),
            _golden(".worked_example.value_usdg"),
            _snapFor(_golden(".worked_example.target_wad"), _golden(".worked_example.price_wad")),
            _golden(".worked_example.bonus_wad"),
            type(uint256).max
        );
        assertEq(repaid, _golden(".worked_example.trim_repay_usdg"));
        assertEq(out, _golden(".worked_example.trim_seized_raw"));
        assertTrue(full);
    }

    function test_trimMath_matchesGoldenDemoExample() public view {
        (uint256 repaid, uint256 out,) = market.trimAmounts(
            _golden(".demo_example.collateral_raw"),
            _golden(".demo_example.debt_usdg"),
            _golden(".demo_example.value_usdg"),
            _snapFor(_golden(".demo_example.target_wad"), _golden(".demo_example.price_wad")),
            _golden(".demo_example.bonus_wad"),
            type(uint256).max
        );
        assertEq(repaid, _golden(".demo_example.trim_repay_usdg"));
        assertEq(out, _golden(".demo_example.trim_seized_raw"));
    }

    function test_trimMath_insolventPositionTakesAllCollateral() public view {
        (uint256 repaid, uint256 out, bool full) =
            market.trimAmounts(25 * TOKEN, 10_000 * USDG, 10_000 * USDG, _snapFor(0.65e18, 400e18), 0.05e18, 1e30);
        assertEq(repaid, uint256(10_000 * USDG) * 100 / 105, "floor(V / 1.05)");
        assertEq(out, 25 * TOKEN);
        assertFalse(full);
    }

    function test_trimMath_partialFillIsCappedByMaxRepay() public view {
        (uint256 repaid, uint256 out, bool full) =
            market.trimAmounts(25 * TOKEN, 7_200 * USDG, 10_000 * USDG, _snapFor(0.65e18, 400e18), 0.02e18, 500 * USDG);
        assertEq(repaid, 500 * USDG);
        assertEq(out, uint256(500 * USDG) * 102 / 100 * TOKEN / (400 * USDG));
        assertFalse(full);
    }

    // ================================================================ lenders

    function test_lender_depositsOnlyInTheOpenWindow() public {
        assertEq(market.maxDeposit(lender), 0, "closed before the open");
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(1_000 * USDG, lender);

        _openFriday();
        assertEq(market.maxDeposit(lender), type(uint256).max);
        _lend(10_000 * USDG);
        assertEq(market.totalAssets(), 10_000 * USDG);
        assertEq(market.balanceOf(lender), 10_000 * USDG * 1e6, "decimals offset of 6");

        _tick(FRI_CLOSE - 120 minutes);
        assertEq(market.maxDeposit(lender), 0, "locked from A");
        assertEq(market.maxWithdraw(lender), 0);
        assertEq(market.maxRedeem(lender), 0);
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdraw(1 * USDG, lender, lender);
    }

    function test_lender_withdrawalsAreLimitedByIdleCash() public {
        _openFriday();
        _lend(10_000 * USDG);
        _workedExample(bob);
        assertEq(market.cash(), 2_800 * USDG);
        assertEq(market.maxWithdraw(lender), 2_800 * USDG);

        vm.prank(lender);
        vm.expectRevert();
        market.withdraw(2_800 * USDG + 1, lender, lender);
        vm.prank(lender);
        market.withdraw(2_800 * USDG, lender, lender);
        assertEq(market.cash(), 0);
    }

    function test_lender_checkedVariantsEnforceSlippage() public {
        _openFriday();
        vm.prank(lender);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.depositChecked(1_000 * USDG, lender, 1_000 * USDG * 1e6 + 1);

        vm.prank(lender);
        uint256 shares = market.depositChecked(1_000 * USDG, lender, 1_000 * USDG * 1e6);
        vm.prank(lender);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.redeemChecked(shares, lender, lender, 1_000 * USDG + 1);
    }

    function test_lender_earnsInterestThroughTheBook() public {
        _openFriday();
        _lend(10_000 * USDG);
        _workedExample(bob);
        _tick(MON_OPEN + 5 minutes);
        _tick(MON_OPEN + 15 minutes);
        uint256 assets = market.totalAssets();
        assertGt(assets, 10_000 * USDG, "interest accrued over the weekend");
        assertEq(assets, market.cash() + market.debtOf(bob));
    }

    function test_lender_runOffStopsDeposits() public {
        _openFriday();
        _lend(10_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 7_500 * USDG - 1);
        uint256 idle = market.cash();
        vm.prank(lender);
        market.withdraw(idle, lender, lender);

        _setPrice(1); // collateral now worth nothing
        _tick(FRI_OPEN + 2 hours);
        assertEq(market.totalAssets(), 0);
        assertGt(market.totalSupply(), 0);
        assertEq(market.maxDeposit(lender), 0, "run-off: no recapitalisation through share conversion");
    }

    // ================================================================ borrowing

    function test_borrow_withinTheOpenLimit() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.AboveBorrowLimit.selector);
        market.borrow(7_500 * USDG + 1, bob);
        _borrow(bob, 7_499 * USDG);
        assertEq(usdg.balanceOf(bob), 7_499 * USDG);
        assertEq(market.activeAccounts().length, 1);
    }

    function test_borrow_belowTheMinimumLoanReverts() public {
        _openFriday();
        _lend(1_000 * USDG);
        _fundCollateral(bob, TOKEN);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.BelowMinimumLoan.selector);
        market.borrow(MIN_LOAN - 1, bob);
    }

    function test_borrow_limitFallsDuringPreparation() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 45 minutes);
        assertEq(s.borrowLimitWad, 666666666666666666);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.AboveBorrowLimit.selector);
        market.borrow(6_700 * USDG, bob);
        _borrow(bob, 6_600 * USDG);
    }

    function test_borrow_blockedFromTheFinalWindowUntilCreditReturns() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        uint256[5] memory times = [
            uint256(FRI_CLOSE - 30 minutes),
            FRI_CLOSE,
            MON_OPEN + 1 minutes,
            MON_OPEN + 5 minutes,
            MON_OPEN + 14 minutes
        ];
        for (uint256 i; i < times.length; ++i) {
            _tick(times[i]);
            vm.prank(bob);
            vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
            market.borrow(1_000 * USDG, bob);
        }
        _tick(MON_OPEN + 15 minutes);
        _borrow(bob, 1_000 * USDG);
    }

    function test_borrow_utilizationCapOf90Percent() public {
        _openFriday();
        _lend(10_000 * USDG);
        _fundCollateral(bob, 1_000 * TOKEN);
        _borrow(bob, 8_999 * USDG);
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(2 * USDG, bob);
    }

    function test_borrow_accountCapOf32() public {
        _openFriday();
        _lend(100_000 * USDG);
        address[] memory who = new address[](33);
        for (uint256 i; i < 33; ++i) {
            who[i] = address(uint160(0x1000 + i));
            _fundCollateral(who[i], TOKEN);
        }
        for (uint256 i; i < 32; ++i) {
            _borrow(who[i], MIN_LOAN);
        }
        assertEq(market.activeAccounts().length, 32);
        vm.prank(who[32]);
        vm.expectRevert(StockReefMarket.AccountCapReached.selector);
        market.borrow(MIN_LOAN, who[32]);

        // Repaying in full frees a slot.
        usdg.mint(who[3], 1 * USDG);
        vm.startPrank(who[3]);
        usdg.approve(address(market), type(uint256).max);
        market.repay(type(uint256).max, who[3]);
        vm.stopPrank();
        assertEq(market.activeAccounts().length, 31);
        _borrow(who[32], MIN_LOAN);
    }

    function test_borrow_blockedWhileTheMarketIsImpaired() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(carol, 25 * TOKEN);
        _borrow(carol, 7_499 * USDG);
        _fundCollateral(alice, 25 * TOKEN);

        _setPrice(312e8); // carol: 7,499 / 7,800 = 96% > 1 / 1.05
        _tick(FRI_OPEN + 2 hours);
        assertTrue(market.bookValuation().impaired);
        vm.prank(alice);
        vm.expectRevert(StockReefMarket.MarketImpaired.selector);
        market.borrow(100 * USDG, alice);
    }

    function test_borrow_activeBufferAuthorizationBlocksFromA() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(alice, 25 * TOKEN);
        vm.prank(alice);
        escrow.authorize(0.65e18, 1_000 * USDG, uint64(MON_CLOSE));
        _borrow(alice, 1_000 * USDG); // before A: allowed

        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.borrow(100 * USDG, alice);
    }

    // ================================================================ repayment

    function test_repay_worksInEveryStateWithoutAPrice() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        vm.prank(bob);
        usdg.approve(address(market), type(uint256).max);

        vm.warp(FRI_CLOSE + 1 days); // closed, feed stale
        vm.prank(bob);
        market.repay(100 * USDG, bob);

        vm.prank(guardian);
        gate.stop();
        assertEq(uint256(_state()), uint256(SessionRiskPolicy.State.GUARDED));
        vm.prank(bob);
        market.repay(100 * USDG, bob);
        assertApproxEqAbs(market.debtOf(bob), 7_000 * USDG, 5 * USDG);
    }

    function test_repay_inFullClearsExactlyAndFreesTheSlot() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_OPEN + 3 hours);
        uint256 debt = market.debtOf(bob);
        assertGt(debt, 7_200 * USDG);
        usdg.mint(bob, debt);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        uint256 paid = market.repay(type(uint256).max, bob);
        vm.stopPrank();
        assertEq(paid, debt);
        assertEq(market.debtOf(bob), 0);
        assertEq(market.totalDebtShares(), 0);
        assertEq(market.activeAccounts().length, 0);
    }

    function test_repay_anyoneCanRepayForABorrower() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        vm.prank(liquidator);
        market.repay(200 * USDG, bob);
        assertApproxEqAbs(market.debtOf(bob), 7_000 * USDG, 1);
    }

    // ================================================================ collateral

    function test_collateral_zeroDebtWithdrawalNeedsNoPrice() public {
        _fundCollateral(bob, 2 * TOKEN); // before any price exists
        vm.prank(bob);
        market.withdrawCollateral(2 * TOKEN, bob);
        assertEq(tsla.balanceOf(bob), 2 * TOKEN);
    }

    function test_collateral_withdrawalWithDebtFollowsTheBorrowLimit() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 5_000 * USDG);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.AboveBorrowLimit.selector);
        market.withdrawCollateral(9 * TOKEN, bob); // 5,000 / 6,400 = 78%
        vm.prank(bob);
        market.withdrawCollateral(8 * TOKEN, bob); // 5,000 / 6,800 = 73.5%

        _tick(FRI_CLOSE + 1 hours);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdrawCollateral(1, bob);
    }

    function test_collateral_frozenTransfersRevertAndPreserveBalances() public {
        _fundCollateral(bob, TOKEN);
        tsla.setFrozen(bob, true);
        vm.prank(bob);
        vm.expectPartialRevert(MockStockToken.AccountFrozen.selector);
        market.withdrawCollateral(TOKEN, bob);
        assertEq(market.collateralOf(bob), TOKEN);
    }

    // ================================================================ interest

    function test_interest_followsTheGoldenIndex() public {
        string[4] memory points = ["1d", "30d", "1y", "5y"];
        uint64 epoch = market.epoch();
        for (uint256 i; i < points.length; ++i) {
            string memory key = string.concat(".interest.points.", points[i]);
            vm.warp(epoch + vm.parseJsonUint(_goldenJson(), string.concat(key, ".seconds")));
            assertApproxEqRel(market.debtIndex(), _golden(string.concat(key, ".index_wad")), 1e3, points[i]);
        }
    }

    function test_interest_isIndependentOfCheckpoints() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _fundCollateral(carol, 25 * TOKEN);
        _borrow(bob, 5_000 * USDG);
        _borrow(carol, 5_000 * USDG);
        for (uint256 i = 1; i <= 20; ++i) {
            _tick(FRI_OPEN + 15 minutes + i * 5 minutes); // refreshes and someone else's activity
            vm.prank(liquidator);
            market.repay(1, carol);
        }
        assertApproxEqAbs(market.debtOf(bob), market.debtOf(carol) + 20, 20);
    }

    function testFuzz_interest_borrowAndRepayCannotProfit(uint256 amount, uint256 dt) public {
        _openFriday();
        _lend(1_000_000 * USDG);
        _fundCollateral(bob, 10_000 * TOKEN);
        amount = bound(amount, MIN_LOAN, 500_000 * USDG);
        dt = bound(dt, 0, 400 days);
        _borrow(bob, amount);
        vm.warp(block.timestamp + dt);
        uint256 debt = market.debtOf(bob);
        assertGe(debt, amount);
        usdg.mint(bob, debt);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        uint256 paid = market.repay(type(uint256).max, bob);
        vm.stopPrank();
        assertGe(paid, amount);
        assertEq(market.debtOf(bob), 0);
    }

    // ================================================================ trims

    function _ltv(address who) internal view returns (uint256) {
        return Math.mulDiv(market.debtOf(who), 1e18, gate.valueOf(market.collateralOf(who), uint256(answer) * 1e10));
    }

    function test_trim_workedExampleAt1515() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_CLOSE - 45 minutes);
        uint256 debt = market.debtOf(bob);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(bob, type(uint256).max, 0, block.timestamp);

        // The worked example's 2,077.15 plus the effect of a few hours of interest.
        assertApproxEqAbs(repaid, _golden(".worked_example.trim_repay_usdg"), 2 * USDG);
        assertApproxEqAbs(_ltv(bob), 0.65e18, 1e12);
        assertLe(market.debtOf(bob) * 1e18, 0.65e18 * gate.valueOf(market.collateralOf(bob), 400e18) + 1e18);
        assertEq(tsla.balanceOf(liquidator), out);
        assertApproxEqRel(gate.valueOf(out, 400e18), repaid * 102 / 100, 1e12, "2% scheduling bonus");
        assertEq(market.debtOf(bob), debt - repaid);
    }

    function test_trim_notEligibleAtOrBelowTheThreshold() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_CLOSE - 60 minutes); // LT 73.3%
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotEligible.selector);
        market.trim(bob, type(uint256).max, 0, block.timestamp);
    }

    function test_trim_finalWindowYesClosedNo() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _workedExample(carol);
        _tick(FRI_CLOSE - 1);
        vm.prank(liquidator);
        market.trim(bob, type(uint256).max, 0, block.timestamp);

        _tick(FRI_CLOSE);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.trim(carol, type(uint256).max, 0, block.timestamp);
    }

    function test_trim_respectsDeadlineAndSlippage() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_CLOSE - 45 minutes);
        vm.startPrank(liquidator);
        vm.expectRevert(StockReefMarket.DeadlinePassed.selector);
        market.trim(bob, type(uint256).max, 0, block.timestamp - 1);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.trim(bob, type(uint256).max, 100 * TOKEN, block.timestamp);
        vm.stopPrank();
    }

    function test_trim_partialFillReportsRemainingExcess() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_CLOSE - 45 minutes);
        vm.prank(liquidator);
        (uint256 repaid,) = market.trim(bob, 500 * USDG, 0, block.timestamp);
        assertEq(repaid, 500 * USDG);
        assertGt(_ltv(bob), 0.65e18, "partial fills do not claim the target");
    }

    function test_trim_openTrimAboveEightyUsesDistressTerms() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _setPrice(340e8); // 7,200 / 8,500 = 84.7%
        _tick(FRI_OPEN + 2 hours);
        vm.prank(liquidator);
        vm.expectEmit(true, true, false, false, address(market));
        emit StockReefMarket.Trimmed(bob, liquidator, 0, 0, 0.05e18, SessionRiskPolicy.State.OPEN, 0, 0);
        market.trim(bob, type(uint256).max, 0, block.timestamp);
        assertApproxEqAbs(_ltv(bob), 0.75e18, 1e12);
    }

    function test_trim_reopeningGapExhaustsCollateralAndWritesOffTheResidual() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(carol); // nobody acted before the close

        _setPrice(260e8); // a 35% gap at the reopening
        SessionRiskPolicy.Snapshot memory s = _tick(MON_OPEN + 5 minutes);
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        uint256 debt = market.debtOf(carol);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, block.timestamp);
        assertEq(out, 25 * TOKEN);
        assertEq(repaid, uint256(6_500 * USDG) * 100 / 105);
        assertEq(market.debtOf(carol), 0);
        assertEq(market.totalBadDebt(), debt - repaid);
        // The spec's simplified unmanaged shortfall (1,009.52) plus weekend interest.
        assertApproxEqAbs(market.totalBadDebt(), 1_009_52 * USDG / 100, 7 * USDG);
        assertEq(market.activeAccounts().length, 0);
    }

    function test_trim_insolventPartialFillWritesNothingOff() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(carol);
        _setPrice(260e8);
        _tick(MON_OPEN + 5 minutes);
        vm.prank(liquidator);
        market.trim(carol, 1_000 * USDG, 0, block.timestamp);
        assertGt(market.collateralOf(carol), 0);
        assertGt(market.debtOf(carol), 0);
        assertEq(market.totalBadDebt(), 0);
    }

    // ================================================================ lender valuation

    function test_valuation_marksAKnownShortfallBeforeAnyTrim() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(carol);
        _setPrice(260e8);
        _tick(MON_OPEN + 5 minutes);

        StockReefMarket.Book memory b = market.bookValuation();
        assertFalse(b.indicative);
        assertTrue(b.impaired);
        assertEq(b.recoverable, uint256(6_500 * USDG) * 100 / 105);
        assertEq(market.totalAssets(), market.cash() + b.recoverable);
        assertLt(market.totalAssets(), 100_000 * USDG, "lenders see the shortfall now, not after the first exit");
    }

    function test_valuation_isIndicativeWhilePricesAreLocked() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        vm.warp(FRI_CLOSE + 1 days);
        StockReefMarket.Book memory b = market.bookValuation();
        assertTrue(b.indicative);
        assertEq(b.priceWad, 400e18);
    }
}
