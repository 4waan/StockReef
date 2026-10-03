// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {PriceGate} from "./PriceGate.sol";
import {SessionCalendar} from "./SessionCalendar.sol";
import {SessionRiskPolicy} from "./SessionRiskPolicy.sol";
import {StockReefMarket} from "./StockReefMarket.sol";
import {RepaymentEscrow} from "./RepaymentEscrow.sol";
import {SessionRules} from "./libraries/SessionRules.sol";
import {SessionTiming} from "./libraries/SessionTiming.sol";
import {StockReefMath} from "./libraries/StockReefMath.sol";

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
    using StockReefMath for uint256;

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
        uint256 borrowCapacity; // more debt allowed now, base units; zero when closed or below the minimum loan
        // Closure plan: reach the target of the snapshot's closure class: the coming close before C, the closure
        // in progress or just ended from C through reopening recovery, EXTENDED outside calendar coverage.
        uint256 planTargetWad; // target LTV T of that closure class, WAD
        uint256 repayToTarget; // repayment that reaches T, base units, rounded up; zero at or below T
        uint256 addCollateralValueToTarget; // value to add to reach T, base units, rounded up; zero at or below T
        uint256 addCollateralRawToTarget; // the same in raw units, rounded up; zero at or below T or without a price
        // If nothing is done before F: the trim a liquidator could make at the book price and the debt at F.
        bool trimmableAtFinal; // eligible at F; set only in the OPEN, PRE_CLOSE and FINAL_WINDOW phases
        uint256 trimAtFinalRepay; // loan tokens the liquidator would pay, base units
        uint256 trimAtFinalCollateral; // collateral the liquidator would receive, raw units, rounded down
        uint256 trimAtFinalBonusWad; // liquidation bonus of that trim, WAD; zero when not eligible
        // At the reopening, if nothing is done: debt accrued to the next open, judged at the closure's LT.
        uint256 projectedDebtAtReopen; // debt at the next open (now from O), base units, rounded up
        bool trimmableAtReopen; // that debt strictly above the closure's LT times the value at the book price
        // Right now.
        StockReefMarket.TrimQuote trimNow; // what trim(account, max, ...) would do at this snapshot; see TrimQuote
        // Funded buffer.
        RepaymentEscrow.Plan plan; // stored escrow plan; see Plan
        bool bufferActive; // authorization set and not expired at the clock time
        bool bufferCommitted; // RepaymentEscrow.committed: the owner cannot re-authorize, cancel or withdraw now
        uint256 bufferCoverage; // what the plan would repay at its next execution window (now while buffers run),
        // at the book price and the debt then, base units; zero if the plan is not active then or no window is left
        uint256 bufferExecutableNow; // what executeBuffer would repay now, base units; zero unless buffers can run
        // Missed execution: in a closure, the position was still above the closure's LT at the close, judged at the
        // debt at that close and the book price; in wind-down, at the last covered close (appendix R19).
        bool missedExecution; // CLOSED or REOPEN_WAIT phase, or wind-down, and that debt above LT times the value
        uint256 exposure; // repayToTarget when missedExecution, otherwise zero; base units, rounded up
    }

    /// @dev Market-wide reads shared by every view built in one call: the policy snapshot, the book valuation at
    /// the book price, idle cash and the number of accounts with debt.
    struct Ctx {
        SessionRiskPolicy.Snapshot s; // policy.snapshot()
        StockReefMarket.Book book; // market.bookValuation()
        uint256 price; // book price: book.priceWad
        uint256 cash; // market.cash()
        uint256 activeCount; // market.activeAccounts().length
        uint256 minLoan; // market.minLoan()
    }

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
    /// @dev The market's VALUE_SCALE: collateral value is raw * priceWad / VALUE_SCALE.
    uint256 private immutable VALUE_SCALE;
    /// @dev Number of calendar sessions; session SESSION_COUNT - 2 is the last covered one and its close the
    /// terminal close before wind-down.
    uint256 private immutable SESSION_COUNT;

    /// @notice Binds the lens to `market_` and reads the escrow, policy, gate and calendar that market uses.
    /// @dev Nothing is checked; it reverts only if `market_` or its gate does not answer these getters.
    /// @param market_ Market to report on.
    constructor(StockReefMarket market_) {
        market = market_;
        escrow = market_.escrow();
        policy = market_.policy();
        gate = market_.gate();
        calendar = gate.calendar();
        VALUE_SCALE = market_.VALUE_SCALE();
        SESSION_COUNT = market_.gate().calendar().sessionCount();
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
        address[] memory list = market.activeAccounts();
        Ctx memory c = _ctx(list.length);
        m.policy = c.s;
        m.simulationClock = gate.clock().isSimulation();
        m.usesPeg = gate.usesPeg();
        m.pegLabel = gate.pegLabel();
        m.cash = c.cash;
        m.totalAssets = market.totalAssets(); // idle cash only in wind-down (appendix R19)
        m.totalShares = market.totalSupply();
        m.totalDebt = c.book.totalDebt;
        m.recoverable = c.book.recoverable;
        m.impaired = c.book.impaired;
        m.valuationIndicative = c.book.indicative;
        m.valuationPriceWad = c.book.priceWad;
        uint256 lendable = m.cash + m.totalDebt;
        m.utilizationWad = lendable == 0 ? 0 : m.totalDebt.divWadDown(lendable);
        m.totalBadDebt = market.totalBadDebt();
        m.activeAccounts = c.activeCount;
        m.maxAccounts = market.MAX_ACCOUNTS();
        m.minLoan = market.minLoan();
        m.lastAcceptedAt = gate.lastAcceptedAt();
        (m.lenderWindowOpensAt, m.lenderWindowClosesAt) = _lenderWindow(c.s);
        (m.pendingMultiplier, m.multiplierEffectiveAt) = _pendingMultiplier(c.s.time);
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
        return _accountView(account, _ctx(market.activeAccounts().length));
    }

    /// @notice Every account with debt, for the Operations view and the keeper (docs/SPEC.md §8 and §9).
    /// @dev The `accountView` of each account in `market.activeAccounts()` (at most MAX_ACCOUNTS, in no fixed
    /// order), all at one policy snapshot and one book valuation, read once. View; anyone may call it in any
    /// state, and it adds no revert conditions of its own. Meant for off-chain calls.
    /// @return views One view per active account, in the order of `market.activeAccounts()`.
    function activeAccountViews() external view returns (AccountView[] memory views) {
        address[] memory list = market.activeAccounts();
        Ctx memory c = _ctx(list.length);
        views = new AccountView[](list.length);
        for (uint256 i; i < list.length; ++i) {
            views[i] = _accountView(list[i], c);
        }
    }

    /// @dev Reads the market-wide inputs once: `policy.snapshot()`, `market.bookValuation()` and `market.cash()`.
    /// @param activeCount Number of accounts with debt.
    /// @return c The shared context.
    function _ctx(uint256 activeCount) internal view returns (Ctx memory c) {
        c.s = policy.snapshot();
        c.book = market.bookValuation();
        c.price = c.book.priceWad;
        c.cash = market.cash();
        c.activeCount = activeCount;
        c.minLoan = market.minLoan();
    }

    /// @dev Builds the view of `account` at the context's snapshot, with collateral valued at the book price
    /// `c.price`. D is the debt and V the collateral value, both in loan-token base units.
    /// - Position: D accrues to the clock time and rounds up; V = collateral * price / VALUE_SCALE, rounded down
    ///   (zero when the price is zero); LTV = D / V rounded up, zero without debt, type(uint256).max when V is
    ///   zero. `valuationIndicative` is set when the snapshot's quote has any reason bit.
    /// - Closure plan (docs/SPEC.md §5): T = the target of `s.closureClass`, the class of the coming close in
    ///   OPEN, PRE_CLOSE and FINAL_WINDOW (in OPEN, not the 75% OPEN target), of the closure in progress or just
    ///   ended in CLOSED, REOPEN_WAIT and REOPEN_RECOVERY, and EXTENDED outside calendar coverage (appendix R1).
    ///   When D > T * V: repayToTarget = ceil(D - T * V), addCollateralValueToTarget = ceil(D / T) - V, and the raw
    ///   collateral worth that value rounded up, left zero when the price is zero. Otherwise all three are zero.
    /// - At F: in the OPEN, PRE_CLOSE and FINAL_WINDOW phases (also when the state is GUARDED), `market.quoteTrim`
    ///   with no repay cap at the `_atFinal` snapshot. It accrues debt to F (to now from F on) and assumes the book
    ///   price and no buffer execution. In other phases these fields stay zero and false.
    /// - At the reopening: the debt accrued to the next open (to now in REOPEN_WAIT and REOPEN_RECOVERY), and
    ///   whether it is strictly above the closure's LT times V. Zero and false outside coverage and when the next
    ///   open is wind-down, which never reopens.
    /// - Now: `market.quoteTrim` with no repay cap at `s`, valued at `s.priceWad`, including `bufferPending`.
    /// - Buffer: the stored plan; `bufferActive` repeats the escrow's active check at `s.time`; `bufferCommitted` is
    ///   RepaymentEscrow.committed; `bufferExecutableNow` is RepaymentEscrow.executableAmount at `s`, zero unless
    ///   buffers can run now; `bufferCoverage` is the same amount at the next execution window (`_nextBufferWindow`)
    ///   with the debt accrued to it, zero when the plan is not active then or no window is left.
    /// - Missed execution (docs/SPEC.md §8, appendix R13): in the CLOSED or REOPEN_WAIT phase (also when the state
    ///   is GUARDED) or in wind-down, the debt at the close that started the closure (the last covered close in
    ///   wind-down) is strictly above s.ltWad * V, where s.ltWad is the closure class's LT at F; zero debt never
    ///   qualifies, and the first loaded session has no earlier close. Closure interest alone therefore does not
    ///   raise it. `exposure` is then `repayToTarget`, at the current debt.
    /// @param account Borrower to report on.
    /// @param c Shared context of this call.
    /// @return v The account view.
    function _accountView(address account, Ctx memory c) internal view returns (AccountView memory v) {
        _position(v, account, c);
        _closurePlan(v, c);
        _trims(v, account, c);
        _reopening(v, account, c);
        _buffer(v, account, c);
        _missed(v, account, c.s);
    }

    /// @dev Position fields and borrow capacity; see `_accountView`.
    function _position(AccountView memory v, address account, Ctx memory c) internal view {
        v.account = account;
        (v.collateral,, v.debt) = market.accountOf(account);
        v.valuationIndicative = c.s.reasons != 0;
        v.collateralValue = v.collateral.toValueDown(c.price, VALUE_SCALE);
        v.ltvWad = v.debt.ltvUp(v.collateralValue);
        v.borrowCapacity = _borrowCapacity(account, v, c);
    }

    /// @dev Closure plan toward the target of the snapshot's closure class; see `_accountView`.
    function _closurePlan(AccountView memory v, Ctx memory c) internal view {
        v.planTargetWad = SessionRules.target(c.s.closureClass == SessionRiskPolicy.ClosureClass.EXTENDED);
        if (v.debt.exceeds(v.collateralValue, v.planTargetWad)) {
            v.repayToTarget = v.debt.repayToReachUp(v.collateralValue, v.planTargetWad);
            v.addCollateralValueToTarget = v.debt.valueForRatioUp(v.planTargetWad) - v.collateralValue;
            if (c.price != 0) {
                v.addCollateralRawToTarget =
                    v.addCollateralValueToTarget.toRaw(c.price, VALUE_SCALE, Math.Rounding.Ceil);
            }
        }
    }

    /// @dev The trim at F if nothing is done (only in the OPEN, PRE_CLOSE and FINAL_WINDOW phases) and the trim
    /// possible now; see `_accountView`.
    function _trims(AccountView memory v, address account, Ctx memory c) internal view {
        SessionRiskPolicy.State ph = c.s.phase;
        if (
            ph == SessionRiskPolicy.State.OPEN || ph == SessionRiskPolicy.State.PRE_CLOSE
                || ph == SessionRiskPolicy.State.FINAL_WINDOW
        ) {
            StockReefMarket.TrimQuote memory f = market.quoteTrim(account, _atFinal(c.s, c.price), type(uint256).max);
            v.trimmableAtFinal = f.eligible;
            v.trimAtFinalRepay = f.repaid;
            v.trimAtFinalCollateral = f.collateralOut;
            v.trimAtFinalBonusWad = f.bonusWad;
        }
        v.trimNow = market.quoteTrim(account, c.s, type(uint256).max);
    }

    /// @dev The debt at the next open and whether it would be trimmable there; see `_accountView`.
    function _reopening(AccountView memory v, address account, Ctx memory c) internal view {
        SessionRiskPolicy.Snapshot memory s = c.s;
        if (!s.covered) return;
        SessionRiskPolicy.State ph = s.phase;
        uint64 reopenAt;
        if (ph == SessionRiskPolicy.State.REOPEN_WAIT || ph == SessionRiskPolicy.State.REOPEN_RECOVERY) {
            reopenAt = s.time;
        } else {
            if (s.session + 2 >= SESSION_COUNT) return; // the next open is wind-down
            reopenAt = s.nextOpen;
        }
        v.projectedDebtAtReopen = market.debtAt(account, reopenAt);
        uint256 lt = SessionRules.ltFinal(s.closureClass == SessionRiskPolicy.ClosureClass.EXTENDED);
        v.trimmableAtReopen = v.projectedDebtAtReopen.exceeds(v.collateralValue, lt);
    }

    /// @dev Funded buffer fields; see `_accountView`.
    function _buffer(AccountView memory v, address account, Ctx memory c) internal view {
        SessionRiskPolicy.Snapshot memory s = c.s;
        v.plan = escrow.planOf(account);
        v.bufferActive = v.plan.targetWad != 0 && s.time < v.plan.expiry;
        v.bufferCommitted = escrow.committed(account);
        v.bufferExecutableNow = escrow.executableAmount(account, s, v.debt, v.collateralValue);
        (bool exists, SessionRiskPolicy.Snapshot memory w) = _nextBufferWindow(s);
        if (exists) {
            uint256 debtThen = w.time == s.time ? v.debt : market.debtAt(account, w.time);
            v.bufferCoverage = escrow.executableAmount(account, w, debtThen, v.collateralValue);
        }
    }

    /// @dev Missed execution and exposure; see `_accountView`.
    function _missed(AccountView memory v, address account, SessionRiskPolicy.Snapshot memory s) internal view {
        uint64 closeAt;
        if (s.windDown) {
            (, closeAt) = calendar.sessionAt(SESSION_COUNT - 2); // the last covered close
        } else if (s.phase == SessionRiskPolicy.State.CLOSED) {
            closeAt = s.close;
        } else if (s.phase == SessionRiskPolicy.State.REOPEN_WAIT && s.session != 0) {
            (, closeAt) = calendar.sessionAt(s.session - 1);
        } else {
            return;
        }
        // Missed: above the closing threshold at the close, so it was trimmable at F and nobody reduced it. A
        // position between the target and that threshold may enter a closure without action (docs/SPEC.md §3).
        // Zero debt never exceeds the threshold.
        uint256 debtAtClose = v.debt == 0 ? 0 : market.debtAt(account, closeAt);
        v.missedExecution = debtAtClose.exceeds(v.collateralValue, s.ltWad);
        v.exposure = v.missedExecution ? v.repayToTarget : 0;
    }

    /// @dev The most `market.borrow` should accept from `account` now, in loan-token base units, rounded down. Zero
    /// when the snapshot does not allow borrowing, an active escrow authorization blocks it from A onward, the
    /// account has no debt while MAX_ACCOUNTS accounts do, or the book is impaired (docs/SPEC.md §4 and §7).
    /// Otherwise the least of: floor(B * value) - debt - 1 (one base unit for share rounding; zero when not
    /// positive), idle cash, and floor(UTILIZATION_CAP * (cash + total debt)) - total debt (zero when negative).
    /// Zero as well when the debt plus that amount would stay below `market.minLoan()`, which `market.borrow`
    /// rejects (appendix R8).
    /// @param account Borrower.
    /// @param v The account view built so far; only `debt` and `collateralValue` are read.
    /// @param c Shared context supplying the snapshot, the book, cash and the active count.
    /// @return Borrow capacity, loan-token base units.
    function _borrowCapacity(address account, AccountView memory v, Ctx memory c) internal view returns (uint256) {
        if (!c.s.canBorrow || escrow.blocksBorrowing(account, c.s)) return 0;
        if (v.debt == 0 && c.activeCount >= market.MAX_ACCOUNTS()) return 0;
        if (c.book.impaired) return 0;
        uint256 limit = c.s.borrowLimitWad.mulWadDown(v.collateralValue);
        if (limit <= v.debt + 1) return 0;
        uint256 cap = limit - v.debt - 1; // one base unit for share rounding
        uint256 utilizationRoom = market.UTILIZATION_CAP().mulWadDown(c.cash + c.book.totalDebt);
        utilizationRoom = utilizationRoom > c.book.totalDebt ? utilizationRoom - c.book.totalDebt : 0;
        cap = Math.min(cap, Math.min(c.cash, utilizationRoom));
        return v.debt + cap < c.minLoan ? 0 : cap;
    }

    /// @dev The policy at F for the coming close, at the current price, without any buffer. A hand-built
    /// snapshot: time F (`s.finalAt`, or `s.time` from F on, so debt accrues to F), state and phase FINAL_WINDOW, price `price`, trims
    /// allowed and buffers not (so `quoteTrim` reports no pending buffer), LT = policy.ltFinalOf(s.closureClass)
    /// and target = policy.targetOf(s.closureClass), both from SessionRules (appendix R1). With it
    /// `policy.bonusFor` gives 5% above an LTV of 80% and 2% otherwise. Every other field stays zero.
    /// @param s Current snapshot; only `time`, `finalAt` and `closureClass` are read.
    /// @param price Collateral price, WAD.
    /// @return f The snapshot at F.
    function _atFinal(SessionRiskPolicy.Snapshot memory s, uint256 price)
        internal
        pure
        returns (SessionRiskPolicy.Snapshot memory f)
    {
        f.time = s.time < s.finalAt ? s.finalAt : s.time;
        f.state = SessionRiskPolicy.State.FINAL_WINDOW;
        f.phase = SessionRiskPolicy.State.FINAL_WINDOW;
        f.priceWad = price;
        f.canTrim = true;
        bool extended = s.closureClass == SessionRiskPolicy.ClosureClass.EXTENDED;
        f.ltWad = SessionRules.ltFinal(extended);
        f.targetWad = SessionRules.target(extended);
    }

    /// @dev The next time buffers can execute, as a snapshot that sets only `time`, `session` and `canBuffer` (true),
    /// which is all RepaymentEscrow.executableAmount reads: the plan must be active at that time and the allowance
    /// is that session's (docs/SPEC.md §4, appendix R20).
    /// - PRE_CLOSE, FINAL_WINDOW and REOPEN_RECOVERY phases: now, in this session.
    /// - OPEN phase: A of this session.
    /// - REOPEN_WAIT phase: the earliest admission, O + ADMIT_AFTER, or now if later.
    /// - CLOSED phase: the earliest admission of the next session, unless that session is wind-down.
    /// - Outside calendar coverage, including wind-down: none.
    /// @param s Current snapshot.
    /// @return exists False when no execution window is left.
    /// @return w The snapshot for sizing.
    function _nextBufferWindow(SessionRiskPolicy.Snapshot memory s)
        internal
        view
        returns (bool exists, SessionRiskPolicy.Snapshot memory w)
    {
        if (!s.covered) return (false, w);
        SessionRiskPolicy.State ph = s.phase;
        w.canBuffer = true;
        w.session = s.session;
        if (ph == SessionRiskPolicy.State.OPEN) {
            w.time = s.prepAt;
        } else if (ph == SessionRiskPolicy.State.REOPEN_WAIT) {
            uint64 admit = s.open + SessionTiming.ADMIT_AFTER;
            w.time = s.time > admit ? s.time : admit;
        } else if (ph == SessionRiskPolicy.State.CLOSED) {
            if (s.session + 2 >= SESSION_COUNT) return (false, w); // the next session is wind-down
            w.time = s.nextOpen + SessionTiming.ADMIT_AFTER;
            w.session = s.session + 1;
        } else {
            w.time = s.time; // PRE_CLOSE, FINAL_WINDOW, REOPEN_RECOVERY
        }
        exists = true;
    }

    // ---------------------------------------------------------------- windows and corporate actions

    /// @dev When lender deposits and withdrawals are next allowed, and when that window closes (docs/SPEC.md §7).
    /// - Outside calendar coverage, including wind-down (appendix R17): (0, 0).
    /// - Effective state OPEN: (0, A); the window is open now.
    /// - Otherwise inside the session before A (reopening, or GUARDED): (creditAt, A), or (O + 15 min, A) before
    ///   admission. The opening time can then be in the past while the window is blocked (GUARDED, or a reopening
    ///   still waiting after O + 15 min), or at or after A when a late admission leaves no OPEN phase.
    /// - From A, and between sessions: the next session's (O + 15 min, A), unless the next session is the last
    ///   loaded one, which is wind-down: then (0, 0).
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
        if (s.session + 2 >= SESSION_COUNT) return (0, 0); // the next session is wind-down
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
