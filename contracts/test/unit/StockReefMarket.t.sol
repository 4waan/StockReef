// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";

/// @notice A loan token with configurable decimals and open minting, for markets that do not lend MockUSDG.
contract MarketLoanToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Market test dollar", "mUSD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A 6-decimal loan token that, once armed, calls back into `target` with `data` the next time a transfer
/// touches `target`, and records how that call ended.
contract MarketHookedLoanToken is MarketLoanToken {
    address public target;
    bytes public data;
    bool public armed;
    bool public reentered;
    bytes public reentryError;

    constructor() MarketLoanToken(6) {}

    function arm(address target_, bytes calldata data_) external {
        (target, data, armed, reentered) = (target_, data_, true, false);
        delete reentryError;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && (from == target || to == target)) {
            armed = false;
            (bool ok, bytes memory err) = target.call(data);
            (reentered, reentryError) = (ok, err);
        }
    }
}

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

    /// @dev Storage touched earlier in a test is warm; mark it cold so measurements match a fresh transaction.
    function _coolAll() internal {
        address[8] memory all = [
            address(market),
            address(gate),
            address(policy),
            address(cal),
            address(stockFeed),
            address(tsla),
            address(usdg),
            address(escrow)
        ];
        for (uint256 i; i < all.length; ++i) {
            vm.cool(all[i]);
        }
    }

    /// @dev Spec §7: publish measured gas for the full-cap valuation (32 accounts with debt).
    function test_gas_fullCapValuation() public {
        _openFriday();
        _lend(100_000 * USDG);
        for (uint256 i; i < 31; ++i) {
            address who = address(uint160(0x2000 + i));
            _fundCollateral(who, TOKEN);
            _borrow(who, 100 * USDG);
        }
        _fundCollateral(bob, TOKEN);
        _coolAll();
        uint256 g = gasleft();
        _borrow(bob, 100 * USDG); // the 32nd account, valued against all others
        uint256 borrowGas = g - gasleft();
        _coolAll();
        g = gasleft();
        market.totalAssets();
        uint256 valuationGas = g - gasleft();
        usdg.mint(lender, 1_000 * USDG);
        _coolAll();
        g = gasleft();
        _lend(1_000 * USDG);
        uint256 depositGas = g - gasleft();
        assertEq(market.activeAccounts().length, 32);
        assertLt(depositGas, 3_000_000, "a full-cap lender deposit fits comfortably in a block");

        string memory k = "gas";
        vm.serializeUint(k, "activeAccounts", 32);
        vm.serializeUint(k, "borrowAt32", borrowGas);
        vm.serializeUint(k, "totalAssetsViewAt32", valuationGas);
        string memory json = vm.serializeUint(k, "lenderDepositAt32", depositGas);
        vm.writeJson(json, "../evidence/gas.json");
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

    function test_repay_cannotLeaveDustBelowTheMinimumLoan() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 10 * USDG);
        usdg.mint(bob, 1 * USDG); // share rounding adds up to one base unit of debt
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        uint256 debt = market.debtOf(bob);
        vm.expectPartialRevert(StockReefMarket.BelowMinimumLoan.selector);
        market.repay(debt - MIN_LOAN + 1, bob); // would leave 4.999999 USDG
        market.repay(debt - MIN_LOAN, bob); // leaves exactly the minimum
        assertApproxEqAbs(market.debtOf(bob), MIN_LOAN, 1);
        market.repay(type(uint256).max, bob); // or everything
        vm.stopPrank();
        assertEq(market.debtOf(bob), 0);
        assertEq(market.activeAccounts().length, 0);
    }

    // ================================================================ wind-down after the calendar

    function test_windDown_lendersExitAgainstCashAfterTheCalendarEnds() public {
        _openFriday();
        _lend(10_000 * USDG);
        _workedExample(bob);
        uint256 shares = market.balanceOf(lender);

        vm.warp(cal.lastOpen() + 1 hours); // the last loaded session has no next open: coverage is over
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertTrue(s.windDown);
        assertEq(market.maxDeposit(lender), 0, "no new deposits");
        assertEq(market.maxWithdraw(lender), market.cash(), "exit is limited to idle cash");

        // Repayments keep flowing to lenders.
        uint256 debt = market.debtOf(bob);
        usdg.mint(bob, debt);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        market.repay(type(uint256).max, bob);
        vm.stopPrank();

        vm.prank(lender);
        uint256 assets = market.redeem(shares, lender, lender);
        assertGt(assets, 10_000 * USDG, "principal plus the interest that was repaid");
        assertEq(market.totalSupply(), 0);

        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.borrow(10 * USDG, bob);
    }

    function test_windDown_doesNotApplyBeforeCoverageStarts() public view {
        assertFalse(policy.evaluate(gate.quote(), cal.firstOpen() - 1).windDown);
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

    // ================================================================ configuration

    /// INV-X-01, INV-X-04
    function test_config_sharesOneGateClockAndTokenPair() public view {
        assertEq(address(market.gate()), address(policy.gate()));
        assertEq(address(market.clock()), address(policy.clock()));
        assertEq(address(market.clock()), address(gate.clock()));
        assertEq(market.asset(), gate.loanToken());
        assertEq(address(market.collateralToken()), address(gate.token()));
        assertEq(market.VALUE_SCALE(), gate.VALUE_SCALE(), "VALUE_SCALE is copied");
        assertEq(address(escrow.market()), address(market));
        assertEq(address(escrow.policy()), address(policy));
        assertEq(address(escrow.gate()), address(gate));
        assertEq(address(escrow.clock()), address(clock));
        assertEq(address(escrow.loanToken()), address(usdg));
        assertEq(market.epoch(), FRI_OPEN - 1 hours, "the index starts at deployment");
        // The market takes whatever clock the policy has, a simulation clock included.
        assertTrue(market.clock().isSimulation());
    }

    /// INV-X-01
    function test_config_rejectsATokenPairTheGateDoesNotPrice() public {
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(IERC20(address(tsla)), tsla, policy, MIN_LOAN, "x", "x");
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(usdg, IERC20(address(usdg)), policy, MIN_LOAN, "x", "x");
        MarketLoanToken other = new MarketLoanToken(6);
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(other, tsla, policy, MIN_LOAN, "x", "x");
    }

    /// INV-X-07
    function test_config_parametersNeverChangeAndThereIsNoAdmin() public {
        bytes32 before = keccak256(
            abi.encode(
                market.minLoan(),
                market.VALUE_SCALE(),
                market.epoch(),
                address(market.gate()),
                address(market.policy()),
                address(market.clock()),
                address(market.escrow()),
                address(market.collateralToken()),
                market.asset(),
                market.MAX_ACCOUNTS(),
                market.UTILIZATION_CAP(),
                market.RECOVERY_HAIRCUT(),
                market.RATE_PER_SECOND()
            )
        );
        // A whole lifecycle: lending, borrowing, a trim, a stop and a repayment.
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_CLOSE - 45 minutes);
        vm.prank(liquidator);
        market.trim(bob, type(uint256).max, 0, block.timestamp);
        vm.prank(guardian);
        gate.stop();
        vm.prank(liquidator);
        market.repay(100 * USDG, bob);
        bytes32 afterwards = keccak256(
            abi.encode(
                market.minLoan(),
                market.VALUE_SCALE(),
                market.epoch(),
                address(market.gate()),
                address(market.policy()),
                address(market.clock()),
                address(market.escrow()),
                address(market.collateralToken()),
                market.asset(),
                market.MAX_ACCOUNTS(),
                market.UTILIZATION_CAP(),
                market.RECOVERY_HAIRCUT(),
                market.RATE_PER_SECOND()
            )
        );
        assertEq(afterwards, before, "every parameter is fixed");

        string[5] memory admin =
            ["owner()", "transferOwnership(address)", "pause()", "setMinLoan(uint256)", "upgradeTo(address)"];
        for (uint256 i; i < admin.length; ++i) {
            (bool ok,) = address(market).call(abi.encodeWithSignature(admin[i], address(this)));
            assertFalse(ok, admin[i]);
        }
    }

    // ================================================================ borrowing: limits and movements

    /// INV-MKT-30, INV-MKT-56, INV-MKT-27
    function test_borrow_paysExactlyTheAmountToTheReceiver() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        uint256 amount = 1_234 * USDG + 5;
        uint256 cash = market.cash();
        uint256 held = usdg.balanceOf(address(market));
        vm.prank(bob);
        market.borrow(amount, alice);
        assertEq(usdg.balanceOf(alice), amount, "the receiver gets exactly the amount");
        assertEq(usdg.balanceOf(bob), 0);
        assertEq(cash - market.cash(), amount);
        assertEq(held - usdg.balanceOf(address(market)), amount);
        (, uint256 bobShares,) = market.accountOf(bob);
        (, uint256 aliceShares,) = market.accountOf(alice);
        assertGt(bobShares, 0, "the debt is the caller's");
        assertEq(aliceShares, 0);
    }

    /// INV-MKT-30 (mutant: amount > cash to >=)
    function test_borrow_allIdleCashFailsOnTheUtilizationCapFirst() public {
        _openFriday();
        _lend(10_000 * USDG);
        _fundCollateral(bob, 1_000 * TOKEN);
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(10_000 * USDG, bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(StockReefMarket.InsufficientCash.selector, 10_000 * USDG + 1, 10_000 * USDG)
        );
        market.borrow(10_000 * USDG + 1, bob);
    }

    /// INV-MKT-30, INV-MKT-32 (mutant: utilization > to >=)
    function test_borrow_exactlyNinetyPercentUtilizationIsAllowed() public {
        _openFriday();
        _lend(10_000 * USDG);
        _fundCollateral(bob, 1_000 * TOKEN);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(9_000 * USDG + 1, bob);
        vm.revertToState(snap);
        _borrow(bob, 9_000 * USDG);
        assertEq(market.cash(), 1_000 * USDG);
    }

    /// INV-X-17, INV-MKT-38
    function test_borrow_bufferAuthorizationBlocksFromAOnlyUntilItsExpiry() public {
        _openFriday();
        _lend(100_000 * USDG);
        _fundCollateral(alice, 25 * TOKEN);
        uint64 expiry = FRI_CLOSE - 100 minutes; // after A, before F
        vm.prank(alice);
        escrow.authorize(0.65e18, 1_000 * USDG, expiry);
        _borrow(alice, 1_000 * USDG); // before A

        _tick(FRI_CLOSE - 115 minutes);
        vm.startPrank(alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.borrow(100 * USDG, alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.withdrawCollateral(1 * TOKEN, alice);
        vm.stopPrank();

        _tick(expiry); // the borrower's own expiry ends the block, still in PRE_CLOSE
        assertEq(uint256(_state()), uint256(SessionRiskPolicy.State.PRE_CLOSE));
        _borrow(alice, 100 * USDG);
        vm.prank(alice);
        market.withdrawCollateral(1 * TOKEN, alice);
    }

    // ================================================================ zero amounts and repayment edges

    /// INV-MKT-49, INV-MKT-35
    function test_zeroAmounts_revertForEveryBorrowerAndTrimCall() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        vm.startPrank(bob);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        market.depositCollateral(0, bob);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        market.withdrawCollateral(0, bob);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        market.borrow(0, bob);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        market.repay(0, bob);
        vm.stopPrank();
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        market.trim(bob, 0, 0, block.timestamp);
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.NoDebt.selector);
        market.repay(1, alice);
    }

    /// INV-MKT-35 (mutant: amount >= debt to >)
    function test_repay_exactlyTheDebtClearsTheAccount() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _tick(FRI_OPEN + 3 hours);
        uint256 debt = market.debtOf(bob);
        uint256 cash = market.cash();
        usdg.mint(alice, debt);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        assertEq(market.repay(debt, bob), debt);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), 0, "the payer paid exactly the debt");
        assertEq(market.cash() - cash, debt);
        (, uint256 shares,) = market.accountOf(bob);
        assertEq(shares, 0);
        assertEq(market.totalDebtShares(), 0);
        assertEq(market.activeAccounts().length, 0);
    }

    /// INV-MKT-34, INV-MKT-52
    function test_minLoan_trimDustCanOnlyBeRepaidInFullAndKeepsItsSlot() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(carol);
        _setPrice(302_39000000); // 302.39: carol sits just inside the insolvent branch
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_OPEN + 1 hours);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        assertTrue(q.eligible);
        assertGe(q.debt * (1e18 + q.bonusWad), q.value * 1e18, "insolvent branch");
        uint256 all = Math.mulDiv(q.value, 1e18, 1e18 + q.bonusWad);
        vm.prank(liquidator);
        market.trim(carol, all - 2 * USDG, 0, block.timestamp);

        uint256 dust = market.debtOf(carol);
        assertGt(dust, 0);
        assertLt(dust, MIN_LOAN, "a trim may leave debt below the minimum loan");
        assertGt(market.collateralOf(carol), 0);
        assertEq(market.activeAccounts().length, 1, "the dust keeps its slot");

        usdg.mint(alice, 10 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        vm.expectPartialRevert(StockReefMarket.BelowMinimumLoan.selector);
        market.repay(dust - 1, carol);
        assertEq(market.repay(type(uint256).max, carol), dust, "only a full repayment clears it");
        vm.stopPrank();
        assertEq(market.activeAccounts().length, 0, "and frees the slot");
    }

    // ================================================================ collateral

    /// INV-MKT-02, INV-MKT-56, INV-MKT-28
    function test_collateral_movesExactlyAndDonationsStayStuck() public {
        tsla.mint(address(market), TOKEN); // a donation
        tsla.mint(liquidator, 3 * TOKEN);
        vm.startPrank(liquidator);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(3 * TOKEN, bob); // anyone may fund any account
        vm.stopPrank();
        assertEq(tsla.balanceOf(liquidator), 0);
        assertEq(market.collateralOf(bob), 3 * TOKEN);
        assertEq(market.collateralOf(liquidator), 0);
        assertEq(tsla.balanceOf(address(market)), 4 * TOKEN);

        vm.prank(bob);
        market.withdrawCollateral(3 * TOKEN, alice);
        assertEq(tsla.balanceOf(alice), 3 * TOKEN, "the receiver gets exactly the amount");
        assertEq(market.collateralOf(bob), 0);
        assertEq(tsla.balanceOf(address(market)), TOKEN, "the donation is stuck");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StockReefMarket.InsufficientCollateral.selector, 1, 0));
        market.withdrawCollateral(1, bob);
    }

    /// INV-MKT-39, INV-MKT-36, INV-MKT-37
    function test_collateral_depositRepayAndDebtFreeWithdrawalNeedNeitherGateNorPolicy() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _fundCollateral(alice, 2 * TOKEN);
        tsla.mint(liquidator, TOKEN);
        vm.prank(liquidator);
        tsla.approve(address(market), type(uint256).max);

        vm.mockCallRevert(address(gate), bytes(""), "gate down");
        vm.mockCallRevert(address(policy), bytes(""), "policy down");
        vm.prank(liquidator);
        market.depositCollateral(TOKEN, bob);
        assertEq(market.collateralOf(bob), 26 * TOKEN);
        vm.prank(liquidator);
        market.repay(100 * USDG, bob);
        vm.prank(alice);
        market.withdrawCollateral(2 * TOKEN, alice);
        assertEq(tsla.balanceOf(alice), 2 * TOKEN);
        // A withdrawal backed by debt needs a price.
        vm.prank(bob);
        vm.expectRevert("gate down");
        market.withdrawCollateral(1, bob);
        vm.clearMockedCalls();
    }

    // ================================================================ lenders

    /// INV-MKT-44, INV-MKT-42 (mutants: mintChecked > to >=, withdrawChecked > to >=)
    function test_lender_checkedVariantsAcceptExactBoundsAndRejectOneBeyond() public {
        _openFriday();
        _lend(10_000 * USDG);
        _workedExample(bob);
        _tick(FRI_OPEN + 3 hours); // interest makes the share price irregular
        vm.startPrank(lender);

        uint256 a = 1_000 * USDG + 7;
        uint256 s = market.previewDeposit(a);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.depositChecked(a, lender, s + 1);
        assertEq(market.depositChecked(a, lender, s), s);

        uint256 shares = 1_000 * USDG * 1e6 + 12345;
        uint256 cost = market.previewMint(shares);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.mintChecked(shares, lender, cost - 1);
        assertEq(market.mintChecked(shares, lender, cost), cost);

        uint256 w = 500 * USDG + 7;
        uint256 burn = market.previewWithdraw(w);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.withdrawChecked(w, lender, lender, burn - 1);
        assertEq(market.withdrawChecked(w, lender, lender, burn), burn);

        uint256 r = 700 * USDG * 1e6 + 3;
        uint256 out = market.previewRedeem(r);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.redeemChecked(r, lender, lender, out + 1);
        assertEq(market.redeemChecked(r, lender, lender, out), out);
        vm.stopPrank();
    }

    /// INV-MKT-43 (mutant: maxRedeem converts cash with Ceil)
    function test_lender_maxRedeemFloorsTheCashConversion() public {
        _openFriday();
        _lend(10_000 * USDG);
        _workedExample(bob);
        uint256 checked;
        for (uint256 i; i < 20 && checked < 3; ++i) {
            _tick(FRI_OPEN + 3 hours + i * 7);
            uint256 cash = market.cash();
            uint256 num = cash * (market.totalSupply() + 1e6);
            uint256 den = market.totalAssets() + 1;
            if (num % den == 0) continue; // only an inexact conversion tells the roundings apart
            uint256 floorShares = num / den;
            assertLt(floorShares, market.balanceOf(lender), "the cash cap binds");
            assertEq(market.maxRedeem(lender), floorShares);
            ++checked;
        }
        assertEq(checked, 3);
    }

    /// INV-MKT-48
    function test_lender_onlyTheOwnerOrAnApprovedSpenderBurnsShares() public {
        _openFriday();
        _lend(10_000 * USDG);
        uint256 shares = 1_000 * USDG * 1e6;
        bytes memory noAllowance =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, liquidator, 0, shares);
        vm.prank(liquidator);
        vm.expectRevert(noAllowance);
        market.redeem(shares, liquidator, lender);

        vm.prank(lender);
        market.approve(liquidator, shares);
        uint256 supply = market.totalSupply();
        uint256 before = usdg.balanceOf(liquidator);
        vm.prank(liquidator);
        uint256 assets = market.redeem(shares, liquidator, lender);
        assertEq(market.allowance(lender, liquidator), 0, "the allowance is spent");
        assertEq(supply - market.totalSupply(), shares, "burned from the owner");
        assertEq(market.balanceOf(lender), 9_000 * USDG * 1e6);
        assertEq(usdg.balanceOf(liquidator) - before, assets);
    }

    /// INV-X-19 (mutant: _pullExact without the received-amount check)
    function test_transfers_shortInboundTransfersAreRejected() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        bytes[] memory rets = new bytes[](2);

        // Collateral.
        tsla.mint(alice, TOKEN);
        vm.prank(alice);
        tsla.approve(address(market), type(uint256).max);
        uint256 tslaHeld = tsla.balanceOf(address(market));
        rets[0] = abi.encode(tslaHeld);
        rets[1] = abi.encode(tslaHeld + TOKEN - 1);
        vm.mockCalls(address(tsla), abi.encodeCall(IERC20.balanceOf, (address(market))), rets);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockReefMarket.UnsupportedTransfer.selector, TOKEN, TOKEN - 1));
        market.depositCollateral(TOKEN, alice);
        vm.clearMockedCalls();

        // Loan token: lender deposit, repayment and trim.
        uint256 held = usdg.balanceOf(address(market));
        rets[0] = abi.encode(held);
        rets[1] = abi.encode(held + 100 * USDG - 1);
        vm.mockCalls(address(usdg), abi.encodeCall(IERC20.balanceOf, (address(market))), rets);
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.UnsupportedTransfer.selector);
        market.deposit(100 * USDG, lender);
        vm.clearMockedCalls();

        vm.mockCalls(address(usdg), abi.encodeCall(IERC20.balanceOf, (address(market))), rets);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.UnsupportedTransfer.selector);
        market.repay(100 * USDG, bob);
        vm.clearMockedCalls();

        _tick(FRI_CLOSE - 45 minutes);
        held = usdg.balanceOf(address(market));
        rets[0] = abi.encode(held);
        rets[1] = abi.encode(held + 100 * USDG - 1);
        vm.mockCalls(address(usdg), abi.encodeCall(IERC20.balanceOf, (address(market))), rets);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.UnsupportedTransfer.selector);
        market.trim(bob, 100 * USDG, 0, block.timestamp);
        vm.clearMockedCalls();

        assertEq(usdg.balanceOf(address(market)), market.cash(), "nothing was credited");
        assertEq(market.collateralOf(alice), 0);
    }

    // ================================================================ trims: boundaries

    /// INV-MKT-22, INV-MKT-40 (mutant: slippage < to <=)
    function test_trim_exactMinCollateralOutIsAccepted() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 45 minutes);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, s, type(uint256).max);
        assertTrue(q.eligible);
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.Slippage.selector);
        market.trim(bob, type(uint256).max, q.collateralOut + 1, block.timestamp);
        vm.prank(liquidator);
        (, uint256 out) = market.trim(bob, type(uint256).max, q.collateralOut, block.timestamp);
        assertEq(out, q.collateralOut);
    }

    /// @dev The policy snapshot with trims on, a fixed price, LT and target, and no buffers.
    function _craftedSnap(uint256 ltWad, bool canTrim) internal view returns (SessionRiskPolicy.Snapshot memory s) {
        s = policy.snapshot();
        s.ltWad = ltWad;
        s.canTrim = canTrim;
        s.canBuffer = false;
        s.state = SessionRiskPolicy.State.OPEN;
        s.priceWad = 400e18;
        s.targetWad = 0.65e18;
    }

    /// INV-MKT-27, INV-MKT-40 (mutant: eligibility > to >=)
    function test_trim_positionExactlyAtTheThresholdIsNotEligible() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        uint256 debt = market.debtOf(bob);
        // Value is 10,000 USDG = 1e10 base units, so LTV is exactly debt * 1e8 in WAD.
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, _craftedSnap(debt * 1e8, true), type(uint256).max);
        assertEq(q.value, 10_000 * USDG);
        assertFalse(q.eligible, "LTV == LT is not eligible");
        assertEq(q.repaid, 0);
        q = market.quoteTrim(bob, _craftedSnap(debt * 1e8 - 1, true), type(uint256).max);
        assertTrue(q.eligible, "one wei above is");
    }

    /// INV-MKT-27 (mutant: quoteTrim without the canTrim conjunct)
    function test_trim_quoteRespectsTheSnapshotPermission() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, _craftedSnap(0.5e18, false), type(uint256).max);
        assertFalse(q.eligible);
        assertEq(q.repaid, 0);
        assertEq(q.collateralOut, 0);
        assertTrue(market.quoteTrim(bob, _craftedSnap(0.5e18, true), type(uint256).max).eligible);
    }

    /// INV-MKT-20, INV-MKT-55 (mutant: insolvency test >= to >)
    function test_trimMath_insolvencyBoundaryTakesAllCollateral() public view {
        SessionRiskPolicy.Snapshot memory s;
        s.targetWad = 0.65e18;
        s.priceWad = 420e18;
        uint256 coll = 25 * TOKEN + 1; // worth floor(25.000...1 * 420) = 10,500 USDG
        // D * (1 + b) == V exactly.
        (uint256 repaid, uint256 out, bool full) =
            market.trimAmounts(coll, 10_000 * USDG, 10_500 * USDG, s, 0.05e18, type(uint256).max);
        assertEq(repaid, 10_000 * USDG);
        assertEq(out, coll, "the boundary takes all collateral, dust included");
        assertFalse(full);
    }

    /// INV-MKT-17 (mutant: seized collateral rounded up)
    function test_trimMath_seizedCollateralRoundsDown() public view {
        SessionRiskPolicy.Snapshot memory s;
        s.targetWad = 0.65e18;
        s.priceWad = 333e18;
        (uint256 repaid, uint256 out,) =
            market.trimAmounts(31 * TOKEN, 7_200 * USDG, 10_000 * USDG, s, 0.02e18, 500 * USDG);
        assertEq(repaid, 500 * USDG);
        uint256 num = uint256(500 * USDG) * 1.02e18 * 1e30;
        uint256 den = uint256(333e18) * 1e18;
        assertTrue(num % den != 0, "inexact");
        assertEq(out, num / den, "floor");
    }

    /// INV-MKT-17 (mutant: LTV for the bonus tier rounded down). Visible only for very large positions, where
    /// one wei of LTV is less than one base unit of debt.
    function test_trim_bonusTierUsesTheLtvRoundedUp() public {
        _openFriday();
        usdg.mint(lender, 1e18);
        _lend(1e18);
        _fundCollateral(bob, 3e9 * TOKEN);
        _borrow(bob, 8e17);
        SessionRiskPolicy.Snapshot memory s;
        uint256 d;
        uint256 v;
        for (uint256 i; i < 8; ++i) {
            d = market.debtOf(bob);
            v = (5 * d - 1) / 4; // 1.25 * v just below d: LTV a hair above 80%
            if (5 * d - 4 * v <= 3) break;
            vm.warp(block.timestamp + 1);
        }
        s = policy.snapshot();
        s.state = SessionRiskPolicy.State.PRE_CLOSE;
        s.canTrim = true;
        s.canBuffer = false;
        s.ltWad = 0.7e18;
        s.targetWad = 0.65e18;
        s.priceWad = Math.mulDiv(v, 1e30, 3e9 * TOKEN, Math.Rounding.Ceil);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, s, type(uint256).max);
        assertEq(q.value, v, "crafted value");
        assertGt(q.debt * 1e18, 0.8e18 * q.value, "strictly above LT_OPEN");
        assertLt(q.debt * 1e18, 0.8e18 * q.value + q.value, "by less than one wei of LTV");
        assertEq(q.bonusWad, 0.05e18, "distress bonus above LT_OPEN");
    }

    /// INV-MKT-19 (mutant: the full-fill TargetMissed post-check removed). A borrow of exactly `debtIndex()` base
    /// units mints exactly 1e36 debt shares, so the debt is a whole number at every later index. A full fill burns
    /// floor(repaid * 1e36 / index) shares, which leaves the debt one unit above debt - repaid, and the remaining
    /// value rounds down: together they leave the fill more than one unit above the target, so the post-check
    /// rejects it and nothing moves. A fill one unit short of the need claims no target and executes.
    function test_trim_fullFillMoreThanOneUnitAboveTheTargetRevertsTargetMissed() public {
        uint256 raw = 3.4e9 * TOKEN; // 1.36e18 base units of value at 400
        _openFriday();
        usdg.mint(lender, 2e18);
        _lend(2e18);
        usdg.mint(liquidator, 1e18);
        _fundCollateral(carol, raw);
        _borrow(carol, market.debtIndex());
        (, uint256 shares,) = market.accountOf(carol);
        assertEq(shares, 1e36, "exactly one share unit");

        _setPrice(360e8); // LTV about 81.7%: eligible and solvent in OPEN
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_OPEN + 1 hours + 1);
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.OPEN));
        uint256 idx = market.debtIndex();
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        assertEq(q.debt, idx, "the debt is exactly the index, with no rounding");
        assertTrue(q.eligible && q.fullFill && !q.bufferPending);
        assertLt(q.repaid, q.debt, "the need is below the debt");
        uint256 debtAfter = Math.mulDiv(shares - Math.mulDiv(q.repaid, 1e36, idx), idx, 1e36, Math.Rounding.Ceil);
        uint256 valueAfter = gate.valueOf(raw - q.collateralOut, s.priceWad);
        assertEq(debtAfter, q.debt - q.repaid + 1, "the floor share burn leaves one unit more debt");
        assertGt(debtAfter * 1e18, s.targetWad * valueAfter + 1e18, "more than one unit above the target");

        uint256 liqUsdg = usdg.balanceOf(liquidator);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(StockReefMarket.TargetMissed.selector, debtAfter, valueAfter, s.targetWad)
        );
        market.trim(carol, type(uint256).max, 0, block.timestamp);
        assertEq(market.debtOf(carol), q.debt, "nothing moved");
        assertEq(market.collateralOf(carol), raw);
        assertEq(usdg.balanceOf(liquidator), liqUsdg);
        assertEq(tsla.balanceOf(liquidator), 0);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, q.repaid - 1, 0, block.timestamp);
        assertEq(repaid, q.repaid - 1, "a partial fill one unit short executes");
        assertEq(out, Math.mulDiv((q.repaid - 1) * 1.05e18, market.VALUE_SCALE(), s.priceWad * 1e18));
        uint256 debtLeft = market.debtOf(carol);
        uint256 valueLeft = gate.valueOf(market.collateralOf(carol), s.priceWad);
        assertGt(debtLeft * 1e18, s.targetWad * valueLeft, "and stops short of the target");
        assertLt(debtLeft * q.value, q.debt * valueLeft, "with a lower LTV");
    }

    /// @dev A second gate, policy and market around `loan`, sharing the fixture's calendar, clock, feed and stock.
    function _sideMarket(MarketLoanToken loan, uint256 minLoan_) internal returns (PriceGate g, StockReefMarket m) {
        PriceGate.Config memory c = _config();
        c.loanToken = address(loan);
        c.loanDecimals = loan.decimals();
        g = new PriceGate(c);
        m = new StockReefMarket(loan, tsla, new SessionRiskPolicy(g), minLoan_, "side", "side");
    }

    /// @dev Admit Friday's opening price on the fixture's gate and on `g`, and move to OPEN.
    function _openFridayWith(PriceGate g) internal {
        _tick(FRI_OPEN + 5 minutes);
        g.refresh();
        _tick(FRI_OPEN + 15 minutes);
        g.refresh();
    }

    function _fund(MarketLoanToken loan, StockReefMarket m, address who, uint256 amount) internal {
        loan.mint(who, amount);
        vm.prank(who);
        loan.approve(address(m), type(uint256).max);
    }

    function _collateralIn(StockReefMarket m, address who, uint256 raw) internal {
        tsla.mint(who, raw);
        vm.startPrank(who);
        tsla.approve(address(m), type(uint256).max);
        m.depositCollateral(raw, who);
        vm.stopPrank();
    }

    /// INV-MKT-21, INV-MKT-40 (mutant: the ZeroAmount guard without `collateralOut == 0`). With an 18-decimal loan
    /// token a few base units buy no raw collateral, so a trim could otherwise take payment and release nothing.
    function test_trim_thatWouldReleaseNoCollateralRevertsZeroAmount() public {
        MarketLoanToken wide = new MarketLoanToken(18);
        (PriceGate g, StockReefMarket m) = _sideMarket(wide, 5e18);
        _openFridayWith(g);
        _fund(wide, m, lender, 100_000e18);
        vm.prank(lender);
        m.deposit(100_000e18, lender);
        _collateralIn(m, bob, 25 * TOKEN);
        vm.prank(bob);
        m.borrow(7_200e18, bob);

        _tick(FRI_CLOSE - 45 minutes);
        _fund(wide, m, liquidator, 10_000e18);
        uint256 debt = m.debtOf(bob);
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.ZeroAmount.selector);
        m.trim(bob, 1, 0, block.timestamp);
        assertEq(m.debtOf(bob), debt);
        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = m.trim(bob, 1_000, 0, block.timestamp);
        assertEq(repaid, 1_000);
        assertEq(out, 2, "floor(1,000 * 1.02 / 400)");
    }

    /// INV-X-09
    function test_reentrancy_tokenCallbacksCannotReenterTheMarket() public {
        MarketHookedLoanToken hooked = new MarketHookedLoanToken();
        (PriceGate g, StockReefMarket m) = _sideMarket(hooked, MIN_LOAN);
        _openFridayWith(g);
        _fund(hooked, m, lender, 1_000_000 * USDG);
        _fund(hooked, m, bob, 1_000_000 * USDG);
        _fund(hooked, m, liquidator, 1_000_000 * USDG);
        vm.prank(lender);
        m.deposit(100_000 * USDG, lender);
        _collateralIn(m, bob, 100 * TOKEN);
        _collateralIn(m, carol, 25 * TOKEN);
        vm.prank(bob);
        m.borrow(10_000 * USDG, bob);
        vm.prank(carol);
        m.borrow(7_200 * USDG, carol);
        _setPrice(340e8); // carol at 84.7%: trimmable in OPEN
        _tick(FRI_OPEN + 1 hours);

        bytes[9] memory inner = [
            abi.encodeCall(StockReefMarket.deposit, (1, address(hooked))),
            abi.encodeCall(StockReefMarket.mint, (1, address(hooked))),
            abi.encodeCall(StockReefMarket.withdraw, (1, address(hooked), address(hooked))),
            abi.encodeCall(StockReefMarket.redeem, (1, address(hooked), address(hooked))),
            abi.encodeCall(StockReefMarket.borrow, (1, address(hooked))),
            abi.encodeCall(StockReefMarket.repay, (1, bob)),
            abi.encodeCall(StockReefMarket.trim, (carol, 1, 0, type(uint256).max)),
            abi.encodeCall(StockReefMarket.depositCollateral, (1, bob)),
            abi.encodeCall(StockReefMarket.withdrawCollateral, (1, address(hooked)))
        ];
        for (uint256 outer; outer < 5; ++outer) {
            for (uint256 i; i < inner.length; ++i) {
                hooked.arm(address(m), inner[i]);
                if (outer == 0) {
                    vm.prank(lender);
                    m.deposit(10 * USDG, lender);
                } else if (outer == 1) {
                    vm.prank(bob);
                    m.borrow(1 * USDG, bob);
                } else if (outer == 2) {
                    vm.prank(bob);
                    m.repay(1 * USDG, bob);
                } else if (outer == 3) {
                    vm.prank(lender);
                    m.withdraw(1 * USDG, lender, lender);
                } else {
                    vm.prank(liquidator);
                    m.trim(carol, 10 * USDG, 0, block.timestamp);
                }
                assertFalse(hooked.armed(), "the callback ran");
                assertFalse(hooked.reentered(), "re-entry failed");
                assertEq(bytes4(hooked.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            }
        }
    }

    // ================================================================ refresh, stops and wind-down

    /// INV-X-06
    function test_refresh_aTrimAdmitsTheReopeningPriceItThenUses() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(carol);
        answer = 260e8;
        _pushAt(MON_OPEN + 5 minutes, answer); // a fresh reopening print nobody has refreshed
        assertEq(uint256(_state()), uint256(SessionRiskPolicy.State.REOPEN_WAIT), "the view sees no admission");
        assertEq(gate.admissionFor(_monIndex()), 0);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, block.timestamp);
        assertEq(gate.admissionFor(_monIndex()), block.timestamp, "the trim's own refresh admitted the price");
        assertEq(gate.lastPriceWad(), 260e18);
        assertEq(repaid, uint256(6_500 * USDG) * 100 / 105, "valued at the admitted price");
        assertEq(out, 25 * TOKEN);
    }

    /// INV-MKT-09 (mutant: the book at the latest feed answer while indicative)
    function test_valuation_lockedBookUsesTheLastAcceptedPrice() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        vm.prank(guardian);
        gate.stop();
        _setPrice(260e8);
        _tick(FRI_OPEN + 2 hours);
        assertEq(gate.quote().priceWad, 260e18, "the feed moved");
        StockReefMarket.Book memory b = market.bookValuation();
        assertTrue(b.indicative);
        assertEq(b.priceWad, 400e18, "the last accepted price");
        assertEq(b.recoverable, market.debtOf(bob));
    }

    /// INV-MKT-57
    function test_views_surviveAFailingFeedButNotUndecodableData() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        stockFeed.bumpPhase(); // latestRoundData now reverts
        assertTrue(gate.quote().reasons & Reasons.STOCK_FEED_UNAVAILABLE != 0);
        StockReefMarket.Book memory b = market.bookValuation();
        assertTrue(b.indicative);
        assertEq(b.priceWad, 400e18);
        assertEq(market.totalAssets(), market.cash() + market.debtOf(bob));
        assertEq(market.maxDeposit(lender), 0);
        assertEq(market.maxMint(lender), 0);
        assertEq(market.maxWithdraw(lender), 0);
        assertEq(market.maxRedeem(lender), 0);
        assertGt(market.previewRedeem(1e12), 0);
        assertFalse(market.quoteTrim(bob, policy.snapshot(), type(uint256).max).eligible);

        vm.mockCall(address(stockFeed), abi.encodeWithSelector(stockFeed.latestRoundData.selector), hex"01");
        vm.expectRevert();
        market.totalAssets();
    }

    /// @dev Every price-dependent market path reverts with NotAllowedNow in the current state.
    function _expectPricePathsClosed() internal {
        vm.prank(alice);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.borrow(100 * USDG, alice);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.trim(carol, type(uint256).max, 0, block.timestamp);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdrawCollateral(1, bob);
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(1 * USDG, lender);
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.mint(1e12, lender);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(bob);
    }

    /// @dev Bob owes the worked example and has a funded plan; carol owes it too; alice only has collateral.
    function _stopScenario() internal {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _workedExample(carol);
        _fundCollateral(alice, 25 * TOKEN);
        usdg.mint(bob, 1_000 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(escrow), type(uint256).max);
        usdg.approve(address(market), type(uint256).max);
        escrow.deposit(500 * USDG, bob);
        escrow.authorize(0.65e18, 500 * USDG, uint64(cal.lastOpen() + 365 days));
        vm.stopPrank();
    }

    /// INV-X-10, INV-MKT-36, INV-MKT-37, INV-MKT-39, INV-MKT-38
    function test_guarded_aStopBlocksPricesNotExits() public {
        _stopScenario();
        _tick(FRI_OPEN + 1 hours);
        vm.prank(guardian);
        gate.stop();
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertTrue(s.reasons & Reasons.STOPPED != 0);
        _expectPricePathsClosed();
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdraw(1 * USDG, lender, lender);

        // Exits that need no price.
        uint256 debt = market.debtOf(bob);
        vm.prank(bob);
        market.repay(100 * USDG, bob);
        vm.prank(bob);
        escrow.ownerRepay(100 * USDG);
        vm.prank(bob);
        escrow.deposit(10 * USDG, bob);
        assertEq(market.debtOf(bob), debt - 200 * USDG);
        tsla.mint(liquidator, TOKEN);
        vm.startPrank(liquidator);
        tsla.approve(address(market), TOKEN);
        market.depositCollateral(TOKEN, carol);
        vm.stopPrank();
        vm.prank(alice);
        market.withdrawCollateral(25 * TOKEN, alice);
        assertEq(tsla.balanceOf(alice), 25 * TOKEN);
    }

    /// INV-X-11, INV-X-10, INV-X-13
    function test_guarded_aPersistentStopLeavesOnlyRepaymentsAndWindDownExits() public {
        _stopScenario();
        vm.prank(guardian);
        gate.stop();
        uint256[6] memory times = [
            uint256(FRI_CLOSE - 90 minutes),
            FRI_CLOSE - 10 minutes,
            FRI_CLOSE + 1 hours,
            MON_OPEN + 10 minutes,
            MON_OPEN + 3 hours,
            TUE_OPEN + 1 hours
        ];
        for (uint256 i; i < times.length; ++i) {
            _tick(times[i]); // fresh prices keep arriving
            SessionRiskPolicy.Snapshot memory s = policy.snapshot();
            assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
            _expectPricePathsClosed();
            assertTrue(escrow.committed(bob), "escrow stays committed");
            vm.prank(bob);
            market.repay(1 * USDG, bob);
        }

        // Wind-down: exits against cash at the last accepted price, repayments, and released plans.
        _tick(cal.lastOpen() + 1 hours);
        SessionRiskPolicy.Snapshot memory w = policy.snapshot();
        assertTrue(w.windDown);
        assertFalse(escrow.committed(bob), "plans are released");
        vm.prank(bob);
        escrow.withdraw(100 * USDG, bob);
        _expectPricePathsClosed();
        uint256 m = market.maxRedeem(lender);
        assertGt(m, 0);
        vm.prank(lender);
        market.redeem(m, lender, lender);
        vm.prank(bob);
        market.repay(1 * USDG, bob);
    }

    /// INV-X-13, INV-MKT-36, INV-MKT-37, INV-MKT-43
    function test_windDown_isAbsorbingWhileExitsRepaymentsAndFreeWithdrawalsContinue() public {
        _stopScenario();
        uint256[3] memory later = [uint256(cal.lastOpen()), cal.lastOpen() + 1 days, cal.lastClose() + 30 days];
        for (uint256 i; i < later.length; ++i) {
            _tick(later[i]); // a usable live price does not reopen anything
            SessionRiskPolicy.Snapshot memory s = policy.snapshot();
            assertTrue(s.windDown);
            assertFalse(s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen);
            _expectPricePathsClosed();
            assertEq(market.maxDeposit(lender), 0);
            assertFalse(escrow.committed(bob));

            uint256 cash = market.cash();
            vm.prank(bob);
            market.repay(10 * USDG, bob);
            assertEq(market.cash(), cash + 10 * USDG, "repayments reach lender cash");
            uint256 m = market.maxWithdraw(lender);
            assertEq(m, Math.min(market.convertToAssets(market.balanceOf(lender)), market.cash()));
            vm.prank(lender);
            market.withdraw(m / 2, lender, lender);
            vm.prank(alice);
            market.withdrawCollateral(1 * TOKEN, alice);
        }
        assertEq(tsla.balanceOf(alice), 3 * TOKEN);
    }

    /// INV-MKT-54
    function test_windDown_exitsUseTheLiveQuoteOrElseTheLastAcceptedPrice() public {
        _openFriday();
        _lend(20_000 * USDG);
        _workedExample(bob);
        _setPrice(300e8);
        _tick(cal.lastOpen() + 1 hours);
        StockReefMarket.Book memory b = market.bookValuation();
        assertFalse(b.indicative, "a usable live quote");
        assertEq(b.priceWad, 300e18);
        uint256 shares = market.balanceOf(lender) / 8;
        uint256 expected = market.previewRedeem(shares);
        vm.prank(lender);
        assertEq(market.redeem(shares, lender, lender), expected);

        // A later answer that arrives stale is not used: the book stays at the last accepted price.
        vm.warp(block.timestamp + 1 days);
        stockFeed.pushAt(200e8, uint64(block.timestamp - 1 hours));
        b = market.bookValuation();
        assertTrue(b.indicative);
        assertEq(b.priceWad, 300e18);
        expected = market.previewRedeem(shares);
        vm.prank(lender);
        assertEq(market.redeem(shares, lender, lender), expected);
        assertEq(gate.lastPriceWad(), 300e18);
    }
}
