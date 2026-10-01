// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DemoClock} from "../clock/DemoClock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice One-transaction demo steps: advance the simulated clock and publish the next simulated price
/// together. Only the demo operator can call it. Everything it changes is labelled as simulation in the app.
contract DemoController {
    address public immutable operator;
    DemoClock public immutable clock;
    MockAggregatorV3 public immutable feed;

    event Step(uint64 time, int256 answer);

    error NotOperator();

    constructor(address operator_, uint8 feedDecimals, string memory feedDescription) {
        operator = operator_;
        clock = new DemoClock(address(this));
        feed = new MockAggregatorV3(feedDecimals, feedDescription, clock, address(this));
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Advance the clock by `secs`, then publish `answer` at the new time.
    function step(uint64 secs, int256 answer) external onlyOperator {
        if (secs > 0) clock.advance(secs);
        feed.push(answer);
        emit Step(clock.time(), answer);
    }

    /// @notice Jump the clock to `t`, then publish `answer` at that time.
    function stepTo(uint64 t, int256 answer) external onlyOperator {
        clock.warpTo(t);
        feed.push(answer);
        emit Step(t, answer);
    }

    /// @notice Advance the clock without publishing a price (for example, across a closure).
    function advance(uint64 secs) external onlyOperator {
        clock.advance(secs);
        emit Step(clock.time(), 0);
    }

    /// @notice Publish a price at the current simulated time (keeps the demo feed fresh).
    function push(int256 answer) external onlyOperator {
        feed.push(answer);
        emit Step(clock.time(), answer);
    }
}
