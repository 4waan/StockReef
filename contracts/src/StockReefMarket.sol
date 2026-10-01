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
/// @notice Reference lending market: one stock-token collateral, one loan token (USDG), ERC-4626 lender
/// shares, session-aware borrowing and partial liquidation (docs/SPEC.md §4, §5, §7; appendix R2, R8).
///
/// Units: loan amounts in loan-token base units (USDG: 6 decimals); collateral in raw token units; ratios,
/// bonuses and the debt index in WAD. Debt shares are scaled so that one base unit of debt at index 1.0 is
/// 1e18 shares, which keeps share rounding far below one base unit.
contract StockReefMarket is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Account {
        uint256 collateral; // raw token units
        uint256 debtShares;
    }

    struct Book {
        uint256 priceWad; // price used for this valuation
        bool indicative; // true when `priceWad` is the last accepted price, not a current one
        uint256 totalDebt; // accrued debt of all accounts, rounded up
        uint256 recoverable; // sum of min(debt, value / 1.05), rounded down
        bool impaired; // some account's debt exceeds its recoverable value
    }

    struct Trim {
        uint256 idx;
        uint256 bonusWad;
        uint256 repaid;
        uint256 collateralOut;
        bool fullFill;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SHARE_UNIT = 1e36; // debt shares per base unit at index 1.0, times WAD
    uint256 public constant MAX_ACCOUNTS = 32;
    uint256 public constant UTILIZATION_CAP = 0.9e18;
    uint256 public constant RECOVERY_HAIRCUT = 0.05e18;
    /// @dev 10% a year, continuously compounded per second from the deployment epoch: index = exp(r * t).
    uint256 public constant RATE_PER_SECOND = 3170979198;

    IERC20 public immutable collateralToken;
    PriceGate public immutable gate;
    SessionRiskPolicy public immutable policy;
    IClock public immutable clock;
    RepaymentEscrow public immutable escrow;
    uint64 public immutable epoch;
    uint256 public immutable minLoan;
    uint256 public immutable VALUE_SCALE; // 10^(token decimals + 18 - loan decimals), as in PriceGate

    uint256 public cash; // loan tokens held for lenders (excludes donations, collateral and escrow)
    uint256 public totalDebtShares;
    uint256 public totalBadDebt; // cumulative written-off debt
    mapping(address => Account) internal _accounts;
    address[] internal _active; // accounts with debt
    mapping(address => uint256) internal _activeSlot; // index in _active plus one

    event CollateralDeposited(address indexed account, address indexed payer, uint256 amount);
    event CollateralWithdrawn(address indexed account, address indexed receiver, uint256 amount);
    event Borrowed(address indexed account, address indexed receiver, uint256 amount, uint256 debtAfter);
    event Repaid(address indexed account, address indexed payer, uint256 amount, uint256 debtAfter);
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
    event BadDebtWrittenOff(address indexed account, uint256 amount);

    error ZeroAmount();
    error NotAllowedNow(SessionRiskPolicy.State state, uint32 reasons);
    error BufferAuthorizationActive();
    error AccountCapReached();
    error BelowMinimumLoan(uint256 debtAfter, uint256 minLoan);
    error AboveBorrowLimit(uint256 debtAfter, uint256 collateralValue, uint256 borrowLimitWad);
    error MarketImpaired();
    error UtilizationCapExceeded();
    error InsufficientCash(uint256 requested, uint256 available);
    error InsufficientCollateral(uint256 requested, uint256 available);
    error NoDebt();
    error UnsupportedTransfer(uint256 expected, uint256 received);
    error DeadlinePassed();
    error NotEligible(uint256 debt, uint256 value, uint256 ltWad);
    error BufferPending();
    error Slippage();
    error TargetMissed(uint256 debtAfter, uint256 valueAfter, uint256 targetWad);
    error ConfigMismatch();

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

    /// @notice Add collateral for `account`. Needs no price and is allowed in every state.
    function depositCollateral(uint256 amount, address account) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pullExact(collateralToken, msg.sender, amount);
        _accounts[account].collateral += amount;
        emit CollateralDeposited(account, msg.sender, amount);
    }

    /// @notice Withdraw collateral. Without debt this needs no price; with debt it is a borrow-limit action.
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

    /// @notice Borrow `amount` loan tokens against the caller's collateral.
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
        uint256 shares = amount.mulDiv(SHARE_UNIT, idx, Math.Rounding.Ceil);
        a.debtShares += shares;
        totalDebtShares += shares;
        uint256 debtAfter = _debt(a.debtShares, idx);
        if (debtAfter < minLoan) revert BelowMinimumLoan(debtAfter, minLoan);
        _requireWithinLimit(s, debtAfter, _value(a.collateral, s.priceWad));

        cash -= amount;
        IERC20(asset()).safeTransfer(receiver, amount);
        emit Borrowed(msg.sender, receiver, amount, debtAfter);
    }

    /// @notice Repay up to `amount` of `account`'s debt. Needs no price and is allowed in every state.
    /// @return paid The amount actually taken from the caller.
    function repay(uint256 amount, address account) external nonReentrant returns (uint256 paid) {
        if (amount == 0) revert ZeroAmount();
        Account storage a = _accounts[account];
        if (a.debtShares == 0) revert NoDebt();
        uint256 idx = _index(clock.time());
        uint256 debtAfter;
        (paid, debtAfter) = _reduceDebt(account, a, amount, idx);
        _pullExact(IERC20(asset()), msg.sender, paid);
        cash += paid;
        emit Repaid(account, msg.sender, paid, debtAfter);
    }

    // =============================================================== liquidation

    /// @notice Partially liquidate `account` toward the current target at the current accepted price. The
    /// caller supplies the loan tokens and receives collateral worth the repayment plus the applicable bonus.
    /// @param maxRepay Most the caller will repay.
    /// @param minCollateralOut Least raw collateral the caller accepts.
    /// @param deadline Latest clock time at which the trim may execute.
    function trim(address account, uint256 maxRepay, uint256 minCollateralOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 repaid, uint256 collateralOut)
    {
        if (maxRepay == 0) revert ZeroAmount();
        SessionRiskPolicy.Snapshot memory s = _refresh();
        if (s.time > deadline) revert DeadlinePassed();
        if (!s.canTrim) revert NotAllowedNow(s.state, s.reasons);

        Trim memory t = _planTrim(account, s, maxRepay);
        repaid = t.repaid;
        collateralOut = t.collateralOut;
        if (repaid == 0 || collateralOut == 0) revert ZeroAmount();
        if (collateralOut < minCollateralOut) revert Slippage();

        Account storage a = _accounts[account];
        (, uint256 debtAfter) = _reduceDebt(account, a, repaid, t.idx);
        a.collateral -= collateralOut;
        if (a.collateral == 0 && debtAfter != 0) {
            // Collateral exhausted: recognise the residual as bad debt; lenders already marked it down.
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

    /// @notice What `trim(account, maxRepay, ...)` would do at snapshot `s`, or revert if it is not eligible.
    function _planTrim(address account, SessionRiskPolicy.Snapshot memory s, uint256 maxRepay)
        internal
        view
        returns (Trim memory t)
    {
        Account storage a = _accounts[account];
        t.idx = _index(s.time);
        uint256 debt = _debt(a.debtShares, t.idx);
        uint256 value = _value(a.collateral, s.priceWad);
        if (debt == 0 || debt * WAD <= s.ltWad * value) revert NotEligible(debt, value, s.ltWad);
        if (escrow.executable(account, s, debt, value)) revert BufferPending();
        t.bonusWad = policy.bonusFor(s, _ltvCeil(debt, value));
        (t.repaid, t.collateralOut, t.fullFill) = _trimAmounts(a.collateral, debt, value, s, t.bonusWad, maxRepay);
    }

    /// @notice Repayment and collateral transfer for a trim (docs/SPEC.md §5).
    /// Solvent: x = ceil((D - T*V) / (1 - T*(1+b))), seized collateral worth x*(1+b), rounded down.
    /// Insolvent (D*(1+b) >= V): repaying floor(V/(1+b)) takes all collateral.
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

    function _collateralFor(uint256 repaid, uint256 onePlusB, uint256 priceWad) internal view returns (uint256) {
        return (repaid * onePlusB).mulDiv(VALUE_SCALE, priceWad * WAD);
    }

    // =============================================================== lenders (ERC-4626)

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _requireLenderWindow();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice deposit() with a minimum number of shares.
    function depositChecked(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares) {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert Slippage();
    }

    /// @notice mint() with a maximum number of assets.
    function mintChecked(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets) {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert Slippage();
    }

    /// @notice withdraw() with a maximum number of shares burned.
    function withdrawChecked(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        returns (uint256 shares)
    {
        shares = withdraw(assets, receiver, owner);
        if (shares > maxShares) revert Slippage();
    }

    /// @notice redeem() with a minimum number of assets.
    function redeemChecked(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner);
        if (assets < minAssets) revert Slippage();
    }

    /// @notice Cash plus the recoverable value of every loan: sum of min(debt, collateral value / 1.05).
    /// Uses the current price when usable, otherwise the last accepted price (indicative).
    function totalAssets() public view override returns (uint256) {
        return cash + bookValuation().recoverable;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (!_lenderWindowOpen() || _inRunOff()) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (!_lenderWindowOpen() || _inRunOff()) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!_lenderWindowOpen()) return 0;
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), cash);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (!_lenderWindowOpen()) return 0;
        return Math.min(balanceOf(owner), _convertToShares(cash, Math.Rounding.Floor));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _pullExact(IERC20(asset()), caller, assets);
        cash += assets;
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > cash) revert InsufficientCash(assets, cash);
        cash -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // =============================================================== views

    function accountOf(address account) external view returns (uint256 collateral, uint256 debtShares, uint256 debt) {
        Account storage a = _accounts[account];
        return (a.collateral, a.debtShares, _debt(a.debtShares, _index(clock.time())));
    }

    function debtOf(address account) public view returns (uint256) {
        return _debt(_accounts[account].debtShares, _index(clock.time()));
    }

    function collateralOf(address account) external view returns (uint256) {
        return _accounts[account].collateral;
    }

    function activeAccounts() external view returns (address[] memory) {
        return _active;
    }

    function debtIndex() external view returns (uint256) {
        return _index(clock.time());
    }

    /// @notice Lender book at one price snapshot: the current quote if usable, else the last accepted price.
    function bookValuation() public view returns (Book memory) {
        PriceGate.Quote memory q = gate.quote();
        bool indicative = q.reasons != 0;
        return _book(indicative ? gate.lastPriceWad() : q.priceWad, indicative, _index(clock.time()));
    }

    // =============================================================== internals

    function _refresh() internal returns (SessionRiskPolicy.Snapshot memory) {
        return policy.evaluate(gate.refresh(), clock.time());
    }

    function _requireBorrowable(SessionRiskPolicy.Snapshot memory s, address account) internal view {
        if (!s.canBorrow) revert NotAllowedNow(s.state, s.reasons);
        if (escrow.blocksBorrowing(account, s)) revert BufferAuthorizationActive();
    }

    function _requireWithinLimit(SessionRiskPolicy.Snapshot memory s, uint256 debt, uint256 value) internal pure {
        if (debt * WAD > s.borrowLimitWad * value) revert AboveBorrowLimit(debt, value, s.borrowLimitWad);
    }

    function _requireLenderWindow() internal {
        SessionRiskPolicy.Snapshot memory s = _refresh();
        if (!s.lenderOpen) revert NotAllowedNow(s.state, s.reasons);
    }

    function _lenderWindowOpen() internal view returns (bool) {
        return policy.snapshot().lenderOpen;
    }

    function _inRunOff() internal view returns (bool) {
        return totalSupply() != 0 && totalAssets() == 0;
    }

    /// @dev Reduce `account`'s debt by up to `amount`; repaying everything clears the shares exactly.
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

    function _deactivate(address account) internal {
        uint256 slot = _activeSlot[account];
        if (slot == 0) return;
        address last = _active[_active.length - 1];
        _active[slot - 1] = last;
        _activeSlot[last] = slot;
        _active.pop();
        delete _activeSlot[account];
    }

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

    function _index(uint64 t) internal view returns (uint256) {
        return uint256(FixedPointMathLib.expWad(int256(RATE_PER_SECOND * (t - epoch))));
    }

    /// @dev Collateral value in loan-token base units, rounded down (same formula as PriceGate.valueOf).
    function _value(uint256 raw, uint256 priceWad) internal view returns (uint256) {
        return raw.mulDiv(priceWad, VALUE_SCALE);
    }

    function _debt(uint256 shares, uint256 idx) internal pure returns (uint256) {
        return shares.mulDiv(idx, SHARE_UNIT, Math.Rounding.Ceil);
    }

    function _ltvCeil(uint256 debt, uint256 value) internal pure returns (uint256) {
        return value == 0 ? type(uint256).max : debt.mulDiv(WAD, value, Math.Rounding.Ceil);
    }

    /// @dev Transfer in and require the full amount to arrive (rejects fee-on-transfer behaviour).
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert UnsupportedTransfer(amount, received);
    }
}
