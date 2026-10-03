// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IClock} from "./interfaces/IClock.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {RepaymentEscrow} from "./RepaymentEscrow.sol";

/// @title StockReefMarket
/// @notice Reference lending market for one tokenized stock. Borrowers post the stock token as collateral and
/// borrow the loan token (USDG); lenders deposit the loan token for ERC-4626 shares; anyone with loan tokens can
/// partially liquidate ("trim") a loan whose LTV is above the session's liquidation threshold. Borrowing, trims
/// and lender entry and exit follow the session policy (docs/SPEC.md §3, §4, §5, §7; appendix R8, R16, R17).
/// @dev Units: loan amounts in loan-token base units (USDG: 6 decimals); collateral in raw stock-token units
/// (18 decimals); ratios, bonuses, LT, B, targets, the debt index and `priceWad` in WAD (1e18 = 100% or 1.0),
/// where `priceWad` is loan-token whole units per collateral whole unit; times in UTC seconds from the IClock.
/// Debt shares are scaled so that one base unit of debt at index 1.0 is 1e18 shares, which keeps share rounding
/// far below one base unit.
///
/// Every price-dependent entry point first calls `gate.refresh()` and evaluates the policy at the clock time, so
/// permission, limits and price come from one snapshot. Repayment and collateral deposits need no price and work
/// in every state; so does collateral withdrawal without debt (docs/SPEC.md §4, §9).
///
/// Trust: the market has no owner and no admin functions. It trusts the immutable PriceGate, SessionRiskPolicy
/// and IClock it is built with, and the RepaymentEscrow it deploys. Both tokens must move exact amounts: incoming
/// transfers are checked by balance delta, which rejects fee-on-transfer tokens; rebasing tokens are not
/// supported. A token issuer's transfer restrictions can still revert any action that moves tokens.
///
/// Invariants: `totalDebtShares` equals the sum of account debt shares; the active list holds exactly the
/// accounts with debt and never more than MAX_ACCOUNTS; the loan-token balance is at least `cash` and the
/// collateral-token balance at least the sum of account collateral (equal unless tokens are sent directly).
/// Every entry point that moves loan tokens or collateral is `nonReentrant` or calls one that is; share
/// transfers and approvals are plain ERC-20.
contract StockReefMarket is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev One borrower's position. Debt in loan-token base units is ceil(debtShares * index / SHARE_UNIT).
    struct Account {
        uint256 collateral; // raw stock-token units
        uint256 debtShares; // debt shares: 1e18 per base unit of debt at index 1.0
    }

    /// @notice Lender valuation of the whole loan book at one price (docs/SPEC.md §7).
    struct Book {
        uint256 priceWad; // price used for this valuation, WAD
        bool indicative; // true when `priceWad` is the last accepted price, not a current one
        uint256 totalDebt; // accrued debt of all accounts, loan-token base units, each rounded up
        uint256 recoverable; // sum of min(debt, value / 1.05), loan-token base units, rounded down
        bool impaired; // some account's debt exceeds its recoverable value
    }

    /// @notice What a trim would do at a given policy snapshot (docs/SPEC.md §5).
    /// @dev When `eligible` is false only `debt` and `value` are filled in; the other fields stay zero or false.
    struct TrimQuote {
        bool eligible; // trims allowed at the snapshot, debt non-zero and LTV strictly above LT
        bool bufferPending; // an executable buffer must run first
        uint256 debt; // accrued debt, loan-token base units, rounded up
        uint256 value; // collateral value at the snapshot price, loan-token base units, rounded down
        uint256 bonusWad; // liquidation bonus, WAD
        uint256 repaid; // loan tokens the liquidator pays, base units
        uint256 collateralOut; // collateral the liquidator receives, raw units, rounded down and capped at the
        // account's collateral; all of it when an insolvent trim repays floor(value / (1 + bonus))
        bool fullFill; // a solvent fill that repays the whole amount needed to reach the target
    }

    /// @dev Fixed-point one (1e18) for WAD ratios, prices and the debt index.
    uint256 internal constant WAD = 1e18;
    /// @dev Debt shares per loan-token base unit at index 1.0, times WAD, so debt = shares * index / SHARE_UNIT.
    uint256 internal constant SHARE_UNIT = 1e36;
    /// @notice Most accounts that may hold debt at once; it bounds the lender valuation loop (appendix R8).
    uint256 public constant MAX_ACCOUNTS = 32;
    /// @notice Highest share of cash plus total debt that total debt may reach after a borrow, WAD (90%)
    /// (docs/SPEC.md §7).
    uint256 public constant UTILIZATION_CAP = 0.9e18;
    /// @notice Haircut on collateral value in the lender valuation, WAD (5%): an account counts for at most
    /// value / 1.05 (docs/SPEC.md §7).
    uint256 public constant RECOVERY_HAIRCUT = 0.05e18;
    /// @notice Interest rate per second, WAD: 10% a year over a 365-day year (0.1e18 / 31,536,000, rounded down).
    /// @dev Compounded continuously from `epoch`: index = expWad(RATE_PER_SECOND * (t - epoch)) for clock time t
    /// (docs/SPEC.md §7).
    uint256 public constant RATE_PER_SECOND = 3170979198;

    /// @notice Stock token accepted as collateral, counted in raw units.
    IERC20 public immutable collateralToken;
    /// @notice Price gate that values the collateral; every price-dependent entry point refreshes it first.
    PriceGate public immutable gate;
    /// @notice Session policy that sets the state, LT, B, target, bonus and action permissions.
    SessionRiskPolicy public immutable policy;
    /// @notice Time source shared with the gate and policy (UTC seconds); a DemoClock on demo deployments.
    IClock public immutable clock;
    /// @notice Borrower repayment escrow, deployed by this market's constructor (docs/SPEC.md §4).
    RepaymentEscrow public immutable escrow;
    /// @notice Clock time at deployment, UTC seconds; the debt index is 1.0 (1e18) at this time.
    uint64 public immutable epoch;
    /// @notice Minimum loan, loan-token base units: a borrow must leave at least this much debt and a repayment
    /// must leave either none or at least this much (appendix R8, R16).
    uint256 public immutable minLoan;
    /// @notice Copied from PriceGate.VALUE_SCALE at deployment: 10^(token decimals + 18 - loan decimals), so
    /// collateral value in loan-token base units is raw * priceWad / VALUE_SCALE.
    uint256 public immutable VALUE_SCALE;

    /// @notice Idle loan tokens held for lenders, base units. Excludes tokens sent to the market directly and the
    /// escrow's balance; it rises with deposits, repayments and trims and falls with borrowing and lender exits.
    uint256 public cash;
    /// @notice Sum of all accounts' debt shares (1e18 shares per base unit of debt at index 1.0).
    uint256 public totalDebtShares;
    /// @notice Cumulative debt written off when trims exhausted an account's collateral, loan-token base units.
    uint256 public totalBadDebt;
    /// @dev Position of each borrower address.
    mapping(address => Account) internal _accounts;
    /// @dev Accounts with debt, at most MAX_ACCOUNTS; removal swaps in the last entry, so order is not stable.
    address[] internal _active;
    /// @dev Index of an account in `_active` plus one; zero when the account is not listed.
    mapping(address => uint256) internal _activeSlot;

    /// @notice Collateral was added to `account`.
    /// @param account Account credited with the collateral.
    /// @param payer Caller that supplied the tokens.
    /// @param amount Collateral added, raw stock-token units.
    event CollateralDeposited(address indexed account, address indexed payer, uint256 amount);
    /// @notice Collateral was withdrawn from `account`.
    /// @param account Account the collateral left (the caller).
    /// @param receiver Address that received the tokens.
    /// @param amount Collateral withdrawn, raw stock-token units.
    event CollateralWithdrawn(address indexed account, address indexed receiver, uint256 amount);
    /// @notice `account` borrowed loan tokens.
    /// @param account Borrowing account (the caller).
    /// @param receiver Address that received the loan tokens.
    /// @param amount Loan tokens lent, base units.
    /// @param debtAfter Account debt after the borrow, loan-token base units, rounded up.
    event Borrowed(address indexed account, address indexed receiver, uint256 amount, uint256 debtAfter);
    /// @notice Debt of `account` was repaid.
    /// @param account Account whose debt fell.
    /// @param payer Caller that paid; the escrow for buffer executions and owner repayments.
    /// @param amount Loan tokens actually paid, base units.
    /// @param debtAfter Remaining debt, loan-token base units, rounded up; zero when fully repaid.
    event Repaid(address indexed account, address indexed payer, uint256 amount, uint256 debtAfter);
    /// @notice A trim repaid part of `account`'s debt in exchange for its collateral.
    /// @param account Trimmed account.
    /// @param liquidator Caller that paid the loan tokens and received the collateral.
    /// @param repaid Loan tokens paid, base units.
    /// @param collateralOut Collateral sent to the liquidator, raw units.
    /// @param bonusWad Liquidation bonus applied, WAD.
    /// @param state Effective policy state when the trim executed.
    /// @param debtAfter Remaining debt, loan-token base units, rounded up; zero when the debt was fully repaid or
    /// the residual was written off.
    /// @param collateralAfter Collateral left in the account, raw units.
    event Trimmed(
        address indexed account,
        address indexed liquidator,
        uint256 repaid,
        uint256 collateralOut,
        uint256 bonusWad,
        SessionRiskPolicy.State state,
        uint256 debtAfter,
        uint256 collateralAfter
    );
    /// @notice A trim exhausted `account`'s collateral and its residual debt was written off.
    /// @param account Account whose debt was cleared.
    /// @param amount Debt written off, loan-token base units.
    event BadDebtWrittenOff(address indexed account, uint256 amount);

    /// @notice An amount is zero, or a trim would repay or release nothing.
    error ZeroAmount();
    /// @notice The current session state does not allow this action.
    /// @param state Effective policy state.
    /// @param reasons PriceGate Reasons bits (see the Reasons library); zero when the price is usable.
    error NotAllowedNow(SessionRiskPolicy.State state, uint32 reasons);
    /// @notice The account has an active escrow authorization and the time is at or after A (docs/SPEC.md §4).
    error BufferAuthorizationActive();
    /// @notice MAX_ACCOUNTS accounts already hold debt, so an account without debt cannot borrow (appendix R8).
    error AccountCapReached();
    /// @notice The action would leave non-zero debt below the minimum loan (appendix R8, R16).
    /// @param debtAfter Debt the action would leave, loan-token base units (for a borrow, before share rounding).
    /// @param minLoan Minimum loan, loan-token base units.
    error BelowMinimumLoan(uint256 debtAfter, uint256 minLoan);
    /// @notice The account's debt would exceed the borrow limit B times its collateral value.
    /// @param debtAfter Account debt after the action, loan-token base units, rounded up.
    /// @param collateralValue Collateral value after the action, loan-token base units, rounded down.
    /// @param borrowLimitWad Borrow limit B, WAD.
    error AboveBorrowLimit(uint256 debtAfter, uint256 collateralValue, uint256 borrowLimitWad);
    /// @notice Some account's debt exceeds its recoverable value, which blocks new borrowing (docs/SPEC.md §7).
    error MarketImpaired();
    /// @notice The borrow would lift total debt above UTILIZATION_CAP of cash plus total debt.
    error UtilizationCapExceeded();
    /// @notice The market's idle cash is smaller than the amount requested.
    /// @param requested Loan tokens requested, base units.
    /// @param available Idle cash, base units.
    error InsufficientCash(uint256 requested, uint256 available);
    /// @notice The account holds less collateral than requested.
    /// @param requested Collateral requested, raw units.
    /// @param available Account collateral, raw units.
    error InsufficientCollateral(uint256 requested, uint256 available);
    /// @notice The account has no debt to repay.
    error NoDebt();
    /// @notice A transfer into the market changed its balance by a different amount than requested, as a
    /// fee-on-transfer token would.
    /// @param expected Amount requested, token units.
    /// @param received Amount by which the market's balance rose, token units.
    error UnsupportedTransfer(uint256 expected, uint256 received);
    /// @notice The clock time is past the trim's deadline.
    error DeadlinePassed();
    /// @notice The account is not eligible for a trim: it has no debt, or its LTV is not strictly above LT.
    /// @param debt Accrued debt, loan-token base units, rounded up.
    /// @param value Collateral value at the current price, loan-token base units, rounded down.
    /// @param ltWad Current liquidation threshold LT, WAD.
    error NotEligible(uint256 debt, uint256 value, uint256 ltWad);
    /// @notice An escrow buffer repayment is executable for this account; it must run first, in its own
    /// transaction (docs/SPEC.md §4).
    error BufferPending();
    /// @notice A result is outside the caller's minimum or maximum.
    error Slippage();
    /// @notice A full solvent trim left debt more than one base unit above target times value (docs/SPEC.md §5).
    /// @param debtAfter Remaining debt, loan-token base units.
    /// @param valueAfter Remaining collateral value at the trim price, loan-token base units.
    /// @param targetWad Target LTV, WAD.
    error TargetMissed(uint256 debtAfter, uint256 valueAfter, uint256 targetWad);
    /// @notice The policy's gate prices a different loan token or collateral token than the market was given.
    error ConfigMismatch();

    /// @notice Deploy the market and its RepaymentEscrow, and start the debt index at 1.0 at the current clock
    /// time. All settings are fixed for the life of the deployment (docs/SPEC.md §2).
    /// @dev Takes the gate and clock from `policy_`. Reverts with ConfigMismatch unless the gate prices exactly
    /// `collateralToken_` in `loanToken`.
    /// @param loanToken Token lent to borrowers and deposited by lenders (USDG); the ERC-4626 asset.
    /// @param collateralToken_ Stock token accepted as collateral.
    /// @param policy_ Session policy; its gate and clock become the market's.
    /// @param minLoan_ Minimum loan, loan-token base units (appendix R8).
    /// @param name_ ERC-20 name of the lender share token.
    /// @param symbol_ ERC-20 symbol of the lender share token.
    constructor(
        IERC20 loanToken,
        IERC20 collateralToken_,
        SessionRiskPolicy policy_,
        uint256 minLoan_,
        string memory name_,
        string memory symbol_
    ) ERC4626(loanToken) ERC20(name_, symbol_) {
        policy = policy_;
        gate = policy_.gate();
        clock = policy_.clock();
        collateralToken = collateralToken_;
        if (address(gate.loanToken()) != address(loanToken) || address(gate.token()) != address(collateralToken_)) {
            revert ConfigMismatch();
        }
        VALUE_SCALE = gate.VALUE_SCALE();
        minLoan = minLoan_;
        epoch = clock.time();
        escrow = new RepaymentEscrow(this, loanToken, policy_);
    }

    // =============================================================== borrower

    /// @notice Add collateral for `account`, paid by the caller. Anyone may call, for any account. Needs no price
    /// and is allowed in every state (docs/SPEC.md §4).
    /// @dev Reverts with ZeroAmount, or UnsupportedTransfer if the market receives a different amount.
    /// @param amount Collateral to add, raw stock-token units.
    /// @param account Account to credit.
    function depositCollateral(uint256 amount, address account) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pullExact(collateralToken, msg.sender, amount);
        _accounts[account].collateral += amount;
        emit CollateralDeposited(account, msg.sender, amount);
    }

    /// @notice Withdraw collateral from the caller's own account. Without debt this needs no price and is allowed
    /// in every state. With debt it is a borrow-limit action: it refreshes the gate and needs a state that allows
    /// borrowing (OPEN or PRE_CLOSE with a usable price), no active escrow authorization at or after A, and debt
    /// at most B times the remaining collateral value (docs/SPEC.md §3, §4).
    /// @dev Reverts with ZeroAmount, InsufficientCollateral, NotAllowedNow, BufferAuthorizationActive or
    /// AboveBorrowLimit. Debt rounds up and value rounds down, both against the borrower.
    /// @param amount Collateral to withdraw, raw stock-token units.
    /// @param receiver Address that receives the collateral.
    function withdrawCollateral(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Account storage a = _accounts[msg.sender];
        if (amount > a.collateral) revert InsufficientCollateral(amount, a.collateral);
        a.collateral -= amount;
        if (a.debtShares != 0) {
            SessionRiskPolicy.Snapshot memory s = _refresh();
            _requireBorrowable(s, msg.sender);
            uint256 debt = _debt(a.debtShares, _index(s.time));
            _requireWithinLimit(s, debt, _value(a.collateral, s.priceWad));
        }
        collateralToken.safeTransfer(receiver, amount);
        emit CollateralWithdrawn(msg.sender, receiver, amount);
    }

    /// @notice Borrow `amount` loan tokens against the caller's collateral. Refreshes the gate first; allowed only
    /// in OPEN or PRE_CLOSE with a usable price, within the borrow limit B (docs/SPEC.md §3, §7; appendix R8).
    /// @dev Checks, in order: a non-zero amount (ZeroAmount); borrowing allowed after the refresh (NotAllowedNow);
    /// no escrow authorization active at or after A (BufferAuthorizationActive); enough idle cash
    /// (InsufficientCash); no impaired account at the current price (MarketImpaired); total debt after the borrow
    /// at most UTILIZATION_CAP of cash plus total debt (UtilizationCapExceeded); a free active slot for an account
    /// without debt (AccountCapReached); previous debt plus `amount` at least `minLoan` (BelowMinimumLoan); and
    /// debt at most B times the collateral value (AboveBorrowLimit). New debt shares round up, so recorded debt
    /// can exceed the previous debt plus `amount` by one base unit.
    /// @param amount Loan tokens to borrow, base units.
    /// @param receiver Address that receives the loan tokens.
    function borrow(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        SessionRiskPolicy.Snapshot memory s = _refresh();
        _requireBorrowable(s, msg.sender);
        if (amount > cash) revert InsufficientCash(amount, cash);

        uint256 idx = _index(s.time);
        Book memory book = _book(s.priceWad, false, idx);
        if (book.impaired) revert MarketImpaired();
        if ((book.totalDebt + amount) * WAD > UTILIZATION_CAP * (cash + book.totalDebt)) {
            revert UtilizationCapExceeded();
        }

        Account storage a = _accounts[msg.sender];
        if (a.debtShares == 0) {
            if (_active.length >= MAX_ACCOUNTS) revert AccountCapReached();
            _active.push(msg.sender);
            _activeSlot[msg.sender] = _active.length;
        }
        // The minimum applies to principal; the share rounding below adds at most one base unit of debt.
        uint256 debtBefore = _debt(a.debtShares, idx);
        if (debtBefore + amount < minLoan) revert BelowMinimumLoan(debtBefore + amount, minLoan);
        uint256 shares = amount.mulDiv(SHARE_UNIT, idx, Math.Rounding.Ceil);
        a.debtShares += shares;
        totalDebtShares += shares;
        uint256 debtAfter = _debt(a.debtShares, idx);
        _requireWithinLimit(s, debtAfter, _value(a.collateral, s.priceWad));

        cash -= amount;
        IERC20(asset()).safeTransfer(receiver, amount);
        emit Borrowed(msg.sender, receiver, amount, debtAfter);
    }

    /// @notice Repay up to `amount` of `account`'s debt. Anyone may repay for any account. Needs no price and is
    /// allowed in every state, including CLOSED, GUARDED and wind-down (docs/SPEC.md §4; appendix R16, R17).
    /// @dev Interest accrues to the current clock time. When `amount` covers the debt, the full debt (rounded up)
    /// is taken, the shares are cleared exactly and the account leaves the active list. Otherwise the shares
    /// burned round down, against the payer, and the remaining debt must be at least `minLoan`. Reverts with
    /// ZeroAmount, NoDebt, BelowMinimumLoan or UnsupportedTransfer.
    /// @param amount Most loan tokens to repay, base units.
    /// @param account Account whose debt is repaid.
    /// @return paid The amount actually taken from the caller, loan-token base units.
    function repay(uint256 amount, address account) external nonReentrant returns (uint256 paid) {
        if (amount == 0) revert ZeroAmount();
        Account storage a = _accounts[account];
        if (a.debtShares == 0) revert NoDebt();
        uint256 idx = _index(clock.time());
        uint256 debtAfter;
        (paid, debtAfter) = _reduceDebt(account, a, amount, idx);
        // Repay everything or leave at least the minimum loan, so dust cannot hold an active slot.
        if (debtAfter != 0 && debtAfter < minLoan) revert BelowMinimumLoan(debtAfter, minLoan);
        _pullExact(IERC20(asset()), msg.sender, paid);
        cash += paid;
        emit Repaid(account, msg.sender, paid, debtAfter);
    }

    // =============================================================== liquidation

    /// @notice Partially liquidate `account` toward the current target at the current accepted price. The
    /// caller supplies the loan tokens and receives collateral worth the repayment plus the applicable bonus.
    /// Permissionless. Refreshes the gate first; allowed in OPEN, PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY
    /// with a usable price, for an account whose LTV is strictly above LT (docs/SPEC.md §3, §5).
    /// @dev Executes exactly `quoteTrim(account, s, maxRepay)` for the refreshed snapshot `s`. Reverts with
    /// ZeroAmount, DeadlinePassed, NotAllowedNow, NotEligible, BufferPending (an executable escrow buffer must run
    /// first, in a separate transaction), Slippage, TargetMissed when a full solvent fill leaves debt more than
    /// one base unit above target times value, or UnsupportedTransfer when the loan tokens received differ from
    /// `repaid`. When the trim takes all remaining collateral and debt remains, the residual is written off as
    /// bad debt. The minimum loan does not apply (appendix R16).
    /// @param account Account to trim.
    /// @param maxRepay Most the caller will repay, loan-token base units.
    /// @param minCollateralOut Least raw collateral the caller accepts.
    /// @param deadline Latest clock time (UTC seconds) at which the trim may execute.
    /// @return repaid Loan tokens taken from the caller, base units.
    /// @return collateralOut Collateral sent to the caller, raw units, rounded down and capped at the account's
    /// collateral; all of it when an insolvent trim repays floor(value / (1 + bonus)).
    function trim(address account, uint256 maxRepay, uint256 minCollateralOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 repaid, uint256 collateralOut)
    {
        if (maxRepay == 0) revert ZeroAmount();
        SessionRiskPolicy.Snapshot memory s = _refresh();
        if (s.time > deadline) revert DeadlinePassed();
        if (!s.canTrim) revert NotAllowedNow(s.state, s.reasons);

        TrimQuote memory t = quoteTrim(account, s, maxRepay);
        if (!t.eligible) revert NotEligible(t.debt, t.value, s.ltWad);
        if (t.bufferPending) revert BufferPending();
        repaid = t.repaid;
        collateralOut = t.collateralOut;
        if (repaid == 0 || collateralOut == 0) revert ZeroAmount();
        if (collateralOut < minCollateralOut) revert Slippage();

        Account storage a = _accounts[account];
        (, uint256 debtAfter) = _reduceDebt(account, a, repaid, _index(s.time));
        a.collateral -= collateralOut;
        if (a.collateral == 0 && debtAfter != 0) {
            // Collateral exhausted: recognize the residual as bad debt; lenders already marked it down.
            totalDebtShares -= a.debtShares;
            a.debtShares = 0;
            _deactivate(account);
            totalBadDebt += debtAfter;
            emit BadDebtWrittenOff(account, debtAfter);
            debtAfter = 0;
        } else if (t.fullFill) {
            // A full solvent fill reaches the target within one loan-token base unit.
            uint256 valueAfter = _value(a.collateral, s.priceWad);
            if (debtAfter * WAD > s.targetWad * valueAfter + WAD) {
                revert TargetMissed(debtAfter, valueAfter, s.targetWad);
            }
        }

        _pullExact(IERC20(asset()), msg.sender, repaid);
        cash += repaid;
        collateralToken.safeTransfer(msg.sender, collateralOut);
        emit Trimmed(account, msg.sender, repaid, collateralOut, t.bonusWad, s.state, debtAfter, a.collateral);
    }

    /// @notice What `trim(account, maxRepay, ...)` would do at snapshot `s`. StockReefLens uses it to preview
    /// trims for the app and the keeper, and `trim` executes exactly this quote.
    /// @dev Debt accrues to `s.time` and collateral is valued at `s.priceWad`. Eligibility needs `s.canTrim`,
    /// non-zero debt and debt strictly above LT times value; `bufferPending` is `escrow.executable` for the same
    /// snapshot, debt and value; the bonus is `policy.bonusFor` at the LTV rounded up.
    /// Does not revert for a SessionRiskPolicy snapshot at a time at or after `epoch`. Other snapshots can make
    /// the arithmetic revert: a time before `epoch`, a target above LT, or target * (1 + bonus) of at least 1.
    /// @param account Account to quote.
    /// @param s Policy snapshot supplying the time, permissions, price, LT and target.
    /// @param maxRepay Most the caller would repay, loan-token base units.
    /// @return t The quote; see TrimQuote for fields and units.
    function quoteTrim(address account, SessionRiskPolicy.Snapshot memory s, uint256 maxRepay)
        public
        view
        returns (TrimQuote memory t)
    {
        Account storage a = _accounts[account];
        t.debt = _debt(a.debtShares, _index(s.time));
        t.value = _value(a.collateral, s.priceWad);
        t.eligible = s.canTrim && t.debt != 0 && t.debt * WAD > s.ltWad * t.value;
        if (!t.eligible) return t;
        t.bufferPending = escrow.executable(account, s, t.debt, t.value);
        t.bonusWad = policy.bonusFor(s, _ltvCeil(t.debt, t.value));
        (t.repaid, t.collateralOut, t.fullFill) = _trimAmounts(a.collateral, t.debt, t.value, s, t.bonusWad, maxRepay);
    }

    /// @dev Repayment and collateral transfer for a trim (docs/SPEC.md §5). D and x in loan-token base units.
    /// Solvent (D*(1+b) < V): x = ceil((D - T*V) / (1 - T*(1+b))), capped at D and at `maxRepay`; the seized
    /// collateral is worth x*(1+b), rounded down and capped at the account's collateral.
    /// Insolvent (D*(1+b) >= V): repaying floor(V/(1+b)) takes all collateral; a smaller `maxRepay` takes
    /// collateral worth maxRepay*(1+b), rounded down. This branch never sets `fullFill`.
    /// @param collateral Account collateral, raw units.
    /// @param debt Accrued debt D, loan-token base units.
    /// @param value Collateral value V at `s.priceWad`, loan-token base units.
    /// @param s Snapshot supplying the target T and the price.
    /// @param bonusWad Bonus b, WAD.
    /// @param maxRepay Most the caller will repay, loan-token base units.
    /// @return repaid Loan tokens to repay, base units.
    /// @return collateralOut Collateral to transfer, raw units.
    /// @return fullFill True when a solvent fill repays the whole amount needed to reach the target.
    function _trimAmounts(
        uint256 collateral,
        uint256 debt,
        uint256 value,
        SessionRiskPolicy.Snapshot memory s,
        uint256 bonusWad,
        uint256 maxRepay
    ) internal view returns (uint256 repaid, uint256 collateralOut, bool fullFill) {
        uint256 onePlusB = WAD + bonusWad;
        if (debt * onePlusB >= value * WAD) {
            uint256 all = value.mulDiv(WAD, onePlusB);
            repaid = Math.min(maxRepay, all);
            collateralOut = repaid == all ? collateral : _collateralFor(repaid, onePlusB, s.priceWad);
        } else {
            uint256 need =
                (debt * WAD - s.targetWad * value).mulDiv(WAD, WAD * WAD - s.targetWad * onePlusB, Math.Rounding.Ceil);
            need = Math.min(need, debt);
            repaid = Math.min(maxRepay, need);
            fullFill = repaid == need;
            collateralOut = Math.min(_collateralFor(repaid, onePlusB, s.priceWad), collateral);
        }
    }

    /// @dev Raw collateral worth `repaid` times (1 + b) at `priceWad`, rounded down:
    /// repaid * onePlusB * VALUE_SCALE / (priceWad * WAD).
    /// @param repaid Repayment, loan-token base units.
    /// @param onePlusB One plus the bonus, WAD.
    /// @param priceWad Collateral price, WAD.
    /// @return Collateral, raw units.
    function _collateralFor(uint256 repaid, uint256 onePlusB, uint256 priceWad) internal view returns (uint256) {
        return (repaid * onePlusB).mulDiv(VALUE_SCALE, priceWad * WAD);
    }

    // =============================================================== lenders (ERC-4626)

    /// @inheritdoc ERC4626
    /// @notice Deposit `assets` loan tokens and mint lender shares to `receiver`. Allowed only in OPEN with a
    /// usable price (docs/SPEC.md §7).
    /// @dev Refreshes the gate, then values the book at that price before converting. Reverts with NotAllowedNow
    /// outside the lender window, ERC4626ExceededMaxDeposit in run-off (lender assets zero while shares remain)
    /// and UnsupportedTransfer when the amount received differs from `assets`. Shares round down.
    /// @param assets Loan tokens to deposit, base units.
    /// @param receiver Address that receives the shares.
    /// @return Shares minted.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    /// @notice Mint exactly `shares` lender shares to `receiver`, paying the loan tokens they cost. Allowed only
    /// in OPEN with a usable price (docs/SPEC.md §7).
    /// @dev Same refresh and lender-window rules as `deposit`; in run-off it reverts with ERC4626ExceededMaxMint,
    /// and with UnsupportedTransfer when the amount received differs. The assets charged round up, against the
    /// caller.
    /// @param shares Shares to mint.
    /// @param receiver Address that receives the shares.
    /// @return Loan tokens taken from the caller, base units.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    /// @notice Withdraw exactly `assets` loan tokens to `receiver`, burning `owner`'s shares. Allowed in OPEN with
    /// a usable price, or in wind-down (from the open of the last loaded session); limited by idle cash
    /// (docs/SPEC.md §7; appendix R17).
    /// @dev Refreshes the gate, then values the book before converting. Reverts with NotAllowedNow when exits
    /// are closed, ERC4626ExceededMaxWithdraw above `maxWithdraw`, and ERC20InsufficientAllowance when a caller
    /// other than `owner` lacks share allowance. `maxWithdraw` is already capped at idle cash, so the
    /// InsufficientCash check in `_withdraw` is only a backstop. Shares burned round up, against the caller.
    /// @param assets Loan tokens to withdraw, base units.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @return Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireLenderExit();
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626
    /// @notice Redeem exactly `shares` of `owner`'s shares for loan tokens sent to `receiver`. Allowed in OPEN with
    /// a usable price, or in wind-down (from the open of the last loaded session); limited by idle cash
    /// (docs/SPEC.md §7; appendix R17).
    /// @dev Refreshes the gate, then values the book before converting. Reverts with NotAllowedNow when exits
    /// are closed, ERC4626ExceededMaxRedeem above `maxRedeem`, and ERC20InsufficientAllowance when a caller other
    /// than `owner` lacks share allowance. `maxRedeem` is already capped at the shares worth the idle cash, so
    /// the InsufficientCash check in `_withdraw` is only a backstop. Assets paid round down, against the caller.
    /// @param shares Shares to redeem.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @return Loan tokens paid, base units.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireLenderExit();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice `deposit` that reverts with Slippage when fewer than `minShares` shares are minted.
    /// @dev Same states, reverts and rounding as `deposit`, which refreshes the gate and is `nonReentrant`.
    /// @param assets Loan tokens to deposit, base units.
    /// @param receiver Address that receives the shares.
    /// @param minShares Fewest shares the caller accepts.
    /// @return shares Shares minted.
    function depositChecked(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares) {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert Slippage();
    }

    /// @notice `mint` that reverts with Slippage when it costs more than `maxAssets` loan tokens.
    /// @dev Same states, reverts and rounding as `mint`, which refreshes the gate and is `nonReentrant`.
    /// @param shares Shares to mint.
    /// @param receiver Address that receives the shares.
    /// @param maxAssets Most loan tokens the caller will pay, base units.
    /// @return assets Loan tokens taken from the caller, base units.
    function mintChecked(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets) {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert Slippage();
    }

    /// @notice `withdraw` that reverts with Slippage when it burns more than `maxShares` shares.
    /// @dev Same states, reverts and rounding as `withdraw`, which refreshes the gate and is `nonReentrant`.
    /// @param assets Loan tokens to withdraw, base units.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @param maxShares Most shares the caller accepts to burn.
    /// @return shares Shares burned.
    function withdrawChecked(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        returns (uint256 shares)
    {
        shares = withdraw(assets, receiver, owner);
        if (shares > maxShares) revert Slippage();
    }

    /// @notice `redeem` that reverts with Slippage when it pays fewer than `minAssets` loan tokens.
    /// @dev Same states, reverts and rounding as `redeem`, which refreshes the gate and is `nonReentrant`.
    /// @param shares Shares to redeem.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @param minAssets Fewest loan tokens the caller accepts, base units.
    /// @return assets Loan tokens paid, base units.
    function redeemChecked(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner);
        if (assets < minAssets) revert Slippage();
    }

    /// @inheritdoc ERC4626
    /// @notice Cash plus the recoverable value of every loan: sum of min(debt, collateral value / 1.05).
    /// Uses the current price when usable, otherwise the last accepted price (indicative) (docs/SPEC.md §7).
    /// @dev View only: it reads the gate's current quote without refreshing it; the share entry and exit
    /// functions refresh first. Escrow balances and tokens sent to the market directly are not counted, and
    /// collateral counts only through each loan's recoverable amount. Recoverable amounts round down. Loops over
    /// at most MAX_ACCOUNTS accounts.
    /// @return Lender assets, loan-token base units.
    function totalAssets() public view override returns (uint256) {
        return cash + bookValuation().recoverable;
    }

    /// @inheritdoc ERC4626
    /// @notice Most loan tokens that can be deposited now, for any receiver (the address argument is ignored):
    /// unlimited while the lender window is open, zero when it is closed or the vault is in run-off.
    /// @dev Reads `policy.snapshot()` without refreshing the gate.
    /// @return Loan-token base units; type(uint256).max when unlimited.
    function maxDeposit(address) public view override returns (uint256) {
        if (!_lenderWindowOpen() || _inRunOff()) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc ERC4626
    /// @notice Most shares that can be minted now, for any receiver (the address argument is ignored): unlimited
    /// while the lender window is open, zero when it is closed or the vault is in run-off.
    /// @dev Reads `policy.snapshot()` without refreshing the gate.
    /// @return Shares; type(uint256).max when unlimited.
    function maxMint(address) public view override returns (uint256) {
        if (!_lenderWindowOpen() || _inRunOff()) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc ERC4626
    /// @notice Most loan tokens `owner` can withdraw now: the value of their shares, rounded down, capped at idle
    /// cash. Zero unless the lender window is open or the market is in wind-down (appendix R17).
    /// @dev Reads `policy.snapshot()` without refreshing the gate.
    /// @param owner Share holder.
    /// @return Loan-token base units.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!_lenderExitOpen()) return 0;
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), cash);
    }

    /// @inheritdoc ERC4626
    /// @notice Most shares `owner` can redeem now: their balance, capped at the shares worth the idle cash
    /// (rounded down). Zero unless the lender window is open or the market is in wind-down (appendix R17).
    /// @dev Reads `policy.snapshot()` without refreshing the gate.
    /// @param owner Share holder.
    /// @return Shares.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (!_lenderExitOpen()) return 0;
        return Math.min(balanceOf(owner), _convertToShares(cash, Math.Rounding.Floor));
    }

    /// @inheritdoc ERC4626
    /// @dev Pulls exactly `assets` from `caller` (UnsupportedTransfer otherwise), adds them to `cash`, then mints
    /// `shares` to `receiver` and emits Deposit.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _pullExact(IERC20(asset()), caller, assets);
        cash += assets;
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev Requires `assets` to fit in idle cash (InsufficientCash otherwise) and takes them out of `cash`; the
    /// base implementation then spends share allowance when `caller` is not `owner`, burns `shares`, transfers
    /// the assets and emits Withdraw.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > cash) revert InsufficientCash(assets, cash);
        cash -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev Six virtual decimals: shares have the loan token's decimals plus 6, and an empty vault mints 1e6
    /// shares per base unit, which makes share-inflation attacks costly (docs/SPEC.md §7). Donations do not
    /// reach `totalAssets`, which counts `cash` rather than the token balance.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // =============================================================== views

    /// @notice One account's position at the current clock time.
    /// @param account Account to read.
    /// @return collateral Collateral, raw stock-token units.
    /// @return debtShares Debt shares (1e18 per base unit of debt at index 1.0).
    /// @return debt Accrued debt, loan-token base units, rounded up.
    function accountOf(address account) external view returns (uint256 collateral, uint256 debtShares, uint256 debt) {
        Account storage a = _accounts[account];
        return (a.collateral, a.debtShares, _debt(a.debtShares, _index(clock.time())));
    }

    /// @notice Accrued debt of `account` at the current clock time.
    /// @param account Account to read.
    /// @return Debt, loan-token base units, rounded up; zero without debt.
    function debtOf(address account) public view returns (uint256) {
        return _debt(_accounts[account].debtShares, _index(clock.time()));
    }

    /// @notice Collateral held for `account`.
    /// @param account Account to read.
    /// @return Collateral, raw stock-token units.
    function collateralOf(address account) external view returns (uint256) {
        return _accounts[account].collateral;
    }

    /// @notice Accounts that currently hold debt, at most MAX_ACCOUNTS, in no fixed order.
    /// @return The active account list.
    function activeAccounts() external view returns (address[] memory) {
        return _active;
    }

    /// @notice Debt index at the current clock time.
    /// @return Index, WAD; 1e18 at `epoch` and growing at RATE_PER_SECOND, continuously compounded.
    function debtIndex() external view returns (uint256) {
        return _index(clock.time());
    }

    /// @notice Lender book at one price snapshot: the current quote if usable, else the last accepted price,
    /// flagged as indicative (docs/SPEC.md §7).
    /// @dev View only; it does not refresh the gate. If the gate has never accepted a price, an indicative
    /// valuation uses a price of zero, so every loan counts as unrecoverable.
    /// @return The valuation; see Book for fields and units.
    function bookValuation() public view returns (Book memory) {
        PriceGate.Quote memory q = gate.quote();
        bool indicative = q.reasons != 0;
        return _book(indicative ? gate.lastPriceWad() : q.priceWad, indicative, _index(clock.time()));
    }

    // =============================================================== internals

    /// @dev Refreshes the gate (recording reopening admission, outages, recovery checkpoints and the last accepted
    /// price) and evaluates the policy at the current clock time (docs/SPEC.md §6).
    /// @return The policy snapshot for this transaction.
    function _refresh() internal returns (SessionRiskPolicy.Snapshot memory) {
        return policy.evaluate(gate.refresh(), clock.time());
    }

    /// @dev Reverts with NotAllowedNow unless `s` allows borrowing, and with BufferAuthorizationActive when
    /// `account` has an active escrow authorization and `s.time` is at or after A (docs/SPEC.md §4).
    /// @param s Refreshed policy snapshot of this transaction.
    /// @param account Borrower about to take or keep debt.
    function _requireBorrowable(SessionRiskPolicy.Snapshot memory s, address account) internal view {
        if (!s.canBorrow) revert NotAllowedNow(s.state, s.reasons);
        if (escrow.blocksBorrowing(account, s)) revert BufferAuthorizationActive();
    }

    /// @dev Reverts with AboveBorrowLimit unless debt <= B * value, compared exactly by cross-multiplication;
    /// equality passes. `debt` and `value` are loan-token base units.
    /// @param s Policy snapshot supplying B (`borrowLimitWad`, WAD).
    /// @param debt Account debt after the action, loan-token base units, rounded up.
    /// @param value Collateral value after the action, loan-token base units, rounded down.
    function _requireWithinLimit(SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value) internal pure {
        if (debt * WAD > s.borrowLimitWad * value) revert AboveBorrowLimit(debt, value, s.borrowLimitWad);
    }

    /// @dev Deposits and mints: refreshes, then reverts with NotAllowedNow unless the lender window is open
    /// (OPEN with a usable price).
    function _requireLenderWindow() internal {
        SessionRiskPolicy.Snapshot memory s = _refresh();
        if (!s.lenderOpen) revert NotAllowedNow(s.state, s.reasons);
    }

    /// @dev Withdrawals and redemptions: the scheduled window, or wind-down from the open of the last loaded
    /// session, when lenders exit against idle cash at the gate's last accepted price and repayments keep adding
    /// to that cash. Refreshes, then reverts with NotAllowedNow otherwise (appendix R17).
    function _requireLenderExit() internal {
        SessionRiskPolicy.Snapshot memory s = _refresh();
        if (!s.lenderOpen && !s.windDown) revert NotAllowedNow(s.state, s.reasons);
    }

    /// @dev View check for `maxDeposit` and `maxMint`: the lender window per `policy.snapshot()`, no refresh.
    function _lenderWindowOpen() internal view returns (bool) {
        return policy.snapshot().lenderOpen;
    }

    /// @dev View check for `maxWithdraw` and `maxRedeem`: the lender window or wind-down per `policy.snapshot()`.
    function _lenderExitOpen() internal view returns (bool) {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        return s.lenderOpen || s.windDown;
    }

    /// @dev Run-off: shares exist but lender assets are zero, so deposits and mints stop rather than recapitalize
    /// through an arbitrary conversion (docs/SPEC.md §7).
    function _inRunOff() internal view returns (bool) {
        return totalSupply() != 0 && totalAssets() == 0;
    }

    /// @dev Reduce `account`'s debt by up to `amount`; repaying everything clears the shares exactly and removes
    /// the account from the active list. A partial reduction burns floor(amount * SHARE_UNIT / idx) shares, so
    /// rounding favors the lenders. Updates `totalDebtShares`; moves no tokens.
    /// @param account Account whose debt is reduced.
    /// @param a Storage record of `account`.
    /// @param amount Most loan tokens to apply, base units.
    /// @param idx Debt index, WAD.
    /// @return paid Loan tokens applied: `amount`, or the full debt (rounded up) when `amount` covers it.
    /// @return debtAfter Remaining debt, loan-token base units, rounded up.
    function _reduceDebt(address account, Account storage a, uint256 amount, uint256 idx)
        internal
        returns (uint256 paid, uint256 debtAfter)
    {
        uint256 debt = _debt(a.debtShares, idx);
        if (amount >= debt) {
            paid = debt;
            totalDebtShares -= a.debtShares;
            a.debtShares = 0;
            _deactivate(account);
            return (paid, 0);
        }
        paid = amount;
        uint256 shares = amount.mulDiv(SHARE_UNIT, idx);
        a.debtShares -= shares;
        totalDebtShares -= shares;
        debtAfter = _debt(a.debtShares, idx);
    }

    /// @dev Removes `account` from the active list by moving the last entry into its slot; no-op if not listed.
    function _deactivate(address account) internal {
        uint256 slot = _activeSlot[account];
        if (slot == 0) return;
        address last = _active[_active.length - 1];
        _active[slot - 1] = last;
        _activeSlot[last] = slot;
        _active.pop();
        delete _activeSlot[account];
    }

    /// @dev Values every active account at `priceWad` and index `idx`. Per account, debt rounds up and
    /// recoverable = min(debt, floor(value * WAD / (WAD + RECOVERY_HAIRCUT))) rounds down; `impaired` is set when
    /// any recoverable amount is below its debt.
    /// @param priceWad Price to value collateral at, WAD.
    /// @param indicative Copied into the result: whether `priceWad` is the last accepted price.
    /// @param idx Debt index, WAD.
    /// @return b The book valuation.
    function _book(uint256 priceWad, bool indicative, uint256 idx) internal view returns (Book memory b) {
        b.priceWad = priceWad;
        b.indicative = indicative;
        uint256 n = _active.length;
        for (uint256 i; i < n; ++i) {
            Account storage a = _accounts[_active[i]];
            uint256 debt = _debt(a.debtShares, idx);
            uint256 rec = Math.min(debt, _value(a.collateral, priceWad).mulDiv(WAD, WAD + RECOVERY_HAIRCUT));
            b.totalDebt += debt;
            b.recoverable += rec;
            if (rec < debt) b.impaired = true;
        }
    }

    /// @dev Debt index at clock time `t` (UTC seconds), WAD: expWad(RATE_PER_SECOND * (t - epoch)). It depends
    /// only on `t`, so extra calls cannot change accrual. Reverts if `t` is before `epoch`.
    /// @param t Clock time, UTC seconds.
    /// @return Debt index, WAD.
    function _index(uint64 t) internal view returns (uint256) {
        return uint256(FixedPointMathLib.expWad(int256(RATE_PER_SECOND * (t - epoch))));
    }

    /// @dev Collateral value in loan-token base units, rounded down (same formula as PriceGate.valueOf).
    /// @param raw Collateral, raw stock-token units.
    /// @param priceWad Price, WAD.
    /// @return Value, loan-token base units.
    function _value(uint256 raw, uint256 priceWad) internal view returns (uint256) {
        return raw.mulDiv(priceWad, VALUE_SCALE);
    }

    /// @dev Debt for `shares` at index `idx` (WAD), loan-token base units, rounded up: shares * idx / SHARE_UNIT.
    /// @param shares Debt shares (1e18 per base unit of debt at index 1.0).
    /// @param idx Debt index, WAD.
    /// @return Debt, loan-token base units, rounded up.
    function _debt(uint256 shares, uint256 idx) internal pure returns (uint256) {
        return shares.mulDiv(idx, SHARE_UNIT, Math.Rounding.Ceil);
    }

    /// @dev LTV = debt / value, WAD, rounded up; type(uint256).max when `value` is zero.
    /// @param debt Debt, loan-token base units.
    /// @param value Collateral value, loan-token base units.
    /// @return LTV, WAD, rounded up.
    function _ltvCeil(uint256 debt, uint256 value) internal pure returns (uint256) {
        return value == 0 ? type(uint256).max : debt.mulDiv(WAD, value, Math.Rounding.Ceil);
    }

    /// @dev Transfer in and require the full amount to arrive (rejects fee-on-transfer behavior).
    /// Reverts with UnsupportedTransfer when the balance rises by a different amount.
    /// @param token Token to pull: the loan token or the collateral token.
    /// @param from Address the tokens come from; it must have approved the market.
    /// @param amount Amount to pull, in `token` units.
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert UnsupportedTransfer(amount, received);
    }
}
