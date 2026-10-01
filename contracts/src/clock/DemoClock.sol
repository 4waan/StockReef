// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClock} from "../interfaces/IClock.sol";

/// @notice Simulation clock for demos: block time plus an offset that only moves forward.
/// It refuses to deploy outside an explicit allowlist of test chains (local 31337 and Robinhood Chain
/// testnet 46630), so it can never stand in for real time on a production network.
contract DemoClock is IClock {
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    address public immutable operator;
    uint64 public offset;

    event ClockAdvanced(uint64 from, uint64 to);

    error ChainNotAllowed(uint256 chainId);
    error NotOperator();
    error ClockBackwards(uint64 current, uint64 requested);

    constructor(address operator_) {
        if (block.chainid != LOCAL_CHAIN_ID && block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }
        operator = operator_;
    }

    function time() public view returns (uint64) {
        return uint64(block.timestamp) + offset;
    }

    function isSimulation() external pure returns (bool) {
        return true;
    }

    /// @notice Move simulated time forward by `secs`.
    function advance(uint64 secs) external {
        if (msg.sender != operator) revert NotOperator();
        uint64 from = time();
        offset += secs;
        emit ClockAdvanced(from, time());
    }

    /// @notice Move simulated time forward to `t`. Reverts if `t` is in the simulated past.
    function warpTo(uint64 t) external {
        if (msg.sender != operator) revert NotOperator();
        uint64 from = time();
        if (t < from) revert ClockBackwards(from, t);
        offset += t - from;
        emit ClockAdvanced(from, t);
    }
}
