// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IClock} from "../interfaces/IClock.sol";

/// @title MockAggregatorV3
/// @notice Labelled stand-in for a Chainlink price feed on networks without one: the simulated TSLA/USD feed of the
/// demo deployments and the stock feed of the unit tests. Only the owner publishes; StockReef reads it through
/// IAggregatorV3 exactly like a real feed (docs/SPEC.md §6, appendix R3, R6, R9).
/// @dev Round ids use Chainlink's proxy encoding, (phase << 64) | round, with the phase starting at 1, so the first
/// round id is 2^64 + 1. `startedAt` equals `updatedAt` and `answeredInRound` equals the round id. The owner may
/// publish any answer, including zero, negative or above PriceGate's answer bound, so that tests and the demo can
/// exercise PriceGate's checks; within a phase timestamps must not decrease. On demo deployments the owner is the
/// DemoController and the clock is its DemoClock. The contract has no chain allowlist of its own; script/Deploy.s.sol
/// deploys it only through the DemoController.
///
/// Trust: its answers are simulated, not market prices, and are trusted no further than PriceGate's checks
/// (docs/SECURITY.md).
contract MockAggregatorV3 is IAggregatorV3 {
    /// @dev One published round.
    struct Round {
        int256 answer; // published answer, in the feed's decimals
        uint64 updatedAt; // publish time, UTC seconds; zero reads as no data
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Fixed at deployment; 8 on the demo deployments.
    uint8 public immutable decimals;
    /// @notice Time source that stamps rounds published with `push` (the DemoClock on demo deployments).
    IClock public immutable clock;
    /// @notice The only address that may call `push`, `pushAt` and `bumpPhase`; fixed at deployment (the
    /// DemoController on demo deployments).
    address public immutable owner;
    /// @inheritdoc IAggregatorV3
    /// @dev Set at deployment and never changed; the demo deployments label the feed as simulated, not Chainlink.
    string public description;
    /// @notice Current aggregator phase id. Starts at 1 and grows by one with each `bumpPhase`; it forms the top
    /// bits of every round id published in it.
    uint16 public phase = 1;
    /// @notice Round number of the latest round in the current phase (the low 64 bits of its id, not the full
    /// round id); zero before the first publish in this phase.
    uint64 public latestRound;
    /// @dev Published rounds by full round id, (phase << 64) | round, across all phases.
    mapping(uint80 => Round) private _rounds;

    /// @notice A new round was published. The signature matches Chainlink's AnswerUpdated event.
    /// @param current Published answer, in the feed's decimals.
    /// @param roundId Full id of the new round, (phase << 64) | round.
    /// @param updatedAt Round timestamp, UTC seconds.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// @notice The caller of `push`, `pushAt` or `bumpPhase` is not `owner`.
    error NotOwner();
    /// @notice The requested round has no data: it was never published or was published with a zero timestamp,
    /// or the current phase has no round yet.
    error NoData();
    /// @notice A publish carried a timestamp earlier than that of the latest round in the current phase.
    error TimestampDecreased();

    /// @notice Deploys an empty feed in phase 1; `getRoundData` and `latestRoundData` revert with NoData until the
    /// first publish.
    /// @dev No argument is checked.
    /// @param decimals_ Decimals of the answers (8, matching the Robinhood feeds).
    /// @param description_ Label of the feed.
    /// @param clock_ Clock that stamps rounds published with `push`.
    /// @param owner_ Address allowed to publish and to start a new phase.
    constructor(uint8 decimals_, string memory description_, IClock clock_, address owner_) {
        decimals = decimals_;
        description = description_;
        clock = clock_;
        owner = owner_;
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Always 6.
    function version() external pure returns (uint256) {
        return 6;
    }

    /// @notice Publish `answer` as a new round stamped with the current clock time. Only the owner may call it.
    /// @dev Reverts with NotOwner, and with TimestampDecreased when the clock time is earlier than the latest round
    /// of the current phase. With a clock that never goes back, such as the DemoClock, that happens only after a
    /// `pushAt` with a later timestamp. Emits AnswerUpdated.
    /// @param answer Answer to publish, in the feed's decimals; not validated.
    /// @return Full id of the new round, (phase << 64) | round.
    function push(int256 answer) external returns (uint80) {
        return _push(answer, clock.time());
    }

    /// @notice Publish `answer` as a new round with an explicit timestamp, for test edge cases such as a stale,
    /// future or out-of-session reading. Only the owner may call it; DemoController does not expose it.
    /// @dev Reverts with NotOwner, and with TimestampDecreased when `updatedAt` is earlier than the latest round of
    /// the current phase; an equal timestamp is accepted. `updatedAt` is not compared with the clock, so it may be
    /// in the future. A zero `updatedAt`, possible only before any non-zero timestamp in the phase, stores a round
    /// that reads as missing (NoData). Emits AnswerUpdated.
    /// @param answer Answer to publish, in the feed's decimals; not validated.
    /// @param updatedAt Round timestamp, UTC seconds.
    /// @return Full id of the new round, (phase << 64) | round.
    function pushAt(int256 answer, uint64 updatedAt) external returns (uint80) {
        return _push(answer, updatedAt);
    }

    /// @notice Start a new aggregator phase, as a Chainlink proxy does when it moves to a new aggregator. Only the
    /// owner may call it; DemoController does not expose it.
    /// @dev Reverts with NotOwner, and with an arithmetic panic once `phase` would exceed the uint16 maximum.
    /// Increments `phase` and resets `latestRound` to zero, so `latestRoundData` reverts with NoData until the next
    /// publish, whose id is (new phase << 64) | 1. Rounds of earlier phases stay readable through `getRoundData`.
    /// The timestamp order check restarts with the phase, so the first round of the new phase may carry an earlier
    /// timestamp than the last round of the previous one.
    function bumpPhase() external {
        if (msg.sender != owner) revert NotOwner();
        phase += 1;
        latestRound = 0;
    }

    /// @dev Shared body of `push` and `pushAt`: checks the caller and the timestamp order within the current phase,
    /// stores the round under the next round number and emits AnswerUpdated.
    /// @param answer Answer to publish, in the feed's decimals.
    /// @param updatedAt Round timestamp, UTC seconds.
    /// @return id Full id of the new round, (phase << 64) | round.
    function _push(int256 answer, uint64 updatedAt) internal returns (uint80 id) {
        if (msg.sender != owner) revert NotOwner();
        if (latestRound > 0 && updatedAt < _rounds[_id(latestRound)].updatedAt) revert TimestampDecreased();
        latestRound += 1;
        id = _id(latestRound);
        _rounds[id] = Round(answer, updatedAt);
        emit AnswerUpdated(answer, id, updatedAt);
    }

    /// @dev Full round id of round number `round` in the current phase: (phase << 64) | round.
    /// @param round Round number within the current phase.
    /// @return Full round id.
    function _id(uint64 round) internal view returns (uint80) {
        return (uint80(phase) << 64) | uint80(round);
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Reads a round of any phase. Returns the round's timestamp as both `startedAt` and `updatedAt`, and
    /// `roundId` as `answeredInRound`. Reverts with NoData when the round has no data (never published, or
    /// published with a zero timestamp).
    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        if (r.updatedAt == 0) revert NoData();
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    /// @inheritdoc IAggregatorV3
    /// @dev Returns the latest round of the current phase with the same fields as `getRoundData`. Reverts with
    /// NoData before the first publish in the current phase (including right after `bumpPhase`) and when that round
    /// has a zero timestamp; PriceGate catches the revert (STOCK_FEED_UNAVAILABLE for the stock feed).
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRound == 0) revert NoData();
        return getRoundData(_id(latestRound));
    }
}
