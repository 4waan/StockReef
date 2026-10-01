// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Bit flags explaining why a PriceGate quote is not usable. A quote is usable only when no bit is
/// set. The app decodes the same bits, so their positions are part of the interface.
library Reasons {
    uint32 internal constant STOCK_FEED_UNAVAILABLE = 1 << 0; // latestRoundData or decimals call failed
    uint32 internal constant STOCK_BAD_ANSWER = 1 << 1; // answer <= 0 or above the feed's bound
    uint32 internal constant STOCK_NO_TIMESTAMP = 1 << 2;
    uint32 internal constant STOCK_FUTURE_TIMESTAMP = 1 << 3;
    uint32 internal constant STOCK_STALE = 1 << 4; // older than the feed's maxAge
    uint32 internal constant STOCK_DECIMALS_CHANGED = 1 << 5;
    uint32 internal constant LOAN_FEED_UNAVAILABLE = 1 << 6;
    uint32 internal constant LOAN_BAD_ANSWER = 1 << 7;
    uint32 internal constant LOAN_NO_TIMESTAMP = 1 << 8;
    uint32 internal constant LOAN_FUTURE_TIMESTAMP = 1 << 9;
    uint32 internal constant LOAN_STALE = 1 << 10;
    uint32 internal constant LOAN_DECIMALS_CHANGED = 1 << 11;
    uint32 internal constant ISSUER_PAUSED = 1 << 12; // token's oraclePaused() is true
    uint32 internal constant PAUSE_FLAG_UNAVAILABLE = 1 << 13; // required flag call failed
    uint32 internal constant MULTIPLIER_LAG = 1 << 14; // multiplier changed after the feed's last update
    uint32 internal constant MULTIPLIER_UNAVAILABLE = 1 << 15;
    uint32 internal constant SEQUENCER_DOWN = 1 << 16;
    uint32 internal constant SEQUENCER_GRACE = 1 << 17;
    uint32 internal constant STOPPED = 1 << 18; // guardian stop
    uint32 internal constant OUTAGE_UNRESOLVED = 1 << 19; // source failed this session; no checkpoint yet
    uint32 internal constant RECOVERY_GRACE = 1 << 20; // checkpoint grace still running

    /// @dev Bits that describe the price source itself, as opposed to gate state.
    uint32 internal constant SOURCE_MASK = (1 << 18) - 1;
}
