// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionCalendar} from "./SessionCalendar.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {StockReefMarket} from "./StockReefMarket.sol";
import {RepaymentEscrow} from "./RepaymentEscrow.sol";
import {SessionTiming} from "./libraries/SessionTiming.sol";

/// @title StockReefLens
/// @notice Read-only answers for the app and the keeper, one call per view (docs/SPEC.md §9). The borrower
/// view answers: what must I repay or add, by when, what can happen if I do nothing, and did it execute?
/// Amounts are loan-token base units unless named otherwise; ratios are WAD.
contract StockReefLens {
    struct MarketView {
        SessionRiskPolicy.Snapshot policy;
        bool simulationClock; // DemoClock: time can be advanced by the demo operator
        bool usesPeg; // loan token valued by a labelled 1:1 test peg
        string pegLabel;
        uint256 cash;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 totalDebt;
        uint256 recoverable;
        bool impaired;
        bool valuationIndicative; // valued at the last accepted price, not a current one
        uint256 valuationPriceWad;
        uint256 utilizationWad; // total debt / (cash + total debt)
        uint256 totalBadDebt;
        uint256 activeAccounts;
        uint256 maxAccounts;
        uint256 minLoan;
        uint64 lastAcceptedAt;
        uint64 lenderWindowOpensAt; // zero while open now
        uint64 lenderWindowClosesAt;
        uint256 pendingMultiplier; // ERC-8056 multiplier taking effect at `multiplierEffectiveAt`, if pending
        uint64 multiplierEffectiveAt;
        uint256 debtIndex;
    }

    struct AccountView {
        address account;
        uint256 collateral; // raw token units
        uint256 collateralValue;
        bool valuationIndicative;
        uint256 debt;
        uint256 ltvWad; // rounded up; max when collateral is worthless
        uint256 borrowCapacity; // additional debt allowed right now; zero when borrowing is closed
        // Closure plan: reach the target of the close that governs the current limits.
        uint256 planTargetWad;
        uint256 repayToTarget;
        uint256 addCollateralValueToTarget;
        uint256 addCollateralRawToTarget;
        // If nothing is done before F: the trim a liquidator could make at the current price and debt.
        bool trimmableAtFinal;
        uint256 trimAtFinalRepay;
        uint256 trimAtFinalCollateral;
        uint256 trimAtFinalBonusWad;
        // Right now.
        StockReefMarket.TrimQuote trimNow;
        // Funded buffer.
        RepaymentEscrow.Plan plan;
        bool bufferActive;
        bool bufferCommitted;
        uint256 bufferCoverage; // what the buffer would repay in preparation, at the current price
        uint256 bufferExecutableNow;
        // The account entered a closure still above the closing threshold: nobody reduced the debt in time.
        bool missedExecution;
        uint256 exposure; // repayment that would still be needed to reach the target
    }

    uint256 internal constant WAD = 1e18;

    StockReefMarket public immutable market;
    RepaymentEscrow public immutable escrow;
    SessionRiskPolicy public immutable policy;
    PriceGate public immutable gate;
    SessionCalendar public immutable calendar;

    constructor(StockReefMarket market_) {
        market = market_;
        escrow = market_.escrow();
        policy = market_.policy();
        gate = market_.gate();
        calendar = gate.calendar();
    }

    // ---------------------------------------------------------------- market

    function marketView() external view returns (MarketView memory m) {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        m.policy = s;
        m.simulationClock = gate.clock().isSimulation();
        m.usesPeg = gate.usesPeg();
        m.pegLabel = gate.pegLabel();
        m.cash = market.cash();
        m.totalAssets = market.totalAssets();
        m.totalShares = market.totalSupply();
        StockReefMarket.Book memory b = market.bookValuation();
        m.totalDebt = b.totalDebt;
        m.recoverable = b.recoverable;
        m.impaired = b.impaired;
        m.valuationIndicative = b.indicative;
        m.valuationPriceWad = b.priceWad;
        uint256 book = m.cash + m.totalDebt;
        m.utilizationWad = book == 0 ? 0 : Math.mulDiv(m.totalDebt, WAD, book);
        m.totalBadDebt = market.totalBadDebt();
        m.activeAccounts = market.activeAccounts().length;
        m.maxAccounts = market.MAX_ACCOUNTS();
        m.minLoan = market.minLoan();
        m.lastAcceptedAt = gate.lastAcceptedAt();
        (m.lenderWindowOpensAt, m.lenderWindowClosesAt) = _lenderWindow(s);
        (m.pendingMultiplier, m.multiplierEffectiveAt) = _pendingMultiplier(s.time);
        m.debtIndex = market.debtIndex();
    }

    // ---------------------------------------------------------------- accounts

    function accountView(address account) public view returns (AccountView memory v) {
        return _accountView(account, policy.snapshot(), market.bookValuation().priceWad);
    }

    /// @notice Every account with debt, for the operations view and the keeper.
    function activeAccountViews() external view returns (AccountView[] memory views) {
        address[] memory list = market.activeAccounts();
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 price = market.bookValuation().priceWad;
        views = new AccountView[](list.length);
        for (uint256 i; i < list.length; ++i) {
            views[i] = _accountView(list[i], s, price);
        }
    }

    function _accountView(address account, SessionRiskPolicy.Snapshot memory s, uint256 price)
        internal
        view
        returns (AccountView memory v)
    {
        v.account = account;
        v.collateral = market.collateralOf(account);
        v.debt = market.debtOf(account);
        v.valuationIndicative = s.reasons != 0;
        v.collateralValue = price == 0 ? 0 : gate.valueOf(v.collateral, price);
        v.ltvWad = v.debt == 0
            ? 0
            : v.collateralValue == 0
                ? type(uint256).max
                : Math.mulDiv(v.debt, WAD, v.collateralValue, Math.Rounding.Ceil);
        v.borrowCapacity = _borrowCapacity(account, s, v);

        v.planTargetWad = policy.targetOf(s.closureClass);
        if (v.debt * WAD > v.planTargetWad * v.collateralValue) {
            v.repayToTarget = Math.ceilDiv(v.debt * WAD - v.planTargetWad * v.collateralValue, WAD);
            v.addCollateralValueToTarget =
                Math.mulDiv(v.debt, WAD, v.planTargetWad, Math.Rounding.Ceil) - v.collateralValue;
            if (price != 0) {
                v.addCollateralRawToTarget = gate.rawForValue(v.addCollateralValueToTarget, price, Math.Rounding.Ceil);
            }
        }

        if (
            s.phase == SessionRiskPolicy.State.OPEN || s.phase == SessionRiskPolicy.State.PRE_CLOSE
                || s.phase == SessionRiskPolicy.State.FINAL_WINDOW
        ) {
            StockReefMarket.TrimQuote memory f = market.quoteTrim(account, _atFinal(s, price), type(uint256).max);
            v.trimmableAtFinal = f.eligible;
            v.trimAtFinalRepay = f.repaid;
            v.trimAtFinalCollateral = f.collateralOut;
            v.trimAtFinalBonusWad = f.bonusWad;
        }
        v.trimNow = market.quoteTrim(account, s, type(uint256).max);

        v.plan = escrow.planOf(account);
        v.bufferActive = v.plan.targetWad != 0 && s.time < v.plan.expiry;
        v.bufferCommitted = escrow.committed(account);
        v.bufferExecutableNow = escrow.executableAmount(account, s, v.debt, v.collateralValue);
        v.bufferCoverage = escrow.executableAmount(account, _buffering(s), v.debt, v.collateralValue);

        bool closedPhase = s.phase == SessionRiskPolicy.State.CLOSED || s.phase == SessionRiskPolicy.State.REOPEN_WAIT;
        // Missed: still above the closing threshold, so it was trimmable at F and nobody reduced it. A position
        // between the target and that threshold may enter a closure without action (docs/SPEC.md §3).
        v.missedExecution = closedPhase && v.debt != 0 && v.debt * WAD > s.ltWad * v.collateralValue;
        v.exposure = v.missedExecution ? v.repayToTarget : 0;
    }

    function _borrowCapacity(address account, SessionRiskPolicy.Snapshot memory s, AccountView memory v)
        internal
        view
        returns (uint256)
    {
        if (!s.canBorrow || escrow.blocksBorrowing(account, s)) return 0;
        if (v.debt == 0 && market.activeAccounts().length >= market.MAX_ACCOUNTS()) return 0;
        StockReefMarket.Book memory b = market.bookValuation();
        if (b.impaired) return 0;
        uint256 limit = Math.mulDiv(s.borrowLimitWad, v.collateralValue, WAD);
        if (limit <= v.debt + 1) return 0;
        uint256 cap = limit - v.debt - 1; // one base unit for share rounding
        uint256 cash = market.cash();
        uint256 utilizationRoom = Math.mulDiv(market.UTILIZATION_CAP(), cash + b.totalDebt, WAD);
        utilizationRoom = utilizationRoom > b.totalDebt ? utilizationRoom - b.totalDebt : 0;
        return Math.min(cap, Math.min(cash, utilizationRoom));
    }

    /// @dev The policy at F for the coming close, at the current price and debt, without any buffer.
    function _atFinal(SessionRiskPolicy.Snapshot memory s, uint256 price)
        internal
        view
        returns (SessionRiskPolicy.Snapshot memory f)
    {
        f.time = s.time;
        f.state = SessionRiskPolicy.State.FINAL_WINDOW;
        f.phase = SessionRiskPolicy.State.FINAL_WINDOW;
        f.priceWad = price;
        f.canTrim = true;
        f.ltWad = policy.ltFinalOf(s.closureClass);
        f.targetWad = policy.targetOf(s.closureClass);
    }

    /// @dev The current snapshot as if buffers could execute, to size what a funded plan would repay.
    function _buffering(SessionRiskPolicy.Snapshot memory s)
        internal
        pure
        returns (SessionRiskPolicy.Snapshot memory b)
    {
        b.time = s.time;
        b.session = s.session;
        b.canBuffer = true;
    }

    // ---------------------------------------------------------------- windows and corporate actions

    /// @dev When lender deposits and withdrawals are next allowed, and when that window closes.
    function _lenderWindow(SessionRiskPolicy.Snapshot memory s)
        internal
        view
        returns (uint64 opensAt, uint64 closesAt)
    {
        if (!s.covered) return (0, 0);
        if (s.state == SessionRiskPolicy.State.OPEN) return (0, s.prepAt);
        bool inSession = s.time >= s.open && s.time < s.close;
        if (inSession && s.time < s.prepAt) {
            opensAt = s.creditAt != 0 ? s.creditAt : s.open + SessionTiming.CREDIT_AFTER;
            return (opensAt, s.prepAt);
        }
        if (s.session + 1 >= calendar.sessionCount()) return (0, 0);
        (uint64 open, uint64 close) = calendar.sessionAt(s.session + 1);
        return (open + SessionTiming.CREDIT_AFTER, close - SessionTiming.PREP);
    }

    function _pendingMultiplier(uint64 t) internal view returns (uint256 multiplier, uint64 effectiveAt) {
        IStockToken token = gate.token();
        try token.effectiveAt() returns (uint256 e) {
            if (e > t) {
                effectiveAt = uint64(e);
                try token.newUIMultiplier() returns (uint256 mult) {
                    multiplier = mult;
                } catch {}
            }
        } catch {}
    }
}
