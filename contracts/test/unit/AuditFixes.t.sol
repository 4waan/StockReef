// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";

/// @notice Regression tests for the audit fixes recorded as appendix R19 to R22, around the Friday 2026-09-11
/// session and its weekend close.
contract AuditFixesTest is MarketFixture {
    StockReefLens internal lens;

    function setUp() public {
        _setUpMarket();
        lens = new StockReefLens(market);
        _openFriday();
        _lend(100_000 * USDG);
    }

    function _fundEscrow(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(amount, who);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- R20: buffers in reopening recovery

    /// A funded buffer that was not executed before the close runs in REOPEN_RECOVERY and keeps priority over a
    /// recovery trim; the recovery bonus stays 5%.
    function test_recovery_bufferRunsBeforeRecoveryTrims() public {
        _workedExample(alice);
        _workedExample(bob);
        _fundEscrow(alice, 2_000 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, 2_000 * USDG, uint64(MON_CLOSE));

        // Nobody executes the buffer before Friday's close; Monday reopens 6% lower.
        _setPrice(376e8);
        SessionRiskPolicy.Snapshot memory s = _tick(MON_OPEN + 5 minutes);
        s = _tick(MON_OPEN + 6 minutes);
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        assertTrue(s.canBuffer, "buffers run in reopening recovery");
        assertTrue(s.canTrim);

        StockReefMarket.TrimQuote memory q = market.quoteTrim(alice, s, type(uint256).max);
        assertTrue(q.eligible && q.bufferPending, "the buffer goes first");
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.BufferPending.selector);
        market.trim(alice, type(uint256).max, 0, type(uint256).max);

        uint256 repaid = escrow.executeBuffer(alice);
        assertGt(repaid, 0);
        s = policy.snapshot();
        assertFalse(market.quoteTrim(alice, s, type(uint256).max).eligible, "the buffer reached the target");

        // Bob has no buffer: the recovery trim pays the 5% bonus of docs/SPEC.md §3 and §6.
        q = market.quoteTrim(bob, s, type(uint256).max);
        assertTrue(q.eligible && !q.bufferPending);
        assertEq(q.bonusWad, 0.05e18);
    }

    // ---------------------------------------------------------------- C1: ownerRepay as a cap

    function test_ownerRepay_maxRepaysTheWholeDebt() public {
        _workedExample(alice);
        _fundEscrow(alice, 8_000 * USDG);
        vm.warp(block.timestamp + 1 hours);
        uint256 debt = market.debtOf(alice);
        vm.prank(alice);
        uint256 repaid = escrow.ownerRepay(type(uint256).max);
        assertEq(repaid, debt);
        assertEq(market.debtOf(alice), 0);
        assertEq(escrow.planOf(alice).balance, 8_000 * USDG - debt);
    }

    function test_ownerRepay_capThatWouldLeaveDustStopsAtTheMinimumLoan() public {
        _workedExample(alice);
        _fundEscrow(alice, 8_000 * USDG);
        uint256 debt = market.debtOf(alice);
        vm.prank(alice);
        uint256 repaid = escrow.ownerRepay(debt - 1 * USDG);
        assertEq(repaid, debt - MIN_LOAN);
        assertGe(market.debtOf(alice), MIN_LOAN);
        assertLe(market.debtOf(alice), MIN_LOAN + 1);
    }

    function test_ownerRepay_balanceJustShortOfTheDebtStopsAtTheMinimumLoan() public {
        _workedExample(alice);
        uint256 debt = market.debtOf(alice);
        _fundEscrow(alice, debt - 1 * USDG);
        vm.prank(alice);
        uint256 repaid = escrow.ownerRepay(type(uint256).max);
        assertEq(repaid, debt - MIN_LOAN);
        assertEq(escrow.planOf(alice).balance, MIN_LOAN - 1 * USDG);
    }

    function test_ownerRepay_withoutBalanceRepaysNothing() public {
        _workedExample(alice);
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.ownerRepay(type(uint256).max);
    }

    // ---------------------------------------------------------------- C1: worthless-dust sweep (docs/SPEC.md §5)

    /// The audit's honest dust case: a solvent full fill near D*(1+b) = V leaves about one unit of debt against
    /// about one unit of value. A second trim now sweeps the dust for a one-unit repayment.
    function test_trim_sweepsWorthlessDust() public {
        _workedExample(carol);
        _fundCollateral(bob, 100 * TOKEN);
        (uint256 t,, uint256 v) = _findBoundarySecond(block.timestamp + 1 minutes, 40);
        answer = int256(4 * v);
        SessionRiskPolicy.Snapshot memory s = _tick(t);
        vm.prank(liquidator);
        market.trim(carol, type(uint256).max, 0, type(uint256).max);
        assertTrue(market.bookValuation().impaired, "dust is left");

        uint256 dust = market.debtOf(carol);
        uint256 dustCollateral = market.collateralOf(carol);
        assertGt(dust, 0);
        assertGt(dustCollateral, 0);
        s = policy.snapshot();
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        assertEq(q.repaid, 1, "one unit");
        assertEq(q.collateralOut, dustCollateral, "all the dust");
        assertFalse(q.fullFill, "a sweep is never a full fill");
        StockReefMarket.TrimQuote memory none = market.quoteTrim(carol, s, 0);
        assertEq(none.repaid, 0, "no repay cap, no sweep");
        assertEq(none.collateralOut, 0);
        assertFalse(none.fullFill);

        uint256 badDebtBefore = market.totalBadDebt();
        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, type(uint256).max);
        assertEq(repaid, 1);
        assertEq(out, dustCollateral);
        assertEq(market.debtOf(carol), 0);
        assertEq(market.collateralOf(carol), 0);
        assertEq(market.totalBadDebt() - badDebtBefore, dust - 1, "the rest is written off");
        assertFalse(market.bookValuation().impaired, "the book recovers");
        _borrow(bob, 1_000 * USDG);
    }

    /// Value above the dust threshold still takes the ordinary insolvent branch.
    function test_trim_noSweepWhenCollateralIsWorthSomething() public {
        _workedExample(carol);
        _setPrice(280e8); // 7,000 USDG of value, insolvent at 5%
        SessionRiskPolicy.Snapshot memory s = _tick(block.timestamp + 1 minutes);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        assertEq(q.repaid, Math.mulDiv(q.value, 1e18, 1.05e18));
    }

    function _findBoundarySecond(uint256 t0, uint256 deltaCents) internal returns (uint256 t, uint256 d, uint256 v) {
        for (t = t0; t < t0 + 600; ++t) {
            vm.warp(t);
            d = market.debtOf(carol);
            if ((105 * d) % 100 == 100 - deltaCents) {
                v = Math.ceilDiv(105 * d, 100);
                return (t, d, v);
            }
        }
        revert("no boundary second found");
    }

    // ---------------------------------------------------------------- C1: zero addresses

    function test_zeroAddressesRejected() public {
        _fundCollateral(alice, 25 * TOKEN);
        tsla.mint(address(this), 1);
        tsla.approve(address(market), 1);
        vm.expectRevert(StockReefMarket.ZeroAddress.selector);
        market.depositCollateral(1, address(0));

        vm.startPrank(alice);
        vm.expectRevert(StockReefMarket.ZeroAddress.selector);
        market.borrow(100 * USDG, address(0));
        vm.expectRevert(StockReefMarket.ZeroAddress.selector);
        market.withdrawCollateral(1, address(0));
        vm.stopPrank();

        usdg.mint(address(this), 1);
        usdg.approve(address(escrow), 1);
        vm.expectRevert(RepaymentEscrow.ZeroAddress.selector);
        escrow.deposit(1, address(0));
        _fundEscrow(alice, 1);
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.ZeroAddress.selector);
        escrow.withdraw(1, address(0));
    }

    // ---------------------------------------------------------------- R21: no lender entry while impaired

    function test_lenderEntryClosedWhileImpaired() public {
        _workedExample(carol);
        _setPrice(290e8); // carol at 99%: recoverable 7,250 / 1.05 < 7,200
        _tick(block.timestamp + 1 minutes);
        assertEq(uint256(_state()), uint256(SessionRiskPolicy.State.OPEN));
        assertTrue(market.bookValuation().impaired);
        assertEq(market.maxDeposit(lender), 0);
        assertEq(market.maxMint(lender), 0);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lender, 1 * USDG, 0));
        market.deposit(1 * USDG, lender);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, lender, 1e12, 0));
        market.mint(1e12, lender);

        // Exits stay open at the marked value.
        vm.prank(lender);
        market.withdraw(1_000 * USDG, lender, lender);
    }

    /// With more debt than idle cash and no impairment, entry stays unlimited: lender assets are cash plus the
    /// recoverable book, not cash alone.
    function test_lenderEntryOpenAtHighUtilization() public {
        for (uint256 i; i < 8; ++i) {
            _workedExample(address(uint160(0xA000 + i))); // 8 x 7,200 USDG of debt against 100,000 lent
        }
        assertGt(market.bookValuation().recoverable, market.cash(), "more debt than cash");
        assertFalse(market.bookValuation().impaired);
        assertEq(market.maxDeposit(lender), type(uint256).max);
        assertEq(market.maxMint(lender), type(uint256).max);
        vm.prank(lender);
        market.deposit(1_000 * USDG, lender);
    }

    // ---------------------------------------------------------------- C4: lens accuracy

    /// A position just below 70% now crosses it by F on interest alone: the F preview accrues to F.
    function test_lens_trimAtFinalAccruesDebtToF() public {
        _fundCollateral(alice, 25 * TOKEN); // 10,000 USDG
        _borrow(alice, 6_999_900_000); // 69.999%
        StockReefLens.AccountView memory v = lens.accountView(alice);
        assertLe(v.debt * 1e18, 0.7e18 * v.collateralValue, "not above 70% now");
        assertTrue(v.trimmableAtFinal, "above 70% at F");
        assertGt(v.trimAtFinalRepay, 0);
    }

    function test_lens_projectsTheReopening() public {
        _fundCollateral(alice, 25 * TOKEN);
        _borrow(alice, 6_996 * USDG);
        StockReefLens.AccountView memory v = lens.accountView(alice);
        assertEq(v.projectedDebtAtReopen, market.debtAt(alice, MON_OPEN));
        assertTrue(v.trimmableAtReopen, "weekend interest crosses 70%");
        assertFalse(v.trimmableAtFinal);
    }

    /// Closure interest alone is not a missed execution: the flag uses the debt at the close.
    function test_lens_missedExecutionUsesTheDebtAtTheClose() public {
        _fundCollateral(alice, 25 * TOKEN);
        _borrow(alice, 6_999 * USDG); // 69.99% at F and at C
        _workedExample(carol); // 72%: a real miss
        _tick(FRI_CLOSE + 1 days + 12 hours); // Sunday
        StockReefLens.AccountView memory a = lens.accountView(alice);
        assertGt(a.debt * 1e18, 0.7e18 * a.collateralValue, "above 70% on Sunday");
        assertFalse(a.missedExecution, "but not at the close");
        assertEq(a.exposure, 0);
        StockReefLens.AccountView memory c = lens.accountView(carol);
        assertTrue(c.missedExecution);
        assertEq(c.exposure, c.repayToTarget);
    }

    /// Coverage is sized for the next execution window: a plan that expires before A covers nothing.
    function test_lens_bufferCoverageNeedsThePlanAtTheNextWindow() public {
        _workedExample(alice);
        _workedExample(bob);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        _fundEscrow(alice, 2_000 * USDG);
        _fundEscrow(bob, 2_000 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, 2_000 * USDG, s.prepAt - 1);
        vm.prank(bob);
        escrow.authorize(0.65e18, 2_000 * USDG, s.prepAt + 1 hours);
        assertEq(lens.accountView(alice).bufferCoverage, 0, "expires before A");
        StockReefLens.AccountView memory b = lens.accountView(bob);
        uint256 debtAtA = market.debtAt(bob, s.prepAt);
        assertEq(b.bufferCoverage, Math.ceilDiv(debtAtA * 1e18 - 0.65e18 * b.collateralValue, 1e18));
    }

    function test_lens_borrowCapacityZeroBelowTheMinimumLoan() public {
        _fundCollateral(alice, 0.01e18); // 4 USDG of collateral: at most 3 USDG of debt
        assertEq(lens.accountView(alice).borrowCapacity, 0);
        _fundCollateral(bob, 1 * TOKEN); // 400 USDG: 300 of capacity
        assertGt(lens.accountView(bob).borrowCapacity, MIN_LOAN);
    }
}

/// @notice The last covered session and wind-down (appendix R17, R19), on the final sessions of the calendar.
contract TerminalCloseTest is MarketFixture {
    StockReefLens internal lens;
    uint256 internal n;
    uint64 internal o3;
    uint64 internal o2;
    uint64 internal c2;
    uint64 internal lo;
    address internal lender2 = makeAddr("lender2");

    function setUp() public {
        SessionCalendar tmp = _deployCalendar();
        n = tmp.sessionCount();
        (o3,) = tmp.sessionAt(n - 3);
        (o2, c2) = tmp.sessionAt(n - 2);
        (lo,) = tmp.sessionAt(n - 1);

        vm.warp(o3 - 1 hours);
        _setUpGate();
        policy = new SessionRiskPolicy(gate);
        market = new MarketHarness(usdg, tsla, policy, MIN_LOAN);
        escrow = market.escrow();
        lens = new StockReefLens(market);
        usdg.mint(lender, 1_000_000 * USDG);
        usdg.mint(lender2, 1_000_000 * USDG);
        usdg.mint(liquidator, 1_000_000 * USDG);
        vm.prank(lender);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(lender2);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);

        _tick(o3 + 5 minutes);
        _tick(o3 + 15 minutes);
        _lend(10_000 * USDG);
        vm.prank(lender2);
        market.deposit(10_000 * USDG, lender2);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 7_400 * USDG); // 74%, allowed before the last covered session
    }

    function _reopenTerminal() internal returns (SessionRiskPolicy.Snapshot memory s) {
        _tick(o2 + 5 minutes);
        s = _tick(o2 + 15 minutes);
    }

    function test_terminalSession_usesTheExtendedClassAndNoNewCredit() public {
        SessionRiskPolicy.Snapshot memory s = _reopenTerminal();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.OPEN));
        assertEq(s.session + 2, n, "last covered session");
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));
        assertFalse(s.canBorrow);
        assertEq(s.borrowLimitWad, 0);
        assertTrue(s.lenderOpen, "lenders can still exit");

        _fundCollateral(alice, 25 * TOKEN);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StockReefMarket.NotAllowedNow.selector, SessionRiskPolicy.State.OPEN, uint32(0))
        );
        market.borrow(100 * USDG, alice);

        s = _tick(c2 - 75 minutes);
        assertEq(s.ltWad, 0.75e18, "the EXTENDED ramp, halfway");
        s = _tick(c2 - 30 minutes);
        assertEq(s.ltWad, 0.7e18);
        assertEq(s.targetWad, 0.65e18);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, s, type(uint256).max);
        assertTrue(q.eligible, "74% is trimmed before the terminal close");
        vm.prank(liquidator);
        market.trim(bob, type(uint256).max, 0, type(uint256).max);
    }

    function test_lens_noLenderWindowAfterTheLastCoveredSession() public {
        _reopenTerminal();
        _tick(c2 - 60 minutes);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(m.lenderWindowOpensAt, 0);
        assertEq(m.lenderWindowClosesAt, 0);
    }

    function test_windDown_cashOnlyExitsWithoutTrims() public {
        _reopenTerminal();
        _setPrice(240e8); // bob under water in wind-down
        SessionRiskPolicy.Snapshot memory s = _tick(lo + 1 hours);
        assertTrue(s.windDown);
        assertFalse(s.canTrim);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(StockReefMarket.NotAllowedNow.selector, SessionRiskPolicy.State.GUARDED, uint32(0))
        );
        market.trim(bob, type(uint256).max, 0, type(uint256).max);

        uint256 cash = market.cash();
        assertEq(market.totalAssets(), cash, "wind-down values lenders at idle cash only");

        // Equal lenders: the first exit takes half the cash, not cash valued with bob's collateral.
        uint256 half = market.maxWithdraw(lender);
        assertApproxEqAbs(half, cash / 2, 1);
        vm.prank(lender);
        market.withdraw(half, lender, lender);

        // A guardian stop does not move the exit value; a later repayment raises it.
        uint256 before = market.convertToAssets(market.balanceOf(lender2));
        vm.prank(guardian);
        gate.stop();
        assertEq(market.convertToAssets(market.balanceOf(lender2)), before);
        usdg.mint(bob, 1_000 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        market.repay(1_000 * USDG, bob);
        vm.stopPrank();
        assertApproxEqAbs(market.convertToAssets(market.balanceOf(lender2)), before + 1_000 * USDG, 1);
    }

    function test_lens_windDownFlagsMissedExecutionAndNoCoverage() public {
        _reopenTerminal();
        usdg.mint(bob, 2_000 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(2_000 * USDG, bob);
        vm.stopPrank();
        _tick(lo + 1 hours);
        vm.prank(bob);
        escrow.authorize(0.65e18, 2_000 * USDG, lo + 30 days);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertTrue(v.missedExecution, "above 70% at the terminal close");
        assertGt(v.exposure, 0);
        assertEq(v.bufferCoverage, 0, "no execution window is left");
    }
}

/// @notice PriceGate deployment bounds (appendix R22).
contract GateConfigTest is GateFixture {
    function setUp() public {
        vm.warp(MON_OPEN);
        _setUpGate();
    }

    function test_rejectsFeedDecimalsAbove18() public {
        MockAggregatorV3 f = new MockAggregatorV3(19, "x", clock, address(this));
        PriceGate.Config memory c = _config();
        c.stockFeed = PriceGate.Feed(IAggregatorV3(address(f)), 19, MOCK_MAX_AGE, ANSWER_BOUND);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
    }

    function test_loanBoundMustKeepThePriceAboveZero() public {
        MockAggregatorV3 f = new MockAggregatorV3(8, "USDG / USD", clock, address(this));
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(f)), 8, 86400, 1e18 + 1);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
        c.loanFeed.answerBound = 1e18;
        new PriceGate(c);
    }

    /// The price ceiling is checked per quote: an answer that would price the token above MAX_PRICE_WAD is a bad
    /// answer, never an overflow.
    function test_priceCeilingIsABadAnswer() public {
        PriceGate.Config memory c = _config(); // peg: price = answer * 1e10
        c.stockFeed.answerBound = type(uint256).max;
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 hours, 1e26);
        PriceGate.Quote memory q = g.quote();
        assertEq(q.priceWad, g.MAX_PRICE_WAD());
        assertEq(q.reasons & Reasons.STOCK_BAD_ANSWER, 0);
        stockFeed.push(1e26 + 1);
        q = g.quote();
        assertEq(q.priceWad, 0);
        assertEq(q.reasons & Reasons.STOCK_BAD_ANSWER, Reasons.STOCK_BAD_ANSWER);
        stockFeed.push(type(int256).max);
        assertEq(g.refresh().reasons & Reasons.STOCK_BAD_ANSWER, Reasons.STOCK_BAD_ANSWER, "no overflow");
    }
}

/// @notice Deploy.s.sol deploys mock tokens only on the local chain and Robinhood Chain testnet (appendix R22).
contract DeployMockGuardTest is Test {
    string internal constant PATH = "../deployments/manifest.audit-mock-guard.json";

    function test_mockTokensOnlyOnTestChains() public {
        vm.chainId(4663);
        string memory m = string.concat(
            '{"chainId":4663,"clock":"block","minLoan":"5000000",',
            '"stockFeed":{"type":"chainlink","address":"0x4A1166a659A55625345e9515b32adECea5547C38"},',
            '"loanToken":{"address":"0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168","decimals":6},',
            '"collateralToken":{"address":"mock","decimals":18,"pauseFlagRequired":true,"erc8056":true}}'
        );
        vm.writeFile(PATH, m);
        vm.setEnv("MANIFEST", PATH);
        Deploy d = new Deploy();
        vm.expectRevert("mock tokens are only deployed on test chains");
        d.run();
        vm.removeFile(PATH);
    }
}
