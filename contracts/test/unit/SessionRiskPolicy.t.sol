// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

contract SessionRiskPolicyTest is GateFixture {
    // Friday 2026-09-11 session (weekend follows), the day before Thanksgiving, and the early close after it.
    uint64 internal constant FRI_OPEN = 1789133400;
    uint64 internal constant WED_BEFORE_HOLIDAY_CLOSE = 1795640400;
    uint64 internal constant BLACK_FRIDAY_OPEN = 1795789800;
    uint64 internal constant BLACK_FRIDAY_CLOSE = 1795802400; // 13:00 New York

    // Calendar facts from tools/calendar/sessions.json, UTC seconds.
    uint64 internal constant THU_CLOSE = 1789070400; // Thursday 2026-09-10, 16:00 New York
    uint64 internal constant LABOR_DAY_FRI_CLOSE = 1788552000; // Friday 2026-09-04; Monday 09-07 is a holiday
    uint64 internal constant LABOR_DAY_TUE_OPEN = 1788874200; // 89.5 h later
    uint64 internal constant BLACK_FRIDAY_NEXT_OPEN = 1796049000; // Monday 2026-11-30, 68.5 h after 13:00
    uint64 internal constant XMAS_EVE_OPEN = 1798122600; // Thursday 2026-12-24, closes 13:00 New York
    uint64 internal constant XMAS_EVE_CLOSE = 1798135200;
    uint64 internal constant XMAS_NEXT_OPEN = 1798468200; // Monday 2026-12-28, 92.5 h later
    uint64 internal constant JULY3_OPEN = 1846243800; // Monday 2028-07-03, closes 13:00 New York
    uint64 internal constant JULY3_CLOSE = 1846256400;
    uint64 internal constant JULY5_OPEN = 1846416600; // Wednesday 2028-07-05, 44.5 h later
    uint64 internal constant FALL_BACK_FRI_CLOSE = 1793390400; // Friday 2026-10-30; New York leaves DST on Sunday
    uint64 internal constant FALL_BACK_MON_OPEN = 1793629800; // 66.5 h later
    uint64 internal constant SPRING_FWD_FRI_CLOSE = 1804885200; // Friday 2027-03-12; New York enters DST on Sunday
    uint64 internal constant SPRING_FWD_MON_OPEN = 1805117400; // 64.5 h later

    SessionRiskPolicy.State internal constant S_OPEN = SessionRiskPolicy.State.OPEN;
    SessionRiskPolicy.State internal constant S_PRE = SessionRiskPolicy.State.PRE_CLOSE;
    SessionRiskPolicy.State internal constant S_FINAL = SessionRiskPolicy.State.FINAL_WINDOW;
    SessionRiskPolicy.State internal constant S_CLOSED = SessionRiskPolicy.State.CLOSED;
    SessionRiskPolicy.State internal constant S_WAIT = SessionRiskPolicy.State.REOPEN_WAIT;
    SessionRiskPolicy.State internal constant S_RECOVERY = SessionRiskPolicy.State.REOPEN_RECOVERY;
    SessionRiskPolicy.State internal constant S_GUARDED = SessionRiskPolicy.State.GUARDED;
    SessionRiskPolicy.ClosureClass internal constant K_OVERNIGHT = SessionRiskPolicy.ClosureClass.OVERNIGHT;
    SessionRiskPolicy.ClosureClass internal constant K_EXTENDED = SessionRiskPolicy.ClosureClass.EXTENDED;

    SessionRiskPolicy internal policy;

    function setUp() public {
        _setUpGate();
        policy = new SessionRiskPolicy(gate);
    }

    function _snap() internal view returns (SessionRiskPolicy.Snapshot memory) {
        return policy.snapshot();
    }

    /// @dev Keep a fresh price at `t` and refresh the gate, as the keeper does.
    function _at(uint256 t) internal returns (SessionRiskPolicy.Snapshot memory) {
        _freshRefresh(t);
        return _snap();
    }

    function _context(uint64 t) internal view returns (bool, bool, uint256, uint64, uint64, uint64, uint64) {
        SessionCalendar.Context memory c = cal.context(t);
        return (c.covered, c.inSession, c.index, c.open, c.close, c.prevClose, c.nextOpen);
    }

    function _assertState(SessionRiskPolicy.Snapshot memory s, SessionRiskPolicy.State expected) internal pure {
        assertEq(uint256(s.state), uint256(expected), "state");
    }

    // ------------------------------------------------------------ golden ramp

    function test_ramp_matchesIndependentGoldenValues() public view {
        string[5] memory points = ["A", "midpoint", "C-45m", "F", "C-1s"];
        string[2] memory classes = ["OVERNIGHT", "EXTENDED"];
        uint64 close = MON_CLOSE;
        for (uint256 c; c < 2; ++c) {
            SessionRiskPolicy.ClosureClass cls = SessionRiskPolicy.ClosureClass(c);
            string memory base = string.concat(".ramp.", classes[c]);
            assertEq(policy.ltFinalOf(cls), _golden(string.concat(base, ".lt_final_wad")));
            assertEq(policy.targetOf(cls), _golden(string.concat(base, ".target_wad")));
            for (uint256 p; p < points.length; ++p) {
                string memory key = string.concat(base, ".points.", points[p]);
                int256 offset = vm.parseJsonInt(_goldenJson(), string.concat(key, ".offset_s"));
                uint64 t = uint64(uint256(int256(uint256(close)) + offset));
                uint256 lt = policy.ltAt(cls, t, close);
                assertEq(lt, _golden(string.concat(key, ".lt_wad")), string.concat("lt ", key));
                assertEq(policy.borrowLimit(lt), _golden(string.concat(key, ".b_wad")), string.concat("b ", key));
            }
        }
    }

    function test_ramp_workedExampleIsEligibleAt1515NotAtEquality() public {
        // Friday 16:00 New York close (EXTENDED). At 15:15 LT is 71.67%, so a 72% loan is eligible.
        _at(FRI_OPEN + 6 minutes);
        SessionRiskPolicy.Snapshot memory s = _at(FRI_CLOSE - 45 minutes);
        _assertState(s, SessionRiskPolicy.State.PRE_CLOSE);
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));
        assertEq(s.ltWad, _golden(".worked_example.lt_at_1515_wad"));
        uint256 ltv = 0.72e18;
        assertTrue(policy.trimEligible(s, ltv));
        assertEq(policy.bonusFor(s, ltv), _golden(".worked_example.bonus_wad"));
        assertEq(s.targetWad, _golden(".worked_example.target_wad"));
        assertFalse(policy.trimEligible(s, s.ltWad), "equality is not eligible");
    }

    // ------------------------------------------------------------ one session, start to finish

    function test_timeline_weekendReopeningThroughOvernightClose() public {
        // Sunday: closed after the weekend close, EXTENDED limits, nothing price-dependent.
        SessionRiskPolicy.Snapshot memory s = _at(MON_OPEN - 10 hours);
        _assertState(s, SessionRiskPolicy.State.CLOSED);
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));
        assertEq(s.ltWad, 0.7e18);
        _assertNoActions(s);

        // O + 1 min: waiting for a reopening price.
        s = _at(MON_OPEN + 1 minutes);
        _assertState(s, SessionRiskPolicy.State.REOPEN_WAIT);
        assertEq(s.ltWad, 0.7e18);
        assertEq(s.guardAt, MON_OPEN + 30 minutes);
        _assertNoActions(s);

        // O + 5 min: admitted; recovery liquidations at 5%, no new credit.
        s = _at(MON_OPEN + 5 minutes);
        _assertState(s, SessionRiskPolicy.State.REOPEN_RECOVERY);
        assertEq(s.admissionAt, MON_OPEN + 5 minutes);
        assertEq(s.creditAt, MON_OPEN + 15 minutes);
        assertEq(s.targetWad, 0.65e18);
        assertTrue(s.canTrim);
        assertFalse(s.canBorrow);
        assertFalse(s.lenderOpen);
        assertEq(policy.bonusFor(s, 0.71e18), 0.05e18);

        // O + 15 min: OPEN.
        s = _at(MON_OPEN + 15 minutes);
        _assertState(s, SessionRiskPolicy.State.OPEN);
        assertEq(s.ltWad, 0.8e18);
        assertEq(s.borrowLimitWad, 0.75e18);
        assertEq(s.targetWad, 0.75e18);
        assertTrue(s.canBorrow && s.lenderOpen && s.canTrim);
        assertFalse(s.canBuffer);
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.OVERNIGHT), "Tuesday follows");

        // A: preparation for an ordinary weeknight.
        s = _at(MON_CLOSE - 120 minutes);
        _assertState(s, SessionRiskPolicy.State.PRE_CLOSE);
        assertEq(s.prepAt, MON_CLOSE - 120 minutes);
        assertEq(s.ltWad, 0.8e18);
        assertEq(s.borrowLimitWad, 0.75e18);
        assertTrue(s.canBuffer && s.canBorrow && s.canTrim);
        assertFalse(s.lenderOpen, "lender windows close at A");

        s = _at(MON_CLOSE - 45 minutes);
        assertEq(s.ltWad, 0.775e18);
        assertEq(s.borrowLimitWad, 0.725e18);
        assertEq(s.targetWad, 0.72e18);

        // F: final window, borrowing off, trims and buffers on.
        s = _at(MON_CLOSE - 30 minutes);
        _assertState(s, SessionRiskPolicy.State.FINAL_WINDOW);
        assertEq(s.ltWad, 0.77e18);
        assertEq(s.borrowLimitWad, 0);
        assertFalse(s.canBorrow);
        assertTrue(s.canTrim && s.canBuffer);

        s = _at(MON_CLOSE - 1);
        _assertState(s, SessionRiskPolicy.State.FINAL_WINDOW);

        // C: closed; the overnight limits hold until Tuesday's reopening.
        s = _at(MON_CLOSE);
        _assertState(s, SessionRiskPolicy.State.CLOSED);
        assertEq(s.ltWad, 0.77e18);
        _assertNoActions(s);

        s = _at(TUE_OPEN + 1 minutes);
        _assertState(s, SessionRiskPolicy.State.REOPEN_WAIT);
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.OVERNIGHT));
        assertEq(s.ltWad, 0.77e18);
        assertEq(s.targetWad, 0.72e18);
    }

    function _assertNoActions(SessionRiskPolicy.Snapshot memory s) internal pure {
        assertFalse(s.canBorrow, "borrow");
        assertFalse(s.canTrim, "trim");
        assertFalse(s.canBuffer, "buffer");
        assertFalse(s.lenderOpen, "lender");
        assertEq(s.borrowLimitWad, 0, "B");
    }

    // ------------------------------------------------------------ reopening timing

    function test_reopen_lateAdmissionStillGetsTenMinutesOfRecovery() public {
        _pushAt(MON_OPEN + 20 minutes, TSLA_400);
        gate.refresh();
        SessionRiskPolicy.Snapshot memory s = _at(MON_OPEN + 29 minutes);
        _assertState(s, SessionRiskPolicy.State.REOPEN_RECOVERY);
        assertEq(s.creditAt, MON_OPEN + 30 minutes);
        _assertState(_at(MON_OPEN + 30 minutes), SessionRiskPolicy.State.OPEN);
    }

    function test_reopen_guardedWithoutAdmissionByOpenPlus30() public {
        _warp(MON_OPEN + 30 minutes - 1);
        _assertState(_snap(), SessionRiskPolicy.State.REOPEN_WAIT);
        _warp(MON_OPEN + 30 minutes);
        SessionRiskPolicy.Snapshot memory s = _snap();
        _assertState(s, SessionRiskPolicy.State.GUARDED);
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.REOPEN_WAIT));
        _assertNoActions(s);

        // The deadline never makes stale data acceptable; a later qualifying price starts recovery.
        s = _at(MON_OPEN + 40 minutes);
        _assertState(s, SessionRiskPolicy.State.REOPEN_RECOVERY);
        assertEq(s.creditAt, MON_OPEN + 50 minutes);
    }

    function test_reopen_sundayQuoteKeepsTheMarketWaiting() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 86400;
        gate = new PriceGate(c);
        policy = new SessionRiskPolicy(gate);
        _pushAt(MON_OPEN - 13 hours, TSLA_400);
        _warp(MON_OPEN + 20 minutes);
        gate.refresh();
        SessionRiskPolicy.Snapshot memory s = _snap();
        assertEq(s.reasons, 0, "a usable price");
        _assertState(s, SessionRiskPolicy.State.REOPEN_WAIT);
    }

    // ------------------------------------------------------------ guarded

    function test_guarded_invalidPriceDuringTradingStopsEverything() public {
        _at(MON_OPEN + 5 minutes);
        _at(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 60 minutes + MOCK_MAX_AGE + 1);
        SessionRiskPolicy.Snapshot memory s = _snap();
        _assertState(s, SessionRiskPolicy.State.GUARDED);
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.OPEN));
        assertEq(s.reasons, Reasons.STOCK_STALE);
        _assertNoActions(s);
    }

    function test_guarded_staleQuoteWhileClosedIsExpected() public {
        _pushAt(MON_CLOSE - 1 minutes, TSLA_400);
        _warp(MON_CLOSE + 3 hours);
        SessionRiskPolicy.Snapshot memory s = _snap();
        assertEq(s.reasons, Reasons.STOCK_STALE);
        _assertState(s, SessionRiskPolicy.State.CLOSED);
    }

    function test_guarded_guardianStopAppliesEvenWhileClosed() public {
        vm.prank(guardian);
        gate.stop();
        _pushAt(MON_OPEN - 2 hours, TSLA_400);
        _assertState(_snap(), SessionRiskPolicy.State.GUARDED);
    }

    function test_guarded_outsideTheLoadedCalendar() public {
        _pushAt(cal.firstOpen() - 1, TSLA_400);
        SessionRiskPolicy.Snapshot memory s = _snap();
        _assertState(s, SessionRiskPolicy.State.GUARDED);
        assertFalse(s.covered);
        _assertNoActions(s);

        _pushAt(cal.lastClose(), TSLA_400);
        s = _snap();
        _assertState(s, SessionRiskPolicy.State.GUARDED);
        assertFalse(s.covered);
    }

    // ------------------------------------------------------------ calendar classes

    function test_class_weekdayCloseBeforeAHolidayIsExtended() public {
        _pushAt(WED_BEFORE_HOLIDAY_CLOSE - 45 minutes, TSLA_400);
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(gate.quote(), uint64(block.timestamp));
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.REOPEN_WAIT), "never admitted in this test");
        assertEq(uint256(policy.classOf(s.nextOpen - s.close)), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));
        assertEq(s.nextOpen, BLACK_FRIDAY_OPEN, "Thanksgiving is skipped");
    }

    function test_class_earlyCloseMovesTheWholeRamp() public {
        _at(BLACK_FRIDAY_OPEN + 5 minutes);
        SessionRiskPolicy.Snapshot memory s = _at(BLACK_FRIDAY_CLOSE - 120 minutes);
        _assertState(s, SessionRiskPolicy.State.PRE_CLOSE);
        assertEq(s.close, BLACK_FRIDAY_CLOSE);
        assertEq(s.finalAt, BLACK_FRIDAY_CLOSE - 30 minutes);
        assertEq(uint256(s.closureClass), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));

        s = _at(BLACK_FRIDAY_CLOSE - 30 minutes);
        _assertState(s, SessionRiskPolicy.State.FINAL_WINDOW);
        assertEq(s.ltWad, 0.7e18);
        _assertState(_at(BLACK_FRIDAY_CLOSE), SessionRiskPolicy.State.CLOSED);
    }

    function test_class_boundaryIs24Hours() public view {
        assertEq(uint256(policy.classOf(24 hours - 1)), uint256(SessionRiskPolicy.ClosureClass.OVERNIGHT));
        assertEq(uint256(policy.classOf(24 hours)), uint256(SessionRiskPolicy.ClosureClass.EXTENDED));
    }

    // ------------------------------------------------------------ bonuses

    function test_bonus_schedulingVersusDistress() public {
        _at(MON_OPEN + 5 minutes);
        SessionRiskPolicy.Snapshot memory s = _at(MON_CLOSE - 60 minutes);
        _assertState(s, SessionRiskPolicy.State.PRE_CLOSE);
        assertEq(policy.bonusFor(s, 0.79e18), 0.02e18, "scheduling-only trim");
        assertEq(policy.bonusFor(s, 0.8e18), 0.02e18, "80% exactly is not above 80%");
        assertEq(policy.bonusFor(s, 0.81e18), 0.05e18, "also above the open threshold");

        s = _at(MON_CLOSE + 1);
        assertEq(policy.bonusFor(s, 0.95e18), 0, "no execution while closed");
    }

    function test_bonus_openTrimsUseTheDistressBonus() public {
        _at(MON_OPEN + 5 minutes);
        SessionRiskPolicy.Snapshot memory s = _at(MON_OPEN + 1 hours);
        assertEq(policy.bonusFor(s, 0.85e18), 0.05e18);
        assertTrue(policy.trimEligible(s, 0.85e18));
        assertFalse(policy.trimEligible(s, 0.8e18));
    }

    // ------------------------------------------------------------ properties

    /// @dev Across a full week, with the keeper keeping prices fresh: no borrowing outside OPEN/PRE_CLOSE
    /// or at/after F, B always at least 5 points under LT, no execution at/after the close.
    function testFuzz_permissionsFollowTheSchedule(uint256 offset) public {
        uint64 t = uint64(MON_OPEN - 3 days + bound(offset, 0, 7 days));
        (bool covered, bool inSession,, uint64 open,,,) = _context(t);
        if (covered && inSession && t >= open + 5 minutes) _freshRefresh(open + 5 minutes); // keeper admission
        SessionRiskPolicy.Snapshot memory s = _at(t);
        assertGe(s.ltWad, 0.7e18);
        assertLe(s.ltWad, 0.8e18);
        if (s.canBorrow) {
            assertTrue(s.state == SessionRiskPolicy.State.OPEN || s.state == SessionRiskPolicy.State.PRE_CLOSE);
            assertLt(t, s.finalAt);
            assertGe(t, s.creditAt);
            assertLe(s.borrowLimitWad + 0.05e18, s.ltWad);
            assertLe(s.borrowLimitWad, 0.75e18);
        }
        if (s.canTrim || s.canBuffer) {
            assertGe(t, s.open);
            assertLt(t, s.close);
            assertTrue(s.admissionAt != 0);
        }
        if (s.lenderOpen) assertLt(t, s.prepAt);
        if (s.state == SessionRiskPolicy.State.CLOSED) _assertNoActions(s);
    }

    function testFuzz_rampIsMonotoneAndBounded(uint64 t1, uint64 t2, bool extended) public view {
        SessionRiskPolicy.ClosureClass cls =
            extended ? SessionRiskPolicy.ClosureClass.EXTENDED : SessionRiskPolicy.ClosureClass.OVERNIGHT;
        t1 = uint64(bound(t1, MON_CLOSE - 3 hours, MON_CLOSE));
        t2 = uint64(bound(t2, t1, MON_CLOSE));
        uint256 a = policy.ltAt(cls, t1, MON_CLOSE);
        uint256 b = policy.ltAt(cls, t2, MON_CLOSE);
        assertLe(b, a);
        assertGe(b, policy.ltFinalOf(cls));
        assertLe(a, 0.8e18);
    }

    // ============================================================ helpers for exact snapshots

    /// @dev A usable quote stamped at `t`, so the schedule alone decides the phase.
    function _cleanQuote(uint64 t) internal pure returns (PriceGate.Quote memory q) {
        q.priceWad = 400e18;
        q.roundId = 1;
        q.updatedAt = t;
    }

    /// @dev The policy at `t` for a usable quote, with the gate's current admission record.
    function _clean(uint64 t) internal view returns (SessionRiskPolicy.Snapshot memory) {
        return policy.evaluate(_cleanQuote(t), t);
    }

    /// @dev The policy at `t` for a quote carrying `reasons`.
    function _with(uint64 t, uint32 reasons) internal view returns (SessionRiskPolicy.Snapshot memory) {
        PriceGate.Quote memory q = _cleanQuote(t);
        q.reasons = reasons;
        return policy.evaluate(q, t);
    }

    function _ltF(SessionRiskPolicy.ClosureClass k) internal pure returns (uint256) {
        return k == K_EXTENDED ? 0.7e18 : 0.77e18;
    }

    function _tgt(SessionRiskPolicy.ClosureClass k) internal pure returns (uint256) {
        return k == K_EXTENDED ? 0.65e18 : 0.72e18;
    }

    function _expectPhase(
        SessionRiskPolicy.Snapshot memory s,
        SessionRiskPolicy.State phase,
        SessionRiskPolicy.State state,
        string memory at
    ) internal pure {
        assertEq(uint256(s.phase), uint256(phase), string.concat("phase at ", at));
        assertEq(uint256(s.state), uint256(state), string.concat("state at ", at));
    }

    function _expectLimits(
        SessionRiskPolicy.Snapshot memory s,
        SessionRiskPolicy.ClosureClass k,
        uint256 lt,
        uint256 b,
        uint256 target,
        string memory at
    ) internal pure {
        assertEq(uint256(s.closureClass), uint256(k), string.concat("class at ", at));
        assertEq(s.ltWad, lt, string.concat("LT at ", at));
        assertEq(s.borrowLimitWad, b, string.concat("B at ", at));
        assertEq(s.targetWad, target, string.concat("target at ", at));
    }

    /// @dev The permission row of docs/SPEC.md §3 for the snapshot's effective state, written out as a table;
    /// buffers also run in REOPEN_RECOVERY (appendix R20).
    function _expectPermissions(SessionRiskPolicy.Snapshot memory s, string memory at) internal pure {
        SessionRiskPolicy.State st = s.state;
        bool borrow;
        bool trim;
        bool buffer;
        bool lender;
        if (st == S_OPEN) (borrow, trim, buffer, lender) = (true, true, false, true);
        else if (st == S_PRE) (borrow, trim, buffer, lender) = (true, true, true, false);
        else if (st == S_FINAL) (borrow, trim, buffer, lender) = (false, true, true, false);
        else if (st == S_RECOVERY) (borrow, trim, buffer, lender) = (false, true, true, false);
        assertEq(s.canBorrow, borrow, string.concat("canBorrow at ", at));
        assertEq(s.canTrim, trim, string.concat("canTrim at ", at));
        assertEq(s.canBuffer, buffer, string.concat("canBuffer at ", at));
        assertEq(s.lenderOpen, lender, string.concat("lenderOpen at ", at));
        if (!borrow) assertEq(s.borrowLimitWad, 0, string.concat("B is zero without borrowing at ", at));
    }

    function _expectSchedule(
        SessionRiskPolicy.Snapshot memory s,
        uint256 index,
        uint64 open,
        uint64 close,
        uint64 nextOpen,
        uint64 admissionAt,
        uint64 creditAt
    ) internal pure {
        assertTrue(s.covered, "covered");
        assertFalse(s.windDown, "windDown");
        assertEq(s.session, index, "session");
        assertEq(s.open, open, "O");
        assertEq(s.close, close, "C");
        assertEq(s.prepAt, close - 120 minutes, "A");
        assertEq(s.finalAt, close - 30 minutes, "F");
        assertEq(s.nextOpen, nextOpen, "next open");
        assertEq(s.guardAt, open + 30 minutes, "guardAt");
        assertEq(s.admissionAt, admissionAt, "admissionAt");
        assertEq(s.creditAt, creditAt, "creditAt");
    }

    function _expectNoPermission(SessionRiskPolicy.Snapshot memory s, string memory at) internal pure {
        assertFalse(s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen, string.concat("no permission at ", at));
        assertEq(s.borrowLimitWad, 0, string.concat("B at ", at));
    }

    // ============================================================ fixtures

    /// INV-POL-01; mutant: any change to a SessionTiming or policy constant
    function test_constants_timingAndLimitFixturesMatchTheSpec() public view {
        assertEq(SessionTiming.PREP, 2 hours, "PREP");
        assertEq(SessionTiming.FINAL, 30 minutes, "FINAL");
        assertEq(SessionTiming.EXTENDED_GAP, 24 hours, "EXTENDED_GAP");
        assertEq(SessionTiming.ADMIT_AFTER, 5 minutes, "ADMIT_AFTER");
        assertEq(SessionTiming.FRESH_AFTER, 1 minutes, "FRESH_AFTER");
        assertEq(SessionTiming.CREDIT_AFTER, 15 minutes, "CREDIT_AFTER");
        assertEq(SessionTiming.MIN_RECOVERY, 10 minutes, "MIN_RECOVERY");
        assertEq(SessionTiming.GUARD_AFTER, 30 minutes, "GUARD_AFTER");
        assertEq(SessionTiming.RECOVERY_GRACE, 5 minutes, "RECOVERY_GRACE");
        assertEq(SessionTiming.RESUME_DELAY, 24 hours, "RESUME_DELAY");

        assertEq(policy.LT_OPEN(), 0.8e18);
        assertEq(policy.B_OPEN(), 0.75e18);
        assertEq(policy.TARGET_OPEN(), 0.75e18);
        assertEq(policy.BORROW_GAP(), 0.05e18);
        assertEq(policy.LT_FINAL_OVERNIGHT(), 0.77e18);
        assertEq(policy.TARGET_OVERNIGHT(), 0.72e18);
        assertEq(policy.LT_FINAL_EXTENDED(), 0.7e18);
        assertEq(policy.TARGET_EXTENDED(), 0.65e18);
        assertEq(policy.BONUS_SCHEDULING(), 0.02e18);
        assertEq(policy.BONUS_DISTRESS(), 0.05e18);
        assertEq(policy.ltFinalOf(K_OVERNIGHT), 0.77e18);
        assertEq(policy.ltFinalOf(K_EXTENDED), 0.7e18);
        assertEq(policy.targetOf(K_OVERNIGHT), 0.72e18);
        assertEq(policy.targetOf(K_EXTENDED), 0.65e18);

        // The policy reads the gate's calendar and clock (one schedule, one time source).
        assertEq(address(policy.gate()), address(gate));
        assertEq(address(policy.calendar()), address(cal));
        assertEq(address(policy.clock()), address(clock));
    }

    /// INV-X-07 (policy and calendar): nothing in their runtime code can change a parameter after deployment
    function test_immutability_policyAndCalendarCodeNeverWritesState() public view {
        assertEq(_stateOpcodes(address(policy)), 0, "policy: SSTORE, TSTORE, DELEGATECALL, CALLCODE or SELFDESTRUCT");
        assertEq(_stateOpcodes(address(cal)), 0, "calendar: SSTORE, TSTORE, DELEGATECALL, CALLCODE or SELFDESTRUCT");
        for (uint256 slot; slot < 8; ++slot) {
            assertEq(vm.load(address(policy), bytes32(slot)), bytes32(0), "the policy keeps no storage");
        }
        assertGt(_stateOpcodes(address(gate)), 0, "the scan does find the gate's storage writes");
    }

    /// @dev Counts state-changing opcodes in `target`'s runtime code, skipping PUSH data and the CBOR metadata
    /// whose length the last two bytes give.
    function _stateOpcodes(address target) internal view returns (uint256 found) {
        bytes memory code = target.code;
        uint256 meta = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        uint256 end = code.length - 2 - meta;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x55 || op == 0x5d || op == 0xf4 || op == 0xf2 || op == 0xff) ++found;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
    }

    /// INV-POL-01
    function test_creditAt_isTheLaterOfOpenPlus15AndAdmissionPlus10() public pure {
        uint64 o = MON_OPEN;
        assertEq(SessionTiming.creditAt(o, o), o + 15 minutes, "O + 15 min binds an admission at O");
        assertEq(SessionTiming.creditAt(o, o + 4 minutes), o + 15 minutes);
        assertEq(SessionTiming.creditAt(o, o + 5 minutes), o + 15 minutes, "both bind at O + 5 min");
        assertEq(SessionTiming.creditAt(o, o + 5 minutes + 1), o + 15 minutes + 1, "admission + 10 min after that");
        assertEq(SessionTiming.creditAt(o, o + 3 hours), o + 3 hours + 10 minutes);
    }

    // ============================================================ every boundary to the second

    /// INV-POL-04, INV-POL-06, INV-POL-08, INV-POL-11, INV-POL-13, INV-POL-17; mutants M06, M09, M10, M11, M12
    function test_boundary_fridaySessionThroughTheWeekendToTheSecond() public {
        uint256 fri = cal.context(FRI_OPEN).index;
        uint64 a = FRI_CLOSE - 120 minutes;
        uint64 f = FRI_CLOSE - 30 minutes;

        // Thursday's overnight closure lasts until one second before Friday's open.
        SessionRiskPolicy.Snapshot memory s = _clean(FRI_OPEN - 1);
        _expectPhase(s, S_CLOSED, S_CLOSED, "O - 1");
        assertEq(s.session, fri - 1);
        assertEq(s.close, THU_CLOSE);
        assertEq(s.nextOpen, FRI_OPEN);
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "O - 1");
        _expectPermissions(s, "O - 1");

        // O: waiting; the closure that just ended (Thursday to Friday, 17.5 h) still sets the limits.
        s = _clean(FRI_OPEN);
        _expectPhase(s, S_WAIT, S_WAIT, "O");
        _expectSchedule(s, fri, FRI_OPEN, FRI_CLOSE, MON_OPEN, 0, 0);
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "O");
        _expectPermissions(s, "O");

        // One second before O + 5 min a fresh price is not admitted.
        _freshRefresh(FRI_OPEN + 5 minutes - 1);
        assertEq(gate.admissionFor(fri), 0, "no admission before O + 5 min");
        _expectPhase(_snap(), S_WAIT, S_WAIT, "O + 5 min - 1");

        // O + 5 min: admitted; trims only, still at the limits of the closure that ended.
        _freshRefresh(FRI_OPEN + 5 minutes);
        s = _snap();
        _expectPhase(s, S_RECOVERY, S_RECOVERY, "O + 5 min");
        _expectSchedule(s, fri, FRI_OPEN, FRI_CLOSE, MON_OPEN, FRI_OPEN + 5 minutes, FRI_OPEN + 15 minutes);
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "O + 5 min");
        _expectPermissions(s, "O + 5 min");

        s = _clean(FRI_OPEN + 15 minutes - 1);
        _expectPhase(s, S_RECOVERY, S_RECOVERY, "creditAt - 1");
        _expectPermissions(s, "creditAt - 1");

        // creditAt is inclusive: OPEN, with the class of the coming weekend close.
        s = _clean(FRI_OPEN + 15 minutes);
        _expectPhase(s, S_OPEN, S_OPEN, "creditAt");
        _expectLimits(s, K_EXTENDED, 0.8e18, 0.75e18, 0.75e18, "creditAt");
        _expectPermissions(s, "creditAt");

        s = _clean(a - 1);
        _expectPhase(s, S_OPEN, S_OPEN, "A - 1");
        _expectLimits(s, K_EXTENDED, 0.8e18, 0.75e18, 0.75e18, "A - 1");

        // A: preparation; LT still 80%, the target drops to the class target.
        s = _clean(a);
        _expectPhase(s, S_PRE, S_PRE, "A");
        _expectLimits(s, K_EXTENDED, 0.8e18, 0.75e18, 0.65e18, "A");
        _expectPermissions(s, "A");

        s = _clean(a + 1);
        _expectLimits(s, K_EXTENDED, 799981481481481481, 749981481481481481, 0.65e18, "A + 1");
        s = _clean(f - 1);
        _expectPhase(s, S_PRE, S_PRE, "F - 1");
        _expectLimits(s, K_EXTENDED, 700018518518518518, 650018518518518518, 0.65e18, "F - 1");
        _expectPermissions(s, "F - 1");

        // F: final window; borrowing stops, trims and buffers go on at the class LT.
        s = _clean(f);
        _expectPhase(s, S_FINAL, S_FINAL, "F");
        assertEq(s.finalAt, f);
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "F");
        _expectPermissions(s, "F");

        s = _clean(FRI_CLOSE - 1);
        _expectPhase(s, S_FINAL, S_FINAL, "C - 1");
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "C - 1");

        // C: closed for the weekend; the session's admission stays on the snapshot.
        s = _clean(FRI_CLOSE);
        _expectPhase(s, S_CLOSED, S_CLOSED, "C");
        _expectSchedule(s, fri, FRI_OPEN, FRI_CLOSE, MON_OPEN, FRI_OPEN + 5 minutes, FRI_OPEN + 15 minutes);
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "C");
        _expectPermissions(s, "C");

        s = _clean(MON_OPEN - 1);
        _expectPhase(s, S_CLOSED, S_CLOSED, "Monday O - 1");
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "Monday O - 1");

        // Monday O: waiting under the weekend limits until O + 30 min, then GUARDED.
        s = _clean(MON_OPEN);
        _expectPhase(s, S_WAIT, S_WAIT, "Monday O");
        _expectSchedule(s, fri + 1, MON_OPEN, MON_CLOSE, TUE_OPEN, 0, 0);
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "Monday O");
        _expectPhase(_clean(MON_OPEN + 30 minutes - 1), S_WAIT, S_WAIT, "guardAt - 1");
        s = _clean(MON_OPEN + 30 minutes);
        _expectPhase(s, S_WAIT, S_GUARDED, "guardAt");
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "guardAt");
        _expectPermissions(s, "guardAt");
    }

    /// INV-POL-04, INV-POL-05, INV-POL-08, INV-POL-12, INV-POL-13; mutants M10, M11, M12, M17
    function test_boundary_mondayAdmittedAtTheGuardThroughTuesdayToTheSecond() public {
        uint256 mon = _monIndex();
        uint64 a = MON_CLOSE - 120 minutes;
        uint64 f = MON_CLOSE - 30 minutes;

        // Nobody refreshes before O + 30 min: the view turns GUARDED at that second.
        _warp(MON_OPEN + 30 minutes - 1);
        _expectPhase(_snap(), S_WAIT, S_WAIT, "guardAt - 1");
        _warp(MON_OPEN + 30 minutes);
        SessionRiskPolicy.Snapshot memory s = _snap();
        _expectPhase(s, S_WAIT, S_GUARDED, "guardAt");
        _expectNoPermission(s, "guardAt");

        // A qualifying refresh at that same second admits; recovery lasts ten minutes from admission.
        _freshRefresh(MON_OPEN + 30 minutes);
        s = _snap();
        _expectPhase(s, S_RECOVERY, S_RECOVERY, "admitted at guardAt");
        _expectSchedule(s, mon, MON_OPEN, MON_CLOSE, TUE_OPEN, MON_OPEN + 30 minutes, MON_OPEN + 40 minutes);
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "admitted at guardAt");
        _expectPermissions(s, "admitted at guardAt");

        _expectPhase(_clean(MON_OPEN + 40 minutes - 1), S_RECOVERY, S_RECOVERY, "creditAt - 1");
        s = _clean(MON_OPEN + 40 minutes);
        _expectPhase(s, S_OPEN, S_OPEN, "creditAt");
        _expectLimits(s, K_OVERNIGHT, 0.8e18, 0.75e18, 0.75e18, "creditAt");

        _expectPhase(_clean(a - 1), S_OPEN, S_OPEN, "A - 1");
        s = _clean(a);
        _expectPhase(s, S_PRE, S_PRE, "A");
        _expectLimits(s, K_OVERNIGHT, 0.8e18, 0.75e18, 0.72e18, "A");
        _expectLimits(_clean(a + 1), K_OVERNIGHT, 799994444444444444, 749994444444444444, 0.72e18, "A + 1");
        s = _clean(f - 1);
        _expectPhase(s, S_PRE, S_PRE, "F - 1");
        _expectLimits(s, K_OVERNIGHT, 770005555555555555, 720005555555555555, 0.72e18, "F - 1");
        s = _clean(f);
        _expectPhase(s, S_FINAL, S_FINAL, "F");
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "F");
        _expectPhase(_clean(MON_CLOSE - 1), S_FINAL, S_FINAL, "C - 1");

        s = _clean(MON_CLOSE);
        _expectPhase(s, S_CLOSED, S_CLOSED, "C");
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "C");
        _expectPhase(_clean(TUE_OPEN - 1), S_CLOSED, S_CLOSED, "Tuesday O - 1");

        s = _clean(TUE_OPEN);
        _expectPhase(s, S_WAIT, S_WAIT, "Tuesday O");
        _expectSchedule(s, mon + 1, TUE_OPEN, MON_CLOSE + 1 days, TUE_OPEN + 1 days, 0, 0);
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "Tuesday O");
    }

    /// INV-POL-04, INV-POL-13; early closes move A and F with the close
    function test_boundary_earlyClosesMoveTheWholeRampToTheSecond() public {
        uint64[2] memory opens = [XMAS_EVE_OPEN, JULY3_OPEN];
        uint64[2] memory closes = [XMAS_EVE_CLOSE, JULY3_CLOSE];
        for (uint256 k; k < 2; ++k) {
            uint64 c = closes[k];
            assertEq(c - opens[k], 3.5 hours, "13:00 New York close");
            _freshRefresh(opens[k] + 5 minutes);
            _expectPhase(_clean(opens[k] + 15 minutes), S_OPEN, S_OPEN, "creditAt");
            _expectPhase(_clean(c - 120 minutes - 1), S_OPEN, S_OPEN, "A - 1");
            SessionRiskPolicy.Snapshot memory s = _clean(c - 120 minutes);
            _expectPhase(s, S_PRE, S_PRE, "A");
            _expectLimits(s, K_EXTENDED, 0.8e18, 0.75e18, 0.65e18, "A");
            _expectLimits(
                _clean(c - 120 minutes + 1), K_EXTENDED, 799981481481481481, 749981481481481481, 0.65e18, "A+1"
            );
            _expectPhase(_clean(c - 30 minutes - 1), S_PRE, S_PRE, "F - 1");
            s = _clean(c - 30 minutes);
            _expectPhase(s, S_FINAL, S_FINAL, "F");
            _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "F");
            _expectPhase(_clean(c - 1), S_FINAL, S_FINAL, "C - 1");
            _expectPhase(_clean(c), S_CLOSED, S_CLOSED, "C");
        }
    }

    /// INV-POL-01, INV-POL-04; mutant M07
    function test_creditAt_staysZeroUntilTheSessionIsAdmitted() public {
        SessionRiskPolicy.Snapshot memory s = _clean(MON_OPEN + 1 minutes);
        _expectPhase(s, S_WAIT, S_WAIT, "O + 1 min");
        assertEq(s.admissionAt, 0);
        assertEq(s.creditAt, 0, "no credit time before admission");

        s = _clean(MON_OPEN + 4 hours);
        _expectPhase(s, S_WAIT, S_GUARDED, "never admitted");
        assertEq(s.creditAt, 0);

        s = _clean(MON_CLOSE + 1 hours);
        _expectPhase(s, S_CLOSED, S_CLOSED, "closed after a session without admission");
        assertEq(s.admissionAt, 0);
        assertEq(s.creditAt, 0);

        // A real admission is never before O + 5 min, so creditAt is always admission + 10 min.
        _freshRefresh(MON_OPEN + 7 minutes);
        s = _snap();
        assertEq(s.admissionAt, MON_OPEN + 7 minutes);
        assertEq(s.creditAt, MON_OPEN + 17 minutes);
    }

    /// INV-POL-09, INV-POL-01
    function testFuzz_admission_realGateRecordsOnlyInsideTheSessionFromOpenPlusFive(uint256 at, uint256 age) public {
        uint64 t = uint64(bound(at, MON_OPEN - 1 hours, MON_CLOSE + 1 hours));
        uint64 stamp = t - uint64(bound(age, 0, MOCK_MAX_AGE));
        vm.warp(t);
        stockFeed.pushAt(TSLA_400, stamp);
        gate.refresh();
        uint64 adm = gate.admissionFor(_monIndex());
        bool expected = t >= MON_OPEN + 5 minutes && t < MON_CLOSE && stamp >= MON_OPEN + 1 minutes;
        assertEq(adm != 0, expected, "admission iff O + 5 min <= t < C with a post-open price");
        if (adm != 0) {
            assertEq(adm, t, "recorded at the clock time");
            SessionRiskPolicy.Snapshot memory s = _snap();
            assertEq(s.admissionAt, adm);
            assertEq(s.creditAt, adm + 10 minutes);
            _expectPhase(s, S_RECOVERY, S_RECOVERY, "admitted");
        }
    }

    // ============================================================ ramp, borrow limit

    /// INV-POL-12; mutant M28
    function test_ramp_exactGoldenValuesAtSecondsThatRound() public view {
        // floor(0.80 - (0.80 - LT_F) * x / 5400) in WAD, from exact rational arithmetic (tools/golden method).
        uint64[9] memory x = [uint64(1), 2, 3, 7, 60, 1000, 2700, 4499, 5399];
        uint256[9] memory ext = [
            uint256(799981481481481481),
            799962962962962962,
            799944444444444444,
            799870370370370370,
            798888888888888888,
            781481481481481481,
            750000000000000000,
            716685185185185185,
            700018518518518518
        ];
        uint256[9] memory ovn = [
            uint256(799994444444444444),
            799988888888888888,
            799983333333333333,
            799961111111111111,
            799666666666666666,
            794444444444444444,
            785000000000000000,
            775005555555555555,
            770005555555555555
        ];
        uint64 a = MON_CLOSE - 120 minutes;
        for (uint256 k; k < 9; ++k) {
            string memory at = vm.toString(x[k]);
            assertEq(policy.ltAt(K_EXTENDED, a + x[k], MON_CLOSE), ext[k], string.concat("EXTENDED A + ", at));
            assertEq(policy.ltAt(K_OVERNIGHT, a + x[k], MON_CLOSE), ovn[k], string.concat("OVERNIGHT A + ", at));
            assertEq(policy.borrowLimit(ext[k]), ext[k] - 0.05e18);
            assertEq(policy.borrowLimit(ovn[k]), ovn[k] - 0.05e18);
        }
        // Flat outside the ramp, including times the function does not check.
        assertEq(policy.ltAt(K_EXTENDED, 0, MON_CLOSE), 0.8e18);
        assertEq(policy.ltAt(K_EXTENDED, a, MON_CLOSE), 0.8e18);
        assertEq(policy.ltAt(K_OVERNIGHT, MON_CLOSE - 30 minutes, MON_CLOSE), 0.77e18);
        assertEq(policy.ltAt(K_EXTENDED, MON_CLOSE + 1 days, MON_CLOSE), 0.7e18);
        assertEq(policy.ltAt(K_OVERNIGHT, type(uint64).max, MON_CLOSE), 0.77e18);
    }

    /// INV-POL-12, INV-POL-10, INV-POL-11
    function test_ramp_preCloseSnapshotsFollowTheRampEverySecondAtBothEnds() public {
        _freshRefresh(FRI_OPEN + 5 minutes);
        uint64 a = FRI_CLOSE - 120 minutes;
        uint256 previous = 0.8e18;
        // Every second of the first and last 12 seconds of the ramp, and every 397 seconds in between.
        for (uint64 x; x <= 5400; x = x < 12 || x >= 5388 ? x + 1 : (x + 397 > 5388 ? 5388 : x + 397)) {
            SessionRiskPolicy.Snapshot memory s = _clean(a + x);
            // Independent form of the same line: floor((0.80 * 5400 - 0.10 * x) / 5400).
            uint256 expected = x == 5400 ? 0.7e18 : (uint256(0.8e18) * 5400 - uint256(0.1e18) * x) / 5400;
            assertEq(s.ltWad, expected, string.concat("LT at A + ", vm.toString(x)));
            assertLe(s.ltWad, previous, "never rises");
            previous = s.ltWad;
            if (x < 5400) {
                _expectPhase(s, S_PRE, S_PRE, "ramp");
                assertEq(s.borrowLimitWad, s.ltWad - 0.05e18, "B = LT - 5%");
            } else {
                _expectPhase(s, S_FINAL, S_FINAL, "F");
            }
        }
    }

    /// INV-POL-10; mutants M13, M29, M30
    function test_borrowLimit_isTheLowerOfTheCapAndTheGap() public {
        assertEq(policy.borrowLimit(1e18), 0.75e18, "the 75% cap binds above 80%");
        assertEq(policy.borrowLimit(0.8e18 + 1), 0.75e18);
        assertEq(policy.borrowLimit(0.8e18), 0.75e18);
        assertEq(policy.borrowLimit(0.8e18 - 1), 0.75e18 - 1, "the 5% gap binds below 80%");
        assertEq(policy.borrowLimit(0.77e18), 0.72e18);
        assertEq(policy.borrowLimit(0.7e18), 0.65e18);
        assertEq(policy.borrowLimit(0.05e18), 0);
        vm.expectRevert(stdError.arithmeticError);
        policy.borrowLimit(0.05e18 - 1);

        // In PRE_CLOSE the snapshot's B follows the falling LT.
        _freshRefresh(MON_OPEN + 5 minutes);
        SessionRiskPolicy.Snapshot memory s = _clean(MON_CLOSE - 75 minutes);
        assertEq(s.ltWad, 0.785e18);
        assertEq(s.borrowLimitWad, 0.735e18);
    }

    // ============================================================ permissions and GUARDED

    /// @dev One time per schedule phase in Monday's session after an admission at O + 5 min; Tuesday is not
    /// admitted, so Tuesday O + 10 min is REOPEN_WAIT before its guard.
    function _phaseTimes() internal pure returns (uint64[6] memory) {
        return [
            MON_OPEN + 6 minutes, // REOPEN_RECOVERY
            MON_OPEN + 1 hours, // OPEN
            MON_CLOSE - 1 hours, // PRE_CLOSE
            MON_CLOSE - 10 minutes, // FINAL_WINDOW
            MON_CLOSE + 1 hours, // CLOSED
            TUE_OPEN + 10 minutes // REOPEN_WAIT
        ];
    }

    function _row(
        SessionRiskPolicy.Snapshot memory s,
        SessionRiskPolicy.State state,
        bool borrow,
        bool trim,
        bool buffer,
        bool lender,
        string memory at
    ) internal pure {
        assertEq(uint256(s.state), uint256(state), string.concat("state of row ", at));
        assertEq(s.canBorrow, borrow, string.concat("canBorrow of row ", at));
        assertEq(s.canTrim, trim, string.concat("canTrim of row ", at));
        assertEq(s.canBuffer, buffer, string.concat("canBuffer of row ", at));
        assertEq(s.lenderOpen, lender, string.concat("lenderOpen of row ", at));
        if (borrow) assertEq(s.borrowLimitWad + 0.05e18, s.ltWad, string.concat("B = LT - 5% in row ", at));
        else assertEq(s.borrowLimitWad, 0, string.concat("B is zero in row ", at));
    }

    /// INV-POL-06, INV-POL-07, INV-POL-10; mutants M18, M19, M20, M21
    function test_permissions_fullTruthTableByState() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64[6] memory ts = _phaseTimes();
        _row(_clean(ts[1]), S_OPEN, true, true, false, true, "OPEN");
        _row(_clean(ts[2]), S_PRE, true, true, true, false, "PRE_CLOSE");
        _row(_clean(ts[3]), S_FINAL, false, true, true, false, "FINAL_WINDOW");
        _row(_clean(ts[4]), S_CLOSED, false, false, false, false, "CLOSED");
        _row(_clean(ts[5]), S_WAIT, false, false, false, false, "REOPEN_WAIT");
        _row(_clean(ts[0]), S_RECOVERY, false, true, true, false, "REOPEN_RECOVERY");
        // GUARDED overrides every phase, and no row of it allows anything.
        for (uint256 k; k < 6; ++k) {
            _row(_with(ts[k], Reasons.STOPPED), S_GUARDED, false, false, false, false, "GUARDED (stop)");
            _row(_with(ts[k], Reasons.STOPPED | Reasons.STOCK_STALE), S_GUARDED, false, false, false, false, "GUARDED");
        }
        _row(_with(ts[1], Reasons.STOCK_STALE), S_GUARDED, false, false, false, false, "GUARDED from OPEN");
        _row(_with(ts[2], Reasons.ISSUER_PAUSED), S_GUARDED, false, false, false, false, "GUARDED from PRE_CLOSE");
        _row(_clean(TUE_OPEN + 30 minutes), S_GUARDED, false, false, false, false, "GUARDED: no admission by O+30");
        _row(_clean(cal.lastOpen()), S_GUARDED, false, false, false, false, "GUARDED: uncovered");
    }

    /// INV-POL-05, INV-X-10; mutant M15
    function test_guarded_stopOverridesEveryPhaseAndKeepsTheSchedule() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64[6] memory ts = _phaseTimes();
        for (uint256 k; k < 6; ++k) {
            SessionRiskPolicy.Snapshot memory c = _clean(ts[k]);
            SessionRiskPolicy.Snapshot memory s = _with(ts[k], Reasons.STOPPED);
            string memory at = vm.toString(k);
            assertEq(uint256(s.state), uint256(S_GUARDED), string.concat("stopped is GUARDED in phase ", at));
            assertEq(uint256(s.phase), uint256(c.phase), "the phase is kept");
            assertEq(s.reasons, Reasons.STOPPED);
            _expectNoPermission(s, at);
            // The overlay keeps every schedule field and the class limits; only the permissions and B change.
            _expectSchedule(s, c.session, c.open, c.close, c.nextOpen, c.admissionAt, c.creditAt);
            assertEq(uint256(s.closureClass), uint256(c.closureClass));
            assertEq(s.ltWad, c.ltWad);
            assertEq(s.targetWad, c.targetWad);
        }
        // Outside the calendar a stop changes nothing: it is GUARDED already.
        assertEq(uint256(_with(cal.firstOpen() - 1, Reasons.STOPPED).state), uint256(S_GUARDED));
        assertEq(uint256(_with(cal.lastOpen(), Reasons.STOPPED).state), uint256(S_GUARDED));
    }

    /// INV-POL-05; mutants M14, M16, M17
    function test_guarded_otherReasonsGuardOnlyThePhasesThatUseThePrice() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64[6] memory ts = _phaseTimes();
        for (uint256 bit; bit < 21; ++bit) {
            uint32 r = uint32(1 << bit);
            if (r == Reasons.STOPPED) continue;
            for (uint256 k; k < 6; ++k) {
                SessionRiskPolicy.Snapshot memory c = _clean(ts[k]);
                SessionRiskPolicy.Snapshot memory s = _with(ts[k], r);
                bool priced = c.phase != S_CLOSED && c.phase != S_WAIT;
                string memory at = string.concat("bit ", vm.toString(bit), " in phase ", vm.toString(uint256(c.phase)));
                assertEq(uint256(s.state), uint256(priced ? S_GUARDED : c.phase), at);
                assertEq(uint256(s.phase), uint256(c.phase), at);
                if (priced) _expectNoPermission(s, at);
            }
        }
        // Gate-state bits outside Reasons.SOURCE_MASK guard the priced phases like source bits do.
        uint32 gateBits = Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE;
        assertEq(gateBits & Reasons.SOURCE_MASK, 0);
        assertEq(uint256(_with(ts[1], Reasons.OUTAGE_UNRESOLVED).state), uint256(S_GUARDED), "outage in OPEN");
        assertEq(uint256(_with(ts[2], Reasons.RECOVERY_GRACE).state), uint256(S_GUARDED), "grace in PRE_CLOSE");
        assertEq(uint256(_with(ts[0], Reasons.RECOVERY_GRACE).state), uint256(S_GUARDED), "grace in recovery");

        // REOPEN_WAIT one second before the guard ignores every non-stop reason; from the guard it is GUARDED.
        uint64 g = TUE_OPEN + 30 minutes;
        assertEq(uint256(_with(g - 1, Reasons.SOURCE_MASK | gateBits).state), uint256(S_WAIT), "guardAt - 1");
        assertEq(uint256(_with(g - 1, 0).state), uint256(S_WAIT));
        assertEq(uint256(_with(g, 0).state), uint256(S_GUARDED), "guardAt, clean quote");
    }

    /// INV-POL-05, INV-POL-21, INV-X-14; mutant M16
    function test_guarded_outageThenRecoveryGraceFromTheRealGate() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes); // the feed misses its heartbeat after credit has returned
        gate.refresh();
        assertEq(gate.outageSession(), _monIndex() + 1, "outage recorded");

        // The source is fresh again, but the view still carries the unresolved outage.
        _pushAt(MON_OPEN + 64 minutes, TSLA_400);
        SessionRiskPolicy.Snapshot memory s = _snap();
        assertEq(s.reasons, Reasons.OUTAGE_UNRESOLVED);
        _expectPhase(s, S_OPEN, S_GUARDED, "unresolved outage");
        _expectNoPermission(s, "unresolved outage");

        // A transaction records the recovery checkpoint and still sees nothing usable during the grace.
        SessionRiskPolicy.Snapshot memory x = policy.evaluate(gate.refresh(), clock.time());
        assertEq(x.reasons, Reasons.RECOVERY_GRACE);
        _expectPhase(x, S_OPEN, S_GUARDED, "recovery grace");
        _expectNoPermission(x, "recovery grace");
        assertEq(keccak256(abi.encode(_snap())), keccak256(abi.encode(x)), "after a refresh the view agrees");

        _pushAt(MON_OPEN + 69 minutes - 1, TSLA_400);
        _expectPhase(_snap(), S_OPEN, S_GUARDED, "grace - 1");
        s = _at(MON_OPEN + 69 minutes);
        _expectPhase(s, S_OPEN, S_OPEN, "grace over");
        _expectPermissions(s, "grace over");
    }

    // ============================================================ outside the calendar

    /// INV-POL-03, INV-X-13; mutants M01, M02, M03, M04, M05
    function test_uncovered_failsClosedWithEveryScheduleFieldZero() public view {
        uint64 fo = cal.firstOpen();
        uint64 lo = cal.lastOpen();
        uint64 lc = cal.lastClose();
        uint64[9] memory ts = [uint64(0), 1, fo - 1, lo, lo + 1, lo + 1 hours, lc - 1, lc, type(uint64).max];
        uint32[3] memory rs = [uint32(0), Reasons.STOPPED, Reasons.STOCK_STALE];
        for (uint256 k; k < ts.length; ++k) {
            for (uint256 j; j < rs.length; ++j) {
                PriceGate.Quote memory q = PriceGate.Quote(123e18, 7, 99, rs[j]);
                SessionRiskPolicy.Snapshot memory s = policy.evaluate(q, ts[k]);
                string memory at = vm.toString(ts[k]);
                assertEq(s.time, ts[k]);
                assertEq(s.reasons, rs[j], "reasons copied");
                assertEq(s.priceWad, 123e18, "price copied");
                assertEq(s.priceUpdatedAt, 99, "price time copied");
                assertFalse(s.covered, at);
                assertEq(s.windDown, ts[k] >= lo, string.concat("windDown iff t >= lastOpen at ", at));
                assertEq(uint256(s.state), uint256(S_GUARDED), at);
                assertEq(uint256(s.phase), uint256(S_GUARDED), at);
                _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, at);
                _expectNoPermission(s, at);
                assertEq(s.session, 0);
                assertEq(s.open, 0);
                assertEq(s.close, 0);
                assertEq(s.prepAt, 0);
                assertEq(s.finalAt, 0);
                assertEq(s.nextOpen, 0);
                assertEq(s.admissionAt, 0);
                assertEq(s.creditAt, 0);
                assertEq(s.guardAt, 0);
            }
        }
    }

    /// INV-POL-03; mutants M01, M02
    function test_windDown_startsAtTheLastOpenSecondAndCoverageEndsThere() public view {
        uint64 lo = cal.lastOpen();
        uint256 n = cal.sessionCount();
        SessionRiskPolicy.Snapshot memory s = _clean(lo - 1);
        assertTrue(s.covered, "the last covered second");
        assertFalse(s.windDown);
        _expectPhase(s, S_CLOSED, S_CLOSED, "lastOpen - 1");
        assertEq(s.session, n - 2);
        assertEq(s.nextOpen, lo);

        s = _clean(lo);
        assertFalse(s.covered);
        assertTrue(s.windDown, "wind-down from the last open, inclusive");
        assertTrue(_clean(lo + 1 hours).windDown, "during the last session");
        assertTrue(_clean(cal.lastClose() - 1).windDown, "before the last close");
        assertTrue(_clean(cal.lastClose()).windDown, "after the calendar");

        s = _clean(cal.firstOpen());
        assertTrue(s.covered, "coverage starts at the first open");
        assertEq(s.session, 0);
        _expectPhase(s, S_WAIT, S_WAIT, "firstOpen");
        assertFalse(_clean(cal.firstOpen() - 1).covered);
    }

    // ============================================================ closure classes

    /// INV-POL-13; mutant M08
    function test_class_firstLoadedSessionReopensUnderExtendedLimits() public {
        uint64 fo = cal.firstOpen();
        (, uint64 c0) = cal.sessionAt(0);
        (uint64 o1,) = cal.sessionAt(1);
        assertEq(o1 - c0, 17.5 hours, "session 0 is followed by an overnight close");

        // The calendar knows no close before session 0, so its reopening is treated as EXTENDED.
        SessionRiskPolicy.Snapshot memory s = _clean(fo);
        _expectPhase(s, S_WAIT, S_WAIT, "first open");
        assertEq(s.session, 0);
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "first open");

        _freshRefresh(fo + 5 minutes);
        s = _snap();
        _expectPhase(s, S_RECOVERY, S_RECOVERY, "first admission");
        _expectLimits(s, K_EXTENDED, 0.7e18, 0, 0.65e18, "first admission");

        // Its own close and the reopening after it use the real 17.5 h gap.
        _expectLimits(_clean(fo + 15 minutes), K_OVERNIGHT, 0.8e18, 0.75e18, 0.75e18, "first OPEN");
        _expectLimits(_clean(c0), K_OVERNIGHT, 0.77e18, 0, 0.72e18, "first close");
        s = _clean(o1);
        assertEq(s.session, 1);
        _expectLimits(s, K_OVERNIGHT, 0.77e18, 0, 0.72e18, "second open");
    }

    /// @dev The closure from `close` to `nextOpen`: CLOSED with class `k` from C through nextOpen - 1, then
    /// REOPEN_WAIT with the same class at nextOpen.
    function _expectClosure(uint64 close, uint64 nextOpen, SessionRiskPolicy.ClosureClass k) internal view {
        string memory at = vm.toString(close);
        SessionRiskPolicy.Snapshot memory s = _clean(close);
        _expectPhase(s, S_CLOSED, S_CLOSED, at);
        assertEq(s.close, close, "close");
        assertEq(s.nextOpen, nextOpen, "next open");
        _expectLimits(s, k, _ltF(k), 0, _tgt(k), at);
        _expectLimits(_clean(nextOpen - 1), k, _ltF(k), 0, _tgt(k), at);
        s = _clean(nextOpen);
        _expectPhase(s, S_WAIT, S_WAIT, at);
        assertEq(s.open, nextOpen, "open");
        _expectLimits(s, k, _ltF(k), 0, _tgt(k), at);
    }

    /// INV-POL-13, INV-POL-14; mutants M09, M25
    function test_class_holidaysEarlyClosesAndClockChangesAreExtended() public view {
        _expectClosure(LABOR_DAY_FRI_CLOSE, LABOR_DAY_TUE_OPEN, K_EXTENDED); // 89.5 h
        _expectClosure(WED_BEFORE_HOLIDAY_CLOSE, BLACK_FRIDAY_OPEN, K_EXTENDED); // 41.5 h, Thanksgiving
        _expectClosure(BLACK_FRIDAY_CLOSE, BLACK_FRIDAY_NEXT_OPEN, K_EXTENDED); // 68.5 h after an early close
        _expectClosure(XMAS_EVE_CLOSE, XMAS_NEXT_OPEN, K_EXTENDED); // 92.5 h, the longest gap
        _expectClosure(JULY3_CLOSE, JULY5_OPEN, K_EXTENDED); // 44.5 h after an early close
        _expectClosure(FALL_BACK_FRI_CLOSE, FALL_BACK_MON_OPEN, K_EXTENDED); // 66.5 h
        _expectClosure(SPRING_FWD_FRI_CLOSE, SPRING_FWD_MON_OPEN, K_EXTENDED); // 64.5 h
        _expectClosure(FRI_CLOSE, MON_OPEN, K_EXTENDED); // 65.5 h
        _expectClosure(MON_CLOSE, TUE_OPEN, K_OVERNIGHT); // 17.5 h
        _expectClosure(THU_CLOSE, FRI_OPEN, K_OVERNIGHT);
    }

    // ============================================================ bonuses and eligibility

    /// INV-POL-19, INV-POL-20; mutants M22, M23, M24
    function test_bonus_fullTableByStateAndLtv() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64[6] memory ts = _phaseTimes();
        uint256[8] memory ltvs =
            [uint256(0), 0.5e18, 0.77e18, 0.8e18 - 1, 0.8e18, 0.8e18 + 1, 0.95e18, type(uint256).max];
        for (uint256 j; j < ltvs.length; ++j) {
            uint256 ltv = ltvs[j];
            string memory at = vm.toString(ltv);
            assertEq(policy.bonusFor(_clean(ts[0]), ltv), 0.05e18, string.concat("REOPEN_RECOVERY ", at));
            assertEq(policy.bonusFor(_clean(ts[1]), ltv), 0.05e18, string.concat("OPEN ", at));
            uint256 split = ltv > 0.8e18 ? 0.05e18 : 0.02e18;
            assertEq(policy.bonusFor(_clean(ts[2]), ltv), split, string.concat("PRE_CLOSE ", at));
            assertEq(policy.bonusFor(_clean(ts[3]), ltv), split, string.concat("FINAL_WINDOW ", at));
            assertEq(policy.bonusFor(_clean(ts[4]), ltv), 0, string.concat("CLOSED ", at));
            assertEq(policy.bonusFor(_clean(ts[5]), ltv), 0, string.concat("REOPEN_WAIT ", at));
            for (uint256 k; k < 6; ++k) {
                assertEq(policy.bonusFor(_with(ts[k], Reasons.STOPPED), ltv), 0, string.concat("GUARDED ", at));
            }
            assertEq(policy.bonusFor(_clean(cal.lastOpen()), ltv), 0, string.concat("uncovered ", at));
        }
    }

    /// INV-POL-20; mutant M24
    function test_trimEligible_isStrictlyAboveLtAndNeedsTrimPermission() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64[6] memory ts = _phaseTimes();
        for (uint256 k; k < 6; ++k) {
            SessionRiskPolicy.Snapshot memory s = _clean(ts[k]);
            assertFalse(policy.trimEligible(s, s.ltWad - 1), "below LT");
            assertFalse(policy.trimEligible(s, s.ltWad), "at LT");
            assertEq(policy.trimEligible(s, s.ltWad + 1), s.canTrim, "above LT");
            assertEq(policy.trimEligible(s, type(uint256).max), s.canTrim);
            assertFalse(policy.trimEligible(_with(ts[k], Reasons.STOPPED), type(uint256).max), "GUARDED");
        }
        // Between B and LT a position is never trimmable (worked example in PRE_CLOSE at 15:15 New York).
        SessionRiskPolicy.Snapshot memory p = _clean(MON_CLOSE - 45 minutes);
        assertFalse(policy.trimEligible(p, p.borrowLimitWad + 0.03e18));
    }

    // ============================================================ non-monotone LT, resume, view versus transaction

    /// INV-POL-16, INV-POL-11
    function test_lt_risesWhenCreditReturnsAfterAnAdmissionInsidePreparation() public {
        uint64 a = MON_CLOSE - 120 minutes;
        _freshRefresh(a + 1 minutes); // the first qualifying refresh of the day comes after A
        SessionRiskPolicy.Snapshot memory r = _clean(a + 10 minutes);
        _expectPhase(r, S_RECOVERY, S_RECOVERY, "recovery inside preparation");
        _expectLimits(r, K_EXTENDED, 0.7e18, 0, 0.65e18, "recovery: weekend limits");
        assertTrue(r.canTrim && r.canBuffer && !r.canBorrow);

        SessionRiskPolicy.Snapshot memory p = _clean(a + 11 minutes);
        _expectPhase(p, S_PRE, S_PRE, "credit returns");
        _expectLimits(p, K_OVERNIGHT, 796333333333333333, 746333333333333333, 0.72e18, "ramp at A + 11 min");
        assertGt(p.ltWad, r.ltWad, "LT rises when credit returns");
    }

    /// INV-X-12, INV-POL-04
    function test_resume_newCreditNeedsAFreshAdmission() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 1 hours);
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();
        uint64 due = gate.resumeAvailableAt();
        assertEq(due, MON_OPEN + 1 hours + 24 hours);
        assertGe(due, MON_CLOSE, "a session ends before the resume delay does");

        // The resume lands in Tuesday's session, which has no admission of its own.
        _pushAt(due, TSLA_400);
        vm.prank(guardian);
        gate.resume();
        SessionRiskPolicy.Snapshot memory s = _snap();
        assertEq(s.session, _monIndex() + 1);
        assertEq(s.admissionAt, 0);
        _expectPhase(s, S_WAIT, S_GUARDED, "after resume, past Tuesday's guard");
        _expectNoPermission(s, "after resume");

        // During the grace the gate admits nothing; afterwards a fresh price starts a full recovery.
        s = _at(due + 4 minutes);
        _expectPhase(s, S_WAIT, S_GUARDED, "grace");
        s = _at(due + 5 minutes);
        _expectPhase(s, S_RECOVERY, S_RECOVERY, "fresh admission");
        assertEq(s.admissionAt, due + 5 minutes);
        assertEq(s.creditAt, due + 15 minutes);
        _expectPhase(_clean(due + 15 minutes - 1), S_RECOVERY, S_RECOVERY, "no credit before creditAt");
        _expectPhase(_clean(due + 15 minutes), S_OPEN, S_OPEN, "credit");
    }

    /// INV-POL-21
    function test_view_equalsEvaluateOfTheQuoteAndNeverAllowsMoreThanATransaction() public {
        _pushAt(MON_OPEN + 40 minutes, TSLA_400);
        SessionRiskPolicy.Snapshot memory v = _snap();
        bytes32 quoted = keccak256(abi.encode(policy.evaluate(gate.quote(), clock.time())));
        assertEq(keccak256(abi.encode(v)), quoted, "snapshot() == evaluate(quote(), now)");
        _expectPhase(v, S_WAIT, S_GUARDED, "the view records no admission");

        SessionRiskPolicy.Snapshot memory x = policy.evaluate(gate.refresh(), clock.time());
        _expectPhase(x, S_RECOVERY, S_RECOVERY, "the transaction admits");
        assertEq(x.creditAt, MON_OPEN + 50 minutes);
        assertEq(keccak256(abi.encode(_snap())), keccak256(abi.encode(x)), "after a refresh the view agrees");
    }

    /// INV-POL-21, INV-POL-07
    function testFuzz_view_neverAllowsMoreThanATransactionAtTheSameSecond(uint256 offset, uint256 keeperGap) public {
        uint64 t = uint64(MON_OPEN - 3 days + bound(offset, 0, 7 days));
        // The keeper last refreshed some time before t, possibly long before.
        uint64 last = t - uint64(bound(keeperGap, 0, 2 hours));
        if (last > MON_OPEN - 3 days) _freshRefresh(last);
        _pushAt(t, TSLA_400);
        SessionRiskPolicy.Snapshot memory v = _snap();
        SessionRiskPolicy.Snapshot memory x = policy.evaluate(gate.refresh(), clock.time());
        if (v.canBorrow) assertTrue(x.canBorrow && x.borrowLimitWad == v.borrowLimitWad, "borrow");
        if (v.canTrim) assertTrue(x.canTrim, "trim");
        if (v.canBuffer) assertTrue(x.canBuffer, "buffer");
        if (v.lenderOpen) assertTrue(x.lenderOpen, "lender");
        if (x.canBorrow || x.canTrim || x.canBuffer || x.lenderOpen) {
            assertEq(x.reasons, 0);
            assertTrue(x.covered && x.admissionAt != 0 && x.admissionAt <= t);
            assertTrue(t >= x.open && t < x.close);
        }
    }
}

/// @notice The policy seen from the contracts that consume it: shared wiring, consistent risk constants, a guardian
/// stop across every phase, the commitment of escrow funds and wind-down after the calendar ends.
contract PolicyConsumersTest is MarketFixture {
    address internal dave = makeAddr("dave"); // collateral only, no debt

    function setUp() public {
        _setUpMarket();
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(bob);
        _workedExample(alice);
        _fundCollateral(dave, 10 * TOKEN);

        usdg.mint(alice, 2_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        escrow.authorize(0.65e18, 1_000 * USDG, type(uint64).max);
        vm.stopPrank();
        vm.prank(bob);
        usdg.approve(address(market), type(uint256).max);
    }

    // ------------------------------------------------------------ wiring and constants

    /// INV-X-01
    function test_wiring_everyContractSharesOneGateCalendarAndClock() public {
        StockReefLens lens = new StockReefLens(market);
        assertEq(address(policy.gate()), address(gate));
        assertEq(address(policy.calendar()), address(gate.calendar()));
        assertEq(address(policy.clock()), address(gate.clock()));
        assertEq(address(market.policy()), address(policy));
        assertEq(address(market.gate()), address(gate));
        assertEq(address(market.clock()), address(gate.clock()));
        assertEq(market.asset(), gate.loanToken());
        assertEq(address(market.collateralToken()), address(gate.token()));
        assertEq(market.VALUE_SCALE(), gate.VALUE_SCALE());
        assertEq(address(escrow.market()), address(market));
        assertEq(address(escrow.policy()), address(policy));
        assertEq(address(escrow.gate()), address(gate));
        assertEq(address(escrow.clock()), address(gate.clock()));
        assertEq(address(escrow.loanToken()), market.asset());
        assertEq(address(lens.market()), address(market));
        assertEq(address(lens.escrow()), address(escrow));
        assertEq(address(lens.policy()), address(policy));
        assertEq(address(lens.gate()), address(gate));
        assertEq(address(lens.calendar()), address(gate.calendar()));
    }

    /// INV-X-01
    function test_wiring_marketRejectsAGateThatPricesOtherTokens() public {
        MockUSDG otherLoan = new MockUSDG();
        MockStockToken otherStock = new MockStockToken("Other Stock Token", "OTHER", true);
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new MarketHarness(otherLoan, tsla, policy, MIN_LOAN);
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new MarketHarness(usdg, otherStock, policy, MIN_LOAN);
    }

    /// INV-X-08, INV-POL-18
    function test_constants_riskParametersAreConsistent() public view {
        uint256 wad = 1e18;
        uint256[3] memory lts = [policy.LT_OPEN(), policy.LT_FINAL_OVERNIGHT(), policy.LT_FINAL_EXTENDED()];
        uint256[3] memory targets = [policy.TARGET_OPEN(), policy.TARGET_OVERNIGHT(), policy.TARGET_EXTENDED()];
        uint256[2] memory bonuses = [policy.BONUS_SCHEDULING(), policy.BONUS_DISTRESS()];
        // T < LT_F <= LT <= 80% in every regime, with the 5% margin between LT and T.
        assertLe(policy.LT_FINAL_EXTENDED(), policy.LT_FINAL_OVERNIGHT());
        assertLe(policy.LT_FINAL_OVERNIGHT(), policy.LT_OPEN());
        assertEq(policy.LT_OPEN(), 0.8e18);
        for (uint256 k; k < 3; ++k) {
            assertLt(targets[k], lts[k], "T < LT");
            assertGe(lts[k], targets[k] + policy.BORROW_GAP(), "LT - T >= 5%");
            assertLt(policy.borrowLimit(lts[k]), lts[k], "B < LT");
            assertGe(targets[k], escrow.MAX_TARGET(), "escrow targets are never above a closure target");
            for (uint256 j; j < 2; ++j) {
                assertLt(lts[k] * (wad + bonuses[j]), wad * wad, "(1 + b) * LT < 1");
                assertLt(targets[k] * (wad + bonuses[j]), wad * wad, "T * (1 + b) < 1: positive trim denominator");
            }
        }
        assertLe(policy.BONUS_SCHEDULING(), policy.BONUS_DISTRESS());
        assertLe(policy.BONUS_DISTRESS(), market.RECOVERY_HAIRCUT(), "b <= the lenders' recovery haircut");
        assertLt(policy.B_OPEN() * 105, 100 * wad, "B_OPEN < 1 / 1.05");
        assertLt(policy.B_OPEN(), policy.LT_OPEN());
        assertEq(escrow.MAX_TARGET(), policy.TARGET_EXTENDED(), "the deepest plan target is the smallest target");
    }

    // ------------------------------------------------------------ a stop blocks prices, not exits

    function _expectPriceActionsRevert() internal {
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.borrow(MIN_LOAN, bob);
        vm.prank(bob);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdrawCollateral(1, bob);
        vm.prank(lender);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(1 * USDG, lender);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.trim(bob, 1_000 * USDG, 0, block.timestamp);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);
    }

    function _expectExitsWork() internal {
        uint256 debt = market.debtOf(bob);
        vm.prank(bob);
        assertEq(market.repay(1 * USDG, bob), 1 * USDG, "repay");
        assertApproxEqAbs(market.debtOf(bob), debt - 1 * USDG, 1);
        tsla.mint(dave, 1);
        vm.prank(dave);
        market.depositCollateral(1, dave);
        vm.prank(dave);
        market.withdrawCollateral(2, dave); // no debt: needs no price
        vm.prank(alice);
        escrow.deposit(1 * USDG, alice);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(1 * USDG), 1 * USDG, "owner repay");
    }

    /// INV-X-10, INV-POL-05, INV-POL-07
    function test_stop_blocksEveryPriceActionInEveryPhaseWhileExitsWork() public {
        vm.prank(guardian);
        gate.stop();
        uint64[6] memory ts = [
            FRI_OPEN + 1 hours,
            FRI_CLOSE - 1 hours,
            FRI_CLOSE - 10 minutes,
            FRI_CLOSE + 1 hours,
            MON_OPEN + 10 minutes,
            MON_OPEN + 40 minutes
        ];
        SessionRiskPolicy.State[6] memory phases = [
            SessionRiskPolicy.State.OPEN,
            SessionRiskPolicy.State.PRE_CLOSE,
            SessionRiskPolicy.State.FINAL_WINDOW,
            SessionRiskPolicy.State.CLOSED,
            SessionRiskPolicy.State.REOPEN_WAIT,
            SessionRiskPolicy.State.REOPEN_WAIT
        ];
        for (uint256 k; k < 6; ++k) {
            SessionRiskPolicy.Snapshot memory s = _tick(ts[k]);
            assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED), "GUARDED");
            assertEq(uint256(s.phase), uint256(phases[k]), "phase kept");
            assertTrue(s.reasons & Reasons.STOPPED != 0);
            assertFalse(s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen);
            _expectPriceActionsRevert();
            _expectExitsWork();
        }
    }

    /// INV-X-14 (a stop or an outage during OPEN), INV-POL-05
    function test_commitment_stopOrOutageDuringOpenKeepsThePhaseAndNeverCommitsEscrow() public {
        assertFalse(escrow.committed(alice), "OPEN");
        vm.warp(block.timestamp + MOCK_MAX_AGE + 1); // the price goes stale
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.OPEN), "phase kept under a stale price");
        assertFalse(escrow.committed(alice));

        vm.prank(guardian);
        gate.stop();
        s = _tick(block.timestamp + 1 minutes);
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.OPEN), "phase kept under a stop");
        assertFalse(escrow.committed(alice));
        vm.prank(alice);
        escrow.withdraw(1 * USDG, alice);

        // From A the commitment follows the phase, stop or not.
        vm.warp(FRI_CLOSE - 120 minutes);
        assertEq(uint256(policy.snapshot().phase), uint256(SessionRiskPolicy.State.PRE_CLOSE));
        assertTrue(escrow.committed(alice));
    }

    // ------------------------------------------------------------ wind-down

    /// INV-X-13 (no price-dependent permission from lastOpen; exits continue), INV-POL-03
    function test_windDown_noPricePermissionAndExitsContinueForGood() public {
        uint64 lo = cal.lastOpen();
        uint64[3] memory ts = [lo, lo + 1 hours, cal.lastClose() + 30 days];
        uint256 shares = market.balanceOf(lender);
        for (uint256 k; k < 3; ++k) {
            SessionRiskPolicy.Snapshot memory s = _tick(ts[k]);
            assertEq(s.reasons, 0, "a usable price");
            assertTrue(s.windDown);
            assertFalse(s.covered);
            assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
            assertFalse(s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen, "no permission");

            vm.prank(bob);
            vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
            market.borrow(MIN_LOAN, bob);
            vm.prank(lender);
            vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
            market.deposit(1 * USDG, lender);
            vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
            escrow.executeBuffer(alice);

            vm.prank(bob);
            market.repay(1 * USDG, bob);
            vm.prank(dave);
            market.withdrawCollateral(1, dave);
            assertFalse(escrow.committed(alice), "escrow is released");
            vm.prank(alice);
            escrow.withdraw(1 * USDG, alice);
            vm.prank(lender);
            assertGt(market.redeem(shares / 1_000, lender, lender), 0, "lenders exit against cash");
        }
    }

    // ------------------------------------------------------------ refreshes never move the book

    /// INV-X-21
    function test_refresh_phaseChangesNeverMovePositionsPlansOrCash() public {
        uint64[9] memory ts = [
            FRI_CLOSE - 2 hours,
            FRI_CLOSE - 30 minutes,
            FRI_CLOSE,
            MON_OPEN,
            MON_OPEN + 5 minutes,
            MON_OPEN + 15 minutes,
            MON_CLOSE,
            cal.lastOpen(),
            cal.lastClose() + 1 days
        ];
        bytes32 book = _bookHash();
        uint256 debt = market.debtOf(bob);
        for (uint256 k; k < ts.length; ++k) {
            _tick(ts[k]);
            assertEq(_bookHash(), book, "a refresh moved positions, plans or cash");
            assertGe(market.debtOf(bob), debt, "a closure never reduces debt");
            debt = market.debtOf(bob);
        }
    }

    function _bookHash() internal view returns (bytes32) {
        (uint256 ac, uint256 as_,) = market.accountOf(alice);
        (uint256 bc, uint256 bs,) = market.accountOf(bob);
        (uint256 dc, uint256 ds,) = market.accountOf(dave);
        return keccak256(
            abi.encode(
                ac,
                as_,
                bc,
                bs,
                dc,
                ds,
                escrow.planOf(alice),
                market.cash(),
                market.totalDebtShares(),
                market.totalSupply(),
                usdg.balanceOf(address(market)),
                usdg.balanceOf(address(escrow)),
                tsla.balanceOf(address(market))
            )
        );
    }
}
