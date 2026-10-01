// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

contract RepaymentEscrowTest is MarketFixture {
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _setUpMarket();
        _openFriday();
        _lend(100_000 * USDG);
    }

    /// @dev Alice: the worked example plus a funded, authorized buffer.
    function _aliceWithBuffer(uint256 funded, uint256 cap) internal {
        _workedExample(alice);
        usdg.mint(alice, funded);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(funded, alice);
        escrow.authorize(0.65e18, cap, uint64(MON_CLOSE));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ authorization

    function test_authorize_rejectsTargetsAboveTheDeepestPlan() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.TargetTooHigh.selector, 0.65e18 + 1, 0.65e18));
        escrow.authorize(0.65e18 + 1, 1_000 * USDG, uint64(MON_CLOSE));
    }

    function test_authorize_rejectsExpiredOrEmptyPlans() public {
        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0.65e18, 1_000 * USDG, uint64(block.timestamp));
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0.65e18, 0, uint64(MON_CLOSE));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ execution

    function test_execute_repaysExactlyToTheTargetWithoutAReward() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        uint256 keeperBefore = usdg.balanceOf(keeper);

        vm.prank(keeper);
        uint256 repaid = escrow.executeBuffer(alice);

        // Worked example: 700 USDG to reach 65%, plus the interest accrued since borrowing.
        assertApproxEqAbs(repaid, _golden(".worked_example.cash_required_usdg"), 1 * USDG);
        assertEq(repaid, debt - 6_500 * USDG);
        assertApproxEqAbs(market.debtOf(alice), 6_500 * USDG, 1, "65% within share rounding");
        assertEq(market.collateralOf(alice), 25 * TOKEN, "collateral untouched");
        assertEq(usdg.balanceOf(keeper), keeperBefore, "no reward");
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG - repaid);
    }

    function test_execute_onlyDuringPreparationWithAValidPrice() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice); // OPEN

        _tick(FRI_CLOSE - 60 minutes);
        vm.warp(block.timestamp + MOCK_MAX_AGE + 1); // stale
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);

        _tick(FRI_CLOSE);
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice); // CLOSED
    }

    function test_execute_isCappedByBalanceAndSessionAllowance() public {
        _aliceWithBuffer(300 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 300 * USDG, "balance cap");
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(alice);
    }

    function test_execute_sessionCapResetsNextSession() public {
        _aliceWithBuffer(1_000 * USDG, 200 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(alice);

        // Monday: a new session and a new allowance (Monday's close is OVERNIGHT, still above 65%).
        _tick(MON_OPEN + 5 minutes);
        _tick(MON_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);
    }

    function test_execute_requiresAnActiveAuthorization() public {
        _workedExample(alice);
        usdg.mint(alice, 1_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        vm.stopPrank();
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NotAuthorized.selector);
        escrow.executeBuffer(alice);
    }

    function test_execute_frozenTransferRevertsAndPreservesBalances() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        usdg.setFrozen(address(escrow), true);
        vm.prank(keeper);
        vm.expectPartialRevert(MockUSDG.AccountFrozen.selector);
        escrow.executeBuffer(alice);
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG);
        assertEq(market.debtOf(alice), debt);
    }

    // ------------------------------------------------------------ ordering with liquidation

    function test_ordering_trimWaitsForAnExecutableBuffer() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 45 minutes);
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.BufferPending.selector);
        market.trim(alice, type(uint256).max, 0, block.timestamp);

        vm.prank(keeper);
        escrow.executeBuffer(alice);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotEligible.selector);
        market.trim(alice, type(uint256).max, 0, block.timestamp);
        assertApproxEqAbs(market.debtOf(alice), 6_500 * USDG, 1, "the buffer repayment stands on its own");
    }

    function test_ordering_partialBufferThenTrimForTheRest() public {
        _aliceWithBuffer(100 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 30 minutes); // final window: LT 70%, the buffer only reaches 71%
        vm.prank(keeper);
        escrow.executeBuffer(alice);
        assertFalse(escrow.executable(alice, policy.snapshot(), market.debtOf(alice), 9_999 * USDG));

        vm.prank(liquidator);
        market.trim(alice, type(uint256).max, 0, block.timestamp);
        uint256 value = gate.valueOf(market.collateralOf(alice), 400e18);
        assertLe(market.debtOf(alice) * 1e18, 0.65e18 * value + 1e18);
    }

    // ------------------------------------------------------------ commitment

    function test_commitment_locksFromAUntilAFullReopening() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        assertFalse(escrow.committed(alice), "OPEN before A");

        _tick(FRI_CLOSE - 120 minutes);
        assertTrue(escrow.committed(alice));
        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.withdraw(1, alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.cancel();
        vm.stopPrank();

        _tick(FRI_CLOSE + 1 days);
        assertTrue(escrow.committed(alice), "closed");
        _tick(MON_OPEN + 5 minutes);
        assertTrue(escrow.committed(alice), "recovery");
        _tick(MON_OPEN + 15 minutes);
        assertFalse(escrow.committed(alice), "valid full reopening");
        vm.prank(alice);
        escrow.withdraw(1, alice);
    }

    function test_commitment_endsWithFullRepaymentOrExpiry() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _tick(FRI_CLOSE + 1 hours);
        assertTrue(escrow.committed(alice));

        uint256 debt = market.debtOf(alice);
        usdg.mint(alice, debt);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        market.repay(debt, alice);
        assertFalse(escrow.committed(alice), "no debt, nothing to protect");
        escrow.withdraw(1_000 * USDG, alice);
        vm.stopPrank();
    }

    function test_commitment_expiredAuthorizationReleasesFunds() public {
        _workedExample(alice);
        usdg.mint(alice, 1_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        escrow.authorize(0.65e18, 100 * USDG, uint64(FRI_CLOSE + 1 hours));
        vm.stopPrank();

        _tick(FRI_CLOSE + 2 hours);
        assertFalse(escrow.committed(alice));
        vm.prank(alice);
        escrow.withdraw(1_000 * USDG, alice);
    }

    function test_ownerRepay_worksWhileClosedOrGuarded() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.warp(FRI_CLOSE + 1 days);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);

        vm.prank(guardian);
        gate.stop();
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);
        assertEq(escrow.planOf(alice).balance, 800 * USDG);
    }

    function test_deposit_allowedEvenWhileCommitted() public {
        _aliceWithBuffer(100 * USDG, 100 * USDG);
        _tick(FRI_CLOSE + 1 hours);
        usdg.mint(alice, 50 * USDG);
        vm.prank(alice);
        escrow.deposit(50 * USDG, alice);
        assertEq(escrow.planOf(alice).balance, 150 * USDG);
    }

    // ------------------------------------------------------------ separation from lender funds

    function test_escrowIsNeverLenderCash() public {
        uint256 assetsBefore = market.totalAssets();
        uint256 cashBefore = market.cash();
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        assertEq(market.cash(), cashBefore - 7_200 * USDG);
        assertEq(usdg.balanceOf(address(escrow)), 1_000 * USDG);
        assertApproxEqAbs(market.totalAssets(), assetsBefore, 1, "escrow adds nothing to the book");
    }
}
