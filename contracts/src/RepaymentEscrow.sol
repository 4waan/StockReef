// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IClock} from "./interfaces/IClock.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {StockReefMarket} from "./StockReefMarket.sol";

/// @title RepaymentEscrow
/// @notice Borrower-owned loan tokens set aside to repay debt before a close (docs/SPEC.md §4, appendix R2).
/// Escrowed funds are neither lender liquidity nor collateral and earn nothing. A borrower authorizes a plan
/// (target LTV, spending cap per session, expiry); anyone can then execute it during PRE_CLOSE or
/// FINAL_WINDOW with a valid price. Execution only repays debt, never sells collateral, and pays no reward.
contract RepaymentEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Plan {
        uint256 balance; // escrowed loan tokens, base units
        uint256 targetWad; // repay toward this LTV; at most MAX_TARGET
        uint256 perSessionCap; // most a plan may spend in one session, base units
        uint64 expiry; // authorization ends at this clock time
        uint32 spentSession; // calendar session index + 1 that `spent` refers to
        uint256 spent; // spent in `spentSession`
    }

    uint256 internal constant WAD = 1e18;
    /// @dev The deepest closure target (EXTENDED class). Plans may target lower, never higher.
    uint256 public constant MAX_TARGET = 0.65e18;

    StockReefMarket public immutable market;
    IERC20 public immutable loanToken;
    PriceGate public immutable gate;
    SessionRiskPolicy public immutable policy;
    IClock public immutable clock;

    mapping(address => Plan) internal _plans;

    event Deposited(address indexed account, address indexed payer, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Authorized(address indexed account, uint256 targetWad, uint256 perSessionCap, uint64 expiry);
    event Cancelled(address indexed account);
    event BufferExecuted(
        address indexed account,
        address indexed caller,
        uint256 indexed session,
        uint256 repaid,
        uint256 debtBefore,
        uint256 debtAfter
    );
    event OwnerRepaid(address indexed account, uint256 repaid);

    error ZeroAmount();
    error TargetTooHigh(uint256 targetWad, uint256 maxWad);
    error BadAuthorization();
    error Committed();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NotAuthorized();
    error NotAllowedNow(SessionRiskPolicy.State state, uint32 reasons);
    error NothingToRepay();
    error UnsupportedTransfer(uint256 expected, uint256 received);

    constructor(StockReefMarket market_, IERC20 loanToken_, SessionRiskPolicy policy_) {
        market = market_;
        loanToken = loanToken_;
        policy = policy_;
        gate = policy_.gate();
        clock = policy_.clock();
    }

    // ---------------------------------------------------------------- owner actions

    /// @notice Add loan tokens to `account`'s escrow. Allowed at any time.
    function deposit(uint256 amount, address account) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = loanToken.balanceOf(address(this));
        loanToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = loanToken.balanceOf(address(this)) - before;
        if (received != amount) revert UnsupportedTransfer(amount, received);
        _plans[account].balance += amount;
        emit Deposited(account, msg.sender, amount);
    }

    /// @notice Authorize anyone to repay the caller's debt from escrow toward `targetWad` during preparation.
    /// Allowed only while the plan is not committed.
    function authorize(uint256 targetWad, uint256 perSessionCap, uint64 expiry) external {
        if (targetWad > MAX_TARGET) revert TargetTooHigh(targetWad, MAX_TARGET);
        if (targetWad == 0 || perSessionCap == 0 || expiry <= clock.time()) revert BadAuthorization();
        if (committed(msg.sender)) revert Committed();
        Plan storage p = _plans[msg.sender];
        p.targetWad = targetWad;
        p.perSessionCap = perSessionCap;
        p.expiry = expiry;
        emit Authorized(msg.sender, targetWad, perSessionCap, expiry);
    }

    /// @notice Cancel the authorization. Allowed only while the plan is not committed.
    function cancel() external {
        if (committed(msg.sender)) revert Committed();
        Plan storage p = _plans[msg.sender];
        p.targetWad = 0;
        p.perSessionCap = 0;
        p.expiry = 0;
        emit Cancelled(msg.sender);
    }

    /// @notice Withdraw escrowed funds. Allowed only while the plan is not committed.
    function withdraw(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (committed(msg.sender)) revert Committed();
        Plan storage p = _plans[msg.sender];
        if (amount > p.balance) revert InsufficientBalance(amount, p.balance);
        p.balance -= amount;
        loanToken.safeTransfer(receiver, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Repay a fixed amount of the caller's own debt from escrow, in any state. Needs no price.
    function ownerRepay(uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();
        Plan storage p = _plans[msg.sender];
        if (amount > p.balance) revert InsufficientBalance(amount, p.balance);
        repaid = _repay(msg.sender, amount);
        p.balance -= repaid;
        emit OwnerRepaid(msg.sender, repaid);
    }

    // ---------------------------------------------------------------- execution

    /// @notice Repay `account`'s debt toward its authorized target from escrow. Permissionless and unrewarded.
    function executeBuffer(address account) external nonReentrant returns (uint256 repaid) {
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(gate.refresh(), clock.time());
        if (!s.canBuffer) revert NotAllowedNow(s.state, s.reasons);
        Plan storage p = _plans[account];
        if (!_active(p, s.time)) revert NotAuthorized();

        uint256 debt = market.debtOf(account);
        uint256 value = gate.valueOf(market.collateralOf(account), s.priceWad);
        uint256 amount = _executableAmount(p, s, debt, value);
        if (amount == 0) revert NothingToRepay();

        uint32 sid = uint32(s.session + 1);
        if (p.spentSession != sid) {
            p.spentSession = sid;
            p.spent = 0;
        }
        repaid = _repay(account, amount);
        p.balance -= repaid;
        p.spent += repaid;
        emit BufferExecuted(account, msg.sender, s.session, repaid, debt, debt - repaid);
    }

    // ---------------------------------------------------------------- views

    function planOf(address account) external view returns (Plan memory) {
        return _plans[account];
    }

    /// @notice True while authorized funds are committed: an active authorization, debt outstanding, and the
    /// schedule anywhere other than the OPEN phase (before A, after a valid full reopening). It follows the
    /// schedule phase, not the effective state, so a price outage or a guardian stop never freezes escrow. After
    /// the calendar has ended (wind-down) buffers can never execute again, so plans are released.
    function committed(address account) public view returns (bool) {
        Plan storage p = _plans[account];
        if (!_active(p, clock.time()) || market.debtOf(account) == 0) return false;
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        return s.phase != SessionRiskPolicy.State.OPEN && !s.windDown;
    }

    /// @notice Borrowing from A onward is rejected while an authorization is active.
    function blocksBorrowing(address account, SessionRiskPolicy.Snapshot memory s) external view returns (bool) {
        return _active(_plans[account], s.time) && s.time >= s.prepAt;
    }

    /// @notice True when `executeBuffer(account)` would repay something now. Trims wait for it.
    function executable(address account, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        external
        view
        returns (bool)
    {
        Plan storage p = _plans[account];
        return s.canBuffer && _active(p, s.time) && _executableAmount(p, s, debt, value) != 0;
    }

    /// @notice What `executeBuffer` would repay for `account` at snapshot `s`.
    function executableAmount(address account, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        external
        view
        returns (uint256)
    {
        Plan storage p = _plans[account];
        if (!s.canBuffer || !_active(p, s.time)) return 0;
        return _executableAmount(p, s, debt, value);
    }

    // ---------------------------------------------------------------- internals

    function _active(Plan storage p, uint64 t) internal view returns (bool) {
        return p.targetWad != 0 && t < p.expiry;
    }

    /// @dev min(cash needed to reach the target, balance, remaining session allowance).
    /// Cash needed: D - T*V, rounded up.
    function _executableAmount(Plan storage p, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        internal
        view
        returns (uint256)
    {
        if (debt * WAD <= p.targetWad * value) return 0;
        uint256 need = Math.ceilDiv(debt * WAD - p.targetWad * value, WAD);
        uint256 spent = p.spentSession == uint32(s.session + 1) ? p.spent : 0;
        uint256 allowance = p.perSessionCap > spent ? p.perSessionCap - spent : 0;
        uint256 available = Math.min(p.balance, allowance);
        uint256 amount = Math.min(need, available);
        // Never leave dust below the minimum loan: repay in full if funds allow, else stop at the minimum.
        uint256 minLoan = market.minLoan();
        if (amount < debt && debt - amount < minLoan) {
            if (available >= debt) return debt;
            return debt > minLoan ? debt - minLoan : 0;
        }
        return amount;
    }

    function _repay(address account, uint256 amount) internal returns (uint256) {
        loanToken.forceApprove(address(market), amount);
        uint256 repaid = market.repay(amount, account);
        loanToken.forceApprove(address(market), 0);
        return repaid;
    }
}
