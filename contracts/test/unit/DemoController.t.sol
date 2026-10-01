// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DemoController} from "../../src/demo/DemoController.sol";
import {DemoClock} from "../../src/clock/DemoClock.sol";

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
}
