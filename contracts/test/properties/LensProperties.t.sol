// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

/// @notice Field-by-field checks of the Lens against the contracts it reads, shared by the fuzz and invariant
/// suites below. Every check is made at one block, against the same state the Lens sees.
abstract contract LensPropertyChecks is MarketFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX = type(uint256).max;

    StockReefLens internal lens;

    function _setUpLens() internal {
        _setUpMarket();
        lens = new StockReefLens(market);
        usdg.mint(liquidator, 100_000_000 * USDG);
    }

    /// @dev Escrow `amount` for `who` and authorize `target` with `cap` per session until `expiry`.
    function _authorize(address who, uint256 target, uint256 amount, uint256 cap, uint64 expiry) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(amount, who);
        escrow.authorize(target, cap, expiry);
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

    // ---------------------------------------------------------------- market view

    /// @dev INV-LENS-02, -03, -04, -05, -06, -08, -09, -14: every marketView field equals its source.
    function _checkMarketView() internal view returns (StockReefLens.MarketView memory m) {
        m = lens.marketView();
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(keccak256(abi.encode(m.policy)), keccak256(abi.encode(s)), "policy snapshot");
        assertEq(m.simulationClock, clock.isSimulation(), "simulationClock");
        assertEq(m.usesPeg, gate.usesPeg(), "usesPeg");
        assertEq(m.pegLabel, gate.pegLabel(), "pegLabel");
        assertEq(m.cash, market.cash(), "cash");
        assertEq(m.totalAssets, market.totalAssets(), "totalAssets");
        assertEq(m.totalShares, market.totalSupply(), "totalShares");
        _checkBook(m, s);
        assertEq(m.totalBadDebt, market.totalBadDebt(), "totalBadDebt");
        assertEq(m.activeAccounts, market.activeAccounts().length, "activeAccounts");
        assertLe(m.activeAccounts, market.MAX_ACCOUNTS(), "account cap");
        assertEq(m.maxAccounts, 32, "maxAccounts");
        assertEq(m.minLoan, market.minLoan(), "minLoan");
        assertEq(m.lastAcceptedAt, gate.lastAcceptedAt(), "lastAcceptedAt");
        assertLe(m.lastAcceptedAt, s.time, "lastAcceptedAt in the past");
        assertEq(m.debtIndex, market.debtIndex(), "debtIndex");
        assertGe(m.debtIndex, WAD, "debtIndex from 1.0");
        uint256 e = tsla.effectiveAt();
        assertEq(m.multiplierEffectiveAt, e > s.time ? uint64(e) : 0, "multiplierEffectiveAt");
        assertEq(m.pendingMultiplier, e > s.time ? tsla.newUIMultiplier() : 0, "pendingMultiplier");
        _checkLenderWindow(m, s);
    }

    function _checkBook(StockReefLens.MarketView memory m, SessionRiskPolicy.Snapshot memory s) internal view {
        StockReefMarket.Book memory b = market.bookValuation();
        assertEq(m.totalDebt, b.totalDebt, "totalDebt");
        assertEq(m.recoverable, b.recoverable, "recoverable");
        assertEq(m.impaired, b.impaired, "impaired");
        assertEq(m.valuationIndicative, b.indicative, "indicative");
        assertEq(m.valuationPriceWad, b.priceWad, "valuation price");
        // INV-LENS-02
        // Idle cash only in wind-down (appendix R19).
        assertEq(m.totalAssets, s.windDown ? m.cash : m.cash + m.recoverable, "totalAssets = cash + recoverable");
        assertLe(m.recoverable, m.totalDebt, "recoverable <= debt");
        assertEq(m.impaired, m.recoverable < m.totalDebt, "impaired iff recoverable < debt");
        // INV-LENS-03
        uint256 book = m.cash + m.totalDebt;
        assertEq(m.utilizationWad, book == 0 ? 0 : Math.mulDiv(m.totalDebt, WAD, book), "utilization");
        assertLe(m.utilizationWad, WAD, "utilization <= 100%");
        // INV-LENS-04
        assertEq(m.valuationIndicative, s.reasons != 0, "indicative iff reasons");
        assertEq(m.valuationPriceWad, s.reasons != 0 ? gate.lastPriceWad() : gate.quote().priceWad, "book price");
        // INV-LENS-14
        if (s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen) {
            assertEq(m.valuationPriceWad, s.priceWad, "book price is the execution price");
        }
    }

    /// @dev INV-LENS-06, INV-LENS-08 (covered sessions): open now iff lenderOpen, else this session's opening
    /// before A, else the next loaded session's (O + 15 min, C - 2 h); (0, 0) outside coverage.
    function _checkLenderWindow(StockReefLens.MarketView memory m, SessionRiskPolicy.Snapshot memory s) internal view {
        if (!s.covered) {
            assertEq(m.lenderWindowOpensAt, 0, "uncovered opensAt");
            assertEq(m.lenderWindowClosesAt, 0, "uncovered closesAt");
            assertFalse(s.lenderOpen, "uncovered lenders closed");
            return;
        }
        assertEq(m.lenderWindowOpensAt == 0 && m.lenderWindowClosesAt != 0, s.lenderOpen, "open now iff lenderOpen");
        if (s.lenderOpen) {
            assertEq(m.lenderWindowClosesAt, s.prepAt, "open until A");
            assertGt(m.lenderWindowClosesAt, s.time, "A in the future");
        } else if (s.time >= s.open && s.time < s.prepAt) {
            assertEq(m.lenderWindowOpensAt, s.creditAt != 0 ? s.creditAt : s.open + SessionTiming.CREDIT_AFTER);
            assertEq(m.lenderWindowClosesAt, s.prepAt);
        } else if (s.session + 2 >= cal.sessionCount()) {
            // The next session is the last loaded one, which opens in wind-down: no window is projected.
            assertEq(m.lenderWindowOpensAt, 0, "no window in wind-down");
            assertEq(m.lenderWindowClosesAt, 0, "no window in wind-down");
        } else {
            (uint64 o, uint64 c) = cal.sessionAt(s.session + 1);
            assertEq(m.lenderWindowOpensAt, o + SessionTiming.CREDIT_AFTER, "next session opens");
            assertEq(m.lenderWindowClosesAt, c - SessionTiming.PREP, "next session A");
        }
    }

    // ---------------------------------------------------------------- account views

    /// @dev INV-LENS-05: activeAccountViews lists exactly the active accounts, in order, each in debt and equal to
    /// its own accountView, and each view passes `_checkAccountView`.
    function _checkAllAccountViews() internal view {
        address[] memory list = market.activeAccounts();
        StockReefLens.AccountView[] memory views = lens.activeAccountViews();
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 price = market.bookValuation().priceWad;
        assertEq(views.length, list.length, "one view per active account");
        assertLe(list.length, 32, "account cap");
        for (uint256 i; i < list.length; ++i) {
            assertEq(views[i].account, list[i], "order of activeAccounts");
            assertGt(views[i].debt, 0, "active accounts hold debt");
            assertEq(
                keccak256(abi.encode(views[i])), keccak256(abi.encode(lens.accountView(list[i]))), "same as accountView"
            );
            _checkAccountView(views[i], list[i], s, price);
        }
    }

    function _checkAccountView(
        StockReefLens.AccountView memory v,
        address account,
        SessionRiskPolicy.Snapshot memory s,
        uint256 price
    ) internal view {
        _checkPosition(v, account, s, price);
        assertEq(v.borrowCapacity, _expectedCapacity(account, s, v.debt, v.collateralValue), "borrowCapacity");
        if (v.borrowCapacity != 0) assertTrue(s.canBorrow, "capacity implies canBorrow");
        _checkPlan(v, s, price);
        _checkTrims(v, account, s, price);
        _checkReopening(v, account, s);
        _checkBuffer(v, account, s);
        _checkMissed(v, account, s);
    }

    /// @dev INV-LENS-04, INV-LENS-10: debt, value and LTV equal the market's.
    function _checkPosition(
        StockReefLens.AccountView memory v,
        address account,
        SessionRiskPolicy.Snapshot memory s,
        uint256 price
    ) internal view {
        assertEq(v.account, account, "account");
        assertEq(v.collateral, market.collateralOf(account), "collateral");
        assertEq(v.debt, market.debtOf(account), "debt");
        assertEq(v.valuationIndicative, s.reasons != 0, "account indicative");
        assertEq(v.collateralValue, price == 0 ? 0 : gate.valueOf(v.collateral, price), "collateralValue");
        uint256 ltv = v.debt == 0
            ? 0
            : v.collateralValue == 0 ? MAX : Math.mulDiv(v.debt, WAD, v.collateralValue, Math.Rounding.Ceil);
        assertEq(v.ltvWad, ltv, "ltvWad");
    }

    /// @dev INV-LENS-11: zero when a borrow guard fails, else min(B * V - debt - 1, cash, utilization room), and zero
    /// when that cannot lift the debt to the minimum loan.
    function _expectedCapacity(address account, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        internal
        view
        returns (uint256)
    {
        if (!s.canBorrow || escrow.blocksBorrowing(account, s)) return 0;
        if (debt == 0 && market.activeAccounts().length >= 32) return 0;
        StockReefMarket.Book memory b = market.bookValuation();
        if (b.impaired) return 0;
        uint256 limit = Math.mulDiv(s.borrowLimitWad, value, WAD);
        if (limit <= debt + 1) return 0;
        uint256 cash = market.cash();
        uint256 room = Math.mulDiv(0.9e18, cash + b.totalDebt, WAD);
        room = room > b.totalDebt ? room - b.totalDebt : 0;
        uint256 cap = Math.min(limit - debt - 1, Math.min(cash, room));
        return debt + cap < market.minLoan() ? 0 : cap;
    }

    /// @dev INV-LENS-15, INV-LENS-16: the target of the governing closure, and the least whole repayment and
    /// top-up that reach it.
    function _checkPlan(StockReefLens.AccountView memory v, SessionRiskPolicy.Snapshot memory s, uint256 price)
        internal
        view
    {
        uint256 t = policy.targetOf(s.closureClass);
        assertEq(v.planTargetWad, t, "planTargetWad");
        assertTrue(t == 0.65e18 || t == 0.72e18, "a closure target");
        if (v.debt * WAD <= t * v.collateralValue) {
            assertEq(v.repayToTarget, 0, "at or below target: repay");
            assertEq(v.addCollateralValueToTarget, 0, "at or below target: value");
            assertEq(v.addCollateralRawToTarget, 0, "at or below target: raw");
            return;
        }
        uint256 gap = v.debt * WAD - t * v.collateralValue;
        assertEq(v.repayToTarget, Math.ceilDiv(gap, WAD), "repayToTarget");
        assertLt((v.repayToTarget - 1) * WAD, gap, "repayToTarget is minimal");
        uint256 add = v.addCollateralValueToTarget;
        assertEq(add, Math.mulDiv(v.debt, WAD, t, Math.Rounding.Ceil) - v.collateralValue, "addCollateralValue");
        assertLe(v.debt * WAD, t * (v.collateralValue + add), "the value reaches the target");
        assertGt(v.debt * WAD, t * (v.collateralValue + add - 1), "the value is minimal");
        if (price == 0) {
            assertEq(v.addCollateralRawToTarget, 0, "no raw amount without a price");
            return;
        }
        uint256 raw = v.addCollateralRawToTarget;
        assertEq(raw, gate.rawForValue(add, price, Math.Rounding.Ceil), "addCollateralRaw");
        assertGe(gate.valueOf(raw, price), add, "raw amount is worth the value");
        if (raw != 0) assertLt(gate.valueOf(raw - 1, price), add, "raw amount is minimal");
    }

    /// @dev The snapshot at F for the coming close (appendix R1): FINAL_WINDOW with LT_F and the closure target,
    /// trims allowed, at the current time and the book price.
    function _finalSnapshot(SessionRiskPolicy.Snapshot memory s, uint256 price)
        internal
        view
        returns (SessionRiskPolicy.Snapshot memory f)
    {
        f.time = s.time < s.finalAt ? s.finalAt : s.time; // debt accrues to F
        f.state = SessionRiskPolicy.State.FINAL_WINDOW;
        f.phase = SessionRiskPolicy.State.FINAL_WINDOW;
        f.priceWad = price;
        f.canTrim = true;
        f.ltWad = policy.ltFinalOf(s.closureClass);
        f.targetWad = policy.targetOf(s.closureClass);
    }

    /// @dev INV-LENS-18, INV-LENS-20, INV-LENS-21.
    function _checkTrims(
        StockReefLens.AccountView memory v,
        address account,
        SessionRiskPolicy.Snapshot memory s,
        uint256 price
    ) internal view {
        StockReefMarket.TrimQuote memory q = market.quoteTrim(account, s, MAX);
        assertEq(keccak256(abi.encode(v.trimNow)), keccak256(abi.encode(q)), "trimNow is quoteTrim at the snapshot");
        if (v.trimNow.eligible) {
            assertTrue(s.canTrim, "eligible implies canTrim");
            assertGt(v.trimNow.debt * WAD, s.ltWad * v.trimNow.value, "eligible implies LTV above LT");
        }
        bool beforeClose = s.phase == SessionRiskPolicy.State.OPEN || s.phase == SessionRiskPolicy.State.PRE_CLOSE
            || s.phase == SessionRiskPolicy.State.FINAL_WINDOW;
        if (!beforeClose) {
            assertFalse(v.trimmableAtFinal, "no trimAtFinal after the close");
            assertEq(v.trimAtFinalRepay, 0, "no trimAtFinal repay");
            assertEq(v.trimAtFinalCollateral, 0, "no trimAtFinal collateral");
            assertEq(v.trimAtFinalBonusWad, 0, "no trimAtFinal bonus");
            return;
        }
        StockReefMarket.TrimQuote memory f = market.quoteTrim(account, _finalSnapshot(s, price), MAX);
        assertEq(v.trimmableAtFinal, f.eligible, "trimmableAtFinal");
        assertEq(v.trimAtFinalRepay, f.repaid, "trimAtFinalRepay");
        assertEq(v.trimAtFinalCollateral, f.collateralOut, "trimAtFinalCollateral");
        assertEq(v.trimAtFinalBonusWad, f.bonusWad, "trimAtFinalBonus");
        if (s.state == SessionRiskPolicy.State.FINAL_WINDOW) {
            assertEq(v.trimmableAtFinal, v.trimNow.eligible, "at F: eligible");
            assertEq(v.trimAtFinalRepay, v.trimNow.repaid, "at F: repaid");
            assertEq(v.trimAtFinalCollateral, v.trimNow.collateralOut, "at F: collateral");
            assertEq(v.trimAtFinalBonusWad, v.trimNow.bonusWad, "at F: bonus");
        }
        if (v.trimNow.eligible) assertTrue(v.trimmableAtFinal, "eligible now implies eligible at F");
    }

    /// @dev INV-LENS-20, INV-LENS-22: bufferExecutableNow is the escrow's amount at the snapshot; bufferCoverage is
    /// bounded like it by the debt, the balance and the allowance left in the snapshot's session, is zero without an
    /// active plan, and equals bufferExecutableNow whenever buffers can run.
    function _checkBuffer(StockReefLens.AccountView memory v, address account, SessionRiskPolicy.Snapshot memory s)
        internal
        view
    {
        RepaymentEscrow.Plan memory p = escrow.planOf(account);
        assertEq(keccak256(abi.encode(v.plan)), keccak256(abi.encode(p)), "plan");
        assertEq(v.bufferActive, p.targetWad != 0 && s.time < p.expiry, "bufferActive");
        assertEq(v.bufferCommitted, escrow.committed(account), "bufferCommitted");
        uint256 nowAmount = v.bufferExecutableNow;
        assertEq(nowAmount, escrow.executableAmount(account, s, v.debt, v.collateralValue), "bufferExecutableNow");
        uint256 spent = p.spentSession == uint32(s.session + 1) ? p.spent : 0;
        uint256 capLeft = p.perSessionCap > spent ? p.perSessionCap - spent : 0;
        assertLe(nowAmount, v.debt, "buffer within debt");
        assertLe(nowAmount, p.balance, "buffer within balance");
        assertLe(nowAmount, capLeft, "buffer within the cap left");
        if (nowAmount != 0) {
            assertTrue(s.canBuffer, "executable implies canBuffer");
            assertTrue(v.bufferActive, "executable implies active");
        }
        assertEq(v.trimNow.bufferPending, v.trimNow.eligible && nowAmount != 0, "bufferPending");
        if (s.canBuffer) assertEq(v.bufferCoverage, nowAmount, "coverage is the executable amount while buffers run");
        _checkCoverage(v, account, s, p);
    }

    /// @dev Coverage is sized at the next execution window, with the debt accrued to it and that session's
    /// allowance.
    function _checkCoverage(
        StockReefLens.AccountView memory v,
        address account,
        SessionRiskPolicy.Snapshot memory s,
        RepaymentEscrow.Plan memory p
    ) internal view {
        (bool exists, SessionRiskPolicy.Snapshot memory w) = _coverageWindow(s);
        if (!exists) {
            assertEq(v.bufferCoverage, 0, "no window left");
            return;
        }
        uint256 debtThen = market.debtAt(account, w.time);
        assertEq(v.bufferCoverage, escrow.executableAmount(account, w, debtThen, v.collateralValue), "coverage");
        uint256 spentThen = p.spentSession == uint32(w.session + 1) ? p.spent : 0;
        assertLe(v.bufferCoverage, debtThen, "coverage within the debt then");
        assertLe(v.bufferCoverage, p.balance, "coverage within balance");
        assertLe(v.bufferCoverage, p.perSessionCap > spentThen ? p.perSessionCap - spentThen : 0, "within that cap");
        if (p.targetWad == 0 || w.time >= p.expiry) assertEq(v.bufferCoverage, 0, "no coverage without a plan then");
    }

    /// @dev The next time buffers can execute (appendix R20): now in PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY;
    /// A in OPEN; the earliest admission in REOPEN_WAIT; the next session's earliest admission in CLOSED unless that
    /// session is wind-down; none outside coverage.
    function _coverageWindow(SessionRiskPolicy.Snapshot memory s)
        internal
        view
        returns (bool exists, SessionRiskPolicy.Snapshot memory w)
    {
        if (!s.covered) return (false, w);
        w.canBuffer = true;
        w.session = s.session;
        w.time = s.time;
        if (s.phase == SessionRiskPolicy.State.OPEN) {
            w.time = s.prepAt;
        } else if (s.phase == SessionRiskPolicy.State.REOPEN_WAIT) {
            uint64 admit = s.open + SessionTiming.ADMIT_AFTER;
            if (admit > s.time) w.time = admit;
        } else if (s.phase == SessionRiskPolicy.State.CLOSED) {
            if (s.session + 2 >= cal.sessionCount()) return (false, w);
            w.time = s.nextOpen + SessionTiming.ADMIT_AFTER;
            w.session = s.session + 1;
        }
        exists = true;
    }

    /// @dev The reopening projection: debt accrued to the next open (to now from O), judged at the closure's LT;
    /// nothing outside coverage or when the next open is wind-down.
    function _checkReopening(StockReefLens.AccountView memory v, address account, SessionRiskPolicy.Snapshot memory s)
        internal
        view
    {
        bool reopening =
            s.phase == SessionRiskPolicy.State.REOPEN_WAIT || s.phase == SessionRiskPolicy.State.REOPEN_RECOVERY;
        if (!s.covered || (!reopening && s.session + 2 >= cal.sessionCount())) {
            assertEq(v.projectedDebtAtReopen, 0, "no reopening");
            assertFalse(v.trimmableAtReopen, "no reopening");
            return;
        }
        uint256 d = market.debtAt(account, reopening ? s.time : s.nextOpen);
        assertEq(v.projectedDebtAtReopen, d, "debt at the reopening");
        assertGe(d, v.debt, "interest only adds");
        assertEq(v.trimmableAtReopen, d * WAD > policy.ltFinalOf(s.closureClass) * v.collateralValue, "trimmable then");
    }

    /// @dev INV-LENS-24: flagged iff CLOSED or REOPEN_WAIT, or wind-down, with the debt at the close that started
    /// the closure above the closure's LT (appendix R19); exposure is then repayToTarget.
    function _checkMissed(StockReefLens.AccountView memory v, address account, SessionRiskPolicy.Snapshot memory s)
        internal
        view
    {
        uint64 closeAt;
        if (s.windDown) {
            (, closeAt) = cal.sessionAt(cal.sessionCount() - 2);
        } else if (s.covered && s.phase == SessionRiskPolicy.State.CLOSED) {
            closeAt = s.close;
        } else if (s.covered && s.phase == SessionRiskPolicy.State.REOPEN_WAIT && s.session != 0) {
            (, closeAt) = cal.sessionAt(s.session - 1);
        }
        bool expected =
            closeAt != 0 && v.debt != 0 && market.debtAt(account, closeAt) * WAD > s.ltWad * v.collateralValue;
        assertEq(v.missedExecution, expected, "missedExecution");
        assertEq(v.exposure, v.missedExecution ? v.repayToTarget : 0, "exposure");
        if (v.missedExecution) assertGt(v.exposure, 0, "missed implies exposure");
    }
}

/// @notice The Lens against what the market and escrow then do, at the same block, after the keeper's refresh,
/// over arbitrary sessions of the calendar: OVERNIGHT and EXTENDED closures, early closes, the first minutes of
/// the next session, and every price-dependent phase.
contract LensDifferentialTest is LensPropertyChecks {
    uint256[] internal opens;
    uint256[] internal closes;

    function setUp() public {
        _setUpLens();
        (opens, closes) = _jsonSessions();
    }

    /// @dev A session after the market's deployment whose next session is still inside calendar coverage, with the
    /// early closes 61 (before a weekend), 80 (before a 92.5 h closure), 461 (44.5 h closure) and 460 weighted in.
    function _pickSession(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 8;
        if (k == 0) return 61;
        if (k == 1) return 80;
        if (k == 2) return 460;
        if (k == 3) return 461;
        return 8 + (seed >> 8) % 576;
    }

    /// @dev A time after credit in session `i`, from its A, in its closure, or in the first 25 minutes of the next
    /// session (before admission, in recovery or just after credit).
    function _pickTime(uint256 i, uint256 seed) internal view returns (uint256) {
        uint256 o = opens[i];
        uint256 c = closes[i];
        uint256 next = opens[i + 1];
        uint256 k = seed % 5;
        seed >>= 8;
        if (k == 0) return o + 15 minutes + seed % (c - o - 15 minutes);
        if (k == 1 || k == 2) return c - 120 minutes + seed % 120 minutes;
        if (k == 3) return c + seed % (next - c);
        return next + seed % 25 minutes;
    }

    /// @dev Admit session `i`, reach its OPEN phase and add lender cash.
    function _openSession(uint256 i, uint256 lendAmount) internal {
        _tick(opens[i] + 5 minutes);
        _tick(opens[i] + 15 minutes);
        _lend(lendAmount);
    }

    function _view(address who) internal view returns (StockReefLens.AccountView memory v) {
        v = lens.accountView(who);
        _checkAccountView(v, who, policy.snapshot(), market.bookValuation().priceWad);
    }

    /// INV-LENS-11, INV-LENS-12, INV-LENS-14: with the minimum loan satisfied, borrow(borrowCapacity) succeeds and
    /// pays out exactly that amount; borrow(borrowCapacity + 2) always reverts, in every phase and with or without
    /// an escrow authorization, existing debt or binding cash and utilization limits.
    function testFuzz_borrowCapacityIsSoundAndTight(
        uint256 sSeed,
        uint256 collSeed,
        uint256 debtSeed,
        uint256 lendSeed,
        uint256 tSeed,
        uint256 pSeed
    ) public {
        uint256 i = _pickSession(sSeed);
        _openSession(i, bound(lendSeed, 20_000, 1_000_000) * USDG);
        _fundCollateral(bob, bound(collSeed, 0.02e18, 500e18));
        uint256 cap0 = lens.accountView(bob).borrowCapacity;
        if (debtSeed % 3 != 0 && cap0 >= MIN_LOAN) _borrow(bob, bound(debtSeed, MIN_LOAN, cap0));
        if (lendSeed % 3 == 0) _authorize(bob, 0.65e18, 1_000 * USDG, 1_000 * USDG, uint64(closes[i] + 1 days));
        answer = int256(bound(pSeed, 250e8, 550e8));
        _tick(_pickTime(i, tSeed));

        StockReefLens.AccountView memory v = _view(bob);
        if (v.borrowCapacity != 0 && v.debt + v.borrowCapacity >= MIN_LOAN) {
            uint256 snap = vm.snapshotState();
            uint256 before = usdg.balanceOf(bob);
            vm.prank(bob);
            market.borrow(v.borrowCapacity, bob);
            assertEq(usdg.balanceOf(bob) - before, v.borrowCapacity, "paid out the capacity");
            vm.revertToState(snap);
        }
        vm.prank(bob);
        try market.borrow(v.borrowCapacity + 2, bob) {
            assertTrue(false, "borrowed more than the capacity plus one unit");
        } catch {}
    }

    /// INV-LENS-18, INV-LENS-20, INV-LENS-21, INV-LENS-14: trim() succeeds iff trimNow is eligible, no buffer is
    /// pending and both amounts are positive, and then moves exactly trimNow's repayment and collateral.
    function testFuzz_trimNowMatchesTrim(
        uint256 sSeed,
        uint256 collSeed,
        uint256 borrowSeed,
        uint256 ltvSeed,
        uint256 tSeed,
        uint256 planSeed
    ) public {
        uint256 i = _pickSession(sSeed);
        _openSession(i, 1_000_000 * USDG);
        uint256 coll = bound(collSeed, 0.02e18, 1_000e18);
        _fundCollateral(bob, coll);
        uint256 cap = lens.accountView(bob).borrowCapacity;
        vm.assume(cap >= MIN_LOAN);
        _borrow(bob, bound(borrowSeed, MIN_LOAN, cap));
        if (planSeed % 2 == 0) {
            _authorize(
                bob,
                0.65e18,
                bound(planSeed >> 8, 1, 20_000 * USDG),
                bound(planSeed >> 128, 1, 20_000 * USDG),
                uint64(closes[i] + 1 days)
            );
        }
        // A price that puts the position between 55% and 130% LTV at its current debt.
        uint256 value = market.debtOf(bob) * WAD / bound(ltvSeed, 0.55e18, 1.3e18);
        answer = int256(bound(value * 1e30 / coll / 1e10, 1, ANSWER_BOUND));
        _tick(_pickTime(i, tSeed));

        StockReefLens.AccountView memory v = _view(bob);
        StockReefMarket.TrimQuote memory q = v.trimNow;
        bool trimmable = q.eligible && !q.bufferPending && q.repaid != 0 && q.collateralOut != 0;
        uint256 usdgBefore = usdg.balanceOf(liquidator);
        uint256 tslaBefore = tsla.balanceOf(liquidator);
        vm.prank(liquidator);
        try market.trim(bob, MAX, 0, block.timestamp) returns (uint256 repaid, uint256 out) {
            assertTrue(trimmable, "trim executed although the Lens quoted none");
            assertEq(repaid, q.repaid, "repaid");
            assertEq(out, q.collateralOut, "collateral out");
            assertEq(usdgBefore - usdg.balanceOf(liquidator), repaid, "liquidator paid");
            assertEq(tsla.balanceOf(liquidator) - tslaBefore, out, "liquidator received");
        } catch {
            assertFalse(trimmable, "the Lens quoted a trim that reverted");
        }
    }

    /// INV-LENS-22, INV-LENS-20: executeBuffer() repays exactly bufferExecutableNow and reverts when it is zero,
    /// including a second execution later in the same session against the allowance left.
    function testFuzz_bufferExecutableNowMatchesExecuteBuffer(
        uint256 sSeed,
        uint256 collSeed,
        uint256 borrowSeed,
        uint256 planSeed,
        uint256 tSeed,
        uint256 pSeed
    ) public {
        uint256 i = _pickSession(sSeed);
        _openSession(i, 1_000_000 * USDG);
        _fundCollateral(bob, bound(collSeed, 0.02e18, 100e18));
        uint256 cap = lens.accountView(bob).borrowCapacity;
        vm.assume(cap >= MIN_LOAN);
        _borrow(bob, bound(borrowSeed, MIN_LOAN, cap));
        uint64 expiry = planSeed % 4 == 0
            ? uint64(block.timestamp + 1 + (planSeed >> 2) % (closes[i] - block.timestamp))
            : uint64(closes[i] + 1 days);
        _authorize(
            bob,
            bound(planSeed >> 8, 0.3e18, 0.65e18),
            bound(planSeed >> 72, 1, 50_000 * USDG),
            bound(planSeed >> 136, 1, 50_000 * USDG),
            expiry
        );
        answer = int256(bound(pSeed, 300e8, 450e8));
        uint256 t = tSeed % 3 == 0 ? _pickTime(i, tSeed >> 2) : closes[i] - 120 minutes + (tSeed >> 2) % 120 minutes;
        _tick(t);

        bool executed = _executeAndCompare(bob);
        if (executed && block.timestamp + 1 minutes < closes[i]) {
            _tick(block.timestamp + 1 minutes);
            _executeAndCompare(bob);
        }
    }

    function _executeAndCompare(address who) internal returns (bool) {
        StockReefLens.AccountView memory v = _view(who);
        if (v.bufferExecutableNow == 0) {
            vm.expectRevert();
            escrow.executeBuffer(who);
            return false;
        }
        uint256 held = usdg.balanceOf(address(escrow));
        uint256 repaid = escrow.executeBuffer(who);
        assertEq(repaid, v.bufferExecutableNow, "executeBuffer repays the Lens amount");
        assertEq(held - usdg.balanceOf(address(escrow)), repaid, "escrow paid it");
        assertEq(escrow.planOf(who).balance, v.plan.balance - repaid, "plan balance");
        uint256 d = market.debtOf(who);
        assertTrue(d == 0 || d >= MIN_LOAN, "no dust left");
        return true;
    }

    /// INV-LENS-15, INV-LENS-16: repaying repayToTarget leaves the account within one unit of the plan target
    /// (when it leaves no dust below the minimum loan), depositing addCollateralRawToTarget reaches it, and an
    /// escrow plan at the same target with ample funds needs exactly repayToTarget.
    function testFuzz_closurePlanReachesTheTarget(
        uint256 sSeed,
        uint256 collSeed,
        uint256 borrowSeed,
        uint256 pSeed,
        uint256 tSeed,
        uint256 how
    ) public {
        uint256 i = _pickSession(sSeed);
        _openSession(i, 1_000_000 * USDG);
        _fundCollateral(bob, bound(collSeed, 0.02e18, 500e18));
        uint256 cap = lens.accountView(bob).borrowCapacity;
        vm.assume(cap >= MIN_LOAN);
        _borrow(bob, bound(borrowSeed, MIN_LOAN, cap));
        answer = int256(bound(pSeed, 200e8, 600e8));
        _tick(_pickTime(i, tSeed));

        StockReefLens.AccountView memory v = _view(bob);
        if (v.repayToTarget == 0) return;
        bool noDust = v.debt == v.repayToTarget || v.debt - v.repayToTarget >= MIN_LOAN;
        StockReefLens.AccountView memory a;
        if (how % 3 == 0) {
            if (v.planTargetWad > escrow.MAX_TARGET()) return;
            _authorize(bob, v.planTargetWad, 10_000_000 * USDG, 10_000_000 * USDG, uint64(block.timestamp + 10 days));
            a = _view(bob);
            if (noDust) {
                // Coverage is sized at the next execution window: exactly repayToTarget while buffers run now,
                // otherwise at least it, since interest to that window only adds.
                if (policy.snapshot().canBuffer) {
                    assertEq(a.bufferCoverage, a.repayToTarget, "the escrow needs exactly repayToTarget");
                } else if (a.bufferCoverage != 0) {
                    assertGe(a.bufferCoverage, a.repayToTarget, "interest to the next window only adds");
                }
            }
        } else if (how % 3 == 1) {
            if (!noDust) return; // INV-LENS-17: such a repayment reverts BelowMinimumLoan
            _repay(bob, v.repayToTarget);
            a = _view(bob);
            assertLe(a.repayToTarget, 1, "within one unit of the target");
            assertLe(a.debt * WAD, a.planTargetWad * a.collateralValue + WAD, "debt within one unit");
        } else {
            _fundCollateral(bob, v.addCollateralRawToTarget);
            a = _view(bob);
            assertEq(a.repayToTarget, 0, "at the target after the top-up");
            assertLe(a.debt * WAD, a.planTargetWad * a.collateralValue, "LTV at or below the target");
        }
    }
}

/// @notice Six borrowers (one with a funded buffer, one whose repayment moved the active list), viewed at any
/// time of the week from Friday 2026-09-11 to the following Friday's close, or in wind-down, with fresh,
/// unrecorded, out-of-bound, stale, stopped, issuer-paused and multiplier-lagged prices.
contract LensWeekTest is LensPropertyChecks {
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank"); // spare capacity whenever borrowing is open

    function setUp() public {
        _setUpLens();
        _openFriday();
        _lend(200_000 * USDG);
        _fundCollateral(erin, 10 * TOKEN);
        _borrow(erin, 2_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 6_000 * USDG);
        _workedExample(carol);
        _workedExample(alice);
        _authorize(alice, 0.65e18, 1_000 * USDG, 500 * USDG, uint64(FRI_OPEN + 8 days));
        _fundCollateral(dave, TOKEN);
        _borrow(dave, 290 * USDG);
        _repay(erin, market.debtOf(erin)); // dave moves into erin's slot
        _fundCollateral(frank, 100 * TOKEN);
        _borrow(frank, 1_000 * USDG);
        address[] memory list = market.activeAccounts();
        assertEq(list.length, 5);
        assertEq(list[0], dave);
    }

    /// INV-LENS-26, INV-LENS-02, INV-LENS-03, INV-LENS-04, INV-LENS-05, INV-LENS-06, INV-LENS-08, INV-LENS-09,
    /// INV-LENS-10, INV-LENS-14, INV-LENS-15, INV-LENS-16, INV-LENS-20, INV-LENS-21, INV-LENS-24: the three views
    /// never revert and every field equals its source.
    function testFuzz_viewsHoldAcrossAWeek(uint256 tSeed, int256 aSeed, uint256 mode) public {
        uint256 t = mode % 16 == 0
            ? bound(tSeed, cal.lastOpen() - 1 days, uint256(cal.lastClose()) + 30 days)
            : bound(tSeed, FRI_OPEN + 15 minutes, FRI_OPEN + 7 days + 7 hours);
        vm.warp(t);
        uint256 source = (mode >> 4) % 4;
        if (source == 0) {
            stockFeed.push(int256(bound(aSeed, 1e8, 2_000e8)));
            gate.refresh();
        } else if (source == 1) {
            stockFeed.push(int256(bound(aSeed, 1e8, 2_000e8)));
        } else if (source == 2) {
            stockFeed.push(int256(bound(aSeed, -1e9, 2e14)));
            if ((mode >> 6) % 2 == 0) gate.refresh();
        }
        if ((mode >> 8) % 5 == 0) {
            vm.prank(guardian);
            gate.stop();
        }
        if ((mode >> 12) % 7 == 0) tsla.setOraclePaused(true);
        if ((mode >> 16) % 6 == 0) tsla.scheduleMultiplier(2e18, t + ((mode >> 20) % 3) * 1 hours);

        _checkMarketView();
        _checkAllAccountViews();
        address nobody = makeAddr("nobody");
        StockReefLens.AccountView memory x = lens.accountView(nobody);
        _checkAccountView(x, nobody, policy.snapshot(), market.bookValuation().priceWad);
        assertEq(x.debt, 0);
        assertEq(x.ltvWad, 0);
        assertEq(x.borrowCapacity, 0);
        assertEq(x.repayToTarget, 0);
        assertFalse(x.missedExecution);
    }

    /// INV-LENS-06, INV-LENS-08: across the last three loaded sessions, their closures and wind-down, both window
    /// fields match their sources; half the runs fall between the second-to-last session's A and the last open,
    /// where the snapshot is still covered and the Lens projects no window, because the next session is wind-down.
    function testFuzz_lenderWindowAcrossTheEndOfCoverage(uint256 tSeed) public {
        uint256 n = cal.sessionCount();
        (uint64 first,) = cal.sessionAt(n - 3);
        (, uint64 close) = cal.sessionAt(n - 2);
        uint256 t = tSeed % 2 == 0
            ? bound(tSeed >> 1, close - SessionTiming.PREP, cal.lastOpen() - 1)
            : bound(tSeed >> 1, first, uint256(cal.lastClose()) + 1 days);
        _tick(t);
        StockReefLens.MarketView memory m = _checkMarketView();
        if (t >= close - SessionTiming.PREP && t < cal.lastOpen()) {
            assertTrue(m.policy.covered, "covered until the last open");
            assertEq(m.policy.session, n - 2);
            assertEq(m.lenderWindowOpensAt, 0, "no window: the next session is wind-down");
            assertEq(m.lenderWindowClosesAt, 0, "no window: the next session is wind-down");
        }
        _checkAllAccountViews();
    }
}

/// @notice Borrowers, a keeper, a liquidator and a lender acting across real sessions and price moves. Before
/// every action the keeper publishes and refreshes at the current time; the action then compares what it does
/// with what the Lens reported at that block.
contract LensHandler is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;
    uint256 internal constant MIN_LOAN = 5e6;

    StockReefLens internal lens;
    StockReefMarket internal market;
    RepaymentEscrow internal escrow;
    PriceGate internal gate;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    MockUSDG internal usdg;
    address internal owner; // the fixture: issuer of the mocks and publisher of the feed
    address internal lender = address(0xA11CE);
    address internal liquidator = address(0x11D);

    address[4] public actors;
    int256 public answer = 400e8;
    uint256 public calls;

    // Successful actions.
    uint256 public okBorrow;
    uint256 public okRepay;
    uint256 public okTopUp;
    uint256 public okTrim;
    uint256 public okBuffer;
    uint256 public okLend;
    uint256 public sessionsCrossed;

    // Disagreements between the Lens and execution; all must stay zero.
    uint256 public capacityRefused; // a borrow within capacity, reaching the minimum loan, reverted
    uint256 public capacityExceeded; // a borrow of capacity + 2 succeeded
    uint256 public trimMismatches; // trim() did not do what trimNow quoted
    uint256 public bufferMismatches; // executeBuffer() did not repay bufferExecutableNow
    uint256 public planMisses; // repayToTarget or addCollateralRawToTarget did not reach the plan target

    constructor(StockReefLens lens_, MockAggregatorV3 feed_, MockStockToken tsla_, MockUSDG usdg_, address owner_) {
        lens = lens_;
        market = lens_.market();
        escrow = lens_.escrow();
        gate = lens_.gate();
        feed = feed_;
        tsla = tsla_;
        usdg = usdg_;
        owner = owner_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xB000 + i));
            vm.startPrank(actors[i]);
            usdg.approve(address(market), type(uint256).max);
            usdg.approve(address(escrow), type(uint256).max);
            tsla.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    // ---------------------------------------------------------------- time and price

    function tick(uint256 dt, int256 moveBps) external {
        calls++;
        // Mostly short steps; one in six crosses into the next session, anywhere from just before its open to
        // late in the day, with a larger gap move.
        if (dt % 6 == 0) {
            SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
            if (!c.covered) return;
            vm.warp(c.nextOpen - 10 minutes + (dt % 7 hours));
            sessionsCrossed++;
            moveBps = bound(moveBps, -3_500, 2_000);
        } else {
            vm.warp(block.timestamp + bound(dt, 1 minutes, 90 minutes));
            moveBps = bound(moveBps, -800, 800);
        }
        _publish(moveBps);
    }

    /// @dev Time passes before each action: 1 to 15 minutes, with a move of up to 2% either way; three closures in
    /// four are skipped to just around the next open. The keeper then publishes and refreshes.
    function _flow(uint256 r) internal {
        calls++;
        vm.warp(block.timestamp + 1 minutes + (r % 15 minutes));
        SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
        if (c.covered && !c.inSession && (r >> 40) % 4 != 0) {
            vm.warp(c.nextOpen - 2 minutes + ((r >> 48) % 30 minutes));
            sessionsCrossed++;
        }
        _publish(int256((r >> 16) % 401) - 200);
    }

    function _publish(int256 moveBps) internal {
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
    }

    // ---------------------------------------------------------------- borrowers

    /// @dev Borrow a quarter to all of the Lens capacity; capacity + 2 must be refused first.
    function borrow(uint256 seed, uint256 frac) external {
        _flow(uint256(keccak256(abi.encode(seed, frac, calls))));
        address a = _actor(seed);
        StockReefLens.AccountView memory v = lens.accountView(a);
        vm.prank(a);
        try market.borrow(v.borrowCapacity + 2, a) {
            capacityExceeded++;
            return;
        } catch {}
        uint256 amount = v.borrowCapacity * (frac % 4 + 1) / 4;
        if (v.debt + amount < MIN_LOAN) amount = v.borrowCapacity;
        if (amount == 0 || v.debt + amount < MIN_LOAN) return;
        vm.prank(a);
        try market.borrow(amount, a) {
            okBorrow++;
        } catch {
            capacityRefused++;
        }
    }

    /// @dev Repay exactly repayToTarget, unless that would leave dust below the minimum loan (INV-LENS-17).
    function repayToTarget(uint256 seed) external {
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        StockReefLens.AccountView memory v = lens.accountView(a);
        uint256 r = v.repayToTarget;
        if (r == 0 || (v.debt != r && v.debt - r < MIN_LOAN)) return;
        _mintUsdg(a, r);
        vm.prank(a);
        try market.repay(r, a) {
            okRepay++;
            if (lens.accountView(a).repayToTarget > 1) planMisses++;
        } catch {
            planMisses++;
        }
    }

    /// @dev Deposit exactly addCollateralRawToTarget.
    function topUpToTarget(uint256 seed) external {
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        uint256 raw = lens.accountView(a).addCollateralRawToTarget;
        if (raw == 0 || raw > 1_000 * TOKEN) return;
        _mintTsla(a, raw);
        vm.prank(a);
        market.depositCollateral(raw, a);
        okTopUp++;
        if (lens.accountView(a).repayToTarget != 0) planMisses++;
    }

    function addCollateral(uint256 seed, uint256 amount) external {
        _flow(uint256(keccak256(abi.encode(seed, amount, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 30 * TOKEN);
        _mintTsla(a, amount);
        vm.prank(a);
        market.depositCollateral(amount, a);
    }

    function fundBuffer(uint256 seed, uint256 amount, uint256 targetBps) external {
        _flow(uint256(keccak256(abi.encode(seed, amount, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 5_000 * USDG);
        _mintUsdg(a, amount);
        vm.startPrank(a);
        escrow.deposit(amount, a);
        try escrow.authorize(bound(targetBps, 5_000, 6_500) * 1e14, 2_000 * USDG, uint64(block.timestamp + 10 days)) {}
            catch {}
        vm.stopPrank();
    }

    function lend(uint256 amount) external {
        _flow(uint256(keccak256(abi.encode(amount, calls))));
        amount = bound(amount, 1 * USDG, 50_000 * USDG);
        _mintUsdg(lender, amount);
        vm.prank(lender);
        try market.deposit(amount, lender) {
            okLend++;
        } catch {}
    }

    // ---------------------------------------------------------------- keeper and liquidator

    function executeBuffer(uint256 seed) external {
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        // Prefer an account with an executable buffer, so executions run as often as they exist.
        address a = _actor(seed);
        for (uint256 k; k < 4; ++k) {
            if (lens.accountView(actors[k]).bufferExecutableNow != 0) {
                a = actors[k];
                break;
            }
        }
        uint256 expected = lens.accountView(a).bufferExecutableNow;
        try escrow.executeBuffer(a) returns (uint256 repaid) {
            okBuffer++;
            if (repaid != expected) bufferMismatches++;
        } catch {
            if (expected != 0) bufferMismatches++;
        }
    }

    function trim(uint256 seed) external {
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        // Prefer an account the Lens shows as eligible, so trims run as often as they exist.
        address a = _actor(seed);
        for (uint256 k; k < 4; ++k) {
            if (lens.accountView(actors[k]).trimNow.eligible) {
                a = actors[k];
                break;
            }
        }
        StockReefMarket.TrimQuote memory q = lens.accountView(a).trimNow;
        bool trimmable = q.eligible && !q.bufferPending && q.repaid != 0 && q.collateralOut != 0;
        _mintUsdg(liquidator, q.repaid);
        vm.prank(liquidator);
        try market.trim(a, type(uint256).max, 0, block.timestamp) returns (uint256 repaid, uint256 out) {
            okTrim++;
            if (!trimmable || repaid != q.repaid || out != q.collateralOut) trimMismatches++;
        } catch {
            if (trimmable) trimMismatches++;
        }
    }

    function _mintUsdg(address to, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(owner);
        usdg.mint(to, amount);
    }

    function _mintTsla(address to, uint256 amount) internal {
        vm.prank(owner);
        tsla.mint(to, amount);
    }
}

contract LensInvariantsTest is LensPropertyChecks {
    LensHandler internal handler;

    function setUp() public {
        _setUpLens();
        _openFriday();
        handler = new LensHandler(lens, stockFeed, tsla, usdg, address(this));
        // Seed: lender liquidity and four collateralized borrowers, two of them in debt.
        _lend(300_000 * USDG);
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            tsla.mint(a, 50 * TOKEN);
            vm.prank(a);
            market.depositCollateral(50 * TOKEN, a);
            if (i < 2) {
                vm.prank(a);
                market.borrow(14_000 * USDG, a);
            }
        }
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = LensHandler.tick.selector;
        actions[1] = LensHandler.borrow.selector;
        actions[2] = LensHandler.repayToTarget.selector;
        actions[3] = LensHandler.topUpToTarget.selector;
        actions[4] = LensHandler.addCollateral.selector;
        actions[5] = LensHandler.fundBuffer.selector;
        actions[6] = LensHandler.lend.selector;
        actions[7] = LensHandler.executeBuffer.selector;
        actions[8] = LensHandler.trim.selector;
        actions[9] = LensHandler.trim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("calls", handler.calls(), "sessions crossed", handler.sessionsCrossed());
        console.log("borrow", handler.okBorrow(), "repay", handler.okRepay());
        console.log("topUp", handler.okTopUp(), "lend", handler.okLend());
        console.log("trim", handler.okTrim(), "buffer", handler.okBuffer());
    }

    /// INV-LENS-11, INV-LENS-12, INV-LENS-16, INV-LENS-18, INV-LENS-22: along random histories, every borrow,
    /// repayment, top-up, trim and buffer execution does what the Lens reported at that block.
    /// forge-config: default.invariant.runs = 20
    /// forge-config: default.invariant.depth = 100
    function invariant_lensQuotesMatchExecution() public view {
        assertEq(handler.capacityRefused(), 0, "borrow within capacity refused");
        assertEq(handler.capacityExceeded(), 0, "borrow above capacity + 1 accepted");
        assertEq(handler.trimMismatches(), 0, "trim differs from trimNow");
        assertEq(handler.bufferMismatches(), 0, "executeBuffer differs from bufferExecutableNow");
        assertEq(handler.planMisses(), 0, "closure plan missed its target");
    }

    /// INV-LENS-02, INV-LENS-03, INV-LENS-04, INV-LENS-05, INV-LENS-06, INV-LENS-09, INV-LENS-10, INV-LENS-11,
    /// INV-LENS-14, INV-LENS-15, INV-LENS-16, INV-LENS-20, INV-LENS-21, INV-LENS-22, INV-LENS-24, INV-LENS-26:
    /// after every action the views do not revert and every field equals its source.
    /// forge-config: default.invariant.runs = 20
    /// forge-config: default.invariant.depth = 100
    function invariant_lensViewsMatchTheirSources() public view {
        _checkMarketView();
        _checkAllAccountViews();
    }
}
