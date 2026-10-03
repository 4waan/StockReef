// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IClock
/// @notice Time source shared by the StockReef contracts. Production deployments use the block clock;
/// demo deployments use a labelled, monotonic DemoClock.
/// @dev PriceGate, SessionRiskPolicy, StockReefMarket and RepaymentEscrow read the same clock (the policy takes it
/// from the gate, the market and escrow from the policy), so within one transaction a session phase, a price age
/// and the debt index are judged at the same time. On demo deployments MockAggregatorV3 stamps its rounds with the
/// same clock, so price ages follow simulated time. The clock is trusted: PriceGate accepts any non-zero IClock.
/// script/Deploy.s.sol deploys BlockClock unless the manifest selects the demo clock, and DemoClock refuses to
/// deploy outside an explicit test-chain allowlist (docs/SPEC.md §9, appendix R6).
/// Invariant expected by callers: `time()` never decreases. StockReefMarket's debt index reverts for a time
/// before the market's deployment epoch, and PriceGate's admission and checkpoint records assume time moves
/// forward.
interface IClock {
    /// @notice Current time as StockReef sees it, in UTC seconds.
    /// @dev Callers rely on it never decreasing between calls.
    /// @return Current time, UTC seconds.
    function time() external view returns (uint64);

    /// @notice True when this clock is a simulation clock that an operator can advance.
    /// @dev StockReefLens reports it so the app labels simulated time as simulation (appendix R6, R9).
    /// @return True for a simulation clock (DemoClock); false for the block clock.
    function isSimulation() external view returns (bool);
}
