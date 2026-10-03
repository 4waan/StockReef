// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClock} from "../interfaces/IClock.sol";

/// @title BlockClock
/// @notice Production clock: the chain's block timestamp, in UTC seconds.
/// @dev script/Deploy.s.sol deploys it whenever the manifest does not select the demo clock (docs/SPEC.md §9).
/// It has no owner and no state, so nobody can move it.
contract BlockClock is IClock {
    /// @inheritdoc IClock
    /// @dev Returns `block.timestamp` cast to uint64, in UTC seconds; the cast cannot truncate a realistic timestamp.
    function time() external view returns (uint64) {
        return uint64(block.timestamp);
    }

    /// @inheritdoc IClock
    /// @dev Always false.
    function isSimulation() external pure returns (bool) {
        return false;
    }
}
