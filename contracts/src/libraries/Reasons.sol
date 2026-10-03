// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Reasons
/// @notice Bit flags explaining why a PriceGate quote is not usable. A quote is usable only when no bit is
/// set. The app decodes the same bits, so their positions are part of the interface.
/// @dev Bits 0 to 17 describe the price source and are set by PriceGate._sourceQuote (docs/SPEC.md §6, appendix
/// R4, R11, R12, R14). Bits 18 to 20 describe gate state and are added by PriceGate.quote and PriceGate.refresh.
/// Both feeds use the same six relative bits (FEED_*): PriceGate._readFeed returns them, and PriceGate._sourceQuote
/// keeps them at bits 0 to 5 for the stock feed (STOCK_*) and shifts them left by LOAN_SHIFT for the loan feed
/// (LOAN_*).
/// Bits 6 to 11 are never set when the gate uses the labelled test peg instead of a loan-token feed.
/// Each constant is a uint32 mask with one bit set; a quote's `reasons` field (PriceGate.Quote) is the OR of the
/// bits that apply, so zero means usable.
/// SessionRiskPolicy treats STOPPED as GUARDED in every phase and any bit as GUARDED in a phase that uses the
/// price (every phase except CLOSED and REOPEN_WAIT). The positions must match REASONS in app/src/lib/policy.ts.
library Reasons {
    /// @dev Bit 0: the stock feed's latestRoundData call reverted. A reverting decimals() call sets
    /// STOCK_DECIMALS_CHANGED instead.
    uint32 internal constant STOCK_FEED_UNAVAILABLE = 1 << 0;
    /// @dev Bit 1: the stock answer is <= 0 or above the feed's answerBound, in the feed's own decimals, or it would
    /// price the token above PriceGate.MAX_PRICE_WAD (appendix R12, R22).
    uint32 internal constant STOCK_BAD_ANSWER = 1 << 1;
    /// @dev Bit 2: the stock round's updatedAt is zero.
    uint32 internal constant STOCK_NO_TIMESTAMP = 1 << 2;
    /// @dev Bit 3: the stock round's updatedAt is after the clock time. Not set together with STOCK_NO_TIMESTAMP.
    uint32 internal constant STOCK_FUTURE_TIMESTAMP = 1 << 3;
    /// @dev Bit 4: the stock round is older than the feed's maxAge in seconds (clock time - updatedAt > maxAge; an
    /// age of exactly maxAge passes). Not set together with the two timestamp bits above.
    uint32 internal constant STOCK_STALE = 1 << 4;
    /// @dev Bit 5: the stock feed's decimals() reverted or differs from the decimals fixed at deployment.
    uint32 internal constant STOCK_DECIMALS_CHANGED = 1 << 5;
    /// @dev Bit 6: the loan-token feed's latestRoundData call reverted. Never set when the gate uses the test peg.
    uint32 internal constant LOAN_FEED_UNAVAILABLE = 1 << 6;
    /// @dev Bit 7: the loan-token answer is <= 0 or above that feed's answerBound, in its own decimals (appendix
    /// R12).
    uint32 internal constant LOAN_BAD_ANSWER = 1 << 7;
    /// @dev Bit 8: the loan-token round's updatedAt is zero.
    uint32 internal constant LOAN_NO_TIMESTAMP = 1 << 8;
    /// @dev Bit 9: the loan-token round's updatedAt is after the clock time. Not set together with
    /// LOAN_NO_TIMESTAMP.
    uint32 internal constant LOAN_FUTURE_TIMESTAMP = 1 << 9;
    /// @dev Bit 10: the loan-token round is older than that feed's maxAge in seconds (clock time - updatedAt >
    /// maxAge; an age of exactly maxAge passes). Not set together with the two timestamp bits above.
    uint32 internal constant LOAN_STALE = 1 << 10;
    /// @dev Bit 11: the loan-token feed's decimals() reverted or differs from the decimals fixed at deployment.
    uint32 internal constant LOAN_DECIMALS_CHANGED = 1 << 11;
    /// @dev Bit 12: the stock token's oraclePaused() returned true (docs/SPEC.md §6).
    uint32 internal constant ISSUER_PAUSED = 1 << 12;
    /// @dev Bit 13: oraclePaused() reverted and the gate's `pauseFlagRequired` is true, as set from the deployment
    /// manifest (appendix R4). A reverting flag that is not required sets no bit.
    uint32 internal constant PAUSE_FLAG_UNAVAILABLE = 1 << 13;
    /// @dev Bit 14: the gate's `erc8056` flag is set and the token's effectiveAt is non-zero, at or before the clock
    /// time, and later than the stock feed's updatedAt, so the feed predates the new multiplier (appendix R11). A
    /// reverting stock feed counts as updatedAt zero here.
    uint32 internal constant MULTIPLIER_LAG = 1 << 14;
    /// @dev Bit 15: the gate's `erc8056` flag is set and the token's effectiveAt() call reverted.
    uint32 internal constant MULTIPLIER_UNAVAILABLE = 1 << 15;
    /// @dev Bit 16: the configured sequencer uptime feed answers a non-zero status (down), has a zero or future
    /// startedAt, or reverted (appendix R14). Never set when no uptime feed is configured.
    uint32 internal constant SEQUENCER_DOWN = 1 << 16;
    /// @dev Bit 17: the sequencer is up but its startedAt is less than the configured grace period (seconds) before
    /// the clock time (appendix R14).
    uint32 internal constant SEQUENCER_GRACE = 1 << 17;
    /// @dev Bit 18: the guardian has stopped the gate. Every quote carries it until `resume`.
    uint32 internal constant STOPPED = 1 << 18;
    /// @dev Bit 19: an outage is marked for the calendar session at the clock time: a covered, in-session refresh
    /// at or after SessionTiming.creditAt saw an invalid source or a stop, and neither a later valid refresh nor a
    /// guardian resume has since recorded a recovery checkpoint. The mark lapses when the calendar index changes.
    uint32 internal constant OUTAGE_UNRESOLVED = 1 << 19;
    /// @dev Bit 20: a recovery checkpoint is pending: less than SessionTiming.RECOVERY_GRACE (5 minutes) has passed
    /// since it, or the stock feed has not updated strictly after it (docs/SPEC.md §6).
    uint32 internal constant RECOVERY_GRACE = 1 << 20;

    /// @dev Feed-relative bits returned by PriceGate._readFeed: the STOCK_* values at bits 0 to 5, and the LOAN_*
    /// values once shifted left by LOAN_SHIFT.
    uint32 internal constant FEED_UNAVAILABLE = STOCK_FEED_UNAVAILABLE;
    uint32 internal constant FEED_BAD_ANSWER = STOCK_BAD_ANSWER;
    uint32 internal constant FEED_NO_TIMESTAMP = STOCK_NO_TIMESTAMP;
    uint32 internal constant FEED_FUTURE_TIMESTAMP = STOCK_FUTURE_TIMESTAMP;
    uint32 internal constant FEED_STALE = STOCK_STALE;
    uint32 internal constant FEED_DECIMALS_CHANGED = STOCK_DECIMALS_CHANGED;
    /// @dev Shift from a feed-relative bit to its LOAN_* position.
    uint8 internal constant LOAN_SHIFT = 6;

    /// @dev Bits that describe the price source itself, as opposed to gate state: bits 0 to 17
    /// (STOCK_FEED_UNAVAILABLE through SEQUENCER_GRACE), value 0x3ffff. STOPPED, OUTAGE_UNRESOLVED and
    /// RECOVERY_GRACE are outside it.
    uint32 internal constant SOURCE_MASK = (1 << 18) - 1;
}
