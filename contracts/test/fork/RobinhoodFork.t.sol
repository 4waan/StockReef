// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Fixtures} from "../utils/Fixtures.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {BlockClock} from "../../src/clock/BlockClock.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";

/// @notice Robinhood Chain mainnet at a pinned block: the real TSLA Stock Token, Paxos USDG and the Chainlink
/// TSLA/USD and USDG/USD feeds against StockReef's contracts.
///
/// The public RPC rejects clients without a browser User-Agent, which forge cannot set, so the suite runs
/// against a local fork:
///   anvil --port 8546 --fork-url https://rpc.mainnet.chain.robinhood.com \
///         --fork-header "User-Agent: Mozilla/5.0" --fork-block-number 78471588 --compute-units-per-second 5
///   FOUNDRY_PROFILE=fork forge test
/// The public RPC rate-limits and keeps only recent state: re-running at this block later needs an archive RPC,
/// or a re-pin to a recent block inside a regular session.
/// This validates interfaces and feed behaviour; it does not establish production economic safety.
contract RobinhoodForkTest is Fixtures {
    uint256 internal constant FORK_BLOCK = 78471588;

    string internal manifest;
    IERC20 internal tsla;
    IERC20 internal usdg;
    IAggregatorV3 internal tslaFeed;
    IAggregatorV3 internal usdgFeed;
    SessionCalendar internal cal;
    PriceGate internal gate;
    SessionRiskPolicy internal policy;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_FORK_RPC", string("http://127.0.0.1:8546")));
        require(block.chainid == 4663, "not Robinhood Chain mainnet");
        require(vm.getBlockNumber() == FORK_BLOCK, "fork is not at the pinned block");
        manifest = vm.readFile("../deployments/manifest.4663-fork.json");
        tsla = IERC20(vm.parseJsonAddress(manifest, ".collateralToken.address"));
        usdg = IERC20(vm.parseJsonAddress(manifest, ".loanToken.address"));
        tslaFeed = IAggregatorV3(vm.parseJsonAddress(manifest, ".stockFeed.address"));
        usdgFeed = IAggregatorV3(vm.parseJsonAddress(manifest, ".loanFeed.address"));
        cal = _deployCalendar();
        BlockClock clock = new BlockClock();

        PriceGate.Config memory c;
        c.token = address(tsla);
        c.tokenDecimals = 18;
        c.pauseFlagRequired = vm.parseJsonBool(manifest, ".collateralToken.pauseFlagRequired");
        c.erc8056 = true;
        c.loanToken = address(usdg);
        c.loanDecimals = 6;
        c.stockFeed = PriceGate.Feed(tslaFeed, 8, uint32(vm.parseJsonUint(manifest, ".stockFeed.maxAgeSeconds")), 1e14);
        c.loanFeed = PriceGate.Feed(usdgFeed, 8, uint32(vm.parseJsonUint(manifest, ".loanFeed.maxAgeSeconds")), 2e8);
        c.clock = clock;
        c.calendar = cal;
        c.guardian = address(this);
        gate = new PriceGate(c);
        policy = new SessionRiskPolicy(gate);
    }

    function test_fork_interfacesMatchTheManifest() public view {
        assertEq(IERC20Metadata(address(tsla)).decimals(), 18);
        assertEq(IERC20Metadata(address(tsla)).symbol(), "TSLA");
        assertEq(IERC20Metadata(address(usdg)).decimals(), 6);
        assertEq(tslaFeed.decimals(), 8);
        assertEq(usdgFeed.decimals(), 8);
        assertEq(tslaFeed.description(), vm.parseJsonString(manifest, ".stockFeed.description"));
        assertEq(usdgFeed.description(), vm.parseJsonString(manifest, ".loanFeed.description"));
        // ERC-8056 getters and the issuer pause flag exist on the mainnet token.
        assertGe(IStockToken(address(tsla)).uiMultiplier(), 1e18);
        IStockToken(address(tsla)).newUIMultiplier();
        IStockToken(address(tsla)).effectiveAt();
        assertFalse(IStockToken(address(tsla)).oraclePaused());
    }

    function test_fork_liveFeedsAreUsableAtThePinnedBlock() public {
        PriceGate.Quote memory q = gate.quote();
        assertEq(q.reasons, 0, "both feeds fresh, in range and unpaused");
        (, int256 tslaUsd,,,) = tslaFeed.latestRoundData();
        (, int256 usdgUsd,,,) = usdgFeed.latestRoundData();
        assertEq(q.priceWad, uint256(tslaUsd) * 1e18 / uint256(usdgUsd), "TSLA per USDG, not per dollar");
        _record(q);
    }

    function test_fork_admissionOnTheLiveRound() public {
        SessionCalendar.Context memory ctx = cal.context(uint64(block.timestamp));
        assertTrue(ctx.inSession, "the pinned block is inside a regular session");
        (,,, uint256 updatedAt,) = tslaFeed.latestRoundData();
        assertGe(updatedAt, ctx.open + 1 minutes, "the live round was published after this session opened");

        gate.refresh();
        assertEq(gate.admissionFor(ctx.index), block.timestamp);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(
            uint256(s.state), uint256(SessionRiskPolicy.State.REOPEN_RECOVERY), "first observation starts recovery"
        );

        vm.warp(block.timestamp + 10 minutes);
        s = policy.snapshot();
        assertTrue(s.state != SessionRiskPolicy.State.REOPEN_RECOVERY && s.state != SessionRiskPolicy.State.GUARDED);
    }

    /// @dev The real tokens through the whole market. A frozen fork publishes no new rounds, so the next
    /// session's opening round is simulated with mockCall (same answer, new timestamp); everything else is live.
    function test_fork_marketWorksWithTheRealTokens() public {
        StockReefMarket market =
            new StockReefMarket(usdg, tsla, policy, 5e6, "StockReef TSLA/USDG lender share", "srUSDG");
        SessionCalendar.Context memory ctx = cal.context(uint64(block.timestamp));

        vm.warp(ctx.nextOpen + 6 minutes);
        _simulateRound(tslaFeed);
        _simulateRound(usdgFeed);
        gate.refresh();
        vm.warp(block.timestamp + 10 minutes);
        _simulateRound(tslaFeed);
        _simulateRound(usdgFeed);
        assertEq(uint256(policy.snapshot().state), uint256(SessionRiskPolicy.State.OPEN));

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        deal(address(usdg), lender, 10_000e6);
        deal(address(tsla), borrower, 10e18);

        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(10_000e6, lender);
        vm.stopPrank();
        assertEq(market.cash(), 10_000e6, "USDG arrived in full");

        vm.startPrank(borrower);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(1e18, borrower);
        assertEq(tsla.balanceOf(address(market)), 1e18, "TSLA arrived in full: no fee, no rebase");
        market.borrow(100e6, borrower);
        usdg.approve(address(market), type(uint256).max);
        deal(address(usdg), borrower, usdg.balanceOf(borrower) + 1e6);
        market.repay(type(uint256).max, borrower);
        market.withdrawCollateral(1e18, borrower);
        vm.stopPrank();
        assertEq(market.debtOf(borrower), 0);
        assertEq(tsla.balanceOf(borrower), 10e18);
    }

    function _simulateRound(IAggregatorV3 feed) internal {
        (uint80 id, int256 answer,,,) = feed.latestRoundData();
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(id + 1, answer, block.timestamp, block.timestamp, id + 1)
        );
    }

    function _record(PriceGate.Quote memory q) internal {
        string memory k = "fork";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "block", vm.getBlockNumber());
        vm.serializeAddress(k, "tsla", address(tsla));
        vm.serializeAddress(k, "usdg", address(usdg));
        vm.serializeAddress(k, "tslaUsdFeed", address(tslaFeed));
        vm.serializeAddress(k, "usdgUsdFeed", address(usdgFeed));
        vm.serializeUint(k, "priceWadTslaPerUsdg", q.priceWad);
        vm.serializeUint(k, "reasons", q.reasons);
        string memory json = vm.serializeUint(k, "secondsSinceTslaRound", block.timestamp - q.updatedAt);
        vm.writeJson(json, "../evidence/fork-4663.json");
    }
}
