// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IClock} from "./interfaces/IClock.sol";
import {SessionCalendar} from "./SessionCalendar.sol";
import {PriceGate} from "./PriceGate.sol";
import {Reasons} from "./libraries/Reasons.sol";
import {SessionTiming} from "./libraries/SessionTiming.sol";

/// @title SessionRiskPolicy
/// @notice View-only session policy: market state, liquidation threshold LT, borrow limit B, trim target,
/// bonus and action permissions at a given time (docs/SPEC.md §3, §6 and appendix R1).
///
/// All ratios are WAD (1e18 = 100%). Values are illustrative product fixtures, fixed per deployment.
contract SessionRiskPolicy {
    enum State {
        OPEN,
        PRE_CLOSE,
        FINAL_WINDOW,
        CLOSED,
        REOPEN_WAIT,
        REOPEN_RECOVERY,
        GUARDED
    }

    enum ClosureClass {
        OVERNIGHT,
        EXTENDED
    }

    struct Snapshot {
        uint64 time;
        State state; // effective state
        State phase; // schedule phase; differs from `state` only when the market is GUARDED
        ClosureClass closureClass; // the close whose limits apply now
        bool covered; // inside the loaded calendar
        uint32 reasons; // PriceGate reasons; zero when the price is usable
        uint256 priceWad;
        uint64 priceUpdatedAt;
        uint256 session; // calendar index: the current session, or the last one closed
        uint64 open;
        uint64 close;
        uint64 prepAt; // A = C - 120 min
        uint64 finalAt; // F = C - 30 min
        uint64 nextOpen;
        uint64 admissionAt; // zero until a reopening price is admitted for `session`
        uint64 creditAt; // when new credit returns; zero until admission
        uint64 guardAt; // O + 30 min: GUARDED if no admission by then
        uint256 ltWad;
        uint256 borrowLimitWad; // zero whenever borrowing is not allowed
        uint256 targetWad;
        bool canBorrow; // new debt and debt-backed collateral withdrawal, within B
        bool canTrim; // partial liquidation of positions strictly above LT
        bool canBuffer; // executeBuffer toward the borrower's authorized target
        bool lenderOpen; // ERC-4626 deposits, mints, withdrawals and redemptions
        bool windDown; // the loaded calendar has ended: lenders may exit against idle cash, nothing else
    }

    uint256 public constant LT_OPEN = 0.8e18;
    uint256 public constant B_OPEN = 0.75e18;
    uint256 public constant TARGET_OPEN = 0.75e18;
    uint256 public constant BORROW_GAP = 0.05e18;
    uint256 public constant LT_FINAL_OVERNIGHT = 0.77e18;
    uint256 public constant TARGET_OVERNIGHT = 0.72e18;
    uint256 public constant LT_FINAL_EXTENDED = 0.7e18;
    uint256 public constant TARGET_EXTENDED = 0.65e18;
    uint256 public constant BONUS_SCHEDULING = 0.02e18;
    uint256 public constant BONUS_DISTRESS = 0.05e18;

    SessionCalendar public immutable calendar;
    PriceGate public immutable gate;
    IClock public immutable clock;

    constructor(PriceGate gate_) {
        gate = gate_;
        calendar = gate_.calendar();
        clock = gate_.clock();
    }

    /// @notice Policy now, using the gate's current view quote (no state change).
    function snapshot() external view returns (Snapshot memory) {
        return evaluate(gate.quote(), clock.time());
    }

    /// @notice Policy at time `t` for quote `q`. The market passes the quote returned by `gate.refresh()`.
    function evaluate(PriceGate.Quote memory q, uint64 t) public view returns (Snapshot memory s) {
        s.time = t;
        s.reasons = q.reasons;
        s.priceWad = q.priceWad;
        s.priceUpdatedAt = q.updatedAt;

        SessionCalendar.Context memory ctx = calendar.context(t);
        s.covered = ctx.covered;
        if (!ctx.covered) {
            s.windDown = t >= calendar.lastOpen();
            s.state = State.GUARDED;
            s.phase = State.GUARDED;
            s.closureClass = ClosureClass.EXTENDED;
            s.ltWad = LT_FINAL_EXTENDED;
            s.targetWad = TARGET_EXTENDED;
            return s;
        }

        s.session = ctx.index;
        s.open = ctx.open;
        s.close = ctx.close;
        s.prepAt = ctx.close - SessionTiming.PREP;
        s.finalAt = ctx.close - SessionTiming.FINAL;
        s.nextOpen = ctx.nextOpen;
        s.guardAt = ctx.open + SessionTiming.GUARD_AFTER;
        s.admissionAt = gate.admissionFor(ctx.index);
        if (s.admissionAt != 0) s.creditAt = SessionTiming.creditAt(ctx.open, s.admissionAt);

        ClosureClass closing = classOf(ctx.nextOpen - ctx.close);
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

        s.state = s.phase;
        bool priced = s.phase != State.CLOSED && s.phase != State.REOPEN_WAIT;
        if (
            q.reasons & Reasons.STOPPED != 0 || (priced && q.reasons != 0)
                || (s.phase == State.REOPEN_WAIT && t >= s.guardAt)
        ) {
            s.state = State.GUARDED;
        }

        State st = s.state;
        s.canBorrow = st == State.OPEN || st == State.PRE_CLOSE;
        s.canTrim = st == State.OPEN || st == State.PRE_CLOSE || st == State.FINAL_WINDOW || st == State.REOPEN_RECOVERY;
        s.canBuffer = st == State.PRE_CLOSE || st == State.FINAL_WINDOW;
        s.lenderOpen = st == State.OPEN;
        if (!s.canBorrow) s.borrowLimitWad = 0;
    }

    /// @notice Liquidation bonus for a trim of a position at `ltvWad`, or zero where trims are not allowed.
    function bonusFor(Snapshot memory s, uint256 ltvWad) public pure returns (uint256) {
        if (!s.canTrim) return 0;
        if (s.state == State.PRE_CLOSE || s.state == State.FINAL_WINDOW) {
            return ltvWad > LT_OPEN ? BONUS_DISTRESS : BONUS_SCHEDULING;
        }
        return BONUS_DISTRESS; // OPEN and REOPEN_RECOVERY
    }

    /// @notice A position is eligible for a trim only when its LTV is strictly above LT.
    function trimEligible(Snapshot memory s, uint256 ltvWad) public pure returns (bool) {
        return s.canTrim && ltvWad > s.ltWad;
    }

    /// @notice EXTENDED when the next open is at least 24 hours after the close, otherwise OVERNIGHT.
    function classOf(uint64 gapSeconds) public pure returns (ClosureClass) {
        return gapSeconds >= SessionTiming.EXTENDED_GAP ? ClosureClass.EXTENDED : ClosureClass.OVERNIGHT;
    }

    function ltFinalOf(ClosureClass c) public pure returns (uint256) {
        return c == ClosureClass.EXTENDED ? LT_FINAL_EXTENDED : LT_FINAL_OVERNIGHT;
    }

    function targetOf(ClosureClass c) public pure returns (uint256) {
        return c == ClosureClass.EXTENDED ? TARGET_EXTENDED : TARGET_OVERNIGHT;
    }

    /// @notice LT at `t` for a close at `close`: 80% until A, linear to the class value at F, flat after.
    /// The decrement rounds up, so LT rounds down (toward the stricter threshold).
    function ltAt(ClosureClass c, uint64 t, uint64 close) public pure returns (uint256) {
        uint64 a = close - SessionTiming.PREP;
        uint64 f = close - SessionTiming.FINAL;
        uint256 ltFinal = ltFinalOf(c);
        if (t <= a) return LT_OPEN;
        if (t >= f) return ltFinal;
        return LT_OPEN - Math.mulDiv(LT_OPEN - ltFinal, t - a, f - a, Math.Rounding.Ceil);
    }

    /// @notice B = min(75%, LT - 5%).
    function borrowLimit(uint256 ltWad) public pure returns (uint256) {
        uint256 b = ltWad - BORROW_GAP;
        return b < B_OPEN ? b : B_OPEN;
    }

    function _closedLimits(Snapshot memory s, ClosureClass c) private pure {
        s.closureClass = c;
        s.ltWad = ltFinalOf(c);
        s.targetWad = targetOf(c);
    }
}
