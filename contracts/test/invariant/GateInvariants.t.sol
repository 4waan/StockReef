// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {ScriptedFeed} from "../utils/ScriptedFeed.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

/// @notice Drives two gates that share one stock feed, token, clock and calendar (a peg gate and a feed-mode gate
/// with a loan feed and a sequencer feed) across real calendar sessions: prints, adversarial rounds, source
/// failures, issuer pauses, multiplier changes, sequencer restarts and guardian stops and resumes. Every refresh
/// is checked against an independent model of the sources and of the refresh state machine; the first mismatch
/// is kept in `violation`.
contract GateHandler is Test {
    uint256 internal constant STOCK_BOUND = 1e14;
    uint256 internal constant LOAN_BOUND = 2e8;
    uint32 internal constant LOAN_MAX_AGE = 3600;
    uint32 internal constant SEQ_GRACE = 120;
    uint32 internal constant GATE_STATE_BITS = Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE;

    /// @dev Gate storage the model tracks.
    struct Rec {
        uint32 admitted;
        uint64 admissionAt;
        uint32 outage;
        uint64 cp;
        bool stopped;
        uint64 resumeAt;
        uint256 lastPrice;
        uint64 lastUpdated;
        uint64 lastAccepted;
    }

    /// @dev The model's reading of the sources at one time.
    struct Source {
        uint32 bits;
        uint256 price;
        uint64 stamp;
    }

    /// @dev The model's expectation for one refresh.
    struct Step {
        Rec post;
        uint32 base;
        uint32 reasons;
        uint32 viewReasons;
        uint256 index;
        bool admit;
        bool reset;
        bool outage;
        bool checkpoint;
    }

    PriceGate[2] internal gates;
    uint32[2] internal stockMaxAge;
    ScriptedFeed internal stock;
    ScriptedFeed internal loan;
    ScriptedFeed internal seq;
    MockStockToken internal tsla;
    SessionCalendar internal cal;
    address internal guardian;
    address internal issuer;
    address internal stranger = address(0x5157);

    uint8 internal stockDecimals = 8;
    uint8 internal loanDecimals = 8;
    int256 internal answer = 400e8;

    uint64[2] public lastStopAt;
    uint64[2] public lastRequestAt;
    string public violation;

    uint256 public refreshes;
    uint256 public usable;
    uint256 public admissions;
    uint256 public resets;
    uint256 public outages;
    uint256 public recoveries;
    uint256 public stops;
    uint256 public requests;
    uint256 public resumes;
    uint256 public earlyResumes;
    uint256 public rejectedCalls;
    uint256 public boundaryHits;
    uint256 public sessionsSeen;
    uint32 internal lastSid;

    constructor(
        PriceGate pegGate,
        PriceGate feedGate,
        ScriptedFeed stock_,
        ScriptedFeed loan_,
        ScriptedFeed seq_,
        MockStockToken tsla_,
        address issuer_
    ) {
        gates[0] = pegGate;
        gates[1] = feedGate;
        stockMaxAge[0] = pegGate.stockMaxAge();
        stockMaxAge[1] = feedGate.stockMaxAge();
        stock = stock_;
        loan = loan_;
        seq = seq_;
        tsla = tsla_;
        cal = pegGate.calendar();
        guardian = pegGate.owner();
        issuer = issuer_;
    }

    // ---------------------------------------------------------------- actions

    /// @dev Time passes with ordinary prints, then both gates refresh.
    function step(uint256 seed) external {
        _flow(seed);
        _refreshAll();
    }

    /// @dev Skip to around the next session's open (before it, at it or in its first 40 minutes).
    function jump(uint256 seed) external {
        SessionCalendar.Context memory c = cal.context(uint64(block.timestamp));
        if (c.covered) {
            uint256 target = c.nextOpen - 10 minutes + seed % 50 minutes;
            if (target > block.timestamp) vm.warp(target);
        }
        if (seed % 5 != 0) _printFresh(seed >> 8);
        if ((seed >> 16) % 4 != 0) loan.set(1e8, block.timestamp, block.timestamp);
        _refreshAll();
    }

    /// @dev Publish an edge-case round: the exact admission stamps, stale, future, zero, out-of-range or
    /// boundary answers, a stamp beyond uint64, or a loan-feed round.
    function print(uint256 kind, uint256 seed) external {
        _flow(seed);
        uint256 t = block.timestamp;
        SessionCalendar.Context memory c = cal.context(uint64(t));
        kind %= 10;
        if (kind == 0) {
            _printFresh(seed >> 8);
        } else if (kind == 1 && c.inSession && t >= c.open + SessionTiming.FRESH_AFTER) {
            stock.set(answer, c.open + SessionTiming.FRESH_AFTER, c.open + SessionTiming.FRESH_AFTER);
        } else if (kind == 2 && c.inSession && t >= c.open + SessionTiming.FRESH_AFTER) {
            stock.set(answer, c.open + SessionTiming.FRESH_AFTER - 1, c.open + SessionTiming.FRESH_AFTER - 1);
        } else if (kind == 3) {
            uint256 s = t - stockMaxAge[0] - 1 - (seed >> 8) % 1000;
            stock.set(answer, s, s);
        } else if (kind == 4) {
            stock.set(answer, t, t + 1 + (seed >> 8) % 10 minutes);
        } else if (kind == 5) {
            stock.set(answer, 0, 0);
        } else if (kind == 6) {
            int256[5] memory bad = [type(int256).min, -1, 0, int256(STOCK_BOUND) + 1, type(int256).max];
            stock.set(bad[(seed >> 8) % 5], t, t);
        } else if (kind == 7) {
            stock.set(int256(STOCK_BOUND), t, t);
        } else if (kind == 8) {
            stock.set(answer, t, uint256(type(uint64).max) + 1 + (seed >> 8) % 1000);
        } else {
            int256[6] memory la = [int256(0.99e8 + int256((seed >> 16) % 2e6)), 1e8, 0, int256(LOAN_BOUND), 1, 3e8];
            uint256 pick = (seed >> 8) % 8;
            if (pick < 6) loan.set(la[pick], t, t);
            else if (pick == 6) loan.set(1e8, t - LOAN_MAX_AGE - 1, t - LOAN_MAX_AGE - 1);
            else loan.set(1e8, t, t + 60);
        }
        _refreshAll();
    }

    /// @dev Toggle or set one source failure: feed reverts, changed or reverting decimals, issuer pause,
    /// multiplier schedule, sequencer up, restarted, down, reverting or starting in the future.
    function fault(uint256 kind, uint256 seed) external {
        _flow(seed);
        uint256 t = block.timestamp;
        kind %= 12;
        if (kind == 0) {
            stock.setReverting(!stock.reverting());
        } else if (kind == 1) {
            stockDecimals = stockDecimals == 8 ? 18 : 8;
            stock.setDecimals(stockDecimals);
        } else if (kind == 2) {
            stock.setDecimalsReverting(!stock.decimalsReverting());
        } else if (kind == 3) {
            loan.setReverting(!loan.reverting());
        } else if (kind == 4) {
            loanDecimals = loanDecimals == 8 ? 6 : 8;
            loan.setDecimals(loanDecimals);
        } else if (kind == 5) {
            bool paused = tsla.oraclePaused();
            vm.prank(issuer);
            tsla.setOraclePaused(!paused);
        } else if (kind == 6) {
            vm.prank(issuer);
            tsla.scheduleMultiplier(1e18 + (seed >> 8) % 1e18, t + (seed >> 16) % 10 minutes);
        } else if (kind == 7) {
            vm.prank(issuer);
            tsla.scheduleMultiplier(1e18, 0);
        } else if (kind == 8) {
            seq.set(0, t - 1 days, t);
        } else if (kind == 9) {
            seq.set(0, t, t);
        } else if (kind == 10) {
            seq.set((seed >> 8) % 2 == 0 ? int256(1) : int256(-1), t - 1 hours, t);
        } else {
            if ((seed >> 8) % 2 == 0) seq.setReverting(!seq.reverting());
            else seq.set(0, t + 60, t);
        }
        _refreshAll();
    }

    /// @dev A guardian or stranger call on one gate, checked against the expected outcome, then refreshes.
    /// Mostly the guardian's sensible next step (stop a running gate now and then, request a resume, resume once
    /// allowed, or too early); sometimes any call regardless of state, or a stranger's call.
    function guardianAct(uint256 kind, uint256 seed) external {
        _flow(seed);
        uint256 gi = (seed >> 100) % 2;
        PriceGate g = gates[gi];
        kind %= 10;
        uint256 call;
        if (kind == 0) call = 6; // stranger
        else if (kind == 1) call = (seed >> 108) % 6; // any guardian call, whatever the state
        else if (!g.stopped()) call = kind < 4 ? 0 : 7; // stop, or only refresh
        else if (g.resumeAvailableAt() == 0) call = 1;
        else call = 3;
        if (call != 7) _guardian(gi, call, seed >> 116);
        _refreshAll();
    }

    /// @dev During a reopening recovery, land exactly on creditAt (or one second before it) with an invalid
    /// round, where an interrupted recovery turns into an outage.
    function creditBoundary(uint256 seed) external {
        PriceGate g = gates[seed % 2];
        SessionCalendar.Context memory c = cal.context(uint64(block.timestamp));
        if (c.covered && c.inSession && g.admittedSession() == c.index + 1) {
            uint256 credit = uint256(c.open) + SessionTiming.CREDIT_AFTER;
            uint256 recovered = uint256(g.admissionAt()) + SessionTiming.MIN_RECOVERY;
            if (recovered > credit) credit = recovered;
            uint256 target = credit - (seed >> 8) % 2;
            if (target > block.timestamp) {
                boundaryHits++;
                vm.warp(target);
                stock.set(0, block.timestamp, block.timestamp);
                _refreshAll();
                return;
            }
        }
        _flow(seed);
        _refreshAll();
    }

    /// @dev Time passes and prints land, but nobody refreshes.
    function quiet(uint256 seed) external {
        _flow(seed);
    }

    // ---------------------------------------------------------------- time and sources

    function _flow(uint256 r) internal {
        uint256 dt = 20 + r % 8 minutes;
        if ((r >> 8) % 16 == 0) dt = 30 minutes + (r >> 16) % 90 minutes;
        vm.warp(block.timestamp + dt);
        // Three times in four, skip a closed period to just around the next open.
        SessionCalendar.Context memory c = cal.context(uint64(block.timestamp));
        if (c.covered && !c.inSession && (r >> 24) % 4 != 0) {
            uint256 target = c.nextOpen - 3 minutes + (r >> 32) % 25 minutes;
            if (target > block.timestamp) vm.warp(target);
        }
        if ((r >> 40) % 5 == 0) _heal();
        if ((r >> 48) % 7 != 0) _printFresh(r >> 56);
        if ((r >> 64) % 8 != 0) loan.set(0.995e8 + int256((r >> 72) % 1e6), block.timestamp, block.timestamp);
    }

    function _printFresh(uint256 r) internal {
        int256 move = int256(r % 301) - 150;
        answer = answer * (10_000 + move) / 10_000;
        if (answer < 50e8) answer = 50e8;
        if (answer > 5_000e8) answer = 5_000e8;
        stock.set(answer, block.timestamp, block.timestamp);
    }

    function _heal() internal {
        stock.setReverting(false);
        stock.setDecimalsReverting(false);
        stockDecimals = 8;
        stock.setDecimals(8);
        loan.setReverting(false);
        loanDecimals = 8;
        loan.setDecimals(8);
        seq.setReverting(false);
        seq.set(0, block.timestamp - 1 days, block.timestamp);
        if (tsla.oraclePaused()) {
            vm.prank(issuer);
            tsla.setOraclePaused(false);
        }
    }

    // ---------------------------------------------------------------- the model

    function _read(PriceGate g) internal view returns (Rec memory r) {
        r.admitted = g.admittedSession();
        r.admissionAt = g.admissionAt();
        r.outage = g.outageSession();
        r.cp = g.checkpointAt();
        r.stopped = g.stopped();
        r.resumeAt = g.resumeAvailableAt();
        r.lastPrice = g.lastPriceWad();
        r.lastUpdated = g.lastUpdatedAt();
        r.lastAccepted = g.lastAcceptedAt();
    }

    function _roundBits(int256 a, uint256 u, uint64 t, uint32 maxAge, uint256 bound) internal pure returns (uint32 b) {
        if (a <= 0 || uint256(a) > bound) b |= 1;
        if (u == 0) b |= 2;
        else if (u > t) b |= 4;
        else if (t - u > maxAge) b |= 8;
    }

    /// @dev Source reasons, price and clamped stamp from the scripted sources' own state.
    function _source(uint256 gi, uint64 t) internal view returns (Source memory s) {
        bool stockOk = !stock.reverting();
        int256 a = stock.answer();
        uint256 u = stock.updatedAt();
        if (!stockOk) {
            s.bits |= Reasons.STOCK_FEED_UNAVAILABLE;
        } else {
            s.bits |= _roundBits(a, u, t, stockMaxAge[gi], STOCK_BOUND) << 1;
            s.stamp = u > type(uint64).max ? type(uint64).max : uint64(u);
        }
        if (stock.decimalsReverting() || stockDecimals != 8) s.bits |= Reasons.STOCK_DECIMALS_CHANGED;

        uint256 loanAnswer = 1e8;
        if (gi == 1) {
            bool loanOk = !loan.reverting();
            int256 la = loan.answer();
            if (!loanOk) s.bits |= Reasons.LOAN_FEED_UNAVAILABLE;
            else s.bits |= _roundBits(la, loan.updatedAt(), t, LOAN_MAX_AGE, LOAN_BOUND) << 7;
            if (loan.decimalsReverting() || loanDecimals != 8) s.bits |= Reasons.LOAN_DECIMALS_CHANGED;
            loanAnswer = loanOk && la > 0 && uint256(la) <= LOAN_BOUND ? uint256(la) : 0;
            if (seq.reverting()) {
                s.bits |= Reasons.SEQUENCER_DOWN;
            } else if (seq.answer() != 0 || seq.startedAt() == 0 || seq.startedAt() > t) {
                s.bits |= Reasons.SEQUENCER_DOWN;
            } else if (t - seq.startedAt() < SEQ_GRACE) {
                s.bits |= Reasons.SEQUENCER_GRACE;
            }
        }
        if (tsla.oraclePaused()) s.bits |= Reasons.ISSUER_PAUSED;
        uint256 e = tsla.effectiveAt();
        if (e != 0 && e <= t && (stockOk ? u : 0) < e) s.bits |= Reasons.MULTIPLIER_LAG;

        if (stockOk && a > 0 && uint256(a) <= STOCK_BOUND && loanAnswer > 0) {
            s.price = uint256(a) * 1e18 / loanAnswer; // sd = ld = 8, so the decimal scales cancel
        }
    }

    function _grace(uint64 cp, uint64 t, uint64 stamp) internal pure returns (bool) {
        return cp != 0 && (t < uint256(cp) + SessionTiming.RECOVERY_GRACE || stamp <= cp);
    }

    /// @dev The refresh state machine (docs/SPEC.md §6), written from the specification of each transition.
    function _model(Rec memory pre, Source memory src, uint64 t) internal view returns (Step memory m) {
        SessionCalendar.Context memory ctx = cal.context(t);
        uint32 sid = uint32(ctx.index + 1);
        m.index = ctx.index;
        m.base = src.bits | (pre.stopped ? Reasons.STOPPED : 0);
        m.viewReasons = m.base;
        if (pre.outage != 0 && pre.outage == sid) m.viewReasons |= Reasons.OUTAGE_UNRESOLVED;
        if (_grace(pre.cp, t, src.stamp)) m.viewReasons |= Reasons.RECOVERY_GRACE;

        Rec memory e = m.post;
        e.admitted = pre.admitted;
        e.admissionAt = pre.admissionAt;
        e.outage = pre.outage != sid ? 0 : pre.outage;
        e.cp = _grace(pre.cp, t, src.stamp) ? pre.cp : 0;
        e.stopped = pre.stopped;
        e.resumeAt = pre.resumeAt;
        e.lastPrice = pre.lastPrice;
        e.lastUpdated = pre.lastUpdated;
        e.lastAccepted = pre.lastAccepted;

        if (ctx.covered && ctx.inSession) {
            bool admitted = e.admitted == sid;
            if (m.base == 0) {
                if (e.outage == sid) {
                    e.outage = 0;
                    e.cp = t;
                    m.checkpoint = true;
                } else if (
                    !admitted && e.cp == 0 && t >= uint256(ctx.open) + 5 minutes
                        && src.stamp >= uint256(ctx.open) + 1 minutes
                ) {
                    e.admitted = sid;
                    e.admissionAt = t;
                    m.admit = true;
                }
            } else if (admitted) {
                uint256 credit = uint256(ctx.open) + 15 minutes;
                if (uint256(e.admissionAt) + 10 minutes > credit) credit = uint256(e.admissionAt) + 10 minutes;
                if (t < credit) {
                    e.admitted = 0;
                    e.admissionAt = 0;
                    m.reset = true;
                } else if (e.outage != sid) {
                    e.outage = sid;
                    m.outage = true;
                }
            }
        }
        m.reasons = m.base;
        if (e.outage == sid && sid != 0) m.reasons |= Reasons.OUTAGE_UNRESOLVED;
        if (_grace(e.cp, t, src.stamp)) m.reasons |= Reasons.RECOVERY_GRACE;
        if (m.reasons == 0) {
            e.lastPrice = src.price;
            e.lastUpdated = src.stamp;
            e.lastAccepted = t;
        }
    }

    // ---------------------------------------------------------------- checks

    function _violate(uint256 gi, string memory what) internal {
        if (bytes(violation).length != 0) return;
        violation = string.concat("gate ", vm.toString(gi), " at ", vm.toString(block.timestamp), ": ", what);
    }

    function _check(uint256 gi, bool ok, string memory what) internal {
        if (!ok) _violate(gi, what);
    }

    function _sameRec(uint256 gi, Rec memory a, Rec memory b, string memory where) internal {
        _check(gi, a.admitted == b.admitted, string.concat(where, ": admittedSession"));
        _check(gi, a.admissionAt == b.admissionAt, string.concat(where, ": admissionAt"));
        _check(gi, a.outage == b.outage, string.concat(where, ": outageSession"));
        _check(gi, a.cp == b.cp, string.concat(where, ": checkpointAt"));
        _check(gi, a.stopped == b.stopped, string.concat(where, ": stopped"));
        _check(gi, a.resumeAt == b.resumeAt, string.concat(where, ": resumeAvailableAt"));
        _check(gi, a.lastPrice == b.lastPrice, string.concat(where, ": lastPriceWad"));
        _check(gi, a.lastUpdated == b.lastUpdated, string.concat(where, ": lastUpdatedAt"));
        _check(gi, a.lastAccepted == b.lastAccepted, string.concat(where, ": lastAcceptedAt"));
    }

    function _refreshAll() internal {
        _checkRefresh(0);
        _checkRefresh(1);
    }

    function _checkRefresh(uint256 gi) internal {
        PriceGate g = gates[gi];
        uint64 t = uint64(block.timestamp);
        Rec memory pre = _read(g);
        Source memory src = _source(gi, t);
        Step memory m = _model(pre, src, t);

        PriceGate.Quote memory v;
        try g.quote() returns (PriceGate.Quote memory q0) {
            v = q0;
        } catch {
            _violate(gi, "quote reverted");
            return;
        }
        vm.recordLogs();
        PriceGate.Quote memory q;
        try g.refresh() returns (PriceGate.Quote memory q1) {
            q = q1;
        } catch {
            _violate(gi, "refresh reverted");
            return;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Rec memory post = _read(g);

        _check(gi, v.reasons == m.viewReasons, "view reasons");
        _check(gi, (v.reasons == 0) == (q.reasons == 0), "view and refresh disagree on usability");
        _check(gi, q.reasons == m.reasons, "refresh reasons");
        _check(gi, q.priceWad == src.price, "priceWad");
        _check(gi, q.updatedAt == src.stamp, "updatedAt");
        _check(gi, q.reasons < (uint32(1) << 21), "reason bits outside 0..20");
        _check(gi, !pre.stopped || q.reasons & Reasons.STOPPED != 0, "a stopped gate returned no STOPPED");
        _sameRec(gi, post, m.post, "refresh");
        _checkEvents(gi, logs, m, t, src.stamp);
        _checkIdempotent(gi, q, post);
        _count(gi, m, q, t);
    }

    /// @dev Exactly the transitions' events, with their fields; reset and outage events carry only the base.
    function _checkEvents(uint256 gi, Vm.Log[] memory logs, Step memory m, uint64 t, uint64 stamp) internal {
        uint256[4] memory n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(gates[gi])) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == PriceGate.RecoveryCheckpoint.selector) {
                n[3]++;
                _check(gi, abi.decode(logs[i].data, (uint64)) == t, "RecoveryCheckpoint time");
                continue;
            }
            _check(gi, uint256(logs[i].topics[1]) == m.index, "event session index");
            if (topic == PriceGate.Admitted.selector) {
                n[0]++;
                (uint64 at, uint64 priceAt) = abi.decode(logs[i].data, (uint64, uint64));
                _check(gi, at == t && priceAt == stamp, "Admitted fields");
            } else {
                if (topic == PriceGate.AdmissionReset.selector) n[1]++;
                else if (topic == PriceGate.OutageDetected.selector) n[2]++;
                else _violate(gi, "unexpected event");
                (uint64 at, uint32 reasons) = abi.decode(logs[i].data, (uint64, uint32));
                _check(gi, at == t && reasons == m.base, "reset or outage event fields");
                _check(gi, reasons & GATE_STATE_BITS == 0, "event reasons include gate-state bits");
            }
        }
        _check(gi, n[0] == (m.admit ? 1 : 0), "Admitted count");
        _check(gi, n[1] == (m.reset ? 1 : 0), "AdmissionReset count");
        _check(gi, n[2] == (m.outage ? 1 : 0), "OutageDetected count");
        _check(gi, n[3] == (m.checkpoint ? 1 : 0), "RecoveryCheckpoint count");
    }

    /// @dev A second refresh at the same time returns the same quote and changes nothing; the view agrees.
    function _checkIdempotent(uint256 gi, PriceGate.Quote memory q, Rec memory post) internal {
        PriceGate.Quote memory again = gates[gi].refresh();
        _check(gi, keccak256(abi.encode(again)) == keccak256(abi.encode(q)), "second refresh quote");
        _sameRec(gi, _read(gates[gi]), post, "second refresh");
        _check(gi, keccak256(abi.encode(gates[gi].quote())) == keccak256(abi.encode(q)), "view after refresh");
    }

    function _count(uint256 gi, Step memory m, PriceGate.Quote memory q, uint64 t) internal {
        refreshes++;
        if (q.reasons == 0) usable++;
        if (m.admit) admissions++;
        if (m.reset) resets++;
        if (m.outage) outages++;
        if (m.checkpoint) recoveries++;
        SessionCalendar.Context memory c = cal.context(t);
        if (gi == 0 && c.inSession && uint32(c.index + 1) != lastSid) {
            lastSid = uint32(c.index + 1);
            sessionsSeen++;
        }
    }

    // ---------------------------------------------------------------- guardian

    function _guardian(uint256 gi, uint256 kind, uint256 seed) internal {
        PriceGate g = gates[gi];
        uint64 t = uint64(block.timestamp);
        Rec memory pre = _read(g);
        Rec memory expected = _read(g);
        address who = guardian;
        bytes memory data;
        bytes memory err;
        if (kind == 0) {
            data = abi.encodeCall(PriceGate.stop, ());
            expected.stopped = true;
            expected.resumeAt = 0;
        } else if (kind <= 2) {
            data = abi.encodeCall(PriceGate.requestResume, ());
            if (!pre.stopped) err = abi.encodeWithSelector(PriceGate.NotStopped.selector);
            expected.resumeAt = t + 1 days;
        } else if (kind <= 5) {
            data = abi.encodeCall(PriceGate.resume, ());
            if (!pre.stopped) err = abi.encodeWithSelector(PriceGate.NotStopped.selector);
            else if (pre.resumeAt == 0) err = abi.encodeWithSelector(PriceGate.ResumeNotRequested.selector);
            else if (t < pre.resumeAt) err = abi.encodeWithSelector(PriceGate.ResumeTooEarly.selector, pre.resumeAt);
            expected.stopped = false;
            expected.resumeAt = 0;
            expected.outage = 0;
            expected.cp = t;
        } else {
            who = stranger;
            uint256 pick = seed % 3;
            data = pick == 0
                ? abi.encodeCall(PriceGate.stop, ())
                : pick == 1 ? abi.encodeCall(PriceGate.requestResume, ()) : abi.encodeCall(PriceGate.resume, ());
            err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        }

        vm.prank(who);
        (bool ok, bytes memory ret) = address(g).call(data);
        if (err.length != 0) {
            _check(gi, !ok && keccak256(ret) == keccak256(err), "guardian call: wrong outcome, expected a revert");
            _sameRec(gi, _read(g), pre, "rejected guardian call");
            rejectedCalls++;
            if (kind >= 3 && kind <= 5 && pre.stopped && pre.resumeAt != 0) earlyResumes++;
            return;
        }
        _check(gi, ok, "guardian call reverted");
        _sameRec(gi, _read(g), expected, "guardian call");
        if (kind == 0) {
            lastStopAt[gi] = t;
            stops++;
        } else if (kind <= 2) {
            lastRequestAt[gi] = t;
            requests++;
        } else {
            _check(gi, t >= uint256(lastStopAt[gi]) + 1 days, "resume within 24 h of the last stop");
            _check(gi, t >= uint256(lastRequestAt[gi]) + 1 days, "resume within 24 h of the last request");
            resumes++;
        }
    }
}

/// @notice Stateful invariants of PriceGate's refresh state machine and guardian controls over real sessions.
contract GateInvariantsTest is GateFixture {
    GateHandler internal handler;
    PriceGate internal pegGate;
    PriceGate internal feedGate;

    function setUp() public {
        vm.warp(MON_OPEN - 30 minutes);
        _setUpGate();
        ScriptedFeed stock = new ScriptedFeed(8);
        ScriptedFeed loan = new ScriptedFeed(8);
        ScriptedFeed seq = new ScriptedFeed(0);
        stock.set(TSLA_400, block.timestamp, block.timestamp);
        loan.set(1e8, block.timestamp, block.timestamp);
        seq.set(0, block.timestamp - 1 days, block.timestamp);

        PriceGate.Config memory c = _config();
        c.stockFeed = PriceGate.Feed(IAggregatorV3(address(stock)), 8, MOCK_MAX_AGE, ANSWER_BOUND);
        pegGate = new PriceGate(c);
        c.stockFeed.maxAge = 900;
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 3600, 2e8);
        c.pegLabel = "";
        c.sequencerFeed = IAggregatorV3(address(seq));
        c.sequencerGrace = 120;
        feedGate = new PriceGate(c);

        handler = new GateHandler(pegGate, feedGate, stock, loan, seq, tsla, address(this));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = GateHandler.step.selector;
        selectors[1] = GateHandler.jump.selector;
        selectors[2] = GateHandler.print.selector;
        selectors[3] = GateHandler.fault.selector;
        selectors[4] = GateHandler.guardianAct.selector;
        selectors[5] = GateHandler.quiet.selector;
        selectors[6] = GateHandler.creditBoundary.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("refreshes", handler.refreshes(), "usable", handler.usable());
        console.log("sessions", handler.sessionsSeen(), "admissions", handler.admissions());
        console.log("resets", handler.resets(), "outages", handler.outages());
        console.log("recoveries", handler.recoveries(), "stops", handler.stops());
        console.log("requests", handler.requests(), "resumes", handler.resumes());
        console.log("early resumes", handler.earlyResumes(), "rejected calls", handler.rejectedCalls());
        console.log("creditAt boundary hits", handler.boundaryHits());
    }

    /// INV-GATE-11, INV-GATE-12, INV-GATE-13, INV-GATE-14, INV-GATE-16, INV-GATE-17, INV-GATE-18, INV-GATE-21,
    /// INV-GATE-22, INV-GATE-23, INV-GATE-24, INV-GATE-26, INV-GATE-30, INV-GATE-32, INV-GATE-33, INV-GATE-34,
    /// INV-GATE-35, INV-GATE-36, INV-GATE-38, INV-GATE-39, INV-GATE-41, INV-GATE-42, INV-GATE-43, INV-GATE-44,
    /// INV-GATE-46, INV-GATE-49, INV-GATE-51 (and the surviving refresh, view and resume mutants): every refresh
    /// returns the modelled reasons, price and stamp, leaves the modelled records, emits exactly the modelled
    /// events (reset and outage events carry only source bits and STOPPED), agrees with the view on usability, is
    /// idempotent within a timestamp and never reverts; guardian calls succeed or revert exactly as specified, and
    /// every resume comes at least 24 h after the last stop and the last request.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 120
    function invariant_everyRefreshAndGuardianCallMatchesTheModel() public view {
        assertEq(handler.violation(), "");
    }

    /// INV-GATE-11, INV-GATE-12, INV-GATE-13, INV-GATE-32, INV-GATE-34, INV-GATE-36, INV-GATE-37, INV-GATE-41,
    /// INV-GATE-46: between any two calls, including after unobserved time, the records are consistent:
    /// admission fields set together and inside a covered session's admission window, an outage only for the
    /// admitted session, no resume request while running and none earlier than 24 h after the last stop,
    /// checkpoint and last-price times not in the future, an accepted price no older than maxAge when accepted,
    /// and the view and a refresh agree on usability.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 120
    function invariant_recordsStayConsistentBetweenCalls() public {
        _checkGate(pegGate, 0);
        _checkGate(feedGate, 1);
    }

    function _checkGate(PriceGate g, uint256 gi) internal {
        uint64 t = clock.time();
        uint32 admitted = g.admittedSession();
        assertEq(admitted == 0, g.admissionAt() == 0, "admission fields set together");
        if (admitted != 0) {
            assertLt(admitted, cal.sessionCount(), "the uncovered last session is never admitted");
            (uint64 o, uint64 c) = cal.sessionAt(admitted - 1);
            assertGe(g.admissionAt(), o + SessionTiming.ADMIT_AFTER, "admission at or after O + 5 minutes");
            assertLt(g.admissionAt(), c, "admission before the close");
            assertEq(g.admissionFor(admitted - 1), g.admissionAt());
            assertEq(g.admissionFor(admitted), 0);
        }
        if (g.outageSession() != 0) assertEq(g.outageSession(), admitted, "an outage only for the admitted session");
        if (!g.stopped()) {
            assertEq(g.resumeAvailableAt(), 0, "no resume request while running");
        } else if (g.resumeAvailableAt() != 0) {
            assertEq(g.resumeAvailableAt(), handler.lastRequestAt(gi) + 1 days, "request time plus 24 h");
            assertGe(g.resumeAvailableAt(), handler.lastStopAt(gi) + 1 days, "never before 24 h after the stop");
        }
        assertLe(g.checkpointAt(), t);
        assertLe(g.lastAcceptedAt(), t);
        assertLe(g.lastUpdatedAt(), g.lastAcceptedAt());
        if (g.lastAcceptedAt() != 0) {
            assertLe(g.lastAcceptedAt() - g.lastUpdatedAt(), g.stockMaxAge(), "accepted within maxAge");
            assertGt(g.lastPriceWad(), 0);
        }

        PriceGate.Quote memory v = g.quote();
        assertLt(v.reasons, uint32(1) << 21);
        if (g.stopped()) assertTrue(v.reasons & Reasons.STOPPED != 0, "stopped gate quotes STOPPED");
        uint256 snap = vm.snapshotState();
        PriceGate.Quote memory r = g.refresh();
        vm.revertToState(snap);
        assertEq(v.reasons == 0, r.reasons == 0, "view and refresh agree on usability");
    }
}
