// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SessionTiming} from "./SessionTiming.sol";

/// @title SessionRules
/// @notice The session limits and the pure rules that pick them: closure class, the LT ramp, the borrow limit B,
/// closure targets and the trim bonus (docs/SPEC.md §3, appendix R1). SessionRiskPolicy exposes them in its ABI;
/// the market and the lens use them directly, so each rule is written once and needs no external call.
/// @dev Ratios are WAD (1e18 = 100%); times are UTC seconds. A closure class is passed as `extended`: true for an
/// EXTENDED close (the next open at least 24 hours later), false for OVERNIGHT. The values are illustrative
/// product fixtures compiled into each contract; no role can change them.
library SessionRules {
    /// @dev Liquidation threshold LT in OPEN and at the start of PRE_CLOSE (80%).
    uint256 internal constant LT_OPEN = 0.8e18;
    /// @dev Borrow limit B in OPEN and the cap on B in PRE_CLOSE (75%).
    uint256 internal constant B_OPEN = 0.75e18;
    /// @dev Target LTV after a trim in OPEN (75%).
    uint256 internal constant TARGET_OPEN = 0.75e18;
    /// @dev Margin kept between B and LT: B = min(B_OPEN, LT - BORROW_GAP) (5%).
    uint256 internal constant BORROW_GAP = 0.05e18;
    /// @dev LT of an OVERNIGHT close from F through the reopening after it (77%).
    uint256 internal constant LT_FINAL_OVERNIGHT = 0.77e18;
    /// @dev Target of an OVERNIGHT close from A through reopening recovery (72%).
    uint256 internal constant TARGET_OVERNIGHT = 0.72e18;
    /// @dev LT of an EXTENDED close from F through the reopening after it, and outside calendar coverage (70%).
    uint256 internal constant LT_FINAL_EXTENDED = 0.7e18;
    /// @dev Target of an EXTENDED close from A through reopening recovery, and outside calendar coverage (65%).
    uint256 internal constant TARGET_EXTENDED = 0.65e18;
    /// @dev Trim bonus in PRE_CLOSE and FINAL_WINDOW for a position at or below LT_OPEN (2%).
    uint256 internal constant BONUS_SCHEDULING = 0.02e18;
    /// @dev Trim bonus in OPEN and REOPEN_RECOVERY, and in PRE_CLOSE and FINAL_WINDOW above LT_OPEN (5%).
    uint256 internal constant BONUS_DISTRESS = 0.05e18;

    /// @dev True when a close followed by the next open `gapSeconds` later is EXTENDED: a gap of at least
    /// SessionTiming.EXTENDED_GAP (24 hours), boundary inclusive.
    function isExtended(uint64 gapSeconds) internal pure returns (bool) {
        return gapSeconds >= SessionTiming.EXTENDED_GAP;
    }

    /// @dev LT reached at F, which also applies through the closure and the reopening after it.
    function ltFinal(bool extended) internal pure returns (uint256) {
        return extended ? LT_FINAL_EXTENDED : LT_FINAL_OVERNIGHT;
    }

    /// @dev Target LTV after a trim from A through reopening recovery.
    function target(bool extended) internal pure returns (uint256) {
        return extended ? TARGET_EXTENDED : TARGET_OVERNIGHT;
    }

    /// @dev LT at `t` for a close at `close`: LT_OPEN until A = close - PREP, linear to ltFinal at F = close -
    /// FINAL, flat after. The decrement rounds up, so LT rounds down (toward the stricter threshold). Reverts on
    /// underflow if `close` is below PREP.
    function ltAt(bool extended, uint64 t, uint64 close) internal pure returns (uint256) {
        uint64 a = close - SessionTiming.PREP;
        uint64 f = close - SessionTiming.FINAL;
        uint256 lt = ltFinal(extended);
        if (t <= a) return LT_OPEN;
        if (t >= f) return lt;
        return LT_OPEN - Math.mulDiv(LT_OPEN - lt, t - a, f - a, Math.Rounding.Ceil);
    }

    /// @dev B = min(B_OPEN, ltWad - BORROW_GAP), exact. Reverts on underflow if `ltWad` is below BORROW_GAP.
    function borrowLimit(uint256 ltWad) internal pure returns (uint256) {
        uint256 b = ltWad - BORROW_GAP;
        return b < B_OPEN ? b : B_OPEN;
    }

    /// @dev Trim bonus where trims are allowed: BONUS_SCHEDULING for a position at or below LT_OPEN during
    /// preparation (PRE_CLOSE and FINAL_WINDOW), BONUS_DISTRESS otherwise.
    /// @param preparing True in PRE_CLOSE and FINAL_WINDOW.
    /// @param ltvWad Position LTV, WAD.
    function bonus(bool preparing, uint256 ltvWad) internal pure returns (uint256) {
        return preparing && ltvWad <= LT_OPEN ? BONUS_SCHEDULING : BONUS_DISTRESS;
    }
}
