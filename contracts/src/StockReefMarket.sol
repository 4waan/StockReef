// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IClock} from "./interfaces/IClock.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {RepaymentEscrow} from "./RepaymentEscrow.sol";
import {SessionRules} from "./libraries/SessionRules.sol";
import {StockReefMath} from "./libraries/StockReefMath.sol";

/// @title StockReefMarket
/// @notice Reference lending market for one tokenized stock. Borrowers post the stock token as collateral and
/// borrow the loan token (USDG); lenders deposit the loan token for ERC-4626 shares; anyone with loan tokens can
/// partially liquidate ("trim") a loan whose LTV is above the session's liquidation threshold. Borrowing, trims
/// and lender entry and exit follow the session policy (docs/SPEC.md §3, §4, §5, §7; appendix R8, R16, R17).
/// @dev Units: loan amounts in loan-token base units (USDG: 6 decimals); collateral in raw stock-token units
/// (18 decimals); ratios, bonuses, LT, B, targets, the debt index and `priceWad` in WAD (1e18 = 100% or 1.0),
/// where `priceWad` is loan-token whole units per collateral whole unit; times in UTC seconds from the IClock.
/// Debt shares are scaled so that one base unit of debt at index 1.0 is 1e18 shares, which keeps share rounding
/// far below one base unit. The formulas live in StockReefMath and the session rules in SessionRules.
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
/// transfers and approvals are plain ERC-20. The guard uses transient storage (EIP-1153).
contract StockReefMarket is ERC4626, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using StockReefMath for uint256;

    /// @dev One borrower's position. Debt in loan-token base units is ceil(debtShares * index / 1e36). Both fields
    /// stay full-width: at 1e18 shares per base unit, a 128-bit share count would cap an 18-decimal loan token's
    /// debt at a few hundred whole tokens.
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
    uint256 internal constant WAD = StockReefMath.WAD;
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
    /// @dev Open of the last loaded calendar session, UTC seconds: wind-down starts here (appendix R17), as
    /// SessionRiskPolicy reports with `windDown`.
    uint64 private immutable WIND_DOWN_AT;

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
    /// @notice An account or receiver is the zero address.
    error ZeroAddress();

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
        WIND_DOWN_AT = gate.calendar().lastOpen();
        minLoan = minLoan_;
        epoch = clock.time();
        escrow = new RepaymentEscrow(this, loanToken, policy_);
    }

    // =============================================================== borrower

    /// @notice Add collateral for `account`, paid by the caller. Anyone may call, for any account. Needs no price
    /// and is allowed in every state (docs/SPEC.md §4).
    /// @dev Reverts with ZeroAmount, ZeroAddress, or UnsupportedTransfer if the market receives a different amount.
    /// @param amount Collateral to add, raw stock-token units.
    /// @param account Account to credit; not the zero address.
    function depositCollateral(uint256 amount, address account) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (account == address(0)) revert ZeroAddress();
        _pullExact(collateralToken, msg.sender, amount);
        _accounts[account].collateral += amount;
        emit CollateralDeposited(account, msg.sender, amount);
    }

    /// @notice Withdraw collateral from the caller's own account. Without debt this needs no price and is allowed
    /// in every state. With debt it is a borrow-limit action: it refreshes the gate and needs a state that allows
    /// borrowing (OPEN or PRE_CLOSE with a usable price), no active escrow authorization at or after A, and debt
    /// at most B times the remaining collateral value (docs/SPEC.md §3, §4).
    /// @dev Reverts with ZeroAmount, ZeroAddress, InsufficientCollateral, NotAllowedNow, BufferAuthorizationActive
    /// or AboveBorrowLimit. Debt rounds up and value rounds down, both against the borrower.
    /// @param amount Collateral to withdraw, raw stock-token units.
    /// @param receiver Address that receives the collateral; not the zero address.
    function withdrawCollateral(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        Account storage a = _accounts[msg.sender];
        uint256 collateral = a.collateral;
        if (amount > collateral) revert InsufficientCollateral(amount, collateral);
        collateral -= amount;
        a.collateral = collateral;
        if (a.debtShares != 0) {
            SessionRiskPolicy.Snapshot memory s = _refresh();
            _requireBorrowable(s, msg.sender);
            uint256 debt = a.debtShares.toDebtUp(_index(s.time));
            _requireWithinLimit(s, debt, _value(collateral, s.priceWad));
        }
        collateralToken.safeTransfer(receiver, amount);
        emit CollateralWithdrawn(msg.sender, receiver, amount);
    }

    /// @notice Borrow `amount` loan tokens against the caller's collateral. Refreshes the gate first; allowed only
    /// in OPEN or PRE_CLOSE with a usable price, within the borrow limit B (docs/SPEC.md §3, §7; appendix R8).
    /// @dev Checks, in order: a non-zero amount (ZeroAmount); a receiver (ZeroAddress); borrowing allowed after the
    /// refresh (NotAllowedNow);
    /// no escrow authorization active at or after A (BufferAuthorizationActive); enough idle cash
    /// (InsufficientCash); no impaired account at the current price (MarketImpaired); total debt after the borrow
    /// at most UTILIZATION_CAP of cash plus total debt (UtilizationCapExceeded); a free active slot for an account
    /// without debt (AccountCapReached); previous debt plus `amount` at least `minLoan` (BelowMinimumLoan); and
    /// debt at most B times the collateral value (AboveBorrowLimit). New debt shares round up, so recorded debt
    /// can exceed the previous debt plus `amount` by one base unit.
    /// @param amount Loan tokens to borrow, base units.
    /// @param receiver Address that receives the loan tokens; not the zero address.
    function borrow(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        SessionRiskPolicy.Snapshot memory s = _refresh();
        uint256 idx = _index(s.time);
        (uint256 shares, uint256 debtAfter) = _validateBorrow(s, msg.sender, amount, idx);
        _mintDebt(msg.sender, shares);
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
        uint256 debtAfter;
        (paid, debtAfter) = _reduceDebt(account, a, amount, _index(clock.time()));
        // Repay everything or leave at least the minimum loan, so dust cannot hold an active slot.
        if (debtAfter != 0 && debtAfter < minLoan) revert BelowMinimumLoan(debtAfter, minLoan);
        cash += paid;
        _pullExact(IERC20(asset()), msg.sender, paid);
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

        TrimQuote memory tq = quoteTrim(account, s, maxRepay);
        _validateTrim(s, tq, minCollateralOut);
        (repaid, collateralOut) = (tq.repaid, tq.collateralOut);
        (uint256 debtAfter, uint256 collateralAfter) = _applyTrim(account, s, tq);

        cash += repaid;
        _pullExact(IERC20(asset()), msg.sender, repaid);
        collateralToken.safeTransfer(msg.sender, collateralOut);
        emit Trimmed(account, msg.sender, repaid, collateralOut, tq.bonusWad, s.state, debtAfter, collateralAfter);
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
        t.debt = a.debtShares.toDebtUp(_index(s.time));
        t.value = _value(a.collateral, s.priceWad);
        // Zero debt never exceeds LT, so it needs no separate check.
        t.eligible = s.canTrim && t.debt.exceeds(t.value, s.ltWad);
        if (!t.eligible) return t;
        t.bufferPending = escrow.executable(account, s, t.debt, t.value);
        // `policy.bonusFor` for an eligible snapshot, which always allows trims.
        t.bonusWad = SessionRules.bonus(_preparing(s.state), t.debt.ltvUp(t.value));
        (t.repaid, t.collateralOut, t.fullFill) = _trimAmounts(a.collateral, t.debt, t.value, s, t.bonusWad, maxRepay);
    }

    /// @dev Repayment and collateral transfer for a trim (docs/SPEC.md §5). D and x in loan-token base units.
    /// Solvent (D*(1+b) < V): x = ceil((D - T*V) / (1 - T*(1+b))), capped at D and at `maxRepay`; the seized
    /// collateral is worth x*(1+b), rounded down and capped at the account's collateral.
    /// Insolvent (D*(1+b) >= V): repaying floor(V/(1+b)) takes all collateral; a smaller `maxRepay` takes
    /// collateral worth maxRepay*(1+b), rounded down. When floor(V/(1+b)) is zero the collateral is economically
    /// worthless dust (worth less than one base unit plus the bonus): one base unit takes all of it, and `trim`
    /// writes off what is left, so a write-off is always reachable (docs/SPEC.md §5). This branch never sets
    /// `fullFill`.
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
        if (debt.insolventAt(value, onePlusB)) {
            uint256 all = value.divWadDown(onePlusB);
            if (all == 0) return maxRepay == 0 ? (0, 0, false) : (1, collateral, false); // worthless dust
            repaid = Math.min(maxRepay, all);
            collateralOut = repaid == all ? collateral : repaid.seizeDown(onePlusB, s.priceWad, VALUE_SCALE);
        } else {
            uint256 need = Math.min(debt.trimRepayUp(value, s.targetWad, onePlusB), debt);
            repaid = Math.min(maxRepay, need);
            fullFill = repaid == need;
            collateralOut = Math.min(repaid.seizeDown(onePlusB, s.priceWad, VALUE_SCALE), collateral);
        }
    }

    /// @dev Trim checks after the quote, in order: eligibility (NotEligible), no pending buffer (BufferPending),
    /// something to repay and to release (ZeroAmount), and the caller's minimum (Slippage).
    /// @param s Refreshed snapshot of this transaction.
    /// @param tq Quote at `s`.
    /// @param minCollateralOut Least raw collateral the caller accepts.
    function _validateTrim(SessionRiskPolicy.Snapshot memory s, TrimQuote memory tq, uint256 minCollateralOut)
        internal
        pure
    {
        if (!tq.eligible) revert NotEligible(tq.debt, tq.value, s.ltWad);
        if (tq.bufferPending) revert BufferPending();
        if (tq.repaid == 0 || tq.collateralOut == 0) revert ZeroAmount();
        if (tq.collateralOut < minCollateralOut) revert Slippage();
    }

    /// @dev Applies a validated trim to `account`: reduces the debt by `tq.repaid` and the collateral by
    /// `tq.collateralOut`. When that exhausts the collateral with debt left, the residual is written off; otherwise
    /// a full solvent fill must land within one base unit of target times value (TargetMissed). Moves no tokens.
    /// @param account Trimmed account.
    /// @param s Refreshed snapshot of this transaction.
    /// @param tq Validated quote at `s`.
    /// @return debtAfter Remaining debt, loan-token base units, rounded up; zero after a write-off.
    /// @return collateralAfter Remaining collateral, raw units.
    function _applyTrim(address account, SessionRiskPolicy.Snapshot memory s, TrimQuote memory tq)
        internal
        returns (uint256 debtAfter, uint256 collateralAfter)
    {
        Account storage a = _accounts[account];
        (, debtAfter) = _reduceDebt(account, a, tq.repaid, _index(s.time));
        collateralAfter = a.collateral - tq.collateralOut; // collateralOut is capped at the collateral
        a.collateral = collateralAfter;
        if (collateralAfter == 0 && debtAfter != 0) {
            // Collateral exhausted: recognize the residual as bad debt; lenders already marked it down.
            _clearDebt(account, a);
            totalBadDebt += debtAfter;
            emit BadDebtWrittenOff(account, debtAfter);
            return (0, 0);
        }
        if (tq.fullFill) {
            // A full solvent fill reaches the target within one loan-token base unit.
            uint256 valueAfter = _value(collateralAfter, s.priceWad);
            if (debtAfter * WAD > s.targetWad * valueAfter + WAD) {
                revert TargetMissed(debtAfter, valueAfter, s.targetWad);
            }
        }
    }

    // =============================================================== lenders (ERC-4626)

    /// @inheritdoc ERC4626
    /// @notice Deposit `assets` loan tokens and mint lender shares to `receiver`. Allowed only in OPEN with a
    /// usable price and an unimpaired book (docs/SPEC.md §7, appendix R21).
    /// @dev Refreshes the gate, then values the book once at that price and converts with it. Reverts with
    /// NotAllowedNow outside the lender window, ERC4626ExceededMaxDeposit while the book is impaired or in run-off
    /// (lender assets zero while shares remain) and UnsupportedTransfer when the amount received differs from
    /// `assets`. Shares round down.
    /// @param assets Loan tokens to deposit, base units.
    /// @param receiver Address that receives the shares.
    /// @return Shares minted.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        (uint256 lenderAssets, bool impaired) = _lenderAssets(_requireLenderWindow());
        uint256 maxAssets = _entryOpen(lenderAssets, impaired) ? type(uint256).max : 0;
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        uint256 shares = _toShares(assets, lenderAssets, Math.Rounding.Floor);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @inheritdoc ERC4626
    /// @notice Mint exactly `shares` lender shares to `receiver`, paying the loan tokens they cost. Allowed only
    /// in OPEN with a usable price and an unimpaired book (docs/SPEC.md §7, appendix R21).
    /// @dev Same refresh, valuation and lender-window rules as `deposit`; while impaired or in run-off it reverts
    /// with ERC4626ExceededMaxMint, and with UnsupportedTransfer when the amount received differs. The assets charged
    /// round up, against the caller.
    /// @param shares Shares to mint.
    /// @param receiver Address that receives the shares.
    /// @return Loan tokens taken from the caller, base units.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        (uint256 lenderAssets, bool impaired) = _lenderAssets(_requireLenderWindow());
        uint256 maxShares = _entryOpen(lenderAssets, impaired) ? type(uint256).max : 0;
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        uint256 assets = _toAssets(shares, lenderAssets, Math.Rounding.Ceil);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /// @inheritdoc ERC4626
    /// @notice Withdraw exactly `assets` loan tokens to `receiver`, burning `owner`'s shares. Allowed in OPEN with
    /// a usable price, or in wind-down (from the open of the last loaded session), where lender assets are idle
    /// cash only; limited by idle cash (docs/SPEC.md §7; appendix R17, R19).
    /// @dev Refreshes the gate, then values the book once and converts with it. Reverts with NotAllowedNow when
    /// exits are closed, ERC4626ExceededMaxWithdraw above `maxWithdraw` (the value of `owner`'s shares, capped at
    /// idle cash), and ERC20InsufficientAllowance when a caller other than `owner` lacks share allowance. Shares
    /// burned round up, against the caller.
    /// @param assets Loan tokens to withdraw, base units.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @return Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        (uint256 lenderAssets,) = _lenderAssets(_requireLenderExit());
        uint256 maxAssets = Math.min(_toAssets(balanceOf(owner), lenderAssets, Math.Rounding.Floor), cash);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        uint256 shares = _toShares(assets, lenderAssets, Math.Rounding.Ceil);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    /// @inheritdoc ERC4626
    /// @notice Redeem exactly `shares` of `owner`'s shares for loan tokens sent to `receiver`. Allowed in OPEN with
    /// a usable price, or in wind-down (from the open of the last loaded session), where lender assets are idle
    /// cash only; limited by idle cash (docs/SPEC.md §7; appendix R17, R19).
    /// @dev Refreshes the gate, then values the book once and converts with it. Reverts with NotAllowedNow when
    /// exits are closed, ERC4626ExceededMaxRedeem above `maxRedeem` (the balance, capped at the shares worth the
    /// idle cash), and ERC20InsufficientAllowance when a caller other than `owner` lacks share allowance. Assets
    /// paid round down, against the caller.
    /// @param shares Shares to redeem.
    /// @param receiver Address that receives the loan tokens.
    /// @param owner Address whose shares are burned.
    /// @return Loan tokens paid, base units.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        (uint256 lenderAssets,) = _lenderAssets(_requireLenderExit());
        uint256 maxShares = Math.min(balanceOf(owner), _toShares(cash, lenderAssets, Math.Rounding.Floor));
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        uint256 assets = _toAssets(shares, lenderAssets, Math.Rounding.Floor);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
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
    /// Uses the current price when usable, otherwise the last accepted price (indicative) (docs/SPEC.md §7). In
    /// wind-down, no trim can ever collect a loan's collateral, so lender assets are idle cash only: exits are pro
    /// rata from cash, later repayments raise the share value, and no price or guardian stop affects it (appendix
    /// R19).
    /// @dev View only: it reads the gate's current quote without refreshing it; the share entry and exit
    /// functions refresh first. Escrow balances and tokens sent to the market directly are not counted, and
    /// collateral counts only through each loan's recoverable amount. Recoverable amounts round down. Loops over
    /// at most MAX_ACCOUNTS accounts.
    /// @return Lender assets, loan-token base units.
    function totalAssets() public view override returns (uint256) {
        if (clock.time() >= WIND_DOWN_AT) return cash;
        return cash + bookValuation().recoverable;
    }

    /// @inheritdoc ERC4626
    /// @notice Most loan tokens that can be deposited now, for any receiver (the address argument is ignored):
    /// unlimited while the lender window is open, zero when it is closed, the book is impaired or the vault is in
    /// run-off.
    /// @dev Reads `policy.snapshot()` and `bookValuation()` without refreshing the gate.
    /// @return Loan-token base units; type(uint256).max when unlimited.
    function maxDeposit(address) public view override returns (uint256) {
        return _entryOpenNow() ? type(uint256).max : 0;
    }

    /// @inheritdoc ERC4626
    /// @notice Most shares that can be minted now, for any receiver (the address argument is ignored): unlimited
    /// while the lender window is open, zero when it is closed, the book is impaired or the vault is in run-off.
    /// @dev Reads `policy.snapshot()` and `bookValuation()` without refreshing the gate.
    /// @return Shares; type(uint256).max when unlimited.
    function maxMint(address) public view override returns (uint256) {
        return _entryOpenNow() ? type(uint256).max : 0;
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
    /// @dev Takes `assets` out of `cash`; the base implementation then spends share allowance when `caller` is
    /// not `owner`, burns `shares`, transfers the assets and emits Withdraw. The callers cap `assets` at idle
    /// cash first (the max checks), and the subtraction is checked.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        cash -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev OpenZeppelin's formula at the current lender assets (`totalAssets`).
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return _toShares(assets, totalAssets(), rounding);
    }

    /// @inheritdoc ERC4626
    /// @dev OpenZeppelin's formula at the current lender assets (`totalAssets`).
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return _toAssets(shares, totalAssets(), rounding);
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
        return (a.collateral, a.debtShares, a.debtShares.toDebtUp(_index(clock.time())));
    }

    /// @notice Accrued debt of `account` at the current clock time.
    /// @param account Account to read.
    /// @return Debt, loan-token base units, rounded up; zero without debt.
    function debtOf(address account) public view returns (uint256) {
        return _accounts[account].debtShares.toDebtUp(_index(clock.time()));
    }

    /// @notice Accrued debt of `account` at clock time `t`, at its current debt shares: the debt it will owe at
    /// `t` if nothing changes before then. The Lens uses it to project debt to F, the close and the reopening.
    /// @param account Account to read.
    /// @param t Clock time, UTC seconds; at or after `epoch` (earlier times revert).
    /// @return Debt, loan-token base units, rounded up; zero without debt.
    function debtAt(address account, uint64 t) external view returns (uint256) {
        return _accounts[account].debtShares.toDebtUp(_index(t));
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
        return _bookFor(q.reasons, q.priceWad, clock.time());
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
        if (debt.exceeds(value, s.borrowLimitWad)) revert AboveBorrowLimit(debt, value, s.borrowLimitWad);
    }

    /// @dev Every borrow check in the order documented on `borrow`, after ZeroAmount and the refresh.
    /// @param s Refreshed snapshot of this transaction.
    /// @param account Borrower (the caller).
    /// @param amount Loan tokens to borrow, base units.
    /// @param idx Debt index at `s.time`, WAD.
    /// @return shares Debt shares to mint, rounded up.
    /// @return debtAfter Account debt after the borrow, loan-token base units, rounded up.
    function _validateBorrow(SessionRiskPolicy.Snapshot memory s, address account, uint256 amount, uint256 idx)
        internal
        view
        returns (uint256 shares, uint256 debtAfter)
    {
        _requireBorrowable(s, account);
        if (amount > cash) revert InsufficientCash(amount, cash);

        Book memory book = _book(s.priceWad, false, idx);
        if (book.impaired) revert MarketImpaired();
        if ((book.totalDebt + amount).exceeds(cash + book.totalDebt, UTILIZATION_CAP)) {
            revert UtilizationCapExceeded();
        }

        Account storage a = _accounts[account];
        uint256 sharesBefore = a.debtShares;
        if (sharesBefore == 0 && _active.length >= MAX_ACCOUNTS) revert AccountCapReached();
        // The minimum applies to principal; the share rounding below adds at most one base unit of debt.
        uint256 debtBefore = sharesBefore.toDebtUp(idx);
        if (debtBefore + amount < minLoan) revert BelowMinimumLoan(debtBefore + amount, minLoan);
        shares = amount.toSharesUp(idx);
        debtAfter = (sharesBefore + shares).toDebtUp(idx);
        _requireWithinLimit(s, debtAfter, _value(a.collateral, s.priceWad));
    }

    /// @dev Adds `shares` of debt to `account`, listing it as active when it had no debt.
    /// @param account Borrower.
    /// @param shares Debt shares to add.
    function _mintDebt(address account, uint256 shares) internal {
        Account storage a = _accounts[account];
        if (a.debtShares == 0) {
            _active.push(account);
            _activeSlot[account] = _active.length;
        }
        a.debtShares += shares;
        totalDebtShares += shares;
    }

    /// @dev Deposits and mints: refreshes, then reverts with NotAllowedNow unless the lender window is open
    /// (OPEN with a usable price).
    /// @return s The refreshed snapshot.
    function _requireLenderWindow() internal returns (SessionRiskPolicy.Snapshot memory s) {
        s = _refresh();
        if (!s.lenderOpen) revert NotAllowedNow(s.state, s.reasons);
    }

    /// @dev Withdrawals and redemptions: the scheduled window, or wind-down from the open of the last loaded
    /// session, when lenders exit against idle cash at the gate's last accepted price and repayments keep adding
    /// to that cash. Refreshes, then reverts with NotAllowedNow otherwise (appendix R17).
    /// @return s The refreshed snapshot.
    function _requireLenderExit() internal returns (SessionRiskPolicy.Snapshot memory s) {
        s = _refresh();
        if (!s.lenderOpen && !s.windDown) revert NotAllowedNow(s.state, s.reasons);
    }

    /// @dev Lender assets (`totalAssets`) for a refreshed snapshot of this transaction: after `gate.refresh()`,
    /// the gate's view quote at the same time carries the same reasons and price, so this is the value
    /// `totalAssets` would return, computed once. In wind-down it is idle cash only.
    /// @param s Refreshed snapshot.
    /// @return assets Cash plus recoverable (cash only in wind-down), loan-token base units.
    /// @return impaired The book is impaired at that valuation; false in wind-down.
    function _lenderAssets(SessionRiskPolicy.Snapshot memory s) internal view returns (uint256 assets, bool impaired) {
        if (s.windDown) return (cash, false);
        Book memory b = _bookFor(s.reasons, s.priceWad, s.time);
        return (cash + b.recoverable, b.impaired);
    }

    /// @dev OpenZeppelin's ERC-4626 share conversion at lender assets `lenderAssets`: assets * (supply + 10^6) /
    /// (lenderAssets + 1).
    function _toShares(uint256 assets, uint256 lenderAssets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), lenderAssets + 1, rounding);
    }

    /// @dev OpenZeppelin's ERC-4626 asset conversion at lender assets `lenderAssets`: shares * (lenderAssets + 1) /
    /// (supply + 10^6).
    function _toAssets(uint256 shares, uint256 lenderAssets, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(lenderAssets + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev View check for `maxDeposit` and `maxMint`: the lender window per `policy.snapshot()` and the entry
    /// rule of `_entryOpen` at `bookValuation()`, no refresh. The window is never open in wind-down.
    function _entryOpenNow() internal view returns (bool) {
        if (!policy.snapshot().lenderOpen) return false;
        Book memory b = bookValuation();
        return _entryOpen(cash + b.recoverable, b.impaired);
    }

    /// @dev Lender entry (deposit, mint) inside the window: closed while the book is impaired (appendix R21) or the
    /// vault is in run-off, where shares exist but lender assets are zero, so deposits stop rather than
    /// recapitalize through an arbitrary conversion (docs/SPEC.md §7).
    /// @param lenderAssets Lender assets at this call's valuation, loan-token base units.
    /// @param impaired The book is impaired at that valuation.
    function _entryOpen(uint256 lenderAssets, bool impaired) internal view returns (bool) {
        return !impaired && (totalSupply() == 0 || lenderAssets != 0);
    }

    /// @dev View check for `maxWithdraw` and `maxRedeem`: the lender window or wind-down per `policy.snapshot()`.
    function _lenderExitOpen() internal view returns (bool) {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        return s.lenderOpen || s.windDown;
    }

    /// @dev Reduce `account`'s debt by up to `amount`; repaying everything clears the shares exactly and removes
    /// the account from the active list. A partial reduction burns floor(amount * 1e36 / idx) shares, so
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
        uint256 shares = a.debtShares;
        uint256 debt = shares.toDebtUp(idx);
        if (amount >= debt) {
            _clearDebt(account, a);
            return (debt, 0);
        }
        // amount < debt = ceil(shares * idx / 1e36), so the burn is strictly below `shares`.
        uint256 burn = amount.toSharesDown(idx);
        shares -= burn;
        a.debtShares = shares;
        totalDebtShares -= burn;
        return (amount, shares.toDebtUp(idx));
    }

    /// @dev Clears all of `account`'s debt shares and removes it from the active list (full repayment or a
    /// write-off).
    /// @param account Account whose debt is cleared.
    /// @param a Storage record of `account`.
    function _clearDebt(address account, Account storage a) internal {
        totalDebtShares -= a.debtShares;
        a.debtShares = 0;
        _deactivate(account);
    }

    /// @dev Removes `account` from the active list by moving the last entry into its slot. Called only for an
    /// account with debt, which is always listed: borrow lists it when its shares go from zero, and only
    /// `_clearDebt` sets them back to zero (a partial reduction never does). An unlisted account would panic here.
    function _deactivate(address account) internal {
        uint256 slot = _activeSlot[account];
        address last = _active[_active.length - 1];
        _active[slot - 1] = last;
        _activeSlot[last] = slot;
        _active.pop();
        delete _activeSlot[account];
    }

    /// @dev The book at a quote's reasons and price: the price itself when `reasons` is zero, otherwise the gate's
    /// last accepted price, flagged as indicative.
    /// @param reasons Reasons bits of the quote.
    /// @param priceWad Price of the quote, WAD.
    /// @param t Clock time, UTC seconds.
    /// @return The book valuation.
    function _bookFor(uint32 reasons, uint256 priceWad, uint64 t) internal view returns (Book memory) {
        bool indicative = reasons != 0;
        return _book(indicative ? gate.lastPriceWad() : priceWad, indicative, _index(t));
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
            uint256 debt = a.debtShares.toDebtUp(idx);
            uint256 rec = debt.recoverableDown(_value(a.collateral, priceWad), RECOVERY_HAIRCUT);
            b.totalDebt += debt;
            b.recoverable += rec;
            if (rec < debt) b.impaired = true;
        }
    }

    /// @dev True in PRE_CLOSE and FINAL_WINDOW, where a position at or below 80% is trimmed at the scheduling
    /// bonus (SessionRiskPolicy.bonusFor).
    function _preparing(SessionRiskPolicy.State st) internal pure returns (bool) {
        return st == SessionRiskPolicy.State.PRE_CLOSE || st == SessionRiskPolicy.State.FINAL_WINDOW;
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
        return raw.toValueDown(priceWad, VALUE_SCALE);
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
