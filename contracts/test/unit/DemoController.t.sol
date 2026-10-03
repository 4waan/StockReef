// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console} from "forge-std/console.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {ScriptedFeed} from "../utils/ScriptedFeed.sol";
import {DemoController} from "../../src/demo/DemoController.sol";
import {DemoClock} from "../../src/clock/DemoClock.sol";
import {BlockClock} from "../../src/clock/BlockClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";

contract DemoControllerTest is Test {
    DemoController internal demo;
    uint64 internal latest;

    function setUp() public {
        vm.warp(1_790_000_000);
        latest = uint64(block.timestamp + 30 days);
        demo = new DemoController(address(this), 8, "Simulated TSLA/USD", latest);
    }

    function test_stepMovesTheClockAndPublishesTogether() public {
        demo.step(1 hours, 400e8);
        (, int256 answer,, uint256 updatedAt,) = demo.feed().latestRoundData();
        assertEq(answer, 400e8);
        assertEq(updatedAt, block.timestamp + 1 hours);
        assertEq(demo.clock().time(), block.timestamp + 1 hours);
        assertTrue(demo.clock().isSimulation());
    }

    function test_onlyTheOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(DemoController.NotOperator.selector);
        demo.step(1, 400e8);
    }

    function test_stepsAreBoundedToSevenDays() public {
        vm.expectRevert(abi.encodeWithSelector(DemoController.StepTooLong.selector, 7 days + 1, 7 days));
        demo.step(7 days + 1, 400e8);
        demo.step(7 days, 400e8);
    }

    function test_neverPastTheLastLoadedOpen() public {
        for (uint256 i; i < 4; ++i) {
            demo.step(7 days, 400e8);
        }
        demo.stepTo(latest, 400e8);
        vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, latest + 1, latest));
        demo.advance(1);
    }

    function test_clockNeverMovesBackwards() public {
        demo.step(1 hours, 400e8);
        uint64 t = demo.clock().time();
        vm.expectRevert(abi.encodeWithSelector(DemoClock.ClockBackwards.selector, t, t - 1));
        demo.stepTo(t - 1, 400e8);
    }

    function test_refusesProductionChains() public {
        vm.chainId(4663);
        vm.expectRevert(abi.encodeWithSelector(DemoClock.ChainNotAllowed.selector, 4663));
        new DemoController(address(this), 8, "x", latest);
    }

    // ---------------------------------------------------------------- helpers for the tests below

    /// @dev Move the simulated clock forward by `secs` in steps of at most seven days, publishing nothing.
    function _advanceBy(uint256 secs) internal {
        while (secs > 0) {
            uint64 hop = uint64(secs > 7 days ? 7 days : secs);
            demo.advance(hop);
            secs -= hop;
        }
    }

    /// @dev The latest round must carry `answer`, be stamped `t` and use Chainlink's encoding for round `round`.
    function _assertLatestRound(uint64 round, int256 answer, uint256 t) internal view {
        (uint80 id, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) = demo.feed().latestRoundData();
        assertEq(id, (uint80(1) << 64) | round, "round id");
        assertEq(a, answer, "answer");
        assertEq(updatedAt, t, "stamped at the clock time");
        assertEq(startedAt, updatedAt, "startedAt");
        assertEq(answeredIn, id, "answeredInRound");
    }

    // ---------------------------------------------------------------- roles

    /// INV-DEMO-04: the controller alone moves its clock and publishes to its feed; the operator cannot reach
    /// either directly.
    function test_ownsItsClockAndFeed() public {
        DemoClock clock = demo.clock();
        MockAggregatorV3 feed = demo.feed();
        assertEq(demo.operator(), address(this));
        assertEq(clock.operator(), address(demo));
        assertEq(feed.owner(), address(demo));
        assertEq(address(feed.clock()), address(clock));
        assertEq(feed.decimals(), 8);
        assertEq(feed.phase(), 1);

        uint64 t = clock.time();
        vm.expectRevert(DemoClock.NotOperator.selector);
        clock.advance(1);
        vm.expectRevert(DemoClock.NotOperator.selector);
        clock.warpTo(t + 1);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.push(400e8);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.pushAt(400e8, t);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.bumpPhase();
    }

    /// INV-DEMO-04: every demo action reverts NotOperator for anyone else, and changes nothing.
    function testFuzz_onlyTheOperatorActs(address caller, uint64 secs, int256 answer) public {
        vm.assume(caller != address(this));
        uint64 t = demo.clock().time();
        vm.startPrank(caller);
        vm.expectRevert(DemoController.NotOperator.selector);
        demo.step(secs, answer);
        vm.expectRevert(DemoController.NotOperator.selector);
        demo.stepTo(t + secs % 7 days, answer);
        vm.expectRevert(DemoController.NotOperator.selector);
        demo.advance(secs);
        vm.expectRevert(DemoController.NotOperator.selector);
        demo.push(answer);
        vm.stopPrank();
        assertEq(demo.clock().time(), t);
        assertEq(demo.feed().latestRound(), 0);
    }

    // ---------------------------------------------------------------- bounds

    /// INV-DEMO-05, INV-DEMO-07: step succeeds iff it moves at most seven days and lands at or before `latest`;
    /// it then moves the clock by exactly `secs` and publishes the answer stamped at the new time (age zero).
    function testFuzz_stepIsBoundedAndStampsTheNewTime(uint256 startSeed, uint64 secs, int256 answer) public {
        _advanceBy(bound(startSeed, 0, 30 days - 1));
        secs = uint64(bound(secs, 0, 10 days));
        uint64 before = demo.clock().time();
        vm.assume(before + secs != latest); // landing exactly on `latest` is left unasserted
        if (secs > 7 days) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.StepTooLong.selector, secs, 7 days));
            demo.step(secs, answer);
            return;
        }
        if (before + secs > latest) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, before + secs, latest));
            demo.step(secs, answer);
            return;
        }
        demo.step(secs, answer);
        assertEq(demo.clock().time(), before + secs);
        assertLe(demo.clock().time(), latest);
        _assertLatestRound(1, answer, before + secs);
    }

    /// INV-DEMO-02, INV-DEMO-05, INV-DEMO-07: stepTo reverts StepTooLong beyond seven days, BeyondCoverage after
    /// `latest` and ClockBackwards before the current time; otherwise the clock reads `t` and the round is stamped
    /// `t`.
    function testFuzz_stepToIsBoundedAndMonotonic(uint256 startSeed, uint256 target, int256 answer) public {
        _advanceBy(bound(startSeed, 0, 30 days - 1));
        uint64 now_ = demo.clock().time();
        uint64 t = uint64(bound(target, now_ - 1 days, uint256(latest) + 1 days));
        vm.assume(t != latest); // landing exactly on `latest` is left unasserted
        if (t > now_ && t - now_ > 7 days) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.StepTooLong.selector, t - now_, 7 days));
        } else if (t > latest) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, t, latest));
        } else if (t < now_) {
            vm.expectRevert(abi.encodeWithSelector(DemoClock.ClockBackwards.selector, now_, t));
        }
        demo.stepTo(t, answer);
        if (t < now_ || t > latest || t - now_ > 7 days) {
            assertEq(demo.clock().time(), now_, "a refused step changes nothing");
            return;
        }
        assertEq(demo.clock().time(), t);
        _assertLatestRound(1, answer, t);
    }

    /// INV-DEMO-05, INV-DEMO-07: advance has the same bounds as step, moves the clock by exactly `secs`, publishes
    /// no round and logs a zero answer.
    function testFuzz_advanceIsBoundedAndPublishesNothing(uint256 startSeed, uint64 secs) public {
        _advanceBy(bound(startSeed, 0, 30 days - 1));
        demo.step(0, 400e8);
        secs = uint64(bound(secs, 0, 10 days));
        uint64 before = demo.clock().time();
        vm.assume(before + secs != latest); // landing exactly on `latest` is left unasserted
        if (secs > 7 days) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.StepTooLong.selector, secs, 7 days));
        } else if (before + secs > latest) {
            vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, before + secs, latest));
        } else {
            vm.expectEmit(address(demo));
            emit DemoController.Step(before + secs, 0);
        }
        demo.advance(secs);
        if (secs <= 7 days && before + secs <= latest) assertEq(demo.clock().time(), before + secs);
        else assertEq(demo.clock().time(), before);
        _assertLatestRound(1, 400e8, before);
    }

    /// INV-DEMO-05, INV-DEMO-07: push publishes at the current simulated time without moving the clock.
    function test_pushPublishesWithoutMovingTime() public {
        demo.step(1 hours, 400e8);
        uint64 t = demo.clock().time();
        vm.expectEmit(address(demo));
        emit DemoController.Step(t, 401e8);
        demo.push(401e8);
        assertEq(demo.clock().time(), t);
        _assertLatestRound(2, 401e8, t);
    }

    /// INV-DEMO-07: one step moves the clock, publishes the round and logs both, in that order.
    function test_stepEmitsTheMoveTheRoundAndTheStep() public {
        uint64 t0 = demo.clock().time();
        vm.expectEmit(address(demo.clock()));
        emit DemoClock.ClockAdvanced(t0, t0 + 1 hours);
        vm.expectEmit(address(demo.feed()));
        emit MockAggregatorV3.AnswerUpdated(400e8, (uint256(1) << 64) | 1, t0 + 1 hours);
        vm.expectEmit(address(demo));
        emit DemoController.Step(t0 + 1 hours, 400e8);
        demo.step(1 hours, 400e8);
    }

    /// INV-DEMO-05: block time keeps the clock running between calls; once it has carried the clock past
    /// `latest`, step and advance revert (BeyondCoverage, or StepTooLong beyond seven days), stepTo to an earlier
    /// time reverts ClockBackwards, and only push still publishes.
    function test_blockTimeCarriesTheClockPastLatest() public {
        _advanceBy(latest - demo.clock().time() - 1);
        vm.warp(block.timestamp + 2);
        uint64 t = demo.clock().time();
        assertEq(t, latest + 1);

        vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, t, latest));
        demo.step(0, 400e8);
        vm.expectRevert(abi.encodeWithSelector(DemoController.BeyondCoverage.selector, t + 1, latest));
        demo.advance(1);
        vm.expectRevert(abi.encodeWithSelector(DemoController.StepTooLong.selector, 7 days + 1, 7 days));
        demo.step(7 days + 1, 400e8);
        vm.expectRevert(abi.encodeWithSelector(DemoClock.ClockBackwards.selector, t, latest - 1));
        demo.stepTo(latest - 1, 400e8);

        demo.push(401e8);
        _assertLatestRound(1, 401e8, t);
    }

    // ---------------------------------------------------------------- chains and clocks

    /// INV-DEMO-01, INV-X-04: DemoClock and DemoController deploy only on the local chain and Robinhood Chain
    /// testnet.
    function testFuzz_deployOnlyOnTheTestChainAllowlist(uint64 chainId) public {
        chainId = uint64(bound(chainId, 1, type(uint64).max));
        vm.chainId(chainId);
        if (chainId == 31337 || chainId == 46630) {
            assertTrue(new DemoClock(address(this)).isSimulation());
            new DemoController(address(this), 8, "x", latest);
            return;
        }
        vm.expectRevert(abi.encodeWithSelector(DemoClock.ChainNotAllowed.selector, chainId));
        new DemoClock(address(this));
        vm.expectRevert(abi.encodeWithSelector(DemoClock.ChainNotAllowed.selector, chainId));
        new DemoController(address(this), 8, "x", latest);
    }

    /// INV-DEMO-01, INV-X-04: Ethereum mainnet and Robinhood Chain mainnet are refused; Robinhood Chain testnet is
    /// accepted.
    function test_namedChains() public {
        uint64[2] memory refused = [uint64(1), uint64(4663)];
        for (uint256 i; i < refused.length; ++i) {
            vm.chainId(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(DemoClock.ChainNotAllowed.selector, refused[i]));
            new DemoClock(address(this));
        }
        vm.chainId(46630);
        DemoController testnet = new DemoController(address(this), 8, "x", latest);
        assertEq(testnet.clock().time(), block.timestamp);
    }

    /// INV-DEMO-01: BlockClock is the block timestamp, is not a simulation and has no way to be moved.
    function testFuzz_blockClockIsTheBlockTimestamp(uint64 t) public {
        t = uint64(bound(t, 0, type(uint64).max - 1));
        BlockClock real = new BlockClock();
        vm.warp(t);
        assertEq(real.time(), t);
        assertFalse(real.isSimulation());
        (bool ok,) = address(real).call(abi.encodeCall(DemoClock.advance, (1)));
        assertFalse(ok, "no advance");
        (ok,) = address(real).call(abi.encodeCall(DemoClock.warpTo, (t + 1)));
        assertFalse(ok, "no warpTo");
    }
}

contract DemoClockTest is Test {
    DemoClock internal ck;

    function setUp() public {
        vm.warp(1_790_000_000);
        ck = new DemoClock(address(this));
    }

    /// INV-DEMO-02: across advances, forward warps, refused backward warps and block-time progress, time is
    /// always block time plus the offset and never decreases.
    function testFuzz_timeIsBlockTimePlusAForwardOffset(uint256[10] memory ops) public {
        uint64 last = ck.time();
        assertEq(last, block.timestamp, "starts at block time");
        for (uint256 k; k < ops.length; ++k) {
            uint256 op = ops[k] % 4;
            uint256 x = ops[k] >> 8;
            if (op == 0) {
                uint64 secs = uint64(bound(x, 0, 30 days));
                ck.advance(secs);
                assertEq(ck.time(), last + secs, "advance");
            } else if (op == 1) {
                uint64 t = uint64(bound(x, last, uint256(last) + 30 days));
                ck.warpTo(t);
                assertEq(ck.time(), t, "warpTo");
            } else if (op == 2) {
                uint64 t = uint64(bound(x, 0, uint256(last) - 1));
                vm.expectRevert(abi.encodeWithSelector(DemoClock.ClockBackwards.selector, last, t));
                ck.warpTo(t);
            } else {
                vm.warp(block.timestamp + bound(x, 0, 1 days));
            }
            assertEq(ck.time(), uint64(block.timestamp) + ck.offset(), "block time plus offset");
            assertGe(ck.time(), last, "never decreases");
            last = ck.time();
        }
    }

    /// INV-DEMO-02: only the clock's operator can raise the offset.
    function testFuzz_onlyTheOperatorMovesTheClock(address caller, uint64 secs) public {
        vm.assume(caller != address(this));
        uint64 t = ck.time();
        vm.startPrank(caller);
        vm.expectRevert(DemoClock.NotOperator.selector);
        ck.advance(secs);
        vm.expectRevert(DemoClock.NotOperator.selector);
        ck.warpTo(t + 1);
        vm.stopPrank();
        assertEq(ck.offset(), 0);
        assertEq(ck.time(), t);
    }

    /// INV-DEMO-02, INV-DEMO-03: the clock's arithmetic is checked: if it can reach 2^64 - 1, a further advance
    /// reverts, and once block time passes that point time() reverts rather than wrapping to an earlier time.
    function test_timeRevertsInsteadOfWrapping() public {
        try ck.advance(type(uint64).max - uint64(block.timestamp)) {}
        catch {
            return; // a clock that refuses the move cannot wrap
        }
        assertEq(ck.time(), type(uint64).max);
        vm.expectRevert(stdError.arithmeticError);
        ck.advance(1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(stdError.arithmeticError);
        ck.time();
    }
}

contract DemoMocksTest is Test {
    DemoClock internal ck;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    MockUSDG internal usdg;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_790_000_000);
        ck = new DemoClock(address(this));
        feed = new MockAggregatorV3(8, "Simulated TSLA/USD", ck, address(this));
        tsla = new MockStockToken("Tesla Stock Token", "TSLA", true);
        usdg = new MockUSDG();
    }

    // ---------------------------------------------------------------- MockAggregatorV3

    /// INV-DEMO-08: round ids use Chainlink's (phase << 64) | round encoding from 2^64 + 1, answeredInRound equals
    /// the round id, startedAt equals updatedAt, and earlier rounds stay readable.
    function test_feed_roundsFollowChainlinkEncoding() public {
        assertEq(feed.version(), 6);
        assertEq(feed.description(), "Simulated TSLA/USD");
        uint80 first = feed.push(400e8);
        assertEq(first, (uint80(1) << 64) | 1);
        ck.advance(60);
        uint80 second = feed.push(401e8);
        assertEq(second, first + 1);

        (uint80 id, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        assertEq(id, second);
        assertEq(a, 401e8);
        assertEq(updatedAt, ck.time());
        assertEq(startedAt, updatedAt);
        assertEq(answeredIn, id);
        (id, a,, updatedAt, answeredIn) = feed.getRoundData(first);
        assertEq(id, first);
        assertEq(a, 400e8);
        assertEq(updatedAt, ck.time() - 60);
        assertEq(answeredIn, first);
    }

    /// INV-DEMO-08: only the owner publishes or starts a phase.
    function testFuzz_feed_onlyTheOwnerPublishes(address caller, int256 answer, uint64 t) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.push(answer);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.pushAt(answer, t);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.bumpPhase();
        vm.stopPrank();
        assertEq(feed.latestRound(), 0);
        assertEq(feed.phase(), 1);
    }

    /// INV-DEMO-08: within a phase timestamps never decrease: a future stamp is accepted, an equal one too, and
    /// an earlier one (including a push at the clock time behind it) reverts.
    function test_feed_timestampsNeverDecreaseWithinAPhase() public {
        uint64 t = ck.time();
        feed.pushAt(400e8, t + 100);
        vm.expectRevert(MockAggregatorV3.TimestampDecreased.selector);
        feed.push(401e8);
        vm.expectRevert(MockAggregatorV3.TimestampDecreased.selector);
        feed.pushAt(401e8, t + 99);
        feed.pushAt(402e8, t + 100);
        assertEq(feed.latestRound(), 2);
        ck.advance(100);
        feed.push(403e8);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, t + 100);
    }

    /// INV-DEMO-08, INV-DEMO-09: bumpPhase empties latestRoundData until the next publish, restarts the round
    /// numbers and the timestamp order, and keeps the earlier phase readable.
    function test_feed_bumpPhaseRestartsRoundsAndOrder() public {
        uint80 old = feed.pushAt(400e8, 1_000);
        feed.bumpPhase();
        assertEq(feed.phase(), 2);
        vm.expectRevert(MockAggregatorV3.NoData.selector);
        feed.latestRoundData();
        uint80 id = feed.pushAt(399e8, 10);
        assertEq(id, (uint80(2) << 64) | 1);
        (uint80 r,,, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        assertEq(r, id);
        assertEq(updatedAt, 10);
        assertEq(answeredIn, id);
        (, int256 a,,,) = feed.getRoundData(old);
        assertEq(a, 400e8);
    }

    /// INV-DEMO-09: an empty feed, an unknown round and a round stamped zero all revert NoData instead of
    /// returning zeros.
    function test_feed_missingDataRevertsNoData() public {
        vm.expectRevert(MockAggregatorV3.NoData.selector);
        feed.latestRoundData();
        vm.expectRevert(MockAggregatorV3.NoData.selector);
        feed.getRoundData((uint80(1) << 64) | 7);
        feed.pushAt(400e8, 0);
        vm.expectRevert(MockAggregatorV3.NoData.selector);
        feed.latestRoundData();
    }

    // ---------------------------------------------------------------- mock tokens

    /// INV-DEMO-10: only the issuer mints, freezes, sets the pause flag or schedules a multiplier.
    function testFuzz_tokens_onlyTheIssuerAdministers(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(MockStockToken.NotIssuer.selector);
        tsla.mint(caller, 1);
        vm.expectRevert(MockStockToken.NotIssuer.selector);
        tsla.setFrozen(alice, true);
        vm.expectRevert(MockStockToken.NotIssuer.selector);
        tsla.setOraclePaused(true);
        vm.expectRevert(MockStockToken.NotIssuer.selector);
        tsla.scheduleMultiplier(2e18, 1);
        vm.expectRevert(MockUSDG.NotIssuer.selector);
        usdg.mint(caller, 1);
        vm.expectRevert(MockUSDG.NotIssuer.selector);
        usdg.setFrozen(alice, true);
        vm.stopPrank();
        assertEq(tsla.issuer(), address(this));
        assertEq(usdg.issuer(), address(this));
    }

    /// INV-DEMO-10: mints and transfers move exactly the amount asked, with no fee and no rebase.
    function testFuzz_tokens_moveExactAmounts(uint256 minted, uint256 sent) public {
        minted = bound(minted, 0, type(uint128).max);
        sent = bound(sent, 0, minted);
        tsla.mint(alice, minted);
        usdg.mint(alice, minted);
        vm.startPrank(alice);
        assertTrue(tsla.transfer(bob, sent));
        assertTrue(usdg.transfer(bob, sent));
        vm.stopPrank();
        assertEq(tsla.balanceOf(alice), minted - sent);
        assertEq(tsla.balanceOf(bob), sent);
        assertEq(usdg.balanceOf(alice), minted - sent);
        assertEq(usdg.balanceOf(bob), sent);
        assertEq(tsla.totalSupply(), minted);
        assertEq(usdg.totalSupply(), minted);
        assertEq(usdg.decimals(), 6);
        assertEq(tsla.decimals(), 18);
    }

    /// INV-DEMO-10: a transfer or mint touching a frozen party reverts AccountFrozen and leaves balances intact;
    /// unfreezing restores transfers.
    function test_tokens_frozenPartiesRevertWithBalancesIntact() public {
        tsla.mint(alice, 10e18);
        usdg.mint(alice, 10e6);
        tsla.setFrozen(alice, true);
        usdg.setFrozen(alice, true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountFrozen.selector, alice));
        tsla.transfer(bob, 1e18);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, alice));
        usdg.transfer(bob, 1e6);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountFrozen.selector, alice));
        tsla.mint(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, alice));
        usdg.mint(alice, 1);
        assertEq(tsla.balanceOf(alice), 10e18);
        assertEq(usdg.balanceOf(alice), 10e6);

        tsla.setFrozen(alice, false);
        usdg.setFrozen(alice, false);
        tsla.setFrozen(bob, true);
        usdg.setFrozen(bob, true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockStockToken.AccountFrozen.selector, bob));
        tsla.transfer(bob, 1e18);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, bob));
        usdg.transfer(bob, 1e6);
        vm.stopPrank();
        assertEq(tsla.balanceOf(alice), 10e18);
        assertEq(tsla.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(alice), 10e6);
        assertEq(usdg.balanceOf(bob), 0);
    }

    /// INV-DEMO-10: a frozen spender can still move an unfrozen holder's tokens with an allowance; only the
    /// holder and the receiver are checked.
    function test_tokens_frozenSpenderIsNotBlocked() public {
        address spender = makeAddr("spender");
        usdg.mint(alice, 10e6);
        vm.prank(alice);
        usdg.approve(spender, 10e6);
        usdg.setFrozen(spender, true);
        vm.prank(spender);
        assertTrue(usdg.transferFrom(alice, bob, 4e6));
        assertEq(usdg.balanceOf(bob), 4e6);
        assertEq(usdg.balanceOf(alice), 6e6);
    }

    /// INV-DEMO-10: the pause flag reads back when supported and reverts PauseFlagUnsupported otherwise.
    function test_stock_pauseFlag() public {
        assertFalse(tsla.oraclePaused());
        tsla.setOraclePaused(true);
        assertTrue(tsla.oraclePaused());
        MockStockToken noFlag = new MockStockToken("Tesla Stock Token", "TSLA", false);
        noFlag.setOraclePaused(true);
        vm.expectRevert(MockStockToken.PauseFlagUnsupported.selector);
        noFlag.oraclePaused();
    }

    /// INV-DEMO-11: the multiplier never switches when effectiveAt arrives; only the next scheduleMultiplier moves
    /// the scheduled value into uiMultiplier.
    function test_stock_multiplierNeverSwitchesAtEffectiveAt() public {
        tsla.mint(alice, 10e18);
        uint256 when = block.timestamp + 1 hours;
        tsla.scheduleMultiplier(2e18, when);
        assertEq(tsla.uiMultiplier(), 1e18);
        assertEq(tsla.newUIMultiplier(), 2e18);
        assertEq(tsla.effectiveAt(), when);
        vm.warp(when + 1 days);
        assertEq(tsla.uiMultiplier(), 1e18, "unchanged after effectiveAt");
        assertEq(tsla.balanceOfUI(alice), 10e18);
        tsla.scheduleMultiplier(3e18, 0);
        assertEq(tsla.uiMultiplier(), 2e18, "moved by the next schedule");
        assertEq(tsla.balanceOfUI(alice), 20e18);
        assertEq(tsla.balanceOf(alice), 10e18, "raw balance unchanged");
    }
}

/// @notice A market wired as script/Deploy.s.sol wires a demo deployment: the DemoController owns the clock and
/// the stock feed, and the test contract is its operator and the guardian.
contract DemoMarketTest is Fixtures {
    uint64 internal constant FRI_OPEN = 1789133400;
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;

    SessionCalendar internal cal;
    DemoController internal demo;
    MockStockToken internal tsla;
    MockUSDG internal usdg;
    PriceGate internal gate;
    SessionRiskPolicy internal policy;
    StockReefMarket internal market;
    StockReefLens internal lens;
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        vm.warp(FRI_OPEN - 1 hours);
        cal = _deployCalendar();
        demo =
            new DemoController(address(this), 8, "Simulated TSLA/USD price (demo feed, not Chainlink)", cal.lastOpen());
        tsla = new MockStockToken("Tesla Stock Token (mock)", "TSLA", true);
        usdg = new MockUSDG();
        gate = new PriceGate(_config(IAggregatorV3(address(demo.feed()))));
        policy = new SessionRiskPolicy(gate);
        market = new StockReefMarket(usdg, tsla, policy, 5 * USDG, "StockReef TSLA/USDG lender share", "srUSDG");
        lens = new StockReefLens(market);
    }

    function _config(IAggregatorV3 feed) internal view returns (PriceGate.Config memory c) {
        c.token = address(tsla);
        c.tokenDecimals = 18;
        c.pauseFlagRequired = true;
        c.erc8056 = true;
        c.loanToken = address(usdg);
        c.loanDecimals = 6;
        c.stockFeed = PriceGate.Feed(feed, 8, 120, 1e14);
        c.pegLabel = "Test peg: 1 USDG = 1 USD";
        c.clock = demo.clock();
        c.calendar = cal;
        c.guardian = address(this);
    }

    /// @dev Open Friday 2026-09-11 with demo steps and keeper refreshes, lend 100,000 USDG and give the borrower
    /// 25 TSLA against 7,200 USDG.
    function _openWithALoan() internal {
        demo.stepTo(FRI_OPEN + 5 minutes, 400e8);
        gate.refresh();
        demo.stepTo(FRI_OPEN + 15 minutes, 400e8);
        gate.refresh();
        usdg.mint(lender, 100_000 * USDG);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(100_000 * USDG, lender);
        vm.stopPrank();
        tsla.mint(borrower, 25 * TOKEN);
        vm.startPrank(borrower);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(25 * TOKEN, borrower);
        market.borrow(7_200 * USDG, borrower);
        vm.stopPrank();
    }

    /// INV-DEMO-07: the controller never refreshes the gate: after demo actions nothing is admitted or accepted
    /// until a keeper refreshes, and the round each step publishes has age zero at the simulated time.
    function test_controllerNeverRefreshesTheGate() public {
        vm.expectCall(address(gate), abi.encodeCall(PriceGate.refresh, ()), 0);
        demo.stepTo(FRI_OPEN + 5 minutes, 400e8);
        demo.step(10 minutes, 401e8);
        demo.advance(1 minutes);
        demo.push(402e8);
        assertEq(gate.lastAcceptedAt(), 0);
        assertEq(gate.lastPriceWad(), 0);
        assertEq(gate.admittedSession(), 0);
        PriceGate.Quote memory q = gate.quote();
        assertEq(q.updatedAt, demo.clock().time(), "age zero");
        assertEq(q.reasons, 0, "usable once a keeper refreshes");
        assertEq(q.priceWad, 402e18);
    }

    /// INV-DEMO-02: interest accrues on simulated time: advancing the clock without any block-time change raises
    /// the debt index to expWad(rate * simulated seconds since deployment).
    function test_simulatedTimeAccruesInterest() public {
        _openWithALoan();
        uint256 blockTime = block.timestamp;
        uint256 debt0 = market.debtOf(borrower);
        demo.advance(7 days);
        assertEq(block.timestamp, blockTime, "no block time passed");
        uint256 elapsed = demo.clock().time() - market.epoch();
        uint256 expected = uint256(FixedPointMathLib.expWad(int256(market.RATE_PER_SECOND() * elapsed)));
        assertEq(market.debtIndex(), expected);
        assertGt(market.debtOf(borrower), debt0);
        assertEq(lens.accountView(borrower).debt, market.debtOf(borrower));
    }

    /// INV-DEMO-01: the Lens labels the demo clock as simulation and reports simulated, not block, time.
    function test_lensLabelsTheDemoClock() public {
        _openWithALoan();
        demo.advance(3 days);
        StockReefLens.MarketView memory m = lens.marketView();
        assertTrue(m.simulationClock);
        assertTrue(demo.clock().isSimulation());
        assertEq(m.policy.time, demo.clock().time());
        assertEq(m.policy.time, block.timestamp + demo.clock().offset());
        assertGe(m.policy.time, block.timestamp + 3 days, "ahead of block time");
    }

    /// INV-DEMO-09: with no round published the demo feed reverts NoData, so the gate reports
    /// STOCK_FEED_UNAVAILABLE (not STOCK_NO_TIMESTAMP, as a Chainlink feed returning zeros would) and fails closed,
    /// as it does for the zero round; the views still answer.
    function test_emptyDemoFeedFailsClosed() public {
        // A controller whose feed has never published, on the same calendar and token pair.
        PriceGate.Quote memory q;
        DemoController empty = new DemoController(address(this), 8, "x", cal.lastOpen());
        empty.advance(1 hours + 10 minutes);
        PriceGate emptyGate = new PriceGate(_configWithClock(IAggregatorV3(address(empty.feed())), empty));
        q = emptyGate.quote();
        assertTrue(q.reasons & Reasons.STOCK_FEED_UNAVAILABLE != 0, "feed unavailable");
        assertEq(q.reasons & Reasons.STOCK_NO_TIMESTAMP, 0);
        assertEq(q.priceWad, 0);
        emptyGate.refresh();
        assertEq(emptyGate.lastAcceptedAt(), 0, "nothing accepted");

        ScriptedFeed zeros = new ScriptedFeed(8);
        zeros.set(400e8, 0, 0);
        PriceGate zeroGate = new PriceGate(_configWithClock(IAggregatorV3(address(zeros)), empty));
        q = zeroGate.quote();
        assertTrue(q.reasons & Reasons.STOCK_NO_TIMESTAMP != 0, "Chainlink-style zero round");
        assertEq(q.reasons & Reasons.STOCK_FEED_UNAVAILABLE, 0);

        StockReefMarket emptyMarket =
            new StockReefMarket(usdg, tsla, new SessionRiskPolicy(emptyGate), 5 * USDG, "StockReef", "srUSDG");
        StockReefLens emptyLens = new StockReefLens(emptyMarket);
        StockReefLens.MarketView memory m = emptyLens.marketView();
        assertTrue(m.valuationIndicative);
        assertEq(m.valuationPriceWad, 0);
        assertFalse(m.policy.canBorrow);
        assertFalse(m.policy.lenderOpen);
        assertEq(emptyLens.accountView(borrower).collateralValue, 0);
    }

    function _configWithClock(IAggregatorV3 feed, DemoController controller)
        internal
        view
        returns (PriceGate.Config memory c)
    {
        c = _config(feed);
        c.clock = controller.clock();
    }

    /// INV-DEMO-11: the market and the Lens value raw balances; a changed uiMultiplier moves no valuation.
    function test_valuationIgnoresTheUiMultiplier() public {
        _openWithALoan();
        StockReefLens.AccountView memory before = lens.accountView(borrower);
        uint256 recoverable = market.bookValuation().recoverable;
        tsla.scheduleMultiplier(2e18, 0);
        tsla.scheduleMultiplier(2e18, 0);
        assertEq(tsla.uiMultiplier(), 2e18);
        assertEq(tsla.balanceOfUI(address(market)), 2 * tsla.balanceOf(address(market)));
        StockReefLens.AccountView memory afterwards = lens.accountView(borrower);
        assertEq(afterwards.collateral, before.collateral);
        assertEq(afterwards.collateralValue, before.collateralValue);
        assertEq(afterwards.borrowCapacity, before.borrowCapacity);
        assertEq(market.bookValuation().recoverable, recoverable);
    }
}

/// @notice The demo operator driving the clock and feed through the controller, block time drifting between
/// calls, and strangers trying every restricted entry point.
contract DemoHandler is Test {
    uint64 internal constant MAX_STEP = 7 days;

    DemoController public demo;
    DemoClock public clock;
    MockAggregatorV3 public feed;
    uint64 public latest;
    uint64 public lastTime;
    uint64 public rounds;

    // Successful and refused actions.
    uint256 public okStep;
    uint256 public okStepTo;
    uint256 public okAdvance;
    uint256 public okPush;
    uint256 public refused;
    uint256 public atLatest;

    // Violations; all must stay zero.
    uint256 public backwards; // an observed clock time below the previous one
    uint256 public overlong; // a successful move of more than MAX_STEP
    uint256 public pastLatest; // a successful move landing after latest
    uint256 public badMoves; // a successful move that did not land where asked, or a push that moved time
    uint256 public unexpectedRefusals; // an in-bound move or a push refused
    uint256 public badRounds; // a round not stamped at the clock time, mis-numbered, or published by advance
    uint256 public intrusions; // a restricted call by anyone but its role succeeded

    constructor() {
        latest = uint64(block.timestamp + 60 days);
        demo = new DemoController(address(this), 8, "Simulated TSLA/USD", latest);
        clock = demo.clock();
        feed = demo.feed();
        lastTime = clock.time();
    }

    function _observe() internal {
        uint64 t = clock.time();
        if (t < lastTime) backwards++;
        lastTime = t;
    }

    function _moved(uint64 before, uint64 target) internal {
        uint64 t = clock.time();
        if (t != target) badMoves++;
        if (t - before > MAX_STEP) overlong++;
        if (t > latest) pastLatest++;
        if (t == latest) atLatest++;
    }

    function _published(int256 answer, uint64 t) internal {
        rounds++;
        (uint80 id, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        if (id != ((uint80(1) << 64) | rounds) || a != answer || updatedAt != t || startedAt != t || answeredIn != id) {
            badRounds++;
        }
    }

    /// @dev A request every bound accepts: forward, at most MAX_STEP, and before `latest` (landing exactly on
    /// `latest` may be accepted or refused).
    function _inBounds(uint64 before, uint64 target) internal view returns (bool) {
        return target >= before && target - before <= MAX_STEP && target < latest;
    }

    function step(uint64 secs, int256 answer) external {
        secs = uint64(bound(secs, 0, 8 days));
        uint64 before = clock.time();
        try demo.step(secs, answer) {
            okStep++;
            _moved(before, before + secs);
            _published(answer, before + secs);
        } catch {
            refused++;
            if (_inBounds(before, before + secs)) unexpectedRefusals++;
        }
        _observe();
    }

    function stepTo(uint64 dt, int256 answer, uint8 mode) external {
        uint64 before = clock.time();
        uint64 t;
        if (mode % 5 == 0) t = latest;
        else if (mode % 5 == 1) t = before - uint64(bound(dt, 1, 1 days));
        else t = before + uint64(bound(dt, 0, 8 days));
        try demo.stepTo(t, answer) {
            okStepTo++;
            _moved(before, t);
            _published(answer, t);
        } catch {
            refused++;
            if (_inBounds(before, t)) unexpectedRefusals++;
        }
        _observe();
    }

    function advance(uint64 secs) external {
        secs = uint64(bound(secs, 0, 8 days));
        uint64 before = clock.time();
        uint64 published = feed.latestRound();
        try demo.advance(secs) {
            okAdvance++;
            _moved(before, before + secs);
            if (feed.latestRound() != published) badRounds++;
        } catch {
            refused++;
            if (_inBounds(before, before + secs)) unexpectedRefusals++;
        }
        _observe();
    }

    function push(int256 answer) external {
        uint64 before = clock.time();
        try demo.push(answer) {
            okPush++;
            if (clock.time() != before) badMoves++;
            _published(answer, before);
        } catch {
            unexpectedRefusals++;
        }
        _observe();
    }

    /// @dev Block time passes between demo calls; the clock runs with it.
    function drift(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 6 hours));
        _observe();
    }

    /// @dev Anyone but the role holder calls a restricted entry point; the operator also tries the clock and the
    /// feed directly.
    function intrude(address caller, uint256 which, uint64 x) external {
        if (caller == address(this) || caller == address(demo)) caller = address(0xBAD);
        uint64 t = clock.time();
        uint256 k = which % 11;
        address target = k < 4 ? address(demo) : (k == 4 || k == 5 || k == 9) ? address(clock) : address(feed);
        bytes memory data;
        if (k == 0) data = abi.encodeCall(DemoController.step, (x % 1 hours, 1e8));
        else if (k == 1) data = abi.encodeCall(DemoController.stepTo, (t, 1e8));
        else if (k == 2) data = abi.encodeCall(DemoController.advance, (x % 1 hours));
        else if (k == 3) data = abi.encodeCall(DemoController.push, (1e8));
        else if (k == 4 || k == 9) data = abi.encodeCall(DemoClock.advance, (x % 1 hours));
        else if (k == 5) data = abi.encodeCall(DemoClock.warpTo, (t));
        else if (k == 6 || k == 10) data = abi.encodeCall(MockAggregatorV3.push, (1e8));
        else if (k == 7) data = abi.encodeCall(MockAggregatorV3.pushAt, (1e8, x));
        else data = abi.encodeCall(MockAggregatorV3.bumpPhase, ());
        // k = 9 and 10: the operator itself calls the clock or the feed directly.
        if (k < 9) vm.prank(caller);
        (bool ok,) = target.call(data);
        if (ok) intrusions++;
    }
}

contract DemoInvariantsTest is Test {
    DemoHandler internal handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        handler = new DemoHandler();
        bytes4[] memory actions = new bytes4[](8);
        actions[0] = DemoHandler.step.selector;
        actions[1] = DemoHandler.stepTo.selector;
        actions[2] = DemoHandler.advance.selector;
        actions[3] = DemoHandler.push.selector;
        actions[4] = DemoHandler.drift.selector;
        actions[5] = DemoHandler.intrude.selector;
        actions[6] = DemoHandler.step.selector;
        actions[7] = DemoHandler.stepTo.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("step", handler.okStep(), "stepTo", handler.okStepTo());
        console.log("advance", handler.okAdvance(), "push", handler.okPush());
        console.log("refused", handler.refused(), "landed on latest", handler.atLatest());
    }

    /// INV-DEMO-02: the clock is block time plus the offset and never decreases.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_clockNeverMovesBackwards() public view {
        DemoClock ck = handler.clock();
        assertEq(handler.backwards(), 0, "observed a backward move");
        assertEq(ck.time(), uint64(block.timestamp) + ck.offset(), "block time plus offset");
        assertGe(ck.time(), handler.lastTime(), "below the last observation");
    }

    /// INV-DEMO-05: every successful step, stepTo and advance moves at most seven days, lands where asked and
    /// never after latest; push never moves time; every in-bound request is accepted.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_movesAreBoundedBySevenDaysAndLatest() public view {
        assertEq(handler.overlong(), 0, "move longer than seven days");
        assertEq(handler.pastLatest(), 0, "move past latest");
        assertEq(handler.badMoves(), 0, "move landed elsewhere");
        assertEq(handler.unexpectedRefusals(), 0, "in-bound request refused");
    }

    /// INV-DEMO-07, INV-DEMO-08: every published round is stamped at the clock time of its call, numbered in
    /// sequence in phase 1 with answeredInRound equal to its id, and advance publishes nothing.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_roundsAreStampedAtTheClockTime() public view {
        MockAggregatorV3 feed = handler.feed();
        assertEq(handler.badRounds(), 0, "bad round");
        assertEq(feed.phase(), 1, "phase never bumped");
        assertEq(feed.latestRound(), handler.rounds(), "one round per publish");
        if (feed.latestRound() != 0) {
            (,,, uint256 updatedAt,) = feed.latestRoundData();
            assertLe(updatedAt, handler.clock().time(), "no future stamp");
        }
    }

    /// INV-DEMO-04: no restricted entry point of the controller, clock or feed ever succeeds for another caller.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_onlyTheOperatorActs() public view {
        assertEq(handler.intrusions(), 0, "restricted call succeeded");
    }
}
