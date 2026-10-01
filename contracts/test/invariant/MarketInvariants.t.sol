// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

/// @notice Random borrowers, lenders, a keeper and a liquidator acting across real sessions and price moves.
/// Every successful price-dependent action records the policy state it ran in.
contract MarketHandler is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;

    MarketHarness internal market;
    RepaymentEscrow internal escrow;
    SessionRiskPolicy internal policy;
    PriceGate internal gate;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    MockUSDG internal usdg;

    address[4] public actors;
    address internal lender = address(0xA11CE);
    address internal liquidator = address(0x11D);
    int256 public answer = 400e8;

    // Ghost records.
    uint256 public borrowsOutsideWindow;
    uint256 public trimsOutsideWindow;
    uint256 public buffersOutsideWindow;
    uint256 public trimsWithoutCapital;
    uint256 public lenderOpsOutsideWindow;
    uint256 public calls;
    uint256 public okBorrow;
    uint256 public okTrim;
    uint256 public okBuffer;
    uint256 public okLend;
    uint256 public okRedeem;
    uint256 public writeOffs;

    address internal owner; // the fixture: issuer of the mocks and publisher of the feed

    constructor(MarketHarness m, MockAggregatorV3 f, MockStockToken t, MockUSDG u, address owner_) {
        owner = owner_;
        market = m;
        escrow = m.escrow();
        policy = m.policy();
        gate = m.gate();
        feed = f;
        tsla = t;
        usdg = u;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xB000 + i));
            vm.startPrank(actors[i]);
            usdg.approve(address(market), type(uint256).max);
            usdg.approve(address(escrow), type(uint256).max);
            tsla.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    // ---------------------------------------------------------------- time and price

    function tick(uint256 dt, int256 moveBps) external {
        calls++;
        // Mostly short steps inside a session; one in six crosses the close into the next session, landing
        // anywhere from just before its open to late in the day. Gap moves are larger than intraday ones.
        if (dt % 6 == 0) {
            SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
            if (!c.covered) return;
            vm.warp(c.nextOpen - 10 minutes + (dt % 7 hours));
            moveBps = bound(moveBps, -3_500, 2_000);
        } else {
            vm.warp(block.timestamp + bound(dt, 1 minutes, 90 minutes));
            moveBps = bound(moveBps, -800, 800);
        }
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
    }

    // ---------------------------------------------------------------- lenders

    function lend(uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(amount, calls))));
        amount = bound(amount, 1 * USDG, 50_000 * USDG);
        SessionRiskPolicy.State st = policy.snapshot().state;
        _mintUsdg(lender, amount);
        vm.prank(lender);
        try market.deposit(amount, lender) {
            okLend++;
            if (st != SessionRiskPolicy.State.OPEN) lenderOpsOutsideWindow++;
        } catch {}
    }

    function redeem(uint256 shares) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(shares, calls))));
        shares = bound(shares, 1, market.balanceOf(lender) + 1);
        SessionRiskPolicy.State st = policy.snapshot().state;
        vm.prank(lender);
        try market.redeem(shares, lender, lender) {
            okRedeem++;
            if (st != SessionRiskPolicy.State.OPEN) lenderOpsOutsideWindow++;
        } catch {}
    }

    // ---------------------------------------------------------------- borrowers

    function addCollateral(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 50 * TOKEN);
        _mintTsla(a, amount);
        vm.prank(a);
        market.depositCollateral(amount, a);
    }

    function removeCollateral(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, market.collateralOf(a) + 1);
        bool hadDebt = market.debtOf(a) != 0;
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        vm.prank(a);
        try market.withdrawCollateral(amount, a) {
            if (hadDebt && !_borrowWindow(s)) borrowsOutsideWindow++;
        } catch {}
    }

    function borrow(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        // Aim near the borrower's current capacity so that limit checks are exercised from both sides.
        uint256 capacity = gate.valueOf(market.collateralOf(a), s.priceWad) * 76 / 100;
        uint256 debt = market.debtOf(a);
        amount = bound(amount, 5 * USDG, capacity > debt + 5 * USDG ? capacity - debt : 5 * USDG);
        vm.prank(a);
        try market.borrow(amount, a) {
            okBorrow++;
            if (!_borrowWindow(s)) borrowsOutsideWindow++;
        } catch {}
    }

    function repay(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 30_000 * USDG);
        _mintUsdg(a, amount);
        vm.prank(a);
        try market.repay(amount, a) {} catch {}
    }

    function fundBuffer(uint256 seed, uint256 amount, uint256 targetBps) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 5_000 * USDG);
        _mintUsdg(a, amount);
        vm.startPrank(a);
        escrow.deposit(amount, a);
        try escrow.authorize(bound(targetBps, 5_000, 6_500) * 1e14, 2_000 * USDG, uint64(block.timestamp + 10 days)) {}
            catch {}
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- keeper and liquidator

    function executeBuffer(uint256 seed) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        try escrow.executeBuffer(a) {
            okBuffer++;
            if (s.state != SessionRiskPolicy.State.PRE_CLOSE && s.state != SessionRiskPolicy.State.FINAL_WINDOW) {
                buffersOutsideWindow++;
            }
        } catch {}
    }

    function trim(uint256 seed, uint256 maxRepay) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        maxRepay = bound(maxRepay, 1, 50_000 * USDG);
        _mintUsdg(liquidator, maxRepay);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 usdgBefore = usdg.balanceOf(liquidator);
        vm.prank(liquidator);
        try market.trim(a, maxRepay, 0, block.timestamp) returns (uint256 repaid, uint256 out) {
            okTrim++;
            if (!s.canTrim || s.time >= s.close) trimsOutsideWindow++;
            if (usdgBefore - usdg.balanceOf(liquidator) != repaid || (out != 0 && repaid == 0)) {
                trimsWithoutCapital++;
            }
        } catch {}
    }

    /// @dev Time passes between actions: 1 to 15 minutes, with a move of up to 2% either way.
    function _flow(uint256 r) internal {
        vm.warp(block.timestamp + 1 minutes + (r % 15 minutes));
        // Overnight and weekends: three times in four, skip to just around the next open.
        SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
        if (c.covered && !c.inSession && (r >> 40) % 4 != 0) {
            vm.warp(c.nextOpen - 2 minutes + ((r >> 48) % 30 minutes));
        }
        int256 moveBps = int256((r >> 16) % 401) - 200;
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
    }

    function _mintUsdg(address to, uint256 amount) internal {
        vm.prank(owner);
        usdg.mint(to, amount);
    }

    function _mintTsla(address to, uint256 amount) internal {
        vm.prank(owner);
        tsla.mint(to, amount);
    }

    function _borrowWindow(SessionRiskPolicy.Snapshot memory s) internal pure returns (bool) {
        return
            (s.state == SessionRiskPolicy.State.OPEN || s.state == SessionRiskPolicy.State.PRE_CLOSE)
                && s.time < s.finalAt;
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }
}

import {console} from "forge-std/console.sol";

contract MarketInvariants is MarketFixture {
    function afterInvariant() external view {
        console.log("borrow", handler.okBorrow(), "trim", handler.okTrim());
        console.log("buffer", handler.okBuffer(), "lend", handler.okLend());
        console.log("redeem", handler.okRedeem(), "badDebt", market.totalBadDebt());
    }

    MarketHandler internal handler;

    function setUp() public {
        _setUpMarket();
        _openFriday();
        handler = new MarketHandler(market, stockFeed, tsla, usdg, address(this));
        // Seed: lender liquidity and four collateralised borrowers, two of them indebted.
        _lend(200_000 * USDG);
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            tsla.mint(a, 50 * TOKEN);
            vm.prank(a);
            market.depositCollateral(50 * TOKEN, a);
            if (i < 2) {
                vm.prank(a);
                market.borrow(14_000 * USDG, a);
            }
        }
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = MarketHandler.tick.selector;
        actions[1] = MarketHandler.lend.selector;
        actions[2] = MarketHandler.redeem.selector;
        actions[3] = MarketHandler.addCollateral.selector;
        actions[4] = MarketHandler.removeCollateral.selector;
        actions[5] = MarketHandler.borrow.selector;
        actions[6] = MarketHandler.repay.selector;
        actions[7] = MarketHandler.fundBuffer.selector;
        actions[8] = MarketHandler.executeBuffer.selector;
        actions[9] = MarketHandler.trim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_loanTokenConservation() public view {
        assertEq(usdg.balanceOf(address(market)), market.cash(), "market USDG equals lender cash");
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_collateralConservation() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += market.collateralOf(handler.actors(i));
        }
        assertEq(tsla.balanceOf(address(market)), sum, "market collateral equals account collateral");
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_debtSharesAddUp() public view {
        uint256 sum;
        uint256 withDebt;
        for (uint256 i; i < 4; ++i) {
            (, uint256 shares,) = market.accountOf(handler.actors(i));
            sum += shares;
            if (shares != 0) withDebt++;
        }
        assertEq(market.totalDebtShares(), sum);
        assertEq(market.activeAccounts().length, withDebt, "active set holds exactly the indebted accounts");
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_escrowBalancesAddUp() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += escrow.planOf(handler.actors(i)).balance;
        }
        assertEq(usdg.balanceOf(address(escrow)), sum);
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_actionsOnlyInTheirWindows() public view {
        assertEq(handler.borrowsOutsideWindow(), 0, "borrowing");
        assertEq(handler.trimsOutsideWindow(), 0, "trims");
        assertEq(handler.buffersOutsideWindow(), 0, "buffers");
        assertEq(handler.lenderOpsOutsideWindow(), 0, "lender windows");
        assertEq(handler.trimsWithoutCapital(), 0, "no collateral without repayment");
    }

    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 48
    function invariant_bookNeverExceedsCashPlusDebt() public view {
        uint256 debt;
        for (uint256 i; i < 4; ++i) {
            debt += market.debtOf(handler.actors(i));
        }
        assertLe(market.totalAssets(), market.cash() + debt);
    }
}
