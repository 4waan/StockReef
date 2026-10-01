// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Session timing fixtures shared by PriceGate and SessionRiskPolicy (docs/SPEC.md §3 and §6).
/// All durations are seconds. They are product fixtures, fixed per deployment.
library SessionTiming {
    /// @dev Preparation starts at A = C - PREP.
    uint64 internal constant PREP = 120 minutes;
    /// @dev The ramp ends and the final window starts at F = C - FINAL.
    uint64 internal constant FINAL = 30 minutes;
    /// @dev A close is EXTENDED when the next scheduled open is at least this long after it.
    uint64 internal constant EXTENDED_GAP = 24 hours;

    /// @dev Earliest admission of a reopening price: O + ADMIT_AFTER.
    uint64 internal constant ADMIT_AFTER = 5 minutes;
    /// @dev The admitted stock price must be stamped at or after O + FRESH_AFTER.
    uint64 internal constant FRESH_AFTER = 1 minutes;
    /// @dev New credit returns at max(O + CREDIT_AFTER, admissionAt + MIN_RECOVERY).
    uint64 internal constant CREDIT_AFTER = 15 minutes;
    uint64 internal constant MIN_RECOVERY = 10 minutes;
    /// @dev Without admission by O + GUARD_AFTER the market is GUARDED.
    uint64 internal constant GUARD_AFTER = 30 minutes;

    /// @dev Observation grace after a mid-session source recovery or a guardian resume.
    uint64 internal constant RECOVERY_GRACE = 5 minutes;
    /// @dev Delay between a guardian's resume request and the resume.
    uint64 internal constant RESUME_DELAY = 24 hours;

    /// @notice When new credit may return after a reopening admitted at `admissionAt`.
    function creditAt(uint64 open, uint64 admissionAt) internal pure returns (uint64) {
        uint64 a = open + CREDIT_AFTER;
        uint64 b = admissionAt + MIN_RECOVERY;
        return a > b ? a : b;
    }
}
