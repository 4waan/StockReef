// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SessionTiming
/// @notice Session timing fixtures shared by PriceGate, SessionRiskPolicy and StockReefLens: when preparation for
/// a close starts, when the final window starts, which closes count as extended, and how long the reopening,
/// recovery and resume waits last (docs/SPEC.md §3 and §6, appendix R1 and R14).
/// @dev All durations are seconds and all times UTC seconds. They are illustrative product fixtures, compiled into
/// the contracts that use them, so they are fixed per deployment and cannot be changed by any role. O and C are a
/// session's scheduled open and close from SessionCalendar.
library SessionTiming {
    /// @dev Preparation starts at A = C - PREP (120 minutes, 7200 s). PRE_CLOSE and the LT ramp run from A to F,
    /// borrowers' buffers may execute from A, and the lender window (OPEN only) closes at A (docs/SPEC.md §3).
    uint64 internal constant PREP = 120 minutes;
    /// @dev The ramp ends and the final window starts at F = C - FINAL (30 minutes, 1800 s). New borrowing stops at
    /// F (docs/SPEC.md §3).
    uint64 internal constant FINAL = 30 minutes;
    /// @dev A close is EXTENDED when the next scheduled open is at least this long after it (24 hours, 86400 s);
    /// a shorter gap is OVERNIGHT (appendix R1).
    uint64 internal constant EXTENDED_GAP = 24 hours;

    /// @dev Earliest admission of a reopening price: O + ADMIT_AFTER (5 minutes, 300 s), inclusive (docs/SPEC.md
    /// §6 step 1).
    uint64 internal constant ADMIT_AFTER = 5 minutes;
    /// @dev The admitted stock price must be stamped at or after O + FRESH_AFTER (1 minute, 60 s), so a price
    /// carried over from the previous close cannot be admitted (docs/SPEC.md §6 step 2).
    uint64 internal constant FRESH_AFTER = 1 minutes;
    /// @dev New credit returns at max(O + CREDIT_AFTER, admissionAt + MIN_RECOVERY); CREDIT_AFTER is 15 minutes
    /// (900 s) (docs/SPEC.md §6 step 4). StockReefLens also uses O + CREDIT_AFTER as the earliest expected opening
    /// of the lender window for a session with no recorded admission, including the next session.
    uint64 internal constant CREDIT_AFTER = 15 minutes;
    /// @dev Shortest reopening recovery after admission: 10 minutes (600 s), so a late first price still gets a
    /// full recovery window (docs/SPEC.md §6 step 4).
    uint64 internal constant MIN_RECOVERY = 10 minutes;
    /// @dev Without admission by O + GUARD_AFTER (30 minutes, 1800 s) the market is GUARDED, from that time
    /// inclusive, until a qualifying refresh admits a price or the session closes (docs/SPEC.md §6 step 5,
    /// appendix R14).
    uint64 internal constant GUARD_AFTER = 30 minutes;

    /// @dev Observation grace after a mid-session source recovery or a guardian resume: 5 minutes (300 s). Prices
    /// stay unusable until the grace has passed and the stock feed has updated strictly after the checkpoint
    /// (docs/SPEC.md §6).
    uint64 internal constant RECOVERY_GRACE = 5 minutes;
    /// @dev Delay between a guardian's resume request and the earliest resume: 24 hours (86400 s) (docs/SPEC.md
    /// §6).
    uint64 internal constant RESUME_DELAY = 24 hours;

    /// @dev When new credit may return after a reopening admitted at `admissionAt`:
    /// max(open + CREDIT_AFTER, admissionAt + MIN_RECOVERY), in UTC seconds (docs/SPEC.md §6 step 4).
    /// SessionRiskPolicy keeps the phase at REOPEN_RECOVERY while the clock is inside the session and before the
    /// result. PriceGate.refresh treats an invalid source or a stop before the result as an interrupted recovery
    /// (the admission is cleared) and from the result on as an outage. PriceGate admits no earlier than
    /// open + ADMIT_AFTER, so for its admissions the result is always admissionAt + MIN_RECOVERY. Reverts with an
    /// arithmetic panic on uint64 overflow.
    /// @param open Scheduled open O of the session, UTC seconds.
    /// @param admissionAt Clock time at which PriceGate recorded the reopening admission, UTC seconds.
    /// @return Time from which new credit may return, UTC seconds.
    function creditAt(uint64 open, uint64 admissionAt) internal pure returns (uint64) {
        uint64 a = open + CREDIT_AFTER;
        uint64 b = admissionAt + MIN_RECOVERY;
        return a > b ? a : b;
    }
}
