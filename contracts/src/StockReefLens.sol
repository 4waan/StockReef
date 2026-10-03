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
/// @notice Read-only answers for the app and the keeper, one call per view (docs/SPEC.md §9). The market view
/// gives the session, the lender book and the next lender window. The borrower view answers: what must I repay or
/// add, by when, what can happen if I do nothing, and did it execute?
/// @dev Units: loan amounts in loan-token base units (USDG: 6 decimals); collateral in raw stock-token units
/// (18 decimals); ratios, bonuses, LT, B, targets, the debt index and prices in WAD (1e18 = 100% or 1.0), where
/// `priceWad` is loan-token whole units per collateral whole unit, scaled by 1e18; times in UTC seconds from the
/// IClock (a DemoClock on demo deployments).
///
/// Snapshot: every view reads `policy.snapshot()` and `market.bookValuation()`, which use `gate.quote()` and
/// record nothing. A state-changing call refreshes the gate first and can see a different state, for example an
/// admitted reopening where the view still shows REOPEN_WAIT, so the keeper refreshes before acting. Collateral is
/// valued at the book price: the current quote when it is usable, otherwise the gate's last accepted price,
/// flagged as indicative (docs/SPEC.md §4 and §7); zero when the quote is unusable and no refresh has ever
/// accepted a price.
///
/// Trust: no owner, no storage writes and no admin functions. It reads the market it is built with and the
/// escrow, policy, gate and calendar that market uses. No StockReef contract calls the lens, and every action
/// recomputes its own limits, so the lens cannot change what any action does. The views loop over at most
/// MAX_ACCOUNTS accounts (appendix R8) and are meant for off-chain calls.
contract StockReefLens {
    /// @notice Market-wide state for the Lend and Operations views (docs/SPEC.md §7 and §9).
    /// @dev The book fields come from one `market.bookValuation()`: the current quote when usable, otherwise the
    /// last accepted price (`valuationIndicative`). Lender window opening times are the earliest possible; see
    /// `marketView` and `_lenderWindow` for how they are chosen.
    struct MarketView {
        SessionRiskPolicy.Snapshot policy; // policy at the clock time for the gate's view quote; see Snapshot
        bool simulationClock; // DemoClock: time can be advanced by the demo operator
        bool usesPeg; // loan token valued by a labelled 1:1 test peg
        string pegLabel; // label of that peg; empty when a loan-token feed is configured
        uint256 cash; // idle loan tokens held for lenders, base units
        uint256 totalAssets; // lender assets: cash plus recoverable, base units
        uint256 totalShares; // lender ERC-4626 share supply (loan-token decimals + 6)
        uint256 totalDebt; // accrued debt of all active accounts, base units, each rounded up
        uint256 recoverable; // sum of min(debt, value / 1.05), base units, rounded down
        bool impaired; // some account's debt exceeds its recoverable value; new borrowing is blocked
        bool valuationIndicative; // valued at the last accepted price, not a current one
        uint256 valuationPriceWad; // price of the book valuation, WAD; zero if indicative and none was ever accepted
        uint256 utilizationWad; // total debt / (cash + total debt), WAD, rounded down; zero when both are zero
        uint256 totalBadDebt; // debt written off since deployment, base units
        uint256 activeAccounts; // number of accounts holding debt
        uint256 maxAccounts; // most accounts that may hold debt at once (MAX_ACCOUNTS, 32)
        uint256 minLoan; // minimum loan, base units (appendix R8, R16)
        uint64 lastAcceptedAt; // clock time of the refresh that accepted the last usable price, UTC seconds; 0 if none
        // Lender window: both fields are zero outside calendar coverage, including wind-down (appendix R17).
        uint64 lenderWindowOpensAt; // earliest opening, UTC seconds, may be past while blocked; zero while open now
        uint64 lenderWindowClosesAt; // A of the window's session, UTC seconds
        uint256 pendingMultiplier; // new ERC-8056 multiplier, WAD; zero if none is pending or it cannot be read
        uint64 multiplierEffectiveAt; // when the new multiplier takes effect, UTC seconds; zero when none is pending
        uint256 debtIndex; // debt index at the clock time, WAD
    }

    /// @notice One borrower's position, closure plan, liquidation outlook, funded buffer and missed-execution status
    /// for the Borrow / My loan and Operations views (docs/SPEC.md §4, §5, §8 and §9).
    /// @dev Debt accrues to the clock time and rounds up. Collateral is valued at the book price and rounds down,
    /// except inside `trimNow`, which values it at the snapshot's quote price; the two agree whenever trims are
    /// allowed. Repayment and top-up amounts round up, against the borrower (docs/SPEC.md §5). See `_accountView`
    /// for how each field is computed.
    struct AccountView {
        address account; // account reported on
        uint256 collateral; // raw stock-token units
        uint256 collateralValue; // at the book price, base units, rounded down; zero without a price
        bool valuationIndicative; // valued at the last accepted price, not a current one
        uint256 debt; // accrued debt at the clock time, base units, rounded up
        uint256 ltvWad; // debt / value, WAD, rounded up; zero without debt; max when collateral is worthless
        uint256 borrowCapacity; // more debt allowed now, base units; zero when borrowing is closed; minLoan not applied
        // Closure plan: reach the target of the snapshot's closure class: the coming close before C, the closure
        // in progress or just ended from C through reopening recovery, EXTENDED outside calendar coverage.
        uint256 planTargetWad; // target LTV T of that closure class, WAD
        uint256 repayToTarget; // repayment that reaches T, base units, rounded up; zero at or below T
        uint256 addCollateralValueToTarget; // value to add to reach T, base units, rounded up; zero at or below T
        uint256 addCollateralRawToTarget; // the same in raw units, rounded up; zero at or below T or without a price
        // If nothing is done before F: the trim a liquidator could make at the book price and current debt.
        bool trimmableAtFinal; // eligible at F; set only in the OPEN, PRE_CLOSE and FINAL_WINDOW phases
        uint256 trimAtFinalRepay; // loan tokens the liquidator would pay, base units
        uint256 trimAtFinalCollateral; // collateral the liquidator would receive, raw units, rounded down
        uint256 trimAtFinalBonusWad; // liquidation bonus of that trim, WAD; zero when not eligible
        // Right now.
        StockReefMarket.TrimQuote trimNow; // what trim(account, max, ...) would do at this snapshot; see TrimQuote
        // Funded buffer.
        RepaymentEscrow.Plan plan; // stored escrow plan; see Plan
        bool bufferActive; // authorization set and not expired at the clock time
        bool bufferCommitted; // RepaymentEscrow.committed: the owner cannot re-authorize, cancel or withdraw now
        uint256 bufferCoverage; // what the plan would repay if buffers could run now, at the book price, base units
        uint256 bufferExecutableNow; // what executeBuffer would repay now, base units; zero unless buffers can run
        // Missed execution: in a closure, the position is still above the closure's LT at F, judged at the current
        // debt and the book price, not at values recorded at the close.
        bool missedExecution; // CLOSED or REOPEN_WAIT phase, debt non-zero and LTV strictly above that LT
        uint256 exposure; // repayToTarget when missedExecution, otherwise zero; base units, rounded up
    }

    /// @dev Fixed-point one (1e18) for WAD ratios.
    uint256 internal constant WAD = 1e18;

    /// @notice Market this lens reports on.
    StockReefMarket public immutable market;
    /// @notice The market's repayment escrow, read for buffer plans.
    RepaymentEscrow public immutable escrow;
    /// @notice The market's session policy, read for the snapshot, closure targets and the LT at F.
    SessionRiskPolicy public immutable policy;
    /// @notice The market's price gate, read for valuation, the test peg, the clock and the collateral token.
    PriceGate public immutable gate;
    /// @notice The gate's session calendar (UTC), read for the next lender window.
    SessionCalendar public immutable calendar;

    /// @notice Binds the lens to `market_` and reads the escrow, policy, gate and calendar that market uses.
    /// @dev Nothing is checked; it reverts only if `market_` or its gate does not answer these getters.
    /// @param market_ Market to report on.
    constructor(StockReefMarket market_) {
        market = market_;
        escrow = market_.escrow();
        policy = market_.policy();
        gate = market_.gate();
        calendar = gate.calendar();
    }

    // ---------------------------------------------------------------- market

    /// @notice Market-wide state now: session snapshot, lender book, utilization, account cap, next lender window
    /// and any pending corporate action (docs/SPEC.md §7 and §9; appendix R11).
    /// @dev View; anyone may call it in any state, and it adds no revert conditions of its own. Reads
    /// `policy.snapshot()` and `market.bookValuation()`, neither of which refreshes the gate; `totalAssets` values
    /// the book again at the same price. Utilization is total debt / (cash + total debt), rounded down. The lender
    /// window comes from `_lenderWindow`: (0, A) while open now, otherwise the earliest opening and its A, and
    /// (0, 0) outside calendar coverage, including wind-down, where only exits against idle cash remain (appendix
    /// R17).
    /// @return m The market view; see MarketView for fields and units.
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

    /// @notice One borrower's position now: debt, value and LTV, borrow capacity, the repayment or top-up that
    /// reaches the closure target, the trim a liquidator could make at F if nothing is done, the trim possible
    /// now, the funded buffer, and whether the account missed execution (docs/SPEC.md §4, §5, §8 and §9).
    /// @dev View; anyone may call it for any account, in any state, and it adds no revert conditions of its own.
    /// Evaluates at `policy.snapshot()` and the book price of `market.bookValuation()`, without refreshing the
    /// gate; see `_accountView` for each field.
    /// @param account Borrower to report on.
    /// @return v The account view; see AccountView for fields and units.
    function accountView(address account) public view returns (AccountView memory v) {
        return _accountView(account, policy.snapshot(), market.bookValuation().priceWad);
    }

    /// @notice Every account with debt, for the Operations view and the keeper (docs/SPEC.md §8 and §9).
    /// @dev The `accountView` of each account in `market.activeAccounts()` (at most MAX_ACCOUNTS, in no fixed
    /// order), all at one policy snapshot and one book price. View; anyone may call it in any state, and it adds no
    /// revert conditions of its own. While borrowing is allowed, each account's borrow capacity values the whole
    /// book again, so gas can grow with the square of the number of accounts; meant for off-chain calls.
    /// @return views One view per active account, in the order of `market.activeAccounts()`.
    function activeAccountViews() external view returns (AccountView[] memory views) {
        address[] memory list = market.activeAccounts();
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 price = market.bookValuation().priceWad;
        views = new AccountView[](list.length);
        for (uint256 i; i < list.length; ++i) {
            views[i] = _accountView(list[i], s, price);
        }
    }

    /// @dev Builds the view of `account` at snapshot `s`, with collateral valued at `price`. D is the debt and V the
    /// collateral value, both in loan-token base units.
    /// - Position: D accrues to the clock time and rounds up; V = gate.valueOf(collateral, price), rounded down,
    ///   zero when `price` is zero; LTV = D / V rounded up, zero without debt, type(uint256).max when V is zero.
    ///   `valuationIndicative` is set when the snapshot's quote has any reason bit.
    /// - Closure plan (docs/SPEC.md §5): T = policy.targetOf(s.closureClass), the class of the coming close in
    ///   OPEN, PRE_CLOSE and FINAL_WINDOW (in OPEN, not the 75% OPEN target), of the closure in progress or just
    ///   ended in CLOSED, REOPEN_WAIT and REOPEN_RECOVERY, and EXTENDED outside calendar coverage (appendix R1).
    ///   When D > T * V: repayToTarget = ceil(D - T * V), addCollateralValueToTarget = ceil(D / T) - V, and the raw
    ///   collateral worth that value rounded up, left zero when `price` is zero. Otherwise all three are zero.
    /// - At F: in the OPEN, PRE_CLOSE and FINAL_WINDOW phases (also when the state is GUARDED), `market.quoteTrim`
    ///   with no repay cap at the `_atFinal` snapshot. It assumes the current debt and `price` and no buffer
    ///   execution. In other phases these fields stay zero and false.
    /// - Now: `market.quoteTrim` with no repay cap at `s`, valued at `s.priceWad`, including `bufferPending`.
    /// - Buffer: the stored plan; `bufferActive` repeats the escrow's active check at `s.time`; `bufferCommitted` is
    ///   RepaymentEscrow.committed; `bufferExecutableNow` is RepaymentEscrow.executableAmount at `s`, zero unless
    ///   buffers can run now; `bufferCoverage` is the same amount at the `_buffering` snapshot.
    /// - Missed execution (docs/SPEC.md §8, appendix R13): in the CLOSED or REOPEN_WAIT phase (also when the state
    ///   is GUARDED), D is non-zero and D > s.ltWad * V, where s.ltWad is the closure class's LT at F. `exposure` is
    ///   then `repayToTarget`. Both use the current debt and `price`, not values recorded at the close.
    /// @param account Borrower to report on.
    /// @param s Policy snapshot shared by every field.
    /// @param price Collateral price, WAD: the book price; zero when the quote is unusable and no refresh has ever
    /// accepted a price.
    /// @return v The account view.
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
        // Missed: still above the closing threshold, so, unless the price or interest moved it since, it was
        // trimmable at F and nobody reduced it. A position between the target and that threshold may enter a
        // closure without action (docs/SPEC.md §3).
        v.missedExecution = closedPhase && v.debt != 0 && v.debt * WAD > s.ltWad * v.collateralValue;
        v.exposure = v.missedExecution ? v.repayToTarget : 0;
    }

    /// @dev The most `market.borrow` should accept from `account` now, in loan-token base units, rounded down. Zero
    /// when the snapshot does not allow borrowing, an active escrow authorization blocks it from A onward, the
    /// account has no debt while MAX_ACCOUNTS accounts do, or the book is impaired (docs/SPEC.md §4 and §7).
    /// Otherwise the least of: floor(B * value) - debt - 1 (one base unit for share rounding; zero when not
    /// positive), idle cash, and floor(UTILIZATION_CAP * (cash + total debt)) - total debt (zero when negative).
    /// It does not apply the minimum loan: `market.borrow` requires the previous debt plus the amount to be at least
    /// `market.minLoan()` (appendix R8), so for an account without debt, or with debt left below the minimum by a
    /// trim, a capacity that cannot reach it is not usable.
    /// @param account Borrower.
    /// @param s Policy snapshot supplying `canBorrow`, the borrow limit B, the time and A.
    /// @param v The account view built so far; only `debt` and `collateralValue` are read.
    /// @return Borrow capacity, loan-token base units.
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

    /// @dev The policy at F for the coming close, at the current price and debt, without any buffer. A hand-built
    /// snapshot: time `s.time` (so debt accrues only to now), state and phase FINAL_WINDOW, price `price`, trims
    /// allowed and buffers not (so `quoteTrim` reports no pending buffer), LT = policy.ltFinalOf(s.closureClass)
    /// and target = policy.targetOf(s.closureClass) (appendix R1). With it `policy.bonusFor` gives 5% above an LTV
    /// of 80% and 2% otherwise. Every other field stays zero.
    /// @param s Current snapshot; only `time` and `closureClass` are read.
    /// @param price Collateral price, WAD.
    /// @return f The snapshot at F.
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

    /// @dev The current snapshot as if buffers could execute, to size what a funded plan would repay. Only `time`,
    /// `session` and `canBuffer` (true) are set, which is all RepaymentEscrow.executableAmount reads. The amount is
    /// zero unless the plan's authorization is active at `s.time`; otherwise it is the repayment toward the plan's
    /// own target, capped by its balance and the allowance left in `s.session` and adjusted for the minimum loan
    /// (appendix R16). In CLOSED that is the allowance of the session just closed, not of the next one; outside
    /// calendar coverage `s.session` is zero.
    /// @param s Current snapshot.
    /// @return b The snapshot for sizing.
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

    /// @dev When lender deposits and withdrawals are next allowed, and when that window closes (docs/SPEC.md §7).
    /// - Outside calendar coverage, including wind-down (appendix R17): (0, 0).
    /// - Effective state OPEN: (0, A); the window is open now.
    /// - Otherwise inside the session before A (reopening, or GUARDED): (creditAt, A), or (O + 15 min, A) before
    ///   admission. The opening time can then be in the past while the window is blocked (GUARDED, or a reopening
    ///   still waiting after O + 15 min), or at or after A when a late admission leaves no OPEN phase.
    /// - From A, and between sessions: the next session's (O + 15 min, A). A covered snapshot always has a next
    ///   session; the (0, 0) return when none is loaded is only a guard.
    /// Opening times are the earliest possible: credit returns at max(O + 15 min, admissionAt + 10 min), and the
    /// window also needs a usable price (docs/SPEC.md §6 step 4).
    /// @param s Current snapshot.
    /// @return opensAt When the window opens, UTC seconds; zero while it is open now or when unknown.
    /// @return closesAt When the window closes (A of its session), UTC seconds; zero when unknown.
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

    /// @dev The collateral token's scheduled ERC-8056 multiplier change, if it takes effect after `t` (appendix
    /// R11). Reads `effectiveAt()` and `newUIMultiplier()` with try/catch, whether or not the gate checks ERC-8056,
    /// so a reverting read leaves its value zero instead of reverting the view; return data that cannot be decoded
    /// still reverts. `effectiveAt` is truncated to 64 bits.
    /// @param t Current clock time, UTC seconds.
    /// @return multiplier New multiplier, WAD (1e18 = 1.0); zero when nothing is pending or either read reverts.
    /// @return effectiveAt When the new multiplier takes effect, UTC seconds; zero when nothing is pending or
    /// `effectiveAt()` reverts.
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
