// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IStockToken
/// @notice The parts of a Robinhood Stock Token that StockReef uses: the issuer pause flag and the ERC-8056
/// multiplier getters (the contracts read `oraclePaused`, `effectiveAt` and `newUIMultiplier`, never
/// `uiMultiplier`). Stock Tokens implement ERC-8056 (Scaled UI Amount): raw balances never change on corporate
/// actions; the multiplier does. The Robinhood Chainlink feeds already include the multiplier, so StockReef values
/// raw balances directly and never applies the multiplier again (docs/SPEC.md §6, appendix R11).
/// @dev The issuer is trusted for transfers, the `oraclePaused` flag and the ERC-8056 multiplier getters
/// (docs/SECURITY.md); prices come from the feeds, never from the token. Multipliers are fixed point with 18
/// decimals (1e18 = 1.0); times are UTC seconds. PriceGate reads `oraclePaused` and, when its `erc8056` flag (set
/// from the manifest) is true, `effectiveAt`; StockReefLens reads `effectiveAt` and `newUIMultiplier` to show a
/// pending change. Both read through try/catch, so a getter that reverts (as on a token version without it) does
/// not revert them; a call that succeeds but returns data that does not decode is not caught.
interface IStockToken {
    /// @notice Multiplier that turns raw balances into displayed (UI) share amounts.
    /// @dev Not called by the StockReef contracts, which value raw balances; the fork tests read it to check that
    /// the token implements ERC-8056.
    /// @return Multiplier, 18-decimal fixed point (1e18 = 1.0).
    function uiMultiplier() external view returns (uint256);
    /// @notice Multiplier that applies from `effectiveAt`, after a scheduled split or dividend adjustment.
    /// @dev StockReefLens reports it while `effectiveAt` is still in the future.
    /// @return Multiplier, 18-decimal fixed point (1e18 = 1.0).
    function newUIMultiplier() external view returns (uint256);
    /// @notice Time at which `newUIMultiplier` takes effect; zero when no change has been scheduled.
    /// @dev PriceGate reads it only when its `erc8056` flag is set. It then sets MULTIPLIER_LAG while this time is
    /// non-zero, at or before the clock time and later than the stock feed's `updatedAt` (zero when the feed call
    /// failed), and MULTIPLIER_UNAVAILABLE when the call reverts (appendix R11). StockReefLens reads it whether or
    /// not that flag is set and reports a pending change while this time is after the clock time.
    /// @return Effective time, UTC seconds; zero when none.
    function effectiveAt() external view returns (uint256);

    /// @notice Issuer flag raised while a corporate action is in progress. Not every token version has it;
    /// the deployment manifest says whether it is required.
    /// @dev PriceGate sets ISSUER_PAUSED while it is true. When the call reverts it sets PAUSE_FLAG_UNAVAILABLE if
    /// the manifest marks the flag as required and ignores the failure otherwise (docs/SPEC.md §6, appendix R4).
    /// The Robinhood Chain testnet token version does not implement it.
    /// @return True while the issuer has paused the token's oracle.
    function oraclePaused() external view returns (bool);
}
