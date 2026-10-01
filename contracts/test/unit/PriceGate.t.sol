// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {ScriptedFeed, PlainToken} from "../utils/ScriptedFeed.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
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
}
