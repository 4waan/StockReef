// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {PriceGate} from "../../src/PriceGate.sol";

/// @notice Fuzzed accounting properties of StockReefMarket: debt shares and their rounding, the continuously
/// compounded index, the utilization cap and impairment, the active set and the minimum loan, trims, debt-backed
/// collateral withdrawal and the lender book. Times are Friday 2026-09-11 (weekend close) and the Monday after.
contract MarketAccountingPropertiesTest is MarketFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SHARE_UNIT = 1e36;
    /// @dev Slot of StockReefMarket._activeSlot (forge inspect StockReefMarket storageLayout).
    uint256 internal constant ACTIVE_SLOT_MAPPING = 10; // forge inspect StockReefMarket storageLayout
    /// @dev First clock offset from `epoch` at which expWad(RATE_PER_SECOND * dt) overflows (about 1353 years).
    uint256 internal constant INDEX_OVERFLOW_DT = 42_670_099_967;

    address internal dave = makeAddr("dave");

    function setUp() public {
        _setUpMarket();
        _openFriday();
        usdg.mint(lender, 9_000_000 * USDG);
        _lend(1_000_000 * USDG);
    }

    // ================================================================ helpers

    /// @dev Fund `who` with `raw` collateral and borrow `ltvBps` of its value at 400.
    function _position(address who, uint256 raw, uint256 ltvBps) internal returns (uint256 amount) {
        _fundCollateral(who, raw);
        amount = gate.valueOf(raw, 400e18) * ltvBps / 10_000;
        if (amount >= MIN_LOAN) _borrow(who, amount);
    }

    function _approveRepay(address who) internal {
        usdg.mint(who, 100_000_000 * USDG);
        vm.prank(who);
        usdg.approve(address(market), type(uint256).max);
    }

    function _shares(address who) internal view returns (uint256 s) {
        (, s,) = market.accountOf(who);
    }

    function _activeSlot(address who) internal view returns (uint256) {
        return uint256(vm.load(address(market), keccak256(abi.encode(who, ACTIVE_SLOT_MAPPING))));
    }

    /// @dev The active list holds exactly the accounts of `pool` with debt shares, each slot points back to its
    /// position, and no account is listed twice.
    function _assertActiveSetExact(address[] memory pool) internal view {
        address[] memory act = market.activeAccounts();
        uint256 withDebt;
        uint256 sum;
        for (uint256 i; i < pool.length; ++i) {
            uint256 s = _shares(pool[i]);
            sum += s;
            uint256 slot = _activeSlot(pool[i]);
            if (s != 0) {
                ++withDebt;
                assertGt(slot, 0, "indebted account is listed");
                assertEq(act[slot - 1], pool[i], "slot points at the account");
            } else {
                assertEq(slot, 0, "account without debt is not listed");
            }
        }
        assertEq(act.length, withDebt, "no other entries");
        for (uint256 i; i < act.length; ++i) {
            assertEq(_activeSlot(act[i]), i + 1, "each entry has its own slot");
        }
        assertEq(market.totalDebtShares(), sum, "totalDebtShares is the sum of account shares");
        assertEq(sum == 0, act.length == 0);
    }

    /// @dev A time inside a trim window: Friday OPEN, PRE_CLOSE or FINAL_WINDOW, or Monday's reopening recovery.
    function _trimTime(uint256 seed) internal pure returns (uint256) {
        if (seed % 4 == 3) return MON_OPEN + 5 minutes + (seed >> 8) % 10 minutes;
        return FRI_OPEN + 20 minutes + (seed >> 8) % (FRI_CLOSE - FRI_OPEN - 20 minutes);
    }

    function _bookOf(address[] memory pool, uint256 priceWad)
        internal
        view
        returns (uint256 totalDebt, uint256 recoverable)
    {
        for (uint256 i; i < pool.length; ++i) {
            uint256 debt = market.debtOf(pool[i]);
            uint256 value = gate.valueOf(market.collateralOf(pool[i]), priceWad);
            totalDebt += debt;
            recoverable += Math.min(debt, Math.mulDiv(value, WAD, WAD + market.RECOVERY_HAIRCUT()));
        }
    }

    // ================================================================ debt shares and rounding

    /// INV-MKT-16, INV-MKT-17 (mutants: borrow shares Floor, _debt Floor)
    function testFuzz_debt_borrowMintsCeilSharesAndDebtRoundsUp(uint256 amount, uint256 dt, uint256 later) public {
        _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 4 hours));
        _fundCollateral(bob, 10_000 * TOKEN);
        amount = bound(amount, MIN_LOAN, 800_000 * USDG);
        uint256 idx = market.debtIndex();
        _borrow(bob, amount);
        (, uint256 shares, uint256 debt) = market.accountOf(bob);
        assertEq(shares, Math.mulDiv(amount, SHARE_UNIT, idx, Math.Rounding.Ceil), "ceil shares");
        assertGe(shares * idx, amount * SHARE_UNIT, "shares cover the principal");
        assertLt((shares - 1) * idx, amount * SHARE_UNIT, "and are the fewest that do");
        assertGe(debt, amount);
        assertLe(debt, amount + 1, "debt rises by amount or amount + 1");
        assertEq(market.totalDebtShares(), shares);

        vm.warp(block.timestamp + bound(later, 0, 3 days));
        idx = market.debtIndex();
        debt = market.debtOf(bob);
        assertEq(debt, Math.mulDiv(shares, idx, SHARE_UNIT, Math.Rounding.Ceil), "debt rounds up");
        assertGe(debt * SHARE_UNIT, shares * idx);
        assertLt((debt - 1) * SHARE_UNIT, shares * idx);
    }

    /// INV-MKT-16, INV-MKT-07, INV-MKT-12, INV-MKT-35
    function testFuzz_debt_borrowAndRepayRoundAgainstTheBorrower(uint256 dt, uint256 b, uint256 r) public {
        _fundCollateral(bob, 1_000 * TOKEN);
        _borrow(bob, 50_000 * USDG);
        _approveRepay(bob);
        _tick(block.timestamp + bound(dt, 1, 100 minutes));

        b = bound(b, 1, 50_000 * USDG);
        uint256 d0 = market.debtOf(bob);
        uint256 ta0 = market.totalAssets();
        _borrow(bob, b);
        uint256 d1 = market.debtOf(bob);
        assertGe(d1, d0 + b);
        assertLe(d1, d0 + b + 1, "borrow adds amount or amount + 1");
        assertGe(market.totalAssets(), ta0);
        assertLe(market.totalAssets(), ta0 + 1, "borrow raises totalAssets by 0 or 1");

        r = bound(r, 1, d1 - MIN_LOAN);
        uint256 ta1 = market.totalAssets();
        uint256 cash1 = market.cash();
        vm.prank(bob);
        uint256 paid = market.repay(r, bob);
        uint256 d2 = market.debtOf(bob);
        assertEq(paid, r);
        assertEq(market.cash() - cash1, r);
        assertLe(d2, d1 - r + 1, "partial repay lowers debt by paid or paid - 1");
        assertGe(d2, d1 - r);
        assertGe(market.totalAssets(), ta1, "repay never lowers totalAssets");

        vm.prank(bob);
        paid = market.repay(type(uint256).max, bob);
        assertEq(paid, d2, "repay-all takes exactly the debt");
        assertEq(_shares(bob), 0);
        assertEq(market.totalDebtShares(), 0);
        assertEq(market.activeAccounts().length, 0);
    }

    /// INV-MKT-16
    function testFuzz_debt_borrowingExactlyTheLimitCanFailByOneUnit(uint256 raw, uint256 dt) public {
        _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 4 hours));
        raw = bound(raw, TOKEN / 10, 1_000 * TOKEN);
        _fundCollateral(bob, raw);
        uint256 limit = gate.valueOf(raw, 400e18) * 0.75e18 / WAD;
        vm.assume(limit > MIN_LOAN + 1);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        try market.borrow(limit, bob) {
            assertLe(market.debtOf(bob) * WAD, 0.75e18 * gate.valueOf(raw, 400e18));
        } catch (bytes memory err) {
            assertEq(bytes4(err), StockReefMarket.AboveBorrowLimit.selector, "only the share rounding can fail it");
        }
        vm.revertToState(snap);
        _borrow(bob, limit - 1); // one unit below always fits
    }

    // ================================================================ interest

    /// INV-MKT-15
    function testFuzz_index_neverDecreasesSecondToSecond(uint256 dt) public {
        dt = bound(dt, 0, 1_300 * 365 days);
        vm.warp(market.epoch() + dt);
        uint256 i0 = market.debtIndex();
        vm.warp(block.timestamp + 1);
        assertLe(i0, market.debtIndex());
        assertGe(i0, WAD);
    }

    /// INV-MKT-15: scan every second around the range-reduction boundaries x = k * ln 2 of expWad.
    function test_index_isMonotoneAroundRangeReductionBoundaries() public {
        uint64 epoch = market.epoch();
        uint256 rate = market.RATE_PER_SECOND();
        for (uint256 k = 1; k < 40; ++k) {
            uint256 center = (k * 693147180559945309) / rate;
            vm.warp(epoch + center - 30);
            uint256 prev = market.debtIndex();
            for (uint256 dt = center - 29; dt <= center + 30; ++dt) {
                vm.warp(epoch + dt);
                uint256 cur = market.debtIndex();
                assertLe(prev, cur);
                prev = cur;
            }
        }
    }

    /// INV-MKT-15, INV-X-03
    function test_index_startsAtOneAndOverflowsOnlyAfterCenturies() public {
        uint64 epoch = market.epoch();
        vm.warp(epoch);
        assertEq(market.debtIndex(), WAD, "1.0 at deployment");
        vm.warp(epoch + 365 days);
        assertApproxEqRel(market.debtIndex(), 1.105170918075647624e18, 1e9, "e^0.1 after a year");
        vm.warp(epoch + INDEX_OVERFLOW_DT - 1);
        assertGt(market.debtIndex(), 0);
        vm.warp(epoch + INDEX_OVERFLOW_DT);
        vm.expectRevert(FixedPointMathLib.ExpOverflow.selector);
        market.debtIndex();
        // A clock behind the epoch underflows.
        vm.warp(epoch - 1);
        vm.expectRevert();
        market.debtIndex();
    }

    /// INV-MKT-14, INV-MKT-15, INV-X-20, INV-X-21
    function testFuzz_interest_debtDependsOnlyOnTheTime(uint256 dt, uint256 steps, uint256 noise) public {
        _position(bob, 25 * TOKEN, 7_000);
        _position(carol, 25 * TOKEN, 6_000);
        _fundCollateral(dave, 100 * TOKEN);
        _approveRepay(dave);
        uint256 t = FRI_OPEN + 16 minutes + bound(dt, 1 minutes, 4 hours);
        steps = bound(steps, 1, 12);

        uint256 snap = vm.snapshotState();
        vm.warp(t);
        uint256 bobDirect = market.debtOf(bob);
        uint256 carolDirect = market.debtOf(carol);
        vm.revertToState(snap);

        uint256 last = market.debtOf(bob);
        for (uint256 i = 1; i <= steps; ++i) {
            _tick(FRI_OPEN + 15 minutes + (t - FRI_OPEN - 15 minutes) * i / (steps + 1));
            uint256 now_ = market.debtOf(bob);
            assertGe(now_, last, "debt never falls with time");
            last = now_;
            market.accountOf(carol);
            market.totalAssets();
            // Someone else's borrowing and repaying in between.
            if ((noise >> i) & 1 == 1) {
                vm.prank(dave);
                try market.borrow(MIN_LOAN + i, dave) {} catch {}
            } else if (market.debtOf(dave) != 0) {
                vm.prank(dave);
                market.repay(type(uint256).max, dave);
            }
        }
        _tick(t);
        assertEq(market.debtOf(bob), bobDirect, "checkpoints never change accrual");
        assertEq(market.debtOf(carol), carolDirect);
    }

    /// INV-MKT-11, INV-MKT-15
    function testFuzz_interest_lendersNeverEarnMoreThanBorrowersOwe(uint256 priceSeed, uint256 dt) public {
        _position(bob, 25 * TOKEN, 7_000);
        _position(carol, 25 * TOKEN, 7_200);
        _setPrice(int256(bound(priceSeed, 250e8, 450e8)));
        _tick(FRI_OPEN + 30 minutes);
        uint256 ta0 = market.totalAssets();
        uint256 debt0 = market.bookValuation().totalDebt;
        uint256 supply0 = market.totalSupply();
        uint256 price0 = market.bookValuation().priceWad;

        // No actions: time passes, through the close and the weekend, at the same price.
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
        StockReefMarket.Book memory b = market.bookValuation();
        assertEq(b.priceWad, price0, "same price (live or last accepted)");
        uint256 ta1 = market.totalAssets();
        assertGe(b.totalDebt, debt0, "debt never falls");
        assertGe(ta1, ta0, "totalAssets never falls at a fixed price");
        assertLe(ta1 - ta0, b.totalDebt - debt0, "lenders earn at most what borrowers owe");
        assertEq(market.totalSupply(), supply0, "no fee shares");
    }

    // ================================================================ utilization, impairment, slots

    /// INV-MKT-30, INV-MKT-32 (mutants: utilization > to >=, amount > cash to >=)
    function testFuzz_utilization_capIsExactlyNinetyPercentOfCashPlusDebt(uint256 otherDebt, uint256 dt) public {
        _fundCollateral(alice, 10_000 * TOKEN);
        _fundCollateral(bob, 10_000 * TOKEN);
        otherDebt = bound(otherDebt, 0, 800_000 * USDG);
        if (otherDebt >= MIN_LOAN) _borrow(alice, otherDebt);
        _tick(block.timestamp + bound(dt, 0, 3 hours));

        uint256 cash = market.cash();
        uint256 debt = market.bookValuation().totalDebt;
        uint256 aMax = (9 * cash - debt) / 10;
        vm.assume(aMax >= MIN_LOAN);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(aMax + 1, bob);
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.UtilizationCapExceeded.selector);
        market.borrow(cash, bob); // all the idle cash fails on the cap, before the cash check
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StockReefMarket.InsufficientCash.selector, cash + 1, cash));
        market.borrow(cash + 1, bob);
        vm.revertToState(snap);

        _borrow(bob, aMax);
        assertEq(cash - market.cash(), aMax, "cash moves by exactly the amount");
        assertEq(usdg.balanceOf(bob), aMax);
    }

    /// INV-MKT-50, INV-MKT-09
    function testFuzz_impairment_blocksAllNewCreditIffSomeLoanIsUnderwater(uint256 priceSeed) public {
        _workedExample(carol);
        _fundCollateral(alice, 100 * TOKEN);
        int256 p = int256(bound(priceSeed, 280e8, 330e8));
        _setPrice(p);
        _tick(FRI_OPEN + 1 hours);
        uint256 debt = market.debtOf(carol);
        uint256 rec = Math.mulDiv(gate.valueOf(25 * TOKEN, uint256(p) * 1e10), WAD, 1.05e18);
        bool underwater = rec < debt;
        assertEq(market.bookValuation().impaired, underwater);
        vm.prank(alice);
        if (underwater) vm.expectRevert(StockReefMarket.MarketImpaired.selector);
        market.borrow(100 * USDG, alice);
    }

    /// INV-MKT-04, INV-MKT-33, INV-MKT-03
    function testFuzz_activeSet_staysExactThroughRepaymentsAndReborrows(uint256 n, uint256 seed) public {
        n = bound(n, 1, 12);
        address[] memory pool = new address[](n);
        for (uint256 i; i < n; ++i) {
            pool[i] = address(uint160(0x5000 + i));
            _fundCollateral(pool[i], TOKEN);
            _borrow(pool[i], 2 * MIN_LOAN + i * USDG);
            _approveRepay(pool[i]);
        }
        _assertActiveSetExact(pool);
        for (uint256 step; step < 2 * n; ++step) {
            address who = pool[uint256(keccak256(abi.encode(seed, step))) % n];
            vm.startPrank(who);
            if (_shares(who) != 0) {
                if ((seed >> step) & 1 == 1 || market.debtOf(who) < MIN_LOAN + 1 * USDG + 1) {
                    market.repay(type(uint256).max, who);
                    assertEq(_shares(who), 0, "repaying in full clears the shares");
                } else {
                    market.repay(1 * USDG, who);
                    assertGt(_shares(who), 0, "a partial repayment never clears the shares");
                }
            } else {
                market.borrow(MIN_LOAN, who);
            }
            vm.stopPrank();
            _assertActiveSetExact(pool);
        }
    }

    // ================================================================ minimum loan (R16)

    /// INV-MKT-34
    function testFuzz_minLoan_borrowAndRepayLeaveNoDebtOrAtLeastTheMinimum(uint256 b, uint256 r, uint256 dt) public {
        _fundCollateral(bob, 10 * TOKEN);
        _approveRepay(bob);
        _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 4 hours));
        b = bound(b, 1, 4 * MIN_LOAN);
        vm.prank(bob);
        if (b < MIN_LOAN) {
            vm.expectRevert(abi.encodeWithSelector(StockReefMarket.BelowMinimumLoan.selector, b, MIN_LOAN));
            market.borrow(b, bob);
            return;
        }
        market.borrow(b, bob);
        vm.warp(block.timestamp + bound(dt >> 64, 0, 10 days));

        uint256 debt = market.debtOf(bob);
        assertGe(debt, MIN_LOAN);
        r = bound(r, 1, 2 * debt);
        uint256 idx = market.debtIndex();
        uint256 s = _shares(bob);
        uint256 predicted =
            r >= debt ? 0 : Math.mulDiv(s - Math.mulDiv(r, SHARE_UNIT, idx), idx, SHARE_UNIT, Math.Rounding.Ceil);
        vm.prank(bob);
        if (predicted != 0 && predicted < MIN_LOAN) {
            vm.expectRevert(abi.encodeWithSelector(StockReefMarket.BelowMinimumLoan.selector, predicted, MIN_LOAN));
            market.repay(r, bob);
        } else {
            uint256 paid = market.repay(r, bob);
            assertEq(paid, Math.min(r, debt), "pays min(amount, debt)");
            assertEq(market.debtOf(bob), predicted);
        }
        uint256 left = market.debtOf(bob);
        assertTrue(left == 0 || left >= MIN_LOAN, "no dust below the minimum");
    }

    // ================================================================ trims

    /// INV-MKT-27, INV-MKT-40
    function testFuzz_trim_eligibleOnlyStrictlyAboveTheThreshold(uint256 priceSeed, uint256 timeSeed) public {
        _workedExample(carol);
        _setPrice(int256(bound(priceSeed, 300e8, 420e8)));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        bool expected = s.canTrim && q.debt != 0 && q.debt * WAD > s.ltWad * q.value;
        assertEq(q.eligible, expected, "eligible iff LTV strictly above LT");
        assertEq(q.debt, market.debtOf(carol));
        assertEq(q.value, gate.valueOf(25 * TOKEN, s.priceWad));
        vm.prank(liquidator);
        if (!expected) {
            vm.expectPartialRevert(StockReefMarket.NotEligible.selector);
            market.trim(carol, type(uint256).max, 0, block.timestamp);
        } else {
            market.trim(carol, type(uint256).max, 0, block.timestamp);
            assertLt(market.debtOf(carol), q.debt);
        }
    }

    /// INV-MKT-19, INV-MKT-20, INV-MKT-18
    function testFuzz_trim_solventFullFillLandsOnTheTarget(uint256 raw, uint256 ltvSeed, uint256 p, uint256 timeSeed)
        public
    {
        raw = bound(raw, 1e17, 400 * TOKEN) | 1; // odd raw amounts stress rounding
        _fundCollateral(carol, raw);
        uint256 amount = gate.valueOf(raw, 400e18) * bound(ltvSeed, 6_000, 7_499) / 10_000;
        vm.assume(amount >= MIN_LOAN);
        _borrow(carol, amount);
        _setPrice(int256(bound(p, 250e8 + 1, 400e8 - 1)));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        vm.assume(q.eligible && q.fullFill && q.repaid != 0 && q.collateralOut != 0);
        assertLt(q.debt * (WAD + q.bonusWad), q.value * WAD, "full fills are solvent");

        vm.prank(liquidator);
        market.trim(carol, type(uint256).max, 0, block.timestamp);
        uint256 debtAfter = market.debtOf(carol);
        uint256 valueAfter = gate.valueOf(market.collateralOf(carol), s.priceWad);
        assertLe(debtAfter * WAD, s.targetWad * valueAfter + WAD, "at most one unit above the target");
        assertLe(s.targetWad * valueAfter, debtAfter * WAD + 2 * WAD, "never more than two units past it");
        assertLe(debtAfter * q.value, (q.debt + 1) * (valueAfter + 1), "LTV did not rise");
        assertEq(market.totalBadDebt(), 0);
    }

    /// @dev What a full fill of `who` leaves before trim's post-check: the debt after burning
    /// floor(repaid * 1e36 / index) shares, rounded up (zero when the fill repays all of it), and the value of the
    /// collateral left, rounded down.
    function _fullFillLeaves(address who, StockReefMarket.TrimQuote memory q, uint256 priceWad)
        internal
        view
        returns (uint256 debtAfter, uint256 valueAfter)
    {
        uint256 idx = market.debtIndex();
        if (q.repaid < q.debt) {
            uint256 burned = Math.mulDiv(q.repaid, SHARE_UNIT, idx);
            debtAfter = Math.mulDiv(_shares(who) - burned, idx, SHARE_UNIT, Math.Rounding.Ceil);
        }
        valueAfter = gate.valueOf(market.collateralOf(who) - q.collateralOut, priceWad);
    }

    /// INV-MKT-19 (mutant: the full-fill TargetMissed post-check removed). A borrow of exactly k * debtIndex()
    /// base units mints exactly k * 1e36 debt shares, so the debt is a whole number at every index and the floor
    /// share burn of a full fill leaves a unit more debt; with the value floor the fill can end more than one unit
    /// above the target. Whatever the case, a full fill never executes more than one unit above the target: it
    /// lands within that unit, or reverts TargetMissed with the exact post-trim figures and moves nothing.
    function testFuzz_trim_fullFillEndsWithinOneUnitOfTheTargetOrRevertsTargetMissed(
        uint256 k,
        uint256 raw,
        uint256 p,
        uint256 timeSeed
    ) public {
        k = bound(k, 1, 3);
        usdg.mint(lender, 2e18 * k);
        _lend(2e18 * k);
        raw = bound(raw, k * 3.4e9 * TOKEN, k * 4e9 * TOKEN); // LTV 62.5% to 73.6% at 400
        _fundCollateral(carol, raw);
        _borrow(carol, k * market.debtIndex());
        assertEq(_shares(carol), k * SHARE_UNIT, "whole share units");
        _setPrice(int256(bound(p, 280e8, 400e8)));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        vm.assume(q.eligible && q.fullFill && !q.bufferPending && q.collateralOut != 0);
        assertEq(q.debt, k * market.debtIndex(), "a whole-number debt, with no rounding");
        (uint256 debtAfter, uint256 valueAfter) = _fullFillLeaves(carol, q, s.priceWad);
        usdg.mint(liquidator, q.repaid);
        TrimFlows memory f0 = _flows(carol);

        if (debtAfter * WAD > s.targetWad * valueAfter + WAD) {
            // Without the share-burn unit the value floor alone stays within the tolerance.
            assertEq(debtAfter, q.debt - q.repaid + 1, "only the share-burn unit carries a fill past it");
            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(StockReefMarket.TargetMissed.selector, debtAfter, valueAfter, s.targetWad)
            );
            market.trim(carol, type(uint256).max, 0, block.timestamp);
            TrimFlows memory f1 = _flows(carol);
            assertEq(f1.debt, f0.debt, "a rejected fill moves nothing");
            assertEq(f1.collateral, f0.collateral);
            assertEq(f1.liqUsdg, f0.liqUsdg);
            assertEq(f1.liqTsla, f0.liqTsla);
            assertEq(f1.cash, f0.cash);
        } else {
            vm.prank(liquidator);
            (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, block.timestamp);
            assertEq(repaid, q.repaid);
            assertEq(out, q.collateralOut);
            assertEq(market.debtOf(carol), debtAfter, "the debt the fill leaves");
            assertEq(gate.valueOf(market.collateralOf(carol), s.priceWad), valueAfter);
            assertLe(market.debtOf(carol) * WAD, s.targetWad * valueAfter + WAD, "within one unit of the target");
        }
    }

    /// INV-MKT-18
    function testFuzz_trim_solventTrimNeverRaisesLtv(uint256 priceSeed, uint256 repaySeed, uint256 timeSeed) public {
        _workedExample(carol);
        _setPrice(int256(bound(priceSeed, 312e8, 360e8))); // LTV 80% to 92.3%, below 1 / 1.05
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        uint256 d0 = market.debtOf(carol);
        uint256 v0 = gate.valueOf(market.collateralOf(carol), s.priceWad);
        vm.prank(liquidator);
        try market.trim(carol, bound(repaySeed, 1, 8_000 * USDG), 0, block.timestamp) {
            uint256 d1 = market.debtOf(carol);
            uint256 v1 = gate.valueOf(market.collateralOf(carol), s.priceWad);
            assertLe(d1 * v0, (d0 + 1) * (v1 + 1), "LTV rose after a solvent trim");
        } catch (bytes memory err) {
            // Only positions at or below LT, in states without trims, may refuse.
            assertTrue(
                bytes4(err) == StockReefMarket.NotEligible.selector
                    || bytes4(err) == StockReefMarket.NotAllowedNow.selector,
                "unexpected trim failure"
            );
        }
    }

    /// INV-MKT-55, INV-MKT-06, INV-MKT-05, INV-MKT-21, INV-MKT-04
    function testFuzz_trim_insolventSweepTakesEverythingAndWritesOffTheRest(uint256 priceSeed, uint256 timeSeed)
        public
    {
        _workedExample(carol);
        _workedExample(bob);
        uint256 p = bound(priceSeed, 100e8, 290e8); // LTV of at least 99%, so D * (1 + b) >= V
        _setPrice(int256(p));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        assertTrue(q.eligible);
        assertGe(q.debt * (WAD + q.bonusWad), q.value * WAD, "insolvent branch");
        uint256 all = Math.mulDiv(q.value, WAD, WAD + q.bonusWad);
        uint256 bobShares = _shares(bob);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, type(uint256).max, 0, block.timestamp);
        assertEq(repaid, all, "repays floor(V / (1 + b))");
        assertEq(out, 25 * TOKEN, "takes all collateral");
        assertEq(market.collateralOf(carol), 0);
        assertEq(_shares(carol), 0, "write-off burns the shares");
        assertEq(market.debtOf(carol), 0);
        assertGe(market.totalBadDebt() + repaid, q.debt, "the whole residual is written off");
        assertLe(market.totalBadDebt() + repaid, q.debt + 1);
        assertEq(market.totalDebtShares(), bobShares, "only carol's shares left the total");
        address[] memory act = market.activeAccounts();
        assertEq(act.length, 1, "carol left the active set");
        assertEq(act[0], bob);
        assertLe(gate.valueOf(out, s.priceWad) * WAD, repaid * (WAD + q.bonusWad) + 2 * WAD, "sweep over-delivers < 2");
    }

    /// INV-MKT-55, INV-MKT-06
    function testFuzz_trim_insolventPartialFillWritesNothingOff(uint256 priceSeed, uint256 maxRepay, uint256 timeSeed)
        public
    {
        _workedExample(carol);
        _setPrice(int256(bound(priceSeed, 200e8, 290e8)));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, type(uint256).max);
        uint256 all = Math.mulDiv(q.value, WAD, WAD + q.bonusWad);
        maxRepay = bound(maxRepay, 1 * USDG, all - 1);
        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, maxRepay, 0, block.timestamp);
        assertEq(repaid, maxRepay);
        assertEq(out, Math.mulDiv(maxRepay * (WAD + q.bonusWad), market.VALUE_SCALE(), s.priceWad * WAD));
        assertGt(market.collateralOf(carol), 0);
        assertEq(market.totalBadDebt(), 0, "no write-off while collateral remains");
        assertGt(market.debtOf(carol), 0);
    }

    /// @dev Balances a trim moves, read before and after.
    struct TrimFlows {
        uint256 liqUsdg;
        uint256 liqTsla;
        uint256 cash;
        uint256 marketUsdg;
        uint256 collateral;
        uint256 debt;
        uint256 badDebt;
        uint256 totalAssets;
    }

    function _flows(address who) internal view returns (TrimFlows memory f) {
        f.liqUsdg = usdg.balanceOf(liquidator);
        f.liqTsla = tsla.balanceOf(liquidator);
        f.cash = market.cash();
        f.marketUsdg = usdg.balanceOf(address(market));
        f.collateral = market.collateralOf(who);
        f.debt = market.debtOf(who);
        f.badDebt = market.totalBadDebt();
        f.totalAssets = market.totalAssets();
    }

    /// INV-MKT-21, INV-MKT-22, INV-MKT-08, INV-MKT-23, INV-MKT-13, INV-MKT-07, INV-MKT-56, INV-MKT-48
    function testFuzz_trim_movesExactlyItsQuote(uint256 priceSeed, uint256 maxRepay, uint256 timeSeed) public {
        _workedExample(carol);
        _position(bob, 30 * TOKEN, 6_000);
        _setPrice(int256(bound(priceSeed, 150e8, 380e8)));
        SessionRiskPolicy.Snapshot memory s = _tick(_trimTime(timeSeed));
        maxRepay = bound(maxRepay, 1, 9_000 * USDG);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(carol, s, maxRepay);
        vm.assume(q.eligible && q.repaid != 0 && q.collateralOut != 0);
        TrimFlows memory f0 = _flows(carol);
        uint256 supply = market.totalSupply();
        uint256 bobDebt = market.debtOf(bob);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out) = market.trim(carol, maxRepay, q.collateralOut, block.timestamp);
        TrimFlows memory f1 = _flows(carol);
        assertEq(repaid, q.repaid, "executes the quote");
        assertEq(out, q.collateralOut);
        assertGt(repaid, 0);
        assertGt(out, 0);
        assertLe(repaid, Math.min(maxRepay, q.debt));
        assertEq(f0.liqUsdg - f1.liqUsdg, repaid, "the liquidator pays exactly repaid");
        assertEq(f1.liqTsla - f0.liqTsla, out, "and receives exactly the collateral");
        assertEq(f1.cash - f0.cash, repaid, "lender cash rises by repaid");
        assertEq(f1.marketUsdg - f0.marketUsdg, repaid);
        assertEq(f0.collateral - f1.collateral, out);
        assertLe(gate.valueOf(out, s.priceWad) * WAD, repaid * (WAD + q.bonusWad) + 2 * WAD, "no bonus beyond b");
        // Debt falls by what was paid (one unit of share rounding), plus any recorded write-off.
        uint256 drop = f0.debt - f1.debt - (f1.badDebt - f0.badDebt);
        assertTrue(drop == repaid || drop + 1 == repaid, "debt falls by repaid or repaid - 1");
        if (f1.badDebt != f0.badDebt) assertEq(f1.collateral, 0, "write-offs only at zero collateral");
        assertGe(f1.totalAssets + 2, f0.totalAssets, "a trim lowers totalAssets by at most two units");
        assertEq(market.totalSupply(), supply, "trims mint or burn no lender shares");
        assertEq(market.debtOf(bob), bobDebt, "other accounts are untouched");
    }

    /// INV-MKT-24 (policy snapshots of the shipped configuration), INV-MKT-57
    function testFuzz_trim_quoteAndBookNeverRevertForPolicySnapshots(uint256 answerSeed, uint256 dt, uint256 raw)
        public
    {
        _workedExample(carol);
        _fundCollateral(bob, bound(raw, TOKEN, 1e9 * TOKEN));
        _borrow(bob, 100 * USDG);
        _setPrice(int256(bound(answerSeed, 1, ANSWER_BOUND)));
        _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 10 days));
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        market.quoteTrim(carol, s, type(uint256).max);
        market.quoteTrim(bob, s, type(uint256).max);
        market.quoteTrim(bob, s, 1);
        market.quoteTrim(dave, s, type(uint256).max);
        market.bookValuation();
        market.totalAssets();
        market.maxWithdraw(lender);
        market.maxRedeem(lender);
        market.maxDeposit(lender);
    }

    /// INV-MKT-24: crafted snapshots outside what the policy produces can make the arithmetic revert.
    function test_trim_quoteRevertsOnlyForCraftedSnapshots() public {
        _workedExample(carol);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        s.canTrim = true;
        s.ltWad = 0.5e18;
        s.targetWad = 0.45e18;
        assertTrue(market.quoteTrim(carol, s, type(uint256).max).eligible);

        SessionRiskPolicy.Snapshot memory early = s;
        early.time = market.epoch() - 1; // before the index starts
        vm.expectRevert();
        market.quoteTrim(carol, early, type(uint256).max);

        SessionRiskPolicy.Snapshot memory inverted = s;
        inverted.targetWad = 0.9e18; // a target above the position's LTV: D - T * V underflows
        vm.expectRevert();
        market.quoteTrim(carol, inverted, type(uint256).max);
    }

    /// INV-MKT-25
    function testFuzz_trimMath_staysInRangeForRealisticBalances(
        uint256 raw,
        uint256 priceWad,
        uint256 debt,
        uint256 targetSeed,
        bool distress,
        uint256 maxRepay
    ) public view {
        raw = bound(raw, 1, 1e9 * TOKEN);
        priceWad = bound(priceWad, 1, ANSWER_BOUND * 1e10);
        uint256 value = gate.valueOf(raw, priceWad);
        uint256[3] memory targets = [uint256(0.65e18), 0.72e18, 0.75e18];
        SessionRiskPolicy.Snapshot memory s;
        s.targetWad = targets[targetSeed % 3];
        s.priceWad = priceWad;
        // Eligible positions only: LTV above LT, which is above the target.
        debt = bound(debt, s.targetWad * value / WAD + 1, 1e18 + s.targetWad * value / WAD + 1);
        uint256 bonus = distress ? 0.05e18 : 0.02e18;
        (uint256 repaid, uint256 out,) = market.trimAmounts(raw, debt, value, s, bonus, maxRepay);
        assertLe(repaid, Math.min(maxRepay, debt));
        assertLe(out, raw);
    }

    /// INV-MKT-26
    function testFuzz_trim_valueAgreesWithTheGate(uint256 raw, uint256 priceWad) public {
        raw = bound(raw, 0, 1e9 * TOKEN);
        priceWad = bound(priceWad, 0, ANSWER_BOUND * 1e10);
        _fundCollateral(carol, raw + 1);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        s.priceWad = priceWad;
        assertEq(market.quoteTrim(carol, s, 0).value, gate.valueOf(raw + 1, priceWad));
        assertEq(market.VALUE_SCALE(), gate.VALUE_SCALE());
    }

    // ================================================================ collateral withdrawal and fresh credit

    /// INV-MKT-38, INV-MKT-31
    function testFuzz_withdrawCollateral_keepsDebtWithinTheBorrowLimit(uint256 ltvSeed, uint256 dt, uint256 raw)
        public
    {
        raw = bound(raw, TOKEN, 200 * TOKEN);
        _position(bob, raw, bound(ltvSeed, 2_000, 6_400));
        // OPEN or PRE_CLOSE, before F, where debt-backed withdrawals are allowed.
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 5 hours + 43 minutes));
        assertTrue(s.canBorrow);
        uint256 debt = market.debtOf(bob);
        uint256 needValue = Math.mulDiv(debt, WAD, s.borrowLimitWad, Math.Rounding.Ceil);
        uint256 keep = gate.rawForValue(needValue, s.priceWad, Math.Rounding.Ceil);
        vm.assume(keep < raw);
        uint256 maxOut = raw - keep;

        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.AboveBorrowLimit.selector);
        market.withdrawCollateral(maxOut + 1, bob);
        vm.revertToState(snap);

        vm.prank(bob);
        market.withdrawCollateral(maxOut, bob);
        assertEq(tsla.balanceOf(bob), maxOut);
        uint256 value = gate.valueOf(market.collateralOf(bob), s.priceWad);
        assertLe(debt * WAD, s.borrowLimitWad * value, "debt <= B * remaining value");
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, policy.snapshot(), type(uint256).max);
        assertFalse(q.eligible, "never trimmable right after");
        assertGe(Math.mulDiv(value, WAD, 1.05e18), debt, "never impaired right after");
    }

    /// INV-MKT-31
    function testFuzz_freshBorrowIsNeverTrimmableOrImpaired(uint256 raw, uint256 frac, uint256 dt) public {
        raw = bound(raw, TOKEN / 10, 500 * TOKEN);
        _fundCollateral(bob, raw);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_OPEN + 16 minutes + bound(dt, 0, 5 hours + 43 minutes));
        uint256 value = gate.valueOf(raw, s.priceWad);
        uint256 room = value * s.borrowLimitWad / WAD;
        vm.assume(room > MIN_LOAN + 1);
        uint256 amount = bound(frac, MIN_LOAN, room - 1);
        _borrow(bob, amount);
        StockReefMarket.TrimQuote memory q = market.quoteTrim(bob, policy.snapshot(), type(uint256).max);
        assertFalse(q.eligible, "LTV <= B < LT");
        assertFalse(market.bookValuation().impaired, "B < 1 / 1.05");
    }

    // ================================================================ the lender book

    /// INV-MKT-09, INV-MKT-10, INV-MKT-17 (mutant: book at the latest feed answer while indicative)
    function testFuzz_book_matchesItsDefinition(uint256 priceSeed, uint256 dt, bool stop, uint256 moveSeed) public {
        _workedExample(carol);
        _position(bob, 100 * TOKEN, 5_000);
        _setPrice(int256(bound(priceSeed, 150e8, 500e8)));
        _tick(FRI_OPEN + 30 minutes);
        if (stop) {
            vm.prank(guardian);
            gate.stop();
        }
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
        stockFeed.push(int256(bound(moveSeed, 100e8, 600e8))); // a new answer, refreshed or not
        if (moveSeed & 1 == 1) gate.refresh();

        PriceGate.Quote memory q = gate.quote();
        bool indicative = q.reasons != 0;
        uint256 price = indicative ? gate.lastPriceWad() : q.priceWad;
        address[] memory pool = new address[](2);
        (pool[0], pool[1]) = (carol, bob);
        (uint256 totalDebt, uint256 recoverable) = _bookOf(pool, price);

        StockReefMarket.Book memory b = market.bookValuation();
        assertEq(b.indicative, indicative);
        assertEq(b.priceWad, price, "usable quote, else the last accepted price");
        assertEq(b.totalDebt, totalDebt, "sum of rounded-up debts");
        assertEq(b.recoverable, recoverable, "sum of min(debt, floor(value) / 1.05)");
        assertEq(b.impaired, recoverable < totalDebt);
        uint256 ta = market.totalAssets();
        assertEq(ta, market.cash() + recoverable);
        assertGe(ta, market.cash());
        assertLe(ta, market.cash() + totalDebt);
        assertLe(market.convertToAssets(market.totalSupply()), ta);
    }

    /// INV-MKT-12, INV-MKT-56, INV-MKT-39
    function testFuzz_book_actionsAtAFixedPriceNeverLowerTotalAssets(
        uint256 priceSeed,
        uint256 borrowAmt,
        uint256 repayAmt,
        uint256 topUp,
        uint256 pull
    ) public {
        _workedExample(carol);
        _position(bob, 100 * TOKEN, 5_000);
        _fundCollateral(alice, 50 * TOKEN);
        _approveRepay(alice);
        _setPrice(int256(bound(priceSeed, 280e8, 450e8)));
        _tick(FRI_OPEN + 45 minutes);

        uint256 ta = market.totalAssets();
        if (!market.bookValuation().impaired) {
            vm.prank(alice);
            market.borrow(bound(borrowAmt, MIN_LOAN, 5_000 * USDG), alice);
            assertGe(market.totalAssets(), ta, "borrow");
            assertLe(market.totalAssets(), ta + 1, "borrow adds at most one unit");
            ta = market.totalAssets();
        }

        uint256 debt = market.debtOf(carol);
        repayAmt = bound(repayAmt, 1, debt - MIN_LOAN);
        vm.prank(alice);
        market.repay(repayAmt, carol);
        assertGe(market.totalAssets(), ta, "repay");
        ta = market.totalAssets();

        topUp = bound(topUp, 1, 10 * TOKEN);
        tsla.mint(alice, topUp);
        vm.startPrank(alice);
        tsla.approve(address(market), topUp);
        uint256 coll = market.collateralOf(carol);
        market.depositCollateral(topUp, carol);
        vm.stopPrank();
        assertEq(market.collateralOf(carol), coll + topUp, "credited exactly");
        assertGe(market.totalAssets(), ta, "depositCollateral");
        ta = market.totalAssets();

        pull = bound(pull, 1, TOKEN);
        vm.prank(bob);
        market.withdrawCollateral(pull, bob);
        assertEq(market.totalAssets(), ta, "withdrawCollateral");
    }

    /// INV-MKT-12, INV-X-18
    function testFuzz_book_bufferExecutionNeverLowersTotalAssets(uint256 balance, uint256 dt) public {
        _position(alice, 25 * TOKEN, 7_200);
        usdg.mint(alice, 10_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(bound(balance, 1 * USDG, 3_000 * USDG), alice);
        escrow.authorize(0.65e18, 3_000 * USDG, uint64(MON_CLOSE));
        vm.stopPrank();
        uint256 escrowed = usdg.balanceOf(address(escrow));
        uint256 ta0 = market.totalAssets();
        assertEq(ta0, market.cash() + market.debtOf(alice), "escrow is not lender cash");
        _tick(FRI_CLOSE - 120 minutes + bound(dt, 0, 115 minutes));
        uint256 ta = market.totalAssets();
        uint256 cash = market.cash();
        uint256 repaid = escrow.executeBuffer(alice);
        assertGe(market.totalAssets(), ta);
        assertEq(market.cash() - cash, repaid, "escrow enters cash only through repay");
        assertEq(escrowed - usdg.balanceOf(address(escrow)), repaid);
    }

    // ================================================================ constants

    /// INV-X-08
    function test_constants_keepTheTrimAndValuationMathConsistent() public view {
        uint256 haircut = market.RECOVERY_HAIRCUT();
        uint256 bonus = policy.BONUS_DISTRESS();
        assertLe(policy.BONUS_SCHEDULING(), bonus);
        assertLe(bonus, haircut, "bonus <= haircut");
        assertLt(policy.B_OPEN() * (WAD + haircut), WAD * WAD, "B_OPEN < 1 / 1.05");
        assertLt(policy.B_OPEN(), policy.LT_OPEN());
        assertLe(policy.LT_OPEN(), 0.8e18);
        assertLe(policy.LT_FINAL_OVERNIGHT(), policy.LT_OPEN());
        assertLe(policy.LT_FINAL_EXTENDED(), policy.LT_FINAL_OVERNIGHT());
        assertLt(policy.TARGET_OPEN(), policy.LT_OPEN());
        assertLt(policy.TARGET_OVERNIGHT(), policy.LT_FINAL_OVERNIGHT());
        assertLt(policy.TARGET_EXTENDED(), policy.LT_FINAL_EXTENDED());
        assertLt(policy.LT_OPEN() * (WAD + bonus), WAD * WAD, "(1 + b) * LT < 1");
        assertLe(escrow.MAX_TARGET(), policy.TARGET_EXTENDED(), "escrow targets sit below every trim target");
        assertLe(escrow.MAX_TARGET(), policy.TARGET_OVERNIGHT());
    }

    /// INV-X-08
    function testFuzz_constants_everySnapshotKeepsTheTrimDenominatorPositive(uint256 dt, bool monday) public {
        uint256 t = monday ? MON_OPEN + bound(dt, 5 minutes, 6 hours) : FRI_OPEN + bound(dt, 16 minutes, 6 hours);
        SessionRiskPolicy.Snapshot memory s = _tick(t);
        assertLt(s.targetWad, s.ltWad, "target below LT");
        assertLt(s.targetWad * (WAD + policy.BONUS_DISTRESS()), WAD * WAD, "T * (1 + b) < 1");
        if (s.canBorrow) assertLt(s.borrowLimitWad, s.ltWad, "B < LT");
        assertLe(s.ltWad, policy.LT_OPEN());
    }
}
