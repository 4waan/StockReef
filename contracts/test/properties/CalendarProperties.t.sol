// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {stdError} from "forge-std/StdError.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

/// @notice Deploys calendars through an external call, so a test can catch constructor reverts with try/catch.
contract CalendarPropsDeployer {
    function deploy(uint256[] memory words, uint256 count) external returns (SessionCalendar) {
        return new SessionCalendar(words, count);
    }
}

/// @notice Reference model of SessionCalendar. A calendar is two plain arrays, `os` and `cs`, holding the open and
/// close of every slot of every word (sessions first, then the unused tail of the last word), so the model never
/// decodes packed words. It restates the constructor rule and the context lookup as a linear scan.
library CalendarPropsRef {
    uint256 internal constant NONE = type(uint256).max;

    /// @dev Packs slot i into word i / 4 at bit 64 * (i % 4) as open * 2^32 + close, using multiplication rather
    /// than shifts. Every value must be below 2^32.
    function pack(uint64[] memory os, uint64[] memory cs) internal pure returns (uint256[] memory words) {
        words = new uint256[]((os.length + 3) / 4);
        for (uint256 i; i < os.length; ++i) {
            words[i / 4] += (uint256(os[i]) * 2 ** 32 + cs[i]) * 2 ** (64 * (i % 4));
        }
    }

    /// @dev First session that does not open strictly after the previous close (time 0 for the first) or does not
    /// close strictly after its open; NONE when all n sessions are ordered.
    function firstBad(uint64[] memory os, uint64[] memory cs, uint256 n) internal pure returns (uint256) {
        uint256 prev;
        for (uint256 i; i < n; ++i) {
            if (os[i] <= prev || cs[i] <= os[i]) return i;
            prev = cs[i];
        }
        return NONE;
    }

    /// @dev The documented lookup: zero outside [open_0, close_{n-1}); otherwise the last session whose open is at
    /// or before t, found by scanning every session, with its neighbours.
    function context(uint64[] memory os, uint64[] memory cs, uint256 n, uint64 t)
        internal
        pure
        returns (SessionCalendar.Context memory r)
    {
        if (t < os[0] || t >= cs[n - 1]) return r;
        uint256 idx;
        for (uint256 i = 1; i < n; ++i) {
            if (os[i] <= t) idx = i;
        }
        r.index = idx;
        r.open = os[idx];
        r.close = cs[idx];
        r.inSession = t < cs[idx];
        if (idx > 0) r.prevClose = cs[idx - 1];
        if (idx + 1 < n) {
            r.covered = true;
            r.nextOpen = os[idx + 1];
        }
    }

    function same(SessionCalendar.Context memory a, SessionCalendar.Context memory b) internal pure returns (bool) {
        return a.covered == b.covered && a.inSession == b.inSession && a.index == b.index && a.open == b.open
            && a.close == b.close && a.prevClose == b.prevClose && a.nextOpen == b.nextOpen;
    }

    function ceilLog2(uint256 n) internal pure returns (uint256 k) {
        while ((uint256(1) << k) < n) ++k;
    }
}

/// @notice Properties of SessionCalendar over arbitrary valid and invalid calendars, checked against the reference
/// model, and over the committed calendar, checked against sessions.json.
contract CalendarPropertiesTest is Fixtures {
    uint256 internal constant NONE = type(uint256).max;

    SessionCalendar internal real;
    CalendarPropsDeployer internal deployer;
    uint64[] internal opens;
    uint64[] internal closes;

    function setUp() public {
        real = _deployCalendar();
        deployer = new CalendarPropsDeployer();
        (uint256[] memory os, uint256[] memory cs) = _jsonSessions();
        for (uint256 i; i < os.length; ++i) {
            opens.push(uint64(os[i]));
            closes.push(uint64(cs[i]));
        }
    }

    // ------------------------------------------------------------ arbitrary calendars

    /// INV-CAL-01, INV-CAL-02, INV-CAL-03, INV-CAL-04, INV-CAL-05, INV-CAL-06, INV-CAL-07, INV-CAL-08, INV-CAL-09,
    /// INV-CAL-10 (mutants: every constructor ordering, bound, search and mask mutant)
    /// @notice For 1 to 24 sessions in nine shapes, valid and invalid, with zero, all-ones or random bits in the
    /// unused slots: the constructor accepts exactly the ordered calendars and otherwise reverts with
    /// SessionsNotOrdered at the first bad index; an accepted calendar reports the model's bounds and slots, and
    /// context equals the linear scan at every open and close (each +-1), at padding times, at 0, 2^31, 2^32 - 1,
    /// 2^32, uint64 max and at random times, in at most ceil(log2 n) search steps.
    function testFuzz_ArbitraryCalendarsAcceptedIffOrderedAndSearchMatchesLinearScan(
        uint256 seed,
        uint8 nSeed,
        uint8 shapeSeed
    ) public {
        uint256 n = bound(nSeed, 1, 24);
        (uint64[] memory os, uint64[] memory cs) = _model(seed, n, shapeSeed % 9);
        uint256 bad = CalendarPropsRef.firstBad(os, cs, n);

        SessionCalendar k;
        try deployer.deploy(CalendarPropsRef.pack(os, cs), n) returns (SessionCalendar deployed) {
            k = deployed;
        } catch (bytes memory err) {
            assertTrue(bad != NONE, "rejected an ordered calendar");
            assertEq(err, abi.encodeWithSelector(SessionCalendar.SessionsNotOrdered.selector, bad), "first bad index");
            return;
        }
        assertEq(bad, NONE, "accepted an unordered calendar");
        _checkLayout(k, os, cs, n);
        _checkSearch(k, os, cs, n, seed);
    }

    /// INV-CAL-01 (mutants: ceil -> floor, (count + 3) / 4 -> (count + 4) / 4, != -> <)
    /// @notice With ordered sessions in every slot, so that only the counts can fail: zero sessions revert with
    /// EmptyCalendar, any word count other than ceil(count / 4) reverts with WordCountMismatch(words, count), and
    /// the exact word count deploys with the right last session, whatever count % 4 is.
    function testFuzz_WordCountMustBeTheCeilingOfAQuarter(uint256 countSeed, uint256 lenSeed) public {
        uint256 count = countSeed % 65;
        uint256 exact = (count + 3) / 4;
        uint256 mode = lenSeed % 4;
        uint256 len =
            mode == 0 ? exact : mode == 1 ? exact + 1 : mode == 2 && exact > 0 ? exact - 1 : (lenSeed / 4) % 20;
        uint64[] memory os = new uint64[](len * 4);
        uint64[] memory cs = new uint64[](len * 4);
        for (uint256 i; i < len * 4; ++i) {
            os[i] = uint64(100 * (i + 1));
            cs[i] = uint64(100 * (i + 1) + 50);
        }
        uint256[] memory words = CalendarPropsRef.pack(os, cs);

        if (count == 0) {
            vm.expectRevert(SessionCalendar.EmptyCalendar.selector);
            deployer.deploy(words, count);
        } else if (len != exact) {
            vm.expectRevert(abi.encodeWithSelector(SessionCalendar.WordCountMismatch.selector, len, count));
            deployer.deploy(words, count);
        } else {
            SessionCalendar k = deployer.deploy(words, count);
            assertEq(k.sessionCount(), count, "count");
            assertEq(k.lastOpen(), os[count - 1], "lastOpen");
            assertEq(k.lastClose(), cs[count - 1], "lastClose");
        }
    }

    /// INV-CAL-13
    /// @notice Every accepted calendar has lastClose >= 2 * sessionCount, because its times strictly increase from
    /// at least 1, and lastClose < 2^32. So sessionCount < 2^31 and the uint32 session id index + 1 (PriceGate
    /// admissions and outages, RepaymentEscrow spends) never truncates. The densest calendar meets the bound.
    function testFuzz_AcceptedCalendarsHoldFewerThan2pow31Sessions(uint256 seed, uint8 nSeed, uint8 shapeSeed) public {
        uint256 n = bound(nSeed, 1, 40);
        uint256 shape = shapeSeed % 9;
        (uint64[] memory os, uint64[] memory cs) = _model(seed, n, shape);
        try deployer.deploy(CalendarPropsRef.pack(os, cs), n) returns (SessionCalendar k) {
            assertGe(k.lastClose(), 2 * k.sessionCount(), "lastClose >= 2 * count");
            assertLt(k.lastClose(), 2 ** 32, "32-bit times");
            assertLt(k.sessionCount(), 2 ** 31, "fewer than 2^31 sessions");
            if (shape == 2) assertEq(k.lastClose(), 2 * n, "the densest calendar meets the bound");
            for (uint256 i; i < n; ++i) {
                (uint64 o, uint64 c) = k.sessionAt(i);
                assertGe(o, 2 * i + 1, "open_i >= 2i + 1");
                assertGe(c, 2 * i + 2, "close_i >= 2i + 2");
                SessionCalendar.Context memory x = k.context(o);
                assertEq(uint256(uint32(x.index + 1)), x.index + 1, "session id fits 32 bits");
            }
        } catch {
            assertTrue(CalendarPropsRef.firstBad(os, cs, n) != NONE, "rejected an ordered calendar");
        }
    }

    // ------------------------------------------------------------ the committed calendar

    /// INV-CAL-06, INV-CAL-07, INV-CAL-08, INV-CAL-09, INV-CAL-10
    /// @notice On the committed calendar, context equals the linear scan over sessions.json at any uint64 time, at
    /// times spread over the schedule and at every open and close +-2 seconds.
    function testFuzz_CommittedCalendarMatchesLinearScan(uint256 seed) public view {
        uint64[] memory os = opens;
        uint64[] memory cs = closes;
        uint64 t = _pickTime(seed, os, cs);
        SessionCalendar.Context memory got = real.context(t);
        _assertSame(got, CalendarPropsRef.context(os, cs, os.length, t));
        _assertWellFormed(got, t, os[0], os[os.length - 1]);
    }

    /// INV-CAL-06, INV-CAL-08, INV-CAL-09, INV-CAL-13
    /// @notice context never reverts for any uint64 time; it is covered exactly in [firstOpen, lastOpen), the
    /// all-zero struct outside [firstOpen, lastClose), the last session in [lastOpen, lastClose), and its index
    /// plus one always fits the 32-bit session id.
    function testFuzz_CommittedCoverageIsFirstOpenToLastOpen(uint64 t) public view {
        SessionCalendar.Context memory c = real.context(t);
        uint256 n = real.sessionCount();
        uint64 first = real.firstOpen();
        uint64 lastOpen = real.lastOpen();
        uint64 lastClose = real.lastClose();
        assertEq(c.covered, t >= first && t < lastOpen, "covered iff firstOpen <= t < lastOpen");
        if (t < first || t >= lastClose) {
            assertFalse(c.inSession, "zero inSession");
            assertEq(c.index, 0, "zero index");
            assertEq(c.open, 0, "zero open");
            assertEq(c.close, 0, "zero close");
            assertEq(c.prevClose, 0, "zero prevClose");
            assertEq(c.nextOpen, 0, "zero nextOpen");
        } else {
            assertLt(c.index, n, "index in range");
            assertLe(c.open, t, "open <= t");
            assertEq(c.index + 1 == n, t >= lastOpen, "last session exactly from lastOpen");
        }
        assertEq(uint256(uint32(c.index + 1)), c.index + 1, "session id fits 32 bits");
    }

    /// INV-CAL-06, INV-CAL-07
    /// @notice Inside the schedule the index never moves backwards in time: from t1 to t2 >= t1 it advances by
    /// exactly the number of opens passed, and two times with the same index see the same session, with t2 in
    /// session only if t1 is.
    function testFuzz_CommittedIndexAdvancesByTheOpensPassed(uint64 t1, uint64 t2) public view {
        uint64[] memory os = opens;
        uint64 lo = real.firstOpen();
        uint64 hi = real.lastClose() - 1;
        t1 = uint64(bound(t1, lo, hi));
        if (t2 % 2 == 1) {
            t2 = uint64(bound(uint256(t1) + (t2 / 2) % 4 days, lo, hi));
        } else {
            t2 = uint64(bound(t2, lo, hi));
        }
        if (t1 > t2) (t1, t2) = (t2, t1);
        SessionCalendar.Context memory c1 = real.context(t1);
        SessionCalendar.Context memory c2 = real.context(t2);
        uint256 passed;
        for (uint256 i = 1; i < os.length; ++i) {
            if (os[i] > t1 && os[i] <= t2) ++passed;
        }
        assertEq(c2.index - c1.index, passed, "index advances by the opens passed");
        if (passed == 0) {
            assertEq(c1.open, c2.open, "same open");
            assertEq(c1.close, c2.close, "same close");
            assertEq(c1.prevClose, c2.prevClose, "same prevClose");
            assertEq(c1.nextOpen, c2.nextOpen, "same nextOpen");
            assertEq(c1.covered, c2.covered, "same coverage");
            if (c2.inSession) assertTrue(c1.inSession, "a session is one interval");
        }
    }

    /// INV-X-12
    /// @notice A guardian resume comes at least RESUME_DELAY after the stop it ends. Wherever inside a committed
    /// session the stop happens, the earliest resume is past that session's close, so it can never fall inside
    /// the stopped session.
    function testFuzz_ResumeDelayAlwaysLeavesTheStoppedSession(uint256 sessionSeed, uint64 offset, uint64 extra)
        public
        view
    {
        uint256 i = sessionSeed % opens.length;
        uint64 o = opens[i];
        uint64 c = closes[i];
        uint64 s = uint64(bound(offset, o, c - 1));
        uint64 r = s + SessionTiming.RESUME_DELAY + uint64(bound(extra, 0, 7 days));
        SessionCalendar.Context memory atStop = real.context(s);
        assertTrue(atStop.inSession, "stopped in session");
        assertEq(atStop.index, i, "stopped session");
        SessionCalendar.Context memory atResume = real.context(r);
        assertGt(r, c, "resume after the stopped session's close");
        assertFalse(atResume.inSession && atResume.index == i, "resume outside the stopped session");
        if (r < real.lastClose()) assertGe(atResume.index, i, "resume at or after the stopped session");
    }

    // ------------------------------------------------------------ helpers

    function _checkLayout(SessionCalendar k, uint64[] memory os, uint64[] memory cs, uint256 n) internal {
        assertEq(k.sessionCount(), n, "sessionCount");
        assertEq(k.firstOpen(), os[0], "firstOpen");
        assertEq(k.lastOpen(), os[n - 1], "lastOpen");
        assertEq(k.lastClose(), cs[n - 1], "lastClose");
        // Every slot reads back exactly, the unused tail of the last word included (it is never validated).
        for (uint256 i; i < os.length; ++i) {
            (uint64 o, uint64 c) = k.sessionAt(i);
            assertEq(o, os[i], "slot open");
            assertEq(c, cs[i], "slot close");
        }
        vm.expectRevert(stdError.indexOOBError);
        k.sessionAt(os.length);
    }

    function _checkSearch(SessionCalendar k, uint64[] memory os, uint64[] memory cs, uint256 n, uint256 seed) internal {
        uint256 maxReads = 2 * (CalendarPropsRef.ceilLog2(n) + 3);
        uint64[8] memory fixedTimes = [
            uint64(0),
            1,
            uint64(1) << 31,
            type(uint32).max,
            uint64(type(uint32).max) + 1,
            type(uint64).max,
            uint64(_rand(seed, 9000)),
            uint64(_rand(seed, 9001) % (uint256(cs[n - 1]) + 2))
        ];
        for (uint256 j; j < fixedTimes.length; ++j) {
            _probe(k, os, cs, n, fixedTimes[j], maxReads);
        }
        for (uint256 i; i < os.length; ++i) {
            uint64 o = os[i];
            uint64 c = cs[i];
            if (o > 0) _probe(k, os, cs, n, o - 1, maxReads);
            _probe(k, os, cs, n, o, maxReads);
            _probe(k, os, cs, n, o + 1, maxReads);
            if (c > 0) _probe(k, os, cs, n, c - 1, maxReads);
            _probe(k, os, cs, n, c, maxReads);
            _probe(k, os, cs, n, c + 1, maxReads);
        }
    }

    function _probe(SessionCalendar k, uint64[] memory os, uint64[] memory cs, uint256 n, uint64 t, uint256 maxReads)
        internal
    {
        vm.record();
        SessionCalendar.Context memory got = k.context(t);
        (bytes32[] memory reads,) = vm.accesses(address(k));
        assertLe(reads.length, maxReads, "at most ceil(log2 n) search steps");
        _assertSame(got, CalendarPropsRef.context(os, cs, n, t));
        _assertWellFormed(got, t, os[0], os[n - 1]);
    }

    /// @dev INV-CAL-08 and INV-CAL-10 on one lookup.
    function _assertWellFormed(SessionCalendar.Context memory c, uint64 t, uint64 firstOpen, uint64 lastOpen)
        internal
        pure
    {
        assertEq(c.covered, t >= firstOpen && t < lastOpen, "covered iff firstOpen <= t < lastOpen");
        if (c.covered) {
            assertLt(c.prevClose, c.open, "prevClose < open");
            assertLe(c.open, t, "open <= t");
            assertLt(t, c.nextOpen, "t < nextOpen");
            assertLt(c.close, c.nextOpen, "close < nextOpen");
            if (!c.inSession) assertLe(c.close, t, "closed means close <= t");
        }
    }

    function _assertSame(SessionCalendar.Context memory got, SessionCalendar.Context memory want) internal pure {
        assertEq(got.covered, want.covered, "covered");
        assertEq(got.inSession, want.inSession, "inSession");
        assertEq(got.index, want.index, "index");
        assertEq(got.open, want.open, "open");
        assertEq(got.close, want.close, "close");
        assertEq(got.prevClose, want.prevClose, "prevClose");
        assertEq(got.nextOpen, want.nextOpen, "nextOpen");
    }

    function _rand(uint256 seed, uint256 k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, k)));
    }

    /// @dev Slots of a calendar with n sessions, padded to whole words, in one of nine shapes: 0 random 32-bit
    /// halves; 1 ordered over the whole 32-bit range; 2 the densest calendar (every session and gap one second,
    /// from time 1); 3 ordered and ending exactly at 2^32 - 1; 4 to 8 ordered with one defect at a random index:
    /// opening at the previous close (or at 0), empty, inverted, opening one second inside the previous session
    /// (or at 0), or a random slot. The unused slots hold zero, all ones or random halves.
    function _model(uint256 seed, uint256 n, uint256 shape)
        internal
        pure
        returns (uint64[] memory os, uint64[] memory cs)
    {
        uint256 slots = (n + 3) / 4 * 4;
        os = new uint64[](slots);
        cs = new uint64[](slots);
        if (shape == 0) {
            for (uint256 i; i < slots; ++i) {
                (os[i], cs[i]) = _halves(_rand(seed, i));
            }
            return (os, cs);
        }
        bool dense = shape == 2 || (shape >= 4 && _rand(seed, 7000) % 4 == 0);
        uint256 step = (2 ** 32 - 2) / (2 * n + 1);
        uint256 t = dense ? 1 : 1 + _rand(seed, 1000) % step;
        for (uint256 i; i < n; ++i) {
            os[i] = uint64(t);
            t += dense ? 1 : 1 + _rand(seed, 2000 + i) % step;
            cs[i] = uint64(t);
            t += dense ? 1 : 1 + _rand(seed, 3000 + i) % step;
        }
        if (shape == 3) {
            uint64 shift = type(uint32).max - cs[n - 1];
            for (uint256 i; i < n; ++i) {
                os[i] += shift;
                cs[i] += shift;
            }
        }
        uint256 j = _rand(seed, 5000) % n;
        if (shape == 4) os[j] = j == 0 ? 0 : cs[j - 1];
        else if (shape == 5) cs[j] = os[j];
        else if (shape == 6) cs[j] = os[j] - 1;
        else if (shape == 7) os[j] = j == 0 ? 0 : cs[j - 1] - 1;
        else if (shape == 8) (os[j], cs[j]) = _halves(_rand(seed, 5001));

        uint256 padding = _rand(seed, 6000) % 3;
        for (uint256 i = n; i < slots; ++i) {
            if (padding == 1) (os[i], cs[i]) = (type(uint32).max, type(uint32).max);
            else if (padding == 2) (os[i], cs[i]) = _halves(_rand(seed, 6001 + i));
        }
    }

    function _halves(uint256 r) internal pure returns (uint64, uint64) {
        return (uint64(r % 2 ** 32), uint64((r / 2 ** 32) % 2 ** 32));
    }

    /// @dev Any uint64, a time spread over the schedule +-3 days, or an open or close of a random session +-2 s.
    function _pickTime(uint256 seed, uint64[] memory os, uint64[] memory cs) internal pure returns (uint64) {
        uint256 n = os.length;
        uint256 mode = seed % 4;
        uint256 r = seed / 4;
        if (mode == 0) return uint64(r);
        if (mode == 1) return uint64(os[0] - 3 days + r % (uint256(cs[n - 1]) - os[0] + 6 days));
        uint256 i = r % n;
        uint64 mark = mode == 2 ? os[i] : cs[i];
        return uint64(uint256(mark) + (r / n) % 5 - 2);
    }
}

/// @notice A guardian stop and resume on a PriceGate that runs on the committed calendar.
contract CalendarResumeTest is GateFixture {
    function setUp() public {
        _setUpGate();
    }

    /// INV-X-12
    /// @notice After a session's reopening is admitted and the gate is stopped in it, the earliest resume (24 hours
    /// later) is past that session: the session the clock is in at the resume has no admission, and new credit
    /// waits for a fresh admission, recorded only after the recovery grace and with a feed update after the resume.
    function testFuzz_ResumeNeedsAFreshAdmission(uint256 sessionSeed, uint256 stopSeed, uint256 delaySeed) public {
        uint256 i = bound(sessionSeed, 0, cal.sessionCount() - 12);
        (uint64 o, uint64 c) = cal.sessionAt(i);
        _freshRefresh(o + SessionTiming.ADMIT_AFTER);
        assertEq(gate.admissionFor(i), o + SessionTiming.ADMIT_AFTER, "admitted");

        uint64 s = uint64(bound(stopSeed, o + SessionTiming.ADMIT_AFTER, c - 1));
        _warp(s);
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();

        uint64 r = s + SessionTiming.RESUME_DELAY + uint64(bound(delaySeed, 0, 4 days));
        _pushAt(r, TSLA_400);
        vm.prank(guardian);
        gate.resume();
        gate.refresh();

        SessionCalendar.Context memory ctx = cal.context(r);
        assertTrue(ctx.covered, "inside coverage");
        assertGt(r, c, "past the stopped session");
        assertFalse(ctx.inSession && ctx.index == i, "never inside the stopped session");
        if (ctx.inSession) assertEq(gate.admissionFor(ctx.index), 0, "no admission at the resume");

        // The first time a new admission can be recorded: O + ADMIT_AFTER of the session in progress or the next
        // one, and not before the recovery grace after the resume has passed.
        uint256 j = ctx.inSession ? ctx.index : ctx.index + 1;
        (uint64 oj, uint64 cj) = cal.sessionAt(j);
        uint64 at = oj + SessionTiming.ADMIT_AFTER;
        if (at < r + SessionTiming.RECOVERY_GRACE) at = r + SessionTiming.RECOVERY_GRACE;
        if (at >= cj) {
            ++j;
            (oj,) = cal.sessionAt(j);
            at = oj + SessionTiming.ADMIT_AFTER;
        }
        assertEq(gate.admissionFor(j), 0, "nothing carried over");
        _freshRefresh(at);
        assertEq(gate.admissionFor(j), at, "fresh admission");
        assertGt(at, r, "admitted after the resume");
        assertEq(gate.admissionFor(i), 0, "the stopped session's admission is gone");
    }
}

/// @notice Walks a clock forward through the committed calendar in short steps, exact boundary jumps,
/// multi-session skips and jumps to the end of coverage, and checks every lookup against a two-pointer reference
/// over sessions.json: `passed` counts the opens at or before the clock and only moves forward, so the reference
/// never searches.
contract CalendarWalkHandler is Test {
    SessionCalendar internal cal;
    uint64[] internal opens;
    uint64[] internal closes;
    uint256 internal n;

    uint64 public t;
    uint256 internal passed;
    bool internal hasPrev;
    uint256 internal prevIndex;

    // Ghost records.
    uint256 public mismatches;
    uint256 public backwards;
    uint256 public observations;
    uint256 public sessionsEntered;
    uint256 public boundaryHits;
    uint256 public coveredSeen;
    uint256 public lastSessionSeen;
    uint256 public outsideSeen;
    uint256 public restarts;

    constructor(SessionCalendar cal_, uint256[] memory os, uint256[] memory cs) {
        cal = cal_;
        n = os.length;
        for (uint256 i; i < n; ++i) {
            opens.push(uint64(os[i]));
            closes.push(uint64(cs[i]));
        }
        t = opens[0] - 1 days;
    }

    /// @notice Moves the clock forward by 1 second to 8 hours.
    function step(uint256 dt) external {
        _restartPastTheEnd(dt);
        _moveTo(t + uint64(bound(dt, 1, 8 hours)));
    }

    /// @notice Jumps to the next boundary second after the clock: an open, a close, or the second before either.
    function toBoundary(uint256 which) external {
        _restartPastTheEnd(which);
        uint256 i = passed == 0 ? 0 : passed - 1;
        uint64[4] memory marks = [opens[i] - 1, opens[i], closes[i] - 1, closes[i]];
        uint64 target = marks[which % 4];
        if (target <= t) {
            uint256 next = passed < n ? passed : n - 1;
            target = which % 2 == 0 ? opens[next] : opens[next] - 1;
            if (target <= t) target = closes[n - 1] + uint64(which % 3);
        }
        if (target > t) _moveTo(target);
    }

    /// @notice Skips 1 to 40 sessions ahead, landing from 1 minute before that open to 1 hour after its close. One
    /// call in twelve jumps instead into the day before lastOpen, the last loaded session or the hour after it.
    function skip(uint256 k, uint256 offset) external {
        _restartPastTheEnd(k);
        uint64 target;
        if (k % 12 == 0) {
            target = opens[n - 1] - 1 days + uint64(offset % (closes[n - 1] - opens[n - 1] + 1 days + 1 hours));
        } else {
            uint256 i = (passed == 0 ? 0 : passed - 1) + bound(k, 1, 40);
            if (i >= n) i = n - 1;
            target = opens[i] - 1 minutes + uint64(offset % (closes[i] - opens[i] + 61 minutes));
        }
        if (target > t) _moveTo(target);
    }

    /// @dev Once the clock is an hour past lastClose, starts a new walk: one time in four up to a day before
    /// firstOpen, otherwise an hour before the open of a random session.
    function _restartPastTheEnd(uint256 seed) internal {
        if (t < closes[n - 1] + 1 hours) return;
        t = seed % 4 == 0 ? opens[0] - uint64(1 + (seed / 4) % 1 days) : opens[(seed / 4) % n] - 1 hours;
        passed = 0;
        while (passed < n && opens[passed] <= t) ++passed;
        hasPrev = false;
        ++restarts;
    }

    function _moveTo(uint64 newT) internal {
        t = newT;
        while (passed < n && opens[passed] <= t) ++passed;
        _observe();
    }

    function _observe() internal {
        SessionCalendar.Context memory got = cal.context(t);
        ++observations;
        SessionCalendar.Context memory want;
        bool inRange = passed > 0 && t < closes[n - 1];
        if (inRange) {
            uint256 i = passed - 1;
            want.index = i;
            want.open = opens[i];
            want.close = closes[i];
            want.inSession = t < closes[i];
            if (i > 0) want.prevClose = closes[i - 1];
            if (i + 1 < n) {
                want.covered = true;
                want.nextOpen = opens[i + 1];
            }
        }
        if (!CalendarPropsRef.same(got, want)) ++mismatches;
        if (!inRange) {
            ++outsideSeen;
            hasPrev = false;
            return;
        }
        if (hasPrev) {
            if (got.index < prevIndex) ++backwards;
            else sessionsEntered += got.index - prevIndex;
        }
        if (got.covered) ++coveredSeen;
        else ++lastSessionSeen;
        if (t == got.open || t == got.close || t + 1 == got.close || t + 1 == got.nextOpen) ++boundaryHits;
        hasPrev = true;
        prevIndex = got.index;
    }
}

/// @notice Stateful walk through the committed calendar: every lookup equals the reference and the index never
/// moves backwards as the clock moves forward.
contract CalendarWalkInvariantsTest is Fixtures {
    CalendarWalkHandler internal handler;

    function setUp() public {
        SessionCalendar cal = _deployCalendar();
        (uint256[] memory os, uint256[] memory cs) = _jsonSessions();
        handler = new CalendarWalkHandler(cal, os, cs);
        bytes4[] memory actions = new bytes4[](3);
        actions[0] = CalendarWalkHandler.step.selector;
        actions[1] = CalendarWalkHandler.toBoundary.selector;
        actions[2] = CalendarWalkHandler.skip.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        assertGt(handler.observations(), 0, "the walk made lookups");
        console.log("observations", handler.observations(), "sessions entered", handler.sessionsEntered());
        console.log("boundary hits", handler.boundaryHits(), "covered", handler.coveredSeen());
        console.log("last session", handler.lastSessionSeen(), "outside", handler.outsideSeen());
        console.log("restarts", handler.restarts());
    }

    /// INV-CAL-06, INV-CAL-07, INV-CAL-08, INV-CAL-09
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 200
    function invariant_contextMatchesTheWalkingReference() public view {
        assertEq(handler.mismatches(), 0, "context differs from the reference");
    }

    /// INV-CAL-06
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 200
    function invariant_indexNeverMovesBackwards() public view {
        assertEq(handler.backwards(), 0, "index moved backwards in time");
    }
}
