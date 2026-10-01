// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GateFixture} from "../utils/GateFixture.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";

contract SessionRiskPolicyTest is GateFixture {
    // Friday 2026-09-11 session (weekend follows), the day before Thanksgiving, and the early close after it.
    uint64 internal constant FRI_OPEN = 1789133400;
    uint64 internal constant WED_BEFORE_HOLIDAY_CLOSE = 1795640400;
    uint64 internal constant BLACK_FRIDAY_OPEN = 1795789800;
    uint64 internal constant BLACK_FRIDAY_CLOSE = 1795802400; // 13:00 New York

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
}
