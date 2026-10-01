// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClock} from "../interfaces/IClock.sol";

/// @notice Production clock: the chain's block timestamp.
contract BlockClock is IClock {
    function time() external view returns (uint64) {
        return uint64(block.timestamp);
    }

    function isSimulation() external pure returns (bool) {
        return false;
    }
}
