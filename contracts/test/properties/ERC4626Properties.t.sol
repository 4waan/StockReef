// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MarketFixture, MarketHarness} from "../utils/MarketFixture.sol";
import {SessionRiskPolicy} from "../../src/SessionRiskPolicy.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";

/// @notice ERC-4626 properties in the style of the a16z property suite, adapted to StockReefMarket: lender assets
/// are idle cash plus the recoverable value of the loan book, the share token carries six virtual decimals, entry
/// is open only in the OPEN state and exits also in wind-down, and exits are capped by idle cash.
/// The book holds a healthy borrower (bob) and the spec's worked example (carol); `_live` moves time inside
/// Friday's OPEN window so interest makes the share price irregular, and can mark carol's loan below face.
contract MarketERC4626PropertiesTest is MarketFixture {
    address internal depositor = makeAddr("depositor");
    address internal other = makeAddr("other");
    address internal whale = makeAddr("whale");

    uint256 internal constant OFFSET = 1e6;

    function setUp() public {
        _setUpMarket();
        _openFriday();
        _lend(100_000 * USDG);
        usdg.mint(depositor, 100_000_000 * USDG);
        vm.prank(depositor);
        usdg.approve(address(market), type(uint256).max);
        vm.prank(depositor);
        market.deposit(1_000_000 * USDG, depositor);
        _workedExample(carol);
        _fundCollateral(bob, 100 * TOKEN);
        _borrow(bob, 20_000 * USDG);
    }

    /// @dev Keeper tick inside Friday's OPEN window (O + 20 min to O + 4 h 10 min, before A at O + 4 h 30 min).
    /// With `impair`, carol's collateral is marked at 290, about 99% LTV, so her loan counts at value / 1.05.
    function _live(uint256 dt, bool impair) internal {
        if (impair) _setPrice(290e8);
        _tick(FRI_OPEN + 20 minutes + bound(dt, 0, 3 hours + 50 minutes));
        assertTrue(policy.snapshot().lenderOpen, "lender window open");
        assertEq(market.bookValuation().impaired, impair, "impairment as requested");
    }

    /// @dev Appendix R21: while the book is impaired, deposits and mints are closed even in the lender window.
    function _expectEntryClosedWhileImpaired() internal {
        assertEq(market.maxDeposit(depositor), 0, "no deposits while impaired");
        assertEq(market.maxMint(depositor), 0, "no mints while impaired");
        vm.startPrank(depositor);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, depositor, 1, 0));
        market.deposit(1, depositor);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, depositor, 1, 0));
        market.mint(1, depositor);
        vm.stopPrank();
    }

    function _sharesFloor(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, market.totalSupply() + OFFSET, market.totalAssets() + 1, Math.Rounding.Floor);
    }

    function _sharesCeil(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, market.totalSupply() + OFFSET, market.totalAssets() + 1, Math.Rounding.Ceil);
    }

    function _assetsFloor(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, market.totalAssets() + 1, market.totalSupply() + OFFSET, Math.Rounding.Floor);
    }

    function _assetsCeil(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, market.totalAssets() + 1, market.totalSupply() + OFFSET, Math.Rounding.Ceil);
    }

    // ================================================================ conversions and previews

    /// INV-MKT-42, INV-MKT-10
    function testFuzz_convert_roundsDownWithTheVirtualOffset(uint256 assets, uint256 shares, uint256 dt, bool impair)
        public
    {
        _live(dt, impair);
        assets = bound(assets, 0, 1e30);
        shares = bound(shares, 0, 1e36);
        assertEq(market.convertToShares(assets), _sharesFloor(assets), "convertToShares floors");
        assertEq(market.convertToAssets(shares), _assetsFloor(shares), "convertToAssets floors");
        // The same answer for every caller.
        vm.prank(other);
        assertEq(market.convertToShares(assets), _sharesFloor(assets));
        vm.prank(carol);
        assertEq(market.convertToAssets(shares), _assetsFloor(shares));
        // Shares never claim more than the book: the virtual offset only dilutes.
        assertLe(market.convertToAssets(market.totalSupply()), market.totalAssets());
    }

    /// INV-MKT-42
    function testFuzz_previews_roundAgainstTheCaller(uint256 assets, uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        assets = bound(assets, 0, 1e30);
        shares = bound(shares, 0, 1e36);
        assertEq(market.previewDeposit(assets), _sharesFloor(assets), "previewDeposit floors");
        assertEq(market.previewMint(shares), _assetsCeil(shares), "previewMint rounds up");
        assertEq(market.previewWithdraw(assets), _sharesCeil(assets), "previewWithdraw rounds up");
        assertEq(market.previewRedeem(shares), _assetsFloor(shares), "previewRedeem floors");
        assertLe(market.previewDeposit(assets), market.previewWithdraw(assets));
        assertGe(market.previewMint(shares), market.previewRedeem(shares));
    }

    // ================================================================ actions equal their previews

    /// INV-MKT-42, INV-MKT-56
    function testFuzz_deposit_mintsThePreviewAndMovesExactlyTheAssets(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assets = bound(assets, 0, 5_000_000 * USDG);
        uint256 preview = market.previewDeposit(assets);
        uint256 cash0 = market.cash();
        uint256 bal0 = usdg.balanceOf(address(market));
        uint256 payer0 = usdg.balanceOf(depositor);
        uint256 held0 = market.balanceOf(other);
        vm.prank(depositor);
        uint256 shares = market.deposit(assets, other);
        assertEq(shares, preview, "deposit == previewDeposit");
        assertEq(market.balanceOf(other) - held0, shares, "receiver gets the shares");
        assertEq(payer0 - usdg.balanceOf(depositor), assets, "caller pays exactly assets");
        assertEq(usdg.balanceOf(address(market)) - bal0, assets);
        assertEq(market.cash() - cash0, assets, "cash rises by exactly assets");
    }

    /// INV-MKT-42, INV-MKT-56
    function testFuzz_mint_chargesThePreview(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        shares = bound(shares, 0, 5_000_000 * USDG * OFFSET);
        uint256 preview = market.previewMint(shares);
        uint256 cash0 = market.cash();
        uint256 payer0 = usdg.balanceOf(depositor);
        uint256 held0 = market.balanceOf(other);
        vm.prank(depositor);
        uint256 assets = market.mint(shares, other);
        assertEq(assets, preview, "mint == previewMint");
        assertEq(market.balanceOf(other) - held0, shares);
        assertEq(payer0 - usdg.balanceOf(depositor), assets);
        assertEq(market.cash() - cash0, assets);
    }

    /// INV-MKT-42, INV-MKT-56
    function testFuzz_withdraw_burnsThePreview(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        assets = bound(assets, 0, market.maxWithdraw(depositor));
        uint256 preview = market.previewWithdraw(assets);
        uint256 cash0 = market.cash();
        uint256 held0 = market.balanceOf(depositor);
        uint256 recv0 = usdg.balanceOf(other);
        vm.prank(depositor);
        uint256 shares = market.withdraw(assets, other, depositor);
        assertEq(shares, preview, "withdraw == previewWithdraw");
        assertEq(held0 - market.balanceOf(depositor), shares);
        assertEq(usdg.balanceOf(other) - recv0, assets, "receiver gets exactly assets");
        assertEq(cash0 - market.cash(), assets);
    }

    /// INV-MKT-42, INV-MKT-56
    function testFuzz_redeem_paysThePreview(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        shares = bound(shares, 0, market.maxRedeem(depositor));
        uint256 preview = market.previewRedeem(shares);
        uint256 cash0 = market.cash();
        uint256 held0 = market.balanceOf(depositor);
        uint256 recv0 = usdg.balanceOf(other);
        vm.prank(depositor);
        uint256 assets = market.redeem(shares, other, depositor);
        assertEq(assets, preview, "redeem == previewRedeem");
        assertEq(held0 - market.balanceOf(depositor), shares);
        assertEq(usdg.balanceOf(other) - recv0, assets);
        assertEq(cash0 - market.cash(), assets);
    }

    // ================================================================ round trips never profit

    /// INV-MKT-45
    function testFuzz_roundTrip_depositThenRedeem(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assets = bound(assets, 0, 5_000_000 * USDG);
        vm.startPrank(depositor);
        uint256 shares = market.deposit(assets, depositor);
        uint256 back = market.redeem(shares, depositor, depositor);
        vm.stopPrank();
        assertLe(back, assets, "redeem(deposit(a)) <= a");
        assertLe(assets - back, 1, "at most one unit lost");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_depositThenWithdraw(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assets = bound(assets, 0, 5_000_000 * USDG);
        vm.startPrank(depositor);
        uint256 minted = market.deposit(assets, depositor);
        uint256 burned = market.withdraw(assets, depositor, depositor);
        vm.stopPrank();
        assertGe(burned, minted, "withdraw(a) after deposit(a) burns at least the shares minted");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_mintThenRedeem(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        shares = bound(shares, 0, 5_000_000 * USDG * OFFSET);
        vm.startPrank(depositor);
        uint256 paid = market.mint(shares, depositor);
        uint256 back = market.redeem(shares, depositor, depositor);
        vm.stopPrank();
        assertLe(back, paid, "redeem(s) after mint(s) returns at most the cost");
        assertLe(paid - back, 1, "at most one unit lost");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_mintThenWithdraw(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        shares = bound(shares, 0, 5_000_000 * USDG * OFFSET);
        vm.startPrank(depositor);
        uint256 paid = market.mint(shares, depositor);
        uint256 burned = market.withdraw(paid, depositor, depositor);
        vm.stopPrank();
        assertGe(burned, shares, "withdraw(mint(s)) burns at least s");
        assertLe(market.convertToAssets(burned - shares), 1, "the extra shares are worth at most one unit");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_redeemThenDeposit(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        shares = bound(shares, 0, market.maxRedeem(depositor));
        vm.startPrank(depositor);
        uint256 assets = market.redeem(shares, depositor, depositor);
        uint256 again = market.deposit(assets, depositor);
        vm.stopPrank();
        assertLe(again, shares, "deposit(redeem(s)) <= s");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_redeemThenMint(uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        shares = bound(shares, 0, market.maxRedeem(depositor));
        uint256 expectPaid = _assetsFloor(shares);
        vm.prank(depositor);
        uint256 assets = market.redeem(shares, depositor, depositor);
        // The redeem's rounding residue stays with the remaining holders and lifts the price the mint pays, so
        // each step loses less than one unit at its own price.
        uint256 expectCost = _assetsCeil(shares);
        vm.prank(depositor);
        uint256 cost = market.mint(shares, depositor);
        assertEq(assets, expectPaid);
        assertEq(cost, expectCost);
        assertGe(cost, assets, "mint(s) after redeem(s) costs at least what redeem paid");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_withdrawThenMint(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assets = bound(assets, 0, market.maxWithdraw(depositor));
        vm.startPrank(depositor);
        uint256 burned = market.withdraw(assets, depositor, depositor);
        uint256 cost = market.mint(burned, depositor);
        vm.stopPrank();
        assertGe(cost, assets, "mint(withdraw(a)) costs at least a");
    }

    /// INV-MKT-45
    function testFuzz_roundTrip_withdrawThenDeposit(uint256 assets, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assets = bound(assets, 0, market.maxWithdraw(depositor));
        vm.startPrank(depositor);
        uint256 burned = market.withdraw(assets, depositor, depositor);
        uint256 again = market.deposit(assets, depositor);
        vm.stopPrank();
        assertLe(again, burned, "deposit(a) after withdraw(a) returns at most the shares burned");
    }

    // ================================================================ max* equals what succeeds

    /// @dev A whale borrows `drainBps` of the most the 90% utilization cap allows, so idle cash binds exits. Runs
    /// before `_live`, while the book is still healthy.
    function _drainCash(uint256 drainBps) internal {
        drainBps = bound(drainBps, 0, 10_000);
        if (drainBps == 0) return;
        _fundCollateral(whale, 20_000 * TOKEN);
        (uint256 cash, uint256 debt) = (market.cash(), market.bookValuation().totalDebt);
        uint256 cap = (9 * cash - debt) / 10;
        uint256 amount = cap * drainBps / 10_000;
        if (amount < MIN_LOAN) return;
        _borrow(whale, amount);
    }

    /// INV-MKT-43, INV-MKT-41
    function testFuzz_max_withdrawIsExactlyWhatSucceeds(uint256 dt, bool impair, uint256 drainBps, bool asLender)
        public
    {
        _drainCash(drainBps);
        _live(dt, impair);
        address owner = asLender ? lender : depositor;
        uint256 m = market.maxWithdraw(owner);
        assertEq(m, Math.min(_assetsFloor(market.balanceOf(owner)), market.cash()), "value of shares, capped by cash");
        assertLe(m, market.cash(), "never more than idle cash");

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        market.withdraw(m + 1, owner, owner);
        vm.revertToState(snap);

        uint256 cash0 = market.cash();
        vm.prank(owner);
        market.withdraw(m, owner, owner);
        assertEq(cash0 - market.cash(), m);
    }

    /// INV-MKT-43, INV-MKT-41
    function testFuzz_max_redeemIsExactlyWhatSucceeds(uint256 dt, bool impair, uint256 drainBps, bool asLender) public {
        _drainCash(drainBps);
        _live(dt, impair);
        address owner = asLender ? lender : depositor;
        uint256 m = market.maxRedeem(owner);
        // The cash cap converts with floor rounding, so the shares it allows never pay out more than the cash.
        assertEq(m, Math.min(market.balanceOf(owner), _sharesFloor(market.cash())), "balance, capped by cash");
        assertLe(market.previewRedeem(m), market.cash());

        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        market.redeem(m + 1, owner, owner);
        vm.revertToState(snap);

        uint256 cash0 = market.cash();
        vm.prank(owner);
        uint256 paid = market.redeem(m, owner, owner);
        assertEq(cash0 - market.cash(), paid);
    }

    /// INV-MKT-41, INV-MKT-44
    function testFuzz_max_entryIsUnlimitedWhileOpen(uint256 assets, uint256 shares, uint256 dt, bool impair) public {
        _live(dt, impair);
        if (impair) {
            _expectEntryClosedWhileImpaired();
            return;
        }
        assertEq(market.maxDeposit(depositor), type(uint256).max);
        assertEq(market.maxMint(other), type(uint256).max);
        assets = bound(assets, 0, 40_000_000 * USDG);
        shares = bound(shares, 0, 40_000_000 * USDG * OFFSET);
        vm.startPrank(depositor);
        market.deposit(assets, depositor);
        market.mint(shares, depositor);
        vm.stopPrank();
    }

    // ================================================================ locks

    /// @dev Puts the market in a state where the lender window is closed, chosen by `which`.
    function _lock(uint256 which, uint256 dt) internal returns (SessionRiskPolicy.State expected) {
        which = bound(which, 0, 6);
        dt = bound(dt, 0, 25 minutes);
        if (which == 0) {
            _tick(FRI_CLOSE - 120 minutes + dt);
            return SessionRiskPolicy.State.PRE_CLOSE;
        } else if (which == 1) {
            _tick(FRI_CLOSE - 30 minutes + dt);
            return SessionRiskPolicy.State.FINAL_WINDOW;
        } else if (which == 2) {
            vm.warp(FRI_CLOSE + dt * 100); // the feed goes stale; no refresh
            return SessionRiskPolicy.State.CLOSED;
        } else if (which == 3) {
            _pushAt(MON_OPEN + dt % 5 minutes, answer); // before admission is possible
            return SessionRiskPolicy.State.REOPEN_WAIT;
        } else if (which == 4) {
            _tick(MON_OPEN + 5 minutes + dt % 10 minutes); // admitted, credit not back yet
            return SessionRiskPolicy.State.REOPEN_RECOVERY;
        } else if (which == 5) {
            _tick(FRI_OPEN + 30 minutes + dt);
            vm.prank(guardian);
            gate.stop();
            return SessionRiskPolicy.State.GUARDED;
        }
        vm.warp(FRI_OPEN + 30 minutes + dt); // OPEN phase, but the feed is older than its maximum age
        return SessionRiskPolicy.State.GUARDED;
    }

    /// INV-MKT-41, INV-MKT-42, INV-MKT-43, INV-MKT-53, INV-X-06
    function testFuzz_locks_closeEveryLenderPathButNotPreviewsOrTransfers(uint256 which, uint256 dt, uint256 amount)
        public
    {
        SessionRiskPolicy.State expected = _lock(which, dt);
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertEq(uint256(s.state), uint256(expected), "intended state");
        assertFalse(s.lenderOpen);
        assertFalse(s.windDown);

        // Views say the window is closed...
        assertEq(market.maxDeposit(depositor), 0);
        assertEq(market.maxMint(depositor), 0);
        assertEq(market.maxWithdraw(depositor), 0);
        assertEq(market.maxRedeem(depositor), 0);
        // ...while conversions and previews keep working with the standard rounding.
        amount = bound(amount, 1, 1_000_000 * USDG);
        assertEq(market.previewDeposit(amount), _sharesFloor(amount));
        assertEq(market.previewMint(amount * OFFSET), _assetsCeil(amount * OFFSET));
        assertEq(market.previewWithdraw(amount), _sharesCeil(amount));
        assertEq(market.previewRedeem(amount * OFFSET), _assetsFloor(amount * OFFSET));

        // ...and every action agrees, after its own refresh.
        vm.startPrank(depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(amount, depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.mint(amount * OFFSET, depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.withdraw(amount, depositor, depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.redeem(amount * OFFSET, depositor, depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(0, depositor);

        // Share transfers are plain ERC-20 and need no window.
        uint256 shares = market.balanceOf(depositor) / 3;
        market.transfer(other, shares);
        vm.stopPrank();
        assertEq(market.balanceOf(other), shares);
    }

    /// INV-MKT-41, INV-MKT-43, INV-MKT-53, INV-X-13
    function testFuzz_windDown_exitsOnlyAgainstIdleCash(uint256 dt, bool stopped, uint256 drainBps) public {
        _drainCash(drainBps);
        vm.warp(cal.lastOpen() + bound(dt, 0, 400 days));
        if (stopped) {
            vm.prank(guardian);
            gate.stop();
        }
        SessionRiskPolicy.Snapshot memory s = policy.snapshot();
        assertTrue(s.windDown);
        assertFalse(s.lenderOpen);
        assertEq(market.maxDeposit(depositor), 0, "no entry in wind-down");
        assertEq(market.maxMint(depositor), 0);
        vm.prank(depositor);
        vm.expectPartialRevert(StockReefMarket.NotAllowedNow.selector);
        market.deposit(1 * USDG, depositor);

        uint256 m = market.maxWithdraw(depositor);
        assertEq(m, Math.min(_assetsFloor(market.balanceOf(depositor)), market.cash()));
        uint256 snap = vm.snapshotState();
        vm.prank(depositor);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        market.withdraw(m + 1, depositor, depositor);
        vm.revertToState(snap);
        vm.prank(depositor);
        market.withdraw(m, depositor, depositor);

        uint256 cashBefore = market.cash();
        uint256 r = market.maxRedeem(lender);
        assertEq(r, Math.min(market.balanceOf(lender), _sharesFloor(cashBefore)));
        vm.prank(lender);
        uint256 paid = market.redeem(r, lender, lender);
        assertLe(paid, cashBefore, "never more than idle cash");
        assertLe(market.maxWithdraw(lender), market.cash());
    }

    // ================================================================ donations and inflation

    /// @dev Everything a donation must leave unchanged.
    struct Picture {
        uint256 totalAssets;
        uint256 toShares;
        uint256 toAssets;
        uint256 totalDebt;
        uint256 recoverable;
        bool impaired;
        uint256 collateral;
        uint256 debtShares;
        uint256 debt;
        uint256 maxWithdraw;
        uint256 plan;
    }

    function _picture() internal view returns (Picture memory p) {
        p.totalAssets = market.totalAssets();
        p.toShares = market.convertToShares(1_000 * USDG);
        p.toAssets = market.convertToAssets(1_000 * USDG * OFFSET);
        StockReefMarket.Book memory b = market.bookValuation();
        (p.totalDebt, p.recoverable, p.impaired) = (b.totalDebt, b.recoverable, b.impaired);
        (p.collateral, p.debtShares, p.debt) = market.accountOf(carol);
        p.maxWithdraw = market.maxWithdraw(depositor);
        p.plan = escrow.planOf(bob).balance;
    }

    /// INV-MKT-47, INV-MKT-10, INV-X-18
    function testFuzz_donations_changeNoAccountingOrConversion(
        uint256 usdgToMarket,
        uint256 tslaToMarket,
        uint256 usdgToEscrow,
        uint256 dt,
        bool impair
    ) public {
        _live(dt, impair);
        usdgToMarket = bound(usdgToMarket, 0, 10_000_000 * USDG);
        tslaToMarket = bound(tslaToMarket, 0, 10_000 * TOKEN);
        usdgToEscrow = bound(usdgToEscrow, 0, 10_000_000 * USDG);
        Picture memory p0 = _picture();

        usdg.mint(address(market), usdgToMarket);
        tsla.mint(address(market), tslaToMarket);
        usdg.mint(address(escrow), usdgToEscrow);

        Picture memory p1 = _picture();
        assertEq(p1.totalAssets, p0.totalAssets, "totalAssets");
        assertEq(p1.toShares, p0.toShares, "convertToShares");
        assertEq(p1.toAssets, p0.toAssets, "convertToAssets");
        assertEq(p1.totalDebt, p0.totalDebt);
        assertEq(p1.recoverable, p0.recoverable);
        assertEq(p1.impaired, p0.impaired);
        assertEq(p1.collateral, p0.collateral);
        assertEq(p1.debtShares, p0.debtShares);
        assertEq(p1.debt, p0.debt);
        assertEq(p1.maxWithdraw, p0.maxWithdraw, "exits are still limited by cash");
        assertEq(p1.plan, p0.plan, "escrow donations credit no plan");
        assertEq(usdg.balanceOf(address(market)), market.cash() + usdgToMarket, "the surplus is the donation");
    }

    /// INV-MKT-47, INV-MKT-45
    function testFuzz_inflation_aDonationCannotSkimTheNextDepositor(uint256 seed, uint256 donation, uint256 victim)
        public
    {
        MarketHarness fresh = new MarketHarness(usdg, tsla, policy, MIN_LOAN);
        seed = bound(seed, 1, 1_000 * USDG);
        donation = bound(donation, 1, 900_000 * USDG);
        victim = bound(victim, 1, 10_000_000 * USDG);
        vm.startPrank(liquidator); // the attacker
        usdg.approve(address(fresh), type(uint256).max);
        uint256 attackerShares = fresh.deposit(seed, liquidator);
        usdg.transfer(address(fresh), donation);
        vm.stopPrank();
        assertEq(fresh.totalAssets(), seed, "the donation is not lender cash");

        vm.startPrank(depositor);
        usdg.approve(address(fresh), type(uint256).max);
        uint256 victimShares = fresh.deposit(victim, depositor);
        vm.stopPrank();
        assertGt(victimShares, 0);
        assertGe(fresh.previewRedeem(victimShares) + 1, victim, "the victim loses at most one unit");
        assertLe(fresh.previewRedeem(attackerShares), seed, "the attacker gets back at most the seed");

        vm.prank(depositor);
        uint256 back = fresh.redeem(victimShares, depositor, depositor);
        assertGe(back + 1, victim);
    }

    // ================================================================ zero amounts and run-off

    /// INV-MKT-49, INV-MKT-44
    function test_zeroAmounts_areNoOpsWhileTheWindowIsOpen() public {
        vm.startPrank(lender);
        uint256 shares = market.balanceOf(lender);
        uint256 cash = market.cash();
        assertEq(market.deposit(0, lender), 0);
        assertEq(market.mint(0, lender), 0);
        assertEq(market.withdraw(0, lender, lender), 0);
        assertEq(market.redeem(0, lender, lender), 0);
        assertEq(market.balanceOf(lender), shares);
        assertEq(market.cash(), cash);
        // A single share is worth less than one base unit, so redeeming it pays nothing.
        assertEq(market.redeem(1, lender, lender), 0);
        assertEq(market.balanceOf(lender), shares - 1);
        vm.stopPrank();
    }

    /// INV-MKT-46, INV-MKT-41 (mutant: maxMint without the run-off check)
    function test_runOff_blocksDepositAndMintAndTheirViewsAgree() public {
        // Fresh market: one lender, one loan that takes all but the capped cash, then the lender takes the rest.
        MarketHarness m = new MarketHarness(usdg, tsla, policy, MIN_LOAN);
        vm.prank(lender);
        usdg.approve(address(m), type(uint256).max);
        vm.prank(lender);
        m.deposit(10_000 * USDG, lender);
        tsla.mint(alice, 25 * TOKEN);
        vm.startPrank(alice);
        tsla.approve(address(m), type(uint256).max);
        m.depositCollateral(25 * TOKEN, alice);
        m.borrow(7_500 * USDG - 1, alice);
        vm.stopPrank();
        uint256 idle = m.cash();
        vm.prank(lender);
        m.withdraw(idle, lender, lender);

        _setPrice(1); // the collateral is now worth nothing
        _tick(FRI_OPEN + 2 hours);
        assertEq(m.totalAssets(), 0);
        assertGt(m.totalSupply(), 0);
        assertTrue(policy.snapshot().lenderOpen, "the window itself is open");
        assertEq(m.maxDeposit(depositor), 0, "run-off: no deposit");
        assertEq(m.maxMint(depositor), 0, "run-off: no mint");

        vm.startPrank(depositor);
        usdg.approve(address(m), type(uint256).max);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        m.deposit(1 * USDG, depositor);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxMint.selector);
        m.mint(1e12, depositor);
        vm.stopPrank();
    }
}
