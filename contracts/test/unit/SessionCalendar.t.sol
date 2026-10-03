// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

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

    // ------------------------------------------------------------ committed data: bounds, layout, padding

    /// INV-CAL-03 (mutants: firstOpen from the first close, lastOpen from the last close, lastOpen one second late)
    /// @notice The coverage bounds are the first and last loaded sessions and agree with the generator's summary
    /// fields.
    function test_BoundsAreTheFirstAndLastLoadedSessions() public view {
        string memory json = _sessionsJson();
        (uint256[] memory opens, uint256[] memory closes) = _jsonSessions();
        uint256 n = opens.length;
        assertEq(cal.sessionCount(), n, "count");
        assertEq(n, vm.parseJsonUint(json, ".count"), "count field");
        assertEq(cal.firstOpen(), opens[0], "firstOpen");
        assertEq(cal.firstOpen(), vm.parseJsonUint(json, ".first_open"), "first_open field");
        assertEq(cal.lastOpen(), opens[n - 1], "lastOpen");
        assertEq(cal.lastClose(), closes[n - 1], "lastClose");
        assertEq(cal.lastClose(), vm.parseJsonUint(json, ".last_close"), "last_close field");
    }

    /// INV-CAL-04, INV-CAL-05
    /// @notice The committed words are the session list packed four per word, session i in slot i % 4 of word
    /// i / 4 as open * 2^32 + close, with zero in the unused slot of the last word. Packing with multiplication
    /// instead of shifts checks the layout independently of the contract's decoder.
    function test_PackedWordsAreTheSessionList() public view {
        uint256[] memory words = vm.parseJsonUintArray(_sessionsJson(), ".packed");
        (uint256[] memory opens, uint256[] memory closes) = _jsonSessions();
        uint256 n = opens.length;
        assertEq(words.length, (n + 3) / 4, "ceil(count / 4) words");
        uint256[] memory expected = new uint256[](words.length);
        for (uint256 i; i < n; ++i) {
            assertLt(opens[i], 2 ** 32, "32-bit open");
            assertLt(closes[i], 2 ** 32, "32-bit close");
            expected[i / 4] += (opens[i] * 2 ** 32 + closes[i]) * 2 ** (64 * (i % 4));
        }
        for (uint256 j; j < words.length; ++j) {
            assertEq(words[j], expected[j], "packed word");
        }
    }

    /// INV-CAL-05
    /// @notice sessionAt does not check sessionCount: the unused slot of the committed last word reads as zero,
    /// and an index past the last word reverts with an array out-of-bounds panic. Callers check
    /// i < sessionCount themselves.
    function test_PaddingSlotReadsZeroAndPastTheLastWordPanics() public {
        uint256 n = cal.sessionCount();
        uint256 slots = (n + 3) / 4 * 4;
        assertGt(slots, n, "the committed count leaves an unused slot");
        for (uint256 i = n; i < slots; ++i) {
            (uint64 o, uint64 c) = cal.sessionAt(i);
            assertEq(o, 0, "padding open");
            assertEq(c, 0, "padding close");
        }
        vm.expectRevert(stdError.indexOOBError);
        cal.sessionAt(slots);
        vm.expectRevert(stdError.indexOOBError);
        cal.sessionAt(type(uint256).max);
    }

    // ------------------------------------------------------------ committed data: context at the edges

    /// INV-CAL-07, INV-CAL-08 (mutants: upper bound one second early, search upper bound sessionCount or
    /// sessionCount - 2, coverage that includes the last session)
    /// @notice Inside the last loaded session the context describes that session, in session but not covered;
    /// one second before it the market is covered and the last session is the next open.
    function test_LastLoadedSessionIsInSessionButNotCovered() public view {
        uint256 n = cal.sessionCount();
        (uint64 lastOpen, uint64 lastClose) = cal.sessionAt(n - 1);
        (uint64 prevOpen, uint64 prevClose) = cal.sessionAt(n - 2);
        uint64[4] memory ts = [lastOpen, lastOpen + 1, lastOpen + 1 hours, lastClose - 1];
        for (uint256 j; j < ts.length; ++j) {
            SessionCalendar.Context memory c = cal.context(ts[j]);
            assertFalse(c.covered, "no next open");
            assertTrue(c.inSession, "in session");
            assertEq(c.index, n - 1, "index");
            assertEq(c.open, lastOpen, "open");
            assertEq(c.close, lastClose, "close");
            assertEq(c.prevClose, prevClose, "prevClose");
            assertEq(c.nextOpen, 0, "nextOpen");
        }
        SessionCalendar.Context memory before = cal.context(lastOpen - 1);
        assertTrue(before.covered, "covered until lastOpen");
        assertFalse(before.inSession, "between sessions");
        assertEq(before.index, n - 2, "index");
        assertEq(before.open, prevOpen, "open");
        assertEq(before.close, prevClose, "close");
        assertEq(before.nextOpen, lastOpen, "nextOpen");
    }

    /// INV-CAL-09 (mutants: lower bound inclusive or dropped, upper bound exclusive or dropped)
    /// @notice Before firstOpen and from lastClose on, context is the all-zero struct, at the boundary seconds and
    /// at the extremes of uint64; at firstOpen itself it is session 0 with no previous close.
    function test_OutsideTheScheduleIsTheZeroContext() public view {
        uint64 first = cal.firstOpen();
        uint64 last = cal.lastClose();
        uint64[9] memory ts = [
            uint64(0),
            1,
            first - 1,
            last,
            last + 1,
            last + 1 days,
            type(uint32).max,
            uint64(type(uint32).max) + 1,
            type(uint64).max
        ];
        for (uint256 j; j < ts.length; ++j) {
            _assertZero(cal.context(ts[j]));
        }
        SessionCalendar.Context memory c = cal.context(first);
        assertTrue(c.covered && c.inSession, "covered and in session at firstOpen");
        assertEq(c.index, 0, "index");
        assertEq(c.open, first, "open");
        assertEq(c.prevClose, 0, "prevClose");
        (uint64 secondOpen,) = cal.sessionAt(1);
        assertEq(c.nextOpen, secondOpen, "nextOpen");
    }

    /// INV-CAL-07, INV-CAL-10 (mutants: prevClose guard lo > 1, prevClose from the same session, prevClose dropped)
    /// @notice At every open, prevClose is the close of the session before it (zero for the first session) and
    /// lies strictly before the open.
    function test_PrevCloseOfEverySession() public view {
        uint256 n = cal.sessionCount();
        assertEq(cal.context(cal.firstOpen()).prevClose, 0, "first session");
        for (uint256 i = 1; i < n; ++i) {
            (uint64 o,) = cal.sessionAt(i);
            (, uint64 before) = cal.sessionAt(i - 1);
            SessionCalendar.Context memory c = cal.context(o);
            assertEq(c.index, i, "index");
            assertEq(c.prevClose, before, "prevClose");
            assertLt(c.prevClose, c.open, "gap before the open");
        }
    }

    /// INV-CAL-06
    /// @notice The upper-mid binary search takes at most ceil(log2 n) steps. A lookup on the committed calendar
    /// reads at most 2 * (ceil(log2 587) + 3) = 26 storage slots (array length and word for each search step and
    /// for the session and its two neighbours), at the open, last second and close of every session.
    function test_LookupReadsAreLogarithmic() public {
        uint256 n = cal.sessionCount();
        uint256 maxReads = 2 * (_ceilLog2(n) + 3);
        assertEq(maxReads, 26, "ceil(log2 587) = 10");
        for (uint256 i; i < n; ++i) {
            (uint64 o, uint64 c) = cal.sessionAt(i);
            _assertReadsAtMost(cal, o, maxReads);
            _assertReadsAtMost(cal, c - 1, maxReads);
            _assertReadsAtMost(cal, c, maxReads);
        }
    }

    /// INV-CAL-03
    /// @notice No call, to a getter with arbitrary arguments or to an unknown selector, writes storage after
    /// construction, so the schedule cannot change; there is no fallback, so unknown selectors revert.
    function testFuzz_NoCallWritesStorage(uint8 which, bytes calldata args) public {
        bytes4[6] memory getters = [
            cal.sessionCount.selector,
            cal.firstOpen.selector,
            cal.lastOpen.selector,
            cal.lastClose.selector,
            cal.sessionAt.selector,
            cal.context.selector
        ];
        bool known = which % 7 < 6;
        bytes4 selector = known ? getters[which % 7] : bytes4(keccak256(abi.encode("unknown", args)));
        vm.record();
        (bool ok,) = address(cal).call(abi.encodePacked(selector, args));
        (, bytes32[] memory writes) = vm.accesses(address(cal));
        assertEq(writes.length, 0, "no storage write");
        if (!known) assertFalse(ok, "no fallback");
    }

    // ------------------------------------------------------------ committed data: the real exchange schedule

    /// INV-CAL-11
    /// @notice Rebuilds the regular NYSE schedule from 2026-09-01 to 2028-12-29 from the exchange's rules alone
    /// (weekdays, holidays with their weekend observance, 1:00 p.m. early closes, 09:30 to 16:00 New York time
    /// under US daylight saving time) and requires the committed calendar to be exactly that list.
    function test_CommittedScheduleIsTheNyseRegularSchedule() public view {
        uint256 n = cal.sessionCount();
        uint256 i;
        uint256 holidays;
        uint256 earlyCloses;
        for (uint256 day = _day(2026, 9, 1); day <= _day(2028, 12, 29); ++day) {
            uint256 wd = _weekday(day);
            if (wd == 0 || wd == 6) continue;
            uint256 y = _yearOf(day);
            if (_isNyseHoliday(day, y)) {
                ++holidays;
                continue;
            }
            bool early = _isEarlyClose(day, y);
            if (early) ++earlyCloses;
            uint256 offset = _isDaylightSaving(day, y) ? 4 hours : 5 hours;
            assertLt(i, n, "a trading day is missing");
            (uint64 o, uint64 c) = cal.sessionAt(i);
            assertEq(o, day * 1 days + 9 hours + 30 minutes + offset, "opens 09:30 New York");
            assertEq(c, day * 1 days + (early ? 13 hours : 16 hours) + offset, "closes 16:00 or 13:00 New York");
            ++i;
        }
        assertEq(i, n, "no session on a non-trading day");
        assertEq(holidays, 22, "weekday holidays in range");
        assertEq(earlyCloses, 5, "early closes in range");
    }

    /// INV-CAL-11
    /// @notice Anchors for the rule helpers above: the movable holidays they compute are the published dates.
    function test_HolidayRulesGiveThePublishedDates() public pure {
        assertEq(_easter(2027) - 2, _day(2027, 3, 26), "Good Friday 2027");
        assertEq(_easter(2028) - 2, _day(2028, 4, 14), "Good Friday 2028");
        assertEq(_nthWeekday(2027, 5, 1, 5), _day(2027, 5, 31), "Memorial Day 2027");
        assertEq(_nthWeekday(2028, 11, 4, 4), _day(2028, 11, 23), "Thanksgiving 2028");
        assertEq(_observed(_day(2027, 6, 19)), _day(2027, 6, 18), "Juneteenth 2027 on Friday");
        assertEq(_observed(_day(2027, 7, 4)), _day(2027, 7, 5), "Independence Day 2027 on Monday");
        assertEq(_nthWeekday(2026, 11, 0, 1), _day(2026, 11, 1), "daylight saving ends 2026-11-01");
        assertEq(_nthWeekday(2027, 3, 0, 2), _day(2027, 3, 14), "daylight saving starts 2027-03-14");
        assertFalse(_isNyseHoliday(_day(2027, 12, 31), 2027), "2028 New Year's Day is not observed on 2027-12-31");
    }

    /// INV-CAL-12, INV-X-12
    /// @notice Data facts that SessionRiskPolicy and PriceGate rely on and the constructor does not check: every
    /// close is at least PREP, every session reaches OPEN (PREP + CREDIT_AFTER) and the guard time
    /// (PREP + GUARD_AFTER), and every session is shorter than RESUME_DELAY, so a guardian resume can never land in
    /// the session in which the gate was stopped. Sessions run 210 to 390 minutes; gaps run 17.5 to 92.5 hours.
    function test_CommittedSessionsMeetTheUncheckedDataPreconditions() public view {
        uint256 n = cal.sessionCount();
        uint256 shortest = type(uint256).max;
        uint256 longest;
        uint256 shortestGap = type(uint256).max;
        uint256 longestGap;
        for (uint256 i; i < n; ++i) {
            (uint64 o, uint64 c) = cal.sessionAt(i);
            uint256 len = c - o;
            assertGe(c, SessionTiming.PREP, "close - PREP does not underflow");
            assertGe(len, SessionTiming.PREP + SessionTiming.CREDIT_AFTER, "OPEN is reachable");
            assertGe(len, SessionTiming.PREP + SessionTiming.GUARD_AFTER, "guard time before preparation");
            assertLt(len, SessionTiming.RESUME_DELAY, "shorter than the resume delay");
            if (len < shortest) shortest = len;
            if (len > longest) longest = len;
            if (i + 1 < n) {
                (uint64 next,) = cal.sessionAt(i + 1);
                uint256 gap = next - c;
                if (gap < shortestGap) shortestGap = gap;
                if (gap > longestGap) longestGap = gap;
            }
        }
        assertEq(shortest, 210 minutes, "shortest session (early close)");
        assertEq(longest, 390 minutes, "regular session");
        assertEq(shortestGap, 17 hours + 30 minutes, "overnight");
        assertEq(longestGap, 92 hours + 30 minutes, "long weekend");
    }

    // ------------------------------------------------------------ constructor rules on hand-built calendars

    /// INV-CAL-01 (mutants: ceil -> floor, (count + 3) / 4 -> (count + 4) / 4, != -> <)
    /// @notice For one to nine sessions exactly ceil(count / 4) words deploy, including counts that fill the last
    /// word; one word fewer or one more reverts with WordCountMismatch.
    function test_WordCountIsTheCeilingOfAQuarter() public {
        for (uint256 n = 1; n <= 9; ++n) {
            uint256[] memory words = _pack(_ladder(n));
            assertEq(words.length, (n + 3) / 4);
            SessionCalendar k = new SessionCalendar(words, n);
            assertEq(k.sessionCount(), n, "count");
            (uint64 o, uint64 c) = k.sessionAt(n - 1);
            assertEq(k.lastOpen(), o, "lastOpen");
            assertEq(k.lastClose(), c, "lastClose");

            uint256[] memory fewer = new uint256[](words.length - 1);
            for (uint256 j; j < fewer.length; ++j) {
                fewer[j] = words[j];
            }
            vm.expectRevert(abi.encodeWithSelector(SessionCalendar.WordCountMismatch.selector, fewer.length, n));
            new SessionCalendar(fewer, n);

            uint256[] memory more = new uint256[](words.length + 1);
            for (uint256 j; j < words.length; ++j) {
                more[j] = words[j];
            }
            vm.expectRevert(abi.encodeWithSelector(SessionCalendar.WordCountMismatch.selector, more.length, n));
            new SessionCalendar(more, n);
        }
    }

    /// INV-CAL-01 (mutant: EmptyCalendar check dropped)
    /// @notice Zero sessions revert with EmptyCalendar even with valid words, and counts so large that the word
    /// count overflows never deploy.
    function test_EmptyAndHugeCountsNeverDeploy() public {
        vm.expectRevert(SessionCalendar.EmptyCalendar.selector);
        new SessionCalendar(_pack(_ladder(4)), 0);
        uint256[] memory none = new uint256[](0);
        vm.expectRevert();
        new SessionCalendar(none, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.WordCountMismatch.selector, 0, type(uint256).max - 3));
        new SessionCalendar(none, type(uint256).max - 3);
    }

    /// INV-CAL-02 (mutant: prev < open -> prev <= open)
    /// @notice A session opens at least one second after the previous close, also across a word boundary, and
    /// the first session opens after time zero.
    function test_SessionOpeningAtThePreviousCloseIsRejected() public {
        new SessionCalendar(_pack(_oc(1000, 2000, 2001, 3000)), 2);
        new SessionCalendar(_pack(_oc(1, 2)), 1);

        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(_pack(_oc(1000, 2000, 2000, 3000)), 2);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 0));
        new SessionCalendar(_pack(_oc(0, 2000)), 1);

        // Sessions 0 to 3 fill the first word; session 4, in the second word, opens at session 3's close.
        uint64[] memory oc = _ladder(5);
        oc[8] = oc[7];
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 4));
        new SessionCalendar(_pack(oc), 5);
    }

    /// INV-CAL-02 (mutants: open < close -> open <= close, open < close dropped, check loop skipping the last
    /// session)
    /// @notice A one-second session is accepted; an empty or inverted session is rejected at its index, also when
    /// it is the last one.
    function test_EmptyOrInvertedSessionIsRejected() public {
        new SessionCalendar(_pack(_oc(1000, 1001)), 1);

        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 0));
        new SessionCalendar(_pack(_oc(1000, 1000)), 1);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 0));
        new SessionCalendar(_pack(_oc(1000, 999)), 1);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(_pack(_oc(1000, 2000, 3000, 3000)), 2);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(_pack(_oc(1000, 2000, 3000, 2500)), 2);
    }

    /// INV-CAL-02 (mutants: prev < open dropped, prev never updated)
    /// @notice An overlap is reported at the first session that breaks the order, even when later sessions are
    /// also out of order, and a session may not open inside the previous one.
    function test_OverlapIsReportedAtTheFirstBadIndex() public {
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 2));
        new SessionCalendar(_pack(_oc(1000, 2000, 3000, 4000, 3500, 5000)), 3);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(_pack(_oc(1000, 5000, 2000, 3000, 6000, 7000)), 3);
        vm.expectRevert(abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, 1));
        new SessionCalendar(_pack(_oc(1000, 2000, 1500, 2500, 2400, 2450)), 3);
    }

    /// INV-CAL-04, INV-CAL-05 (mutant: close mask 0xffffffff -> 0x7fffffff)
    /// @notice Each 64-bit slot decodes on its own at every shift (0, 64, 128 and 192 bits): times with bit 31 set
    /// and up to 2^32 - 1 come back unchanged, and all-ones bits in the unused slots neither leak into a session
    /// nor get validated; sessionAt returns them as they are.
    function test_EverySlotDecodesIndependently() public {
        uint64 top = uint64(1) << 31;
        uint64 max32 = type(uint32).max;
        uint64[] memory oc = new uint64[](10);
        (oc[0], oc[1]) = (top - 5, top + 5);
        (oc[2], oc[3]) = (top + 2 ** 28, top + 2 ** 29);
        (oc[4], oc[5]) = (top + 2 ** 30, top + 2 ** 30 + 1);
        (oc[6], oc[7]) = (max32 - 1000, max32 - 500);
        (oc[8], oc[9]) = (max32 - 3, max32);
        uint256[] memory words = _pack(oc);
        words[1] |= type(uint256).max << 64; // slots 1 to 3 of the last word are unused
        SessionCalendar k = new SessionCalendar(words, 5);

        for (uint256 i; i < 5; ++i) {
            (uint64 o, uint64 c) = k.sessionAt(i);
            assertEq(o, oc[2 * i], "open");
            assertEq(c, oc[2 * i + 1], "close");
        }
        for (uint256 i = 5; i < 8; ++i) {
            (uint64 o, uint64 c) = k.sessionAt(i);
            assertEq(o, max32, "unused slot open");
            assertEq(c, max32, "unused slot close");
        }
        vm.expectRevert(stdError.indexOOBError);
        k.sessionAt(8);
        assertEq(k.firstOpen(), top - 5, "firstOpen");
        assertEq(k.lastOpen(), max32 - 3, "lastOpen");
        assertEq(k.lastClose(), max32, "lastClose");

        SessionCalendar.Context memory c0 = k.context(top);
        assertTrue(c0.covered && c0.inSession, "session 0 across bit 31");
        assertEq(c0.close, top + 5, "close");
        assertEq(c0.nextOpen, top + 2 ** 28, "nextOpen");
        SessionCalendar.Context memory c4 = k.context(max32 - 1);
        assertFalse(c4.covered, "last session");
        assertTrue(c4.inSession, "in session");
        assertEq(c4.index, 4, "index");
        assertEq(c4.prevClose, max32 - 500, "prevClose");
        _assertZero(k.context(max32));
        _assertZero(k.context(uint64(max32) + 1));
    }

    /// INV-CAL-06, INV-CAL-08 (mutants: search upper bound sessionCount or sessionCount - 2, coverage that
    /// includes the last session)
    /// @notice With one session the search loop never runs: the session is found at every second inside it and
    /// is never covered. The unused slots hold a plausible session that must never be read.
    function test_SingleSessionCalendarIsNeverCovered() public {
        uint256[] memory words = _pack(_oc(1000, 2000));
        words[0] += (uint256(1200) * 2 ** 32 + 1300) * 2 ** 64;
        SessionCalendar k = new SessionCalendar(words, 1);
        assertEq(k.firstOpen(), 1000);
        assertEq(k.lastOpen(), 1000);
        assertEq(k.lastClose(), 2000);
        uint64[4] memory inside = [uint64(1000), 1250, 1500, 1999];
        for (uint256 j; j < inside.length; ++j) {
            SessionCalendar.Context memory c = k.context(inside[j]);
            assertFalse(c.covered, "never covered");
            assertTrue(c.inSession, "in session");
            assertEq(c.index, 0, "index");
            assertEq(c.open, 1000, "open");
            assertEq(c.close, 2000, "close");
            assertEq(c.prevClose, 0, "prevClose");
            assertEq(c.nextOpen, 0, "nextOpen");
        }
        _assertZero(k.context(0));
        _assertZero(k.context(999));
        _assertZero(k.context(2000));
        _assertZero(k.context(type(uint64).max));
    }

    /// INV-CAL-06, INV-CAL-07, INV-CAL-08, INV-CAL-09
    /// @notice Two sessions, [10, 20) and [30, 40), with plausible sessions in the unused slots: context at every
    /// second from 0 to 45 and at uint64 max equals the hand-written schedule.
    function test_TwoSessionCalendarAtEverySecond() public {
        uint256[] memory words = _pack(_oc(10, 20, 30, 40));
        words[0] += (uint256(11) * 2 ** 32 + 12) * 2 ** 128 + (uint256(25) * 2 ** 32 + 26) * 2 ** 192;
        SessionCalendar k = new SessionCalendar(words, 2);
        for (uint64 t; t <= 45; ++t) {
            SessionCalendar.Context memory c = k.context(t);
            if (t < 10 || t >= 40) {
                _assertZero(c);
                continue;
            }
            bool second = t >= 30;
            assertEq(c.covered, !second, "covered");
            assertEq(c.inSession, t < 20 || second, "inSession");
            assertEq(c.index, second ? 1 : 0, "index");
            assertEq(c.open, second ? 30 : 10, "open");
            assertEq(c.close, second ? 40 : 20, "close");
            assertEq(c.prevClose, second ? 20 : 0, "prevClose");
            assertEq(c.nextOpen, second ? 0 : 30, "nextOpen");
        }
        _assertZero(k.context(type(uint64).max));
    }

    // ------------------------------------------------------------ helpers

    function _assertZero(SessionCalendar.Context memory c) internal pure {
        assertFalse(c.covered, "zero covered");
        assertFalse(c.inSession, "zero inSession");
        assertEq(c.index, 0, "zero index");
        assertEq(c.open, 0, "zero open");
        assertEq(c.close, 0, "zero close");
        assertEq(c.prevClose, 0, "zero prevClose");
        assertEq(c.nextOpen, 0, "zero nextOpen");
    }

    function _assertReadsAtMost(SessionCalendar k, uint64 t, uint256 maxReads) internal {
        vm.record();
        k.context(t);
        (bytes32[] memory reads,) = vm.accesses(address(k));
        assertLe(reads.length, maxReads, "storage reads per lookup");
        if (t >= k.firstOpen() && t < k.lastClose()) assertGe(reads.length, 2, "the lookup reads the words");
    }

    function _ceilLog2(uint256 n) internal pure returns (uint256 k) {
        while ((uint256(1) << k) < n) ++k;
    }

    /// @dev Packs sessions given as [open0, close0, open1, close1, ...]: session i goes to slot i % 4 of word
    /// i / 4 as open * 2^32 + close. Multiplication instead of shifts keeps it independent of the decoder.
    function _pack(uint64[] memory oc) internal pure returns (uint256[] memory words) {
        uint256 n = oc.length / 2;
        words = new uint256[]((n + 3) / 4);
        for (uint256 i; i < n; ++i) {
            words[i / 4] += (uint256(oc[2 * i]) * 2 ** 32 + oc[2 * i + 1]) * 2 ** (64 * (i % 4));
        }
    }

    /// @dev n ordered sessions: [1000 (i + 1), 1000 (i + 1) + 500).
    function _ladder(uint256 n) internal pure returns (uint64[] memory oc) {
        oc = new uint64[](2 * n);
        for (uint256 i; i < n; ++i) {
            oc[2 * i] = uint64(1000 * (i + 1));
            oc[2 * i + 1] = uint64(1000 * (i + 1) + 500);
        }
    }

    function _oc(uint64 o0, uint64 c0) internal pure returns (uint64[] memory oc) {
        oc = new uint64[](2);
        (oc[0], oc[1]) = (o0, c0);
    }

    function _oc(uint64 o0, uint64 c0, uint64 o1, uint64 c1) internal pure returns (uint64[] memory oc) {
        oc = new uint64[](4);
        (oc[0], oc[1], oc[2], oc[3]) = (o0, c0, o1, c1);
    }

    function _oc(uint64 o0, uint64 c0, uint64 o1, uint64 c1, uint64 o2, uint64 c2)
        internal
        pure
        returns (uint64[] memory oc)
    {
        oc = new uint64[](6);
        (oc[0], oc[1], oc[2], oc[3], oc[4], oc[5]) = (o0, c0, o1, c1, o2, c2);
    }

    /// @dev Days since 1970-01-01 of a Gregorian date (days_from_civil, for years from 1970).
    function _day(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function _yearOf(uint256 day) internal pure returns (uint256 y) {
        y = 1970 + day / 366;
        while (_day(y + 1, 1, 1) <= day) ++y;
    }

    /// @dev 0 = Sunday; 1970-01-01 was a Thursday.
    function _weekday(uint256 day) internal pure returns (uint256) {
        return (day + 4) % 7;
    }

    /// @dev The nth weekday `wd` (0 = Sunday) of month m; nth = 5 means the last one.
    function _nthWeekday(uint256 y, uint256 m, uint256 wd, uint256 nth) internal pure returns (uint256) {
        if (nth == 5) {
            uint256 last = (m == 12 ? _day(y + 1, 1, 1) : _day(y, m + 1, 1)) - 1;
            return last - (_weekday(last) + 7 - wd) % 7;
        }
        uint256 first = _day(y, m, 1);
        return first + (wd + 7 - _weekday(first)) % 7 + 7 * (nth - 1);
    }

    /// @dev A fixed-date holiday on a Saturday is observed on the Friday before, on a Sunday the Monday after.
    function _observed(uint256 day) internal pure returns (uint256) {
        uint256 wd = _weekday(day);
        return wd == 6 ? day - 1 : wd == 0 ? day + 1 : day;
    }

    /// @dev Easter Sunday, anonymous Gregorian algorithm.
    function _easter(uint256 y) internal pure returns (uint256) {
        uint256 a = y % 19;
        uint256 b = y / 100;
        uint256 c = y % 100;
        uint256 h = (19 * a + b - b / 4 - (b - (b + 8) / 25 + 1) / 3 + 15) % 30;
        uint256 l = (32 + 2 * (b % 4) + 2 * (c / 4) - h - c % 4) % 7;
        uint256 m = (a + 11 * h + 22 * l) / 451;
        uint256 x = h + l + 114 - 7 * m;
        return _day(y, x / 31, x % 31 + 1);
    }

    /// @dev NYSE holidays: New Year's Day (not moved to the Friday before when it falls on a Saturday), Martin
    /// Luther King Jr. Day, Washington's Birthday, Good Friday, Memorial Day, Juneteenth, Independence Day, Labor
    /// Day, Thanksgiving and Christmas.
    function _isNyseHoliday(uint256 day, uint256 y) internal pure returns (bool) {
        uint256 newYear = _day(y, 1, 1);
        if (_weekday(newYear) == 0) newYear += 1;
        return day == newYear || day == _nthWeekday(y, 1, 1, 3) || day == _nthWeekday(y, 2, 1, 3)
            || day == _easter(y) - 2 || day == _nthWeekday(y, 5, 1, 5) || day == _observed(_day(y, 6, 19))
            || day == _observed(_day(y, 7, 4)) || day == _nthWeekday(y, 9, 1, 1) || day == _nthWeekday(y, 11, 4, 4)
            || day == _observed(_day(y, 12, 25));
    }

    /// @dev 1:00 p.m. closes: the day after Thanksgiving, and July 3 and December 24 when they are Monday to
    /// Thursday (on a Friday they are the observed holiday).
    function _isEarlyClose(uint256 day, uint256 y) internal pure returns (bool) {
        if (day == _nthWeekday(y, 11, 4, 4) + 1) return true;
        uint256 wd = _weekday(day);
        return wd >= 1 && wd <= 4 && (day == _day(y, 7, 3) || day == _day(y, 12, 24));
    }

    /// @dev US daylight saving time: from the second Sunday of March to the first Sunday of November. Sessions
    /// start after the 02:00 switch, so the date alone decides the offset.
    function _isDaylightSaving(uint256 day, uint256 y) internal pure returns (bool) {
        return day >= _nthWeekday(y, 3, 0, 2) && day < _nthWeekday(y, 11, 0, 1);
    }
}
