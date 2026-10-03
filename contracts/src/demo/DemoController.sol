// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DemoClock} from "../clock/DemoClock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @title DemoController
/// @notice Time and price control for a demo deployment: one transaction moves the simulated clock and publishes
/// the next simulated stock price together, so each demo step is a single action. Only the demo operator can call
/// it, and the app labels everything it changes as simulation (docs/SPEC.md §6, appendix R6, R9, R15, R18).
/// @dev The constructor deploys its own DemoClock and MockAggregatorV3 and makes this contract the only address
/// that can move that clock or publish to that feed; neither role can be handed on. The DemoClock constructor
/// accepts only chains 31337 and 46630, so this contract cannot be deployed anywhere else. It does not expose the
/// feed's `pushAt` or `bumpPhase`, so every round it publishes is stamped with the simulated time and the feed
/// stays in phase 1.
///
/// Bounds (appendix R18): a call moves the clock at most MAX_STEP forward and never to a time after `latest`.
/// The clock also runs on with block time between calls (DemoClock time is block time plus an offset), which
/// this contract cannot stop, so the clock can pass `latest` without a step. From then on `step`, `stepTo` and
/// `advance` always revert: with StepTooLong for a move longer than MAX_STEP, with DemoClock.ClockBackwards for a
/// `stepTo` target at or before `latest`, and otherwise with BeyondCoverage. Only `push` still works. Answers are
/// not validated: zero, negative or out-of-bound prices are published as given, and PriceGate's checks decide
/// whether they are usable.
/// Simulated time ages prices and accrues interest exactly as real time does.
///
/// Trust: the operator sets the demo stock price and time of a test-chain deployment, and through them which
/// market actions are allowed, which positions can be trimmed and how much interest accrues; it cannot move time
/// backwards and cannot transfer anyone's tokens itself. script/Deploy.s.sol makes the deployer the operator and
/// passes SessionCalendar.lastOpen() as `latest`. A zero operator leaves the demo controls unusable.
contract DemoController {
    /// @notice Longest forward move of the simulated clock in one call, in seconds (7 days = 604,800;
    /// appendix R18).
    uint64 public constant MAX_STEP = 7 days;

    /// @notice The demo operator: the only address that may call `step`, `stepTo`, `advance` and `push`. Fixed at
    /// deployment.
    address public immutable operator;
    /// @notice The simulated clock this contract deployed and alone moves; the demo deployment's IClock.
    DemoClock public immutable clock;
    /// @notice The simulated stock price feed this contract deployed and alone publishes to; the demo deployment's
    /// stock feed. Answers are in the feed's decimals (8 for the demo TSLA/USD feed).
    MockAggregatorV3 public immutable feed;
    /// @notice Latest simulated time a call may move the clock to, UTC seconds: the open of the last loaded
    /// calendar session (appendix R18). A step may land exactly on it but not after it; with `latest` set to
    /// SessionCalendar.lastOpen(), as script/Deploy.s.sol does, landing on it ends calendar coverage and starts
    /// wind-down (appendix R17). Block time can still carry the clock past it between calls. The constructor does
    /// not check it against the calendar.
    uint64 public immutable latest;

    /// @notice A demo action (`step`, `stepTo`, `advance` or `push`) completed.
    /// @param time Simulated clock time after the action, UTC seconds.
    /// @param answer Price published by the action, in the feed's decimals; zero for `advance`, which publishes
    /// nothing (a published zero answer logs the same value).
    event Step(uint64 time, int256 answer);

    /// @notice The caller is not `operator`.
    error NotOperator();
    /// @notice The requested move is longer than MAX_STEP.
    /// @param secs Requested forward move, seconds.
    /// @param maxStep MAX_STEP, seconds.
    error StepTooLong(uint64 secs, uint64 maxStep);
    /// @notice The requested time is after `latest`. Once block time has carried the clock past `latest`, `step`
    /// and `advance` revert with this error for every move of at most MAX_STEP (a longer one reverts with
    /// StepTooLong first).
    /// @param time Requested simulated time, UTC seconds.
    /// @param latest The `latest` bound, UTC seconds.
    error BeyondCoverage(uint64 time, uint64 latest);

    /// @notice Deploys the demo clock and the simulated stock feed, both controlled only by this contract.
    /// @dev Reverts with DemoClock.ChainNotAllowed outside chains 31337 and 46630. Neither `operator_` nor `latest_`
    /// is checked. The feed starts with no rounds, so its `latestRoundData` reverts until the first publish.
    /// @param operator_ Address allowed to call the demo actions.
    /// @param feedDecimals Decimals of the feed's answers (8, matching the Robinhood feeds).
    /// @param feedDescription Label of the simulated feed, for example "Simulated TSLA/USD price (demo feed, not
    /// Chainlink)".
    /// @param latest_ Latest simulated time a call may move the clock to, UTC seconds; the open of the last loaded
    /// calendar session.
    constructor(address operator_, uint8 feedDecimals, string memory feedDescription, uint64 latest_) {
        operator = operator_;
        latest = latest_;
        clock = new DemoClock(address(this));
        feed = new MockAggregatorV3(feedDecimals, feedDescription, clock, address(this));
    }

    /// @dev Reverts with NotOperator unless the caller is `operator`.
    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Advance the simulated clock by `secs`, then publish `answer` stamped with the new time, in one
    /// transaction. Only the operator may call it.
    /// @dev Reverts with NotOperator; StepTooLong when `secs` exceeds MAX_STEP; BeyondCoverage when the new time
    /// would be after `latest` (or the clock is already past it); an arithmetic panic when the new time overflows
    /// uint64. A zero `secs` publishes at the current time without moving the clock. Emits DemoClock.ClockAdvanced
    /// (only when `secs` is non-zero), MockAggregatorV3.AnswerUpdated and Step.
    /// @param secs Seconds to move the clock forward, at most MAX_STEP.
    /// @param answer Price to publish, in the feed's decimals (with 8 decimals, 400e8 is 400 USD); not validated.
    function step(uint64 secs, int256 answer) external onlyOperator {
        _check(clock.time() + secs);
        if (secs > 0) clock.advance(secs);
        feed.push(answer);
        emit Step(clock.time(), answer);
    }

    /// @notice Move the simulated clock forward to `t`, then publish `answer` stamped with `t`, in one transaction.
    /// Only the operator may call it.
    /// @dev Reverts with NotOperator; StepTooLong when `t` is more than MAX_STEP after the current simulated time;
    /// BeyondCoverage when `t` is after `latest`; DemoClock.ClockBackwards when `t` is before the current simulated
    /// time. A `t` equal to the current time publishes without moving the clock. Emits DemoClock.ClockAdvanced,
    /// MockAggregatorV3.AnswerUpdated and Step.
    /// @param t Target simulated time, UTC seconds.
    /// @param answer Price to publish, in the feed's decimals; not validated.
    function stepTo(uint64 t, int256 answer) external onlyOperator {
        _check(t);
        clock.warpTo(t);
        feed.push(answer);
        emit Step(t, answer);
    }

    /// @notice Advance the simulated clock by `secs` without publishing a price (for example, across a closure).
    /// Only the operator may call it.
    /// @dev Same bounds and reverts as `step`. Calls the clock even when `secs` is zero. The feed's latest round
    /// keeps its timestamp, so PriceGate treats it as stale once it is older than the feed's `maxAge` (120 seconds
    /// in the demo manifests; appendix R3). Emits DemoClock.ClockAdvanced and Step with a zero answer.
    /// @param secs Seconds to move the clock forward, at most MAX_STEP.
    function advance(uint64 secs) external onlyOperator {
        _check(clock.time() + secs);
        clock.advance(secs);
        emit Step(clock.time(), 0);
    }

    /// @notice Publish `answer` stamped with the current simulated time without moving the clock; keeps the demo
    /// feed fresh between steps (appendix R3). Only the operator may call it.
    /// @dev Reverts with NotOperator. It applies no time bound, so it still works after block time has carried the
    /// clock past `latest`. Emits MockAggregatorV3.AnswerUpdated and Step.
    /// @param answer Price to publish, in the feed's decimals; not validated.
    function push(int256 answer) external onlyOperator {
        feed.push(answer);
        emit Step(clock.time(), answer);
    }

    /// @dev Enforces the step bounds of appendix R18 for a move to simulated time `t`: reverts with StepTooLong when
    /// `t` is more than MAX_STEP after the current simulated time, then with BeyondCoverage when `t` is after
    /// `latest`. A `t` at or before the current time passes the first check; `stepTo` relies on DemoClock to reject
    /// a backward move. Simulated time accrues interest exactly as real time does; the app labels it.
    /// @param t Target simulated time, UTC seconds.
    function _check(uint64 t) internal view {
        uint64 now_ = clock.time();
        if (t > now_ && t - now_ > MAX_STEP) revert StepTooLong(t - now_, MAX_STEP);
        if (t > latest) revert BeyondCoverage(t, latest);
    }
}
