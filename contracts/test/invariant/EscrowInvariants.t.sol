// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {IClock} from "../../src/interfaces/IClock.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {DemoClock} from "../../src/clock/DemoClock.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @notice Receiver of loan-token hooks.
interface IEscrowInvHook {
    function onTokenMove(address from, address to, uint256 value) external;
}

/// @notice The suite's loan token: a 6-decimal ERC-20 that calls registered contracts before they send and after
/// they receive (ERC-777 style), so every escrow transfer to or from the attacker runs attacker code.
contract EscrowInvHookedUSDG is ERC20 {
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
        if (from != address(0) && hooked[from]) IEscrowInvHook(from).onTokenMove(from, to, value);
        super._update(from, to, value);
        if (to != address(0) && hooked[to]) IEscrowInvHook(to).onTokenMove(from, to, value);
    }
}

/// @notice An indebted plan owner that, from its token hook, re-enters every escrow function that moves tokens
/// whenever a loan-token move to or from the escrow reaches it.
contract EscrowInvAttacker is IEscrowInvHook {
    RepaymentEscrow internal immutable escrow;
    StockReefMarket internal immutable market;
    IERC20 internal immutable token;
    address internal immutable victim;

    /// @dev Hooks that fired inside an escrow token move.
    uint256 public hookCalls;
    /// @dev Re-entered deposit, withdraw, ownerRepay or executeBuffer calls that succeeded.
    uint256 public fundMoves;

    constructor(RepaymentEscrow escrow_, StockReefMarket market_, IERC20 token_, IERC20 collateral, address victim_) {
        escrow = escrow_;
        market = market_;
        token = token_;
        victim = victim_;
        token_.approve(address(escrow_), type(uint256).max);
        token_.approve(address(market_), type(uint256).max);
        collateral.approve(address(market_), type(uint256).max);
    }

    function onTokenMove(address from, address to, uint256) external {
        if (msg.sender != address(token) || (from != address(escrow) && to != address(escrow))) return;
        hookCalls++;
        try escrow.withdraw(1, address(this)) {
            fundMoves++;
        } catch {}
        try escrow.deposit(1, address(this)) {
            fundMoves++;
        } catch {}
        try escrow.ownerRepay(1) {
            fundMoves++;
        } catch {}
        try escrow.executeBuffer(victim) {
            fundMoves++;
        } catch {}
    }

    function deposit(uint256 amount, address account) external {
        escrow.deposit(amount, account);
    }

    function withdraw(uint256 amount, address receiver) external {
        escrow.withdraw(amount, receiver);
    }

    function ownerRepay(uint256 amount) external returns (uint256) {
        return escrow.ownerRepay(amount);
    }

    function authorize(uint256 targetWad, uint256 cap, uint64 expiry) external {
        escrow.authorize(targetWad, cap, expiry);
    }

    function cancel() external {
        escrow.cancel();
    }

    function executeBuffer(address account) external returns (uint256) {
        return escrow.executeBuffer(account);
    }

    function depositCollateral(uint256 amount) external {
        market.depositCollateral(amount, address(this));
    }

    function borrow(uint256 amount) external {
        market.borrow(amount, address(this));
    }
}

/// @notice Plan owners, a keeper, a stranger, a hooked attacker contract, a donor and a liquidator acting on the
/// escrow and its market across real sessions. Every successful action is checked against what it may change;
/// a breach is counted, never reverted, so the invariants see it.
contract EscrowHandler is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;
    uint256 internal constant WAD = 1e18;
    /// @dev Subject used when an action may change no plan and no debt at all.
    address internal constant NOBODY = address(1);

    StockReefMarket internal market;
    RepaymentEscrow internal escrow;
    SessionRiskPolicy internal policy;
    PriceGate internal gate;
    SessionCalendar internal cal;
    IClock internal clock;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    EscrowInvHookedUSDG internal usdg;
    address internal owner; // the fixture: issuer of the stock token and publisher of the feed

    /// @dev Indebted plan owners: four wallets, then the hooked attacker contract.
    address[5] public borrowers;
    EscrowInvAttacker public attacker;
    address public mallory = address(0xBAD);
    address public keeper = address(0x6EE9);
    address internal liquidator = address(0x11D);
    address internal donor = address(0xD0);
    address internal friend = address(0xF7);
    /// @dev Every address a plan balance can be credited to: the borrowers, mallory, the keeper, then three
    /// accounts that can never call the escrow (address(0), the escrow, the market).
    address[] internal tracked;
    int256 public answer = 400e8;

    // ---------------------------------------------------------------- ghosts
    mapping(address => uint256) public ghostBalance;
    uint256 public ghostIn; // credited by deposit
    uint256 public ghostDonated; // sent to the escrow directly, credited to no plan
    uint256 public ghostPaidOut; // withdrawn to receivers other than the escrow
    uint256 public ghostSelfWithdrawn; // withdrawn with the escrow itself as receiver: stays as surplus
    uint256 public ghostRepaid; // paid into the market by ownerRepay and executeBuffer

    // ---------------------------------------------------------------- breaches (must stay zero)
    uint256 public foreignPlanChanged; // an action changed a plan other than its subject's
    uint256 public foreignDebtChanged; // an action changed a debt other than its subject's
    uint256 public wrongCredit; // a deposit credited other than exactly `amount` to the named account
    uint256 public depositRejected; // a funded deposit for a callable account reverted
    uint256 public wrongPayout; // a withdrawal paid other than exactly `amount` to the receiver
    uint256 public withdrawRejected; // an uncommitted owner could not withdraw its own balance
    uint256 public overdraft; // withdraw or ownerRepay took more than the caller's balance
    uint256 public committedBypass; // withdraw, cancel or authorize succeeded while committed
    uint256 public authMismatch; // authorize or cancel wrote other values, or accepted invalid ones
    uint256 public authorizeRejected; // a valid authorize, or a cancel, by an uncommitted owner reverted
    uint256 public repayMismatch; // ownerRepay repaid other than min(amount, debt) from the caller's plan
    uint256 public debtMismatch; // a repayment cut the debt by other than the amount taken from the plan
    uint256 public cashMismatch; // market cash or escrow tokens moved by other than the amount repaid
    uint256 public dustLeft; // a repayment left debt between zero and the minimum loan
    uint256 public bufferOutsideWindow; // executeBuffer ran without canBuffer or without an active plan
    uint256 public bufferOverBalance;
    uint256 public bufferOverCap; // the session's spend record broke the cap or did not add up
    uint256 public bufferPastTarget; // repaid past the target other than by the bounded minimum-loan rule
    uint256 public bufferMissedTarget; // stopped short of the target with funds and allowance to spare
    uint256 public bufferViewMismatch; // execution differs from executableAmount at the same snapshot
    uint256 public callerPaid; // executeBuffer changed the caller's wallet or plan, or moved collateral

    // ---------------------------------------------------------------- productivity
    uint256 public calls;
    uint256 public okDeposit;
    uint256 public okThirdPartyDeposit;
    uint256 public okSinkDeposit;
    uint256 public okDonate;
    uint256 public okWithdraw;
    uint256 public okWithdrawElsewhere;
    uint256 public okSelfWithdraw;
    uint256 public okAuthorize;
    uint256 public okCancel;
    uint256 public okOwnerRepay;
    uint256 public okBuffer;
    uint256 public okBufferToTarget;
    uint256 public okBufferShort;
    uint256 public okBufferFull;
    uint256 public bufferNothing;
    uint256 public blockedByCommitment;
    uint256 public strangerRefused;
    uint256 public okTrim;
    uint256 public okBorrow;
    uint256 public okMarketRepay;

    /// @dev State read before an action.
    struct Pre {
        RepaymentEscrow.Plan plan; // the subject's plan
        bytes32[] plans; // hash of every tracked plan
        uint256[5] debts; // every borrower's debt
        uint256 held; // escrow loan-token balance
    }

    /// @dev State read before an executeBuffer.
    struct Exec {
        SessionRiskPolicy.Snapshot s;
        RepaymentEscrow.Plan plan;
        uint256 debt;
        uint256 value;
        uint256 expected;
        uint256 callerWallet;
        uint256 cash;
        uint256 collateral;
        Pre pre;
    }

    constructor(StockReefMarket m, MockAggregatorV3 f, MockStockToken t, EscrowInvHookedUSDG u, address owner_) {
        market = m;
        escrow = m.escrow();
        policy = m.policy();
        gate = m.gate();
        cal = gate.calendar();
        clock = m.clock();
        feed = f;
        tsla = t;
        usdg = u;
        owner = owner_;
        for (uint256 i; i < 4; ++i) {
            borrowers[i] = address(uint160(0xE000 + i));
        }
        attacker = new EscrowInvAttacker(escrow, m, u, t, borrowers[0]);
        borrowers[4] = address(attacker);
        u.setHooked(address(attacker), true);

        address[6] memory wallets = [borrowers[0], borrowers[1], borrowers[2], borrowers[3], mallory, keeper];
        for (uint256 i; i < wallets.length; ++i) {
            vm.startPrank(wallets[i]);
            u.approve(address(escrow), type(uint256).max);
            u.approve(address(m), type(uint256).max);
            t.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(liquidator);
        u.approve(address(m), type(uint256).max);

        for (uint256 i; i < 5; ++i) {
            tracked.push(borrowers[i]);
        }
        tracked.push(mallory);
        tracked.push(keeper);
        tracked.push(address(0));
        tracked.push(address(escrow));
        tracked.push(address(m));
    }

    /// @dev Opening positions at 70% LTV with funded plans: three wallets and the attacker with 50 TSLA
    /// (20,000 USDG) and a plan toward 60%, and one small wallet with 0.03 TSLA (12 USDG) and a plan toward 40%,
    /// whose target sits near the minimum loan, so the minimum-loan rule decides most of its buffers.
    function seed() external {
        uint64 expiry = clock.time() + 60 days;
        for (uint256 i; i < 5; ++i) {
            address b = borrowers[i];
            bool small = i == 3;
            uint256 collateral = small ? 0.03e18 : 50 * TOKEN;
            uint256 debt = small ? 8.4e6 : 14_000 * USDG;
            uint256 funds = small ? 20 * USDG : 3_000 * USDG;
            uint256 cap = small ? 6 * USDG : 1_500 * USDG;
            uint256 target = small ? 0.4e18 : 0.6e18;
            _mintTsla(b, collateral);
            usdg.mint(b, funds);
            if (b == address(attacker)) {
                attacker.depositCollateral(collateral);
                attacker.borrow(debt);
                attacker.deposit(funds, b);
                attacker.authorize(target, cap, expiry);
            } else {
                vm.startPrank(b);
                market.depositCollateral(collateral, b);
                market.borrow(debt, b);
                escrow.deposit(funds, b);
                escrow.authorize(target, cap, expiry);
                vm.stopPrank();
            }
            ghostBalance[b] += funds;
            ghostIn += funds;
        }
    }

    function trackedAccounts() external view returns (address[] memory) {
        return tracked;
    }

    // ---------------------------------------------------------------- time and price

    /// @dev A step of 1 to 60 minutes with a move of up to 1% either way.
    function tick(uint256 seed_, uint256 minutes_) external {
        calls++;
        vm.warp(block.timestamp + 1 minutes + (minutes_ % 60 minutes));
        _move(int256(seed_ % 201) - 100);
        _publish();
    }

    /// @dev Jump into the preparation window (A to C - 5 min) of the current session, or of the next one after a
    /// full reopening when it has already begun.
    function toPreparation(uint256 seed_) external {
        calls++;
        SessionCalendar.Context memory c = cal.context(clock.time());
        if (!c.covered) return;
        if (!c.inSession || block.timestamp >= c.close - 115 minutes) {
            _reopen(c, int256(seed_ % 1_001) - 500);
            c = cal.context(clock.time());
        }
        uint256 t = c.close - 120 minutes + (seed_ >> 16) % 115 minutes;
        if (t > block.timestamp) vm.warp(t);
        _move(int256((seed_ >> 32) % 201) - 100);
        _publish();
        // Half the time the keeper is there as the window opens.
        if ((seed_ >> 48) % 2 == 0) _sweep(seed_);
    }

    /// @dev Cross the next closure with a gap move of up to 8%, reopen fully, then move up to 3 hours into it.
    function toNextSession(uint256 seed_) external {
        calls++;
        SessionCalendar.Context memory c = cal.context(clock.time());
        if (!c.covered) return;
        _reopen(c, int256(seed_ % 1_601) - 800);
        vm.warp(block.timestamp + (seed_ >> 16) % 3 hours);
        _publish();
    }

    // ---------------------------------------------------------------- plan owners and strangers

    function deposit(uint256 payerSeed, uint256 accountSeed, uint256 amount) external {
        _flow(payerSeed ^ amount);
        address payer = _caller(payerSeed);
        address account = accountSeed % 3 == 0 ? payer : tracked[accountSeed % tracked.length];
        amount = bound(amount, 1, 3_000 * USDG);
        usdg.mint(payer, amount);
        Pre memory pre = _pre(account);
        bool wasCommitted = escrow.committed(account);
        uint256 payerWallet = usdg.balanceOf(payer);

        bool ok;
        if (payer == address(attacker)) {
            try attacker.deposit(amount, account) {
                ok = true;
            } catch {}
        } else {
            vm.prank(payer);
            try escrow.deposit(amount, account) {
                ok = true;
            } catch {}
        }
        if (!ok) {
            if (!_isSink(account)) depositRejected++;
            return;
        }
        okDeposit++;
        if (payer != account) okThirdPartyDeposit++;
        if (_isSink(account)) okSinkDeposit++;

        RepaymentEscrow.Plan memory p = escrow.planOf(account);
        if (p.balance != pre.plan.balance + amount || !_sameAuthorization(p, pre.plan)) wrongCredit++;
        if (usdg.balanceOf(payer) + amount != payerWallet) wrongCredit++;
        if (usdg.balanceOf(address(escrow)) != pre.held + amount) wrongCredit++;
        if (escrow.committed(account) != wasCommitted) wrongCredit++;
        _othersUnchanged(pre, account, NOBODY);
        ghostBalance[account] += amount;
        ghostIn += amount;
    }

    function withdraw(uint256 callerSeed, uint256 amount, uint256 receiverSeed) external {
        _flow(callerSeed ^ receiverSeed);
        address caller = _caller(callerSeed);
        address receiver = _receiver(receiverSeed, caller);
        uint256 bal = escrow.planOf(caller).balance;
        // One in five tries to take more than its own balance, up to everything the escrow holds.
        amount = amount % 5 == 0
            ? bound(amount, bal + 1, bal + usdg.balanceOf(address(escrow)) + 1)
            : bound(amount, 1, bal == 0 ? 1 : bal);
        Pre memory pre = _pre(caller);
        bool wasCommitted = escrow.committed(caller);
        uint256 receiverWallet = usdg.balanceOf(receiver);
        uint256 callerWallet = usdg.balanceOf(caller);

        (bool ok, bytes4 err) = _withdrawAs(caller, amount, receiver);
        if (!ok) {
            if (err == RepaymentEscrow.Committed.selector) blockedByCommitment++;
            else if (amount > bal) strangerRefused++;
            else if (!wasCommitted && receiver != address(escrow)) withdrawRejected++;
            return;
        }
        okWithdraw++;
        if (wasCommitted) committedBypass++;
        if (amount > bal) overdraft++;
        RepaymentEscrow.Plan memory p = escrow.planOf(caller);
        if (p.balance + amount != bal || !_sameAuthorization(p, pre.plan)) wrongPayout++;
        if (receiver == address(escrow)) {
            okSelfWithdraw++;
            if (usdg.balanceOf(address(escrow)) != pre.held) wrongPayout++;
            ghostSelfWithdrawn += amount;
        } else {
            if (receiver != caller) okWithdrawElsewhere++;
            if (usdg.balanceOf(receiver) != receiverWallet + amount) wrongPayout++;
            if (receiver != caller && usdg.balanceOf(caller) != callerWallet) wrongPayout++;
            if (usdg.balanceOf(address(escrow)) + amount != pre.held) wrongPayout++;
            ghostPaidOut += amount;
        }
        _othersUnchanged(pre, caller, NOBODY);
        ghostBalance[caller] = _sub(ghostBalance[caller], amount);
    }

    function ownerRepay(uint256 callerSeed, uint256 amount) external {
        _flow(callerSeed ^ amount);
        address caller = _caller(callerSeed);
        uint256 bal = escrow.planOf(caller).balance;
        uint256 debt = market.debtOf(caller);
        amount = amount % 4 == 0 ? bound(amount, 1, bal + 100 * USDG) : bound(amount, 1, bal == 0 ? 1 : bal);
        Pre memory pre = _pre(caller);
        uint256 cash = market.cash();

        (bool ok, uint256 repaid) = _ownerRepayAs(caller, amount);
        if (!ok) return;
        okOwnerRepay++;
        if (amount > bal) overdraft++;
        if (repaid != Math.min(amount, debt)) repayMismatch++;
        RepaymentEscrow.Plan memory p = escrow.planOf(caller);
        if (p.balance + repaid != bal || !_sameAuthorization(p, pre.plan)) repayMismatch++;
        uint256 debtAfter = market.debtOf(caller);
        if (!_exactReduction(debt, repaid, debtAfter)) debtMismatch++;
        if (debtAfter != 0 && debtAfter < market.minLoan()) dustLeft++;
        if (market.cash() != cash + repaid || usdg.balanceOf(address(escrow)) + repaid != pre.held) cashMismatch++;
        _othersUnchanged(pre, caller, caller);
        ghostBalance[caller] = _sub(ghostBalance[caller], repaid);
        ghostRepaid += repaid;
    }

    /// @dev Set a plan; one call in six cancels it instead.
    function authorize(uint256 callerSeed, uint256 targetSeed, uint256 capSeed, uint256 expirySeed) external {
        _flow(callerSeed ^ targetSeed);
        address caller = _caller(callerSeed);
        if (expirySeed % 6 == 5) {
            _cancel(caller);
            return;
        }
        // Mostly valid; now and then a zero or excessive target, a zero cap or an expiry of now.
        uint256 target = targetSeed % 11 == 0
            ? (targetSeed % 2 == 0 ? 0 : escrow.MAX_TARGET() + 1)
            : bound(targetSeed, 0.4e18, escrow.MAX_TARGET());
        uint256 cap = capSeed % 13 == 0 ? 0 : bound(capSeed, 1, 3_000 * USDG);
        uint64 nowT = clock.time();
        uint64 expiry = uint64(nowT + bound(expirySeed, 0, 6 days));
        bool valid = target != 0 && target <= escrow.MAX_TARGET() && cap != 0 && expiry > nowT;
        bool wasCommitted = escrow.committed(caller);
        Pre memory pre = _pre(caller);

        bool ok;
        bytes4 err;
        if (caller == address(attacker)) {
            try attacker.authorize(target, cap, expiry) {
                ok = true;
            } catch (bytes memory e) {
                err = bytes4(e);
            }
        } else {
            vm.prank(caller);
            try escrow.authorize(target, cap, expiry) {
                ok = true;
            } catch (bytes memory e) {
                err = bytes4(e);
            }
        }
        if (!ok) {
            if (err == RepaymentEscrow.Committed.selector) blockedByCommitment++;
            else if (valid && !wasCommitted) authorizeRejected++;
            return;
        }
        okAuthorize++;
        if (wasCommitted) committedBypass++;
        if (!valid) authMismatch++;
        RepaymentEscrow.Plan memory p = escrow.planOf(caller);
        if (p.targetWad != target || p.perSessionCap != cap || p.expiry != expiry) authMismatch++;
        if (p.balance != pre.plan.balance || p.spent != pre.plan.spent || p.spentSession != pre.plan.spentSession) {
            authMismatch++;
        }
        if (usdg.balanceOf(address(escrow)) != pre.held) authMismatch++;
        _othersUnchanged(pre, caller, NOBODY);
    }

    function _cancel(address caller) internal {
        bool wasCommitted = escrow.committed(caller);
        Pre memory pre = _pre(caller);

        bool ok;
        bytes4 err;
        if (caller == address(attacker)) {
            try attacker.cancel() {
                ok = true;
            } catch (bytes memory e) {
                err = bytes4(e);
            }
        } else {
            vm.prank(caller);
            try escrow.cancel() {
                ok = true;
            } catch (bytes memory e) {
                err = bytes4(e);
            }
        }
        if (!ok) {
            if (err == RepaymentEscrow.Committed.selector) blockedByCommitment++;
            else if (!wasCommitted) authorizeRejected++;
            return;
        }
        okCancel++;
        if (wasCommitted) committedBypass++;
        RepaymentEscrow.Plan memory p = escrow.planOf(caller);
        if (p.targetWad != 0 || p.perSessionCap != 0 || p.expiry != 0) authMismatch++;
        if (p.balance != pre.plan.balance || p.spent != pre.plan.spent || p.spentSession != pre.plan.spentSession) {
            authMismatch++;
        }
        if (usdg.balanceOf(address(escrow)) != pre.held) authMismatch++;
        _othersUnchanged(pre, caller, NOBODY);
    }

    // ---------------------------------------------------------------- keeper

    /// @dev Anyone runs one buffer: mostly the keeper, sometimes a stranger, the attacker or another owner.
    function executeBuffer(uint256 callerSeed, uint256 accountSeed) external {
        _flow(callerSeed ^ accountSeed);
        address caller = callerSeed % 3 == 0 ? _caller(callerSeed >> 8) : keeper;
        address account = accountSeed % 7 < 5 ? borrowers[accountSeed % 5] : tracked[accountSeed % tracked.length];
        _execute(caller, account);
    }

    /// @dev The keeper's sweep: one buffer for every borrower in turn, in one block.
    function keeperRound(uint256 seed_) external {
        _flow(seed_);
        _sweep(seed_);
    }

    function _sweep(uint256 seed_) internal {
        for (uint256 i; i < 5; ++i) {
            _execute(keeper, borrowers[(seed_ % 5 + i) % 5]);
        }
    }

    // ---------------------------------------------------------------- the market around the escrow

    function borrow(uint256 seed_, uint256 amount) external {
        _flow(seed_ ^ amount);
        address a = borrowers[seed_ % 5];
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 capacity = gate.valueOf(market.collateralOf(a), s.priceWad) * 74 / 100;
        uint256 debt = market.debtOf(a);
        if (capacity <= debt + 5 * USDG) return;
        amount = bound(amount, 5 * USDG, capacity - debt);
        Pre memory pre = _pre(NOBODY);
        if (a == address(attacker)) {
            try attacker.borrow(amount) {
                okBorrow++;
            } catch {}
        } else {
            vm.prank(a);
            try market.borrow(amount, a) {
                okBorrow++;
            } catch {}
        }
        _escrowUntouched(pre, a);
    }

    /// @dev A wallet repays a borrower's debt directly at the market.
    function marketRepay(uint256 payerSeed, uint256 accountSeed, uint256 amount) external {
        _flow(payerSeed ^ accountSeed);
        address payer = payerSeed % 2 == 0 ? mallory : borrowers[payerSeed % 4];
        address account = borrowers[accountSeed % 5];
        amount = bound(amount, 1, 3_000 * USDG);
        usdg.mint(payer, amount);
        Pre memory pre = _pre(NOBODY);
        vm.prank(payer);
        try market.repay(amount, account) {
            okMarketRepay++;
        } catch {}
        _escrowUntouched(pre, account);
    }

    /// @dev The liquidator trims whoever is eligible; trims never touch escrowed funds.
    function trim(uint256 accountSeed, uint256 maxRepay) external {
        _flow(accountSeed ^ maxRepay);
        address account = borrowers[accountSeed % 5];
        maxRepay = bound(maxRepay, 1, 20_000 * USDG);
        usdg.mint(liquidator, maxRepay);
        Pre memory pre = _pre(NOBODY);
        vm.prank(liquidator);
        try market.trim(account, maxRepay, 0, block.timestamp) {
            okTrim++;
        } catch {}
        _escrowUntouched(pre, account);
    }

    /// @dev Tokens sent to the escrow directly are credited to nobody.
    function donate(uint256 amount) external {
        _flow(amount);
        amount = bound(amount, 1, 500 * USDG);
        usdg.mint(donor, amount);
        Pre memory pre = _pre(NOBODY);
        vm.prank(donor);
        usdg.transfer(address(escrow), amount);
        okDonate++;
        _othersUnchanged(pre, NOBODY, NOBODY);
        ghostDonated += amount;
    }

    // ---------------------------------------------------------------- execution checks

    function _execute(address caller, address account) internal {
        Exec memory x;
        x.s = policy.evaluate(gate.refresh(), clock.time());
        x.debt = market.debtOf(account);
        x.value = gate.valueOf(market.collateralOf(account), x.s.priceWad);
        x.expected = escrow.executableAmount(account, x.s, x.debt, x.value);
        x.plan = escrow.planOf(account);
        x.callerWallet = usdg.balanceOf(caller);
        x.cash = market.cash();
        x.collateral = market.collateralOf(account);
        x.pre = _pre(account);

        bool ok;
        uint256 repaid;
        if (caller == address(attacker)) {
            try attacker.executeBuffer(account) returns (uint256 r) {
                (ok, repaid) = (true, r);
            } catch {}
        } else {
            vm.prank(caller);
            try escrow.executeBuffer(account) returns (uint256 r) {
                (ok, repaid) = (true, r);
            } catch {}
        }
        if (!ok) {
            if (x.expected != 0) bufferViewMismatch++;
            else bufferNothing++;
            return;
        }
        okBuffer++;
        _checkWindowAndSpend(account, x, repaid);
        _checkDebtAndTarget(account, x, repaid);
        // The caller gains nothing, collateral stays, cash and the escrow move by exactly the amount.
        if (usdg.balanceOf(caller) != x.callerWallet) callerPaid++;
        if (market.collateralOf(account) != x.collateral) callerPaid++;
        if (market.cash() != x.cash + repaid || usdg.balanceOf(address(escrow)) + repaid != x.pre.held) {
            cashMismatch++;
        }
        _othersUnchanged(x.pre, account, account);
        ghostBalance[account] = _sub(ghostBalance[account], repaid);
        ghostRepaid += repaid;
    }

    function _checkWindowAndSpend(address account, Exec memory x, uint256 repaid) internal {
        if (!x.s.canBuffer || x.plan.targetWad == 0 || x.s.time >= x.plan.expiry) bufferOutsideWindow++;
        if (repaid != x.expected) bufferViewMismatch++;
        RepaymentEscrow.Plan memory p = escrow.planOf(account);
        if (repaid > x.plan.balance || p.balance + repaid != x.plan.balance) bufferOverBalance++;
        uint256 sid = x.s.session + 1;
        uint256 spentBefore = x.plan.spentSession == sid ? x.plan.spent : 0;
        if (p.spentSession != sid || p.spent != spentBefore + repaid || p.spent > x.plan.perSessionCap) {
            bufferOverCap++;
        }
        if (p.targetWad != x.plan.targetWad || p.perSessionCap != x.plan.perSessionCap || p.expiry != x.plan.expiry) {
            authMismatch++;
        }
    }

    function _checkDebtAndTarget(address account, Exec memory x, uint256 repaid) internal {
        uint256 minLoan = market.minLoan();
        uint256 debtAfter = market.debtOf(account);
        if (repaid > x.debt || !_exactReduction(x.debt, repaid, debtAfter)) debtMismatch++;
        if (debtAfter != 0 && debtAfter < minLoan) dustLeft++;
        uint256 need = _need(x.debt, x.value, x.plan.targetWad);
        if (repaid > need) {
            // Past the target only as the minimum-loan rule's full repayment of a debt within minLoan of it.
            okBufferFull++;
            if (debtAfter != 0 || need > x.debt || x.debt - need >= minLoan) bufferPastTarget++;
        } else if (repaid == need) {
            okBufferToTarget++;
            if (debtAfter * WAD > x.plan.targetWad * x.value + WAD) bufferMissedTarget++;
        } else {
            // Short of the target only when the balance or the session allowance ran out, or at the minimum loan.
            okBufferShort++;
            uint256 sid = x.s.session + 1;
            uint256 spentBefore = x.plan.spentSession == sid ? x.plan.spent : 0;
            uint256 allowance = x.plan.perSessionCap > spentBefore ? x.plan.perSessionCap - spentBefore : 0;
            if (repaid != Math.min(x.plan.balance, allowance) && repaid + minLoan != x.debt) bufferMissedTarget++;
        }
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Owner-side callers: the four wallets, the attacker contract, mallory and the keeper.
    function _caller(uint256 seed_) internal view returns (address) {
        uint256 i = seed_ % 7;
        if (i < 5) return borrowers[i];
        return i == 5 ? mallory : keeper;
    }

    /// @dev Mostly the caller itself; otherwise a friend, mallory, another wallet, the attacker or the escrow.
    function _receiver(uint256 seed_, address caller) internal view returns (address) {
        uint256 i = seed_ % 8;
        if (i < 3) return caller;
        if (i == 3) return friend;
        if (i == 4) return mallory;
        if (i == 5) return borrowers[(seed_ >> 8) % 4];
        if (i == 6) return address(attacker);
        return address(escrow);
    }

    function _isSink(address a) internal view returns (bool) {
        return a == address(0) || a == address(escrow) || a == address(market);
    }

    function _withdrawAs(address caller, uint256 amount, address receiver) internal returns (bool ok, bytes4 err) {
        if (caller == address(attacker)) {
            try attacker.withdraw(amount, receiver) {
                ok = true;
            } catch (bytes memory e) {
                err = bytes4(e);
            }
            return (ok, err);
        }
        vm.prank(caller);
        try escrow.withdraw(amount, receiver) {
            ok = true;
        } catch (bytes memory e) {
            err = bytes4(e);
        }
    }

    function _ownerRepayAs(address caller, uint256 amount) internal returns (bool ok, uint256 repaid) {
        if (caller == address(attacker)) {
            try attacker.ownerRepay(amount) returns (uint256 r) {
                (ok, repaid) = (true, r);
            } catch {}
            return (ok, repaid);
        }
        vm.prank(caller);
        try escrow.ownerRepay(amount) returns (uint256 r) {
            (ok, repaid) = (true, r);
        } catch {}
    }

    function _pre(address subject) internal view returns (Pre memory pre) {
        pre.plan = escrow.planOf(subject);
        pre.plans = new bytes32[](tracked.length);
        for (uint256 i; i < tracked.length; ++i) {
            pre.plans[i] = keccak256(abi.encode(escrow.planOf(tracked[i])));
        }
        for (uint256 i; i < 5; ++i) {
            pre.debts[i] = market.debtOf(borrowers[i]);
        }
        pre.held = usdg.balanceOf(address(escrow));
    }

    /// @dev Every plan except `planOwner`'s and every debt except `debtOwner`'s is as it was.
    function _othersUnchanged(Pre memory pre, address planOwner, address debtOwner) internal {
        for (uint256 i; i < tracked.length; ++i) {
            if (tracked[i] != planOwner && keccak256(abi.encode(escrow.planOf(tracked[i]))) != pre.plans[i]) {
                foreignPlanChanged++;
            }
        }
        for (uint256 i; i < 5; ++i) {
            if (borrowers[i] != debtOwner && market.debtOf(borrowers[i]) != pre.debts[i]) foreignDebtChanged++;
        }
    }

    /// @dev A market action left every plan and the escrow's tokens alone, and no debt but `account`'s moved.
    function _escrowUntouched(Pre memory pre, address account) internal {
        _othersUnchanged(pre, NOBODY, account);
        if (usdg.balanceOf(address(escrow)) != pre.held) cashMismatch++;
    }

    function _sameAuthorization(RepaymentEscrow.Plan memory a, RepaymentEscrow.Plan memory b)
        internal
        pure
        returns (bool)
    {
        return a.targetWad == b.targetWad && a.perSessionCap == b.perSessionCap && a.expiry == b.expiry
            && a.spent == b.spent && a.spentSession == b.spentSession;
    }

    /// @dev The market applied exactly `repaid`: a full repayment clears the debt, a partial one leaves the debt
    /// less `repaid`, or one base unit more from share rounding.
    function _exactReduction(uint256 debt, uint256 repaid, uint256 debtAfter) internal pure returns (bool) {
        if (repaid == debt) return debtAfter == 0;
        return debtAfter + repaid >= debt && debtAfter + repaid <= debt + 1;
    }

    function _need(uint256 debt, uint256 value, uint256 target) internal pure returns (uint256) {
        if (debt * WAD <= target * value) return 0;
        return Math.ceilDiv(debt * WAD - target * value, WAD);
    }

    function _sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Time passes between actions: 1 to 8 minutes. Between sessions, three times in four, cross to the next
    /// open and reopen fully with a gap move of up to 5%; otherwise a move of up to 0.5% either way.
    function _flow(uint256 r) internal {
        calls++;
        vm.warp(block.timestamp + 1 minutes + (r % 8 minutes));
        SessionCalendar.Context memory c = cal.context(clock.time());
        if (c.covered && !c.inSession && (r >> 32) % 4 != 0) {
            _reopen(c, int256((r >> 64) % 1_001) - 500);
            return;
        }
        _move(int256((r >> 16) % 101) - 50);
        _publish();
    }

    /// @dev Move to the next open: admission at O + 5 min after a gap move, full credit at O + 15 min.
    function _reopen(SessionCalendar.Context memory c, int256 gapBps) internal {
        vm.warp(c.nextOpen + 5 minutes);
        _move(gapBps);
        _publish();
        vm.warp(c.nextOpen + 15 minutes);
        _publish();
    }

    /// @dev Move the price by `bps`, kept between 300 and 500 USD.
    function _move(int256 bps) internal {
        answer = answer * (10_000 + bps) / 10_000;
        if (answer < 300e8) answer = 300e8;
        if (answer > 500e8) answer = 500e8;
    }

    function _publish() internal {
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
    }

    function _mintTsla(address to, uint256 amount) internal {
        vm.prank(owner);
        tsla.mint(to, amount);
    }
}

/// @notice Fund security of RepaymentEscrow under a hooked loan token, with several owners, a keeper, strangers, an
/// attacker contract and the market acting across real sessions.
contract EscrowInvariantsTest is GateFixture {
    uint64 internal constant FRI_OPEN = 1789133400;
    uint256 internal constant USDG = 1e6;

    EscrowInvHookedUSDG internal husdg;
    SessionRiskPolicy internal policy;
    StockReefMarket internal market;
    RepaymentEscrow internal escrow;
    EscrowHandler internal handler;
    address[] internal accounts;

    function setUp() public {
        vm.warp(FRI_OPEN - 1 hours);
        cal = _deployCalendar();
        clock = new DemoClock(address(this));
        stockFeed = new MockAggregatorV3(8, "Simulated TSLA/USD", clock, address(this));
        tsla = new MockStockToken("Tesla Stock Token", "TSLA", true);
        husdg = new EscrowInvHookedUSDG();
        PriceGate.Config memory c = _config();
        c.loanToken = address(husdg);
        gate = new PriceGate(c);
        policy = new SessionRiskPolicy(gate);
        market = new StockReefMarket(husdg, tsla, policy, 5 * USDG, "StockReef hUSDG", "srH");
        escrow = market.escrow();
        _freshRefresh(FRI_OPEN + 5 minutes);
        _freshRefresh(FRI_OPEN + 15 minutes);

        address lender = makeAddr("lender");
        husdg.mint(lender, 500_000 * USDG);
        vm.startPrank(lender);
        husdg.approve(address(market), type(uint256).max);
        market.deposit(500_000 * USDG, lender);
        vm.stopPrank();

        handler = new EscrowHandler(market, stockFeed, tsla, husdg, address(this));
        handler.seed();
        accounts = handler.trackedAccounts();

        bytes4[] memory actions = new bytes4[](13);
        actions[0] = EscrowHandler.tick.selector;
        actions[1] = EscrowHandler.toPreparation.selector;
        actions[2] = EscrowHandler.toNextSession.selector;
        actions[3] = EscrowHandler.deposit.selector;
        actions[4] = EscrowHandler.withdraw.selector;
        actions[5] = EscrowHandler.ownerRepay.selector;
        actions[6] = EscrowHandler.authorize.selector;
        actions[7] = EscrowHandler.executeBuffer.selector;
        actions[8] = EscrowHandler.keeperRound.selector;
        actions[9] = EscrowHandler.borrow.selector;
        actions[10] = EscrowHandler.marketRepay.selector;
        actions[11] = EscrowHandler.trim.selector;
        actions[12] = EscrowHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("calls", handler.calls(), "deposit", handler.okDeposit());
        console.log("thirdPartyDeposit", handler.okThirdPartyDeposit(), "sinkDeposit", handler.okSinkDeposit());
        console.log("withdraw", handler.okWithdraw(), "elsewhere", handler.okWithdrawElsewhere());
        console.log("selfWithdraw", handler.okSelfWithdraw(), "donate", handler.okDonate());
        console.log("authorize", handler.okAuthorize(), "cancel", handler.okCancel());
        console.log("ownerRepay", handler.okOwnerRepay(), "blockedByCommitment", handler.blockedByCommitment());
        console.log("strangerRefused", handler.strangerRefused(), "buffer", handler.okBuffer());
        console.log("toTarget", handler.okBufferToTarget(), "short", handler.okBufferShort());
        console.log("minLoanFull", handler.okBufferFull(), "bufferNothing", handler.bufferNothing());
        console.log("trim", handler.okTrim(), "borrow", handler.okBorrow());
        console.log("marketRepay", handler.okMarketRepay(), "hooks", handler.attacker().hookCalls());
    }

    /// INV-ESC-01, INV-ESC-03
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_escrowHoldsEveryPlanBalancePlusAnUnspendableSurplus() public view {
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            sum += escrow.planOf(accounts[i]).balance;
        }
        uint256 held = husdg.balanceOf(address(escrow));
        assertGe(held, sum, "escrow holds at least every plan balance");
        assertEq(held, sum + handler.ghostDonated() + handler.ghostSelfWithdrawn(), "surplus is donations only");
        assertEq(
            held + handler.ghostPaidOut() + handler.ghostRepaid(),
            handler.ghostIn() + handler.ghostDonated(),
            "tokens left only to withdrawal receivers or into the market"
        );
    }

    /// INV-ESC-02, INV-ESC-03, INV-ESC-19, INV-X-20
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_planBalancesMoveOnlyByExactAmountsOfTheirOwnActions() public view {
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(escrow.planOf(accounts[i]).balance, handler.ghostBalance(accounts[i]), "plan balance ledger");
        }
        assertEq(handler.wrongCredit(), 0, "deposits credit exactly the named account");
        assertEq(handler.depositRejected(), 0, "anyone may deposit for any account at any time");
        assertEq(handler.wrongPayout(), 0, "withdrawals pay exactly the chosen receiver");
        assertEq(handler.repayMismatch(), 0, "ownerRepay takes min(amount, debt) from the caller's plan");
        assertEq(handler.cashMismatch(), 0, "escrow tokens move only by the amounts repaid or withdrawn");
    }

    /// INV-ESC-03, INV-ESC-04, INV-ESC-05, INV-ESC-17, INV-X-20
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_onlyTheOwnerMovesOrControlsItsPlan() public view {
        assertEq(handler.foreignPlanChanged(), 0, "no action changes another account's plan");
        assertEq(handler.foreignDebtChanged(), 0, "no repayment cuts another account's debt");
        assertEq(handler.overdraft(), 0, "nobody takes more than its own balance");
        assertEq(handler.withdrawRejected(), 0, "an uncommitted owner can always withdraw its own balance");
        assertEq(handler.authMismatch(), 0, "authorize and cancel write exactly the caller's authorization");
        assertEq(handler.authorizeRejected(), 0, "an uncommitted owner can always authorize or cancel");
        assertEq(handler.callerPaid(), 0, "executeBuffer pays its caller nothing and moves no collateral");
    }

    /// INV-ESC-11, INV-ESC-12, INV-ESC-13, INV-ESC-14, INV-ESC-15, INV-ESC-16, INV-ESC-05, INV-X-15
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_buffersStayWithinWindowCapBalanceAndTarget() public view {
        assertEq(handler.bufferOutsideWindow(), 0, "only with canBuffer and an active plan");
        assertEq(handler.bufferOverBalance(), 0, "never past the plan balance");
        assertEq(handler.bufferOverCap(), 0, "never past the per-session cap");
        assertEq(handler.bufferPastTarget(), 0, "never below the target but for the bounded minimum-loan rule");
        assertEq(handler.bufferMissedTarget(), 0, "short of the target only when funds or allowance run out");
        assertEq(handler.bufferViewMismatch(), 0, "execution agrees with executableAmount");
        assertEq(handler.debtMismatch(), 0, "the owner's debt falls by exactly the amount taken from its plan");
        assertEq(handler.dustLeft(), 0, "no repayment leaves debt below the minimum loan");
    }

    /// INV-ESC-07, INV-ESC-08, INV-X-14
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_commitmentFollowsTheSchedulePhase() public view {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 maxTarget = escrow.MAX_TARGET();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            RepaymentEscrow.Plan memory p = escrow.planOf(a);
            bool active = p.targetWad != 0 && s.time < p.expiry;
            bool expected = active && market.debtOf(a) != 0 && s.phase != SessionRiskPolicy.State.OPEN && !s.windDown;
            assertEq(escrow.committed(a), expected, "committed iff active, indebted and outside the OPEN phase");
            assertEq(p.targetWad == 0, p.perSessionCap == 0, "authorization fields all set or all clear");
            assertEq(p.targetWad == 0, p.expiry == 0, "authorization fields all set or all clear");
            assertLe(p.targetWad, maxTarget);
        }
        assertEq(handler.committedBypass(), 0, "no withdraw, cancel or authorize while committed");
    }

    /// INV-ESC-06, INV-X-09
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 200
    function invariant_noApprovalLeftAndReentryMovesNothing() public view {
        assertEq(husdg.allowance(address(escrow), address(market)), 0, "no approval outlives a repayment");
        assertEq(handler.attacker().fundMoves(), 0, "no re-entered call moved funds");
    }
}
