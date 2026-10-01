// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GateFixture} from "./GateFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";

/// @notice Exposes the trim arithmetic so golden values can be checked without interest.
contract MarketHarness is StockReefMarket {
    constructor(IERC20 loan, IERC20 coll, SessionRiskPolicy p, uint256 minLoan_)
        StockReefMarket(loan, coll, p, minLoan_, "StockReef TSLA/USDG", "srUSDG")
    {}

    function trimAmounts(
        uint256 collateral,
        uint256 debt,
        uint256 value,
        SessionRiskPolicy.Snapshot memory s,
        uint256 bonusWad,
        uint256 maxRepay
    ) external view returns (uint256, uint256, bool) {
        return _trimAmounts(collateral, debt, value, s, bonusWad, maxRepay);
    }
}

/// @notice A deployed market around the Friday 2026-09-11 session (weekend close) and the following Monday.
/// The test contract plays the keeper: it keeps the mock feed fresh and refreshes the gate.
abstract contract MarketFixture is GateFixture {
    uint64 internal constant FRI_OPEN = 1789133400;
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;
    uint256 internal constant MIN_LOAN = 5e6;

    SessionRiskPolicy internal policy;
    MarketHarness internal market;
    RepaymentEscrow internal escrow;
    int256 internal answer = TSLA_400;

    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice"); // funded buffer
    address internal bob = makeAddr("bob"); // no buffer
    address internal carol = makeAddr("carol"); // nobody acts
    address internal liquidator = makeAddr("liquidator");

    function _setUpMarket() internal {
        vm.warp(FRI_OPEN - 1 hours);
        _setUpGate();
        policy = new SessionRiskPolicy(gate);
        market = new MarketHarness(usdg, tsla, policy, MIN_LOAN);
        escrow = market.escrow();

        usdg.mint(lender, 1_000_000 * USDG);
        usdg.mint(liquidator, 1_000_000 * USDG);
        vm.prank(lender);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    /// @dev Keeper tick: warp, publish the current answer, refresh the gate.
    function _tick(uint256 t) internal returns (SessionRiskPolicy.Snapshot memory) {
        vm.warp(t);
        stockFeed.push(answer);
        gate.refresh();
        return policy.snapshot();
    }

    function _setPrice(int256 a) internal {
        answer = a;
        stockFeed.push(a);
    }

    /// @dev Admit Friday's opening price and move to OPEN.
    function _openFriday() internal {
        _tick(FRI_OPEN + 5 minutes);
        _tick(FRI_OPEN + 15 minutes);
    }

    function _lend(uint256 amount) internal {
        vm.prank(lender);
        market.deposit(amount, lender);
    }

    function _fundCollateral(address who, uint256 raw) internal {
        tsla.mint(who, raw);
        vm.startPrank(who);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(raw, who);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        market.borrow(amount, who);
    }

    /// @dev The spec's worked example: 25 TSLA at 400 = 10,000 USDG of collateral, 7,200 USDG of debt.
    function _workedExample(address who) internal {
        _fundCollateral(who, 25 * TOKEN);
        _borrow(who, 7_200 * USDG);
    }

    function _state() internal view returns (SessionRiskPolicy.State) {
        return policy.snapshot().state;
    }
}
