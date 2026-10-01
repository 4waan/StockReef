// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The parts of a Robinhood Stock Token that StockReef reads. Stock Tokens implement ERC-8056
/// (Scaled UI Amount): raw balances never change on corporate actions; the multiplier does. The
/// Robinhood Chainlink feeds already include the multiplier, so StockReef values raw balances directly
/// and never applies the multiplier again.
interface IStockToken {
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);

    /// @notice Issuer flag raised while a corporate action is in progress. Not every token version has it;
    /// the deployment manifest says whether it is required.
    function oraclePaused() external view returns (bool);
}
