// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IClock} from "./interfaces/IClock.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {StockReefMarket} from "./StockReefMarket.sol";
import {SessionRules} from "./libraries/SessionRules.sol";
import {StockReefMath} from "./libraries/StockReefMath.sol";

/// @title RepaymentEscrow
/// @notice Holds loan tokens (USDG) that borrowers set aside to repay their own debt before a close
/// (docs/SPEC.md §4 "Prefunded buffer", appendix R2, R16 and R17). Escrowed funds belong to the borrower: they
/// are neither lender liquidity nor collateral, and they earn nothing. A borrower authorizes a plan (target LTV,
/// spending cap per session, expiry); anyone can then call `executeBuffer` during preparation (PRE_CLOSE and
/// FINAL_WINDOW) or reopening recovery with a usable price to repay that borrower's debt toward the target
/// (appendix R20). Execution only repays debt, never sells collateral and pays no reward. A borrower can also repay
/// from escrow at any time, up to an amount of its choosing, with no price.
/// @dev StockReefMarket's constructor deploys one escrow per market. Units: loan amounts and balances in loan-token
/// base units (USDG: 6 decimals); collateral in raw stock-token units (18 decimals); targets, LTVs and `priceWad`
/// in WAD (1e18 = 100% or 1.0); times are UTC seconds from `clock` (DemoClock on demo deployments).
///
/// Trust: `market`, `gate`, `policy` and `clock` are immutable StockReef contracts and are trusted. There is no
/// admin role. A plan's balance leaves only through its owner's `withdraw` or `ownerRepay`, or through
/// `executeBuffer` under the owner's active authorization; both repayment paths pay `market` for that account's
/// debt, through an approval of exactly the amount that is reset to zero afterwards. Issuer transfer restrictions
/// on the loan token can still block any of these transfers (docs/SPEC.md §4 "Ordering with liquidation").
///
/// Invariants:
/// - for a loan token that moves exact amounts, the sum of plan balances never exceeds this contract's loan-token
///   balance: deposits must arrive in full, every outflow debits a plan by the amount sent, and tokens sent here
///   directly are credited to no plan;
/// - every repayment is capped at the account's current debt, so the market takes exactly the amount requested;
///   balances are updated before the market call, and every state-changing token path is `nonReentrant`;
/// - while a plan is committed (see `committed`) its owner cannot re-authorize, cancel or withdraw.
contract RepaymentEscrow is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StockReefMath for uint256;

    /// @notice One account's escrow balance and buffer authorization. The authorization is active while
    /// `targetWad` is non-zero and the clock is before `expiry`; `cancel` clears it but keeps the balance.
    struct Plan {
        uint256 balance; // escrowed loan tokens, base units
        uint256 targetWad; // repay toward this LTV, WAD; zero means no authorization; at most MAX_TARGET
        uint256 perSessionCap; // most executeBuffer may spend in one calendar session, base units
        uint64 expiry; // authorization ends at this clock time, UTC seconds (active while time < expiry)
        uint32 spentSession; // calendar session index + 1 that `spent` refers to; zero before any execution
        uint256 spent; // spent in `spentSession` by executeBuffer, base units; ownerRepay is not counted
    }

    /// @notice Highest LTV target a plan may authorize, WAD (0.65e18 = 65%; appendix R2).
    /// @dev The deepest closure target (EXTENDED class, SessionRiskPolicy.TARGET_EXTENDED). Plans may target lower,
    /// never higher.
    uint256 public constant MAX_TARGET = SessionRules.TARGET_EXTENDED;

    /// @notice Market whose debt this escrow repays; it deployed this escrow.
    StockReefMarket public immutable market;
    /// @notice Token held in escrow and used for repayment: the market's loan token (USDG, 6 decimals).
    IERC20 public immutable loanToken;
    /// @notice Price gate, taken from `policy`; `executeBuffer` refreshes it and values collateral at its price.
    PriceGate public immutable gate;
    /// @notice Session policy that decides when buffers may execute and which schedule phase applies.
    SessionRiskPolicy public immutable policy;
    /// @notice Time source, taken from `policy` (DemoClock on demo deployments); UTC seconds.
    IClock public immutable clock;
    /// @dev PriceGate.VALUE_SCALE, read at deployment: collateral value is raw * priceWad / VALUE_SCALE.
    uint256 private immutable VALUE_SCALE;

    /// @dev Plan of each account, keyed by the borrower's address.
    mapping(address => Plan) internal _plans;

    /// @notice Loan tokens were added to `account`'s escrow balance.
    /// @param account Plan owner credited with the deposit.
    /// @param payer Address the tokens came from (the caller).
    /// @param amount Amount credited, loan-token base units.
    event Deposited(address indexed account, address indexed payer, uint256 amount);
    /// @notice A plan owner withdrew loan tokens from its escrow balance. The receiver is not logged.
    /// @param account Plan owner whose balance fell (the caller).
    /// @param amount Amount withdrawn, loan-token base units.
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice A plan owner set or replaced its buffer authorization.
    /// @param account Plan owner (the caller).
    /// @param targetWad LTV the buffer repays toward, WAD.
    /// @param perSessionCap Most `executeBuffer` may spend in one calendar session, loan-token base units.
    /// @param expiry Clock time at which the authorization ends, UTC seconds.
    event Authorized(address indexed account, uint256 targetWad, uint256 perSessionCap, uint64 expiry);
    /// @notice A plan owner cleared its buffer authorization; its escrow balance is unchanged.
    /// @param account Plan owner (the caller).
    event Cancelled(address indexed account);
    /// @notice A buffer execution repaid `account`'s debt from its escrow balance.
    /// @param account Borrower whose debt was repaid.
    /// @param caller Address that called `executeBuffer`; it receives nothing.
    /// @param session Calendar index of the session in which the buffer ran.
    /// @param repaid Amount taken from escrow and paid to the market, loan-token base units.
    /// @param debtBefore Debt including interest before the repayment, loan-token base units, rounded up
    /// (StockReefMarket.debtOf).
    /// @param debtAfter `debtBefore - repaid`, loan-token base units. After share rounding the market's recorded
    /// debt can be one base unit higher; the market's Repaid event logs that figure.
    event BufferExecuted(
        address indexed account,
        address indexed caller,
        uint256 indexed session,
        uint256 repaid,
        uint256 debtBefore,
        uint256 debtAfter
    );
    /// @notice A plan owner repaid its own debt from its escrow balance with `ownerRepay`.
    /// @param account Plan owner and borrower (the caller).
    /// @param repaid Amount taken from escrow and paid to the market, loan-token base units.
    event OwnerRepaid(address indexed account, uint256 repaid);

    /// @notice An amount of zero was passed to `deposit`, `withdraw` or `ownerRepay`.
    error ZeroAmount();
    /// @notice `authorize` was called with a target above MAX_TARGET.
    /// @param targetWad Requested target, WAD.
    /// @param maxWad MAX_TARGET, WAD.
    error TargetTooHigh(uint256 targetWad, uint256 maxWad);
    /// @notice `authorize` was called with a zero target, a zero per-session cap, or an expiry at or before the
    /// current clock time.
    error BadAuthorization();
    /// @notice The caller's plan is committed (see `committed`), so it cannot be re-authorized, cancelled or
    /// withdrawn from at this time.
    error Committed();
    /// @notice The requested amount exceeds the caller's escrow balance.
    /// @param requested Amount asked for, loan-token base units.
    /// @param available The caller's escrow balance, loan-token base units.
    error InsufficientBalance(uint256 requested, uint256 available);
    /// @notice `executeBuffer` was called for an account without an active authorization (none, cancelled or
    /// expired).
    error NotAuthorized();
    /// @notice Buffers cannot execute now: the effective state is not PRE_CLOSE, FINAL_WINDOW or REOPEN_RECOVERY, for
    /// example because the time is outside preparation and recovery, the price is unusable or the guardian has
    /// stopped the gate.
    /// @param state Effective market state from SessionRiskPolicy.
    /// @param reasons PriceGate Reasons bits; zero when the price is usable.
    error NotAllowedNow(SessionRiskPolicy.State state, uint32 reasons);
    /// @notice Nothing can be repaid: the account has no debt, the plan has no executable amount, or the market
    /// took a different amount than requested.
    error NothingToRepay();
    /// @notice An account or receiver is the zero address.
    error ZeroAddress();
    /// @notice A deposit did not arrive in full; fee-on-transfer and similar token behavior is not supported.
    /// @param expected Amount requested, loan-token base units.
    /// @param received Amount that arrived, loan-token base units.
    error UnsupportedTransfer(uint256 expected, uint256 received);

    /// @notice Bind the escrow to its market, loan token and session policy. StockReefMarket's constructor deploys
    /// it with its own loan token and policy.
    /// @dev `gate`, `clock` and the gate's VALUE_SCALE are read from `policy_`. Nothing is checked here; the market
    /// checks the gate's tokens against its own before deploying the escrow.
    /// @param market_ Market whose debt the escrow repays.
    /// @param loanToken_ Token held in escrow; must be the market's loan token.
    /// @param policy_ Session policy shared with the market.
    constructor(StockReefMarket market_, IERC20 loanToken_, SessionRiskPolicy policy_) {
        market = market_;
        loanToken = loanToken_;
        policy = policy_;
        gate = policy_.gate();
        clock = policy_.clock();
        VALUE_SCALE = gate.VALUE_SCALE();
    }

    // ---------------------------------------------------------------- owner actions

    /// @notice Add loan tokens to `account`'s escrow balance. Anyone may deposit for any account, in any state and
    /// with no price; the funds then belong to `account`, and only `account` can withdraw them. A deposit does not
    /// authorize execution by itself (docs/SPEC.md §4).
    /// @dev Pulls `amount` from the caller, which needs an allowance, and requires exactly `amount` to arrive.
    /// Reverts with ZeroAmount for a zero amount, ZeroAddress for a zero `account`, and UnsupportedTransfer when a
    /// different amount arrives.
    /// @param amount Amount to deposit, loan-token base units.
    /// @param account Plan owner to credit; not the zero address.
    function deposit(uint256 amount, address account) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (account == address(0)) revert ZeroAddress();
        uint256 before = loanToken.balanceOf(address(this));
        loanToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = loanToken.balanceOf(address(this)) - before;
        if (received != amount) revert UnsupportedTransfer(amount, received);
        _plans[account].balance += amount;
        emit Deposited(account, msg.sender, amount);
    }

    /// @notice Authorize anyone to repay the caller's debt from the caller's escrow toward `targetWad` during
    /// preparation (PRE_CLOSE and FINAL_WINDOW) and reopening recovery, spending at most `perSessionCap` per calendar session, until
    /// `expiry` (docs/SPEC.md §4, appendix R2). Replaces any earlier authorization. Allowed only while the
    /// caller's plan is not committed.
    /// @dev Needs no balance. Keeps the spend already recorded for the current session, so re-authorizing within
    /// a session does not reset its allowance. While the authorization is active, the market rejects borrowing and
    /// debt-backed collateral withdrawal from A onward (see `blocksBorrowing`). Reverts with TargetTooHigh above
    /// MAX_TARGET, BadAuthorization for a zero target, a zero cap or an expiry not after the current clock time,
    /// and Committed.
    /// @param targetWad LTV to repay toward, WAD; non-zero and at most MAX_TARGET.
    /// @param perSessionCap Most that buffer executions may spend in one calendar session, loan-token base units;
    /// non-zero.
    /// @param expiry Clock time at which the authorization ends, UTC seconds; must be after the current time.
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

    /// @notice Cancel the caller's buffer authorization. The escrow balance stays and can be withdrawn. Allowed
    /// only while the caller's plan is not committed.
    /// @dev Clears the target, cap and expiry and keeps the per-session spend record. Succeeds, and emits
    /// Cancelled, even when no authorization exists. Reverts with Committed.
    function cancel() external {
        if (committed(msg.sender)) revert Committed();
        Plan storage p = _plans[msg.sender];
        p.targetWad = 0;
        p.perSessionCap = 0;
        p.expiry = 0;
        emit Cancelled(msg.sender);
    }

    /// @notice Withdraw loan tokens from the caller's escrow balance to `receiver`. Allowed only while the caller's
    /// plan is not committed: in the OPEN phase (after a valid full reopening and before A), with no debt, with no
    /// active authorization, or in wind-down (docs/SPEC.md §4, appendix R17). An expired authorization never
    /// blocks withdrawal.
    /// @dev Reverts with ZeroAmount, ZeroAddress, Committed or InsufficientBalance.
    /// @param amount Amount to withdraw, loan-token base units; at most the caller's balance.
    /// @param receiver Address that receives the tokens; not the zero address.
    function withdraw(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (committed(msg.sender)) revert Committed();
        Plan storage p = _plans[msg.sender];
        if (amount > p.balance) revert InsufficientBalance(amount, p.balance);
        p.balance -= amount;
        loanToken.safeTransfer(receiver, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Repay the caller's own debt from the caller's escrow, up to `amount`, in any state (including CLOSED,
    /// GUARDED and wind-down) and with no price (docs/SPEC.md §4). Works with no authorization, an expired one, or
    /// a committed plan. Pass type(uint256).max to repay everything the balance covers, including interest up to
    /// this second.
    /// @dev `amount` is a cap: the repayment is min(`amount`, balance, current debt including interest), so the
    /// caller never overpays and the rest stays in escrow. When that would leave non-zero debt below the market's
    /// minimum loan, it stops at exactly the minimum instead (appendix R16), never above the cap. Does not count
    /// toward the per-session buffer allowance. Reverts with ZeroAmount, or NothingToRepay when nothing can be
    /// repaid (no debt, no balance, or a debt at or below the minimum that the cap does not clear).
    /// @param amount Most to repay, loan-token base units; type(uint256).max for all.
    /// @return repaid Amount taken from escrow and repaid, loan-token base units.
    function ownerRepay(uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();
        Plan storage p = _plans[msg.sender];
        uint256 cap = Math.min(amount, p.balance);
        repaid = _withinMinimumLoan(cap, cap, market.debtOf(msg.sender));
        if (repaid == 0) revert NothingToRepay();
        p.balance -= repaid; // effects before the call; the market repays exactly this amount
        emit OwnerRepaid(msg.sender, repaid);
        _repay(msg.sender, repaid);
    }

    // ---------------------------------------------------------------- execution

    /// @notice Repay `account`'s debt from its escrow toward its authorized target. Anyone may call it; it pays no
    /// reward and never sells collateral (docs/SPEC.md §4, appendix R2 and R16).
    /// @dev Refreshes the gate (which may record reopening admission, outages or checkpoints), then evaluates the
    /// policy at the current clock time. Requires `canBuffer` (effective state PRE_CLOSE, FINAL_WINDOW or
    /// REOPEN_RECOVERY, so a usable price and no guardian stop) and an authorization active at that time. Debt includes interest;
    /// collateral is valued at the refreshed price, rounded down. The amount comes from `_executableAmount`: the
    /// cash needed to reach the target (rounded up), capped by the balance and the session allowance, then
    /// adjusted for the market's minimum loan; it is counted against this session's allowance. Reverts with
    /// NotAllowedNow, NotAuthorized, or NothingToRepay when the amount is zero.
    /// @param account Borrower whose plan executes.
    /// @return repaid Amount taken from escrow and repaid, loan-token base units.
    function executeBuffer(address account) external nonReentrant returns (uint256 repaid) {
        SessionRiskPolicy.Snapshot memory s = policy.evaluate(gate.refresh(), clock.time());
        if (!s.canBuffer) revert NotAllowedNow(s.state, s.reasons);
        Plan storage p = _plans[account];
        if (!_active(p, s.time)) revert NotAuthorized();

        (uint256 collateral,, uint256 debt) = market.accountOf(account);
        uint256 value = collateral.toValueDown(s.priceWad, VALUE_SCALE);
        uint256 amount = _executableAmount(p, s, debt, value);
        if (amount == 0) revert NothingToRepay();

        uint32 sid = uint32(s.session + 1);
        if (p.spentSession != sid) {
            p.spentSession = sid;
            p.spent = 0;
        }
        // `amount` never exceeds the debt, so the market repays exactly this amount: effects before the call.
        repaid = amount;
        p.balance -= repaid;
        p.spent += repaid;
        emit BufferExecuted(account, msg.sender, s.session, repaid, debt, debt - repaid);
        _repay(account, repaid);
    }

    // ---------------------------------------------------------------- views

    /// @notice The stored plan of `account`: balance, authorization and per-session spend record.
    /// @dev Raw storage: `spent` refers to `spentSession` and may belong to an earlier session, and an expired
    /// authorization still shows its target. Use `committed` and `executableAmount` for derived status.
    /// @param account Plan owner.
    /// @return The plan of `account`; see Plan for fields and units. All fields are zero until a deposit for it or
    /// an authorization by it.
    function planOf(address account) external view returns (Plan memory) {
        return _plans[account];
    }

    /// @notice True while authorized funds are committed: an active authorization, debt outstanding, and the
    /// schedule anywhere other than the OPEN phase (after a valid full reopening and before A). While committed, the
    /// owner cannot re-authorize, cancel or withdraw (docs/SPEC.md §4); full repayment or expiry releases the
    /// funds. After the calendar has ended (wind-down, appendix R17) buffers can never execute again, so plans are
    /// released.
    /// @dev Uses the schedule phase, not the effective state, so a price outage or a guardian stop during the OPEN
    /// phase does not commit funds. The phase depends on the reopening admission PriceGate has recorded: funds stay
    /// committed through CLOSED, REOPEN_WAIT and REOPEN_RECOVERY until a gate refresh admits a price and credit
    /// returns, and an invalid price or a stop seen by a refresh before credit returns clears the admission and
    /// extends the commitment. Reads `policy.snapshot()`, which records nothing.
    /// @param account Plan owner.
    /// @return True when the plan's funds are committed.
    function committed(address account) public view returns (bool) {
        Plan storage p = _plans[account];
        if (!_active(p, clock.time()) || market.debtOf(account) == 0) return false;
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        return s.phase != SessionRiskPolicy.State.OPEN && !s.windDown;
    }

    /// @notice Borrowing from A onward is rejected while an authorization is active (docs/SPEC.md §4). Returns
    /// true when `account` has an active authorization at `s.time` and `s.time` is at or after A of the snapshot's
    /// session; the market then rejects borrowing and debt-backed collateral withdrawal with
    /// BufferAuthorizationActive.
    /// @dev Ignores debt, balance and commitment. Outside the calendar `s.prepAt` is zero, so any active
    /// authorization blocks; borrowing is closed there anyway.
    /// @param account Borrower to check.
    /// @param s Policy snapshot the caller acts on (the market passes its refreshed snapshot).
    /// @return True when borrowing must be rejected for `account`.
    function blocksBorrowing(address account, SessionRiskPolicy.Snapshot memory s) external view returns (bool) {
        return _active(_plans[account], s.time) && s.time >= s.prepAt;
    }

    /// @notice True when `executeBuffer(account)` would repay something at snapshot `s`. Trims wait for it: the
    /// market rejects a trim with BufferPending while this is true (docs/SPEC.md §4 "Ordering with liquidation").
    /// @dev The checks of `executeBuffer` (`canBuffer`, an authorization active at `s.time`, a non-zero
    /// `_executableAmount`), applied to the caller's snapshot, debt and value and the plan's current balance and
    /// spend record.
    /// @param account Borrower to check.
    /// @param s Policy snapshot to evaluate at.
    /// @param debt Debt of `account` including interest, loan-token base units.
    /// @param value Collateral value of `account` at `s.priceWad`, loan-token base units, rounded down.
    /// @return True when a buffer execution would repay a non-zero amount.
    function executable(address account, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        external
        view
        returns (bool)
    {
        return _executableAt(_plans[account], s, debt, value) != 0;
    }

    /// @notice What `executeBuffer` would repay for `account` at snapshot `s`, in loan-token base units; zero when
    /// buffers cannot run at `s` or the authorization is not active at `s.time`.
    /// @dev Same rules as `executeBuffer` through `_executableAmount`: the cash needed to reach the target is
    /// rounded up, then capped by the plan's current balance and the allowance left for `s.session`, then
    /// adjusted for the minimum loan. StockReefLens calls it with the current snapshot (what could execute now)
    /// and with a snapshot that keeps only that snapshot's time and session and allows buffers (what a funded plan
    /// would repay in the current session).
    /// @param account Borrower to check.
    /// @param s Policy snapshot to evaluate at.
    /// @param debt Debt of `account` including interest, loan-token base units.
    /// @param value Collateral value of `account` at `s.priceWad`, loan-token base units, rounded down.
    /// @return Amount a buffer execution would repay, loan-token base units.
    function executableAmount(address account, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        external
        view
        returns (uint256)
    {
        return _executableAt(_plans[account], s, debt, value);
    }

    // ---------------------------------------------------------------- internals

    /// @dev True when `p` holds an authorization (non-zero target) that has not expired at time `t`, UTC seconds
    /// (`t < expiry`). Balance, debt and commitment are not considered.
    /// @param p Plan to check.
    /// @param t Time to check at, UTC seconds.
    /// @return True when the authorization is active at `t`.
    function _active(Plan storage p, uint64 t) internal view returns (bool) {
        return p.targetWad != 0 && t < p.expiry;
    }

    /// @dev `_executableAmount` where buffers can run at `s` and the authorization is active at `s.time`; zero
    /// otherwise.
    function _executableAt(Plan storage p, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        internal
        view
        returns (uint256)
    {
        if (!s.canBuffer || !_active(p, s.time)) return 0;
        return _executableAmount(p, s, debt, value);
    }

    /// @dev Returns zero at once, before any other rule, when the position is at or below its target
    /// (D * 1e18 <= T * V). Otherwise min(cash needed to reach the target, balance, remaining session allowance),
    /// in loan-token base units, then the minimum-loan rule.
    /// Cash needed: ceil((D * 1e18 - T * V) / 1e18) with debt D and value V in base units and target T in WAD;
    /// rounding up means that paying it in full reaches the target.
    /// Allowance: `perSessionCap` minus the spend recorded for session `s.session`, floored at zero.
    /// Minimum loan (appendix R16): when the result would leave non-zero debt below `market.minLoan()`, repay the
    /// whole debt if balance and allowance cover it (which can exceed the cash needed), otherwise repay down to
    /// exactly minLoan, short of the target, or nothing when the debt is at most minLoan. The result never
    /// exceeds the debt, the balance or the allowance.
    /// @param p Plan to execute.
    /// @param s Policy snapshot; only `s.session` is read.
    /// @param debt Debt including interest, loan-token base units.
    /// @param value Collateral value, loan-token base units.
    /// @return Amount to repay, loan-token base units.
    function _executableAmount(Plan storage p, SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value)
        internal
        view
        returns (uint256)
    {
        if (!debt.exceeds(value, p.targetWad)) return 0;
        uint256 need = debt.repayToReachUp(value, p.targetWad);
        uint256 spent = p.spentSession == uint32(s.session + 1) ? p.spent : 0;
        uint256 allowance = p.perSessionCap > spent ? p.perSessionCap - spent : 0;
        uint256 available = Math.min(p.balance, allowance);
        return _withinMinimumLoan(Math.min(need, available), available, debt);
    }

    /// @dev The minimum-loan rule shared by buffer execution and owner repayment (appendix R16): a repayment of
    /// `amount` (at most `limit`) that would leave non-zero debt below `market.minLoan()` becomes the whole debt
    /// when `limit` covers it, otherwise the repayment down to exactly minLoan, or nothing when the debt is at most
    /// minLoan. The result never exceeds `debt` or `limit`.
    /// @param amount Proposed repayment, loan-token base units; at most `limit`.
    /// @param limit Most that may be spent, loan-token base units.
    /// @param debt Debt including interest, loan-token base units.
    /// @return Repayment, loan-token base units.
    function _withinMinimumLoan(uint256 amount, uint256 limit, uint256 debt) internal view returns (uint256) {
        if (amount >= debt) return debt;
        uint256 minLoan = market.minLoan();
        if (debt - amount >= minLoan) return amount;
        if (limit >= debt) return debt;
        return debt > minLoan ? debt - minLoan : 0;
    }

    /// @dev Pay `amount` of `account`'s debt to the market from this contract's tokens: approve exactly `amount`,
    /// call `market.repay`, which pulls the tokens, require the market to take exactly `amount` (else
    /// NothingToRepay), then reset the approval to zero. Callers cap `amount` at the current debt and update the
    /// plan before calling.
    /// @param account Borrower whose debt is repaid.
    /// @param amount Amount to repay, loan-token base units.
    function _repay(address account, uint256 amount) internal {
        loanToken.forceApprove(address(market), amount);
        uint256 repaid = market.repay(amount, account);
        if (repaid != amount) revert NothingToRepay();
        loanToken.forceApprove(address(market), 0);
    }
}
