// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {DemoClock} from "../../src/clock/DemoClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

/// @notice A 6-decimal loan token that burns 1% of every transfer between two holders.
contract EscrowFeeToken is ERC20 {
    constructor() ERC20("Fee USDG", "fUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Receiver of loan-token hooks.
interface IEscrowTokenHook {
    function onTokenMove(address from, address to, uint256 value) external;
}

/// @notice A 6-decimal loan token that calls registered contracts before they send and after they receive
/// (ERC-777 style hooks on both sides of a move).
contract EscrowHookedUSDG is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hooked USDG", "hUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooked(address account, bool on) external {
        hooked[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && hooked[from]) IEscrowTokenHook(from).onTokenMove(from, to, value);
        super._update(from, to, value);
        if (to != address(0) && hooked[to]) IEscrowTokenHook(to).onTokenMove(from, to, value);
    }
}

/// @notice Plan owner whose token hook re-enters every escrow entry point while the escrow is moving its tokens.
contract EscrowReenterer is IEscrowTokenHook {
    RepaymentEscrow internal immutable escrow;
    IERC20 internal immutable token;
    address internal immutable victim;

    /// @dev Hooks that fired inside an escrow token move.
    uint256 public hookCalls;
    /// @dev Re-entered deposit, withdraw, ownerRepay or executeBuffer calls that succeeded.
    uint256 public fundMoves;
    /// @dev Revert selectors of the re-entered fund-moving calls, all hooks together.
    bytes4[] public errors;

    constructor(RepaymentEscrow escrow_, IERC20 token_, address victim_) {
        escrow = escrow_;
        token = token_;
        victim = victim_;
        token_.approve(address(escrow_), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        escrow.deposit(amount, address(this));
    }

    function withdraw(uint256 amount, address receiver) external {
        escrow.withdraw(amount, receiver);
    }

    function errorCount() external view returns (uint256) {
        return errors.length;
    }

    function onTokenMove(address from, address to, uint256) external {
        if (msg.sender != address(token) || (from != address(escrow) && to != address(escrow))) return;
        hookCalls++;
        try escrow.withdraw(1, address(this)) {
            fundMoves++;
        } catch (bytes memory err) {
            errors.push(bytes4(err));
        }
        try escrow.deposit(1, address(this)) {
            fundMoves++;
        } catch (bytes memory err) {
            errors.push(bytes4(err));
        }
        try escrow.ownerRepay(1) {
            fundMoves++;
        } catch (bytes memory err) {
            errors.push(bytes4(err));
        }
        try escrow.executeBuffer(victim) {
            fundMoves++;
        } catch (bytes memory err) {
            errors.push(bytes4(err));
        }
        // authorize and cancel move no tokens; whatever they do here applies to this contract's own plan.
        try escrow.authorize(0.65e18, type(uint256).max, type(uint64).max) {} catch {}
        try escrow.cancel() {} catch {}
    }
}

/// @notice Stand-in market with only the functions the escrow calls. During `repay` it records what the escrow
/// had already written and approved, and it can take less than asked to model a market that pays short.
contract EscrowProbeMarket {
    IERC20 internal immutable token;
    uint256 public debt;
    uint256 public collateral;
    uint256 public minLoan;
    uint256 public shortBy;
    uint256 public seenAllowance;
    uint256 public seenBalance;
    uint256 public seenSpent;

    constructor(IERC20 token_, uint256 debt_, uint256 collateral_, uint256 minLoan_) {
        token = token_;
        debt = debt_;
        collateral = collateral_;
        minLoan = minLoan_;
    }

    function setShortBy(uint256 units) external {
        shortBy = units;
    }

    function debtOf(address) external view returns (uint256) {
        return debt;
    }

    function collateralOf(address) external view returns (uint256) {
        return collateral;
    }

    function accountOf(address) external view returns (uint256, uint256, uint256) {
        return (collateral, debt * 1e18, debt);
    }

    function repay(uint256 amount, address account) external returns (uint256 paid) {
        seenAllowance = token.allowance(msg.sender, address(this));
        RepaymentEscrow.Plan memory p = RepaymentEscrow(msg.sender).planOf(account);
        seenBalance = p.balance;
        seenSpent = p.spent;
        paid = amount - shortBy;
        token.transferFrom(msg.sender, address(this), paid);
        debt -= paid;
    }
}

contract RepaymentEscrowTest is MarketFixture {
    uint256 internal constant WAD = 1e18;

    address internal keeper = makeAddr("keeper");
    address internal mallory = makeAddr("mallory");
    address internal friend = makeAddr("friend");

    function setUp() public {
        _setUpMarket();
        _openFriday();
        _lend(100_000 * USDG);
    }

    /// @dev Alice: the worked example plus a funded, authorized buffer.
    function _aliceWithBuffer(uint256 funded, uint256 cap) internal {
        _workedExample(alice);
        usdg.mint(alice, funded);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(funded, alice);
        escrow.authorize(0.65e18, cap, uint64(MON_CLOSE));
        vm.stopPrank();
    }

    /// @dev Mint `amount` to `who` and deposit it into `who`'s own plan of escrow `e`.
    function _fundIn(RepaymentEscrow e, address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(e), type(uint256).max);
        e.deposit(amount, who);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        _fundIn(escrow, who, amount);
    }

    /// @dev Bob: a funded, active plan without debt, for the amount rules with chosen debt and value.
    function _bobPlan(uint256 funded, uint256 targetWad, uint256 cap) internal {
        _fund(bob, funded);
        vm.prank(bob);
        escrow.authorize(targetWad, cap, uint64(MON_CLOSE));
    }

    function _valueOf(address who, SessionRiskPolicy.Snapshot memory s) internal view returns (uint256) {
        return gate.valueOf(market.collateralOf(who), s.priceWad);
    }

    function _need(uint256 debt, uint256 value, uint256 target) internal pure returns (uint256) {
        if (debt * WAD <= target * value) return 0;
        return Math.ceilDiv(debt * WAD - target * value, WAD);
    }

    /// @dev The commitment rule written out: an active plan, debt, and a schedule phase other than OPEN outside
    /// wind-down.
    function _expectedCommitted(address who) internal view returns (bool) {
        RepaymentEscrow.Plan memory p = escrow.planOf(who);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        bool active = p.targetWad != 0 && s.time < p.expiry;
        return active && market.debtOf(who) != 0 && s.phase != SessionRiskPolicy.State.OPEN && !s.windDown;
    }

    function _assertSamePlan(RepaymentEscrow.Plan memory a, RepaymentEscrow.Plan memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "plan changed");
    }

    // ------------------------------------------------------------ wiring

    /// INV-X-01, INV-X-08
    function test_wiring_escrowSharesTheMarketsGatePolicyClockAndToken() public {
        assertEq(address(escrow.market()), address(market));
        assertEq(address(escrow.loanToken()), market.asset());
        assertEq(address(escrow.loanToken()), address(gate.loanToken()));
        assertEq(address(escrow.gate()), address(market.gate()));
        assertEq(address(escrow.gate()), address(policy.gate()));
        assertEq(address(escrow.policy()), address(market.policy()));
        assertEq(address(escrow.clock()), address(market.clock()));
        assertEq(address(escrow.clock()), address(gate.clock()));
        assertEq(address(escrow.clock()), address(policy.clock()));
        // No plan may target above the deepest closure target, or reach any threshold.
        assertLe(escrow.MAX_TARGET(), policy.TARGET_EXTENDED());
        assertLe(escrow.MAX_TARGET(), policy.TARGET_OVERNIGHT());
        assertLt(escrow.MAX_TARGET(), policy.LT_FINAL_EXTENDED());

        // A market for another loan token than its gate prices cannot be built, so neither can its escrow.
        MockUSDG other = new MockUSDG();
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(other, tsla, policy, MIN_LOAN, "x", "x");
    }

    // ------------------------------------------------------------ deposit

    /// INV-ESC-19, INV-X-20; kills M02 (deposit credits the payer instead of the named account)
    function test_deposit_creditsTheNamedAccountNotThePayer() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        assertTrue(escrow.committed(alice));
        RepaymentEscrow.Plan memory before = escrow.planOf(alice);

        usdg.mint(mallory, 100 * USDG);
        vm.startPrank(mallory);
        usdg.approve(address(escrow), 100 * USDG);
        vm.expectEmit(address(escrow));
        emit RepaymentEscrow.Deposited(alice, mallory, 100 * USDG);
        escrow.deposit(100 * USDG, alice);
        vm.stopPrank();

        RepaymentEscrow.Plan memory p = escrow.planOf(alice);
        assertEq(p.balance, before.balance + 100 * USDG, "credited to the named account");
        assertEq(escrow.planOf(mallory).balance, 0, "the payer is credited nothing");
        assertEq(usdg.balanceOf(mallory), 0, "pulled from the payer");
        assertEq(usdg.balanceOf(address(escrow)), 1_100 * USDG);
        assertEq(p.targetWad, before.targetWad);
        assertEq(p.perSessionCap, before.perSessionCap);
        assertEq(p.expiry, before.expiry);
        assertEq(p.spent, before.spent);
        assertEq(p.spentSession, before.spentSession);
        assertTrue(escrow.committed(alice), "commitment unchanged");

        // A deposit for an account without a plan authorizes nothing.
        usdg.mint(mallory, 5 * USDG);
        vm.startPrank(mallory);
        usdg.approve(address(escrow), 5 * USDG);
        escrow.deposit(5 * USDG, carol);
        vm.stopPrank();
        assertEq(escrow.planOf(carol).balance, 5 * USDG);
        assertEq(escrow.planOf(carol).targetWad, 0);
        assertEq(escrow.planOf(carol).expiry, 0);
    }

    /// INV-ESC-19; kills M34 (zero deposits accepted)
    function test_deposit_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.ZeroAmount.selector);
        escrow.deposit(0, alice);
    }

    /// INV-X-19, INV-ESC-19; kills M01 (the exact-arrival check on deposit)
    function test_deposit_rejectsAFeeOnTransferLoanToken() public {
        EscrowFeeToken fee = new EscrowFeeToken();
        PriceGate.Config memory c = _config();
        c.loanToken = address(fee);
        PriceGate feeGate = new PriceGate(c);
        StockReefMarket feeMarket = new StockReefMarket(fee, tsla, new SessionRiskPolicy(feeGate), MIN_LOAN, "f", "f");
        RepaymentEscrow feeEscrow = feeMarket.escrow();

        fee.mint(alice, 100 * USDG);
        vm.startPrank(alice);
        fee.approve(address(feeEscrow), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.UnsupportedTransfer.selector, 100 * USDG, 99 * USDG));
        feeEscrow.deposit(100 * USDG, alice);
        vm.stopPrank();
        assertEq(feeEscrow.planOf(alice).balance, 0);
        assertEq(fee.balanceOf(address(feeEscrow)), 0);
    }

    /// INV-ESC-19, INV-ESC-06, INV-X-11, INV-X-13
    function test_deposit_worksInEveryStateAndPullsOnlyFromTheCaller() public {
        _workedExample(alice);
        usdg.mint(alice, 1_000 * USDG);
        vm.prank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        uint256 wallet = usdg.balanceOf(alice);

        // Alice's approval cannot be spent by anyone else: a deposit pulls from its caller.
        vm.prank(mallory);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        escrow.deposit(1 * USDG, alice);

        usdg.mint(mallory, 10 * USDG);
        vm.prank(mallory);
        usdg.approve(address(escrow), type(uint256).max);
        uint64[5] memory times = [
            uint64(FRI_CLOSE - 100 minutes), // PRE_CLOSE with a stale price: GUARDED
            FRI_CLOSE + 1 hours, // CLOSED
            MON_OPEN + 1 minutes, // REOPEN_WAIT, nothing admitted
            MON_OPEN + 3 hours, // REOPEN_WAIT past O + 30 min: GUARDED
            cal.lastOpen() + 1 hours // wind-down
        ];
        vm.prank(mallory);
        escrow.deposit(1 * USDG, alice); // OPEN
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            if (i == 3) {
                vm.prank(guardian);
                gate.stop();
            }
            vm.prank(mallory);
            escrow.deposit(1 * USDG, alice);
        }
        assertEq(escrow.planOf(alice).balance, 6 * USDG);
        assertEq(usdg.balanceOf(mallory), 4 * USDG);
        assertEq(usdg.balanceOf(alice), wallet, "the named account's wallet is never pulled");
    }

    // ------------------------------------------------------------ withdraw

    /// INV-ESC-03, INV-ESC-04; kills M11 (withdraw pays the caller instead of the receiver)
    function test_withdraw_paysTheChosenReceiverAndDebitsOnlyTheCaller() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _fund(bob, 50 * USDG);
        uint256 wallet = usdg.balanceOf(alice);

        vm.expectEmit(address(escrow));
        emit RepaymentEscrow.Withdrawn(alice, 300 * USDG);
        vm.prank(alice);
        escrow.withdraw(300 * USDG, friend);

        assertEq(usdg.balanceOf(friend), 300 * USDG, "the receiver is paid");
        assertEq(usdg.balanceOf(alice), wallet, "nothing goes to the caller");
        assertEq(escrow.planOf(alice).balance, 700 * USDG);
        assertEq(escrow.planOf(bob).balance, 50 * USDG);
        assertEq(escrow.planOf(friend).balance, 0);
        assertEq(usdg.balanceOf(address(escrow)), 750 * USDG);
    }

    /// INV-ESC-04, INV-ESC-08
    function test_withdraw_revertPaths() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.ZeroAmount.selector);
        escrow.withdraw(0, alice);
        vm.expectRevert(
            abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 1_000 * USDG + 1, 1_000 * USDG)
        );
        escrow.withdraw(1_000 * USDG + 1, alice);
        vm.stopPrank();

        // A stranger reaches only its own plan, never the pooled tokens.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 1, 0));
        escrow.withdraw(1, mallory);
        _fund(mallory, 10 * USDG);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 11 * USDG, 10 * USDG));
        escrow.withdraw(11 * USDG, mallory);
        vm.prank(mallory);
        escrow.withdraw(10 * USDG, mallory);
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG);

        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.withdraw(1, alice);
    }

    /// INV-ESC-03, INV-ESC-04, INV-ESC-05, INV-ESC-17
    function test_ownerOnly_strangersActOnlyOnTheirOwnPlan() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        RepaymentEscrow.Plan memory alicePlan = escrow.planOf(alice);
        _fundCollateral(mallory, 25 * TOKEN);
        _borrow(mallory, 7_000 * USDG);

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 1, 0));
        escrow.withdraw(1, mallory);
        vm.expectRevert();
        escrow.ownerRepay(1); // her own empty plan cannot repay even her own debt
        escrow.cancel();
        escrow.authorize(0.5e18, 1_000 * USDG, uint64(MON_CLOSE));
        vm.stopPrank();
        _assertSamePlan(escrow.planOf(alice), alicePlan);
        assertEq(escrow.planOf(mallory).targetWad, 0.5e18, "the stranger wrote its own plan");

        _tick(FRI_CLOSE - 60 minutes);
        uint256 malloryDebt = market.debtOf(mallory);
        uint256 malloryWallet = usdg.balanceOf(mallory);
        vm.prank(mallory);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(mallory); // her plan holds nothing; alice's funds are out of reach

        vm.prank(mallory);
        uint256 repaid = escrow.executeBuffer(alice);
        assertGt(repaid, 0);
        assertEq(market.debtOf(mallory), malloryDebt, "only the named account's debt falls");
        assertEq(usdg.balanceOf(mallory), malloryWallet, "the caller is paid nothing");
        assertEq(escrow.planOf(mallory).balance, 0);
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG - repaid);
    }

    /// INV-ESC-01, INV-ESC-03
    function test_surplus_donationsAndUnclaimableCreditsAreNeverSpendable() public {
        _fund(alice, 100 * USDG);
        usdg.mint(mallory, 100 * USDG);
        vm.startPrank(mallory);
        usdg.transfer(address(escrow), 40 * USDG); // a direct transfer is credited to no plan
        usdg.approve(address(escrow), type(uint256).max);
        address[3] memory sinks = [address(0), address(escrow), address(market)];
        uint256 locked;
        for (uint256 i; i < sinks.length; ++i) {
            // Credits to addresses that can never call the escrow, where accepted, stay locked.
            try escrow.deposit(10 * USDG, sinks[i]) {
                locked += 10 * USDG;
            } catch {}
        }
        vm.stopPrank();

        uint256 sum = escrow.planOf(alice).balance;
        for (uint256 i; i < sinks.length; ++i) {
            sum += escrow.planOf(sinks[i]).balance;
        }
        assertEq(sum, 100 * USDG + locked);
        assertEq(usdg.balanceOf(address(escrow)), sum + 40 * USDG, "the donation is surplus");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 1, 0));
        escrow.withdraw(1, mallory);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RepaymentEscrow.InsufficientBalance.selector, 100 * USDG + 1, 100 * USDG)
        );
        escrow.withdraw(100 * USDG + 1, alice);
        vm.prank(alice);
        escrow.withdraw(100 * USDG, alice);
        assertEq(usdg.balanceOf(address(escrow)), locked + 40 * USDG, "surplus and locked credits remain");
    }

    // ------------------------------------------------------------ authorization

    function test_authorize_rejectsTargetsAboveTheDeepestPlan() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.TargetTooHigh.selector, 0.65e18 + 1, 0.65e18));
        escrow.authorize(0.65e18 + 1, 1_000 * USDG, uint64(MON_CLOSE));
    }

    function test_authorize_rejectsExpiredOrEmptyPlans() public {
        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0.65e18, 1_000 * USDG, uint64(block.timestamp));
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0.65e18, 0, uint64(MON_CLOSE));
        vm.stopPrank();
    }

    /// INV-ESC-07
    function test_authorize_acceptsTheBoundaryValuesAndWritesOnlyTheCallersPlan() public {
        _fund(bob, 10 * USDG);
        vm.prank(bob);
        escrow.authorize(0.5e18, 7, uint64(MON_CLOSE));
        RepaymentEscrow.Plan memory bobPlan = escrow.planOf(bob);

        uint256 maxTarget = escrow.MAX_TARGET();
        uint64 next = uint64(block.timestamp + 1);
        vm.expectEmit(address(escrow));
        emit RepaymentEscrow.Authorized(alice, maxTarget, 1, next);
        vm.prank(alice);
        escrow.authorize(maxTarget, 1, next);

        RepaymentEscrow.Plan memory p = escrow.planOf(alice);
        assertEq(p.targetWad, maxTarget);
        assertEq(p.perSessionCap, 1);
        assertEq(p.expiry, next);
        assertEq(p.balance, 0, "authorization needs no balance and adds none");
        assertEq(p.spent, 0);
        _assertSamePlan(escrow.planOf(bob), bobPlan);

        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0, 1, next);
        vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        escrow.authorize(0.5e18, 1, uint64(block.timestamp - 1));
        // The target check comes first.
        vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.TargetTooHigh.selector, maxTarget + 1, maxTarget));
        escrow.authorize(maxTarget + 1, 0, 0);
        vm.stopPrank();
        assertEq(escrow.planOf(alice).expiry, next, "rejected calls write nothing");
    }

    /// INV-ESC-07, INV-X-20
    function testFuzz_authorize_validatesAndWritesOnlyTheCallersPlan(uint256 target, uint256 cap, uint256 expiry)
        public
    {
        target = bound(target, 0, 0.66e18);
        cap = bound(cap, 0, 1_000 * USDG);
        uint64 nowT = uint64(block.timestamp);
        uint64 exp = uint64(bound(expiry, nowT - 1 days, nowT + 10 days));
        _fund(bob, 10 * USDG);
        vm.prank(bob);
        escrow.authorize(0.5e18, 7, uint64(MON_CLOSE));
        RepaymentEscrow.Plan memory bobPlan = escrow.planOf(bob);
        _fund(alice, 3 * USDG);

        bool valid = target != 0 && target <= escrow.MAX_TARGET() && cap != 0 && exp > nowT;
        if (target > escrow.MAX_TARGET()) {
            vm.expectRevert(abi.encodeWithSelector(RepaymentEscrow.TargetTooHigh.selector, target, 0.65e18));
        } else if (!valid) {
            vm.expectRevert(RepaymentEscrow.BadAuthorization.selector);
        }
        vm.prank(alice);
        escrow.authorize(target, cap, exp);

        RepaymentEscrow.Plan memory p = escrow.planOf(alice);
        assertEq(p.targetWad, valid ? target : 0);
        assertEq(p.perSessionCap, valid ? cap : 0);
        assertEq(p.expiry, valid ? exp : 0);
        assertEq(p.balance, 3 * USDG);
        assertEq(p.spent, 0);
        _assertSamePlan(escrow.planOf(bob), bobPlan);
    }

    /// INV-ESC-08; kills M06 (re-authorizing while committed)
    function test_authorize_revertsWhileCommitted() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        assertTrue(escrow.committed(alice));
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.authorize(0.65e18, 100 * USDG, uint64(block.timestamp + 1));
        assertEq(escrow.planOf(alice).expiry, MON_CLOSE, "a committed plan cannot be shortened");
        assertTrue(escrow.committed(alice));
    }

    /// INV-ESC-20, INV-X-17
    function test_authorize_letsAnIndebtedAccountCommitItself() public {
        // In CLOSED: no plan, so the funds are free; authorizing commits them at once.
        _workedExample(alice);
        _fund(alice, 500 * USDG);
        _tick(FRI_CLOSE + 1 hours);
        assertFalse(escrow.committed(alice));
        vm.prank(alice);
        escrow.withdraw(100 * USDG, alice);
        vm.prank(alice);
        escrow.authorize(0.65e18, 100 * USDG, uint64(MON_CLOSE));
        assertTrue(escrow.committed(alice));
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.withdraw(1, alice);

        // In PRE_CLOSE: authorizing blocks the borrower's own further borrowing.
        _tick(MON_OPEN + 5 minutes);
        _tick(MON_OPEN + 15 minutes);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 2_000 * USDG);
        _tick(MON_CLOSE - 100 minutes);
        _borrow(bob, 100 * USDG);
        vm.prank(bob);
        escrow.authorize(0.5e18, 100 * USDG, uint64(TUE_OPEN));
        vm.prank(bob);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.borrow(100 * USDG, bob);
    }

    /// INV-ESC-07, INV-ESC-13; kills M08 (cancel keeps the target)
    function test_cancel_clearsTheAuthorizationButKeepsBalanceAndSpend() public {
        _aliceWithBuffer(1_000 * USDG, 200 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);
        _tick(MON_OPEN + 5 minutes);
        _tick(MON_OPEN + 15 minutes); // a full reopening releases the plan
        assertFalse(escrow.committed(alice));
        RepaymentEscrow.Plan memory before = escrow.planOf(alice);

        vm.expectEmit(address(escrow));
        emit RepaymentEscrow.Cancelled(alice);
        vm.prank(alice);
        escrow.cancel();

        RepaymentEscrow.Plan memory p = escrow.planOf(alice);
        assertEq(p.targetWad, 0);
        assertEq(p.perSessionCap, 0);
        assertEq(p.expiry, 0);
        assertEq(p.balance, before.balance);
        assertEq(p.spent, 200 * USDG);
        assertEq(p.spentSession, before.spentSession);

        _tick(MON_CLOSE - 120 minutes);
        assertFalse(escrow.committed(alice));
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NotAuthorized.selector);
        escrow.executeBuffer(alice);
    }

    /// INV-ESC-07, INV-ESC-09, INV-X-17; kills M24 (authorization still active at its expiry)
    function test_authorization_endsExactlyAtExpiry() public {
        _workedExample(alice);
        _fund(alice, 1_000 * USDG);
        uint64 expiry = FRI_CLOSE - 60 minutes;
        vm.prank(alice);
        escrow.authorize(0.65e18, 1_000 * USDG, expiry);

        SessionRiskPolicy.Snapshot memory s = _tick(expiry - 1);
        uint256 debt = market.debtOf(alice);
        assertTrue(escrow.committed(alice), "active one second before expiry");
        assertTrue(escrow.blocksBorrowing(alice, s));
        assertGt(escrow.executableAmount(alice, s, debt, _valueOf(alice, s)), 0);

        s = _tick(expiry);
        debt = market.debtOf(alice);
        assertFalse(escrow.committed(alice), "ended at expiry");
        assertFalse(escrow.blocksBorrowing(alice, s));
        assertEq(escrow.executableAmount(alice, s, debt, _valueOf(alice, s)), 0);
        assertFalse(escrow.executable(alice, s, debt, _valueOf(alice, s)));
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NotAuthorized.selector);
        escrow.executeBuffer(alice);
        vm.prank(alice);
        escrow.withdraw(1_000 * USDG, alice);
    }

    /// INV-X-17
    function test_activePlan_blocksBorrowingFromAOnlyUntilItsExpiry() public {
        _fundCollateral(alice, 25 * TOKEN);
        _borrow(alice, 2_000 * USDG);
        uint64 expiry = FRI_CLOSE - 90 minutes; // A + 30 min, before F
        vm.prank(alice);
        escrow.authorize(0.65e18, 100 * USDG, expiry);

        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 120 minutes - 1);
        assertFalse(escrow.blocksBorrowing(alice, s), "OPEN: an active plan does not block");
        _borrow(alice, 100 * USDG);

        s = _tick(FRI_CLOSE - 120 minutes);
        assertTrue(escrow.blocksBorrowing(alice, s));
        vm.startPrank(alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.borrow(100 * USDG, alice);
        vm.expectRevert(StockReefMarket.BufferAuthorizationActive.selector);
        market.withdrawCollateral(1 * TOKEN, alice);
        vm.stopPrank();

        s = _tick(expiry);
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.PRE_CLOSE));
        assertFalse(escrow.blocksBorrowing(alice, s), "the borrower's own expiry ends the block");
        _borrow(alice, 100 * USDG);
        vm.prank(alice);
        market.withdrawCollateral(1 * TOKEN, alice);
    }

    // ------------------------------------------------------------ ownerRepay

    /// INV-ESC-18; kills M12 (ownerRepay without the balance check)
    function test_ownerRepay_revertPaths() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.prank(alice);
        vm.expectRevert(RepaymentEscrow.ZeroAmount.selector);
        escrow.ownerRepay(0);

        _fund(carol, 10 * USDG); // no debt
        vm.prank(carol);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.ownerRepay(10 * USDG);

        // `amount` is a cap (appendix R16): above the balance it spends the balance, never more.
        uint256 debt = market.debtOf(alice);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(1_000 * USDG + 1), 1_000 * USDG);
        assertEq(escrow.planOf(alice).balance, 0);
        assertApproxEqAbs(market.debtOf(alice), debt - 1_000 * USDG, 1);

        // A cap that would leave non-zero debt below the minimum loan stops at the minimum instead.
        _fundCollateral(bob, 0.025e18);
        _borrow(bob, 7 * USDG);
        _fund(bob, 10 * USDG);
        uint256 bobDebt = market.debtOf(bob);
        vm.prank(bob);
        assertEq(escrow.ownerRepay(3 * USDG), bobDebt - MIN_LOAN);
        assertEq(escrow.planOf(bob).balance, 10 * USDG - (bobDebt - MIN_LOAN));

        // At the minimum, only clearing the whole debt is possible.
        vm.prank(bob);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.ownerRepay(1 * USDG);
    }

    /// INV-ESC-18, INV-ESC-21
    function test_ownerRepay_repaysAtMostTheDebtAndKeepsTheRest() public {
        _workedExample(alice);
        _fund(alice, 10_000 * USDG);
        uint256 debt = market.debtOf(alice);
        uint256 cash = market.cash();

        vm.expectEmit(address(escrow));
        emit RepaymentEscrow.OwnerRepaid(alice, debt);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(9_000 * USDG), debt);

        assertEq(market.debtOf(alice), 0);
        assertEq(escrow.planOf(alice).balance, 10_000 * USDG - debt, "the rest stays in escrow");
        assertEq(market.cash(), cash + debt);
        assertEq(usdg.balanceOf(address(escrow)), 10_000 * USDG - debt);
        assertEq(usdg.allowance(address(escrow), address(market)), 0);
    }

    /// INV-ESC-18, INV-X-11, INV-X-13
    function test_ownerRepay_worksInEveryStateWithoutAuthorization() public {
        _workedExample(alice);
        _fund(alice, 1_000 * USDG);
        uint64[5] memory times = [
            uint64(FRI_CLOSE - 100 minutes), // PRE_CLOSE with a stale price: GUARDED
            FRI_CLOSE + 1 hours, // CLOSED
            MON_OPEN + 1 minutes, // REOPEN_WAIT
            MON_OPEN + 3 hours, // stopped by the guardian
            cal.lastOpen() + 1 hours // wind-down
        ];
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG); // OPEN
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            if (i == 3) {
                vm.prank(guardian);
                gate.stop();
            }
            vm.prank(alice);
            assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);
        }
        assertEq(escrow.planOf(alice).balance, 400 * USDG);
        assertEq(escrow.planOf(alice).spent, 0, "ownerRepay is not a buffer spend");
    }

    /// INV-ESC-13, INV-ESC-18
    function test_ownerRepay_doesNotCountAgainstTheSessionAllowance() public {
        _aliceWithBuffer(1_000 * USDG, 200 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(alice);
        escrow.ownerRepay(300 * USDG);
        assertEq(escrow.planOf(alice).spent, 0);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG, "the whole cap is still available");
        assertEq(escrow.planOf(alice).spent, 200 * USDG);
    }

    /// INV-ESC-05, INV-X-20
    function test_ownerRepay_cutsOnlyTheCallersDebt() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 7_000 * USDG);
        _fund(bob, 500 * USDG);
        uint256 aliceDebt = market.debtOf(alice);
        uint256 bobDebt = market.debtOf(bob);
        RepaymentEscrow.Plan memory alicePlan = escrow.planOf(alice);

        vm.prank(bob);
        escrow.ownerRepay(500 * USDG);
        assertEq(market.debtOf(alice), aliceDebt);
        _assertSamePlan(escrow.planOf(alice), alicePlan);
        assertGe(market.debtOf(bob), bobDebt - 500 * USDG);
        assertLe(market.debtOf(bob), bobDebt - 500 * USDG + 1, "exactly the amount, within share rounding");
        assertEq(escrow.planOf(bob).balance, 0);
    }

    // ------------------------------------------------------------ execution

    function test_execute_repaysExactlyToTheTargetWithoutAReward() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        uint256 keeperBefore = usdg.balanceOf(keeper);

        vm.prank(keeper);
        uint256 repaid = escrow.executeBuffer(alice);

        // Worked example: 700 USDG to reach 65%, plus the interest accrued since borrowing.
        assertApproxEqAbs(repaid, _golden(".worked_example.cash_required_usdg"), 1 * USDG);
        assertEq(repaid, debt - 6_500 * USDG);
        assertApproxEqAbs(market.debtOf(alice), 6_500 * USDG, 1, "65% within share rounding");
        assertEq(market.collateralOf(alice), 25 * TOKEN, "collateral untouched");
        assertEq(usdg.balanceOf(keeper), keeperBefore, "no reward");
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG - repaid);
    }

    function test_execute_onlyDuringPreparationWithAValidPrice() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice); // OPEN

        _tick(FRI_CLOSE - 60 minutes);
        vm.warp(block.timestamp + MOCK_MAX_AGE + 1); // stale
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);

        _tick(FRI_CLOSE);
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice); // CLOSED
    }

    function test_execute_isCappedByBalanceAndSessionAllowance() public {
        _aliceWithBuffer(300 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 300 * USDG, "balance cap");
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(alice);
    }

    function test_execute_sessionCapResetsNextSession() public {
        _aliceWithBuffer(1_000 * USDG, 200 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(alice);

        // Monday: a new session and a new allowance (Monday's close is OVERNIGHT, still above 65%).
        _tick(MON_OPEN + 5 minutes);
        _tick(MON_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);
    }

    /// INV-ESC-13; kills M16 (the spend record is not reset in a new session)
    function test_execute_allowanceRestartsFromZeroInEachSession() public {
        _aliceWithBuffer(1_000 * USDG, 200 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);

        _tick(MON_OPEN + 5 minutes);
        _tick(MON_OPEN + 15 minutes);
        vm.prank(alice);
        escrow.withdraw(750 * USDG, alice); // 50 left

        _tick(MON_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 50 * USDG, "limited by the balance");
        assertEq(escrow.planOf(alice).spent, 50 * USDG, "Monday's record starts from zero");
        usdg.mint(alice, 500 * USDG);
        vm.prank(alice);
        escrow.deposit(500 * USDG, alice);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 150 * USDG, "the rest of Monday's allowance");
        assertEq(escrow.planOf(alice).spent, 200 * USDG);
    }

    /// INV-ESC-13
    function test_execute_reauthorizingCannotResetTheSessionAllowance() public {
        _workedExample(alice);
        _fund(alice, 1_000 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, 200 * USDG, uint64(FRI_CLOSE - 100 minutes));
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 200 * USDG);

        _tick(FRI_CLOSE - 99 minutes); // expired, so released: the owner may cancel and authorize again
        assertFalse(escrow.committed(alice));
        vm.startPrank(alice);
        escrow.cancel();
        escrow.authorize(0.65e18, 300 * USDG, uint64(MON_CLOSE));
        vm.stopPrank();
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 100 * USDG, "only the cap left after this session's spend");
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NothingToRepay.selector);
        escrow.executeBuffer(alice);
    }

    /// INV-ESC-05, INV-ESC-17, INV-X-20
    function test_execute_cutsOnlyTheNamedDebtAndPaysTheCallerNothing() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _fundCollateral(bob, 25 * TOKEN);
        _borrow(bob, 7_000 * USDG);
        _fund(bob, 800 * USDG);
        vm.prank(bob);
        escrow.authorize(0.6e18, 800 * USDG, uint64(MON_CLOSE));
        _tick(FRI_CLOSE - 120 minutes);

        uint256 aliceDebt = market.debtOf(alice);
        uint256 bobDebt = market.debtOf(bob);
        uint256 bobWallet = usdg.balanceOf(bob);
        RepaymentEscrow.Plan memory bobPlan = escrow.planOf(bob);
        uint256 cash = market.cash();
        uint256 held = usdg.balanceOf(address(escrow));

        vm.prank(bob);
        uint256 repaid = escrow.executeBuffer(alice);
        assertGt(repaid, 0);
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG - repaid);
        assertGe(market.debtOf(alice) + repaid, aliceDebt);
        assertLe(market.debtOf(alice) + repaid, aliceDebt + 1, "exactly the amount taken, within share rounding");
        assertEq(market.debtOf(bob), bobDebt, "the caller's debt is untouched");
        _assertSamePlan(escrow.planOf(bob), bobPlan);
        assertEq(usdg.balanceOf(bob), bobWallet, "the caller is paid nothing");
        assertEq(market.cash(), cash + repaid);
        assertEq(usdg.balanceOf(address(escrow)), held - repaid);
        assertEq(market.collateralOf(alice), 25 * TOKEN);
    }

    /// INV-ESC-06
    function test_execute_neverPullsFromTheBorrowersWalletAndLeavesNoApproval() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG); // alice also approved the escrow without limit
        usdg.mint(alice, 5_000 * USDG);
        uint256 wallet = usdg.balanceOf(alice);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 120 minutes);
        uint256 amount = escrow.executableAmount(alice, s, market.debtOf(alice), _valueOf(alice, s));
        assertGt(amount, 0);

        vm.expectCall(address(usdg), abi.encodeCall(IERC20.approve, (address(market), amount)));
        vm.expectCall(address(usdg), abi.encodeCall(IERC20.approve, (address(market), 0)));
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), amount);
        assertEq(usdg.balanceOf(alice), wallet, "the borrower's wallet is never pulled");
        assertEq(usdg.allowance(address(escrow), address(market)), 0);

        vm.prank(alice);
        escrow.ownerRepay(100 * USDG);
        assertEq(usdg.balanceOf(alice), wallet);
        assertEq(usdg.allowance(address(escrow), address(market)), 0);
    }

    /// INV-ESC-06, INV-ESC-16
    function test_repay_effectsPrecedeTheMarketCallWithAnExactApproval() public {
        EscrowProbeMarket probe = new EscrowProbeMarket(usdg, 1_000 * USDG, 1 * TOKEN, MIN_LOAN);
        RepaymentEscrow probed = new RepaymentEscrow(StockReefMarket(address(probe)), usdg, policy);
        _fundIn(probed, alice, 500 * USDG);

        vm.prank(alice);
        assertEq(probed.ownerRepay(200 * USDG), 200 * USDG);
        assertEq(probe.seenBalance(), 300 * USDG, "balance debited before the market call");
        assertEq(probe.seenAllowance(), 200 * USDG, "approval of exactly the amount");
        assertEq(usdg.allowance(address(probed), address(probe)), 0, "approval reset afterwards");
        assertEq(usdg.balanceOf(address(probe)), 200 * USDG);

        // Debt 800 on 400 of value at a 50% target needs 600; the cap allows 150.
        vm.prank(alice);
        probed.authorize(0.5e18, 150 * USDG, uint64(MON_CLOSE));
        _tick(FRI_CLOSE - 60 minutes);
        vm.prank(keeper);
        assertEq(probed.executeBuffer(alice), 150 * USDG);
        assertEq(probe.seenBalance(), 150 * USDG);
        assertEq(probe.seenSpent(), 150 * USDG, "spend recorded before the market call");
        assertEq(probe.seenAllowance(), 150 * USDG);
        assertEq(usdg.allowance(address(probed), address(probe)), 0);
        assertEq(usdg.balanceOf(address(probed)), 150 * USDG);
    }

    /// INV-ESC-16
    function test_repay_revertsWhenTheMarketTakesADifferentAmount() public {
        EscrowProbeMarket probe = new EscrowProbeMarket(usdg, 1_000 * USDG, 1 * TOKEN, MIN_LOAN);
        RepaymentEscrow probed = new RepaymentEscrow(StockReefMarket(address(probe)), usdg, policy);
        _fundIn(probed, alice, 500 * USDG);
        vm.prank(alice);
        probed.authorize(0.5e18, 150 * USDG, uint64(MON_CLOSE));
        probe.setShortBy(1);

        vm.prank(alice);
        vm.expectRevert();
        probed.ownerRepay(200 * USDG);

        _tick(FRI_CLOSE - 60 minutes);
        vm.prank(keeper);
        vm.expectRevert();
        probed.executeBuffer(alice);

        RepaymentEscrow.Plan memory p = probed.planOf(alice);
        assertEq(p.balance, 500 * USDG, "nothing debited");
        assertEq(p.spent, 0);
        assertEq(usdg.balanceOf(address(probe)), 0);
        assertEq(usdg.allowance(address(probed), address(probe)), 0);
    }

    function test_execute_requiresAnActiveAuthorization() public {
        _workedExample(alice);
        usdg.mint(alice, 1_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        vm.stopPrank();
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        vm.expectRevert(RepaymentEscrow.NotAuthorized.selector);
        escrow.executeBuffer(alice);
    }

    function test_execute_frozenTransferRevertsAndPreservesBalances() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        usdg.setFrozen(address(escrow), true);
        vm.prank(keeper);
        vm.expectPartialRevert(MockUSDG.AccountFrozen.selector);
        escrow.executeBuffer(alice);
        assertEq(escrow.planOf(alice).balance, 1_000 * USDG);
        assertEq(market.debtOf(alice), debt);
    }

    function test_execute_neverLeavesDustBelowTheMinimum() public {
        // A small loan whose 65% target sits just above zero debt after the buffer: 8 USDG on 0.025 TSLA.
        _fundCollateral(bob, 0.025e18); // 10 USDG of collateral
        _borrow(bob, 7 * USDG);
        usdg.mint(bob, 100 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(100 * USDG, bob);
        escrow.authorize(0.1e18, 100 * USDG, uint64(MON_CLOSE)); // target 10%: would leave about 1 USDG
        vm.stopPrank();

        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        uint256 repaid = escrow.executeBuffer(bob);
        assertEq(market.debtOf(bob), 0, "repaid in full rather than leaving dust");
        assertGt(repaid, 7 * USDG - 1);
    }

    function test_execute_stopsAtTheMinimumWhenFundsAreShort() public {
        _fundCollateral(bob, 0.025e18);
        _borrow(bob, 7 * USDG);
        usdg.mint(bob, 5 * USDG);
        vm.startPrank(bob);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(5 * USDG, bob);
        escrow.authorize(0.1e18, 100 * USDG, uint64(MON_CLOSE));
        vm.stopPrank();

        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        escrow.executeBuffer(bob);
        assertApproxEqAbs(market.debtOf(bob), MIN_LOAN, 1, "stops at the minimum loan");
    }

    /// INV-ESC-11, INV-X-15; kills M23 (executable ignores canBuffer)
    function test_executable_isFalseOutsideTheBufferWindow() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _setPrice(340e8); // 7,200 / 8,500 = 84.7%: above the OPEN threshold
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_OPEN + 2 hours);
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.OPEN));
        uint256 debt = market.debtOf(alice);
        uint256 value = _valueOf(alice, s);
        assertGt(debt * WAD, 0.65e18 * value, "the plan would have work to do");

        assertFalse(escrow.executable(alice, s, debt, value));
        assertEq(escrow.executableAmount(alice, s, debt, value), 0);
        SessionRiskPolicy.Snapshot memory allowed = s;
        allowed.canBuffer = true;
        assertTrue(escrow.executable(alice, allowed, debt, value), "only the window keeps it back");

        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);
        vm.prank(liquidator);
        market.trim(alice, type(uint256).max, 0, block.timestamp); // not held back by BufferPending
    }

    /// INV-ESC-12; kills M25 (a position exactly at its target treated as above it)
    function test_executableAmount_exactlyAtTheTargetNeedsNothing() public {
        _bobPlan(100 * USDG, 0.1e18, 100 * USDG);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 60 minutes);
        assertEq(escrow.executableAmount(bob, s, 4 * USDG, 40 * USDG), 0, "4 on 40 is exactly 10%");
        assertEq(
            escrow.executableAmount(bob, s, 4 * USDG + 1, 40 * USDG),
            4 * USDG + 1,
            "one unit above: the dust rule repays the whole debt"
        );
    }

    /// INV-ESC-12, INV-ESC-14; kills M26 (the cash needed rounded down)
    function test_executableAmount_needRoundsUp() public {
        _bobPlan(1_000 * USDG, 0.65e18, 1_000 * USDG);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 60 minutes);
        assertEq(escrow.executableAmount(bob, s, 7_000 * USDG, 10_000 * USDG), 500 * USDG, "exact division");
        // D - T*V = 500 USDG - 0.65 base units: paying 499.999999 would miss the target.
        assertEq(escrow.executableAmount(bob, s, 7_000 * USDG, 10_000 * USDG + 1), 500 * USDG);
    }

    /// INV-ESC-12, INV-ESC-15; kills M29 (a remainder of exactly the minimum loan treated as dust)
    function test_executableAmount_keepsARemainderOfExactlyTheMinimum() public {
        _bobPlan(100 * USDG, 0.1e18, 100 * USDG);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 60 minutes);
        // D = 7, T*V = 5 = minLoan: the need of 2 leaves exactly the minimum, so nothing more is repaid.
        assertEq(escrow.executableAmount(bob, s, 7 * USDG, 50 * USDG), 2 * USDG);
    }

    /// INV-ESC-12, INV-ESC-15; kills M30 (funds equal to the debt treated as short)
    function test_executableAmount_exactFundsRepayInFullAndShortFundsStopAtTheMinimum() public {
        _bobPlan(100 * USDG, 0.1e18, 7 * USDG);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 60 minutes);
        // D = 7, T*V = 1: the need of 6 would leave 1, below the minimum; the allowance of 7 covers the debt.
        assertEq(escrow.executableAmount(bob, s, 7 * USDG, 10 * USDG), 7 * USDG);
        // One unit short of the debt: stop at exactly the minimum loan instead.
        vm.prank(bob);
        escrow.authorize(0.1e18, 7 * USDG - 1, uint64(MON_CLOSE));
        assertEq(escrow.executableAmount(bob, s, 7 * USDG, 10 * USDG), 2 * USDG);
        // A debt at or below the minimum that the allowance cannot clear: nothing.
        vm.prank(bob);
        escrow.authorize(0.1e18, 3 * USDG, uint64(MON_CLOSE));
        assertEq(escrow.executableAmount(bob, s, 4 * USDG, 10 * USDG), 0);
    }

    /// INV-ESC-21
    function test_execute_eventsReportTheAmountRepaid() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        uint256 amount = escrow.executableAmount(alice, s, debt, _valueOf(alice, s));

        vm.recordLogs();
        vm.prank(keeper);
        escrow.executeBuffer(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 left = market.debtOf(alice);
        assertGe(left, debt - amount);
        assertLe(left, debt - amount + 1, "exactly the amount, within share rounding");

        bytes32 sig = keccak256("BufferExecuted(address,address,uint256,uint256,uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(escrow) || logs[i].topics[0] != sig) continue;
            found++;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(keeper))));
            assertEq(uint256(logs[i].topics[3]), s.session, "the raw calendar index");
            (uint256 repaid, uint256 before, uint256 after_) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(repaid, amount, "the amount actually repaid");
            assertEq(before, debt);
            assertGe(after_, debt - amount);
            assertLe(after_, left, "debt after is the computed figure or the market's, never above it");
        }
        assertEq(found, 1);
    }

    /// INV-ESC-22
    function test_execute_unboundedCapAndExpiryDoNotOverflow() public {
        _workedExample(alice);
        _fund(alice, 1_000 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, type(uint256).max, type(uint64).max);
        _tick(FRI_CLOSE - 120 minutes);
        vm.prank(keeper);
        uint256 repaid = escrow.executeBuffer(alice);
        assertApproxEqAbs(market.debtOf(alice), 6_500 * USDG, 1);
        assertEq(escrow.planOf(alice).spent, repaid);
    }

    /// INV-X-06, INV-ESC-11
    function test_execute_refreshesTheGateAndUsesThatPrice() public {
        _aliceWithBuffer(2_000 * USDG, 2_000 * USDG);
        _tick(FRI_CLOSE - 110 minutes);
        assertEq(gate.lastPriceWad(), 400e18);
        vm.warp(block.timestamp + 1 minutes);
        stockFeed.push(380e8); // published, not yet refreshed
        uint256 expected = _need(market.debtOf(alice), gate.valueOf(25 * TOKEN, 380e18), 0.65e18);

        vm.expectCall(address(gate), abi.encodeCall(PriceGate.refresh, ()));
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), expected, "valued at the refreshed price");
        assertEq(gate.lastPriceWad(), 380e18, "the execution recorded the price it used");
    }

    /// INV-ESC-12, INV-ESC-13, INV-ESC-14, INV-ESC-15, INV-ESC-16, INV-ESC-17, INV-ESC-05, INV-X-15
    function testFuzz_execute_boundedIsolatedAndAgreesWithTheView(
        uint256 minLoanSeed,
        uint256 collSeed,
        uint256 borrowSeed,
        uint256 dropBps,
        uint256 targetSeed,
        uint256 capSeed,
        uint256 balSeed,
        uint256 tSeed
    ) public {
        run.collateral = bound(collSeed, 0.01e18, 100e18);
        uint256 maxBorrow = gate.valueOf(run.collateral, 400e18) * 3 / 4;
        run.minLoan = bound(minLoanSeed, 1, Math.min(500 * USDG, maxBorrow - 2));
        fuzzMarket = new MarketHarness(usdg, tsla, policy, run.minLoan);
        fuzzEscrow = fuzzMarket.escrow();
        vm.startPrank(lender);
        usdg.approve(address(fuzzMarket), type(uint256).max);
        fuzzMarket.deposit(400_000 * USDG, lender);
        vm.stopPrank();

        tsla.mint(alice, run.collateral);
        vm.startPrank(alice);
        tsla.approve(address(fuzzMarket), type(uint256).max);
        fuzzMarket.depositCollateral(run.collateral, alice);
        fuzzMarket.borrow(bound(borrowSeed, run.minLoan, maxBorrow - 1), alice);
        vm.stopPrank();

        // A bystander with its own funded plan is never touched.
        _fundIn(fuzzEscrow, bob, 777 * USDG);
        vm.prank(bob);
        fuzzEscrow.authorize(0.5e18, 100 * USDG, uint64(MON_CLOSE));

        run.balance = bound(balSeed, 0, 50_000 * USDG);
        run.cap = bound(capSeed, 1, 50_000 * USDG);
        run.target = bound(targetSeed, 1, 0.65e18);
        if (run.balance != 0) _fundIn(fuzzEscrow, alice, run.balance);
        vm.prank(alice);
        fuzzEscrow.authorize(run.target, run.cap, uint64(MON_CLOSE));

        answer = TSLA_400 * int256(10_000 - bound(dropBps, 0, 6_000)) / 10_000;
        SessionRiskPolicy.Snapshot memory s = _tick(bound(tSeed, FRI_CLOSE - 120 minutes, FRI_CLOSE - 1));
        assertTrue(s.canBuffer);
        for (uint256 i; i < 3; ++i) {
            _fuzzRound(s);
        }
        uint256 plans = fuzzEscrow.planOf(alice).balance + fuzzEscrow.planOf(bob).balance;
        assertEq(usdg.balanceOf(address(fuzzEscrow)), plans, "the escrow holds exactly the two plans");
    }

    // ------------------------------------------------------------ write-off, stop and wind-down

    /// INV-ESC-10, INV-X-18
    function test_writeOff_leavesTheEscrowToTheBorrower() public {
        _fundCollateral(bob, 0.025e18); // 10 USDG
        _borrow(bob, 7 * USDG);
        _bobPlan(20 * USDG, 0.1e18, 100 * USDG);
        uint256 held = usdg.balanceOf(address(escrow));
        _setPrice(200e8); // 5 USDG of value for 7 USDG of debt
        _tick(FRI_OPEN + 2 hours);

        vm.prank(liquidator);
        market.trim(bob, type(uint256).max, 0, block.timestamp);
        assertEq(market.collateralOf(bob), 0);
        assertEq(market.debtOf(bob), 0, "the residual was written off");
        assertGt(market.totalBadDebt(), 0);
        assertEq(escrow.planOf(bob).balance, 20 * USDG, "the escrow covered nothing");
        assertEq(usdg.balanceOf(address(escrow)), held);
        assertFalse(escrow.committed(bob));
        vm.prank(bob);
        escrow.withdraw(20 * USDG, bob);
    }

    /// INV-X-11, INV-ESC-08, INV-ESC-18, INV-ESC-19
    function test_stop_haltsBuffersButKeepsRepaymentsTopUpsAndWindDownExits() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 100 minutes);
        vm.prank(guardian);
        gate.stop();
        SessionRiskPolicy.Snapshot memory s = _tick(FRI_CLOSE - 90 minutes); // the keeper still publishes
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.PRE_CLOSE));
        assertTrue(escrow.committed(alice), "commitment follows the phase");

        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.trim(alice, type(uint256).max, 0, block.timestamp);

        usdg.mint(mallory, 10 * USDG);
        vm.startPrank(mallory);
        usdg.approve(address(escrow), 10 * USDG);
        escrow.deposit(10 * USDG, alice);
        vm.stopPrank();
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);

        // The stop never lifts; wind-down still releases the plan and buffers stay off.
        vm.warp(cal.lastOpen() + 1 hours);
        assertFalse(escrow.committed(alice));
        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);
        vm.prank(alice);
        escrow.withdraw(910 * USDG, alice);
        assertEq(escrow.planOf(alice).balance, 0);
    }

    /// INV-X-13, INV-ESC-09, INV-ESC-18
    function test_windDown_noBufferButRepaymentsTopUpsAndWithdrawalsContinue() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, 1_000 * USDG, type(uint64).max);
        vm.warp(cal.lastOpen() + 1 hours);
        stockFeed.push(answer);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertTrue(s.windDown);
        assertFalse(s.canBuffer);
        assertFalse(escrow.committed(alice));

        vm.prank(keeper);
        vm.expectPartialRevert(RepaymentEscrow.NotAllowedNow.selector);
        escrow.executeBuffer(alice);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);
        usdg.mint(mallory, 10 * USDG);
        vm.startPrank(mallory);
        usdg.approve(address(escrow), 10 * USDG);
        escrow.deposit(10 * USDG, alice);
        vm.stopPrank();
        vm.prank(alice);
        escrow.withdraw(910 * USDG, alice);
    }

    function test_windDown_releasesPlans() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.prank(alice);
        escrow.authorize(0.65e18, 100 * USDG, type(uint64).max);
        vm.warp(cal.lastOpen() + 1 hours);
        assertFalse(escrow.committed(alice), "buffers can never execute again");
        vm.prank(alice);
        escrow.withdraw(1_000 * USDG, alice);
    }

    // ------------------------------------------------------------ ordering with liquidation

    function test_ordering_trimWaitsForAnExecutableBuffer() public {
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 45 minutes);
        vm.prank(liquidator);
        vm.expectRevert(StockReefMarket.BufferPending.selector);
        market.trim(alice, type(uint256).max, 0, block.timestamp);

        vm.prank(keeper);
        escrow.executeBuffer(alice);
        vm.prank(liquidator);
        vm.expectPartialRevert(StockReefMarket.NotEligible.selector);
        market.trim(alice, type(uint256).max, 0, block.timestamp);
        assertApproxEqAbs(market.debtOf(alice), 6_500 * USDG, 1, "the buffer repayment stands on its own");
    }

    function test_ordering_partialBufferThenTrimForTheRest() public {
        _aliceWithBuffer(100 * USDG, 1_000 * USDG);
        _tick(FRI_CLOSE - 30 minutes); // final window: LT 70%, the buffer only reaches 71%
        vm.prank(keeper);
        escrow.executeBuffer(alice);
        assertFalse(escrow.executable(alice, policy.snapshot(), market.debtOf(alice), 9_999 * USDG));

        vm.prank(liquidator);
        market.trim(alice, type(uint256).max, 0, block.timestamp);
        uint256 value = gate.valueOf(market.collateralOf(alice), 400e18);
        assertLe(market.debtOf(alice) * 1e18, 0.65e18 * value + 1e18);
    }

    // ------------------------------------------------------------ commitment

    function test_commitment_locksFromAUntilAFullReopening() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        assertFalse(escrow.committed(alice), "OPEN before A");

        _tick(FRI_CLOSE - 120 minutes);
        assertTrue(escrow.committed(alice));
        vm.startPrank(alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.withdraw(1, alice);
        vm.expectRevert(RepaymentEscrow.Committed.selector);
        escrow.cancel();
        vm.stopPrank();

        _tick(FRI_CLOSE + 1 days);
        assertTrue(escrow.committed(alice), "closed");
        _tick(MON_OPEN + 5 minutes);
        assertTrue(escrow.committed(alice), "recovery");
        _tick(MON_OPEN + 15 minutes);
        assertFalse(escrow.committed(alice), "valid full reopening");
        vm.prank(alice);
        escrow.withdraw(1, alice);
    }

    /// INV-ESC-08, INV-X-14
    function test_commitment_followsTheSchedulePhaseNotTheEffectiveState() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _bobPlan(50 * USDG, 0.5e18, 100 * USDG); // an active plan without debt

        // OPEN phase with a stale price: GUARDED, yet nothing is committed.
        vm.warp(FRI_OPEN + 2 hours);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.OPEN));
        assertFalse(escrow.committed(alice));
        assertEq(escrow.committed(alice), _expectedCommitted(alice));

        // PRE_CLOSE phase with the same stale price: GUARDED, and committed.
        vm.warp(FRI_CLOSE - 100 minutes);
        s = policy.snapshot();
        assertEq(uint256(s.state), uint256(SessionRiskPolicy.State.GUARDED));
        assertEq(uint256(s.phase), uint256(SessionRiskPolicy.State.PRE_CLOSE));
        assertTrue(escrow.committed(alice));
        assertEq(escrow.committed(alice), _expectedCommitted(alice));
        assertFalse(escrow.committed(bob), "no debt, nothing to protect");
        assertEq(escrow.committed(bob), _expectedCommitted(bob));
        vm.prank(bob);
        escrow.withdraw(50 * USDG, bob);

        // While committed, top-ups, ownerRepay and (with a usable price) executeBuffer all work.
        usdg.mint(alice, 10 * USDG);
        vm.prank(alice);
        escrow.deposit(10 * USDG, alice);
        vm.prank(alice);
        escrow.ownerRepay(10 * USDG);
        _tick(FRI_CLOSE - 99 minutes);
        vm.prank(keeper);
        assertEq(escrow.executeBuffer(alice), 100 * USDG);
        assertTrue(escrow.committed(alice));
        assertEq(escrow.committed(alice), _expectedCommitted(alice));
    }

    function test_commitment_priceOutageOrGuardianStopNeverFreezesEscrow() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.warp(block.timestamp + MOCK_MAX_AGE + 1); // OPEN phase, stale price: GUARDED
        assertEq(uint256(_state()), uint256(SessionRiskPolicy.State.GUARDED));
        assertFalse(escrow.committed(alice));

        vm.prank(guardian);
        gate.stop();
        vm.prank(alice);
        escrow.withdraw(400 * USDG, alice);
        vm.prank(alice);
        escrow.cancel();
        assertEq(escrow.planOf(alice).balance, 600 * USDG);
    }

    function test_commitment_endsWithFullRepaymentOrExpiry() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        _tick(FRI_CLOSE + 1 hours);
        assertTrue(escrow.committed(alice));

        uint256 debt = market.debtOf(alice);
        usdg.mint(alice, debt);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        market.repay(debt, alice);
        assertFalse(escrow.committed(alice), "no debt, nothing to protect");
        escrow.withdraw(1_000 * USDG, alice);
        vm.stopPrank();
    }

    function test_commitment_expiredAuthorizationReleasesFunds() public {
        _workedExample(alice);
        usdg.mint(alice, 1_000 * USDG);
        vm.startPrank(alice);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        escrow.authorize(0.65e18, 100 * USDG, uint64(FRI_CLOSE + 1 hours));
        vm.stopPrank();

        _tick(FRI_CLOSE + 2 hours);
        assertFalse(escrow.committed(alice));
        vm.prank(alice);
        escrow.withdraw(1_000 * USDG, alice);
    }

    function test_ownerRepay_worksWhileClosedOrGuarded() public {
        _aliceWithBuffer(1_000 * USDG, 100 * USDG);
        vm.warp(FRI_CLOSE + 1 days);
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);

        vm.prank(guardian);
        gate.stop();
        vm.prank(alice);
        assertEq(escrow.ownerRepay(100 * USDG), 100 * USDG);
        assertEq(escrow.planOf(alice).balance, 800 * USDG);
    }

    function test_deposit_allowedEvenWhileCommitted() public {
        _aliceWithBuffer(100 * USDG, 100 * USDG);
        _tick(FRI_CLOSE + 1 hours);
        usdg.mint(alice, 50 * USDG);
        vm.prank(alice);
        escrow.deposit(50 * USDG, alice);
        assertEq(escrow.planOf(alice).balance, 150 * USDG);
    }

    // ------------------------------------------------------------ separation from lender funds

    function test_escrowIsNeverLenderCash() public {
        uint256 assetsBefore = market.totalAssets();
        uint256 cashBefore = market.cash();
        _aliceWithBuffer(1_000 * USDG, 1_000 * USDG);
        assertEq(market.cash(), cashBefore - 7_200 * USDG);
        assertEq(usdg.balanceOf(address(escrow)), 1_000 * USDG);
        assertApproxEqAbs(market.totalAssets(), assetsBefore, 1, "escrow adds nothing to the book");
    }

    // ------------------------------------------------------------ fuzz helpers

    /// @dev State of one fuzzed buffer run, kept in storage to stay within the stack limit.
    struct BufferRun {
        uint256 minLoan;
        uint256 collateral;
        uint256 balance;
        uint256 cap;
        uint256 target;
        uint256 debt;
        uint256 value;
        uint256 expected;
        uint256 held;
        uint256 cash;
        uint256 spent;
        uint256 keeperWallet;
        uint256 balanceBefore;
    }

    BufferRun internal run;
    MarketHarness internal fuzzMarket;
    RepaymentEscrow internal fuzzEscrow;

    function _fuzzRound(SessionRiskPolicy.Snapshot memory s) internal {
        run.debt = fuzzMarket.debtOf(alice);
        run.value = gate.valueOf(run.collateral, s.priceWad);
        run.expected = fuzzEscrow.executableAmount(alice, s, run.debt, run.value);
        assertEq(fuzzEscrow.executable(alice, s, run.debt, run.value), run.expected != 0, "view flags agree");
        run.held = usdg.balanceOf(address(fuzzEscrow));
        run.cash = fuzzMarket.cash();
        run.balanceBefore = fuzzEscrow.planOf(alice).balance;
        run.keeperWallet = usdg.balanceOf(keeper);

        vm.prank(keeper);
        try fuzzEscrow.executeBuffer(alice) returns (uint256 repaid) {
            _checkFuzzExecution(repaid);
        } catch (bytes memory err) {
            assertEq(run.expected, 0, "the view said executable but the execution reverted");
            assertEq(bytes4(err), RepaymentEscrow.NothingToRepay.selector);
        }
        assertEq(fuzzEscrow.planOf(bob).balance, 777 * USDG, "bystander untouched");
        assertEq(fuzzEscrow.planOf(bob).spent, 0);
    }

    function _checkFuzzExecution(uint256 repaid) internal {
        assertEq(repaid, run.expected, "execution == view");
        assertGt(repaid, 0);
        assertLe(repaid, run.debt, "never above the debt");
        assertLe(repaid, run.balanceBefore, "never above the balance");
        uint256 available = Math.min(run.balanceBefore, run.cap - run.spent);
        run.spent += repaid;
        assertLe(run.spent, run.cap, "per-session cap");

        uint256 debtAfter = fuzzMarket.debtOf(alice);
        assertTrue(debtAfter == 0 || debtAfter >= run.minLoan, "never below the minimum loan");
        if (repaid == run.debt) assertEq(debtAfter, 0);
        else assertTrue(debtAfter + repaid == run.debt || debtAfter + repaid == run.debt + 1, "exact reduction");

        uint256 need = _need(run.debt, run.value, run.target);
        assertTrue(
            repaid == Math.min(need, available) || repaid == run.debt || repaid == run.debt - run.minLoan,
            "only the documented amounts"
        );
        if (repaid > need) {
            // The minimum-loan overshoot is a full repayment of a debt within minLoan of the need.
            assertEq(debtAfter, 0);
            assertLt(run.debt - need, run.minLoan);
        }
        if (repaid == need) assertLe(debtAfter * WAD, run.target * run.value + WAD, "target within one unit");

        assertEq(usdg.balanceOf(address(fuzzEscrow)), run.held - repaid);
        assertEq(fuzzMarket.cash(), run.cash + repaid);
        assertEq(usdg.allowance(address(fuzzEscrow), address(fuzzMarket)), 0);
        assertEq(fuzzEscrow.planOf(alice).balance, run.balanceBefore - repaid);
        assertEq(fuzzEscrow.planOf(alice).spent, run.spent);
        assertEq(usdg.balanceOf(keeper), run.keeperWallet, "no reward");
    }
}

/// @notice The escrow under a loan token with sender and receiver hooks: re-entry cannot move funds.
contract EscrowReentrancyTest is GateFixture {
    uint64 internal constant FRI_OPEN = 1789133400;
    uint256 internal constant USDG = 1e6;

    EscrowHookedUSDG internal husdg;
    SessionRiskPolicy internal policy;
    StockReefMarket internal market;
    RepaymentEscrow internal escrow;
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(FRI_OPEN - 1 hours);
        cal = _deployCalendar();
        clock = new DemoClock(address(this));
        stockFeed = new MockAggregatorV3(8, "Simulated TSLA/USD", clock, address(this));
        tsla = new MockStockToken("Tesla Stock Token", "TSLA", true);
        husdg = new EscrowHookedUSDG();
        PriceGate.Config memory c = _config();
        c.loanToken = address(husdg);
        gate = new PriceGate(c);
        policy = new SessionRiskPolicy(gate);
        market = new StockReefMarket(husdg, tsla, policy, 5 * USDG, "StockReef hUSDG", "srH");
        escrow = market.escrow();

        _freshRefresh(FRI_OPEN + 5 minutes);
        _freshRefresh(FRI_OPEN + 15 minutes);
        husdg.mint(lender, 100_000 * USDG);
        vm.startPrank(lender);
        husdg.approve(address(market), type(uint256).max);
        market.deposit(100_000 * USDG, lender);
        vm.stopPrank();

        // Alice: the worked example with a funded plan.
        tsla.mint(alice, 25e18);
        husdg.mint(alice, 1_000 * USDG);
        vm.startPrank(alice);
        tsla.approve(address(market), type(uint256).max);
        market.depositCollateral(25e18, alice);
        market.borrow(7_200 * USDG, alice);
        husdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000 * USDG, alice);
        escrow.authorize(0.65e18, 1_000 * USDG, MON_CLOSE);
        vm.stopPrank();
    }

    /// INV-X-09, INV-ESC-01, INV-ESC-03, INV-ESC-06
    function test_hookedLoanToken_reentryCannotMoveFunds() public {
        EscrowReenterer r = new EscrowReenterer(escrow, husdg, alice);
        husdg.mint(address(r), 100 * USDG);
        r.deposit(50 * USDG);
        husdg.setHooked(address(r), true);
        RepaymentEscrow.Plan memory alicePlan = escrow.planOf(alice);

        r.withdraw(10 * USDG, address(r)); // receiver hook inside its own withdrawal
        r.deposit(10 * USDG); // sender hook inside its own deposit
        vm.prank(alice);
        escrow.withdraw(5 * USDG, address(r)); // receiver hook inside another owner's withdrawal

        assertEq(r.hookCalls(), 3);
        assertEq(r.fundMoves(), 0, "no re-entered call moved funds");
        assertEq(r.errorCount(), 12);
        for (uint256 i; i < 12; ++i) {
            assertEq(r.errors(i), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "stopped by the guard");
        }
        assertEq(escrow.planOf(address(r)).balance, 50 * USDG);
        assertEq(escrow.planOf(alice).balance, alicePlan.balance - 5 * USDG);
        assertEq(escrow.planOf(alice).targetWad, alicePlan.targetWad, "the victim's plan is out of reach");
        assertEq(escrow.planOf(alice).expiry, alicePlan.expiry);
        assertEq(husdg.balanceOf(address(r)), 55 * USDG);
        assertEq(husdg.balanceOf(address(escrow)), escrow.planOf(alice).balance + escrow.planOf(address(r)).balance);
        assertEq(husdg.allowance(address(escrow), address(market)), 0);
    }

    /// INV-X-09, INV-ESC-16
    function test_hookedLoanToken_bufferStaysExact() public {
        EscrowReenterer r = new EscrowReenterer(escrow, husdg, alice);
        husdg.setHooked(address(r), true);
        _freshRefresh(FRI_CLOSE - 120 minutes);
        uint256 debt = market.debtOf(alice);
        vm.prank(keeper);
        uint256 repaid = escrow.executeBuffer(alice);
        assertGt(repaid, 0);
        assertGe(market.debtOf(alice) + repaid, debt);
        assertLe(market.debtOf(alice) + repaid, debt + 1);
        assertEq(husdg.balanceOf(address(escrow)), escrow.planOf(alice).balance);
        assertEq(husdg.allowance(address(escrow), address(market)), 0);
        assertEq(r.hookCalls(), 0, "the escrow-to-market payment has no hooked party");
    }
}
