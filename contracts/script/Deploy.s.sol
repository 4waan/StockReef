// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";
import {PriceGate} from "../src/PriceGate.sol";
import {SessionRiskPolicy} from "../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../src/StockReefMarket.sol";
import {StockReefLens} from "../src/StockReefLens.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IClock} from "../src/interfaces/IClock.sol";
import {BlockClock} from "../src/clock/BlockClock.sol";
import {DemoController} from "../src/demo/DemoController.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @notice Deploys a StockReef market from a deployment manifest and the generated session calendar.
///
///   forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast [--slow --gas-estimate-multiplier 300]
///
/// Environment: MANIFEST (default ../deployments/manifest.<chainid>.json), GUARDIAN (default: the deployer).
/// Writes ../deployments/addresses.<chainid>.json. A manifest with `"clock": "demo"` deploys the labelled
/// DemoController, which owns the demo clock and the mock stock feed; the deployer is its operator.
contract Deploy is Script {
    struct Deployed {
        SessionCalendar calendar;
        IClock clock;
        DemoController demo;
        IAggregatorV3 stockFeed;
        address loanToken;
        address collateralToken;
        PriceGate gate;
        SessionRiskPolicy policy;
        StockReefMarket market;
        StockReefLens lens;
    }

    string internal manifest;

    function run() external returns (Deployed memory d) {
        string memory path =
            vm.envOr("MANIFEST", string.concat("../deployments/manifest.", vm.toString(block.chainid), ".json"));
        manifest = vm.readFile(path);
        require(vm.parseJsonUint(manifest, ".chainId") == block.chainid, "manifest is for another chain");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address guardian = vm.envOr("GUARDIAN", deployer);

        d.calendar = _deployCalendar();
        _deployClockAndFeed(d, deployer);
        _resolveTokens(d, deployer);

        d.gate = new PriceGate(_gateConfig(d, guardian));
        d.policy = new SessionRiskPolicy(d.gate);
        d.market = new StockReefMarket(
            IERC20(d.loanToken),
            IERC20(d.collateralToken),
            d.policy,
            vm.parseUint(vm.parseJsonString(manifest, ".minLoan")),
            "StockReef TSLA/USDG lender share",
            "srUSDG"
        );
        d.lens = new StockReefLens(d.market);
        vm.stopBroadcast();

        _write(d, guardian);
    }

    function _deployCalendar() internal returns (SessionCalendar) {
        string memory sessions = vm.readFile("../tools/calendar/sessions.json");
        return new SessionCalendar(vm.parseJsonUintArray(sessions, ".packed"), vm.parseJsonUint(sessions, ".count"));
    }

    function _deployClockAndFeed(Deployed memory d, address deployer) internal {
        bool demoClock = _eq(vm.parseJsonString(manifest, ".clock"), "demo");
        bool mockFeed = _eq(vm.parseJsonString(manifest, ".stockFeed.type"), "mock");
        if (demoClock) {
            require(mockFeed, "the demo clock is only used with the mock feed");
            d.demo = new DemoController(
                deployer,
                uint8(vm.parseJsonUint(manifest, ".stockFeed.decimals")),
                vm.parseJsonString(manifest, ".stockFeed.label"),
                d.calendar.lastOpen()
            );
            d.clock = d.demo.clock();
            d.stockFeed = d.demo.feed();
        } else {
            require(!mockFeed, "a mock feed needs the demo clock");
            d.clock = new BlockClock();
            d.stockFeed = IAggregatorV3(vm.parseJsonAddress(manifest, ".stockFeed.address"));
        }
    }

    function _resolveTokens(Deployed memory d, address deployer) internal {
        if (_eq(vm.parseJsonString(manifest, ".loanToken.address"), "mock")) {
            MockUSDG usdg = new MockUSDG();
            usdg.mint(deployer, 1_000_000e6);
            d.loanToken = address(usdg);
        } else {
            d.loanToken = vm.parseJsonAddress(manifest, ".loanToken.address");
        }
        if (_eq(vm.parseJsonString(manifest, ".collateralToken.address"), "mock")) {
            MockStockToken tsla = new MockStockToken(
                "Tesla Stock Token (mock)", "TSLA", vm.parseJsonBool(manifest, ".collateralToken.pauseFlagRequired")
            );
            tsla.mint(deployer, 1_000e18);
            d.collateralToken = address(tsla);
        } else {
            d.collateralToken = vm.parseJsonAddress(manifest, ".collateralToken.address");
        }
    }

    function _gateConfig(Deployed memory d, address guardian) internal view returns (PriceGate.Config memory c) {
        c.token = d.collateralToken;
        c.tokenDecimals = uint8(vm.parseJsonUint(manifest, ".collateralToken.decimals"));
        c.pauseFlagRequired = vm.parseJsonBool(manifest, ".collateralToken.pauseFlagRequired");
        c.erc8056 = vm.parseJsonBool(manifest, ".collateralToken.erc8056");
        c.loanToken = d.loanToken;
        c.loanDecimals = uint8(vm.parseJsonUint(manifest, ".loanToken.decimals"));
        c.stockFeed = PriceGate.Feed(
            d.stockFeed,
            uint8(vm.parseJsonUint(manifest, ".stockFeed.decimals")),
            uint32(vm.parseJsonUint(manifest, ".stockFeed.maxAgeSeconds")),
            vm.parseUint(vm.parseJsonString(manifest, ".stockFeed.answerBound"))
        );
        if (_eq(vm.parseJsonString(manifest, ".loanFeed.type"), "peg")) {
            c.pegLabel = vm.parseJsonString(manifest, ".loanFeed.label");
        } else {
            c.loanFeed = PriceGate.Feed(
                IAggregatorV3(vm.parseJsonAddress(manifest, ".loanFeed.address")),
                uint8(vm.parseJsonUint(manifest, ".loanFeed.decimals")),
                uint32(vm.parseJsonUint(manifest, ".loanFeed.maxAgeSeconds")),
                vm.parseUint(vm.parseJsonString(manifest, ".loanFeed.answerBound"))
            );
        }
        if (vm.keyExistsJson(manifest, ".sequencerFeed.address") && !_isNull(".sequencerFeed.address")) {
            c.sequencerFeed = IAggregatorV3(vm.parseJsonAddress(manifest, ".sequencerFeed.address"));
            c.sequencerGrace = uint32(vm.parseJsonUint(manifest, ".sequencerFeed.graceSeconds"));
        }
        c.clock = d.clock;
        c.calendar = d.calendar;
        c.guardian = guardian;
    }

    function _write(Deployed memory d, address guardian) internal {
        string memory k = "addresses";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "calendar", address(d.calendar));
        vm.serializeAddress(k, "clock", address(d.clock));
        vm.serializeAddress(k, "demoController", address(d.demo));
        vm.serializeAddress(k, "stockFeed", address(d.stockFeed));
        vm.serializeAddress(k, "loanToken", d.loanToken);
        vm.serializeAddress(k, "collateralToken", d.collateralToken);
        vm.serializeAddress(k, "gate", address(d.gate));
        vm.serializeAddress(k, "policy", address(d.policy));
        vm.serializeAddress(k, "market", address(d.market));
        vm.serializeAddress(k, "escrow", address(d.market.escrow()));
        vm.serializeAddress(k, "guardian", guardian);
        string memory json = vm.serializeAddress(k, "lens", address(d.lens));
        string memory out = string.concat("../deployments/addresses.", vm.toString(block.chainid), ".json");
        vm.writeJson(json, out);
        console.log("market", address(d.market));
        console.log("lens", address(d.lens));
        console.log("written", out);
    }

    function _isNull(string memory key) internal view returns (bool) {
        bytes memory raw = vm.parseJson(manifest, key);
        return raw.length == 0 || keccak256(raw) == keccak256(abi.encode(address(0)));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
