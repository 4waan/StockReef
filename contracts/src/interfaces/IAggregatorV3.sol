// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3
/// @notice Read interface of a Chainlink AggregatorV3 feed. StockReef uses it for the stock price feed, the
/// loan-token (USDG/USD) feed unless the deployment uses the labelled test peg, and the optional L2 sequencer uptime
/// feed. It exposes rounds and timestamps only; it has no market-session field, so session status comes from
/// SessionCalendar (docs/SPEC.md §6 "Adapter contract").
/// @dev Answers are signed integers in the feed's own decimals (8 for the Robinhood feeds); timestamps are UTC
/// seconds. On a Chainlink proxy a round id is (phaseId << 64) | aggregatorRoundId, so ids jump when the proxy
/// moves to a new aggregator; MockAggregatorV3 uses the same encoding.
///
/// Trust: PriceGate trusts a price answer and its `updatedAt` only within its own checks (answer positive and at
/// most the feed's answer bound, timestamp non-zero, not in the future and no older than `maxAge`, expected
/// decimals; docs/SPEC.md §6, appendix R3, R12). Its constructor calls `decimals()` directly, so a reverting call
/// there reverts the deployment. After deployment it reads every feed through try/catch, so a reverting feed marks
/// the price unusable instead of reverting the caller; a call that succeeds but returns data that does not decode
/// is not caught and reverts the caller. On demo deployments the stock feed is MockAggregatorV3, a labelled
/// simulation.
interface IAggregatorV3 {
    /// @notice Number of decimals in this feed's answers.
    /// @dev PriceGate's constructor reverts with DecimalsMismatch when the stock feed, or the loan feed when one is
    /// configured, reports decimals other than the configured (manifest) value; a reverting call reverts the
    /// deployment. Every quote and refresh rechecks them through try/catch: a reverting call or a different value
    /// sets STOCK_DECIMALS_CHANGED or LOAN_DECIMALS_CHANGED. The sequencer uptime feed's decimals are never read.
    /// @return Answer decimals (8 for the Robinhood feeds).
    function decimals() external view returns (uint8);
    /// @notice Human-readable name of the feed, for example "RHTSLA / USD".
    /// @dev Not read by the StockReef contracts; the fork tests compare it with the deployment manifest.
    /// @return Feed description.
    function description() external view returns (string memory);
    /// @notice Version number of the aggregator implementation.
    /// @dev Not read by the StockReef contracts.
    /// @return Aggregator version.
    function version() external view returns (uint256);
    /// @notice Data of one past or current round.
    /// @dev Not called by the StockReef contracts, which read only the latest round. An implementation may revert
    /// for a round without data (MockAggregatorV3 reverts with NoData).
    /// @param roundId Round to read, in the feed's round-id encoding.
    /// @return roundId_ The round read; equal to `roundId` on Chainlink feeds and MockAggregatorV3.
    /// @return answer Answer of that round, in the feed's decimals.
    /// @return startedAt Time the round started, UTC seconds.
    /// @return updatedAt Time the round's answer was last updated, UTC seconds; by Chainlink convention, zero
    /// means the round is not complete.
    /// @return answeredInRound Round in which the answer was computed; deprecated by Chainlink.
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// @notice Data of the latest round.
    /// @dev For the stock and loan feeds PriceGate reads `answer` and `updatedAt`, plus the stock feed's `roundId`,
    /// which it only reports in its quote; it ignores the rest (docs/SPEC.md §6). For an L2 sequencer uptime feed
    /// (appendix R14) it reads only `answer` (0 when the sequencer is up; any other value counts as down) and
    /// `startedAt` (when that status last changed; zero or a time after the clock time counts as down). An
    /// implementation may revert before its first round (MockAggregatorV3 reverts with NoData); PriceGate turns a
    /// revert into STOCK_FEED_UNAVAILABLE, LOAN_FEED_UNAVAILABLE or SEQUENCER_DOWN.
    /// @return roundId Id of the latest round, in the feed's round-id encoding.
    /// @return answer Latest answer, in the feed's decimals; for an uptime feed, 0 (up) or 1 (down).
    /// @return startedAt Time the round started, UTC seconds; for an uptime feed, when the status last changed.
    /// @return updatedAt Time the answer was last updated, UTC seconds. For a price feed PriceGate rejects zero, a
    /// time after the clock time and an age above the feed's `maxAge`; it is not read for an uptime feed.
    /// @return answeredInRound Round in which the answer was computed; deprecated by Chainlink and not read.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
