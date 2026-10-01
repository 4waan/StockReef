// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IClock} from "../interfaces/IClock.sol";

/// @notice Labelled stand-in for a Chainlink price feed on networks without one. Round ids use
/// Chainlink's encoding (phase << 64 | round). Only the owner (the demo controller or a test) publishes.
contract MockAggregatorV3 is IAggregatorV3 {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint8 public immutable decimals;
    IClock public immutable clock;
    address public immutable owner;
    string public description;
    uint16 public phase = 1;
    uint64 public latestRound;
    mapping(uint80 => Round) private _rounds;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotOwner();
    error NoData();
    error TimestampDecreased();

    constructor(uint8 decimals_, string memory description_, IClock clock_, address owner_) {
        decimals = decimals_;
        description = description_;
        clock = clock_;
        owner = owner_;
    }

    function version() external pure returns (uint256) {
        return 6;
    }

    /// @notice Publish `answer` stamped with the current clock time.
    function push(int256 answer) external returns (uint80) {
        return _push(answer, clock.time());
    }

    /// @notice Publish `answer` with an explicit timestamp (tests only need this for edge cases).
    function pushAt(int256 answer, uint64 updatedAt) external returns (uint80) {
        return _push(answer, updatedAt);
    }

    /// @notice Start a new aggregator phase, as Chainlink does when it upgrades a feed.
    function bumpPhase() external {
        if (msg.sender != owner) revert NotOwner();
        phase += 1;
        latestRound = 0;
    }

    function _push(int256 answer, uint64 updatedAt) internal returns (uint80 id) {
        if (msg.sender != owner) revert NotOwner();
        if (latestRound > 0 && updatedAt < _rounds[_id(latestRound)].updatedAt) revert TimestampDecreased();
        latestRound += 1;
        id = _id(latestRound);
        _rounds[id] = Round(answer, updatedAt);
        emit AnswerUpdated(answer, id, updatedAt);
    }

    function _id(uint64 round) internal view returns (uint80) {
        return (uint80(phase) << 64) | uint80(round);
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        if (r.updatedAt == 0) revert NoData();
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRound == 0) revert NoData();
        return getRoundData(_id(latestRound));
    }
}
