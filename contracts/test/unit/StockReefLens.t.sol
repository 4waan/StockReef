// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {BlockClock} from "../../src/clock/BlockClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

contract StockReefLensTest is MarketFixture {
    uint256 internal constant WAD = 1e18;

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

        // If nothing is done, a liquidator can trim it at F: the worked example's 2,077.15 at 2%, with the debt
        // accrued to F (about 0.47 USDG of interest, which the trim repays 1 / 0.337 times over).
        assertTrue(v.trimmableAtFinal);
        uint256 debtAtF = market.debtAt(bob, policy.snapshot().finalAt);
        uint256 x = Math.mulDiv(
            debtAtF * 1e18 - 0.65e18 * v.collateralValue, 1e18, 1e36 - 0.65e18 * 1.02e18, Math.Rounding.Ceil
        );
        assertEq(v.trimAtFinalRepay, x);
        assertApproxEqAbs(v.trimAtFinalRepay, _golden(".worked_example.trim_repay_usdg"), 2 * USDG);
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
        // Sized at A, the next execution window, with the debt accrued to A.
        uint256 debtAtA = market.debtAt(alice, policy.snapshot().prepAt);
        assertEq(v.bufferCoverage, Math.ceilDiv(debtAtA * 1e18 - 0.65e18 * v.collateralValue, 1e18), "covers the plan");
        assertApproxEqAbs(v.bufferCoverage, 700 * USDG, 1 * USDG);
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

    // ---------------------------------------------------------------- helpers for the tests below

    /// @dev Escrow `amount` for `who` and authorize the 65% plan with `cap` per session until `expiry`.
    function _authorize(address who, uint256 amount, uint256 cap, uint64 expiry) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(amount, who);
        escrow.authorize(0.65e18, cap, expiry);
        vm.stopPrank();
    }

    /// @dev `who` repays `amount` of its own debt with freshly minted USDG.
    function _repay(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(market), amount);
        market.repay(amount, who);
        vm.stopPrank();
    }

    /// @dev Borrowers at the address range 0xB000.. each holding 1 TSLA and the minimum loan.
    function _fillAccounts(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0xB000 + i));
            _fundCollateral(who, TOKEN);
            _borrow(who, MIN_LOAN);
        }
    }

    // ---------------------------------------------------------------- read-only and wiring

    /// INV-LENS-01: the views write no storage anywhere, read none of the Lens's own, create nothing and never
    /// call gate.refresh(), in a phase where every account-view branch runs (borrow, buffer and trim quotes).
    function test_lens_viewsWriteNothingAndNeverRefreshTheGate() public {
        _workedExample(alice);
        _authorize(alice, 1_000 * USDG, 1_000 * USDG, uint64(MON_CLOSE));
        _workedExample(bob);
        _tick(FRI_CLOSE - 100 minutes);

        vm.expectCall(address(gate), abi.encodeCall(PriceGate.refresh, ()), 0);
        vm.startStateDiffRecording();
        lens.marketView();
        lens.accountView(alice);
        lens.accountView(makeAddr("nobody"));
        lens.activeAccountViews();
        Vm.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        assertGt(diff.length, 0, "the views were recorded");
        for (uint256 i; i < diff.length; ++i) {
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.Create, "no contract created");
            assertTrue(diff[i].kind != VmSafe.AccountAccessKind.SelfDestruct, "nothing destroyed");
            assertEq(diff[i].value, 0, "no value moved");
            if (diff[i].account == address(lens)) assertEq(diff[i].storageAccesses.length, 0, "no Lens storage");
            for (uint256 j; j < diff[i].storageAccesses.length; ++j) {
                assertFalse(diff[i].storageAccesses[j].isWrite, "no storage write");
            }
        }
    }

    /// INV-X-01: the Lens, policy, market and escrow derive one gate, calendar, clock and token pair; the market
    /// copies VALUE_SCALE and owns its escrow, and refuses a token pair that differs from the gate's.
    function test_wiring_everyContractSharesOneGateCalendarClockAndTokenPair() public {
        assertEq(address(lens.market()), address(market));
        assertEq(address(lens.escrow()), address(market.escrow()));
        assertEq(address(escrow.market()), address(market));
        assertEq(address(lens.policy()), address(market.policy()));
        assertEq(address(escrow.policy()), address(policy));
        assertEq(address(lens.gate()), address(gate));
        assertEq(address(policy.gate()), address(gate));
        assertEq(address(market.gate()), address(gate));
        assertEq(address(escrow.gate()), address(gate));
        assertEq(address(lens.calendar()), address(gate.calendar()));
        assertEq(address(policy.calendar()), address(gate.calendar()));
        assertEq(address(policy.clock()), address(gate.clock()));
        assertEq(address(market.clock()), address(gate.clock()));
        assertEq(address(escrow.clock()), address(gate.clock()));
        assertEq(market.VALUE_SCALE(), gate.VALUE_SCALE());
        assertEq(address(market.collateralToken()), address(gate.token()));
        assertEq(market.asset(), gate.loanToken());
        assertEq(address(escrow.loanToken()), market.asset());

        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new MarketHarness(tsla, usdg, policy, MIN_LOAN);
        MockUSDG otherLoan = new MockUSDG();
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new MarketHarness(otherLoan, tsla, policy, MIN_LOAN);
    }

    // ---------------------------------------------------------------- market view

    /// INV-LENS-09, mutants `remove m.lastAcceptedAt` and `remove m.debtIndex`: the view mirrors the gate's last
    /// acceptance (kept while later quotes go unaccepted) and the market's debt index.
    function test_market_mirrorsTheLastAcceptanceAndTheDebtIndex() public {
        _workedExample(bob);
        _tick(FRI_OPEN + 75 minutes);
        vm.warp(FRI_OPEN + 85 minutes); // the feed goes stale; nothing new is accepted
        StockReefLens.MarketView memory m = lens.marketView();
        assertTrue(m.valuationIndicative, "precondition: stale quote");
        assertEq(m.lastAcceptedAt, FRI_OPEN + 75 minutes);
        assertEq(m.lastAcceptedAt, gate.lastAcceptedAt());
        assertLe(m.lastAcceptedAt, m.policy.time);
        assertEq(m.debtIndex, market.debtIndex());
        assertGt(m.debtIndex, WAD, "interest accrued since deployment");
    }

    /// INV-LENS-09, mutant `pending e > t -> e >= t`: a multiplier is pending only strictly before its effective
    /// time, as the gate treats effectiveAt <= now as effective.
    function test_market_multiplierIsPendingOnlyBeforeItsEffectiveTime() public {
        uint256 when = block.timestamp + 1 hours;
        tsla.scheduleMultiplier(1.01e18, when);
        _tick(when - 1);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(m.pendingMultiplier, 1.01e18);
        assertEq(m.multiplierEffectiveAt, when);

        _tick(when);
        m = lens.marketView();
        assertEq(m.pendingMultiplier, 0, "effective now");
        assertEq(m.multiplierEffectiveAt, 0, "effective now");
    }

    /// INV-LENS-09: an effective time beyond 64 bits is still pending and is reported truncated to 64 bits.
    function test_market_multiplierEffectiveTimeIsTruncatedTo64Bits() public {
        tsla.scheduleMultiplier(2e18, uint256(type(uint64).max) + 101);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(m.pendingMultiplier, 2e18);
        assertEq(m.multiplierEffectiveAt, 100);
    }

    /// INV-LENS-09, INV-DEMO-01: simulationClock repeats the clock's flag: true on the DemoClock fixture, false on
    /// a market built on BlockClock, whose snapshot time is the block time.
    function test_market_simulationClockFollowsTheClock() public {
        assertTrue(lens.marketView().simulationClock, "DemoClock");

        BlockClock real = new BlockClock();
        MockAggregatorV3 realFeed = new MockAggregatorV3(8, "TSLA/USD", real, address(this));
        PriceGate.Config memory c = _config();
        c.clock = real;
        c.stockFeed = PriceGate.Feed(IAggregatorV3(address(realFeed)), 8, MOCK_MAX_AGE, ANSWER_BOUND);
        PriceGate realGate = new PriceGate(c);
        StockReefMarket realMarket =
            new StockReefMarket(usdg, tsla, new SessionRiskPolicy(realGate), MIN_LOAN, "StockReef", "srUSDG");
        StockReefLens realLens = new StockReefLens(realMarket);
        realFeed.push(TSLA_400);

        StockReefLens.MarketView memory m = realLens.marketView();
        assertFalse(m.simulationClock, "BlockClock");
        assertEq(m.policy.time, block.timestamp);
    }

    /// INV-LENS-06, INV-LENS-08, mutant `s.time < s.prepAt -> <=`: the window is open now until one second before
    /// A; from A, and through the closure, the Lens reports the next session's (O + 15 min, C - 2 h).
    function test_market_lenderWindowFromPreparationProjectsTheNextSession() public {
        _tick(FRI_CLOSE - 120 minutes - 1);
        StockReefLens.MarketView memory m = lens.marketView();
        assertTrue(m.policy.lenderOpen);
        assertEq(m.lenderWindowOpensAt, 0);
        assertEq(m.lenderWindowClosesAt, FRI_CLOSE - 120 minutes);

        _tick(FRI_CLOSE - 120 minutes);
        m = lens.marketView();
        assertFalse(m.policy.lenderOpen);
        assertEq(m.lenderWindowOpensAt, MON_OPEN + 15 minutes, "at A");
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes, "at A");

        _tick(FRI_CLOSE + 1 hours);
        m = lens.marketView();
        assertEq(uint256(m.policy.phase), uint256(SessionRiskPolicy.State.CLOSED));
        assertEq(m.lenderWindowOpensAt, MON_OPEN + 15 minutes, "closed");
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes, "closed");
    }

    /// INV-LENS-06: during a reopening the window is this session's: O + 15 min before admission, then creditAt
    /// (here later than O + 15 min after an admission at O + 8 min); it reads open now once credit returns.
    function test_market_lenderWindowDuringTheReopening() public {
        _tick(MON_OPEN + 1 minutes);
        StockReefLens.MarketView memory m = lens.marketView();
        assertEq(uint256(m.policy.phase), uint256(SessionRiskPolicy.State.REOPEN_WAIT));
        assertEq(m.lenderWindowOpensAt, MON_OPEN + 15 minutes);
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes);

        _tick(MON_OPEN + 8 minutes);
        m = lens.marketView();
        assertEq(uint256(m.policy.phase), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        assertEq(m.policy.creditAt, MON_OPEN + 18 minutes);
        assertEq(m.lenderWindowOpensAt, MON_OPEN + 18 minutes, "creditAt");
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes);

        _tick(MON_OPEN + 18 minutes);
        m = lens.marketView();
        assertTrue(m.policy.lenderOpen);
        assertEq(m.lenderWindowOpensAt, 0);
        assertEq(m.lenderWindowClosesAt, MON_CLOSE - 120 minutes);
    }

    /// INV-LENS-06: outside calendar coverage (wind-down and after the last close) both window fields are zero
    /// and lender deposits are closed.
    function test_market_noLenderWindowOutsideCoverage() public {
        _tick(cal.lastOpen() + 1 hours);
        StockReefLens.MarketView memory m = lens.marketView();
        assertFalse(m.policy.covered);
        assertTrue(m.policy.windDown);
        assertFalse(m.policy.lenderOpen);
        assertEq(m.lenderWindowOpensAt, 0);
        assertEq(m.lenderWindowClosesAt, 0);

        _tick(cal.lastClose() + 1 days);
        m = lens.marketView();
        assertEq(m.lenderWindowOpensAt, 0);
        assertEq(m.lenderWindowClosesAt, 0);
    }

    /// INV-LENS-06, INV-LENS-08, mutant `s.session + 1 >= sessionCount -> s.session + 2 >= sessionCount`: from the
    /// second-to-last session's A and through its closure the snapshot is still covered, so the Lens projects the
    /// last loaded session's (O + 15 min, C - 2 h) although that session opens in wind-down; from its open both
    /// fields are zero.
    function test_market_noLenderWindowProjectedIntoWindDown() public {
        uint256 n = cal.sessionCount();
        (, uint64 close) = cal.sessionAt(n - 2);
        (uint64 lastOpen,) = cal.sessionAt(n - 1);
        uint64[3] memory times = [close - SessionTiming.PREP, close - 1, close + 1 hours];
        for (uint256 i; i < times.length; ++i) {
            _tick(times[i]);
            StockReefLens.MarketView memory m = lens.marketView();
            assertTrue(m.policy.covered, "covered until the last open");
            assertEq(m.policy.session, n - 2);
            assertFalse(m.policy.lenderOpen);
            assertEq(m.lenderWindowOpensAt, 0, "the last session opens in wind-down");
            assertEq(m.lenderWindowClosesAt, 0, "the last session opens in wind-down");
        }

        _tick(lastOpen);
        StockReefLens.MarketView memory w = lens.marketView();
        assertTrue(w.policy.windDown);
        assertEq(w.lenderWindowOpensAt, 0);
        assertEq(w.lenderWindowClosesAt, 0);
    }

    /// INV-LENS-03: utilization is zero for an empty book and for cash without debt, stays within [0, 1e18], and
    /// a lender exit after a borrow to the 90% cap pushes it above 90%.
    function test_market_utilizationIsZeroWhenEmptyAndCanExceedTheCap() public {
        StockReefLens emptyLens = new StockReefLens(new MarketHarness(usdg, tsla, policy, MIN_LOAN));
        assertEq(emptyLens.marketView().utilizationWad, 0, "no cash, no debt");
        assertEq(lens.marketView().utilizationWad, 0, "cash, no debt");

        _fundCollateral(alice, 300 * TOKEN); // 120,000 USDG of collateral: B * V = 90,000
        uint256 capacity = lens.accountView(alice).borrowCapacity;
        assertEq(capacity, 90_000 * USDG - 1);
        _borrow(alice, capacity);
        StockReefLens.MarketView memory m = lens.marketView();
        assertLe(m.utilizationWad, 0.9e18);

        vm.prank(lender);
        market.withdraw(5_000 * USDG, lender, lender);
        m = lens.marketView();
        assertGt(m.utilizationWad, 0.9e18, "above the borrow cap after a lender exit");
        assertLe(m.utilizationWad, WAD);
        assertEq(m.utilizationWad, Math.mulDiv(m.totalDebt, WAD, m.cash + m.totalDebt));
    }

    // ---------------------------------------------------------------- account view: position

    /// INV-LENS-10: an account the market has never seen shows zeros; collateral alone shows its value, a zero
    /// LTV and the full capacity floor(B * V) - 1.
    function test_account_emptyAccountShowsZeros() public {
        address nobody = makeAddr("nobody");
        StockReefLens.AccountView memory v = lens.accountView(nobody);
        assertEq(v.account, nobody);
        assertEq(v.collateral, 0);
        assertEq(v.collateralValue, 0);
        assertEq(v.debt, 0);
        assertEq(v.ltvWad, 0);
        assertEq(v.borrowCapacity, 0);
        assertEq(v.repayToTarget, 0);
        assertEq(v.addCollateralValueToTarget, 0);
        assertEq(v.addCollateralRawToTarget, 0);
        assertFalse(v.trimmableAtFinal);
        assertFalse(v.trimNow.eligible);
        assertFalse(v.bufferActive);
        assertEq(v.bufferCoverage, 0);
        assertEq(v.bufferExecutableNow, 0);
        assertFalse(v.missedExecution);
        assertEq(v.exposure, 0);

        _fundCollateral(nobody, 25 * TOKEN);
        v = lens.accountView(nobody);
        assertEq(v.collateralValue, 10_000 * USDG);
        assertEq(v.ltvWad, 0);
        assertEq(v.borrowCapacity, 7_500 * USDG - 1);
    }

    /// INV-LENS-10, mutant `ltvWad Ceil -> Floor`: the LTV rounds up when debt / value is inexact.
    function test_account_ltvRoundsUp() public {
        _fundCollateral(bob, 25 * TOKEN + 2_500_000_000); // 10,000.000001 USDG
        _borrow(bob, 7_200 * USDG);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertEq(v.debt, market.debtOf(bob));
        assertEq(v.collateralValue, 10_000 * USDG + 1);
        assertTrue(mulmod(v.debt, WAD, v.collateralValue) != 0, "precondition: inexact");
        assertEq(v.ltvWad, Math.mulDiv(v.debt, WAD, v.collateralValue, Math.Rounding.Ceil));
    }

    /// INV-LENS-10: debt against collateral worth zero reports the maximum LTV.
    function test_account_ltvIsMaxWhenCollateralIsWorthless() public {
        _workedExample(carol);
        answer = 1; // 1e-8 USD per token: 25 TSLA are worth less than one base unit
        _tick(FRI_OPEN + 2 hours);
        StockReefLens.AccountView memory v = lens.accountView(carol);
        assertEq(v.collateralValue, 0);
        assertEq(v.debt, market.debtOf(carol));
        assertEq(v.ltvWad, type(uint256).max);
    }

    /// INV-LENS-04, mutant `price source book -> snapshot`: with an unusable quote the account is valued at the
    /// last accepted price and flagged indicative, while trimNow values at the snapshot's quote price.
    function test_account_valuesAtTheBookPriceWhenTheQuoteIsUnusable() public {
        _workedExample(bob);
        tsla.setOraclePaused(true);
        stockFeed.push(380e8); // an issuer pause keeps it from being usable
        StockReefLens.MarketView memory m = lens.marketView();
        assertTrue(m.valuationIndicative);
        assertTrue(m.policy.reasons != 0);
        assertEq(m.valuationPriceWad, gate.lastPriceWad());
        assertEq(m.valuationPriceWad, 400e18);
        assertEq(m.policy.priceWad, 380e18, "the quote still carries the indicative price");

        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertTrue(v.valuationIndicative);
        assertEq(v.collateralValue, 10_000 * USDG, "book price");
        assertEq(v.trimNow.value, 9_500 * USDG, "snapshot price");
    }

    // ---------------------------------------------------------------- account view: closure plan

    /// INV-LENS-15: the plan target is the governing closure's target, never the 75% OPEN target: EXTENDED
    /// (65%) for Friday's close and Monday's reopening after the weekend, OVERNIGHT (72%) from Monday's credit
    /// through Tuesday's reopening, and EXTENDED outside coverage.
    function test_account_planTargetFollowsTheGoverningClose() public {
        _workedExample(bob);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertEq(policy.snapshot().targetWad, 0.75e18, "OPEN trim target");
        assertEq(v.planTargetWad, 0.65e18, "Friday OPEN: weekend close");
        _tick(FRI_CLOSE - 100 minutes);
        assertEq(lens.accountView(bob).planTargetWad, 0.65e18, "Friday PRE_CLOSE");
        _tick(FRI_CLOSE + 1 hours);
        assertEq(lens.accountView(bob).planTargetWad, 0.65e18, "weekend CLOSED");
        _tick(MON_OPEN + 1 minutes);
        assertEq(lens.accountView(bob).planTargetWad, 0.65e18, "Monday REOPEN_WAIT after the weekend");
        _tick(MON_OPEN + 5 minutes);
        assertEq(lens.accountView(bob).planTargetWad, 0.65e18, "Monday REOPEN_RECOVERY after the weekend");
        _tick(MON_OPEN + 15 minutes);
        assertEq(uint256(policy.snapshot().state), uint256(SessionRiskPolicy.State.OPEN));
        assertEq(policy.snapshot().targetWad, 0.75e18, "OPEN trim target");
        assertEq(lens.accountView(bob).planTargetWad, 0.72e18, "Monday OPEN: overnight close");
        _tick(MON_CLOSE + 1 hours);
        assertEq(lens.accountView(bob).planTargetWad, 0.72e18, "Monday night CLOSED");
        _tick(TUE_OPEN + 1 minutes);
        assertEq(lens.accountView(bob).planTargetWad, 0.72e18, "Tuesday REOPEN_WAIT after the night");
        _tick(cal.lastOpen() + 1 hours);
        assertEq(lens.accountView(bob).planTargetWad, 0.65e18, "outside coverage");
    }

    /// INV-LENS-16, mutant `repayToTarget ceilDiv -> floor`: with T * V not a whole unit the repayment rounds up;
    /// one unit less would not reach the target, and repaying it leaves the account within one unit of it.
    function test_account_repayToTargetRoundsUpAndReachesTheTarget() public {
        _fundCollateral(carol, 25 * TOKEN + 2_500_000_000); // 10,000.000001 USDG
        _borrow(carol, 7_200 * USDG);
        StockReefLens.AccountView memory v = lens.accountView(carol);
        uint256 gap = v.debt * WAD - v.planTargetWad * v.collateralValue;
        assertTrue(gap % WAD != 0, "precondition: inexact");
        assertEq(v.repayToTarget, Math.ceilDiv(gap, WAD));
        assertLt((v.repayToTarget - 1) * WAD, gap, "minimal");

        _repay(carol, v.repayToTarget);
        StockReefLens.AccountView memory a = lens.accountView(carol);
        assertLe(a.debt * WAD, a.planTargetWad * a.collateralValue + WAD, "target within one unit");
        assertLe(a.repayToTarget, 1);
    }

    /// INV-LENS-16, mutant `addCollateralValueToTarget Ceil -> Floor`: the value to add is ceil(D / T) - V, the
    /// least whole amount that reaches the target.
    function test_account_addCollateralValueRoundsUp() public {
        _workedExample(bob);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        assertTrue(mulmod(v.debt, WAD, v.planTargetWad) != 0, "precondition: inexact");
        assertEq(
            v.addCollateralValueToTarget,
            Math.mulDiv(v.debt, WAD, v.planTargetWad, Math.Rounding.Ceil) - v.collateralValue
        );
        assertLe(v.debt * WAD, v.planTargetWad * (v.collateralValue + v.addCollateralValueToTarget));
        assertGt(v.debt * WAD, v.planTargetWad * (v.collateralValue + v.addCollateralValueToTarget - 1), "minimal");
    }

    /// INV-LENS-16, mutant `addCollateralRawToTarget Ceil -> Floor`: at 399.99 USD the raw amount rounds up, and
    /// depositing exactly that amount brings the account to the target.
    function test_account_addCollateralRawRoundsUpAndReachesTheTarget() public {
        _setPrice(39_999_000_000);
        _tick(block.timestamp + 1 minutes);
        _workedExample(bob);
        StockReefLens.AccountView memory v = lens.accountView(bob);
        uint256 price = market.bookValuation().priceWad;
        uint256 ceilRaw = gate.rawForValue(v.addCollateralValueToTarget, price, Math.Rounding.Ceil);
        assertTrue(
            ceilRaw != gate.rawForValue(v.addCollateralValueToTarget, price, Math.Rounding.Floor),
            "precondition: inexact"
        );
        assertEq(v.addCollateralRawToTarget, ceilRaw);

        _fundCollateral(bob, v.addCollateralRawToTarget);
        StockReefLens.AccountView memory a = lens.accountView(bob);
        assertLe(a.debt * WAD, a.planTargetWad * a.collateralValue, "at or below the target");
        assertEq(a.repayToTarget, 0);
        assertEq(a.addCollateralValueToTarget, 0);
        assertEq(a.addCollateralRawToTarget, 0);
    }

    // ---------------------------------------------------------------- account view: borrow capacity

    /// INV-LENS-11, mutant `activeAccounts.length >= MAX_ACCOUNTS -> >`: with 32 accounts in debt a new account
    /// gets no capacity (borrow reverts AccountCapReached) while an account already in debt keeps its capacity.
    function test_account_noCapacityForANewAccountAtTheAccountCap() public {
        _fillAccounts(market.MAX_ACCOUNTS());
        assertEq(lens.marketView().activeAccounts, 32);
        address dave = makeAddr("dave");
        _fundCollateral(dave, 25 * TOKEN);
        assertEq(lens.accountView(dave).borrowCapacity, 0);
        assertGt(lens.accountView(address(0xB000)).borrowCapacity, 0, "an account in debt can borrow more");

        vm.prank(dave);
        vm.expectRevert(StockReefMarket.AccountCapReached.selector);
        market.borrow(MIN_LOAN, dave);
    }

    /// INV-LENS-11, mutant `remove if (b.impaired) return 0`: an impaired book blocks new borrowing even for a
    /// well-collateralized account.
    function test_account_noCapacityWhileTheBookIsImpaired() public {
        _workedExample(bob);
        _fundCollateral(alice, 100 * TOKEN);
        _setPrice(280e8); // bob's 25 TSLA are worth 7,000 USDG against 7,200 of debt
        _tick(block.timestamp + 1 minutes);
        assertTrue(market.bookValuation().impaired, "precondition");
        assertTrue(policy.snapshot().canBorrow, "precondition");
        assertEq(lens.accountView(alice).borrowCapacity, 0);

        vm.prank(alice);
        vm.expectRevert(StockReefMarket.MarketImpaired.selector);
        market.borrow(MIN_LOAN, alice);
    }

    /// INV-LENS-11, INV-LENS-12, mutant `UTILIZATION_CAP -> WAD`: the capacity stops exactly at the 90% cap; one
    /// unit more reverts UtilizationCapExceeded and the capacity itself is accepted.
    function test_account_capacityHonoursTheUtilizationCap() public {
        _fundCollateral(alice, 1_000 * TOKEN); // 400,000 USDG of collateral
        uint256 capacity = lens.accountView(alice).borrowCapacity;
        assertEq(capacity, 90_000 * USDG);

        vm.prank(alice);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(capacity + 1, alice);
        _borrow(alice, capacity);
        assertEq(lens.accountView(alice).borrowCapacity, 0, "cap reached");
    }

    /// INV-LENS-11: from A an active buffer authorization blocks the account's borrowing (capacity zero, borrow
    /// reverts BufferAuthorizationActive) while an account without a plan keeps its capacity.
    function test_account_noCapacityWhileABufferAuthorizationBlocksBorrowing() public {
        _fundCollateral(alice, 25 * TOKEN);
        _borrow(alice, 5_000 * USDG);
        _authorize(alice, 1_000 * USDG, 1_000 * USDG, uint64(MON_CLOSE));
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 5_000 * USDG);
        assertGt(lens.accountView(alice).borrowCapacity, 0, "before A the plan does not block");

        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 120 minutes);
        assertTrue(s.canBorrow);
        assertTrue(escrow.blocksBorrowing(alice, s));
        assertEq(lens.accountView(alice).borrowCapacity, 0);
        assertGt(lens.accountView(bob).borrowCapacity, 0);

        vm.prank(alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.borrow(MIN_LOAN, alice);
    }

    // ---------------------------------------------------------------- account view: trims and buffers

    /// INV-LENS-21: trimAtFinal is quoted only in OPEN, PRE_CLOSE and FINAL_WINDOW; in FINAL_WINDOW it equals
    /// trimNow; in CLOSED and both reopening phases every trimAtFinal field is zero, even when trimNow is eligible.
    function test_account_trimAtFinalIsQuotedOnlyBeforeTheClose() public {
        _workedExample(carol);
        StockReefLens.AccountView memory v = lens.accountView(carol);
        assertTrue(v.trimmableAtFinal, "OPEN");
        assertEq(v.trimAtFinalBonusWad, 0.02e18);
        assertGt(v.trimAtFinalRepay, 0);

        _tick(FRI_CLOSE - 30 minutes);
        v = lens.accountView(carol);
        assertEq(uint256(policy.snapshot().state), uint256(SessionRiskPolicy.State.FINAL_WINDOW));
        assertTrue(v.trimNow.eligible);
        assertEq(v.trimmableAtFinal, v.trimNow.eligible);
        assertEq(v.trimAtFinalRepay, v.trimNow.repaid);
        assertEq(v.trimAtFinalCollateral, v.trimNow.collateralOut);
        assertEq(v.trimAtFinalBonusWad, v.trimNow.bonusWad);

        uint64[3] memory later = [FRI_CLOSE + 1 hours, MON_OPEN + 1 minutes, MON_OPEN + 5 minutes];
        for (uint256 i; i < later.length; ++i) {
            _tick(later[i]);
            v = lens.accountView(carol);
            assertFalse(v.trimmableAtFinal);
            assertEq(v.trimAtFinalRepay, 0);
            assertEq(v.trimAtFinalCollateral, 0);
            assertEq(v.trimAtFinalBonusWad, 0);
        }
        assertEq(uint256(policy.snapshot().state), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        assertTrue(v.trimNow.eligible, "recovery trims at the weekend LT");
    }

    /// INV-LENS-19, INV-LENS-18: before the keeper's refresh records an admissible reopening the views still show
    /// REOPEN_WAIT and no trim, although trim() admits and executes; after the refresh the same-time trimNow is
    /// exactly what trim() does.
    function test_account_viewsLagAnUnrecordedAdmissionUntilTheKeeperRefreshes() public {
        _workedExample(carol);
        vm.warp(MON_OPEN + 5 minutes);
        stockFeed.push(300e8); // gapped reopening, published but not yet recorded by the gate

        StockReefLens.AccountView memory v = lens.accountView(carol);
        assertEq(uint256(lens.marketView().policy.phase), uint256(SessionRiskPolicy.State.REOPEN_WAIT));
        assertFalse(v.trimNow.eligible);

        uint256 snap = vm.snapshotState();
        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, block.timestamp);
        assertGt(repaid, 0);
        vm.revertToState(snap);

        gate.refresh();
        v = lens.accountView(carol);
        assertEq(uint256(lens.marketView().policy.state), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        assertTrue(v.trimNow.eligible);
        assertFalse(v.trimNow.bufferPending);
        assertEq(v.trimNow.repaid, repaid);
        assertEq(v.trimNow.collateralOut, out);
    }

    /// INV-LENS-22, mutant `bufferActive s.time < plan.expiry -> <=`: the plan reads inactive from its expiry,
    /// as the escrow treats it.
    function test_account_bufferIsInactiveFromItsExpiry() public {
        _workedExample(alice);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        _authorize(alice, 1_000 * USDG, 1_000 * USDG, expiry);
        _tick(expiry - 1);
        assertTrue(lens.accountView(alice).bufferActive);
        _tick(expiry);
        StockReefLens.AccountView memory v = lens.accountView(alice);
        assertFalse(v.bufferActive);
        assertEq(v.plan.expiry, expiry);
        assertEq(v.bufferCoverage, 0);
    }

    /// INV-LENS-20, INV-LENS-22, mutant `remove b.session = s.session`: bufferCoverage counts the allowance already
    /// spent in the current session. After a cap-limited execution at A the plan is still short of its target and
    /// funded, yet it can repay nothing more this session, so coverage and bufferExecutableNow are both zero; the
    /// next session's allowance restores the coverage.
    function test_account_bufferCoverageCountsTheAllowanceSpentThisSession() public {
        _workedExample(alice); // 700 USDG to reach 65%
        _authorize(alice, 1_000 * USDG, 300 * USDG, uint64(TUE_OPEN + 1 days));
        assertEq(lens.accountView(alice).bufferCoverage, 300 * USDG, "cap-limited before A");

        _tick(FRI_CLOSE - 120 minutes);
        assertEq(escrow.executeBuffer(alice), 300 * USDG, "cap-limited execution");

        _tick(FRI_CLOSE - 119 minutes);
        StockReefLens.AccountView memory v = lens.accountView(alice);
        assertGt(v.repayToTarget, 0, "still above the plan target");
        assertEq(v.plan.balance, 700 * USDG, "still funded");
        assertEq(v.plan.spent, 300 * USDG);
        assertEq(v.plan.spentSession, policy.snapshot().session + 1, "spent in this session");
        assertEq(v.bufferExecutableNow, 0, "allowance spent");
        assertEq(v.bufferCoverage, 0, "coverage counts the spent allowance");
        vm.expectRevert();
        escrow.executeBuffer(alice);

        _tick(FRI_CLOSE + 1 hours);
        assertEq(lens.accountView(alice).bufferCoverage, 300 * USDG, "closed: the next session's allowance");

        _tick(MON_OPEN + 5 minutes);
        _tick(MON_OPEN + 15 minutes);
        v = lens.accountView(alice);
        assertEq(v.bufferCoverage, 300 * USDG, "a new session's allowance");
        assertEq(v.bufferExecutableNow, 0, "not before A");
    }

    // ---------------------------------------------------------------- account view: missed execution

    /// INV-LENS-24: above the closure's LT the account is flagged through CLOSED and REOPEN_WAIT with an exposure
    /// equal to repayToTarget; the flag clears at admission; an account below LT is never flagged.
    function test_account_missedExecutionThroughTheClosureUntilAdmission() public {
        _workedExample(carol); // 72%, above the weekend LT of 70%
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 6_000 * USDG); // 60%
        assertFalse(lens.accountView(carol).missedExecution, "OPEN");

        uint64[2] memory closed = [FRI_CLOSE + 1 hours, MON_OPEN + 1 minutes];
        for (uint256 i; i < closed.length; ++i) {
            _tick(closed[i]);
            StockReefLens.AccountView memory c = lens.accountView(carol);
            assertTrue(c.missedExecution);
            assertGt(c.exposure, 0);
            assertEq(c.exposure, c.repayToTarget);
            StockReefLens.AccountView memory b = lens.accountView(bob);
            assertFalse(b.missedExecution);
            assertEq(b.exposure, 0);
        }
        assertEq(uint256(policy.snapshot().phase), uint256(SessionRiskPolicy.State.REOPEN_WAIT));

        _tick(MON_OPEN + 5 minutes);
        StockReefLens.AccountView memory v = lens.accountView(carol);
        assertEq(uint256(policy.snapshot().phase), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY));
        assertFalse(v.missedExecution, "clears at admission");
        assertEq(v.exposure, 0);
    }

    /// INV-LENS-24, mutant `missedExecution > -> >=`: a position exactly at the closure's LT (D = 0.70 * V) is
    /// not trimmable, so it is not flagged.
    function test_account_missedExecutionIsStrictAtTheThreshold() public {
        _workedExample(carol);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE + 1 hours);
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.CLOSED));
        assertEq(s.ltWad, 0.7e18);
        // Repay to a debt that is a multiple of 7, so 0.70 * V can equal it exactly.
        uint256 d = market.debtOf(carol);
        for (uint256 k; d % 7 != 0 && k < 8; ++k) {
            _repay(carol, d % 7 + 7 * k);
            d = market.debtOf(carol);
        }
        assertEq(d % 7, 0, "precondition: debt divisible by 7");
        uint256 wantRaw = (d * 10 / 7) * 2_500_000_000; // value = raw * 400e18 / 1e30
        _fundCollateral(carol, wantRaw - market.collateralOf(carol));

        StockReefLens.AccountView memory v = lens.accountView(carol);
        assertEq(v.debt * WAD, s.ltWad * v.collateralValue, "precondition: exactly at LT");
        assertFalse(v.missedExecution);
        assertEq(v.exposure, 0);
    }

    // ---------------------------------------------------------------- gas

    /// INV-LENS-27: at the 32-account cap, with borrowing open (every account view values the whole book again),
    /// cold Lens views stay far below the RPC eth_call cap and a lender deposit costs less than 3M gas.
    function test_gas_viewsAndLenderDepositAtTheAccountCap() public {
        _fillAccounts(32);
        _tick(FRI_OPEN + 1 hours);
        assertTrue(policy.snapshot().canBorrow);

        _coolAll();
        uint256 g = gasleft();
        StockReefLens.AccountView[] memory all = lens.activeAccountViews();
        uint256 viewsGas = g - gasleft();
        assertEq(all.length, 32);
        _coolAll();
        g = gasleft();
        lens.marketView();
        uint256 marketGas = g - gasleft();
        _coolAll();
        g = gasleft();
        _lend(1_000 * USDG);
        uint256 depositGas = g - gasleft();

        emit log_named_uint("activeAccountViews gas, 32 accounts, cold", viewsGas);
        emit log_named_uint("marketView gas, 32 accounts, cold", marketGas);
        emit log_named_uint("lender deposit gas, 32 accounts, cold", depositGas);
        assertLt(viewsGas, 10_000_000, "activeAccountViews");
        assertLt(marketGas, 1_000_000, "marketView");
        assertLt(depositGas, 3_000_000, "lender deposit");
    }

    function _coolAll() internal {
        address[9] memory all = [
            address(market),
            address(gate),
            address(policy),
            address(cal),
            address(stockFeed),
            address(tsla),
            address(usdg),
            address(escrow),
            address(lens)
        ];
        for (uint256 i; i < all.length; ++i) {
            vm.cool(all[i]);
        }
    }
}
