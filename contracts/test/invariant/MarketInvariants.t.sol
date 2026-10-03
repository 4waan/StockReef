// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {RepaymentEscrow} from "../../src/RepaymentEscrow.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";

/// @notice Random borrowers, lenders, a keeper, a liquidator and donors acting across real sessions and price moves.
/// Every successful price-dependent action records the policy state it ran in, and every action compares the
/// market before and after it, at the same clock time and price, against what that action may change.
contract MarketHandler is Test {
    uint256 internal constant USDG = 1e6;
    uint256 internal constant TOKEN = 1e18;
    uint256 internal constant WAD = 1e18;

    MarketHarness internal market;
    RepaymentEscrow internal escrow;
    SessionRiskPolicy internal policy;
    PriceGate internal gate;
    MockAggregatorV3 internal feed;
    MockStockToken internal tsla;
    MockUSDG internal usdg;

    address[4] public actors;
    address public lender = address(0xA11CE);
    address public liquidator = address(0x11D);
    int256 public answer = 400e8;

    // Ghost records.
    uint256 public borrowsOutsideWindow;
    uint256 public trimsOutsideWindow;
    uint256 public buffersOutsideWindow;
    uint256 public trimsWithoutCapital;
    uint256 public lenderOpsOutsideWindow;
    uint256 public calls;
    uint256 public okBorrow;
    uint256 public okTrim;
    uint256 public okBuffer;
    uint256 public okLend;
    uint256 public okRedeem;
    uint256 public writeOffs;
    uint256 public okRepay;
    uint256 public okWithdraw;
    uint256 public okMint;
    uint256 public okRemove;
    uint256 public okSpender;
    uint256 public fullFills;
    uint256 public ticks;

    // Donations, which the market and the escrow must ignore.
    uint256 public donatedUsdgToMarket;
    uint256 public donatedTslaToMarket;
    uint256 public donatedUsdgToEscrow;

    // Violations found by the per-action comparisons; each must stay zero.
    uint256 public crossAccountChanges; // another account's collateral, shares or plan moved
    uint256 public debtMoveErrors; // debt moved by other than the amount paid or borrowed
    uint256 public tokenMoveErrors; // a token or cash moved by other than the action's amount
    uint256 public assetsDrops; // totalAssets fell where the action may not lower it
    uint256 public sharePriceDrops; // the lender share price fell outside a trim
    uint256 public badDebtErrors; // bad debt recorded or changed other than by a zero-collateral write-off
    uint256 public trimErrors; // a trim differed from its quote, its window, its bonus or its target
    uint256 public minLoanErrors; // borrow, repay or buffer left 0 < debt < minLoan
    uint256 public freshCreditErrors; // a fresh borrow or debt-backed withdrawal left the account trimmable or impaired
    uint256 public tickErrors; // a clock tick or refresh moved positions, plans, cash, shares or lowered debt
    uint256 public windowErrors; // a lender action and its max* view disagreed, or an exit paid more than cash
    uint256 public previewErrors; // a lender action differed from its preview
    uint256 public donationErrors; // a donation changed assets, conversions, positions or plans
    uint256 public supplyErrors; // lender shares minted or burned outside deposit/mint/withdraw/redeem
    uint256 public exitFailures; // a repayment, top-up or debt-free withdrawal failed

    address internal owner; // the fixture: issuer of the mocks and publisher of the feed

    /// @dev Positions, plans, cash and the lender book at one moment.
    struct World {
        uint256[4] collateral;
        uint256[4] shares;
        uint256[4] debt;
        uint256[4] plan;
        uint256 cash;
        uint256 totalAssets;
        uint256 supply;
        uint256 badDebt;
        uint256 marketUsdg;
        uint256 marketTsla;
        uint256 escrowUsdg;
        uint256 index;
    }

    constructor(MarketHarness m, MockAggregatorV3 f, MockStockToken t, MockUSDG u, address owner_) {
        owner = owner_;
        market = m;
        escrow = m.escrow();
        policy = m.policy();
        gate = m.gate();
        feed = f;
        tsla = t;
        usdg = u;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0xB000 + i));
            vm.startPrank(actors[i]);
            usdg.approve(address(market), type(uint256).max);
            usdg.approve(address(escrow), type(uint256).max);
            tsla.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    /// @dev Storage slots (forge inspect storageLayout): StockReefMarket._accounts and RepaymentEscrow._plans.
    uint256 internal constant ACCOUNTS_MAPPING = 9;
    uint256 internal constant PLANS_MAPPING = 1;

    /// @dev Reads positions and plans straight from storage, and debt as the market defines it:
    /// ceil(shares * index / 1e36).
    function _world() internal view returns (World memory w) {
        w.index = market.debtIndex();
        for (uint256 i; i < 4; ++i) {
            bytes32 account = keccak256(abi.encode(actors[i], ACCOUNTS_MAPPING));
            w.collateral[i] = uint256(vm.load(address(market), account));
            w.shares[i] = uint256(vm.load(address(market), bytes32(uint256(account) + 1)));
            w.debt[i] = Math.mulDiv(w.shares[i], w.index, 1e36, Math.Rounding.Ceil);
            w.plan[i] = uint256(vm.load(address(escrow), keccak256(abi.encode(actors[i], PLANS_MAPPING))));
        }
        w.cash = market.cash();
        w.totalAssets = market.totalAssets();
        w.supply = market.totalSupply();
        w.badDebt = market.totalBadDebt();
        w.marketUsdg = usdg.balanceOf(address(market));
        w.marketTsla = tsla.balanceOf(address(market));
        w.escrowUsdg = usdg.balanceOf(address(escrow));
    }

    /// @dev Nobody but `subject` (index 0..3; 4 for none) had collateral, shares or plan change, and the bad debt
    /// moved only if `badDebtMayMove`.
    function _othersUntouched(World memory a, World memory b, uint256 subject, bool badDebtMayMove) internal {
        for (uint256 i; i < 4; ++i) {
            if (i == subject) continue;
            if (a.collateral[i] != b.collateral[i] || a.shares[i] != b.shares[i] || a.plan[i] != b.plan[i]) {
                crossAccountChanges++;
            }
        }
        if (!badDebtMayMove && a.badDebt != b.badDebt) badDebtErrors++;
    }

    /// @dev Lender assets per share did not fall: (TA1 + 1) / (S1 + 1e6) >= (TA0 + 1) / (S0 + 1e6).
    function _sharePriceHeld(World memory a, World memory b) internal {
        if ((b.totalAssets + 1) * (a.supply + 1e6) < (a.totalAssets + 1) * (b.supply + 1e6)) sharePriceDrops++;
    }

    /// @dev Debt after a repayment of `paid` against `before`: cleared exactly, or lowered by paid or paid - 1.
    function _checkRepayment(uint256 before, uint256 afterwards, uint256 paid, uint256 sharesAfter) internal {
        if (paid == before) {
            if (afterwards != 0 || sharesAfter != 0) debtMoveErrors++;
        } else if (
            paid > before || sharesAfter == 0 || (before - afterwards != paid && before - afterwards + 1 != paid)
        ) {
            debtMoveErrors++;
        }
        if (afterwards != 0 && afterwards < market.minLoan()) minLoanErrors++;
    }

    /// @dev Right after new credit: not trimmable and not impaired at this snapshot.
    function _checkFreshCredit(address a) internal {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        uint256 debt = market.debtOf(a);
        uint256 value = gate.valueOf(market.collateralOf(a), s.priceWad);
        if (market.quoteTrim(a, s, type(uint256).max).eligible) freshCreditErrors++;
        if (Math.mulDiv(value, WAD, WAD + market.RECOVERY_HAIRCUT()) < debt) freshCreditErrors++;
        if (debt * WAD > s.borrowLimitWad * value) freshCreditErrors++;
    }

    // ---------------------------------------------------------------- time and price

    function tick(uint256 dt, int256 moveBps) external {
        calls++;
        // Mostly short steps inside a session; one in six crosses the close into the next session, landing
        // anywhere from just before its open to late in the day. Gap moves are larger than intraday ones.
        World memory w0 = _world();
        if (dt % 6 == 0) {
            SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
            if (!c.covered) return;
            _warpForward(c.nextOpen - 10 minutes + (dt % 7 hours));
            moveBps = bound(moveBps, -3_500, 2_000);
        } else {
            vm.warp(block.timestamp + bound(dt, 1 minutes, 90 minutes));
            moveBps = bound(moveBps, -800, 800);
        }
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
        ticks++;

        // Time, phase changes and refreshes move no position, plan, cash or share, and never lower debt.
        World memory w1 = _world();
        _othersUntouched(w0, w1, 4, false);
        if (w1.cash != w0.cash || w1.supply != w0.supply || w1.marketUsdg != w0.marketUsdg) tickErrors++;
        if (w1.index < w0.index) tickErrors++;
        for (uint256 i; i < 4; ++i) {
            if (w1.debt[i] < w0.debt[i]) tickErrors++;
        }
    }

    // ---------------------------------------------------------------- lenders

    function lend(uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(amount, calls))));
        amount = bound(amount, 1 * USDG, 50_000 * USDG);
        SessionRiskPolicy.State st = policy.snapshot().state;
        address receiver = amount % 3 == 0 ? liquidator : lender;
        _mintUsdg(lender, amount);
        bool viewOpen = market.maxDeposit(receiver) >= amount;
        uint256 preview = market.previewDeposit(amount);
        uint256 paying = usdg.balanceOf(lender);
        uint256 held = market.balanceOf(receiver);
        World memory w0 = _world();
        vm.prank(lender);
        try market.deposit(amount, receiver) returns (uint256 shares) {
            okLend++;
            if (st != SessionRiskPolicy.State.OPEN) lenderOpsOutsideWindow++;
            World memory w1 = _world();
            if (shares != preview) previewErrors++;
            if (!viewOpen) windowErrors++;
            if (paying - usdg.balanceOf(lender) != amount || w1.cash - w0.cash != amount) tokenMoveErrors++;
            if (w1.marketUsdg - w0.marketUsdg != amount) tokenMoveErrors++;
            if (market.balanceOf(receiver) - held != shares || w1.supply - w0.supply != shares) supplyErrors++;
            _othersUntouched(w0, w1, 4, false);
            _sharePriceHeld(w0, w1);
        } catch {
            if (viewOpen) windowErrors++;
        }
    }

    function mintShares(uint256 shares) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(shares, calls))));
        shares = bound(shares, 1, 50_000 * USDG * 1e6);
        bool viewOpen = market.maxMint(lender) >= shares;
        uint256 preview = market.previewMint(shares);
        _mintUsdg(lender, preview);
        uint256 paying = usdg.balanceOf(lender);
        World memory w0 = _world();
        vm.prank(lender);
        try market.mint(shares, lender) returns (uint256 assets) {
            okMint++;
            World memory w1 = _world();
            if (assets != preview) previewErrors++;
            if (!viewOpen || policy.snapshot().state != SessionRiskPolicy.State.OPEN) windowErrors++;
            if (paying - usdg.balanceOf(lender) != assets || w1.cash - w0.cash != assets) tokenMoveErrors++;
            if (w1.supply - w0.supply != shares) supplyErrors++;
            _othersUntouched(w0, w1, 4, false);
            _sharePriceHeld(w0, w1);
        } catch {
            if (viewOpen) windowErrors++;
        }
    }

    function redeem(uint256 shares) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(shares, calls))));
        shares = bound(shares, 1, market.balanceOf(lender) + 1);
        SessionRiskPolicy.State st = policy.snapshot().state;
        bool viewAllows = shares <= market.maxRedeem(lender);
        uint256 preview = market.previewRedeem(shares);
        uint256 receiving = usdg.balanceOf(lender);
        World memory w0 = _world();
        vm.prank(lender);
        try market.redeem(shares, lender, lender) returns (uint256 assets) {
            okRedeem++;
            if (st != SessionRiskPolicy.State.OPEN) lenderOpsOutsideWindow++;
            World memory w1 = _world();
            if (assets != preview) previewErrors++;
            if (!viewAllows || assets > w0.cash) windowErrors++;
            if (usdg.balanceOf(lender) - receiving != assets || w0.cash - w1.cash != assets) tokenMoveErrors++;
            if (w0.supply - w1.supply != shares) supplyErrors++;
            _othersUntouched(w0, w1, 4, false);
            _sharePriceHeld(w0, w1);
        } catch {
            if (viewAllows) windowErrors++;
        }
    }

    function withdrawExit(uint256 amount, bool useMax) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(amount, calls))));
        uint256 maxW = market.maxWithdraw(lender);
        amount = useMax ? maxW : bound(amount, 1, maxW + 1);
        bool viewAllows = amount <= maxW && (amount != 0 || _exitOpen());
        uint256 preview = market.previewWithdraw(amount);
        uint256 receiving = usdg.balanceOf(lender);
        World memory w0 = _world();
        vm.prank(lender);
        try market.withdraw(amount, lender, lender) returns (uint256 shares) {
            okWithdraw++;
            if (!_exitOpen()) lenderOpsOutsideWindow++;
            World memory w1 = _world();
            if (shares != preview) previewErrors++;
            if (!viewAllows || amount > w0.cash) windowErrors++;
            if (usdg.balanceOf(lender) - receiving != amount || w0.cash - w1.cash != amount) tokenMoveErrors++;
            if (w0.supply - w1.supply != shares) supplyErrors++;
            _othersUntouched(w0, w1, 4, false);
            _sharePriceHeld(w0, w1);
        } catch {
            if (viewAllows) windowErrors++;
        }
    }

    /// @dev The liquidator redeems the lender's shares with an allowance, which the redeem spends.
    function spenderRedeem(uint256 shares) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(shares, calls))));
        shares = bound(shares, 1, market.maxRedeem(lender) + 1);
        vm.prank(lender);
        market.approve(liquidator, shares);
        World memory w0 = _world();
        uint256 held = market.balanceOf(lender);
        vm.prank(liquidator);
        try market.redeem(shares, liquidator, lender) {
            okSpender++;
            World memory w1 = _world();
            if (held - market.balanceOf(lender) != shares || w0.supply - w1.supply != shares) supplyErrors++;
            if (market.allowance(lender, liquidator) != 0) supplyErrors++;
            if (!_exitOpen()) lenderOpsOutsideWindow++;
        } catch {}
        vm.prank(lender);
        market.approve(liquidator, 0);
    }

    // ---------------------------------------------------------------- borrowers

    function addCollateral(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 50 * TOKEN);
        _mintTsla(a, amount);
        World memory w0 = _world();
        vm.prank(a);
        try market.depositCollateral(amount, a) {
            World memory w1 = _world();
            if (w1.collateral[seed % 4] - w0.collateral[seed % 4] != amount) tokenMoveErrors++;
            if (w1.marketTsla - w0.marketTsla != amount) tokenMoveErrors++;
            if (w1.totalAssets < w0.totalAssets) assetsDrops++;
            if (w1.shares[seed % 4] != w0.shares[seed % 4]) debtMoveErrors++;
            _othersUntouched(w0, w1, seed % 4, false);
        } catch {
            exitFailures++; // top-ups work in every state
        }
    }

    function removeCollateral(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, market.collateralOf(a) + 1);
        bool hadDebt = market.debtOf(a) != 0;
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        World memory w0 = _world();
        uint256 received = tsla.balanceOf(a);
        vm.prank(a);
        try market.withdrawCollateral(amount, a) {
            okRemove++;
            if (hadDebt && !_borrowWindow(s)) borrowsOutsideWindow++;
            World memory w1 = _world();
            if (w0.collateral[seed % 4] - w1.collateral[seed % 4] != amount) tokenMoveErrors++;
            if (tsla.balanceOf(a) - received != amount || w0.marketTsla - w1.marketTsla != amount) tokenMoveErrors++;
            if (w1.totalAssets != w0.totalAssets) assetsDrops++;
            if (w1.shares[seed % 4] != w0.shares[seed % 4]) debtMoveErrors++; // only borrow raises shares
            if (hadDebt) _checkFreshCredit(a);
            _othersUntouched(w0, w1, seed % 4, false);
        } catch {
            if (!hadDebt && amount <= w0.collateral[seed % 4]) exitFailures++; // free withdrawals always work
        }
    }

    function borrow(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        // Aim near the borrower's current limit so that limit checks are exercised from both sides.
        uint256 limit = s.borrowLimitWad == 0 ? 0.75e18 : s.borrowLimitWad;
        uint256 capacity = gate.valueOf(market.collateralOf(a), s.priceWad) * limit / WAD;
        uint256 debt = market.debtOf(a);
        amount = bound(amount, 5 * USDG, capacity > debt + 5 * USDG ? capacity - debt + 1 : 5 * USDG);
        World memory w0 = _world();
        StockReefMarket.Book memory b0 = market.bookValuation();
        uint256 received = usdg.balanceOf(a);
        vm.prank(a);
        try market.borrow(amount, a) {
            okBorrow++;
            if (!_borrowWindow(s)) borrowsOutsideWindow++;
            uint256 i = seed % 4;
            World memory w1 = _world();
            if (w1.debt[i] < w0.debt[i] + amount || w1.debt[i] > w0.debt[i] + amount + 1) debtMoveErrors++;
            if (usdg.balanceOf(a) - received != amount || w0.cash - w1.cash != amount) tokenMoveErrors++;
            if (w0.marketUsdg - w1.marketUsdg != amount) tokenMoveErrors++;
            if (w1.totalAssets < w0.totalAssets || w1.totalAssets > w0.totalAssets + 1) assetsDrops++;
            if (b0.impaired) freshCreditErrors++;
            if ((b0.totalDebt + amount) * WAD > market.UTILIZATION_CAP() * (w0.cash + b0.totalDebt)) {
                freshCreditErrors++;
            }
            if (w1.debt[i] < market.minLoan()) minLoanErrors++;
            _checkFreshCredit(a);
            _othersUntouched(w0, w1, i, false);
            _sharePriceHeld(w0, w1);
        } catch {}
    }

    function repay(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        uint256 i = seed % 4;
        // Half the repayments are partial, sized against the current debt.
        uint256 debt = market.debtOf(a);
        amount = seed % 2 == 0 || debt == 0 ? bound(amount, 1, 30_000 * USDG) : bound(amount, 1, debt);
        _mintUsdg(a, amount);
        World memory w0 = _world();
        uint256 paying = usdg.balanceOf(a);
        vm.prank(a);
        try market.repay(amount, a) returns (uint256 paid) {
            okRepay++;
            World memory w1 = _world();
            if (paid != Math.min(amount, w0.debt[i])) debtMoveErrors++;
            _checkRepayment(w0.debt[i], w1.debt[i], paid, w1.shares[i]);
            if (paying - usdg.balanceOf(a) != paid || w1.cash - w0.cash != paid) tokenMoveErrors++;
            if (w1.marketUsdg - w0.marketUsdg != paid) tokenMoveErrors++;
            if (w1.totalAssets < w0.totalAssets) assetsDrops++;
            if (w1.collateral[i] != w0.collateral[i]) tokenMoveErrors++;
            _othersUntouched(w0, w1, i, false);
            _sharePriceHeld(w0, w1);
        } catch {
            // Only "no debt" and the minimum-loan rule may refuse a funded repayment, in any state.
            if (w0.debt[i] != 0 && (amount >= w0.debt[i] || w0.debt[i] - amount > market.minLoan())) exitFailures++;
        }
    }

    function fundBuffer(uint256 seed, uint256 amount, uint256 targetBps) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        amount = bound(amount, 1, 5_000 * USDG);
        _mintUsdg(a, amount);
        World memory w0 = _world();
        vm.startPrank(a);
        escrow.deposit(amount, a);
        try escrow.authorize(bound(targetBps, 5_000, 6_500) * 1e14, 2_000 * USDG, uint64(block.timestamp + 10 days)) {}
            catch {}
        vm.stopPrank();
        World memory w1 = _world();
        if (w1.cash != w0.cash || w1.totalAssets != w0.totalAssets) assetsDrops++; // escrow is not lender cash
        if (w1.shares[seed % 4] != w0.shares[seed % 4] || w1.plan[seed % 4] - w0.plan[seed % 4] != amount) {
            debtMoveErrors++;
        }
        _othersUntouched(w0, w1, seed % 4, false);
    }

    // ---------------------------------------------------------------- donors

    function donate(uint256 seed, uint256 amount) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        World memory w0 = _world();
        uint256 toShares = market.convertToShares(1_000 * USDG);
        uint256 kind = seed % 3;
        if (kind == 0) {
            amount = bound(amount, 1, 100_000 * USDG);
            _mintUsdg(address(market), amount);
            donatedUsdgToMarket += amount;
        } else if (kind == 1) {
            amount = bound(amount, 1, 100 * TOKEN);
            _mintTsla(address(market), amount);
            donatedTslaToMarket += amount;
        } else {
            amount = bound(amount, 1, 100_000 * USDG);
            _mintUsdg(address(escrow), amount);
            donatedUsdgToEscrow += amount;
        }
        World memory w1 = _world();
        if (w1.totalAssets != w0.totalAssets || w1.cash != w0.cash || w1.supply != w0.supply) donationErrors++;
        if (market.convertToShares(1_000 * USDG) != toShares) donationErrors++;
        for (uint256 i; i < 4; ++i) {
            if (w1.debt[i] != w0.debt[i] || w1.collateral[i] != w0.collateral[i] || w1.plan[i] != w0.plan[i]) {
                donationErrors++;
            }
        }
    }

    // ---------------------------------------------------------------- keeper and liquidator

    function executeBuffer(uint256 seed) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        address a = _actor(seed);
        uint256 i = seed % 4;
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        World memory w0 = _world();
        try escrow.executeBuffer(a) returns (uint256 repaid) {
            okBuffer++;
            if (s.state != SessionRiskPolicy.State.PRE_CLOSE && s.state != SessionRiskPolicy.State.FINAL_WINDOW) {
                buffersOutsideWindow++;
            }
            World memory w1 = _world();
            _checkRepayment(w0.debt[i], w1.debt[i], repaid, w1.shares[i]);
            if (w1.cash - w0.cash != repaid || w0.plan[i] - w1.plan[i] != repaid) tokenMoveErrors++;
            if (w0.escrowUsdg - w1.escrowUsdg != repaid) tokenMoveErrors++;
            if (w1.totalAssets < w0.totalAssets) assetsDrops++;
            if (w1.collateral[i] != w0.collateral[i]) tokenMoveErrors++;
            _othersUntouched(w0, w1, i, false);
            _sharePriceHeld(w0, w1);
        } catch {}
    }

    /// @dev What a trim is checked against, read before it executes.
    struct TrimCase {
        uint256 i;
        address a;
        uint256 maxRepay;
        SessionRiskPolicy.Snapshot s;
        StockReefMarket.TrimQuote q;
        uint256 liqUsdg;
        uint256 liqTsla;
    }

    function trim(uint256 seed, uint256 maxRepay) external {
        calls++;
        _flow(uint256(keccak256(abi.encode(seed, calls))));
        TrimCase memory c;
        c.s = policy.snapshot();
        c.maxRepay = bound(maxRepay, 1, 50_000 * USDG);
        // Prefer an eligible account, starting from the seeded one.
        c.i = seed % 4;
        for (uint256 k; k < 4; ++k) {
            uint256 j = (seed % 4 + k) % 4;
            StockReefMarket.TrimQuote memory probe = market.quoteTrim(actors[j], c.s, c.maxRepay);
            if (probe.eligible && !probe.bufferPending) {
                c.i = j;
                break;
            }
        }
        c.a = actors[c.i];
        c.q = market.quoteTrim(c.a, c.s, c.maxRepay);
        _mintUsdg(liquidator, c.maxRepay);
        c.liqUsdg = usdg.balanceOf(liquidator);
        c.liqTsla = tsla.balanceOf(liquidator);
        World memory w0 = _world();
        vm.prank(liquidator);
        try market.trim(c.a, c.maxRepay, 0, block.timestamp) returns (uint256 repaid, uint256 out) {
            okTrim++;
            if (!c.s.canTrim || c.s.time >= c.s.close) trimsOutsideWindow++;
            if (c.liqUsdg - usdg.balanceOf(liquidator) != repaid || (out != 0 && repaid == 0)) {
                trimsWithoutCapital++;
            }
            _checkTrim(c, w0, _world(), repaid, out);
        } catch {}
    }

    function _checkTrim(TrimCase memory c, World memory w0, World memory w1, uint256 repaid, uint256 out) internal {
        StockReefMarket.TrimQuote memory q = c.q;
        // Exactly the quote, for an eligible account strictly above LT, paying something for something.
        if (repaid != q.repaid || out != q.collateralOut || !q.eligible || q.bufferPending) trimErrors++;
        if (q.debt * WAD <= c.s.ltWad * q.value || repaid == 0 || out == 0) trimErrors++;
        if (repaid > Math.min(c.maxRepay, q.debt)) trimErrors++;
        if (gate.valueOf(out, c.s.priceWad) * WAD > repaid * (WAD + q.bonusWad) + 2 * WAD) trimErrors++;
        if (tsla.balanceOf(liquidator) - c.liqTsla != out || w0.collateral[c.i] - w1.collateral[c.i] != out) {
            tokenMoveErrors++;
        }
        if (w1.cash - w0.cash != repaid || w1.marketUsdg - w0.marketUsdg != repaid) tokenMoveErrors++;
        if (w0.marketTsla - w1.marketTsla != out) tokenMoveErrors++;
        if (w1.totalAssets + 2 < w0.totalAssets) assetsDrops++;
        if (w1.supply != w0.supply) supplyErrors++;
        _othersUntouched(w0, w1, c.i, true);

        if (w1.badDebt != w0.badDebt) {
            // Write-off: only at zero collateral, by exactly the residual, burning the shares.
            writeOffs++;
            uint256 written = w1.badDebt - w0.badDebt;
            if (w1.badDebt < w0.badDebt || w1.collateral[c.i] != 0 || w1.shares[c.i] != 0 || w1.debt[c.i] != 0) {
                badDebtErrors++;
            }
            if (written + repaid < q.debt || written + repaid > q.debt + 1) badDebtErrors++;
        } else {
            if (w1.collateral[c.i] == 0 && w1.debt[c.i] != 0) badDebtErrors++;
            _checkTrimDebt(c, w0, w1, repaid);
        }
    }

    function _checkTrimDebt(TrimCase memory c, World memory w0, World memory w1, uint256 repaid) internal {
        uint256 before = w0.debt[c.i];
        uint256 afterwards = w1.debt[c.i];
        if (repaid == before) {
            if (afterwards != 0) debtMoveErrors++;
        } else if (before - afterwards != repaid && before - afterwards + 1 != repaid) {
            debtMoveErrors++;
        }
        uint256 valueAfter = gate.valueOf(w1.collateral[c.i], c.s.priceWad);
        // A solvent trim never raises LTV beyond one unit of rounding on each side.
        if (
            c.q.debt * (WAD + c.q.bonusWad) < c.q.value * WAD
                && afterwards * c.q.value > (before + 1) * (valueAfter + 1)
        ) {
            trimErrors++;
        }
        if (c.q.fullFill) {
            fullFills++;
            if (afterwards * WAD > c.s.targetWad * valueAfter + WAD) trimErrors++;
        }
    }

    /// @dev Time passes between actions: 1 to 15 minutes, with a move of up to 2% either way.
    function _flow(uint256 r) internal {
        vm.warp(block.timestamp + 1 minutes + (r % 15 minutes));
        // Overnight and weekends: three times in four, skip to just around the next open.
        SessionCalendar.Context memory c = gate.calendar().context(uint64(block.timestamp));
        if (c.covered && !c.inSession && (r >> 40) % 4 != 0) {
            _warpForward(c.nextOpen - 2 minutes + ((r >> 48) % 30 minutes));
        }
        int256 moveBps = int256((r >> 16) % 401) - 200;
        answer = answer * (10_000 + moveBps) / 10_000;
        if (answer < 1e8) answer = 1e8;
        vm.prank(owner);
        feed.push(answer);
        gate.refresh();
    }

    /// @dev The clock never goes backwards: a target at or before now becomes a one-minute step.
    function _warpForward(uint256 t) internal {
        vm.warp(t > block.timestamp ? t : block.timestamp + 1 minutes);
    }

    function _mintUsdg(address to, uint256 amount) internal {
        vm.prank(owner);
        usdg.mint(to, amount);
    }

    function _mintTsla(address to, uint256 amount) internal {
        vm.prank(owner);
        tsla.mint(to, amount);
    }

    function _borrowWindow(SessionRiskPolicy.Snapshot memory s) internal pure returns (bool) {
        return
            (s.state == SessionRiskPolicy.State.OPEN || s.state == SessionRiskPolicy.State.PRE_CLOSE)
                && s.time < s.finalAt;
    }

    function _exitOpen() internal view returns (bool) {
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        return s.lenderOpen || s.windDown;
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }
}

import {console} from "forge-std/console.sol";

contract MarketInvariants is MarketFixture {
    function afterInvariant() external view {
        console.log("borrow", handler.okBorrow(), "trim", handler.okTrim());
        console.log("buffer", handler.okBuffer(), "lend", handler.okLend());
        console.log("redeem", handler.okRedeem(), "badDebt", market.totalBadDebt());
        console.log("repay", handler.okRepay(), "withdraw", handler.okWithdraw());
        console.log("mint", handler.okMint(), "removeCollateral", handler.okRemove());
        console.log("spender", handler.okSpender(), "fullFills", handler.fullFills());
        console.log("writeOffs", handler.writeOffs(), "ticks", handler.ticks());
    }

    MarketHandler internal handler;

    /// @dev Slot of StockReefMarket._activeSlot (forge inspect StockReefMarket storageLayout).
    uint256 internal constant ACTIVE_SLOT_MAPPING = 11;

    function setUp() public {
        _setUpMarket();
        _openFriday();
        handler = new MarketHandler(market, stockFeed, tsla, usdg, address(this));
        // Seed: lender liquidity and four collateralised borrowers, two of them indebted.
        _lend(200_000 * USDG);
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            tsla.mint(a, 50 * TOKEN);
            vm.prank(a);
            market.depositCollateral(50 * TOKEN, a);
            if (i < 2) {
                vm.prank(a);
                market.borrow(14_000 * USDG, a);
            }
        }
        bytes4[] memory actions = new bytes4[](14);
        actions[0] = MarketHandler.tick.selector;
        actions[1] = MarketHandler.lend.selector;
        actions[2] = MarketHandler.redeem.selector;
        actions[3] = MarketHandler.addCollateral.selector;
        actions[4] = MarketHandler.removeCollateral.selector;
        actions[5] = MarketHandler.borrow.selector;
        actions[6] = MarketHandler.repay.selector;
        actions[7] = MarketHandler.fundBuffer.selector;
        actions[8] = MarketHandler.executeBuffer.selector;
        actions[9] = MarketHandler.trim.selector;
        actions[10] = MarketHandler.mintShares.selector;
        actions[11] = MarketHandler.withdrawExit.selector;
        actions[12] = MarketHandler.spenderRedeem.selector;
        actions[13] = MarketHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
        targetContract(address(handler));
    }

    /// INV-MKT-01
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_loanTokenConservation() public view {
        assertEq(
            usdg.balanceOf(address(market)),
            market.cash() + handler.donatedUsdgToMarket(),
            "market USDG equals lender cash plus donations"
        );
    }

    /// INV-MKT-02
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_collateralConservation() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += market.collateralOf(handler.actors(i));
        }
        assertEq(
            tsla.balanceOf(address(market)),
            sum + handler.donatedTslaToMarket(),
            "market collateral equals account collateral plus donations"
        );
    }

    /// INV-MKT-03, INV-MKT-04
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_debtSharesAddUp() public view {
        uint256 sum;
        uint256 withDebt;
        for (uint256 i; i < 4; ++i) {
            (, uint256 shares,) = market.accountOf(handler.actors(i));
            sum += shares;
            if (shares != 0) withDebt++;
        }
        assertEq(market.totalDebtShares(), sum);
        assertEq(market.activeAccounts().length, withDebt, "active set holds exactly the indebted accounts");
    }

    /// INV-X-18
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_escrowBalancesAddUp() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += escrow.planOf(handler.actors(i)).balance;
        }
        assertEq(usdg.balanceOf(address(escrow)), sum + handler.donatedUsdgToEscrow());
    }

    /// INV-MKT-27, INV-MKT-30, INV-MKT-38, INV-MKT-40, INV-MKT-41, INV-MKT-53, INV-MKT-21, INV-MKT-22
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_actionsOnlyInTheirWindows() public view {
        assertEq(handler.borrowsOutsideWindow(), 0, "borrowing");
        assertEq(handler.trimsOutsideWindow(), 0, "trims");
        assertEq(handler.buffersOutsideWindow(), 0, "buffers");
        assertEq(handler.lenderOpsOutsideWindow(), 0, "lender windows");
        assertEq(handler.trimsWithoutCapital(), 0, "no collateral without repayment");
    }

    /// INV-MKT-10
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 12
    function invariant_bookNeverExceedsCashPlusDebt() public view {
        uint256 debt;
        for (uint256 i; i < 4; ++i) {
            debt += market.debtOf(handler.actors(i));
        }
        assertLe(market.totalAssets(), market.cash() + debt);
    }

    /// INV-MKT-04, INV-MKT-05, INV-MKT-06, INV-MKT-09, INV-MKT-10, INV-MKT-15, INV-MKT-33, INV-MKT-48
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 20
    function invariant_bookSharesAndActiveSetAddUp() public view {
        // The active list: exactly the indebted accounts, each slot pointing back at its entry.
        address[] memory act = market.activeAccounts();
        assertLe(act.length, market.MAX_ACCOUNTS());
        uint256 withDebt;
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            (uint256 collateral, uint256 shares, uint256 debt) = market.accountOf(a);
            uint256 slot = uint256(vm.load(address(market), keccak256(abi.encode(a, ACTIVE_SLOT_MAPPING))));
            if (shares != 0) {
                ++withDebt;
                assertGt(slot, 0, "indebted account is listed");
                assertEq(act[slot - 1], a, "its slot points at it");
                assertGt(collateral, 0, "debt is always backed by some collateral");
                assertGt(debt, 0);
            } else {
                assertEq(slot, 0, "accounts without debt hold no slot");
                assertEq(debt, 0);
            }
        }
        assertEq(act.length, withDebt);
        assertEq(market.totalDebtShares() == 0, act.length == 0);

        // The lender book, recomputed from the positions at the price the market uses.
        PriceGate.Quote memory q = gate.quote();
        uint256 price = q.reasons == 0 ? q.priceWad : gate.lastPriceWad();
        uint256 totalDebt;
        uint256 recoverable;
        for (uint256 i; i < act.length; ++i) {
            uint256 debt = market.debtOf(act[i]);
            uint256 value = gate.valueOf(market.collateralOf(act[i]), price);
            totalDebt += debt;
            recoverable += Math.min(debt, Math.mulDiv(value, 1e18, 1e18 + market.RECOVERY_HAIRCUT()));
        }
        StockReefMarket.Book memory b = market.bookValuation();
        assertEq(b.priceWad, price, "usable quote, else the last accepted price");
        assertEq(b.indicative, q.reasons != 0);
        assertEq(b.totalDebt, totalDebt);
        assertEq(b.recoverable, recoverable);
        assertEq(b.impaired, recoverable < totalDebt);
        uint256 ta = market.totalAssets();
        assertEq(ta, market.cash() + recoverable, "totalAssets is cash plus recoverable");
        assertLe(market.convertToAssets(market.totalSupply()), ta);

        // Lender shares belong to the seed lender and the two holders the handler uses.
        assertEq(
            market.totalSupply(),
            market.balanceOf(lender) + market.balanceOf(handler.lender()) + market.balanceOf(handler.liquidator()),
            "totalSupply is the sum of share balances"
        );
        assertGe(market.debtIndex(), 1e18);
    }

    /// INV-MKT-06, INV-MKT-07, INV-MKT-08, INV-MKT-12, INV-MKT-13, INV-MKT-16, INV-MKT-18, INV-MKT-19,
    /// INV-MKT-21, INV-MKT-23, INV-MKT-27, INV-MKT-31, INV-MKT-34, INV-MKT-35, INV-MKT-36, INV-MKT-37,
    /// INV-MKT-39, INV-MKT-41, INV-MKT-42, INV-MKT-43, INV-MKT-45, INV-MKT-47, INV-MKT-48, INV-MKT-56,
    /// INV-X-20, INV-X-21
    /// forge-config: default.invariant.depth = 400
    /// forge-config: default.invariant.runs = 20
    function invariant_actionsMoveExactlyWhatTheyShould() public view {
        assertEq(handler.crossAccountChanges(), 0, "actions on one account moved another");
        assertEq(handler.debtMoveErrors(), 0, "debt moved by other than the amount");
        assertEq(handler.tokenMoveErrors(), 0, "tokens or cash moved by other than the amount");
        assertEq(handler.assetsDrops(), 0, "totalAssets fell where it may not");
        assertEq(handler.sharePriceDrops(), 0, "share price fell outside a trim or a price move");
        assertEq(handler.badDebtErrors(), 0, "bad debt outside a zero-collateral write-off");
        assertEq(handler.trimErrors(), 0, "trim off its quote, window, bonus or target");
        assertEq(handler.minLoanErrors(), 0, "dust below the minimum loan");
        assertEq(handler.freshCreditErrors(), 0, "fresh credit left the account trimmable or impaired");
        assertEq(handler.tickErrors(), 0, "time or a refresh moved positions, cash or shares");
        assertEq(handler.windowErrors(), 0, "lender view and execution disagree, or an exit beat cash");
        assertEq(handler.previewErrors(), 0, "lender action differs from its preview");
        assertEq(handler.donationErrors(), 0, "a donation changed the accounting");
        assertEq(handler.supplyErrors(), 0, "lender shares moved outside the lender paths");
        assertEq(handler.exitFailures(), 0, "a repayment, top-up or free withdrawal failed");
    }
}
