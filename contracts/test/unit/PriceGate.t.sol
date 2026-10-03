// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {MarketFixture} from "../utils/MarketFixture.sol";
import {ScriptedFeed, PlainToken} from "../utils/ScriptedFeed.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";
import {StockReefMarket} from "../../src/StockReefMarket.sol";
import {StockReefLens} from "../../src/StockReefLens.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IClock} from "../../src/interfaces/IClock.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

contract PriceGateTest is GateFixture {
    function setUp() public {
        _setUpGate();
    }

    // ------------------------------------------------------------ construction

    function test_constructor_recordsManifest() public view {
        assertEq(gate.VALUE_SCALE(), 1e30);
        assertTrue(gate.usesPeg());
        assertEq(gate.pegLabel(), "Test peg: 1 USDG = 1 USD");
        assertEq(gate.owner(), guardian);
        assertEq(address(gate.stockFeed()), address(stockFeed));
        assertEq(gate.stockMaxAge(), MOCK_MAX_AGE);
    }

    function test_constructor_revertsOnTokenDecimalsMismatch() public {
        PriceGate.Config memory c = _config();
        c.tokenDecimals = 8;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(tsla), 8, 18));
        new PriceGate(c);
    }

    function test_constructor_revertsOnLoanDecimalsMismatch() public {
        PriceGate.Config memory c = _config();
        c.loanDecimals = 18;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(usdg), 18, 6));
        new PriceGate(c);
    }

    function test_constructor_revertsOnFeedDecimalsMismatch() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.decimals = 18;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(stockFeed), 18, 8));
        new PriceGate(c);
    }

    function test_constructor_revertsOnPegOutsideTestChains() public {
        PriceGate.Config memory c = _config();
        vm.chainId(4663);
        vm.expectRevert(abi.encodeWithSelector(PriceGate.PegNotAllowed.selector, 4663));
        new PriceGate(c);
    }

    function test_constructor_revertsOnMissingPegLabel() public {
        PriceGate.Config memory c = _config();
        c.pegLabel = "";
        vm.expectRevert(PriceGate.MissingPegLabel.selector);
        new PriceGate(c);
    }

    function test_constructor_acceptsLoanFeedOutsideTestChains() public {
        PriceGate.Config memory c = _config();
        ScriptedFeed loan = new ScriptedFeed(8);
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 86400, 2e8);
        c.pegLabel = "";
        vm.chainId(4663);
        PriceGate g = new PriceGate(c);
        assertFalse(g.usesPeg());
    }

    function test_constructor_revertsOnMissingFeedLimits() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 0;
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
    }

    // ------------------------------------------------------------ prices and units

    function test_quote_valuesTheWorkedExampleAtGoldenValues() public {
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        PriceGate.Quote memory q = gate.quote();
        assertEq(q.reasons, 0);
        assertEq(q.priceWad, _golden(".worked_example.price_wad"));
        assertEq(
            gate.valueOf(_golden(".worked_example.collateral_raw"), q.priceWad), _golden(".worked_example.value_usdg")
        );
        assertEq(gate.valueOf(_golden(".demo_example.collateral_raw"), q.priceWad), _golden(".demo_example.value_usdg"));
    }

    function test_quote_convertsThroughLoanFeed() public {
        ScriptedFeed loan = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 86400, 2e8);
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        loan.set(0.98e8, block.timestamp, block.timestamp);
        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, 0);
        // 400 USD per token / 0.98 USD per USDG, floored in WAD.
        assertEq(q.priceWad, uint256(400e18) * 100 / 98);
    }

    function test_quote_rejectsBadStockAnswers() public {
        _warp(MON_OPEN + 1 hours);
        stockFeed.push(0);
        assertEq(gate.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        stockFeed.push(-1);
        assertEq(gate.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        stockFeed.push(int256(ANSWER_BOUND) + 1);
        assertEq(gate.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        assertEq(gate.quote().priceWad, 0);
        stockFeed.push(int256(ANSWER_BOUND));
        assertEq(gate.quote().reasons, 0, "the bound itself is accepted");
    }

    function test_quote_largeMoveBelowBoundIsNotInvalid() public {
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        stockFeed.push(TSLA_400 / 3); // a 66% gap is a price, not a malformed round
        assertEq(gate.quote().reasons, 0);
    }

    function test_quote_rejectsFutureAndStaleStockTimestamps() public {
        _warp(MON_OPEN + 1 hours);
        stockFeed.pushAt(TSLA_400, uint64(block.timestamp + 1));
        assertEq(gate.quote().reasons, Reasons.STOCK_FUTURE_TIMESTAMP);

        _warp(block.timestamp + 1 + MOCK_MAX_AGE);
        assertEq(gate.quote().reasons, 0, "exactly maxAge old is fresh");
        _warp(block.timestamp + 1);
        assertEq(gate.quote().reasons, Reasons.STOCK_STALE);
    }

    function test_quote_rejectsZeroTimestampAndUnavailableFeed() public {
        ScriptedFeed feed = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.stockFeed.feed = IAggregatorV3(address(feed));
        PriceGate g = new PriceGate(c);
        _warp(MON_OPEN + 1 hours);

        feed.set(TSLA_400, 0, 0);
        assertEq(g.quote().reasons, Reasons.STOCK_NO_TIMESTAMP);

        feed.setReverting(true);
        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, Reasons.STOCK_FEED_UNAVAILABLE);
        assertEq(q.priceWad, 0);
    }

    function test_quote_flagsChangedFeedDecimals() public {
        ScriptedFeed feed = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.stockFeed.feed = IAggregatorV3(address(feed));
        PriceGate g = new PriceGate(c);
        _warp(MON_OPEN + 1 hours);
        feed.set(TSLA_400, block.timestamp, block.timestamp);
        assertEq(g.quote().reasons, 0);
        feed.setDecimals(18);
        assertEq(g.quote().reasons, Reasons.STOCK_DECIMALS_CHANGED);
        feed.setDecimalsReverting(true);
        assertEq(g.quote().reasons, Reasons.STOCK_DECIMALS_CHANGED);
    }

    function test_quote_rejectsBrokenLoanConversion() public {
        ScriptedFeed loan = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 3600, 2e8);
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        uint256 t = block.timestamp;

        loan.set(1e8, t, t);
        assertEq(g.quote().reasons, 0);
        loan.set(0, t, t);
        assertEq(g.quote().reasons, Reasons.LOAN_BAD_ANSWER);
        loan.set(type(int256).max, t, t);
        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, Reasons.LOAN_BAD_ANSWER, "an absurd answer is rejected without overflowing");
        assertEq(q.priceWad, 0);
        loan.set(1e8, 0, 0);
        assertEq(g.quote().reasons, Reasons.LOAN_NO_TIMESTAMP);
        loan.set(1e8, t + 1, t + 1);
        assertEq(g.quote().reasons, Reasons.LOAN_FUTURE_TIMESTAMP);
        loan.set(1e8, t - 3601, t - 3601);
        assertEq(g.quote().reasons, Reasons.LOAN_STALE);
        loan.set(1e8, t, t);
        loan.setDecimals(6);
        assertEq(g.quote().reasons, Reasons.LOAN_DECIMALS_CHANGED);
        loan.setReverting(true);
        assertEq(g.quote().reasons, Reasons.LOAN_FEED_UNAVAILABLE | Reasons.LOAN_DECIMALS_CHANGED);
    }

    // ------------------------------------------------------------ token checks

    function test_quote_honoursIssuerPause() public {
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        tsla.setOraclePaused(true);
        assertEq(gate.quote().reasons, Reasons.ISSUER_PAUSED);
        tsla.setOraclePaused(false);
        assertEq(gate.quote().reasons, 0);
    }

    function test_quote_failsClosedWhenRequiredPauseFlagIsMissing() public {
        MockStockToken noFlag = new MockStockToken("Tesla", "TSLA", false);
        PriceGate.Config memory c = _config();
        c.token = address(noFlag);
        PriceGate required = new PriceGate(c);
        c.pauseFlagRequired = false;
        PriceGate optional = new PriceGate(c);

        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        assertEq(required.quote().reasons, Reasons.PAUSE_FLAG_UNAVAILABLE);
        assertEq(optional.quote().reasons, 0, "testnet token version without the flag, declared in the manifest");
    }

    function test_quote_waitsForTheFeedAfterAMultiplierChange() public {
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        uint256 effective = block.timestamp + 60;
        tsla.scheduleMultiplier(2e18, effective);

        _warp(effective - 1);
        stockFeed.push(TSLA_400);
        assertEq(gate.quote().reasons, 0, "not yet effective");

        _warp(effective);
        assertEq(gate.quote().reasons, Reasons.MULTIPLIER_LAG, "feed predates the new multiplier");

        stockFeed.push(TSLA_400 * 2);
        assertEq(gate.quote().reasons, 0, "feed published at or after the change");
    }

    function test_quote_failsClosedWithoutMultiplierGetters() public {
        PlainToken plain = new PlainToken();
        PriceGate.Config memory c = _config();
        c.token = address(plain);
        c.pauseFlagRequired = false;
        PriceGate checked = new PriceGate(c);
        c.erc8056 = false;
        PriceGate unchecked_ = new PriceGate(c);

        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        assertEq(checked.quote().reasons, Reasons.MULTIPLIER_UNAVAILABLE);
        assertEq(unchecked_.quote().reasons, 0);
    }

    // ------------------------------------------------------------ sequencer uptime (appendix R14)

    function test_quote_sequencerSlotIsOptional() public {
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        assertEq(address(gate.sequencerFeed()), address(0));
        assertEq(gate.quote().reasons, 0);
    }

    function test_quote_checksSequencerUptimeWhenConfigured() public {
        ScriptedFeed seq = new ScriptedFeed(0);
        PriceGate.Config memory c = _config();
        c.sequencerFeed = IAggregatorV3(address(seq));
        c.sequencerGrace = 3600;
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 3 hours, TSLA_400);
        uint256 t = block.timestamp;

        seq.set(0, t - 3600, t - 3600);
        assertEq(g.quote().reasons, 0, "up for exactly the grace period");
        seq.set(0, t - 3599, t - 3599);
        assertEq(g.quote().reasons, Reasons.SEQUENCER_GRACE);
        seq.set(1, t - 7200, t - 7200);
        assertEq(g.quote().reasons, Reasons.SEQUENCER_DOWN);
        seq.set(0, 0, t);
        assertEq(g.quote().reasons, Reasons.SEQUENCER_DOWN, "uninitialised uptime feed");
        seq.setReverting(true);
        assertEq(g.quote().reasons, Reasons.SEQUENCER_DOWN);
    }

    // ------------------------------------------------------------ reopening admission

    function test_refresh_admitsAtOpenPlusFiveWithAFreshPrice() public {
        _pushAt(MON_OPEN + 1 minutes, TSLA_400);
        _warp(MON_OPEN + 5 minutes - 1);
        stockFeed.push(TSLA_400);
        gate.refresh();
        assertEq(gate.admissionFor(_monIndex()), 0, "too early");

        _warp(MON_OPEN + 5 minutes);
        stockFeed.push(TSLA_400);
        vm.expectEmit(address(gate));
        emit PriceGate.Admitted(_monIndex(), MON_OPEN + 5 minutes, MON_OPEN + 5 minutes);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, 0);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 5 minutes);
    }

    function test_refresh_neverAdmitsAPriorSessionQuote() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 86400; // the real feed's heartbeat: a Sunday-evening quote is still "fresh"
        PriceGate g = new PriceGate(c);

        _pushAt(MON_OPEN - 13 hours, TSLA_400); // Sunday overnight-session print
        _warp(MON_OPEN + 10 minutes);
        PriceGate.Quote memory q = g.refresh();
        assertEq(q.reasons, 0, "valid as a price");
        assertEq(g.admissionFor(_monIndex()), 0, "but not admitted for the reopening");

        _pushAt(MON_OPEN + 1 minutes - 1, TSLA_400);
        _warp(MON_OPEN + 11 minutes);
        g.refresh();
        assertEq(g.admissionFor(_monIndex()), 0, "stamped before O + 1 minute");

        _pushAt(MON_OPEN + 12 minutes, TSLA_400);
        g.refresh();
        assertEq(g.admissionFor(_monIndex()), MON_OPEN + 12 minutes);
    }

    function test_refresh_admitsOncePerSession() public {
        _freshRefresh(MON_OPEN + 6 minutes);
        _freshRefresh(MON_OPEN + 2 hours);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 6 minutes);
    }

    function test_refresh_recordsNothingWhileClosed() public {
        _freshRefresh(MON_OPEN - 1 hours);
        assertEq(gate.admittedSession(), 0);
        _freshRefresh(MON_CLOSE + 1 hours);
        assertEq(gate.admittedSession(), 0);
    }

    function test_refresh_eachSessionNeedsItsOwnAdmission() public {
        _freshRefresh(MON_OPEN + 6 minutes);
        uint256 tue = _monIndex() + 1;
        _pushAt(TUE_OPEN + 4 minutes, TSLA_400);
        assertEq(gate.admissionFor(tue), 0);
        _freshRefresh(TUE_OPEN + 5 minutes);
        assertEq(gate.admissionFor(tue), TUE_OPEN + 5 minutes);
        assertEq(gate.admissionFor(_monIndex()), 0);
    }

    function test_refresh_interruptedRecoveryRestartsAdmission() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _warp(MON_OPEN + 8 minutes); // stale: the last price is three minutes old
        vm.expectEmit(address(gate));
        emit PriceGate.AdmissionReset(_monIndex(), MON_OPEN + 8 minutes, Reasons.STOCK_STALE);
        gate.refresh();
        assertEq(gate.admissionFor(_monIndex()), 0);

        _freshRefresh(MON_OPEN + 9 minutes);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 9 minutes, "new admission time, new recovery window");
    }

    function test_refresh_midSessionOutageNeedsCheckpointAndGrace() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);

        _warp(MON_OPEN + 63 minutes);
        vm.expectEmit(address(gate));
        emit PriceGate.OutageDetected(_monIndex(), MON_OPEN + 63 minutes, Reasons.STOCK_STALE);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOCK_STALE | Reasons.OUTAGE_UNRESOLVED);

        _pushAt(MON_OPEN + 64 minutes, TSLA_400);
        assertEq(gate.quote().reasons, Reasons.OUTAGE_UNRESOLVED, "a valid price alone does not end the outage");

        q = gate.refresh();
        assertEq(gate.checkpointAt(), MON_OPEN + 64 minutes);
        assertEq(q.reasons, Reasons.RECOVERY_GRACE);

        _pushAt(MON_OPEN + 69 minutes - 1, TSLA_400);
        assertEq(gate.refresh().reasons, Reasons.RECOVERY_GRACE, "five-minute grace");
        _pushAt(MON_OPEN + 69 minutes, TSLA_400);
        assertEq(gate.refresh().reasons, 0);
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 5 minutes, "a mid-session outage keeps admission");
    }

    function test_refresh_graceNeedsAQuoteNewerThanTheCheckpoint() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 86400;
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        vm.startPrank(guardian);
        g.stop();
        g.requestResume();
        vm.stopPrank();

        _pushAt(MON_OPEN + 1 days + 1 hours, TSLA_400);
        vm.prank(guardian);
        g.resume();
        _warp(block.timestamp + 10 minutes);
        assertEq(g.refresh().reasons, Reasons.RECOVERY_GRACE, "the only quote is stamped at the checkpoint");
        stockFeed.push(TSLA_400);
        assertEq(g.refresh().reasons, 0);
    }

    function test_refresh_doesNotFabricateAnUnobservedOutage() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 20 minutes);
        _freshRefresh(MON_OPEN + 40 minutes); // stale between 22 and 40 minutes, but nobody looked
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.outageSession(), 0);
        assertEq(gate.quote().reasons, 0);
    }

    function test_refresh_outageDoesNotCarryIntoTheNextSession() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_CLOSE - 10 minutes);
        _warp(MON_CLOSE - 5 minutes);
        gate.refresh();
        assertEq(gate.outageSession(), _monIndex() + 1);

        _freshRefresh(TUE_OPEN + 5 minutes);
        assertEq(gate.admissionFor(_monIndex() + 1), TUE_OPEN + 5 minutes);
        assertEq(gate.outageSession(), 0);
    }

    function test_refresh_keepsTheLastUsablePriceOnly() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        assertEq(gate.lastPriceWad(), 400e18);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 5 minutes);

        _pushAt(MON_OPEN + 6 minutes, 0);
        gate.refresh();
        assertEq(gate.lastPriceWad(), 400e18);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 5 minutes);
    }

    // ------------------------------------------------------------ guardian

    function test_guardian_onlyOwnerCanStop() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        gate.stop();
    }

    function test_guardian_stopIsImmediateAndResumeWaits24Hours() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 20 minutes);
        vm.prank(guardian);
        gate.stop();
        assertEq(gate.quote().reasons, Reasons.STOPPED);

        vm.prank(guardian);
        vm.expectRevert(PriceGate.ResumeNotRequested.selector);
        gate.resume();

        vm.prank(guardian);
        gate.requestResume();
        assertEq(gate.resumeAvailableAt(), MON_OPEN + 20 minutes + 24 hours);

        _warp(MON_OPEN + 20 minutes + 24 hours - 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(PriceGate.ResumeTooEarly.selector, MON_OPEN + 20 minutes + 24 hours));
        gate.resume();

        _pushAt(MON_OPEN + 20 minutes + 24 hours, TSLA_400);
        vm.prank(guardian);
        gate.resume();
        assertFalse(gate.stopped());
        assertEq(gate.quote().reasons, Reasons.RECOVERY_GRACE);

        _pushAt(block.timestamp + SessionTiming.RECOVERY_GRACE, TSLA_400);
        assertEq(gate.refresh().reasons, 0);
    }

    function test_guardian_stopCancelsAPendingResume() public {
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        gate.stop();
        vm.stopPrank();
        assertEq(gate.resumeAvailableAt(), 0);
    }

    function test_guardian_cannotResumeWhenRunning() public {
        vm.prank(guardian);
        vm.expectRevert(PriceGate.NotStopped.selector);
        gate.requestResume();
    }

    function test_guardian_stopDuringRecoveryResetsAdmission() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        vm.prank(guardian);
        gate.stop();
        _freshRefresh(MON_OPEN + 7 minutes);
        assertEq(gate.admissionFor(_monIndex()), 0);
    }

    function test_guardian_cannotRenounceButCanTransferInTwoSteps() public {
        vm.prank(guardian);
        vm.expectRevert(PriceGate.RenounceDisabled.selector);
        gate.renounceOwnership();

        address next = makeAddr("next guardian");
        vm.prank(guardian);
        gate.transferOwnership(next);
        assertEq(gate.owner(), guardian);
        vm.prank(next);
        gate.acceptOwnership();
        assertEq(gate.owner(), next);
    }

    // ------------------------------------------------------------ properties

    function testFuzz_valueConversionsRoundAgainstTheBorrower(uint256 raw, uint256 priceWad, uint256 value)
        public
        view
    {
        raw = bound(raw, 0, 1e30);
        priceWad = bound(priceWad, 1e12, 1e24);
        value = bound(value, 0, 1e18);
        assertLe(gate.rawForValue(gate.valueOf(raw, priceWad), priceWad, Math.Rounding.Floor), raw);
        assertGe(gate.valueOf(gate.rawForValue(value, priceWad, Math.Rounding.Ceil), priceWad), value);
    }

    function testFuzz_admissionNeedsOpenPlusFiveAndAPostOpenPrice(uint256 stampOffset, uint256 refreshOffset) public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 86400;
        PriceGate g = new PriceGate(c);
        uint256 stamp = MON_OPEN - 1 hours + bound(stampOffset, 0, 3 hours);
        uint256 at = stamp + bound(refreshOffset, 0, 2 hours);
        _pushAt(stamp, TSLA_400);
        _warp(at);
        g.refresh();

        uint64 admitted = g.admissionFor(_monIndex());
        bool expected = at >= MON_OPEN + 5 minutes && stamp >= MON_OPEN + 1 minutes && at < MON_CLOSE;
        assertEq(admitted != 0, expected);
        if (expected) assertEq(admitted, at);
    }

    // ------------------------------------------------------------ construction: required fields and chains

    /// INV-GATE-01 (mutant: dropping the zero stock answer bound check)
    function test_constructor_revertsOnEachMissingAddressOrLimit() public {
        for (uint256 i; i < 7; ++i) {
            PriceGate.Config memory c = _config();
            if (i == 0) c.token = address(0);
            if (i == 1) c.loanToken = address(0);
            if (i == 2) c.stockFeed.feed = IAggregatorV3(address(0));
            if (i == 3) c.clock = IClock(address(0));
            if (i == 4) c.calendar = SessionCalendar(address(0));
            if (i == 5) c.stockFeed.maxAge = 0;
            if (i == 6) c.stockFeed.answerBound = 0;
            vm.expectRevert(PriceGate.InvalidConfig.selector);
            new PriceGate(c);
        }
    }

    /// INV-GATE-01 (mutant: deleting the loan feed's maxAge and answerBound check)
    function test_constructor_revertsOnMissingLoanFeedLimits() public {
        ScriptedFeed loan = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 0, 2e8);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 86400, 0);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
        c.loanFeed.answerBound = 2e8;
        assertFalse(new PriceGate(c).usesPeg());
    }

    /// INV-GATE-01, INV-GATE-10: the guardian is the initial owner and can never be address(0).
    function test_constructor_revertsOnZeroGuardian() public {
        PriceGate.Config memory c = _config();
        c.guardian = address(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PriceGate(c);
    }

    /// INV-GATE-04 (mutant: changing ROBINHOOD_TESTNET_CHAIN_ID): the labelled peg deploys on Robinhood Chain
    /// testnet.
    function test_constructor_allowsTheLabelledPegOnRobinhoodTestnet() public {
        vm.chainId(46630);
        PriceGate g = new PriceGate(_config());
        assertTrue(g.usesPeg());
        assertEq(g.pegLabel(), "Test peg: 1 USDG = 1 USD");
        assertEq(g.ROBINHOOD_TESTNET_CHAIN_ID(), 46630);
        assertEq(g.LOCAL_CHAIN_ID(), 31337);
    }

    /// INV-GATE-04: the peg deploys exactly on chains 31337 and 46630; a loan feed deploys on any chain.
    function testFuzz_constructor_pegOnlyOnTheTwoTestChains(uint32 chainId, uint8 pick) public {
        chainId = uint32(bound(chainId, 1, type(uint32).max));
        if (pick % 4 == 0) chainId = 31337;
        if (pick % 4 == 1) chainId = 46630;
        vm.chainId(chainId);
        PriceGate.Config memory c = _config();
        if (chainId == 31337 || chainId == 46630) {
            assertTrue(new PriceGate(c).usesPeg());
        } else {
            vm.expectRevert(abi.encodeWithSelector(PriceGate.PegNotAllowed.selector, uint256(chainId)));
            new PriceGate(c);
        }
        ScriptedFeed loan = new ScriptedFeed(8);
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 86400, 2e8);
        assertFalse(new PriceGate(c).usesPeg());
    }

    // ------------------------------------------------------------ guardian: access

    /// INV-GATE-10: only the owner stops, requests a resume, resumes or transfers; refresh is permissionless.
    function testFuzz_guardian_onlyTheOwnerActsAndAnyoneRefreshes(address caller) public {
        vm.assume(caller != guardian);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(denied);
        gate.stop();
        vm.expectRevert(denied);
        gate.requestResume();
        vm.expectRevert(denied);
        gate.resume();
        vm.expectRevert(denied);
        gate.transferOwnership(caller);
        PriceGate.Quote memory q = gate.refresh();
        vm.stopPrank();
        assertEq(q.reasons, 0);
        assertFalse(gate.stopped());
    }

    /// INV-GATE-10: ownership moves only by transferOwnership plus acceptOwnership; a pending owner has no power,
    /// the old owner loses it on acceptance, a transfer to address(0) only cancels, and nobody can renounce.
    function test_guardian_ownershipMovesOnlyThroughTheTwoStepHandshake() public {
        address next = makeAddr("next guardian");
        address stranger = makeAddr("stranger");
        vm.prank(guardian);
        gate.transferOwnership(next);
        assertEq(gate.pendingOwner(), next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        gate.stop();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gate.acceptOwnership();

        vm.prank(guardian);
        gate.transferOwnership(address(0));
        assertEq(gate.pendingOwner(), address(0));
        assertEq(gate.owner(), guardian, "a transfer to zero only cancels the pending one");
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        gate.acceptOwnership();

        vm.prank(guardian);
        gate.transferOwnership(next);
        vm.prank(next);
        gate.acceptOwnership();
        assertEq(gate.owner(), next);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        gate.stop();
        vm.startPrank(next);
        vm.expectRevert(PriceGate.RenounceDisabled.selector);
        gate.renounceOwnership();
        gate.stop();
        vm.stopPrank();
        assertTrue(gate.stopped());
        assertEq(gate.owner(), next);
    }

    // ------------------------------------------------------------ guardian: stop

    struct GateState {
        uint32 admittedSession;
        uint64 admissionAt;
        uint32 outageSession;
        uint64 checkpointAt;
        bool stopped;
        uint64 resumeAvailableAt;
        uint256 lastPriceWad;
        uint64 lastUpdatedAt;
        uint64 lastAcceptedAt;
    }

    function _gateState(PriceGate g) internal view returns (GateState memory s) {
        s = GateState(
            g.admittedSession(),
            g.admissionAt(),
            g.outageSession(),
            g.checkpointAt(),
            g.stopped(),
            g.resumeAvailableAt(),
            g.lastPriceWad(),
            g.lastUpdatedAt(),
            g.lastAcceptedAt()
        );
    }

    function _assertSameRecords(GateState memory a, GateState memory b) internal pure {
        assertEq(a.admittedSession, b.admittedSession, "admittedSession");
        assertEq(a.admissionAt, b.admissionAt, "admissionAt");
        assertEq(a.outageSession, b.outageSession, "outageSession");
        assertEq(a.checkpointAt, b.checkpointAt, "checkpointAt");
        assertEq(a.lastPriceWad, b.lastPriceWad, "lastPriceWad");
        assertEq(a.lastUpdatedAt, b.lastUpdatedAt, "lastUpdatedAt");
        assertEq(a.lastAcceptedAt, b.lastAcceptedAt, "lastAcceptedAt");
    }

    /// @dev Monday: admitted at O + 5, last price at O + 60, outage at O + 63, recovery checkpoint at O + 64 and
    /// the outage marked again at O + 67, inside the checkpoint's grace.
    function _outageInsideAGrace() internal {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        _freshRefresh(MON_OPEN + 64 minutes);
        _warp(MON_OPEN + 67 minutes);
        gate.refresh();
        assertEq(gate.outageSession(), _monIndex() + 1);
        assertEq(gate.checkpointAt(), MON_OPEN + 64 minutes);
    }

    /// INV-GATE-11: stop sets stopped and clears a pending request; admission, outage, checkpoint and the last
    /// price stay exactly as they were.
    function test_guardian_stopTouchesOnlyTheStopFields() public {
        _outageInsideAGrace();
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        GateState memory before = _gateState(gate);
        _warp(MON_OPEN + 68 minutes);
        vm.expectEmit(address(gate));
        emit PriceGate.Stopped(MON_OPEN + 68 minutes);
        gate.stop();
        vm.stopPrank();
        GateState memory after_ = _gateState(gate);
        _assertSameRecords(before, after_);
        assertTrue(after_.stopped);
        assertEq(after_.resumeAvailableAt, 0);
        assertEq(
            gate.quote().reasons,
            Reasons.STOCK_STALE | Reasons.STOPPED | Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE
        );
    }

    /// INV-GATE-11 (mutant: refresh() not returning STOPPED): while stopped, refresh itself reports STOPPED, so a
    /// fresh print after the close is neither usable nor stored as the last price.
    function test_guardian_refreshReportsTheStopAndFreezesTheLastPriceWhileClosed() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 20 minutes);
        vm.prank(guardian);
        gate.stop();
        _pushAt(MON_CLOSE + 1 hours, TSLA_400 / 2);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOPPED);
        assertEq(q.priceWad, 200e18);
        assertEq(gate.lastPriceWad(), 400e18);
        assertEq(gate.lastUpdatedAt(), MON_OPEN + 20 minutes);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 20 minutes);
        assertEq(gate.quote().reasons, Reasons.STOPPED);
    }

    /// INV-GATE-11: a stopped gate admits no session and records no checkpoint, however good the source.
    function test_guardian_aStoppedGateAdmitsNothingAndAcceptsNoPrice() public {
        _warp(MON_OPEN - 1 hours);
        vm.prank(guardian);
        gate.stop();
        for (uint256 m = 5; m <= 60; m += 5) {
            assertEq(_freshRefresh(MON_OPEN + m * 1 minutes).reasons, Reasons.STOPPED);
        }
        assertEq(gate.admittedSession(), 0);
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.lastAcceptedAt(), 0);
    }

    /// INV-GATE-11, INV-GATE-41: a stop keeps a recorded outage open: a valid source no longer clears it.
    function test_guardian_aStopHoldsAnOutageOpen() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        vm.prank(guardian);
        gate.stop();
        PriceGate.Quote memory q = _freshRefresh(MON_OPEN + 64 minutes);
        assertEq(q.reasons, Reasons.STOPPED | Reasons.OUTAGE_UNRESOLVED);
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.outageSession(), _monIndex() + 1);
    }

    /// INV-GATE-39, INV-GATE-16: after creditAt a stop is recorded as an outage; the event carries STOPPED, never
    /// the gate-state bits.
    function test_guardian_aStopAfterCreditAtIsRecordedAsAnOutage() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 20 minutes);
        vm.prank(guardian);
        gate.stop();
        _pushAt(MON_OPEN + 21 minutes, TSLA_400);
        vm.expectEmit(address(gate));
        emit PriceGate.OutageDetected(_monIndex(), MON_OPEN + 21 minutes, Reasons.STOPPED);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOPPED | Reasons.OUTAGE_UNRESOLVED);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 5 minutes);
    }

    /// INV-X-11 (gate side): a stop with no resume holds across sessions; every refresh carries STOPPED and no
    /// session is admitted.
    function test_guardian_aStopWithoutResumeHoldsAcrossSessions() public {
        _warp(MON_OPEN - 1 hours);
        vm.prank(guardian);
        gate.stop();
        uint64 open = MON_OPEN;
        for (uint256 i; i < 6; ++i) {
            assertEq(_freshRefresh(open + 10 minutes).reasons, Reasons.STOPPED);
            assertEq(_freshRefresh(open + 3 hours).reasons, Reasons.STOPPED);
            assertEq(gate.admittedSession(), 0);
            open = cal.context(open).nextOpen;
        }
    }

    // ------------------------------------------------------------ guardian: resume

    /// INV-GATE-12: requestResume sets now + 24 h and a second request restarts the delay.
    function test_guardian_requestResumeRestartsTheDelay() public {
        _warp(MON_OPEN);
        vm.startPrank(guardian);
        gate.stop();
        vm.expectEmit(address(gate));
        emit PriceGate.ResumeRequested(MON_OPEN, MON_OPEN + 1 days);
        gate.requestResume();
        _warp(MON_OPEN + 6 hours);
        gate.requestResume();
        assertEq(gate.resumeAvailableAt(), MON_OPEN + 6 hours + 1 days);
        _warp(MON_OPEN + 1 days);
        vm.expectRevert(abi.encodeWithSelector(PriceGate.ResumeTooEarly.selector, MON_OPEN + 6 hours + 1 days));
        gate.resume();
        _warp(MON_OPEN + 6 hours + 1 days);
        gate.resume();
        vm.stopPrank();
        assertFalse(gate.stopped());
    }

    /// INV-GATE-12 (mutant: deleting the NotStopped check in resume): resume and requestResume on a running gate
    /// revert NotStopped, before and after a completed stop cycle.
    function test_guardian_resumeOnARunningGateRevertsNotStopped() public {
        vm.startPrank(guardian);
        vm.expectRevert(PriceGate.NotStopped.selector);
        gate.resume();
        gate.stop();
        gate.requestResume();
        _warp(block.timestamp + 1 days);
        gate.resume();
        vm.expectRevert(PriceGate.NotStopped.selector);
        gate.resume();
        vm.expectRevert(PriceGate.NotStopped.selector);
        gate.requestResume();
        vm.stopPrank();
    }

    /// INV-GATE-12, INV-GATE-41, INV-GATE-51: resume clears the stop, the request and a recorded outage, sets the
    /// checkpoint to now and emits Resumed then RecoveryCheckpoint; admission is untouched.
    function test_guardian_resumeClearsTheStopTheRequestAndTheOutage() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();
        uint64 at = MON_OPEN + 63 minutes + 1 days;
        _warp(at);
        assertEq(gate.outageSession(), _monIndex() + 1, "nobody refreshed since");
        vm.expectEmit(address(gate));
        emit PriceGate.Resumed(at);
        vm.expectEmit(address(gate));
        emit PriceGate.RecoveryCheckpoint(at);
        vm.prank(guardian);
        gate.resume();
        assertFalse(gate.stopped());
        assertEq(gate.resumeAvailableAt(), 0);
        assertEq(gate.outageSession(), 0);
        assertEq(gate.checkpointAt(), at);
        assertEq(gate.admissionFor(_monIndex()), MON_OPEN + 5 minutes, "resume does not touch admission");
    }

    /// INV-GATE-12, INV-GATE-41 (mutant: deleting `outageSession = 0` in resume). Observable only when a session
    /// outlasts the 24-hour delay (no shipped session does, INV-X-12), so this calendar has a 30-hour session:
    /// a resume inside the stopped session leaves one five-minute grace, not an outage plus a second grace.
    function test_guardian_resumeClearsAnOutageOfTheSameSession() public {
        uint64 o = MON_OPEN;
        uint256[] memory words = new uint256[](1);
        words[0] =
            ((uint256(o) << 32) | uint256(o + 30 hours)) | (((uint256(o + 48 hours) << 32) | (o + 54 hours)) << 64);
        PriceGate.Config memory c = _config();
        c.calendar = new SessionCalendar(words, 2);
        PriceGate g = new PriceGate(c);

        _pushAt(o + 5 minutes, TSLA_400);
        g.refresh();
        _pushAt(o + 20 minutes, TSLA_400);
        vm.startPrank(guardian);
        g.stop();
        g.requestResume();
        vm.stopPrank();
        _pushAt(o + 30 minutes, TSLA_400);
        g.refresh();
        assertEq(g.outageSession(), 1, "the stop after creditAt is an outage of session 0");

        _pushAt(o + 24 hours + 20 minutes, TSLA_400);
        vm.prank(guardian);
        g.resume();
        assertEq(g.outageSession(), 0);
        assertEq(g.quote().reasons, Reasons.RECOVERY_GRACE);
        _pushAt(o + 24 hours + 25 minutes, TSLA_400);
        assertEq(g.refresh().reasons, 0, "one grace, no outage left to clear");
    }

    /// INV-GATE-13, INV-GATE-12: whatever the order of stops and requests, resume succeeds exactly from 24 h after
    /// the latest request, which is never earlier than 24 h after the latest stop.
    function testFuzz_guardian_resumeComesAtLeast24HoursAfterTheLastStopAndRequest(
        uint256 toRequest,
        uint256 again,
        uint256 restop,
        uint256 toAttempt
    ) public {
        uint256 t = MON_OPEN;
        _warp(t);
        vm.startPrank(guardian);
        gate.stop();
        uint256 lastStop = t;
        t += bound(toRequest, 0, 2 days);
        _warp(t);
        gate.requestResume();
        uint256 lastRequest = t;
        if (again % 3 == 0) {
            t += bound(again, 0, 1 days);
            _warp(t);
            gate.requestResume();
            lastRequest = t;
        }
        if (restop % 4 == 0) {
            t += bound(restop, 0, 1 days);
            _warp(t);
            gate.stop();
            assertEq(gate.resumeAvailableAt(), 0, "a stop cancels the request");
            lastStop = t;
            gate.requestResume();
            lastRequest = t;
        }
        t += bound(toAttempt, 0, 2 days);
        _warp(t);
        if (t < lastRequest + 1 days) {
            vm.expectRevert(abi.encodeWithSelector(PriceGate.ResumeTooEarly.selector, lastRequest + 1 days));
            gate.resume();
            assertTrue(gate.stopped());
        } else {
            gate.resume();
            assertGe(t, lastStop + 1 days);
            assertGe(t, lastRequest + 1 days);
            assertEq(gate.checkpointAt(), t);
        }
        vm.stopPrank();
    }

    /// INV-X-12, INV-GATE-35: every shipped session is shorter than the 24-hour resume delay, so a resume lands
    /// in a later session than its stop, and new credit there needs that session's own admission after the
    /// resume grace.
    function test_resume_newCreditNeedsAFreshAdmission() public {
        (uint256[] memory opens, uint256[] memory closes) = _jsonSessions();
        for (uint256 i; i < opens.length; ++i) {
            assertLt(closes[i] - opens[i], SessionTiming.RESUME_DELAY, "session shorter than the resume delay");
        }
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 20 minutes);
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();
        uint64 at = MON_OPEN + 20 minutes + 1 days; // Tuesday, 20 minutes after the open
        _pushAt(at, TSLA_400);
        vm.prank(guardian);
        gate.resume();
        uint256 tue = _monIndex() + 1;
        assertEq(gate.admissionFor(tue), 0);
        assertEq(_freshRefresh(at + 1 minutes).reasons, Reasons.RECOVERY_GRACE);
        assertEq(gate.admissionFor(tue), 0, "no admission inside the resume grace");
        assertEq(_freshRefresh(at + 5 minutes).reasons, 0);
        assertEq(gate.admissionFor(tue), at + 5 minutes, "the first usable refresh admits Tuesday");
        assertEq(gate.admissionFor(_monIndex()), 0);
    }

    // ------------------------------------------------------------ admission boundaries

    /// INV-GATE-35 (mutant: `>=` to `>` on O + FRESH_AFTER): a stock round stamped exactly at O + 1 minute is
    /// fresh enough for admission.
    function test_refresh_admitsAPriceStampedExactlyAtOpenPlusOneMinute() public {
        PriceGate.Config memory c = _config();
        c.stockFeed.maxAge = 86400;
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 minutes, TSLA_400);
        _warp(MON_OPEN + 5 minutes);
        g.refresh();
        assertEq(g.admissionFor(_monIndex()), MON_OPEN + 5 minutes);
    }

    /// INV-GATE-35, INV-GATE-36 (mutant: admitting without calendar coverage): the last calendar session has no
    /// known next open, so refreshes in it admit nothing and record no outage, and none after it either.
    function test_refresh_neverAdmitsInTheUncoveredLastSession() public {
        uint256 last = cal.sessionCount() - 1;
        (uint64 o, uint64 c) = cal.sessionAt(last);
        assertFalse(cal.context(o + 10 minutes).covered);
        assertTrue(cal.context(o + 10 minutes).inSession);
        for (uint64 m = 5; m < 60; m += 5) {
            assertEq(_freshRefresh(o + m * 1 minutes).reasons, 0);
        }
        _warp(o + 2 hours);
        gate.refresh();
        assertEq(gate.admittedSession(), 0);
        assertEq(gate.admissionFor(last), 0);
        assertEq(gate.outageSession(), 0);
        _freshRefresh(c + 1 hours);
        assertEq(gate.admittedSession(), 0);
    }

    /// INV-GATE-35, INV-GATE-43 (mutant: dropping `checkpointAt == 0` from admission): a guardian resume at the
    /// start of a session holds admission back until its grace has ended.
    function test_refresh_noAdmissionWhileAResumeCheckpointIsPending() public {
        _freshRefresh(MON_OPEN + 2 minutes);
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();
        _pushAt(TUE_OPEN + 2 minutes, TSLA_400);
        vm.prank(guardian);
        gate.resume();
        assertEq(_freshRefresh(TUE_OPEN + 6 minutes).reasons, Reasons.RECOVERY_GRACE);
        assertEq(gate.admissionFor(_monIndex() + 1), 0, "still in the resume grace");
        _freshRefresh(TUE_OPEN + 7 minutes);
        assertEq(gate.admissionFor(_monIndex() + 1), TUE_OPEN + 7 minutes);
    }

    /// INV-GATE-38, INV-GATE-39 (mutant: `t < creditAt` to `t <= creditAt`): creditAt is the exact boundary.
    /// A failure one second before it resets the admission; a failure at it keeps the admission and records an
    /// outage. Admission at O + 5 gives creditAt = O + 15; admission at O + 12 gives creditAt = O + 22.
    function test_refresh_creditAtIsTheExactBoundaryBetweenResetAndOutage() public {
        uint256 start = vm.snapshotState();
        uint64[2] memory admitAt = [MON_OPEN + 5 minutes, MON_OPEN + 12 minutes];
        uint64[2] memory credit = [MON_OPEN + 15 minutes, MON_OPEN + 22 minutes];
        for (uint256 i; i < 2; ++i) {
            vm.revertToState(start);
            _freshRefresh(admitAt[i]);
            uint256 admitted = vm.snapshotState();
            _pushAt(credit[i] - 1, 0);
            vm.expectEmit(address(gate));
            emit PriceGate.AdmissionReset(_monIndex(), credit[i] - 1, Reasons.STOCK_BAD_ANSWER);
            gate.refresh();
            assertEq(gate.admittedSession(), 0, "one second before creditAt: interrupted recovery");
            assertEq(gate.admissionAt(), 0);
            assertEq(gate.outageSession(), 0);
            vm.revertToState(admitted);
            _pushAt(credit[i], 0);
            vm.expectEmit(address(gate));
            emit PriceGate.OutageDetected(_monIndex(), credit[i], Reasons.STOCK_BAD_ANSWER);
            gate.refresh();
            assertEq(gate.admissionFor(_monIndex()), admitAt[i], "at creditAt: admission kept");
            assertEq(gate.outageSession(), _monIndex() + 1, "and the outage recorded");
        }
    }

    // ------------------------------------------------------------ outages, checkpoints and events

    function _countLogs(bytes32 topic) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(gate) && logs[i].topics[0] == topic) ++n;
        }
    }

    /// INV-GATE-39, INV-GATE-51 (mutant: re-emitting OutageDetected on every failing refresh): one outage, one
    /// event, however many refreshes see it.
    function test_refresh_outageDetectedOncePerOutage() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        vm.recordLogs();
        for (uint256 m = 63; m < 70; ++m) {
            _warp(MON_OPEN + m * 1 minutes);
            assertEq(gate.refresh().reasons, Reasons.STOCK_STALE | Reasons.OUTAGE_UNRESOLVED);
        }
        assertEq(_countLogs(PriceGate.OutageDetected.selector), 1);
    }

    /// INV-GATE-16, INV-GATE-42, INV-GATE-43: an outage inside a pending grace keeps the checkpoint, its event
    /// carries only source bits, and the next recovery records a newer checkpoint, which only extends the grace.
    function test_refresh_anOutageInsideTheGraceExtendsIt() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        _freshRefresh(MON_OPEN + 64 minutes);
        _warp(MON_OPEN + 67 minutes);
        vm.expectEmit(address(gate));
        emit PriceGate.OutageDetected(_monIndex(), MON_OPEN + 67 minutes, Reasons.STOCK_STALE);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOCK_STALE | Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE);
        assertEq(gate.checkpointAt(), MON_OPEN + 64 minutes, "a pending checkpoint is kept");

        _pushAt(MON_OPEN + 68 minutes, TSLA_400);
        vm.expectEmit(address(gate));
        emit PriceGate.RecoveryCheckpoint(MON_OPEN + 68 minutes);
        assertEq(gate.refresh().reasons, Reasons.RECOVERY_GRACE);
        assertEq(gate.checkpointAt(), MON_OPEN + 68 minutes);
        assertEq(_freshRefresh(MON_OPEN + 73 minutes - 1).reasons, Reasons.RECOVERY_GRACE, "grace from the newer one");
        assertEq(_freshRefresh(MON_OPEN + 73 minutes).reasons, 0);
    }

    /// INV-GATE-44, INV-GATE-43: an ended grace is cleared even by an invalid quote; the same refresh records
    /// the outage again, so the next recovery still needs a checkpoint and a full grace.
    function test_refresh_anEndedGraceClearsOnAnInvalidQuoteAndTheOutageReturns() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        _freshRefresh(MON_OPEN + 64 minutes);
        _pushAt(MON_OPEN + 70 minutes, TSLA_400);
        tsla.setOraclePaused(true);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.outageSession(), _monIndex() + 1);
        assertEq(q.reasons, Reasons.ISSUER_PAUSED | Reasons.OUTAGE_UNRESOLVED);
        tsla.setOraclePaused(false);
        assertEq(gate.refresh().reasons, Reasons.RECOVERY_GRACE);
        assertEq(gate.checkpointAt(), MON_OPEN + 70 minutes);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 60 minutes, "nothing accepted since the outage");
    }

    /// INV-GATE-44, INV-GATE-35: a future-stamped round ends a resume grace without making anything usable;
    /// while the stamp is ahead of the clock there is no usable quote and no admission.
    function test_refresh_aFutureStampEndsTheGraceButAdmitsNothing() public {
        _warp(MON_OPEN + 2 minutes - 1 days);
        vm.startPrank(guardian);
        gate.stop();
        gate.requestResume();
        vm.stopPrank();
        _warp(MON_OPEN + 2 minutes);
        vm.prank(guardian);
        gate.resume();
        _warp(MON_OPEN + 7 minutes);
        stockFeed.pushAt(TSLA_400, uint64(block.timestamp + 30));
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOCK_FUTURE_TIMESTAMP);
        assertEq(gate.checkpointAt(), 0);
        _warp(block.timestamp + 29);
        assertEq(gate.refresh().reasons, Reasons.STOCK_FUTURE_TIMESTAMP);
        assertEq(gate.admittedSession(), 0);
        assertEq(gate.lastAcceptedAt(), 0);
    }

    /// INV-GATE-41 (mutant: quote() reading an outage of any session): before anyone refreshes the next
    /// session, the view already ignores the previous session's outage.
    function test_quote_ignoresAPriorSessionOutageBeforeAnyRefresh() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_CLOSE - 10 minutes);
        _warp(MON_CLOSE - 5 minutes);
        gate.refresh();
        assertEq(gate.outageSession(), _monIndex() + 1);
        _pushAt(TUE_OPEN + 5 minutes, TSLA_400);
        assertEq(gate.quote().reasons, 0, "the view must not carry Monday's outage");
        assertEq(gate.outageSession(), _monIndex() + 1, "still stored until a refresh");
    }

    /// INV-GATE-41, INV-GATE-34: an outage persists through the closed period (the calendar index stays on the
    /// closed session) and lapses at the next open without a checkpoint.
    function test_refresh_outagePersistsThroughTheCloseAndLapsesAtTheNextOpen() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_CLOSE - 10 minutes);
        _warp(MON_CLOSE - 5 minutes);
        gate.refresh();
        assertEq(_freshRefresh(MON_CLOSE + 1 hours).reasons, Reasons.OUTAGE_UNRESOLVED);
        assertEq(_freshRefresh(TUE_OPEN - 1 minutes).reasons, Reasons.OUTAGE_UNRESOLVED);
        assertEq(gate.outageSession(), _monIndex() + 1);
        assertEq(gate.lastAcceptedAt(), MON_CLOSE - 10 minutes);

        assertEq(_freshRefresh(TUE_OPEN + 1 minutes).reasons, 0);
        assertEq(gate.outageSession(), 0);
        assertEq(gate.checkpointAt(), 0);
        assertEq(gate.lastAcceptedAt(), TUE_OPEN + 1 minutes);
    }

    /// INV-GATE-46 (mutant: storing the last price when only the source is valid): while an outage or a
    /// recovery grace holds, a valid source neither becomes usable nor replaces the last price.
    function test_refresh_noLastPriceDuringAnOutageOrAGrace() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        gate.refresh();
        _pushAt(MON_OPEN + 64 minutes, TSLA_400 * 2);
        assertEq(gate.quote().reasons, Reasons.OUTAGE_UNRESOLVED);
        assertEq(gate.refresh().reasons, Reasons.RECOVERY_GRACE);
        for (uint256 m = 65; m < 69; ++m) {
            _pushAt(MON_OPEN + m * 1 minutes, TSLA_400 * 2);
            assertEq(gate.refresh().reasons, Reasons.RECOVERY_GRACE);
        }
        assertEq(gate.lastPriceWad(), 400e18);
        assertEq(gate.lastUpdatedAt(), MON_OPEN + 60 minutes);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 60 minutes);
        _pushAt(MON_OPEN + 69 minutes, TSLA_400 * 2);
        assertEq(gate.refresh().reasons, 0);
        assertEq(gate.lastPriceWad(), 800e18);
    }

    /// INV-GATE-46 (mutant: deleting `lastUpdatedAt = q.updatedAt`): the three last-price fields are written
    /// together, with the feed's stamp and the refresh's clock time.
    function test_refresh_recordsTheFeedStampAndTheClockTimeOfTheLastPrice() public {
        _pushAt(MON_OPEN + 4 minutes, TSLA_400);
        _warp(MON_OPEN + 5 minutes);
        gate.refresh();
        assertEq(gate.lastPriceWad(), 400e18);
        assertEq(gate.lastUpdatedAt(), MON_OPEN + 4 minutes);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 5 minutes);
        _pushAt(MON_OPEN + 6 minutes, TSLA_400 + 1e8);
        _warp(MON_OPEN + 7 minutes);
        gate.refresh();
        assertEq(gate.lastPriceWad(), 401e18);
        assertEq(gate.lastUpdatedAt(), MON_OPEN + 6 minutes);
        assertEq(gate.lastAcceptedAt(), MON_OPEN + 7 minutes);
    }

    /// INV-GATE-37: only the latest admission is live; earlier sessions read zero, and the index + 1 in
    /// admissionFor panics for type(uint256).max.
    function test_admissionFor_onlyTheLatestAdmissionIsLive() public {
        uint256 mon = _monIndex();
        _freshRefresh(MON_OPEN + 5 minutes);
        assertEq(gate.admissionFor(mon), MON_OPEN + 5 minutes);
        assertEq(gate.admissionFor(mon - 1), 0);
        assertEq(gate.admissionFor(mon + 1), 0);
        _freshRefresh(TUE_OPEN + 6 minutes);
        assertEq(gate.admissionFor(mon + 1), TUE_OPEN + 6 minutes);
        assertEq(gate.admissionFor(mon), 0, "Monday's admission is no longer readable");
        vm.expectRevert(stdError.arithmeticError);
        gate.admissionFor(type(uint256).max);
    }

    /// INV-GATE-37: admissionFor(i) is non-zero exactly for i + 1 == admittedSession.
    function testFuzz_admissionFor_matchesTheAdmittedSession(uint256 index) public {
        index = bound(index, 0, type(uint256).max - 1);
        _freshRefresh(MON_OPEN + 5 minutes);
        uint64 a = gate.admissionFor(index);
        assertEq(a != 0, index + 1 == gate.admittedSession());
        if (a != 0) assertEq(a, gate.admissionAt());
    }

    /// INV-GATE-40: refresh records only what a successful transaction observed; a caller that reverts after
    /// refreshing leaves no outage, and a standalone refresh then records it.
    function test_refresh_aRevertingCallerLeavesNoRecord() public {
        _freshRefresh(MON_OPEN + 5 minutes);
        _freshRefresh(MON_OPEN + 60 minutes);
        _warp(MON_OPEN + 63 minutes);
        GateRevertingCaller caller = new GateRevertingCaller();
        vm.expectRevert(GateRevertingCaller.CallerFailed.selector);
        caller.refreshThenRevert(gate);
        assertEq(gate.outageSession(), 0);
        gate.refresh();
        assertEq(gate.outageSession(), _monIndex() + 1);
    }

    /// INV-GATE-33, INV-GATE-32, INV-GATE-34: along random paths (prints, pauses, stops, resumes, day jumps),
    /// the view agrees with refresh on usability, a second refresh at the same time changes nothing and returns
    /// the same quote, the view then returns that quote, and the outage and grace bits mirror storage.
    function testFuzz_refresh_isIdempotentAndMatchesTheView(uint256 seed) public {
        _warp(MON_OPEN - 10 minutes);
        for (uint256 i; i < 30; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if ((seed >> 200) % 12 == 0) {
                uint256 target = cal.context(uint64(block.timestamp)).nextOpen - 5 minutes + (seed >> 210) % 40 minutes;
                _warp(target > block.timestamp ? target : block.timestamp + 1 minutes);
            } else {
                _warp(block.timestamp + 20 + seed % 9 minutes);
            }
            uint256 kind = (seed >> 32) % 10;
            if (kind < 6) {
                stockFeed.push(TSLA_400 + int256((seed >> 64) % 100) * 1e8);
            } else if (kind == 6) {
                tsla.setOraclePaused((seed >> 72) % 3 == 0);
            } else if (kind == 7) {
                vm.prank(guardian);
                gate.stop();
            } else if (kind == 8 && gate.stopped()) {
                vm.prank(guardian);
                gate.requestResume();
            } else if (gate.stopped() && gate.resumeAvailableAt() != 0 && block.timestamp >= gate.resumeAvailableAt()) {
                vm.prank(guardian);
                gate.resume();
            }
            if ((seed >> 80) % 5 == 0) continue; // nobody observes this step

            PriceGate.Quote memory before = gate.quote();
            PriceGate.Quote memory first = gate.refresh();
            assertEq(before.reasons == 0, first.reasons == 0, "view and refresh agree on usability");
            GateState memory s1 = _gateState(gate);
            PriceGate.Quote memory second = gate.refresh();
            GateState memory s2 = _gateState(gate);
            PriceGate.Quote memory after_ = gate.quote();
            _assertSameRecords(s1, s2);
            assertEq(abi.encode(first), abi.encode(second), "a second refresh returns the same quote");
            assertEq(abi.encode(second), abi.encode(after_), "the view right after a refresh returns it too");
            uint32 sid = uint32(cal.context(uint64(block.timestamp)).index + 1);
            assertTrue(s2.outageSession == 0 || s2.outageSession == sid, "outage only for the current session");
            assertEq(first.reasons & Reasons.OUTAGE_UNRESOLVED != 0, s2.outageSession != 0, "outage bit");
            assertEq(first.reasons & Reasons.RECOVERY_GRACE != 0, s2.checkpointAt != 0, "grace bit");
        }
    }

    // ------------------------------------------------------------ storage footprint and static reads

    uint256 internal constant SLOT_ADMITTED = 0xffffffff;
    uint256 internal constant SLOT_ADMISSION_AT = uint256(type(uint64).max) << 32;
    uint256 internal constant SLOT_OUTAGE = uint256(type(uint32).max) << 96;
    uint256 internal constant SLOT_CHECKPOINT = uint256(type(uint64).max) << 128;
    uint256 internal constant SLOT_STOPPED = uint256(0xff) << 192;

    /// @dev Asserts that the recorded accesses wrote only gate slots in `slots` (bit i allows slot i) and that
    /// changes to the packed slot 3 stay inside `slot3Fields`. Returns the number of slot writes.
    function _assertWrites(Vm.AccountAccess[] memory acc, uint256 slots, uint256 slot3Fields)
        internal
        view
        returns (uint256 writes)
    {
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = acc[i].storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                writes++;
                assertEq(s.account, address(gate), "only gate storage is written");
                uint256 slot = uint256(s.slot);
                assertTrue(slot < 7 && (slots >> slot) & 1 == 1, "slot outside the entry point's fields");
                if (slot == 3) {
                    uint256 changed = uint256(s.previousValue) ^ uint256(s.newValue);
                    assertEq(changed & ~slot3Fields, 0, "packed field outside the entry point's fields");
                }
            }
        }
    }

    /// INV-GATE-05, INV-GATE-15, INV-X-07: storage slots are 0 owner, 1 pending owner, 2 peg label, 3 admission,
    /// outage, checkpoint and stopped, 4 resumeAvailableAt, 5 lastPriceWad, 6 lastUpdatedAt and lastAcceptedAt.
    /// refresh writes only 3 (never `stopped`), 5 and 6; stop only `stopped` and 4; requestResume only 4; resume
    /// only outage, checkpoint, `stopped` and 4; quote nothing; the owner fields move only by the handshake.
    /// Everything else is immutable, so the guardian has no lever on prices, limits or records beyond these.
    function test_storage_eachEntryPointWritesOnlyItsOwnFields() public {
        uint256 refreshFields = SLOT_ADMITTED | SLOT_ADMISSION_AT | SLOT_OUTAGE | SLOT_CHECKPOINT;
        uint256 refreshSlots = (1 << 3) | (1 << 5) | (1 << 6);
        uint256 total;

        // admission, outage, checkpoint and acceptance transitions through refresh
        uint64[6] memory at = [
            MON_OPEN + 5 minutes,
            MON_OPEN + 60 minutes,
            MON_OPEN + 63 minutes,
            MON_OPEN + 64 minutes,
            MON_OPEN + 69 minutes,
            TUE_OPEN + 1 minutes
        ];
        for (uint256 i; i < at.length; ++i) {
            if (i == 2) _warp(at[i]);
            else _pushAt(at[i], TSLA_400);
            vm.startStateDiffRecording();
            gate.refresh();
            gate.quote();
            total += _assertWrites(vm.stopAndReturnStateDiff(), refreshSlots, refreshFields);
        }
        _freshRefresh(TUE_OPEN + 5 minutes);
        _freshRefresh(TUE_OPEN + 20 minutes);

        vm.prank(guardian);
        vm.startStateDiffRecording();
        gate.stop();
        total += _assertWrites(vm.stopAndReturnStateDiff(), (1 << 3) | (1 << 4), SLOT_STOPPED);

        _pushAt(TUE_OPEN + 25 minutes, TSLA_400);
        vm.startStateDiffRecording();
        gate.refresh(); // the stop after creditAt is recorded as an outage
        total += _assertWrites(vm.stopAndReturnStateDiff(), refreshSlots, refreshFields);
        assertEq(gate.outageSession(), _monIndex() + 2);

        vm.prank(guardian);
        vm.startStateDiffRecording();
        gate.requestResume();
        total += _assertWrites(vm.stopAndReturnStateDiff(), 1 << 4, 0);

        _warp(TUE_OPEN + 25 minutes + 1 days);
        vm.prank(guardian);
        vm.startStateDiffRecording();
        gate.resume();
        total += _assertWrites(
            vm.stopAndReturnStateDiff(), (1 << 3) | (1 << 4), SLOT_OUTAGE | SLOT_CHECKPOINT | SLOT_STOPPED
        );

        address next = makeAddr("next guardian");
        vm.prank(guardian);
        vm.startStateDiffRecording();
        gate.transferOwnership(next);
        total += _assertWrites(vm.stopAndReturnStateDiff(), 1 << 1, 0);
        vm.prank(next);
        vm.startStateDiffRecording();
        gate.acceptOwnership();
        total += _assertWrites(vm.stopAndReturnStateDiff(), (1 << 0) | (1 << 1), 0);
        assertGt(total, 12, "the scenario writes");
    }

    /// INV-X-09 (gate side): every call the gate makes, to the feeds, the token, the sequencer feed, the clock or
    /// the calendar, is a STATICCALL, in refresh, quote and the guardian functions alike.
    function test_sources_areReadOnlyThroughStaticCalls() public {
        ScriptedFeed loan = new ScriptedFeed(8);
        ScriptedFeed seq = new ScriptedFeed(0);
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, 3600, 2e8);
        c.sequencerFeed = IAggregatorV3(address(seq));
        c.sequencerGrace = 600;
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 5 minutes, TSLA_400);
        loan.set(1e8, block.timestamp, block.timestamp);
        seq.set(0, block.timestamp - 1 days, block.timestamp);

        vm.startStateDiffRecording();
        g.refresh();
        g.quote();
        vm.startPrank(guardian);
        g.stop();
        g.requestResume();
        vm.stopPrank();
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 calls;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].accessor != address(g) || uint256(acc[i].kind) > uint256(VmSafe.AccountAccessKind.StaticCall)) {
                continue;
            }
            calls++;
            assertEq(uint256(acc[i].kind), uint256(VmSafe.AccountAccessKind.StaticCall), "static read");
        }
        // refresh: clock, stock round and decimals, loan round and decimals, pause flag, effectiveAt, sequencer,
        // calendar (9); quote: the same without the calendar, as no outage is recorded (8); stop and
        // requestResume: the clock (2).
        assertEq(calls, 19, "every source, the clock and the calendar were read");
    }
}

/// @notice Refreshes the gate and then reverts, like a price-dependent entry point that fails afterwards.
contract GateRevertingCaller {
    error CallerFailed();

    function refreshThenRevert(PriceGate g) external {
        g.refresh();
        revert CallerFailed();
    }
}

/// @notice The policy, market, escrow and Lens take their calendar, clock, gate and scale from one gate, and
/// nothing the gate does writes their state.
contract PriceGateWiringTest is MarketFixture {
    function setUp() public {
        _setUpMarket();
    }

    /// INV-X-01: one calendar, gate, clock, token pair and VALUE_SCALE across policy, market, escrow and Lens.
    function test_wiring_everyContractDerivesFromTheGate() public {
        StockReefLens lens = new StockReefLens(market);
        assertEq(address(policy.gate()), address(gate));
        assertEq(address(policy.calendar()), address(gate.calendar()));
        assertEq(address(policy.clock()), address(gate.clock()));
        assertEq(address(market.gate()), address(gate));
        assertEq(address(market.policy()), address(policy));
        assertEq(address(market.clock()), address(gate.clock()));
        assertEq(market.asset(), gate.loanToken());
        assertEq(address(market.collateralToken()), address(gate.token()));
        assertEq(market.VALUE_SCALE(), gate.VALUE_SCALE());
        assertEq(address(escrow.market()), address(market));
        assertEq(address(escrow.gate()), address(gate));
        assertEq(address(escrow.policy()), address(policy));
        assertEq(address(escrow.clock()), address(gate.clock()));
        assertEq(address(escrow.loanToken()), gate.loanToken());
        assertEq(address(lens.gate()), address(gate));
        assertEq(address(lens.calendar()), address(gate.calendar()));
        assertEq(address(lens.escrow()), address(escrow));
        assertEq(address(lens.policy()), address(policy));
    }

    /// INV-X-01: a market for tokens the gate does not price reverts ConfigMismatch.
    function test_wiring_marketRejectsTokensTheGateDoesNotPrice() public {
        IERC20 loan = IERC20(address(usdg));
        IERC20 coll = IERC20(address(tsla));
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(coll, loan, policy, MIN_LOAN, "x", "x");
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(loan, loan, policy, MIN_LOAN, "x", "x");
        vm.expectRevert(StockReefMarket.ConfigMismatch.selector);
        new StockReefMarket(coll, coll, policy, MIN_LOAN, "x", "x");
    }

    /// INV-X-21: refreshes and policy evaluations across a session never write market, escrow or policy
    /// storage; positions, cash and escrow balances are unchanged by them.
    function test_refreshAndPolicy_neverWriteMarketOrEscrowState() public {
        _openFriday();
        _lend(100_000 * USDG);
        _workedExample(alice);
        (, uint256 shares,) = market.accountOf(alice);
        uint256 totalShares = market.totalDebtShares();
        uint256 cash = market.cash();
        uint64[5] memory at = [
            FRI_OPEN + 1 hours,
            FRI_CLOSE - 90 minutes,
            FRI_CLOSE - 10 minutes,
            FRI_CLOSE + 1 hours,
            MON_OPEN + 3 minutes
        ];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            stockFeed.push(i % 2 == 0 ? TSLA_400 : TSLA_400 / 2);
            if (i == 3) {
                vm.prank(guardian);
                gate.stop();
            }
            vm.startStateDiffRecording();
            gate.refresh();
            policy.snapshot();
            policy.evaluate(gate.quote(), uint64(block.timestamp));
            Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
            for (uint256 k; k < acc.length; ++k) {
                for (uint256 j; j < acc[k].storageAccesses.length; ++j) {
                    Vm.StorageAccess memory s = acc[k].storageAccesses[j];
                    if (s.isWrite) assertEq(s.account, address(gate), "only gate storage is written");
                }
            }
        }
        (, uint256 sharesAfter,) = market.accountOf(alice);
        assertEq(sharesAfter, shares, "debt shares");
        assertEq(market.totalDebtShares(), totalShares);
        assertEq(market.cash(), cash);
        assertEq(market.collateralOf(alice), 25 * TOKEN);
    }
}
