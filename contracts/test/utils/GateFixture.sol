// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixtures} from "./Fixtures.sol";
import {ScriptedFeed} from "./ScriptedFeed.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {DemoClock} from "../../src/clock/DemoClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A PriceGate on the local chain with the generated calendar, a demo clock and mock feeds.
/// Time moves with vm.warp: the demo clock's offset stays zero, so clock time equals block time.
abstract contract GateFixture is Fixtures {
    // Monday 2026-09-14 regular session, after the weekend close of Friday 2026-09-11 (UTC seconds).
    uint64 internal constant FRI_CLOSE = 1789156800;
    uint64 internal constant MON_OPEN = 1789392600;
    uint64 internal constant MON_CLOSE = 1789416000;
    uint64 internal constant TUE_OPEN = MON_OPEN + 1 days;

    int256 internal constant TSLA_400 = 400e8;
    uint256 internal constant ANSWER_BOUND = 1e14;
    uint32 internal constant MOCK_MAX_AGE = 120;

    SessionCalendar internal cal;
    DemoClock internal clock;
    MockAggregatorV3 internal stockFeed;
    MockStockToken internal tsla;
    MockUSDG internal usdg;
    PriceGate internal gate;
    address internal guardian = makeAddr("guardian");

    function _setUpGate() internal {
        cal = _deployCalendar();
        clock = new DemoClock(address(this));
        stockFeed = new MockAggregatorV3(8, "Simulated TSLA/USD", clock, address(this));
        tsla = new MockStockToken("Tesla Stock Token", "TSLA", true);
        usdg = new MockUSDG();
        gate = new PriceGate(_config());
    }

    function _config() internal view returns (PriceGate.Config memory c) {
        c.token = address(tsla);
        c.tokenDecimals = 18;
        c.pauseFlagRequired = true;
        c.erc8056 = true;
        c.loanToken = address(usdg);
        c.loanDecimals = 6;
        c.stockFeed = PriceGate.Feed(IAggregatorV3(address(stockFeed)), 8, MOCK_MAX_AGE, ANSWER_BOUND);
        c.pegLabel = "Test peg: 1 USDG = 1 USD";
        c.clock = clock;
        c.calendar = cal;
        c.guardian = guardian;
    }

    function _warp(uint256 t) internal {
        vm.warp(t);
    }

    /// @dev Warp to `t` and publish `answer` stamped at `t`.
    function _pushAt(uint256 t, int256 answer) internal {
        vm.warp(t);
        stockFeed.push(answer);
    }

    /// @dev Warp to `t`, publish a fresh 400 USD price and refresh the gate.
    function _freshRefresh(uint256 t) internal returns (PriceGate.Quote memory) {
        _pushAt(t, TSLA_400);
        return gate.refresh();
    }

    function _monIndex() internal view returns (uint256) {
        return cal.context(MON_OPEN).index;
    }
}
