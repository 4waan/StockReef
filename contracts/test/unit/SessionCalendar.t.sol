// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixtures} from "../utils/Fixtures.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";

contract SessionCalendarTest is Fixtures {
    SessionCalendar internal cal;

    // Reference sessions (UTC), cross-checked against tools/calendar/sessions.json.
    uint64 internal constant FRI_2026_10_02_OPEN = 1790947800; // 09:30 EDT
    uint64 internal constant FRI_2026_10_02_CLOSE = 1790971200; // 16:00 EDT
    uint64 internal constant MON_2026_10_05_OPEN = 1791207000; // 09:30 EDT
    uint64 internal constant MON_2026_11_02_OPEN = 1793629800; // 09:30 EST (after the DST change)
    uint64 internal constant WED_2026_11_25_CLOSE = 1795640400; // 16:00 EST, before Thanksgiving
    uint64 internal constant FRI_2026_11_27_OPEN = 1795789800; // 09:30 EST
    uint64 internal constant FRI_2026_11_27_CLOSE = 1795802400; // 13:00 EST early close
    uint64 internal constant FRI_2026_09_04_CLOSE = 1788552000; // 16:00 EDT, before Labor Day
    uint64 internal constant TUE_2026_09_08_OPEN = 1788874200; // 09:30 EDT

    function setUp() public {
        cal = _deployCalendar();
    }

    function test_EverySessionMatchesGeneratedJson() public view {
        uint256 n = cal.sessionCount();
        (uint256[] memory opens, uint256[] memory closes) = _jsonSessions();
        assertEq(n, opens.length);
        for (uint256 i; i < n; ++i) {
            (uint64 o, uint64 c) = cal.sessionAt(i);
            assertEq(o, opens[i], "open");
            assertEq(c, closes[i], "close");
        }
    }

    function test_EveryOpenAndCloseResolvesToItsOwnSession() public view {
        uint256 n = cal.sessionCount();
        for (uint256 i; i + 1 < n; ++i) {
            (uint64 o, uint64 c) = cal.sessionAt(i);
            SessionCalendar.Context memory atOpen = cal.context(o);
            assertTrue(atOpen.covered && atOpen.inSession, "in session at open");
            assertEq(atOpen.index, i);
            SessionCalendar.Context memory lastSecond = cal.context(c - 1);
            assertTrue(lastSecond.inSession, "in session one second before close");
            SessionCalendar.Context memory atClose = cal.context(c);
            assertFalse(atClose.inSession, "closed at close");
            assertEq(atClose.index, i);
            (uint64 nextOpen,) = cal.sessionAt(i + 1);
            assertEq(atClose.nextOpen, nextOpen);
        }
    }

    function test_FridayCloseToMondayOpen() public view {
        SessionCalendar.Context memory c = cal.context(FRI_2026_10_02_CLOSE + 3 hours);
        assertTrue(c.covered);
        assertFalse(c.inSession);
        assertEq(c.close, FRI_2026_10_02_CLOSE);
        assertEq(c.nextOpen, MON_2026_10_05_OPEN);
        assertEq(c.open, FRI_2026_10_02_OPEN);
    }

    function test_DaylightSavingChangeMovesTheUtcOpen() public view {
        SessionCalendar.Context memory c = cal.context(MON_2026_11_02_OPEN);
        assertTrue(c.inSession);
        assertEq(c.open, MON_2026_11_02_OPEN);
        assertFalse(cal.context(MON_2026_11_02_OPEN - 1).inSession, "13:30 UTC is pre-market after the change");
    }

    function test_ThanksgivingIsNotASessionAndFridayClosesEarly() public view {
        SessionCalendar.Context memory c = cal.context(WED_2026_11_25_CLOSE + 1 days);
        assertFalse(c.inSession);
        assertEq(c.close, WED_2026_11_25_CLOSE);
        assertEq(c.nextOpen, FRI_2026_11_27_OPEN);

        SessionCalendar.Context memory fri = cal.context(FRI_2026_11_27_OPEN + 1 hours);
        assertTrue(fri.inSession);
        assertEq(fri.close, FRI_2026_11_27_CLOSE, "1:00 p.m. ET early close");
    }

    function test_HolidayDoesNotCreateAWeekendReopen() public view {
        SessionCalendar.Context memory c = cal.context(FRI_2026_09_04_CLOSE + 2 days);
        assertFalse(c.inSession);
        assertEq(c.close, FRI_2026_09_04_CLOSE);
        assertEq(c.nextOpen, TUE_2026_09_08_OPEN, "Labor Day Monday is closed");
    }

    function test_OutsideCoverageFailsClosed() public view {
        assertFalse(cal.context(cal.firstOpen() - 1).covered);
        assertFalse(cal.context(cal.lastClose()).covered);
        assertFalse(cal.context(type(uint64).max).covered);
        // The last session is in the schedule, but its next open is unknown, so it is not covered.
        assertFalse(cal.context(cal.lastClose() - 1).covered);
    }

    function test_RevertsOnBadInput() public {
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(SessionCalendar.EmptyCalendar.selector);
        new SessionCalendar(none, 0);

        uint256[] memory one = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.WordCountMismatch.selector, 1, 5));
        new SessionCalendar(one, 5);

        // Session 1 opens before session 0 closes.
        one[0] = (uint256((uint64(1000) << 32) | 2000)) | (uint256((uint64(1500) << 32) | 3000) << 64);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(one, 2);
    }

    function testFuzz_ContextIsConsistent(uint64 t) public view {
        t = uint64(bound(t, cal.firstOpen(), cal.lastClose() - 1));
        SessionCalendar.Context memory c = cal.context(t);
        assertLe(c.open, t);
        if (c.inSession) {
            assertLt(t, c.close);
        } else {
            assertGe(t, c.close);
            if (c.covered) assertLt(t, c.nextOpen);
        }
        if (c.covered) assertLt(c.close, c.nextOpen);
    }
}
