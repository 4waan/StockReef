// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClock} from "./interfaces/IClock.sol";
import {SessionCalendar} from "./SessionCalendar.sol";
import {PriceGate} from "./PriceGate.sol";
import {Reasons} from "./libraries/Reasons.sol";
import {SessionRules} from "./libraries/SessionRules.sol";
import {SessionTiming} from "./libraries/SessionTiming.sol";

/// @title SessionRiskPolicy
/// @notice Read-only session rules for a StockReef market. For a time and a PriceGate quote it reports the market
/// state, the liquidation threshold LT, the borrow limit B, the target LTV after a trim and which actions are
/// allowed: borrowing, trims, buffer repayments and lender entry and exit. `bonusFor` gives the trim bonus for a
/// snapshot (docs/SPEC.md §3 and §6; appendix R1 and R17).
/// @dev Units: LT, B, targets, bonuses, LTVs and `priceWad` are WAD (1e18 = 100% or 1.0); `priceWad` is loan-token
/// whole units per collateral whole unit, scaled by 1e18. Times are UTC seconds from `clock` (a DemoClock on demo
/// deployments); durations are seconds. Every limit is a compile-time constant: the values are illustrative
/// product fixtures, not calibrated limits, and a different policy needs a new deployment.
///
/// Phase and state: the schedule phase comes from `calendar` and the gate's admission record. It is CLOSED
/// between sessions, REOPEN_WAIT in a session without an admitted reopening price, REOPEN_RECOVERY from admission
/// until SessionTiming.creditAt, then OPEN until A = C - 120 min, PRE_CLOSE until F = C - 30 min and
/// FINAL_WINDOW until the close C (a late admission skips the phases whose time has passed). The effective state
/// is the phase, or GUARDED when the quote carries Reasons.STOPPED (the gate is stopped) in any phase, when the
/// quote has any reason in a phase other than CLOSED and REOPEN_WAIT, or when REOPEN_WAIT lasts to O + 30 min.
/// Outside calendar coverage both are GUARDED, and from the open of the last loaded session the snapshot reports
/// wind-down (appendix R17). The last covered session ends in that permanent closure, so its close is EXTENDED
/// and it gives no new credit (appendix R19).
///
/// Trust: no owner, no storage writes and no admin functions. It trusts the PriceGate it is built with and the
/// SessionCalendar and IClock taken from that gate.
///
/// Invariants of every snapshot from `evaluate`: `borrowLimitWad` is zero unless `canBorrow`, and otherwise at
/// most both B_OPEN and LT - BORROW_GAP; `targetWad` is below `ltWad`; `lenderOpen` implies `canBorrow` except in
/// the last covered session; `canBuffer` implies `canTrim`; `windDown` implies `covered` is false and all four permission flags are false
/// (StockReefMarket still lets lenders exit on `windDown`).
contract SessionRiskPolicy {
    /// @notice Market states of docs/SPEC.md §3. Inside calendar coverage the schedule phase is one of the first
    /// six; GUARDED is the effective state that overrides the phase, and the phase outside coverage.
    enum State {
        OPEN, // after reopening recovery until A: LT 80%, B 75%, target 75%
        PRE_CLOSE, // A <= t < F: LT falls to the class value, B follows it
        FINAL_WINDOW, // F <= t < C: class LT and target, trims and buffers only
        CLOSED, // C until the next open: no price-dependent action
        REOPEN_WAIT, // from O until a reopening price is admitted: no price-dependent action
        REOPEN_RECOVERY, // from admission until new credit returns: trims only, at the ended closure's LT and target
        GUARDED // stopped, unusable price in a priced phase, no admission by O + 30 min, or outside the calendar
    }

    /// @notice Class of a scheduled close, chosen from the gap to the next scheduled open (appendix R1).
    enum ClosureClass {
        OVERNIGHT, // next open less than 24 hours after the close: LT 77% at F, target 72%
        EXTENDED // next open 24 hours or more after the close (weekends, holidays): LT 70% at F, target 65%
    }

    /// @notice The policy at one time for one quote: state, schedule times, limits and permissions.
    /// @dev Fields that do not apply stay zero. `closureClass` is the class of the close C of `session` in OPEN,
    /// PRE_CLOSE, FINAL_WINDOW and CLOSED, the class of the closure that ended at O in REOPEN_WAIT and
    /// REOPEN_RECOVERY (EXTENDED for the first loaded session), and EXTENDED outside calendar coverage; a GUARDED
    /// state keeps the class of its phase. Outside calendar coverage only `time`, the quote fields
    /// (`reasons`, `priceWad`, `priceUpdatedAt`), `state`, `phase`, `closureClass`, `ltWad`, `targetWad` and
    /// `windDown` are set; `covered` is false and every permission is false.
    struct Snapshot {
        uint64 time; // evaluation time, UTC seconds
        State state; // effective state: `phase`, or GUARDED
        State phase; // schedule phase; differs from `state` only when the market is GUARDED
        ClosureClass closureClass; // class whose limits apply now: of the session's close, or of the closure before O
        bool covered; // the calendar knows the current or last-closed session and the next open after it
        uint32 reasons; // PriceGate Reasons bits from the quote; zero when the price is usable
        uint256 priceWad; // WAD loan-token whole units per collateral whole unit; usable only when `reasons` is 0
        uint64 priceUpdatedAt; // stock feed timestamp of the quote, UTC seconds
        uint256 session; // calendar index: the current session, or the last one closed; zero when not covered
        uint64 open; // O: open of `session`, UTC seconds
        uint64 close; // C: close of `session`, UTC seconds
        uint64 prepAt; // A = C - 120 min, UTC seconds
        uint64 finalAt; // F = C - 30 min, UTC seconds
        uint64 nextOpen; // open of the session after `session`, UTC seconds
        uint64 admissionAt; // UTC seconds; zero while the gate holds no reopening admission for `session`
        uint64 creditAt; // max(O + 15 min, admissionAt + 10 min): when new credit returns; zero until admission
        uint64 guardAt; // O + 30 min: GUARDED if no admission by then
        uint256 ltWad; // liquidation threshold LT, WAD
        uint256 borrowLimitWad; // borrow limit B, WAD; zero whenever borrowing is not allowed
        uint256 targetWad; // target LTV T after a trim, WAD
        bool canBorrow; // new debt and debt-backed collateral withdrawal, within B
        bool canTrim; // partial liquidation of positions strictly above LT
        bool canBuffer; // executeBuffer toward the borrower's authorized target (preparation and recovery)
        bool lenderOpen; // ERC-4626 deposits, mints, withdrawals and redemptions
        bool windDown; // from the open of the last loaded session: lender exits against idle cash only (appendix R17)
    }

    /// @notice Liquidation threshold LT in OPEN and at the start of PRE_CLOSE, WAD (0.8e18 = 80%).
    uint256 public constant LT_OPEN = SessionRules.LT_OPEN;
    /// @notice Borrow limit B in OPEN and the cap on B in PRE_CLOSE, WAD (0.75e18 = 75%).
    uint256 public constant B_OPEN = SessionRules.B_OPEN;
    /// @notice Target LTV after a trim in OPEN, WAD (0.75e18 = 75%).
    uint256 public constant TARGET_OPEN = SessionRules.TARGET_OPEN;
    /// @notice Margin kept between B and LT: B = min(B_OPEN, LT - BORROW_GAP), WAD (0.05e18 = 5%).
    uint256 public constant BORROW_GAP = SessionRules.BORROW_GAP;
    /// @notice LT of an OVERNIGHT close from F, through the closure and the reopening after it, WAD (0.77e18 = 77%).
    uint256 public constant LT_FINAL_OVERNIGHT = SessionRules.LT_FINAL_OVERNIGHT;
    /// @notice Target LTV after a trim for an OVERNIGHT close, from A through reopening recovery, WAD
    /// (0.72e18 = 72%).
    uint256 public constant TARGET_OVERNIGHT = SessionRules.TARGET_OVERNIGHT;
    /// @notice LT of an EXTENDED close from F, through the closure and the reopening after it, and outside
    /// calendar coverage, WAD (0.7e18 = 70%).
    uint256 public constant LT_FINAL_EXTENDED = SessionRules.LT_FINAL_EXTENDED;
    /// @notice Target LTV after a trim for an EXTENDED close, from A through reopening recovery, and outside
    /// calendar coverage, WAD (0.65e18 = 65%).
    uint256 public constant TARGET_EXTENDED = SessionRules.TARGET_EXTENDED;
    /// @notice Trim bonus in PRE_CLOSE and FINAL_WINDOW for a position at or below LT_OPEN (a scheduling-only
    /// trim), WAD (0.02e18 = 2%). The liquidator receives collateral worth at most the repayment times (1 + bonus).
    uint256 public constant BONUS_SCHEDULING = SessionRules.BONUS_SCHEDULING;
    /// @notice Trim bonus in OPEN and REOPEN_RECOVERY, and in PRE_CLOSE and FINAL_WINDOW for a position above
    /// LT_OPEN, WAD (0.05e18 = 5%).
    uint256 public constant BONUS_DISTRESS = SessionRules.BONUS_DISTRESS;

    /// @notice Session schedule (UTC), taken from the gate at construction.
    SessionCalendar public immutable calendar;
    /// @notice Price gate whose quotes and reopening admissions the policy reads.
    PriceGate public immutable gate;
    /// @notice Time source shared with the gate, UTC seconds (a DemoClock on demo deployments); taken from the gate.
    IClock public immutable clock;
    /// @dev Number of sessions in `calendar`, fixed at deployment; session SESSION_COUNT - 2 is the last covered one.
    uint256 private immutable SESSION_COUNT;

    /// @notice Deploys the policy for `gate_`, taking the gate's calendar and clock so all three share one schedule
    /// and one time source.
    /// @dev Reverts if `gate_` does not answer `calendar()` and `clock()`. Nothing else is checked.
    /// @param gate_ Price gate of the market this policy serves.
    constructor(PriceGate gate_) {
        gate = gate_;
        calendar = gate_.calendar();
        clock = gate_.clock();
        SESSION_COUNT = gate_.calendar().sessionCount();
    }

    /// @notice The policy now, at the clock time, for the gate's current view quote. Changes nothing.
    /// @dev Uses `gate.quote()`, which records no admission, outage or checkpoint. It can therefore show
    /// REOPEN_WAIT (or GUARDED from O + 30 min) where a `gate.refresh()` at the same time would admit a reopening
    /// price, so views can differ from what a state-changing call sees. StockReefLens, the market's ERC-4626
    /// `max*` functions and RepaymentEscrow.committed use it. Anyone may call it; it reverts only when `evaluate`
    /// does, or when `gate.quote()` or `clock.time()` reverts.
    /// @return The snapshot at `clock.time()`; see Snapshot for fields and units.
    function snapshot() external view returns (Snapshot memory) {
        return evaluate(gate.quote(), clock.time());
    }

    /// @notice The policy at time `t` for quote `q`. State-changing callers (StockReefMarket, RepaymentEscrow) pass
    /// the quote returned by `gate.refresh()` and the clock time of the same transaction.
    /// @dev View; anyone may call it. It has no custom errors; it reverts when a calendar or gate call reverts,
    /// or on underflow for a session that closes before 7200 (120 minutes after time zero). The admission time
    /// comes from the gate's current record (`gate.admissionFor`), so a `t` other than the clock time combines
    /// that time with the current record: a session other than the most recently admitted one reads as not
    /// admitted.
    /// - Outside calendar coverage: state and phase GUARDED, EXTENDED limits (LT 70%, target 65%), no
    ///   permissions, and `windDown` from the open of the last loaded session (docs/SPEC.md §3, appendix R17).
    /// - Phase inside coverage: CLOSED from C to the next open, with the class of that closure (the close C of
    ///   `session`); REOPEN_WAIT before admission and REOPEN_RECOVERY until `creditAt`, both with the class of the
    ///   closure that ended at O (EXTENDED for the first loaded session); then OPEN before A with the OPEN limits,
    ///   PRE_CLOSE before F with LT = ltAt(...) and B = borrowLimit(LT), and FINAL_WINDOW until C, the last two
    ///   with the class of the coming close (docs/SPEC.md §3 and §6, appendix R1). A late admission can go from
    ///   REOPEN_RECOVERY straight to PRE_CLOSE, FINAL_WINDOW or CLOSED; a session never admitted stays in
    ///   REOPEN_WAIT until C. The last covered session (index + 2 == sessionCount) closes into wind-down, which
    ///   never reopens: its close is EXTENDED and it allows no borrowing (appendix R19).
    /// - State: GUARDED when `q.reasons` has Reasons.STOPPED, when it has any bit in a phase other than CLOSED and
    ///   REOPEN_WAIT, or in REOPEN_WAIT from O + 30 min (docs/SPEC.md §6 step 5); otherwise the phase.
    /// - Permissions follow the state: borrow in OPEN and PRE_CLOSE; trim in OPEN, PRE_CLOSE, FINAL_WINDOW and
    ///   REOPEN_RECOVERY; buffer in PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY (appendix R20); lender entry and
    ///   exit in OPEN. B is set to zero whenever borrowing is not allowed; LT and target stay set in every state.
    /// @param q Price quote from the gate; its reasons decide GUARDED and its price fields are copied unchanged.
    /// @param t Evaluation time, UTC seconds.
    /// @return s The snapshot; see Snapshot for fields and units.
    function evaluate(PriceGate.Quote memory q, uint64 t) public view returns (Snapshot memory s) {
        s.time = t;
        s.reasons = q.reasons;
        s.priceWad = q.priceWad;
        s.priceUpdatedAt = q.updatedAt;

        SessionCalendar.Context memory ctx = calendar.context(t);
        s.covered = ctx.covered;
        if (!ctx.covered) {
            _uncovered(s, t);
            return s;
        }
        _schedule(s, ctx);
        bool terminal = ctx.index + 2 == SESSION_COUNT;
        _phaseAndLimits(s, ctx, t, terminal);
        s.state = _effectiveState(s.phase, q.reasons, t >= s.guardAt);
        _permissions(s, terminal);
    }

    /// @notice Liquidation bonus for a trim of a position at `ltvWad`, or zero where trims are not allowed.
    /// @dev Zero unless `s.canTrim`. In PRE_CLOSE and FINAL_WINDOW: BONUS_DISTRESS (5%) when `ltvWad` is strictly
    /// above LT_OPEN (80%), otherwise BONUS_SCHEDULING (2%). In any other state that allows trims (OPEN and
    /// REOPEN_RECOVERY for snapshots from `evaluate`): BONUS_DISTRESS (docs/SPEC.md §3, appendix R1). It does not
    /// check trim eligibility; StockReefMarket passes the LTV rounded up. The liquidator receives collateral worth
    /// at most the repayment times (1 + bonus) (docs/SPEC.md §5). Anyone may call it; it never reverts.
    /// @param s Policy snapshot; only `canTrim` and `state` are read.
    /// @param ltvWad Position LTV (accrued debt divided by collateral value), WAD.
    /// @return Bonus, WAD: BONUS_DISTRESS, BONUS_SCHEDULING, or zero when `s.canTrim` is false.
    function bonusFor(Snapshot memory s, uint256 ltvWad) public pure returns (uint256) {
        if (!s.canTrim) return 0;
        return SessionRules.bonus(isPreparing(s.state), ltvWad);
    }

    /// @notice A position is eligible for a trim only when its LTV is strictly above LT.
    /// @dev Requires `s.canTrim` and `ltvWad > s.ltWad`; equality is not eligible (docs/SPEC.md §3).
    /// StockReefMarket.quoteTrim applies the same rule to the amounts rather than to a rounded LTV (debt * 1e18 >
    /// LT * value, with debt rounded up and value rounded down) instead of calling this function. Anyone may call
    /// it; it never reverts.
    /// @param s Policy snapshot; only `canTrim` and `ltWad` are read.
    /// @param ltvWad Position LTV (accrued debt divided by collateral value), WAD.
    /// @return True when trims are allowed and `ltvWad` is strictly above `s.ltWad`.
    function trimEligible(Snapshot memory s, uint256 ltvWad) public pure returns (bool) {
        return s.canTrim && ltvWad > s.ltWad;
    }

    /// @notice EXTENDED when the next open is at least 24 hours after the close, otherwise OVERNIGHT (appendix R1).
    /// @dev `evaluate` applies it to nextOpen - close for the coming close and to open - prevClose for the closure
    /// that ended at O. The boundary is inclusive: a gap of exactly 24 hours is EXTENDED. Never reverts.
    /// @param gapSeconds Seconds from a scheduled close to the next scheduled open.
    /// @return EXTENDED when `gapSeconds` is at least SessionTiming.EXTENDED_GAP (24 hours), otherwise OVERNIGHT.
    function classOf(uint64 gapSeconds) public pure returns (ClosureClass) {
        return SessionRules.isExtended(gapSeconds) ? ClosureClass.EXTENDED : ClosureClass.OVERNIGHT;
    }

    /// @notice LT reached at F for closure class `c`, which also applies through the closure and the reopening
    /// after it (appendix R1).
    /// @dev Also the end point of the PRE_CLOSE ramp in `ltAt`. Never reverts.
    /// @param c Closure class.
    /// @return LT, WAD: LT_FINAL_EXTENDED (70%) for EXTENDED, LT_FINAL_OVERNIGHT (77%) for OVERNIGHT.
    function ltFinalOf(ClosureClass c) public pure returns (uint256) {
        return SessionRules.ltFinal(c == ClosureClass.EXTENDED);
    }

    /// @notice Target LTV after a trim for closure class `c`, which applies from A through reopening recovery
    /// (appendix R1).
    /// @dev `evaluate` uses it from PRE_CLOSE through REOPEN_RECOVERY; OPEN uses TARGET_OPEN. Never reverts.
    /// @param c Closure class.
    /// @return Target, WAD: TARGET_EXTENDED (65%) for EXTENDED, TARGET_OVERNIGHT (72%) for OVERNIGHT.
    function targetOf(ClosureClass c) public pure returns (uint256) {
        return SessionRules.target(c == ClosureClass.EXTENDED);
    }

    /// @notice LT at `t` for a close at `close`: 80% until A, linear to the class value at F, flat after.
    /// The decrement rounds up, so LT rounds down (toward the stricter threshold).
    /// @dev LT(t) = LT_OPEN - (LT_OPEN - LT_F) * (t - A) / (F - A) with A = close - 120 min, F = close - 30 min
    /// and LT_F = ltFinalOf(c) (docs/SPEC.md §3, appendix R1). It does not check that `t` is before `close`.
    /// Reverts on underflow if `close` is below 7200 (120 minutes after time zero).
    /// @param c Closure class of the close.
    /// @param t Time, UTC seconds.
    /// @param close Scheduled close C, UTC seconds.
    /// @return LT, WAD, between ltFinalOf(c) and LT_OPEN.
    function ltAt(ClosureClass c, uint64 t, uint64 close) public pure returns (uint256) {
        return SessionRules.ltAt(c == ClosureClass.EXTENDED, t, close);
    }

    /// @notice B = min(75%, LT - 5%).
    /// @dev Computes min(B_OPEN, ltWad - BORROW_GAP) exactly, with no rounding (docs/SPEC.md §3, appendix R1).
    /// `evaluate` uses it in PRE_CLOSE, where B falls from 75% toward 72% (OVERNIGHT) or 65% (EXTENDED). Reverts
    /// on underflow if `ltWad` is below BORROW_GAP.
    /// @param ltWad Liquidation threshold LT, WAD.
    /// @return Borrow limit B, WAD.
    function borrowLimit(uint256 ltWad) public pure returns (uint256) {
        return SessionRules.borrowLimit(ltWad);
    }

    /// @dev True in the preparation states PRE_CLOSE and FINAL_WINDOW, where a position at or below LT_OPEN is
    /// trimmed at the scheduling bonus.
    /// @param st Effective state.
    function isPreparing(State st) internal pure returns (bool) {
        return st == State.PRE_CLOSE || st == State.FINAL_WINDOW;
    }

    /// @dev Outside calendar coverage: state and phase GUARDED, EXTENDED limits, no permissions, and `windDown`
    /// from the open of the last loaded session (appendix R17).
    /// @param s Snapshot being built, modified in place.
    /// @param t Evaluation time, UTC seconds.
    function _uncovered(Snapshot memory s, uint64 t) private view {
        s.windDown = t >= calendar.lastOpen();
        s.state = State.GUARDED;
        s.phase = State.GUARDED;
        _closedLimits(s, ClosureClass.EXTENDED);
    }

    /// @dev Schedule times of the covered session in `ctx`, and the gate's admission and credit times for it.
    /// @param s Snapshot being built, modified in place.
    /// @param ctx Calendar context at the evaluation time; covered.
    function _schedule(Snapshot memory s, SessionCalendar.Context memory ctx) private view {
        s.session = ctx.index;
        s.open = ctx.open;
        s.close = ctx.close;
        s.prepAt = ctx.close - SessionTiming.PREP;
        s.finalAt = ctx.close - SessionTiming.FINAL;
        s.nextOpen = ctx.nextOpen;
        s.guardAt = ctx.open + SessionTiming.GUARD_AFTER;
        s.admissionAt = gate.admissionFor(ctx.index);
        if (s.admissionAt != 0) s.creditAt = SessionTiming.creditAt(ctx.open, s.admissionAt);
    }

    /// @dev Schedule phase and the limits that apply in it (docs/SPEC.md §3 and §6, appendix R1): CLOSED with the
    /// class of the close C of `session`; REOPEN_WAIT and REOPEN_RECOVERY with the class of the closure that ended
    /// at O (EXTENDED for the first loaded session); OPEN with the OPEN limits; PRE_CLOSE on the LT ramp; and
    /// FINAL_WINDOW with the class of the coming close. The close of the last covered session is EXTENDED
    /// whatever its gap, because wind-down follows it and no session reopens.
    /// @param s Snapshot being built, with its schedule set; modified in place.
    /// @param ctx Calendar context at `t`; covered.
    /// @param t Evaluation time, UTC seconds.
    /// @param terminal `ctx` is the last covered session.
    function _phaseAndLimits(Snapshot memory s, SessionCalendar.Context memory ctx, uint64 t, bool terminal)
        private
        pure
    {
        ClosureClass closing = terminal ? ClosureClass.EXTENDED : classOf(ctx.nextOpen - ctx.close);
        ClosureClass opening = ctx.index == 0 ? ClosureClass.EXTENDED : classOf(ctx.open - ctx.prevClose);

        if (!ctx.inSession) {
            s.phase = State.CLOSED;
            _closedLimits(s, closing);
        } else if (s.admissionAt == 0) {
            s.phase = State.REOPEN_WAIT;
            _closedLimits(s, opening);
        } else if (t < s.creditAt) {
            s.phase = State.REOPEN_RECOVERY;
            _closedLimits(s, opening);
        } else if (t < s.prepAt) {
            s.phase = State.OPEN;
            s.closureClass = closing;
            s.ltWad = LT_OPEN;
            s.borrowLimitWad = B_OPEN;
            s.targetWad = TARGET_OPEN;
        } else if (t < s.finalAt) {
            s.phase = State.PRE_CLOSE;
            s.closureClass = closing;
            s.ltWad = ltAt(closing, t, ctx.close);
            s.borrowLimitWad = borrowLimit(s.ltWad);
            s.targetWad = targetOf(closing);
        } else {
            s.phase = State.FINAL_WINDOW;
            _closedLimits(s, closing);
        }
    }

    /// @dev The effective state: GUARDED when `reasons` has Reasons.STOPPED, when it has any bit in a phase that
    /// uses the price (any phase other than CLOSED and REOPEN_WAIT), or in REOPEN_WAIT from O + 30 min
    /// (docs/SPEC.md §6 step 5); otherwise the phase.
    /// @param phase Schedule phase.
    /// @param reasons PriceGate Reasons bits of the quote.
    /// @param pastGuard The evaluation time is at or after O + 30 min.
    function _effectiveState(State phase, uint32 reasons, bool pastGuard) private pure returns (State) {
        bool priced = phase != State.CLOSED && phase != State.REOPEN_WAIT;
        if (reasons & Reasons.STOPPED != 0 || (priced && reasons != 0) || (phase == State.REOPEN_WAIT && pastGuard)) {
            return State.GUARDED;
        }
        return phase;
    }

    /// @dev Permissions from the effective state: borrow in OPEN and PRE_CLOSE, except in the last covered session
    /// (appendix R19); trim in OPEN, PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY; buffer in PRE_CLOSE,
    /// FINAL_WINDOW and REOPEN_RECOVERY, so a funded buffer also runs before recovery trims (appendix R20); lender
    /// entry and exit in OPEN. B is cleared whenever borrowing is not allowed (for example GUARDED during
    /// PRE_CLOSE).
    /// @param s Snapshot being built, with its state set; modified in place.
    /// @param terminal The snapshot's session is the last covered one.
    function _permissions(Snapshot memory s, bool terminal) private pure {
        State st = s.state;
        s.canBorrow = !terminal && (st == State.OPEN || st == State.PRE_CLOSE);
        s.canTrim = st == State.OPEN || isPreparing(st) || st == State.REOPEN_RECOVERY;
        s.canBuffer = isPreparing(st) || st == State.REOPEN_RECOVERY;
        s.lenderOpen = st == State.OPEN;
        if (!s.canBorrow) s.borrowLimitWad = 0;
    }

    /// @dev Writes the limits of closure class `c` into `s`: `closureClass`, LT = ltFinalOf(c) and target =
    /// targetOf(c). Used outside coverage and for FINAL_WINDOW, CLOSED, REOPEN_WAIT and REOPEN_RECOVERY;
    /// `borrowLimitWad` stays zero.
    /// @param s Snapshot being built, modified in place.
    /// @param c Closure class whose limits apply.
    function _closedLimits(Snapshot memory s, ClosureClass c) private pure {
        s.closureClass = c;
        s.ltWad = ltFinalOf(c);
        s.targetWad = targetOf(c);
    }
}
