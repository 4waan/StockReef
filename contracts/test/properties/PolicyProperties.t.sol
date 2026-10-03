// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {stdError} from "forge-std/StdError.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {IClock} from "../../src/interfaces/IClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

// ================================================================ stand-ins for the gate

/// @notice Clock a test sets directly.
contract PolicyFakeClock is IClock {
    uint64 public t;

    function set(uint64 t_) external {
        t = t_;
    }

    function time() external view returns (uint64) {
        return t;
    }

    function isSimulation() external pure returns (bool) {
        return true;
    }
}

/// @notice The PriceGate members SessionRiskPolicy reads (calendar, clock, admissionFor, quote), with every value
/// set by the test, so any session can carry any admission record and any quote.
contract PolicyFakeGate {
    SessionCalendar public calendar;
    IClock public clock;
    mapping(uint256 => uint64) internal _admission;
    PriceGate.Quote internal _quote;

    constructor(SessionCalendar calendar_, IClock clock_) {
        calendar = calendar_;
        clock = clock_;
    }

    function setAdmission(uint256 index, uint64 at) external {
        _admission[index] = at;
    }

    function admissionFor(uint256 index) external view returns (uint64) {
        return _admission[index];
    }

    function setQuote(PriceGate.Quote memory q) external {
        _quote = q;
    }

    function quote() external view returns (PriceGate.Quote memory) {
        return _quote;
    }
}

// ================================================================ rules every snapshot keeps

/// @notice The snapshot rules of docs/SPEC.md §3 and §6 (appendix R1, R17) as one checker, shared by the fuzz
/// tests and the stateful suite. It returns the first rule a snapshot breaks, or an empty string.
abstract contract PolicyRules {
    SessionRiskPolicy.State internal constant S_OPEN = SessionRiskPolicy.State.OPEN;
    SessionRiskPolicy.State internal constant S_PRE = SessionRiskPolicy.State.PRE_CLOSE;
    SessionRiskPolicy.State internal constant S_FINAL = SessionRiskPolicy.State.FINAL_WINDOW;
    SessionRiskPolicy.State internal constant S_CLOSED = SessionRiskPolicy.State.CLOSED;
    SessionRiskPolicy.State internal constant S_WAIT = SessionRiskPolicy.State.REOPEN_WAIT;
    SessionRiskPolicy.State internal constant S_RECOVERY = SessionRiskPolicy.State.REOPEN_RECOVERY;
    SessionRiskPolicy.State internal constant S_GUARDED = SessionRiskPolicy.State.GUARDED;
    SessionRiskPolicy.ClosureClass internal constant K_OVERNIGHT = SessionRiskPolicy.ClosureClass.OVERNIGHT;
    SessionRiskPolicy.ClosureClass internal constant K_EXTENDED = SessionRiskPolicy.ClosureClass.EXTENDED;

    /// @dev Permission row of an effective state: borrow, trim, buffer, lender.
    function _flagsOf(SessionRiskPolicy.State st) internal pure returns (bool, bool, bool, bool) {
        if (st == S_OPEN) return (true, true, false, true);
        if (st == S_PRE) return (true, true, true, false);
        if (st == S_FINAL) return (false, true, true, false);
        if (st == S_RECOVERY) return (false, true, true, false); // buffers in recovery: appendix R20
        return (false, false, false, false);
    }

    function _anyPermission(SessionRiskPolicy.Snapshot memory s) internal pure returns (bool) {
        return s.canBorrow || s.canTrim || s.canBuffer || s.lenderOpen;
    }

    /// @dev `realAdmission`: the admission came from the real gate, so it lies in [O + 5 min, C) and not after t.
    function _brokenRule(SessionRiskPolicy.Snapshot memory s, uint64 lastOpen, bool realAdmission)
        internal
        pure
        returns (string memory)
    {
        bool any = _anyPermission(s);
        if (s.state != s.phase && s.state != S_GUARDED) return "state differs from the phase only by GUARDED";
        (bool b, bool tr, bool bu, bool l) = _flagsOf(s.state);
        // The last covered session (its next open is wind-down) gives no new credit: appendix R19.
        bool terminal = s.covered && s.nextOpen == lastOpen;
        if (terminal) b = false;
        if (s.canBorrow != b || s.canTrim != tr || s.canBuffer != bu || s.lenderOpen != l) {
            return "permissions follow the effective state";
        }
        bool closingClassPhase = s.phase == S_PRE || s.phase == S_FINAL || s.phase == S_CLOSED || s.phase == S_OPEN;
        if (terminal && closingClassPhase && s.closureClass != K_EXTENDED) return "the last covered close is EXTENDED";
        if (s.windDown != (s.time >= lastOpen)) return "windDown iff t >= lastOpen";
        if (s.windDown && (s.covered || any)) return "wind-down is uncovered and allows nothing";
        if (s.reasons & Reasons.STOPPED != 0 && (s.state != S_GUARDED || any)) return "a stop is GUARDED";
        if (s.ltWad < 0.7e18 || s.ltWad > 0.8e18) return "LT in [70%, 80%]";
        if (s.targetWad != 0.75e18 && s.targetWad != 0.72e18 && s.targetWad != 0.65e18) return "target values";
        if (s.ltWad < s.targetWad + 0.05e18) return "LT - target >= 5%";
        if (s.targetWad * 105 >= 100e18) return "target * 1.05 < 1";
        if (!s.canBorrow && s.borrowLimitWad != 0) return "B is zero unless borrowing";
        if (
            s.canBorrow
                && (s.borrowLimitWad + 0.05e18 != s.ltWad
                    || s.borrowLimitWad > 0.75e18
                    || s.borrowLimitWad < s.targetWad)
        ) return "B = LT - 5%, at most 75%, at least the target";
        if (!s.covered) return _uncoveredRule(s);
        return _coveredRule(s, any, realAdmission);
    }

    function _uncoveredRule(SessionRiskPolicy.Snapshot memory s) private pure returns (string memory) {
        if (s.state != S_GUARDED || s.phase != S_GUARDED) return "uncovered is GUARDED";
        if (s.closureClass != K_EXTENDED || s.ltWad != 0.7e18 || s.targetWad != 0.65e18) {
            return "uncovered limits are EXTENDED";
        }
        if (
            s.session != 0 || s.open != 0 || s.close != 0 || s.prepAt != 0 || s.finalAt != 0 || s.nextOpen != 0
                || s.admissionAt != 0 || s.creditAt != 0 || s.guardAt != 0
        ) return "uncovered schedule fields are zero";
        return "";
    }

    function _coveredRule(SessionRiskPolicy.Snapshot memory s, bool any, bool realAdmission)
        private
        pure
        returns (string memory)
    {
        uint64 t = s.time;
        if (s.phase == S_GUARDED) return "a covered phase is never GUARDED";
        if (s.prepAt + 2 hours != s.close || s.finalAt + 30 minutes != s.close || s.guardAt != s.open + 30 minutes) {
            return "A = C - 2 h, F = C - 30 min, guardAt = O + 30 min";
        }
        if (t < s.open || t >= s.nextOpen || s.close >= s.nextOpen) return "O <= t < next open, C < next open";
        if ((s.phase == S_CLOSED) != (t >= s.close)) return "CLOSED iff t >= C";
        if ((s.phase == S_WAIT) != (t < s.close && s.admissionAt == 0)) return "REOPEN_WAIT iff unadmitted in session";
        if (s.phase == S_WAIT && t >= s.guardAt && s.state != S_GUARDED) return "GUARDED from O + 30 min";
        if (s.admissionAt == 0 && s.creditAt != 0) return "creditAt is zero until admission";
        if (s.admissionAt != 0) {
            uint64 credit =
                s.open + 15 minutes > s.admissionAt + 10 minutes ? s.open + 15 minutes : s.admissionAt + 10 minutes;
            if (s.creditAt != credit) return "creditAt = max(O + 15 min, admission + 10 min)";
            if (realAdmission) {
                if (s.admissionAt < s.open + 5 minutes || s.admissionAt >= s.close || s.admissionAt > t) {
                    return "a real admission lies in [O + 5 min, C) and not after t";
                }
                if (s.creditAt != s.admissionAt + 10 minutes) return "real admissions get credit 10 min later";
            }
        }
        if (any && (s.reasons != 0 || s.admissionAt == 0 || t >= s.close)) {
            return "a permission needs a usable price, an admission and t < C";
        }
        if (s.canBorrow && (t < s.creditAt || t >= s.finalAt)) return "borrowing within [creditAt, F)";
        if (s.lenderOpen && (t < s.creditAt || t >= s.prepAt)) return "lender window within [creditAt, A)";
        // Reopening recovery, taking the admission record at face value as the policy does (appendix R20).
        bool inRecovery = s.admissionAt != 0 && t >= s.open && t < s.creditAt;
        if (s.canBuffer && !inRecovery && (t < s.prepAt || t < s.creditAt || t >= s.close)) {
            return "buffers within recovery or [max(A, creditAt), C)";
        }
        if (s.canTrim && t >= s.close) return "trims end at C";
        return "";
    }

    function _hash(SessionRiskPolicy.Snapshot memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }
}

// ================================================================ model-based properties on the committed calendar

/// @notice SessionRiskPolicy against an independent model of docs/SPEC.md §3 and §6 written from the calendar
/// JSON, with a fake gate that can give any session any admission record and any quote.
contract PolicyModelTest is Fixtures, PolicyRules {
    SessionCalendar internal cal;
    PolicyFakeClock internal clk;
    PolicyFakeGate internal fg;
    SessionRiskPolicy internal policy;
    uint64[] internal opens;
    uint64[] internal closes;
    uint256 internal n;

    /// @dev What the model expects at one time.
    struct PolicyExpected {
        bool covered;
        bool windDown;
        uint256 index;
        SessionRiskPolicy.State phase;
        SessionRiskPolicy.State state;
        SessionRiskPolicy.ClosureClass cls;
        uint256 lt;
        uint256 b;
        uint256 target;
        uint64 admissionAt;
        uint64 creditAt;
    }

    function setUp() public {
        cal = _deployCalendar();
        clk = new PolicyFakeClock();
        fg = new PolicyFakeGate(cal, clk);
        policy = new SessionRiskPolicy(PriceGate(address(fg)));
        (uint256[] memory o, uint256[] memory c) = _jsonSessions();
        n = o.length;
        for (uint256 i; i < n; ++i) {
            opens.push(uint64(o[i]));
            closes.push(uint64(c[i]));
        }
    }

    // ------------------------------------------------------------ model

    function _gapClass(uint64 gap) internal pure returns (SessionRiskPolicy.ClosureClass) {
        return gap >= 86_400 ? K_EXTENDED : K_OVERNIGHT;
    }

    function _ltF(SessionRiskPolicy.ClosureClass k) internal pure returns (uint256) {
        return k == K_EXTENDED ? 0.7e18 : 0.77e18;
    }

    function _tgt(SessionRiskPolicy.ClosureClass k) internal pure returns (uint256) {
        return k == K_EXTENDED ? 0.65e18 : 0.72e18;
    }

    /// @dev LT on the ramp as floor((0.80 * 5400 - (0.80 - LT_F) * x) / 5400), x seconds after A.
    function _ramp(SessionRiskPolicy.ClosureClass k, uint256 x) internal pure returns (uint256) {
        return (uint256(0.8e18) * 5400 - (0.8e18 - _ltF(k)) * x) / 5400;
    }

    /// @dev Largest index whose open is at or before `t`; `t` must be at or after the first open.
    function _indexAt(uint64 t) internal view returns (uint256 lo) {
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (opens[mid] <= t) lo = mid;
            else hi = mid - 1;
        }
    }

    function _model(uint64 t, uint32 reasons) internal view returns (PolicyExpected memory e) {
        e.windDown = t >= opens[n - 1];
        if (t < opens[0] || t >= opens[n - 1]) {
            _set(e, S_GUARDED, K_EXTENDED, 0.7e18, 0, 0.65e18);
            e.state = S_GUARDED;
            return e;
        }
        e.covered = true;
        e.index = _indexAt(t);
        e.admissionAt = fg.admissionFor(e.index);
        if (e.admissionAt != 0) {
            uint64 o = opens[e.index];
            e.creditAt = o + 15 minutes > e.admissionAt + 10 minutes ? o + 15 minutes : e.admissionAt + 10 minutes;
        }
        _modelPhase(e, t);
        bool priced = e.phase != S_CLOSED && e.phase != S_WAIT;
        bool guarded = reasons & Reasons.STOPPED != 0 || (priced && reasons != 0)
            || (e.phase == S_WAIT && t >= opens[e.index] + 30 minutes);
        e.state = guarded ? S_GUARDED : e.phase;
        if ((e.state != S_OPEN && e.state != S_PRE) || e.index + 2 == n) e.b = 0;
    }

    /// @dev Schedule phase and limits: CLOSED from C, REOPEN_WAIT before admission, REOPEN_RECOVERY before
    /// creditAt (both with the class of the closure that ended at O), then OPEN, PRE_CLOSE and FINAL_WINDOW with
    /// the class of the coming close.
    function _modelPhase(PolicyExpected memory e, uint64 t) internal view {
        uint256 i = e.index;
        uint64 c = closes[i];
        // The last covered close is EXTENDED whatever its gap: wind-down follows it (appendix R19).
        SessionRiskPolicy.ClosureClass closing = i + 2 == n ? K_EXTENDED : _gapClass(opens[i + 1] - c);
        SessionRiskPolicy.ClosureClass opening = i == 0 ? K_EXTENDED : _gapClass(opens[i] - closes[i - 1]);
        if (t >= c) {
            _set(e, S_CLOSED, closing, _ltF(closing), 0, _tgt(closing));
        } else if (e.admissionAt == 0) {
            _set(e, S_WAIT, opening, _ltF(opening), 0, _tgt(opening));
        } else if (t < e.creditAt) {
            _set(e, S_RECOVERY, opening, _ltF(opening), 0, _tgt(opening));
        } else if (t < c - 2 hours) {
            _set(e, S_OPEN, closing, 0.8e18, 0.75e18, 0.75e18);
        } else if (t < c - 30 minutes) {
            uint256 lt = _ramp(closing, t - (c - 2 hours));
            _set(e, S_PRE, closing, lt, lt - 0.05e18 < 0.75e18 ? lt - 0.05e18 : 0.75e18, _tgt(closing));
        } else {
            _set(e, S_FINAL, closing, _ltF(closing), 0, _tgt(closing));
        }
    }

    function _set(
        PolicyExpected memory e,
        SessionRiskPolicy.State phase,
        SessionRiskPolicy.ClosureClass k,
        uint256 lt,
        uint256 b,
        uint256 target
    ) internal pure {
        e.phase = phase;
        e.cls = k;
        e.lt = lt;
        e.b = b;
        e.target = target;
    }

    function _expectModel(SessionRiskPolicy.Snapshot memory s, PriceGate.Quote memory q, uint64 t) internal view {
        PolicyExpected memory e = _model(t, q.reasons);
        assertEq(s.time, t, "time");
        assertEq(s.reasons, q.reasons, "reasons");
        assertEq(s.priceWad, q.priceWad, "price");
        assertEq(s.priceUpdatedAt, q.updatedAt, "price time");
        assertEq(s.covered, e.covered, "covered");
        assertEq(s.windDown, e.windDown, "windDown");
        assertEq(uint256(s.phase), uint256(e.phase), "phase");
        assertEq(uint256(s.state), uint256(e.state), "state");
        assertEq(uint256(s.closureClass), uint256(e.cls), "class");
        assertEq(s.ltWad, e.lt, "LT");
        assertEq(s.borrowLimitWad, e.b, "B");
        assertEq(s.targetWad, e.target, "target");
        assertEq(s.admissionAt, e.admissionAt, "admissionAt");
        assertEq(s.creditAt, e.creditAt, "creditAt");
        (bool b, bool tr, bool bu, bool l) = _flagsOf(e.state);
        if (e.covered && e.index + 2 == n) b = false; // appendix R19
        assertEq(s.canBorrow, b, "canBorrow");
        assertEq(s.canTrim, tr, "canTrim");
        assertEq(s.canBuffer, bu, "canBuffer");
        assertEq(s.lenderOpen, l, "lenderOpen");
        if (e.covered) {
            uint256 i = e.index;
            assertEq(s.session, i, "session");
            assertEq(s.open, opens[i], "O");
            assertEq(s.close, closes[i], "C");
            assertEq(s.prepAt, closes[i] - 2 hours, "A");
            assertEq(s.finalAt, closes[i] - 30 minutes, "F");
            assertEq(s.nextOpen, opens[i + 1], "next open");
            assertEq(s.guardAt, opens[i] + 30 minutes, "guardAt");
        }
    }

    /// @dev bonusFor and trimEligible against the bonus table of docs/SPEC.md §3 at LTVs around every threshold.
    function _expectBonusAndEligibility(SessionRiskPolicy.Snapshot memory s) internal view {
        uint256[10] memory ltvs = [
            uint256(0), 0.65e18, 0.7e18, s.ltWad - 1, s.ltWad, s.ltWad + 1, 0.8e18, 0.8e18 + 1, 1e18, type(uint256).max
        ];
        for (uint256 k; k < ltvs.length; ++k) {
            uint256 expected;
            if (s.canTrim) {
                bool split = s.state == S_PRE || s.state == S_FINAL;
                expected = split && ltvs[k] <= 0.8e18 ? 0.02e18 : 0.05e18;
            }
            assertEq(policy.bonusFor(s, ltvs[k]), expected, "bonus");
            assertEq(policy.trimEligible(s, ltvs[k]), s.canTrim && ltvs[k] > s.ltWad, "eligibility");
        }
    }

    // ------------------------------------------------------------ scenario generation

    /// @dev An admission record for session `i`: none, on time, anywhere in the session, or values the real gate
    /// never records (before O + 5 min, after the close), which the policy takes at face value.
    function _pickAdmission(uint256 i, uint256 seed) internal view returns (uint64) {
        uint64 o = opens[i];
        uint64 len = closes[i] - o;
        uint256 mode = seed % 6;
        seed >>= 8;
        if (mode == 0) return 0;
        if (mode == 1) return o + 5 minutes;
        if (mode == 2) return o + 5 minutes + uint64(seed % (len - 5 minutes));
        if (mode == 3) return o + uint64(seed % 5 minutes);
        if (mode == 4) return closes[i] + uint64(seed % 2 days);
        return o + 5 minutes + uint64(seed % 10 minutes);
    }

    /// @dev A time near a boundary of a random session (within two seconds), uniform over the calendar, or any
    /// uint64; sets the admission record of the session that time falls in.
    function _pickTime(uint256 seed, uint256 admSeed) internal returns (uint64 t) {
        uint256 mode = seed % 8;
        seed >>= 8;
        uint256 i = type(uint256).max;
        if (mode == 0) {
            t = uint64(bound(seed, opens[0] - 3 days, closes[n - 1] + 3 days));
        } else if (mode == 1) {
            t = uint64(seed);
        } else {
            i = seed % n;
            uint64 adm = _pickAdmission(i, admSeed);
            fg.setAdmission(i, adm);
            uint64 o = opens[i];
            uint64 c = closes[i];
            uint64[12] memory marks = [
                o,
                o + 1 minutes,
                o + 5 minutes,
                o + 15 minutes,
                o + 30 minutes,
                adm,
                adm + 10 minutes,
                c - 2 hours,
                c - 75 minutes,
                c - 30 minutes,
                c,
                i + 1 < n ? opens[i + 1] : c + 1 days
            ];
            uint64 m = marks[(seed >> 16) % 12];
            if (m < 2) m = o;
            t = m + uint64((seed >> 32) % 5) - 2;
        }
        if (t >= opens[0] && t < closes[n - 1]) {
            uint256 j = _indexAt(t);
            if (j != i) fg.setAdmission(j, _pickAdmission(j, admSeed >> 64));
        }
    }

    function _pickReasons(uint256 seed) internal pure returns (uint32) {
        uint256 mode = seed % 7;
        seed >>= 8;
        if (mode <= 1) return 0;
        if (mode == 2) return Reasons.STOPPED;
        if (mode == 3) return uint32(1 << (seed % 21));
        if (mode == 4) return uint32(seed) & ((uint32(1) << 21) - 1);
        if (mode == 5) return Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE;
        return Reasons.SOURCE_MASK;
    }

    function _clean(uint64 t) internal view returns (SessionRiskPolicy.Snapshot memory) {
        return policy.evaluate(PriceGate.Quote(400e18, 1, t, 0), t);
    }

    // ------------------------------------------------------------ the whole state machine

    /// INV-POL-03 to INV-POL-11, INV-POL-13, INV-POL-18 to INV-POL-21; mutants M01 to M25 and M28 to M30
    function testFuzz_evaluateMatchesTheModel(uint256 timeSeed, uint256 reasonSeed, uint256 admSeed) public {
        uint64 t = _pickTime(timeSeed, admSeed);
        PriceGate.Quote memory q = PriceGate.Quote(400e18, 7, t, _pickReasons(reasonSeed));
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(q, t);
        _expectModel(s, q, t);
        assertEq(_brokenRule(s, opens[n - 1], false), "");
        _expectBonusAndEligibility(s);

        // The view is the same function of the gate's quote at the clock time.
        fg.setQuote(q);
        clk.set(t);
        assertEq(_hash(policy.snapshot()), _hash(s), "snapshot() == evaluate(quote(), now)");
    }

    /// INV-POL-04, INV-POL-05, INV-POL-08; mutants M06, M10, M11, M12, M17
    function testFuzz_everyBoundaryOfAnySessionToTheSecond(uint256 iSeed, uint256 admSeed) public {
        uint256 i = bound(iSeed, 0, n - 2);
        uint64 o = opens[i];
        uint64 c = closes[i];
        uint64 a = c - 2 hours;
        uint64 f = c - 30 minutes;

        // Unadmitted: waiting until one second before O + 30 min, GUARDED from that second, CLOSED from C.
        fg.setAdmission(i, 0);
        _expectAt(o, S_WAIT, S_WAIT);
        _expectAt(o + 30 minutes - 1, S_WAIT, S_WAIT);
        _expectAt(o + 30 minutes, S_WAIT, S_GUARDED);
        _expectAt(c - 1, S_WAIT, S_GUARDED);
        _expectAt(c, S_CLOSED, S_CLOSED);

        // Admitted before A - 10 min: every boundary of the schedule falls on its own second.
        uint64 adm = uint64(bound(admSeed, o + 5 minutes, a - 10 minutes - 1));
        fg.setAdmission(i, adm);
        _expectAt(adm, S_RECOVERY, S_RECOVERY);
        _expectAt(adm + 10 minutes - 1, S_RECOVERY, S_RECOVERY);
        _expectAt(adm + 10 minutes, S_OPEN, S_OPEN);
        _expectAt(a - 1, S_OPEN, S_OPEN);
        _expectAt(a, S_PRE, S_PRE);
        _expectAt(f - 1, S_PRE, S_PRE);
        _expectAt(f, S_FINAL, S_FINAL);
        _expectAt(c - 1, S_FINAL, S_FINAL);
        _expectAt(c, S_CLOSED, S_CLOSED);
        _expectAt(opens[i + 1] - 1, S_CLOSED, S_CLOSED);
        if (i > 0) _expectAt(o - 1, S_CLOSED, S_CLOSED);
    }

    function _expectAt(uint64 t, SessionRiskPolicy.State phase, SessionRiskPolicy.State state) internal view {
        SessionRiskPolicy.Snapshot memory s = _clean(t);
        string memory at = vm.toString(t);
        assertEq(uint256(s.phase), uint256(phase), string.concat("phase at ", at));
        assertEq(uint256(s.state), uint256(state), string.concat("state at ", at));
        _expectModel(s, PriceGate.Quote(400e18, 1, t, 0), t);
        assertEq(_brokenRule(s, opens[n - 1], false), "");
    }

    /// INV-POL-02, INV-POL-07, INV-POL-08, INV-POL-10, INV-POL-11, INV-POL-18
    function testFuzz_evaluateNeverRevertsOnTheCommittedCalendar(uint64 t, uint32 reasons, uint256 admSeed) public {
        if (t >= opens[0] && t < closes[n - 1]) fg.setAdmission(_indexAt(t), uint64(bound(admSeed, 0, 2 ** 40)));
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(PriceGate.Quote(1, 1, t, reasons), t);
        assertEq(_brokenRule(s, opens[n - 1], false), "");
    }

    /// INV-POL-09: the phase follows whatever record the gate holds, including ones the real gate never writes.
    function testFuzz_policyTakesTheAdmissionRecordAtFaceValue(uint256 iSeed, uint256 admSeed, uint256 off) public {
        uint256 i = bound(iSeed, 0, n - 2);
        uint64 o = opens[i];
        uint64 adm = uint64(bound(admSeed, 1, closes[i] + 1 days));
        fg.setAdmission(i, adm);
        uint64 t = uint64(bound(off, o, closes[i] - 1));
        SessionRiskPolicy.Snapshot memory s = _clean(t);
        _expectModel(s, PriceGate.Quote(400e18, 1, t, 0), t);
        uint64 credit = o + 15 minutes > adm + 10 minutes ? o + 15 minutes : adm + 10 minutes;
        assertEq(s.creditAt, credit);
        if (t < credit) assertEq(uint256(s.phase), uint256(S_RECOVERY), "recovery until creditAt, as recorded");
    }

    // ------------------------------------------------------------ properties over time

    /// INV-POL-14, INV-POL-13; mutant M09
    function testFuzz_closureLimitsHoldFromFinalUntilCreditReturns(
        uint256 iSeed,
        uint256 admSeed,
        uint256 nextAdmSeed,
        uint256 off
    ) public {
        // Session n - 2 is left out: wind-down, not the next session, follows its close.
        uint256 i = bound(iSeed, 0, n - 3);
        uint64 c = closes[i];
        uint64 next = opens[i + 1];
        fg.setAdmission(i, uint64(bound(admSeed, opens[i] + 5 minutes, c - 40 minutes)));
        fg.setAdmission(i + 1, 0);
        SessionRiskPolicy.ClosureClass k = _gapClass(next - c);
        uint64[8] memory ts = [
            c - 30 minutes,
            uint64(bound(off, c - 30 minutes, c - 1)),
            c - 1,
            c,
            uint64(bound(off, c, next - 1)),
            next - 1,
            next,
            uint64(bound(off, next, closes[i + 1] - 1))
        ];
        for (uint256 j; j < ts.length; ++j) {
            _expectClosureLimits(_clean(ts[j]), k);
        }
        // Admitted reopening: the same limits until credit returns, inclusive of creditAt - 1.
        uint64 adm = uint64(bound(nextAdmSeed, next + 5 minutes, closes[i + 1] - 10 minutes));
        fg.setAdmission(i + 1, adm);
        _expectClosureLimits(_clean(adm), k);
        _expectClosureLimits(_clean(uint64(bound(off, adm, adm + 10 minutes - 1))), k);
        _expectClosureLimits(_clean(adm + 10 minutes - 1), k);
        SessionRiskPolicy.Snapshot memory s = _clean(adm + 10 minutes);
        assertTrue(s.phase != S_RECOVERY && s.phase != S_WAIT, "credit returns at creditAt");
    }

    function _expectClosureLimits(SessionRiskPolicy.Snapshot memory s, SessionRiskPolicy.ClosureClass k) internal pure {
        assertEq(uint256(s.closureClass), uint256(k), "class of the gap");
        assertEq(s.ltWad, _ltF(k), "LT_F of the gap");
        assertEq(s.targetWad, _tgt(k), "target of the gap");
        assertEq(s.borrowLimitWad, 0, "no B");
        assertFalse(s.canBorrow || s.lenderOpen, "no credit, no lender window");
    }

    /// INV-POL-15, INV-POL-08
    function testFuzz_limitsNeverRiseAndWindowsAreIntervalsWithinASession(
        uint256 iSeed,
        uint256 admSeed,
        uint256 a,
        uint256 b,
        uint256 c
    ) public {
        uint256 i = bound(iSeed, 0, n - 2);
        uint64 adm = uint64(bound(admSeed, opens[i] + 5 minutes, closes[i] - 1));
        fg.setAdmission(i, adm);
        uint64 lo = adm + 10 minutes;
        uint64 hi = opens[i + 1] - 1;
        uint64 t1 = uint64(bound(a, lo, hi));
        uint64 t2 = uint64(bound(b, t1, hi));
        uint64 t3 = uint64(bound(c, t2, hi));
        SessionRiskPolicy.Snapshot memory s1 = _clean(t1);
        SessionRiskPolicy.Snapshot memory s2 = _clean(t2);
        SessionRiskPolicy.Snapshot memory s3 = _clean(t3);
        // OPEN < PRE_CLOSE < FINAL_WINDOW < CLOSED in the enum order.
        assertLe(uint256(s1.phase), uint256(s2.phase), "phases only advance");
        assertLe(uint256(s2.phase), uint256(s3.phase), "phases only advance");
        assertLe(uint256(s3.phase), uint256(S_CLOSED));
        assertGe(s1.ltWad, s2.ltWad, "LT never rises");
        assertGe(s2.ltWad, s3.ltWad, "LT never rises");
        assertGe(s1.targetWad, s2.targetWad, "target never rises");
        assertGe(s2.targetWad, s3.targetWad, "target never rises");
        assertGe(s1.borrowLimitWad, s2.borrowLimitWad, "B never rises");
        assertGe(s2.borrowLimitWad, s3.borrowLimitWad, "B never rises");
        // Each window is one interval: on at t1 and t3 means on at t2.
        if (s1.canBorrow && s3.canBorrow) assertTrue(s2.canBorrow, "borrow window");
        if (s1.lenderOpen && s3.lenderOpen) assertTrue(s2.lenderOpen, "lender window");
        if (s1.canTrim && s3.canTrim) assertTrue(s2.canTrim, "trim window");
        if (s1.canBuffer && s3.canBuffer) assertTrue(s2.canBuffer, "buffer window");
        if (s2.canBorrow) assertTrue(s1.canBorrow, "borrowing never restarts");
        if (s2.lenderOpen) assertTrue(s1.lenderOpen, "the lender window never restarts");
    }

    /// INV-POL-17 (sessions admitted before A - 10 min)
    function testFuzz_onTimeAdmissionAppliesTheClosingClassFromA(uint256 iSeed, uint256 admSeed, uint256 off) public {
        uint256 i = bound(iSeed, 0, n - 3);
        uint64 c = closes[i];
        fg.setAdmission(i, uint64(bound(admSeed, opens[i] + 5 minutes, c - 2 hours - 10 minutes)));
        uint64 t = uint64(bound(off, c - 2 hours, c - 1));
        SessionRiskPolicy.ClosureClass k = _gapClass(opens[i + 1] - c);
        SessionRiskPolicy.Snapshot memory s = _clean(t);
        assertEq(uint256(s.closureClass), uint256(k), "closing class from A");
        assertEq(s.targetWad, _tgt(k), "closing target from A");
        assertEq(s.ltWad, t < c - 30 minutes ? _ramp(k, t - (c - 2 hours)) : _ltF(k), "ramp, then LT_F");
        assertTrue(s.canBuffer && s.canTrim, "buffers and trims over [A, C)");
        assertTrue(s.phase == S_PRE || s.phase == S_FINAL);
    }

    /// INV-POL-16
    function test_lateAdmissionAfterALetsLtRiseWhenCreditReturns() public {
        // The first session after a weekend (EXTENDED opening) that closes overnight.
        uint256 i = 1;
        while (!(opens[i] - closes[i - 1] >= 24 hours && opens[i + 1] - closes[i] < 24 hours)) ++i;
        uint64 a = closes[i] - 2 hours;
        fg.setAdmission(i, a + 1 minutes);
        SessionRiskPolicy.Snapshot memory r = _clean(a + 10 minutes);
        assertEq(uint256(r.phase), uint256(S_RECOVERY));
        assertEq(r.ltWad, 0.7e18);
        SessionRiskPolicy.Snapshot memory p = _clean(a + 11 minutes);
        assertEq(uint256(p.phase), uint256(S_PRE));
        assertEq(p.ltWad, _ramp(K_OVERNIGHT, 11 minutes));
        assertGt(p.ltWad, r.ltWad, "LT rises when credit returns");
    }

    /// INV-X-13, INV-POL-03: from the last open nothing is ever allowed again, whatever the quote or the records.
    function testFuzz_windDownIsAbsorbing(uint64 t, uint32 reasons, uint64 admLast, uint64 admBefore) public {
        t = uint64(bound(t, opens[n - 1], type(uint64).max));
        fg.setAdmission(n - 1, admLast);
        fg.setAdmission(n - 2, admBefore);
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(PriceGate.Quote(400e18, 1, t, reasons), t);
        assertTrue(s.windDown);
        assertFalse(s.covered);
        assertEq(uint256(s.state), uint256(S_GUARDED));
        assertFalse(_anyPermission(s), "no borrow, trim, buffer or lender entry");
        assertEq(s.borrowLimitWad, 0);
        assertEq(_brokenRule(s, opens[n - 1], false), "");
    }

    // ------------------------------------------------------------ pure functions

    /// INV-POL-12; mutants M26, M27 (equivalent), M28
    function testFuzz_rampIsTheFloorOfTheExactLineAndNeverRises(uint64 close, uint64 t1, uint64 t2, bool ext)
        public
        view
    {
        close = uint64(bound(close, 2 hours, type(uint64).max));
        SessionRiskPolicy.ClosureClass k = ext ? K_EXTENDED : K_OVERNIGHT;
        uint64 a = close - 2 hours;
        uint64 top = close > type(uint64).max - 600 ? type(uint64).max : close + 600;
        t1 = uint64(bound(t1, a > 600 ? a - 600 : 0, top));
        t2 = uint64(bound(t2, t1, top));
        uint256 l1 = _expectRampAt(k, t1, close);
        assertLe(policy.ltAt(k, t2, close), l1, "never rises");
        assertLe(policy.ltAt(K_EXTENDED, t1, close), policy.ltAt(K_OVERNIGHT, t1, close), "EXTENDED never looser");
        _expectRampEnds(k, close);
    }

    /// @dev LT at `t` is 80% up to A, LT_F from F, and in between the floor of the exact line.
    function _expectRampAt(SessionRiskPolicy.ClosureClass k, uint64 t, uint64 close)
        internal
        view
        returns (uint256 lt)
    {
        uint64 a = close - 2 hours;
        lt = policy.ltAt(k, t, close);
        if (t <= a) {
            assertEq(lt, 0.8e18, "80% up to A");
        } else if (t >= close - 30 minutes) {
            assertEq(lt, _ltF(k), "LT_F from F");
        } else {
            uint256 x = t - a;
            uint256 exact = uint256(0.8e18) * 5400 - (0.8e18 - _ltF(k)) * x; // the line times 5400
            assertEq(lt, _ramp(k, x), "floor of the exact line");
            assertLe(lt * 5400, exact, "never above the exact line");
            assertGt((lt + 1) * 5400, exact, "less than one wei below it");
            assertLt(lt, 0.8e18, "strictly below 80% after A");
            assertGt(lt, _ltF(k), "strictly above LT_F before F");
        }
    }

    /// @dev Continuity at A and F, and the first and last steps of the ramp.
    function _expectRampEnds(SessionRiskPolicy.ClosureClass k, uint64 close) internal view {
        uint64 a = close - 2 hours;
        uint64 f = close - 30 minutes;
        uint256 d = 0.8e18 - _ltF(k);
        assertEq(policy.ltAt(k, a, close), 0.8e18, "continuous at A");
        assertEq(policy.ltAt(k, a + 1, close), 0.8e18 - (d + 5399) / 5400, "first step after A");
        assertEq(policy.ltAt(k, f - 1, close), _ltF(k) + d / 5400, "last step before F");
        assertEq(policy.ltAt(k, f, close), _ltF(k), "continuous at F");
    }

    /// INV-POL-10; mutants M29, M30
    function testFuzz_borrowLimitIsTheLowerOfTheCapAndTheGap(uint256 lt) public view {
        lt = bound(lt, 0.05e18, type(uint256).max);
        uint256 b = policy.borrowLimit(lt);
        assertEq(b, lt - 0.05e18 < 0.75e18 ? lt - 0.05e18 : 0.75e18);
        assertLe(b, 0.75e18);
        assertLe(b + 0.05e18, lt);
    }

    /// INV-POL-10
    function testFuzz_borrowLimitRevertsBelowTheGap(uint256 lt) public {
        lt = bound(lt, 0, 0.05e18 - 1);
        vm.expectRevert(stdError.arithmeticError);
        policy.borrowLimit(lt);
    }

    /// INV-POL-01
    function testFuzz_creditAtIsTheLaterOfOpenPlus15AndAdmissionPlus10(uint64 open, uint64 adm) public pure {
        open = uint64(bound(open, 0, type(uint64).max - 15 minutes));
        adm = uint64(bound(adm, 0, type(uint64).max - 10 minutes));
        uint64 c = SessionTiming.creditAt(open, adm);
        assertEq(c, open + 15 minutes > adm + 10 minutes ? open + 15 minutes : adm + 10 minutes);
        if (adm >= open + 5 minutes) assertEq(c, adm + 10 minutes, "O + 15 min never binds a real admission");
    }

    // ------------------------------------------------------------ the committed calendar

    /// INV-POL-13; mutants M08, M09, M25
    function test_class_everyCloseAndReopeningFollowsTheGapRule() public view {
        SessionRiskPolicy.Snapshot memory s = _clean(opens[0]);
        assertEq(uint256(s.closureClass), uint256(K_EXTENDED), "session 0 opens EXTENDED");
        uint256 extended;
        // Session n - 2 is left out: wind-down follows its close.
        for (uint256 i; i + 2 < n; ++i) {
            SessionRiskPolicy.ClosureClass k = _gapClass(opens[i + 1] - closes[i]);
            if (k == K_EXTENDED) ++extended;
            s = _clean(closes[i]);
            assertEq(uint256(s.phase), uint256(S_CLOSED));
            assertEq(uint256(s.closureClass), uint256(k), "class of the close");
            assertEq(s.ltWad, _ltF(k));
            assertEq(s.targetWad, _tgt(k));
            s = _clean(opens[i + 1]);
            assertEq(uint256(s.phase), uint256(S_WAIT));
            assertEq(uint256(s.closureClass), uint256(k), "the reopening keeps the class of the closure");
            assertEq(s.ltWad, _ltF(k));
            assertEq(s.targetWad, _tgt(k));
        }
        assertGt(extended, 100, "weekends and holidays");
        assertLt(extended, n / 2, "weeknights are overnight");
    }

    /// INV-X-12, INV-POL-02: the data the policy relies on but nothing checks on-chain.
    function test_calendar_sessionsSuitThePolicyTimings() public view {
        for (uint256 i; i < n; ++i) {
            uint64 len = closes[i] - opens[i];
            assertLt(len, SessionTiming.RESUME_DELAY, "a resume always lands after the stop's session");
            assertGe(len, SessionTiming.PREP + SessionTiming.GUARD_AFTER, "OPEN is reachable on time");
            assertGe(closes[i], SessionTiming.PREP, "C - PREP cannot underflow");
            if (i + 1 < n) assertGe(opens[i + 1] - closes[i], 17.5 hours, "gaps");
        }
    }
}

// ================================================================ synthetic calendars

/// @notice Calendars built for one edge each: an exact 24-hour gap, a close below PREP, a single session.
contract PolicyEdgeCalendarTest is Test, PolicyRules {
    function _deploy(uint64[] memory o, uint64[] memory c) internal returns (SessionRiskPolicy p, PolicyFakeGate g) {
        uint256[] memory words = new uint256[]((o.length + 3) / 4);
        for (uint256 i; i < o.length; ++i) {
            words[i / 4] |= ((uint256(o[i]) << 32) | uint256(c[i])) << (64 * (i % 4));
        }
        SessionCalendar cal = new SessionCalendar(words, o.length);
        g = new PolicyFakeGate(cal, new PolicyFakeClock());
        p = new SessionRiskPolicy(PriceGate(address(g)));
    }

    function _q(uint64 t) internal pure returns (PriceGate.Quote memory) {
        return PriceGate.Quote(400e18, 1, t, 0);
    }

    /// INV-POL-13; mutant M25
    function test_class_aGapOfExactly24HoursIsExtendedAndOneSecondLessIsOvernight() public {
        uint64 base = 1_800_000_000;
        uint64[] memory o = new uint64[](4);
        uint64[] memory c = new uint64[](4);
        o[0] = base;
        c[0] = base + 6.5 hours;
        o[1] = c[0] + 24 hours - 1;
        c[1] = o[1] + 6.5 hours;
        o[2] = c[1] + 24 hours;
        c[2] = o[2] + 6.5 hours;
        o[3] = c[2] + 17.5 hours;
        c[3] = o[3] + 6.5 hours;
        (SessionRiskPolicy p, PolicyFakeGate g) = _deploy(o, c);
        g.setAdmission(1, o[1] + 5 minutes);

        assertEq(uint256(p.evaluate(_q(c[0]), c[0]).closureClass), uint256(K_OVERNIGHT), "close: 24 h - 1 s");
        SessionRiskPolicy.Snapshot memory s = p.evaluate(_q(o[1] + 6 minutes), o[1] + 6 minutes);
        assertEq(uint256(s.phase), uint256(S_RECOVERY));
        assertEq(uint256(s.closureClass), uint256(K_OVERNIGHT), "reopening after 24 h - 1 s");
        assertEq(s.ltWad, 0.77e18);
        s = p.evaluate(_q(o[1] + 1 hours), o[1] + 1 hours);
        assertEq(uint256(s.closureClass), uint256(K_EXTENDED), "OPEN before a 24 h gap");
        s = p.evaluate(_q(c[1] - 1), c[1] - 1);
        assertEq(uint256(s.phase), uint256(S_FINAL));
        assertEq(s.ltWad, 0.7e18, "LT_F of an exactly 24 h gap");
        s = p.evaluate(_q(o[2]), o[2]);
        assertEq(uint256(s.closureClass), uint256(K_EXTENDED), "reopening after exactly 24 h");
        assertEq(s.targetWad, 0.65e18);
    }

    /// INV-POL-02
    function test_evaluateRevertsOnlyForACloseBelowPrep() public {
        uint64[] memory o = new uint64[](2);
        uint64[] memory c = new uint64[](2);
        (o[0], c[0], o[1], c[1]) = (100, 7199, 100_000, 120_000);
        (SessionRiskPolicy p,) = _deploy(o, c);
        vm.expectRevert(stdError.arithmeticError);
        p.evaluate(_q(150), 150);
        vm.expectRevert(stdError.arithmeticError);
        p.ltAt(K_EXTENDED, 150, 7199);

        c[0] = 7200;
        (p,) = _deploy(o, c);
        SessionRiskPolicy.Snapshot memory s = p.evaluate(_q(150), 150);
        assertEq(s.prepAt, 0);
        assertEq(s.finalAt, 5400);
        assertEq(uint256(s.phase), uint256(S_WAIT));
        assertEq(_brokenRule(s, o[1], false), "");
    }

    /// INV-POL-03
    function test_singleSessionCalendarIsNeverCovered() public {
        uint64[] memory o = new uint64[](1);
        uint64[] memory c = new uint64[](1);
        (o[0], c[0]) = (1_800_000_000, 1_800_023_400);
        (SessionRiskPolicy p, PolicyFakeGate g) = _deploy(o, c);
        g.setAdmission(0, o[0] + 5 minutes);
        SessionRiskPolicy.Snapshot memory s = p.evaluate(_q(o[0] - 1), o[0] - 1);
        assertFalse(s.covered || s.windDown);
        s = p.evaluate(_q(o[0] + 1 hours), o[0] + 1 hours);
        assertFalse(s.covered);
        assertTrue(s.windDown);
        assertFalse(_anyPermission(s));
    }
}

// ================================================================ stateful suite on the real gate and market

/// @dev Everything in a market that a refresh or a phase change must leave alone.
struct PolicyBook {
    uint256[3] collateral;
    uint256[3] debtShares;
    uint256[3] escrowBalance;
    uint256 cash;
    uint256 totalDebtShares;
    uint256 lenderShares;
    uint256 marketLoanTokens;
    uint256 marketCollateral;
    uint256 escrowLoanTokens;
    uint256 badDebt;
}

/// @notice Drives a market's gate across real sessions: price moves, missed feed updates, issuer pauses, guardian
/// stops and resumes, and leaps of many sessions toward the end of the calendar. Around every refresh it records
/// what the view saw, what the transaction saw and whether anything outside the gate moved.
contract PolicyHandler is Test, PolicyRules {
    uint256 internal constant USDG = 1e6;

    MarketHarness internal market;
    RepaymentEscrow internal escrow;
    SessionRiskPolicy internal policy;
    PriceGate internal gate;
    SessionCalendar internal cal;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    address internal owner; // issuer of the mocks and publisher of the feed
    address internal guardian;
    address internal lender;
    address internal liquidator;
    address[3] internal accounts; // alice: debt and a plan; bob: debt; carol: collateral only
    uint64 internal lastOpen;
    int256 public answer = 400e8;
    bool internal issuerPaused;
    bool internal seenWindDown;
    uint64 internal lastAdmission;
    uint256[3] internal lastDebt;

    // Rule breaks; every one must stay zero.
    uint256 public brokenRules;
    string public firstBrokenRule;
    uint256 public viewDiffersFromQuoteEvaluation;
    uint256 public viewDiffersAfterRefresh;
    uint256 public viewMorePermissive;
    uint256 public refreshMovedTheBook;
    uint256 public debtFellWithoutRepayment;
    uint256 public windDownLeft;
    uint256 public priceActionUnderStop;
    uint256 public exitBlockedUnderStop;
    uint256 public priceActionInWindDown;
    uint256 public exitBlockedInWindDown;

    // Coverage of the run.
    uint256 public steps;
    uint256 public coveredSteps;
    uint256 public windDownSteps;
    uint256 public admissions;
    uint256 public stops;
    uint256 public resumes;
    uint256 public pauses;
    uint256 public outageSteps;
    uint256 public graceSteps;
    uint256 public exitsUnderStop;
    uint256 public maxSession;
    uint256[7] public stateSteps;

    constructor(
        MarketHarness market_,
        MockAggregatorV3 feed_,
        MockStockToken tsla_,
        address owner_,
        address guardian_,
        address[3] memory accounts_,
        address lender_,
        address liquidator_
    ) {
        market = market_;
        escrow = market_.escrow();
        policy = market_.policy();
        gate = market_.gate();
        cal = gate.calendar();
        feed = feed_;
        tsla = tsla_;
        owner = owner_;
        guardian = guardian_;
        accounts = accounts_;
        lender = lender_;
        liquidator = liquidator_;
        lastOpen = cal.lastOpen();
        for (uint256 k; k < 3; ++k) {
            lastDebt[k] = market.debtOf(accounts_[k]);
        }
    }

    // ---------------------------------------------------------------- actions

    /// @dev Mostly short steps inside a session; one in six jumps to around the next open, and three steps in four
    /// taken during a closure skip to just around the next open. One step in five leaves the feed alone, so
    /// prices go stale and outages are recorded.
    function tick(uint256 dt, int256 moveBps) external {
        dt = _whiten(dt);
        uint64 now_ = uint64(block.timestamp);
        SessionCalendar.Context memory c = cal.context(now_);
        uint64 to;
        if (!c.covered) {
            to = now_ + 1 days;
            moveBps = bound(moveBps, -800, 800);
        } else if (dt % 6 == 0) {
            to = c.nextOpen - 10 minutes + uint64((dt >> 8) % 7 hours);
            moveBps = bound(moveBps, -3_500, 2_000);
        } else if (!c.inSession && dt % 4 != 0) {
            to = c.nextOpen - 10 minutes + uint64((dt >> 8) % 40 minutes);
            moveBps = bound(moveBps, -3_500, 2_000);
        } else {
            to = now_ + uint64(bound(dt >> 8, 1 minutes, 90 minutes));
            moveBps = bound(moveBps, -800, 800);
        }
        vm.warp(to > now_ ? to : now_ + 1);
        if ((dt >> 4) % 5 != 0) _publish(moveBps);
        _step();
    }

    /// @dev Jump 1 to 5 sessions ahead (one leap in 128 to the last two sessions) and land on a boundary.
    function leap(uint256 k, uint256 mark) external {
        mark = _whiten(mark);
        uint64 now_ = uint64(block.timestamp);
        SessionCalendar.Context memory c = cal.context(now_);
        uint256 n = cal.sessionCount();
        uint256 idx;
        if (c.covered) {
            idx = c.index + bound(k, 1, 5);
        } else if (now_ >= cal.lastOpen()) {
            vm.warp(now_ + bound(k, 1 hours, 10 days));
            _publish(0);
            _step();
            return;
        }
        if (mark % 128 == 0) idx = n - 2 + (mark >> 8) % 2;
        if (idx > n - 1) idx = n - 1;
        (uint64 o, uint64 cl) = cal.sessionAt(idx);
        uint64[10] memory marks = [
            o - 5 minutes,
            o,
            o + 5 minutes,
            o + 20 minutes,
            o + 31 minutes,
            cl - 2 hours,
            cl - 45 minutes,
            cl - 30 minutes,
            cl - 1,
            cl + 1 hours
        ];
        uint64 t = marks[(mark >> 16) % 10];
        vm.warp(t > now_ ? t : now_ + 1);
        _publish(0);
        _step();
    }

    /// @dev The guardian stops (one call in eight while running), then requests the resume and performs it once
    /// the 24-hour delay has passed; otherwise time passes.
    function guardianAct(uint256 seed) external {
        seed = _whiten(seed);
        if (!gate.stopped()) {
            if (seed % 8 == 0) {
                vm.prank(guardian);
                gate.stop();
                stops++;
                _step();
                _probeUnderStop();
                return;
            }
        } else if (gate.resumeAvailableAt() == 0) {
            vm.prank(guardian);
            gate.requestResume();
        } else {
            if (block.timestamp < gate.resumeAvailableAt()) vm.warp(gate.resumeAvailableAt());
            vm.prank(guardian);
            gate.resume();
            resumes++;
        }
        vm.warp(block.timestamp + bound(seed >> 8, 1 minutes, 90 minutes));
        _publish(0);
        _step();
    }

    /// @dev The issuer raises its pause flag (one call in five) or clears it.
    function issuerAct(uint256 seed) external {
        seed = _whiten(seed);
        if (issuerPaused || seed % 5 == 0) {
            issuerPaused = !issuerPaused;
            if (issuerPaused) pauses++;
            vm.prank(owner);
            tsla.setOraclePaused(issuerPaused);
        }
        vm.warp(block.timestamp + bound(seed >> 8, 1 minutes, 30 minutes));
        _publish(0);
        _step();
    }

    // ---------------------------------------------------------------- the check around every refresh

    function _step() internal {
        steps++;
        uint64 t = uint64(block.timestamp);
        PolicyBook memory before = _book();

        SessionRiskPolicy.Snapshot memory v = policy.snapshot();
        if (_hash(v) != _hash(policy.evaluate(gate.quote(), t))) viewDiffersFromQuoteEvaluation++;
        SessionRiskPolicy.Snapshot memory x = policy.evaluate(gate.refresh(), t);
        if (_hash(policy.snapshot()) != _hash(x)) viewDiffersAfterRefresh++;
        if (_morePermissive(v, x)) viewMorePermissive++;
        _record(_brokenRule(v, lastOpen, true));
        _record(_brokenRule(x, lastOpen, true));

        if (keccak256(abi.encode(before)) != keccak256(abi.encode(_book()))) refreshMovedTheBook++;
        for (uint256 k; k < 3; ++k) {
            uint256 d = market.debtOf(accounts[k]);
            if (d < lastDebt[k]) debtFellWithoutRepayment++;
            lastDebt[k] = d;
        }

        if (seenWindDown && !x.windDown) windDownLeft++;
        stateSteps[uint256(x.state)]++;
        if (x.covered) {
            coveredSteps++;
            if (x.session > maxSession) maxSession = x.session;
        }
        if (x.reasons & Reasons.OUTAGE_UNRESOLVED != 0) outageSteps++;
        if (x.reasons & Reasons.RECOVERY_GRACE != 0) graceSteps++;
        if (x.admissionAt != 0 && x.admissionAt != lastAdmission) {
            admissions++;
            lastAdmission = x.admissionAt;
        }
        if (x.windDown) {
            seenWindDown = true;
            windDownSteps++;
            _probeWindDown();
        }
    }

    /// @dev Fuzzed values favour edge cases such as zero; hashing keeps the action mix at the rates above.
    function _whiten(uint256 seed) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(seed, steps)));
    }

    function _record(string memory broken) internal {
        if (bytes(broken).length == 0) return;
        brokenRules++;
        if (bytes(firstBrokenRule).length == 0) firstBrokenRule = broken;
    }

    function _morePermissive(SessionRiskPolicy.Snapshot memory v, SessionRiskPolicy.Snapshot memory x)
        internal
        pure
        returns (bool)
    {
        return (v.canBorrow && !x.canBorrow) || (v.canTrim && !x.canTrim) || (v.canBuffer && !x.canBuffer)
            || (v.lenderOpen && !x.lenderOpen) || (v.canBorrow && v.borrowLimitWad > x.borrowLimitWad);
    }

    /// @dev Under a stop every price-dependent action reverts, and repayment, top-ups, zero-debt withdrawals and
    /// the owner's escrow paths still work.
    function _probeUnderStop() internal {
        (address alice, address bob, address carol) = (accounts[0], accounts[1], accounts[2]);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        if (s.state != S_GUARDED || _anyPermission(s)) priceActionUnderStop++;
        vm.prank(bob);
        try market.borrow(5 * USDG, bob) {
            priceActionUnderStop++;
        } catch {}
        vm.prank(lender);
        try market.deposit(1 * USDG, lender) {
            priceActionUnderStop++;
        } catch {}
        vm.prank(liquidator);
        try market.trim(bob, 1_000 * USDG, 0, block.timestamp) {
            priceActionUnderStop++;
        } catch {}
        try escrow.executeBuffer(alice) {
            priceActionUnderStop++;
        } catch {}

        vm.prank(bob);
        try market.repay(1 * USDG, bob) {
            exitsUnderStop++;
        } catch {
            exitBlockedUnderStop++;
        }
        vm.prank(carol);
        try market.depositCollateral(1, carol) {}
        catch {
            exitBlockedUnderStop++;
        }
        vm.prank(carol);
        try market.withdrawCollateral(1, carol) {}
        catch {
            exitBlockedUnderStop++;
        }
        vm.prank(alice);
        try escrow.deposit(1 * USDG, alice) {}
        catch {
            exitBlockedUnderStop++;
        }
        vm.prank(alice);
        try escrow.ownerRepay(1 * USDG) {}
        catch {
            exitBlockedUnderStop++;
        }
        lastDebt[0] = market.debtOf(alice);
        lastDebt[1] = market.debtOf(bob);
    }

    /// @dev In wind-down nothing new can be borrowed, deposited or buffered, and repayments, zero-debt withdrawals
    /// and escrow withdrawals still work.
    function _probeWindDown() internal {
        (address alice, address bob, address carol) = (accounts[0], accounts[1], accounts[2]);
        vm.prank(bob);
        try market.borrow(5 * USDG, bob) {
            priceActionInWindDown++;
        } catch {}
        vm.prank(lender);
        try market.deposit(1 * USDG, lender) {
            priceActionInWindDown++;
        } catch {}
        try escrow.executeBuffer(alice) {
            priceActionInWindDown++;
        } catch {}
        vm.prank(bob);
        try market.repay(1 * USDG, bob) {}
        catch {
            exitBlockedInWindDown++;
        }
        vm.prank(carol);
        try market.withdrawCollateral(1, carol) {}
        catch {
            exitBlockedInWindDown++;
        }
        if (escrow.committed(alice)) exitBlockedInWindDown++;
        lastDebt[1] = market.debtOf(bob);
    }

    function _publish(int256 moveBps) internal {
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
    }

    function _book() internal view returns (PolicyBook memory b) {
        for (uint256 k; k < 3; ++k) {
            (b.collateral[k], b.debtShares[k],) = market.accountOf(accounts[k]);
            b.escrowBalance[k] = escrow.planOf(accounts[k]).balance;
        }
        b.cash = market.cash();
        b.totalDebtShares = market.totalDebtShares();
        b.lenderShares = market.totalSupply();
        b.marketLoanTokens = IERC20(market.asset()).balanceOf(address(market));
        b.marketCollateral = tsla.balanceOf(address(market));
        b.escrowLoanTokens = IERC20(market.asset()).balanceOf(address(escrow));
        b.badDebt = market.totalBadDebt();
    }
}

/// @notice The policy over long random runs with the real gate, market and escrow (docs/SPEC.md §3, §4, §6, R17).
contract PolicyInvariants is MarketFixture, PolicyRules {
    PolicyHandler internal handler;

    function setUp() public {
        _setUpMarket();
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(alice);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 6_000 * USDG);
        _fundCollateral(carol, 10 * TOKEN);

        usdg.mint(alice, 10_000 * USDG);
        usdg.mint(bob, 10_000 * USDG);
        tsla.mint(carol, 1 * TOKEN);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        escrow.authorize(0.65e18, 1_000 * USDG, type(uint64).max);
        vm.stopPrank();
        vm.prank(bob);
        usdg.approve(address(market), type(uint256).max);

        handler = new PolicyHandler(
            market, stockFeed, tsla, address(this), guardian, [alice, bob, carol], lender, liquidator
        );
        bytes4[] memory actions = new bytes4[](4);
        actions[0] = PolicyHandler.tick.selector;
        actions[1] = PolicyHandler.leap.selector;
        actions[2] = PolicyHandler.guardianAct.selector;
        actions[3] = PolicyHandler.issuerAct.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("steps", handler.steps(), "covered", handler.coveredSteps());
        console.log("windDown", handler.windDownSteps(), "furthest session", handler.maxSession());
        console.log("admissions", handler.admissions(), "stops", handler.stops());
        console.log("resumes", handler.resumes(), "issuer pauses", handler.pauses());
        console.log("outage steps", handler.outageSteps(), "grace steps", handler.graceSteps());
        console.log("exits under stop", handler.exitsUnderStop());
        console.log("OPEN", handler.stateSteps(0), "PRE_CLOSE", handler.stateSteps(1));
        console.log("FINAL_WINDOW", handler.stateSteps(2), "CLOSED", handler.stateSteps(3));
        console.log("REOPEN_WAIT", handler.stateSteps(4), "REOPEN_RECOVERY", handler.stateSteps(5));
        console.log("GUARDED", handler.stateSteps(6));
    }

    /// INV-POL-03 to INV-POL-08, INV-POL-10, INV-POL-11, INV-POL-18, INV-POL-21, INV-POL-01 (real admissions)
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    function invariant_everySnapshotKeepsThePolicyRules() public view {
        assertEq(handler.brokenRules(), 0, handler.firstBrokenRule());
        assertEq(_brokenRule(policy.snapshot(), cal.lastOpen(), true), "");
        assertEq(handler.viewDiffersFromQuoteEvaluation(), 0, "snapshot() == evaluate(quote(), now)");
        assertEq(handler.viewDiffersAfterRefresh(), 0, "after a refresh the view agrees with the transaction");
        assertEq(handler.viewMorePermissive(), 0, "the view never allows more than a transaction");
    }

    /// INV-X-21
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    function invariant_refreshesAndPhaseChangesNeverMoveTheBook() public view {
        assertEq(handler.refreshMovedTheBook(), 0, "positions, plans or cash moved");
        assertEq(handler.debtFellWithoutRepayment(), 0, "a closure reduced debt");
    }

    /// INV-X-10, INV-X-13
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 150
    function invariant_stopsAndWindDownBlockPricesNotExits() public view {
        assertEq(handler.priceActionUnderStop(), 0, "a price-dependent action ran under a stop");
        assertEq(handler.exitBlockedUnderStop(), 0, "an exit was blocked by a stop");
        assertEq(handler.priceActionInWindDown(), 0, "a price-dependent action ran in wind-down");
        assertEq(handler.exitBlockedInWindDown(), 0, "an exit was blocked in wind-down");
        assertEq(handler.windDownLeft(), 0, "wind-down ended");
    }
}
