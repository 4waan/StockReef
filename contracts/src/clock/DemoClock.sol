// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IClock} from "../interfaces/IClock.sol";

/// @title DemoClock
/// @notice Simulation clock for demos: block time plus an offset that only moves forward.
/// It refuses to deploy outside an explicit allowlist of test chains (local 31337 and Robinhood Chain
/// testnet 46630), so it can never stand in for real time on a production network.
/// @dev docs/SPEC.md §6 and §9, appendix R6 and R9. `time()` is `block.timestamp + offset`. Only `operator` can
/// raise `offset` and nothing can lower it, so simulated time never decreases, and it keeps running with block
/// time between moves. Simulated time drives sessions, price ages and interest exactly as real time does.
/// The clock itself does not limit how far one move goes; on demo deployments `operator` is the
/// DemoController, which moves it at most seven days per call and never to a time after its `latest` bound, the
/// open of the last loaded calendar session (appendix R18); block time can still carry the clock past that bound
/// between moves. The chain allowlist is checked only at deployment.
contract DemoClock is IClock {
    /// @notice Chain id of a local development chain, where the clock may be deployed.
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    /// @notice Chain id of Robinhood Chain testnet, where the clock may be deployed (appendix R6).
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    /// @notice The only address that may move the clock forward; fixed at deployment. On demo deployments it is
    /// the DemoController.
    address public immutable operator;
    /// @notice Seconds added to the block timestamp to give simulated time. Starts at zero and only grows.
    uint64 public offset;

    /// @notice Emitted when the operator moves simulated time forward.
    /// @param from Simulated time before the move, UTC seconds.
    /// @param to Simulated time after the move, UTC seconds; equal to `from` for a zero-length move.
    event ClockAdvanced(uint64 from, uint64 to);

    /// @notice The constructor ran on a chain outside the allowlist (31337 and 46630).
    /// @param chainId Chain id of the attempted deployment.
    error ChainNotAllowed(uint256 chainId);
    /// @notice The caller of `advance` or `warpTo` is not `operator`.
    error NotOperator();
    /// @notice `warpTo` asked for a time before the current simulated time.
    /// @param current Current simulated time, UTC seconds.
    /// @param requested Requested time, UTC seconds.
    error ClockBackwards(uint64 current, uint64 requested);

    /// @notice Deploys the clock with a zero offset, so it starts at block time.
    /// @dev Reverts with ChainNotAllowed unless `block.chainid` is LOCAL_CHAIN_ID or ROBINHOOD_TESTNET_CHAIN_ID.
    /// `operator_` is not checked; a zero address gives a clock that nobody can move.
    /// @param operator_ Address allowed to call `advance` and `warpTo`.
    constructor(address operator_) {
        if (block.chainid != LOCAL_CHAIN_ID && block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }
        operator = operator_;
    }

    /// @inheritdoc IClock
    /// @dev Returns `block.timestamp + offset` in checked uint64 arithmetic, so it reverts if the sum overflows.
    function time() public view returns (uint64) {
        return uint64(block.timestamp) + offset;
    }

    /// @inheritdoc IClock
    /// @dev Always true.
    function isSimulation() external pure returns (bool) {
        return true;
    }

    /// @notice Move simulated time forward by `secs`. Only `operator` may call it.
    /// @dev Only `operator`; reverts with NotOperator otherwise. Zero is allowed and emits an event with equal
    /// times. Reverts with an arithmetic panic if `offset` or the new time would overflow uint64. Emits
    /// ClockAdvanced with the times before and after.
    /// @param secs Seconds to add to simulated time.
    function advance(uint64 secs) external {
        if (msg.sender != operator) revert NotOperator();
        uint64 from = time();
        offset += secs;
        emit ClockAdvanced(from, time());
    }

    /// @notice Move simulated time forward to `t`. Only `operator` may call it. Reverts if `t` is in the simulated
    /// past.
    /// @dev Only `operator`; reverts with NotOperator otherwise, and with ClockBackwards when `t` is before the
    /// current simulated time. A `t` equal to the current time changes nothing but still emits. The new `offset` is
    /// `t - block.timestamp`, so the update cannot overflow. Afterwards `time()` returns `t` until the block
    /// timestamp or `offset` changes. Emits ClockAdvanced with the time before and `t`.
    /// @param t Target simulated time, UTC seconds.
    function warpTo(uint64 t) external {
        if (msg.sender != operator) revert NotOperator();
        uint64 from = time();
        if (t < from) revert ClockBackwards(from, t);
        offset += t - from;
        emit ClockAdvanced(from, t);
    }
}
