// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DemoClock} from "../clock/DemoClock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice One-transaction demo steps: advance the simulated clock and publish the next simulated price
/// together. Only the demo operator can call it. Everything it changes is labelled as simulation in the app.
contract DemoController {
    /// @dev Longest single jump of the simulated clock.
    uint64 public constant MAX_STEP = 7 days;

    address public immutable operator;
    DemoClock public immutable clock;
    MockAggregatorV3 public immutable feed;
    /// @notice The simulated clock never moves past this time (the open of the last loaded calendar session),
    /// so a demo step cannot end the market's calendar coverage.
    uint64 public immutable latest;

    event Step(uint64 time, int256 answer);

    error NotOperator();
    error StepTooLong(uint64 secs, uint64 maxStep);
    error BeyondCoverage(uint64 time, uint64 latest);

    constructor(address operator_, uint8 feedDecimals, string memory feedDescription, uint64 latest_) {
        operator = operator_;
        latest = latest_;
        clock = new DemoClock(address(this));
        feed = new MockAggregatorV3(feedDecimals, feedDescription, clock, address(this));
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Advance the clock by `secs`, then publish `answer` at the new time.
    function step(uint64 secs, int256 answer) external onlyOperator {
        _check(clock.time() + secs);
        if (secs > 0) clock.advance(secs);
        feed.push(answer);
        emit Step(clock.time(), answer);
    }

    /// @notice Jump the clock to `t`, then publish `answer` at that time.
    function stepTo(uint64 t, int256 answer) external onlyOperator {
        _check(t);
        clock.warpTo(t);
        feed.push(answer);
        emit Step(t, answer);
    }

    /// @notice Advance the clock without publishing a price (for example, across a closure).
    function advance(uint64 secs) external onlyOperator {
        _check(clock.time() + secs);
        clock.advance(secs);
        emit Step(clock.time(), 0);
    }

    /// @notice Publish a price at the current simulated time (keeps the demo feed fresh).
    function push(int256 answer) external onlyOperator {
        feed.push(answer);
        emit Step(clock.time(), answer);
    }

    /// @dev Bounded steps: at most MAX_STEP forward and never past `latest`. Simulated time accrues interest like
    /// real time; the app labels it.
    function _check(uint64 t) internal view {
        uint64 now_ = clock.time();
        if (t > now_ && t - now_ > MAX_STEP) revert StepTooLong(t - now_, MAX_STEP);
        if (t > latest) revert BeyondCoverage(t, latest);
    }
}
