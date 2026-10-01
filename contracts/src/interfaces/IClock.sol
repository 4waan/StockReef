// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Time source shared by every StockReef contract. Production deployments use the block clock;
/// demo deployments use a labelled, monotonic DemoClock.
interface IClock {
    function time() external view returns (uint64);

    /// @notice True when this clock is a simulation clock that an operator can advance.
    function isSimulation() external view returns (bool);
}
