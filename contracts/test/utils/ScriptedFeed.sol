// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Feed whose every field a test can set, including malformed rounds and reverting calls.
contract ScriptedFeed is IAggregatorV3 {
    uint8 private _decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public reverting;
    bool public decimalsReverting;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        roundId += 1;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setReverting(bool r) external {
        reverting = r;
    }

    function setDecimalsReverting(bool r) external {
        decimalsReverting = r;
    }

    function decimals() external view returns (uint8) {
        require(!decimalsReverting, "decimals");
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "scripted";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return latestRoundData();
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverting, "feed down");
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @notice An 18-decimal ERC-20 with none of the Stock Token getters.
contract PlainToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
