// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GateFixture} from "../utils/GateFixture.sol";
import {ScriptedFeed} from "../utils/ScriptedFeed.sol";
import {PriceGate} from "../../src/PriceGate.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IClock} from "../../src/interfaces/IClock.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {SessionTiming} from "../../src/libraries/SessionTiming.sol";

/// @notice Ways a scripted price-source call can fail. NONE returns normally; every other mode reverts.
library GateArithFail {
    uint8 internal constant NONE = 0;
    uint8 internal constant EMPTY = 1; // revert() without data
    uint8 internal constant STRING = 2; // Error(string)
    uint8 internal constant CUSTOM = 3; // custom error
    uint8 internal constant ASSERT = 4; // Panic(0x01)
    uint8 internal constant DIVISION = 5; // Panic(0x12)
    uint8 internal constant MODES = 6;

    error GateArithSourceDown();

    /// @dev `zero` is a storage zero, so the division panic is not folded away at compile time.
    function check(uint8 mode, uint256 zero) internal pure {
        if (mode == EMPTY) revert();
        if (mode == STRING) revert("source down");
        if (mode == CUSTOM) revert GateArithSourceDown();
        if (mode == ASSERT) assert(false);
        if (mode == DIVISION) {
            uint256 x = 1 / zero;
            x;
        }
    }
}

/// @notice AggregatorV3 feed whose round, decimals and failure mode a test sets freely (any int256 answer, any
/// uint256 timestamp, any decimals).
contract GateArithFeed is IAggregatorV3 {
    uint8 internal _decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint8 public roundFail;
    uint8 public decimalsFail;
    uint256 internal _zero;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        roundId += 1;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function fail(uint8 roundMode, uint8 decimalsMode) external {
        roundFail = roundMode;
        decimalsFail = decimalsMode;
    }

    function decimals() external view returns (uint8) {
        GateArithFail.check(decimalsFail, _zero);
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "gate arithmetic feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return latestRoundData();
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        GateArithFail.check(roundFail, _zero);
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @notice Token with settable decimals, issuer pause flag and ERC-8056 effectiveAt, each able to fail.
contract GateArithToken {
    uint8 internal _decimals;
    bool public paused;
    uint256 public effectiveAtValue;
    uint8 public decimalsFail;
    uint8 public pauseFail;
    uint8 public effectiveAtFail;
    uint256 internal _zero;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setEffectiveAt(uint256 when) external {
        effectiveAtValue = when;
    }

    function fail(uint8 decimalsMode, uint8 pauseMode, uint8 effectiveAtMode) external {
        decimalsFail = decimalsMode;
        pauseFail = pauseMode;
        effectiveAtFail = effectiveAtMode;
    }

    function decimals() external view returns (uint8) {
        GateArithFail.check(decimalsFail, _zero);
        return _decimals;
    }

    function oraclePaused() external view returns (bool) {
        GateArithFail.check(pauseFail, _zero);
        return paused;
    }

    function effectiveAt() external view returns (uint256) {
        GateArithFail.check(effectiveAtFail, _zero);
        return effectiveAtValue;
    }
}

/// @notice Clock set directly to any uint64, including 0 and 2^64 - 1.
contract GateArithClock is IClock {
    uint64 public t;

    function set(uint64 t_) external {
        t = t_;
    }

    function time() external view returns (uint64) {
        return t;
    }

    function isSimulation() external pure returns (bool) {
        return true;
    }
}

/// @notice PriceGate arithmetic at and around its exact bounds, adversarial answers, timestamps and clocks,
/// failing sources, decimals checks, peg and feed mode and the sequencer slot. Each bound is stated where it is
/// tested. M = 2^256 - 1 and M64 = 2^64 - 1.
contract GateArithmeticTest is GateFixture {
    uint256 internal constant M = type(uint256).max;
    uint64 internal constant M64 = type(uint64).max;
    uint32 internal constant LOAN_MAX_AGE = 3600;
    uint256 internal constant LOAN_BOUND = 2e8;

    GateArithClock internal setClock;

    function setUp() public {
        _setUpGate();
        setClock = new GateArithClock();
    }

    // ------------------------------------------------------------ builders

    function _pegConfig(IAggregatorV3 feed, uint8 sd, uint256 bound) internal view returns (PriceGate.Config memory c) {
        c = _config();
        c.stockFeed = PriceGate.Feed(feed, sd, MOCK_MAX_AGE, bound);
    }

    function _feedConfig(IAggregatorV3 stock, uint8 sd, uint256 sBound, IAggregatorV3 loan, uint8 ld, uint256 lBound)
        internal
        view
        returns (PriceGate.Config memory c)
    {
        c = _pegConfig(stock, sd, sBound);
        c.loanFeed = PriceGate.Feed(loan, ld, LOAN_MAX_AGE, lBound);
        c.pegLabel = "";
    }

    /// @dev Peg gate on the settable clock with a flagless-safe token (pause false, no multiplier change).
    function _clockGate(GateArithFeed stock, uint32 maxAge, uint256 bound) internal returns (PriceGate) {
        PriceGate.Config memory c = _pegConfig(IAggregatorV3(address(stock)), 8, bound);
        c.stockFeed.maxAge = maxAge;
        c.token = address(new GateArithToken(18));
        c.clock = setClock;
        return new PriceGate(c);
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    function _flooredRatio(uint256 stock, uint8 sd, uint256 loan, uint8 ld) internal pure returns (uint256) {
        return stock * 1e18 * 10 ** uint256(ld) / (loan * 10 ** uint256(sd));
    }

    // ------------------------------------------------------------ reason bits

    /// INV-GATE-19, INV-GATE-16: 21 distinct flags at bits 0..20, SOURCE_MASK = bits 0..17, and _checkRound's
    /// bits 0..3 shifted by 1 and 7 land exactly on the STOCK_ and LOAN_ round bits.
    function test_reasons_areTwentyOneDistinctBitsWithAlignedRoundShifts() public pure {
        uint32[21] memory bits = [
            Reasons.STOCK_FEED_UNAVAILABLE,
            Reasons.STOCK_BAD_ANSWER,
            Reasons.STOCK_NO_TIMESTAMP,
            Reasons.STOCK_FUTURE_TIMESTAMP,
            Reasons.STOCK_STALE,
            Reasons.STOCK_DECIMALS_CHANGED,
            Reasons.LOAN_FEED_UNAVAILABLE,
            Reasons.LOAN_BAD_ANSWER,
            Reasons.LOAN_NO_TIMESTAMP,
            Reasons.LOAN_FUTURE_TIMESTAMP,
            Reasons.LOAN_STALE,
            Reasons.LOAN_DECIMALS_CHANGED,
            Reasons.ISSUER_PAUSED,
            Reasons.PAUSE_FLAG_UNAVAILABLE,
            Reasons.MULTIPLIER_LAG,
            Reasons.MULTIPLIER_UNAVAILABLE,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_GRACE,
            Reasons.STOPPED,
            Reasons.OUTAGE_UNRESOLVED,
            Reasons.RECOVERY_GRACE
        ];
        uint32 union;
        for (uint256 i; i < bits.length; ++i) {
            assertEq(bits[i], uint32(1 << i), "bit position");
            assertEq(union & bits[i], 0, "distinct");
            union |= bits[i];
        }
        assertEq(union, (uint32(1) << 21) - 1);
        assertEq(Reasons.SOURCE_MASK, (uint32(1) << 18) - 1);
        assertEq(Reasons.SOURCE_MASK & (Reasons.STOPPED | Reasons.OUTAGE_UNRESOLVED | Reasons.RECOVERY_GRACE), 0);
        uint32[4] memory round = [uint32(1), 2, 4, 8]; // bad answer, no timestamp, future, stale
        uint32[4] memory stock =
            [Reasons.STOCK_BAD_ANSWER, Reasons.STOCK_NO_TIMESTAMP, Reasons.STOCK_FUTURE_TIMESTAMP, Reasons.STOCK_STALE];
        uint32[4] memory loan =
            [Reasons.LOAN_BAD_ANSWER, Reasons.LOAN_NO_TIMESTAMP, Reasons.LOAN_FUTURE_TIMESTAMP, Reasons.LOAN_STALE];
        for (uint256 i; i < 4; ++i) {
            assertEq(round[i] << 1, stock[i]);
            assertEq(round[i] << 7, loan[i]);
        }
    }

    // ------------------------------------------------------------ VALUE_SCALE = 10^(td + 18 - ld)

    function _scaleConfig(uint8 td, uint8 ld) internal returns (PriceGate.Config memory c) {
        c = _config();
        c.token = address(new GateArithToken(td));
        c.tokenDecimals = td;
        c.loanToken = address(new GateArithToken(ld));
        c.loanDecimals = ld;
    }

    /// INV-GATE-02. Bound: the exponent e = td + 18 - ld must lie in [0, 77], since 10^77 < 2^256 <= 10^78.
    /// e = 0 gives 1, e = 77 gives 1e77, e = 78 panics (0x11) and e = -1 reverts InvalidConfig.
    function test_valueScale_exponentBounds() public {
        assertEq(new PriceGate(_scaleConfig(0, 18)).VALUE_SCALE(), 1, "e = 0");
        assertEq(new PriceGate(_scaleConfig(255, 255)).VALUE_SCALE(), 1e18, "uint8 extremes cancel");
        assertEq(new PriceGate(_scaleConfig(59, 0)).VALUE_SCALE(), 1e77, "e = 77");

        PriceGate.Config memory c = _scaleConfig(60, 0);
        vm.expectRevert(stdError.arithmeticError);
        new PriceGate(c);

        c = _scaleConfig(0, 19);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
        c = _scaleConfig(236, 255);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(c);
    }

    /// INV-GATE-02: for every pair of uint8 decimals the constructor either stores exactly 10^e or rejects e < 0
    /// with InvalidConfig and e > 77 with an arithmetic panic.
    function testFuzz_valueScale_isTenToTheExponentOrRejected(uint8 td, uint8 ld) public {
        PriceGate.Config memory c = _scaleConfig(td, ld);
        if (uint256(td) + 18 < ld) {
            vm.expectRevert(PriceGate.InvalidConfig.selector);
            new PriceGate(c);
            return;
        }
        uint256 e = uint256(td) + 18 - ld;
        if (e > 77) {
            vm.expectRevert(stdError.arithmeticError);
            new PriceGate(c);
            return;
        }
        assertEq(new PriceGate(c).VALUE_SCALE(), 10 ** e);
    }

    // ------------------------------------------------------------ declared vs live decimals

    /// INV-GATE-03: each declared decimals value must equal the live one: token, loan token, stock feed and, in
    /// feed mode, the loan feed; the error names the source, the declared and the live value.
    function test_constructor_declaredDecimalsMustMatchEverySource() public {
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate.Config memory c = _feedConfig(stockFeed, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND);
        assertFalse(new PriceGate(c).usesPeg());

        c.loanFeed.decimals = 6;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(loan), 6, 8));
        new PriceGate(c);

        c.loanFeed.decimals = 8;
        c.stockFeed.decimals = 9;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(stockFeed), 9, 8));
        new PriceGate(c);

        c.stockFeed.decimals = 8;
        c.loanDecimals = 5;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(usdg), 5, 6));
        new PriceGate(c);

        c.loanDecimals = 6;
        c.tokenDecimals = 17;
        vm.expectRevert(abi.encodeWithSelector(PriceGate.DecimalsMismatch.selector, address(tsla), 17, 18));
        new PriceGate(c);
    }

    /// INV-GATE-03, INV-GATE-01: with the peg the loan feed is never read, so its declared decimals, age and bound
    /// are stored unchecked and never produce a reason.
    function test_constructor_pegNeverReadsTheLoanFeedFields() public {
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(0)), 77, 0, 0);
        PriceGate g = new PriceGate(c);
        assertTrue(g.usesPeg());
        assertEq(g.loanFeedDecimals(), 77);
        assertEq(g.loanMaxAge(), 0);
        assertEq(g.loanAnswerBound(), 0);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        assertEq(g.quote().reasons, 0);
        assertEq(g.quote().priceWad, 400e18);
    }

    /// INV-GATE-03: the constructor's decimals() calls are not wrapped, so a reverting source reverts the
    /// deployment with that source's own error.
    function test_constructor_decimalsCallsAreNotCaught() public {
        GateArithToken token = new GateArithToken(18);
        GateArithToken loanToken = new GateArithToken(6);
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate.Config memory c = _feedConfig(stock, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND);
        c.token = address(token);
        c.loanToken = address(loanToken);
        new PriceGate(c);

        token.fail(GateArithFail.CUSTOM, 0, 0);
        vm.expectRevert(GateArithFail.GateArithSourceDown.selector);
        new PriceGate(c);
        token.fail(0, 0, 0);

        loanToken.fail(GateArithFail.STRING, 0, 0);
        vm.expectRevert(bytes("source down"));
        new PriceGate(c);
        loanToken.fail(0, 0, 0);

        stock.fail(0, GateArithFail.CUSTOM);
        vm.expectRevert(GateArithFail.GateArithSourceDown.selector);
        new PriceGate(c);
        stock.fail(0, 0);

        loan.fail(0, GateArithFail.ASSERT);
        vm.expectRevert(stdError.assertionError);
        new PriceGate(c);
    }

    /// INV-GATE-03: token and loan-token decimals are checked only at deployment; feed decimals are rechecked on
    /// every read. A later change of a token's decimals leaves quotes and VALUE_SCALE as they were.
    function test_tokenDecimalsAreCheckedOnlyAtDeployment() public {
        GateArithToken token = new GateArithToken(18);
        GateArithToken loanToken = new GateArithToken(6);
        PriceGate.Config memory c = _config();
        c.token = address(token);
        c.loanToken = address(loanToken);
        PriceGate g = new PriceGate(c);
        _pushAt(MON_OPEN + 1 hours, TSLA_400);
        token.setDecimals(6);
        loanToken.setDecimals(18);
        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, 0);
        assertEq(q.priceWad, 400e18);
        assertEq(g.VALUE_SCALE(), 1e30);
        token.fail(GateArithFail.EMPTY, 0, 0);
        assertEq(g.refresh().reasons, 0, "token decimals are never called after deployment");
    }

    // ------------------------------------------------------------ decimals bounds of the price math

    /// INV-GATE-06, INV-GATE-49, appendix R22. Feed decimals are at most 18: sd = 18 deploys and prices exactly
    /// (peg: answer * 1e18 / 1e18), while 19, 39 and 78, which used to overflow on every read, are rejected at
    /// deployment.
    function test_pegStockDecimals_exactBounds() public {
        GateArithFeed f18 = new GateArithFeed(18);
        PriceGate g18 = new PriceGate(_pegConfig(f18, 18, 1e60));
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();
        f18.set(400e18, t, t);
        assertEq(g18.quote().reasons, 0);
        assertEq(g18.quote().priceWad, 400e18);
        f18.set(1e36, t, t);
        assertEq(g18.quote().priceWad, g18.MAX_PRICE_WAD(), "the ceiling itself is usable");

        uint8[3] memory bad = [19, 39, 78];
        for (uint256 i; i < bad.length; ++i) {
            GateArithFeed f = new GateArithFeed(bad[i]);
            vm.expectRevert(PriceGate.InvalidConfig.selector);
            new PriceGate(_pegConfig(f, bad[i], 1));
        }
    }

    /// INV-GATE-06, INV-GATE-49, appendix R22. Loan feed decimals are at most 18: ld = 18 deploys and prices
    /// exactly; 19, 60 and 78 are rejected at deployment.
    function test_feedLoanDecimals_exactBounds() public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed l18 = new GateArithFeed(18);
        PriceGate g18 = new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, l18, 18, 2e18));
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();
        stock.set(TSLA_400, t, t);
        l18.set(1e18, t, t);
        assertEq(g18.quote().reasons, 0);
        assertEq(g18.quote().priceWad, 400e18);

        uint8[3] memory bad = [19, 60, 78];
        for (uint256 i; i < bad.length; ++i) {
            GateArithFeed l = new GateArithFeed(bad[i]);
            vm.expectRevert(PriceGate.InvalidConfig.selector);
            new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, l, bad[i], 2));
        }
    }

    // ------------------------------------------------------------ answer magnitude bounds

    /// INV-GATE-07, INV-GATE-49, appendix R22. Peg mode, sd = 8: priceWad = answer * 1e10, usable up to
    /// MAX_PRICE_WAD (answer 1e26). One more is a bad answer with no price, and no answer, however large, makes a
    /// read revert.
    function test_pegAnswer_exactOverflowBound() public {
        GateArithFeed f = new GateArithFeed(8);
        PriceGate g = new PriceGate(_pegConfig(f, 8, M));
        _warp(MON_OPEN + 1 hours);
        f.set(1e26, _now(), _now());
        assertEq(g.quote().priceWad, 1e36);
        assertEq(g.quote().reasons, 0);
        f.set(1e26 + 1, _now(), _now());
        assertEq(g.quote().priceWad, 0);
        assertEq(g.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        f.set(type(int256).max, _now(), _now());
        assertEq(g.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        assertEq(g.refresh().reasons, Reasons.STOCK_BAD_ANSWER);
    }

    /// INV-GATE-07, INV-GATE-49, appendix R22. Feed mode, sd = ld = 8, loan answer 1 (the smallest in-range
    /// answer): priceWad = stock * 1e18, usable up to stock 1e18; above that a bad answer, never an overflow.
    function test_feedStockAnswer_exactOverflowBound() public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate g = new PriceGate(_feedConfig(stock, 8, M, loan, 8, LOAN_BOUND));
        _warp(MON_OPEN + 1 hours);
        loan.set(1, _now(), _now());
        stock.set(1e18, _now(), _now());
        assertEq(g.quote().priceWad, 1e36);
        stock.set(1e18 + 1, _now(), _now());
        assertEq(g.quote().reasons, Reasons.STOCK_BAD_ANSWER);
        stock.set(type(int256).max, _now(), _now());
        assertEq(g.quote().reasons, Reasons.STOCK_BAD_ANSWER);
    }

    /// INV-GATE-07, INV-GATE-49, appendix R22. The loan answer bound must keep loanAnswer * 10^sd <= 1e18 * 10^ld,
    /// so the price of an in-range quote is at least one: with sd = ld = 8 the largest bound is 1e18. A larger
    /// bound, which used to let a quote price at zero or overflow, is rejected at deployment.
    function test_feedLoanAnswer_exactOverflowBound() public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, 1e18 + 1));
        vm.expectRevert(PriceGate.InvalidConfig.selector);
        new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, M));
        PriceGate g = new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, 1e18));
        _warp(MON_OPEN + 1 hours);
        stock.set(1, _now(), _now());
        loan.set(1e18, _now(), _now());
        assertEq(g.quote().reasons, 0);
        assertEq(g.quote().priceWad, 1, "the smallest price is one");
    }

    /// INV-GATE-49, INV-GATE-18, INV-GATE-21, INV-GATE-22. With bounds like the shipped manifests (stock 1e14,
    /// loan 2e8, 8 decimals each) no answer or timestamp can make a read revert: casts happen only after
    /// answer > 0, and the largest price is 1e14 * 1e18 / 1 = 1e32.
    function testFuzz_quote_neverRevertsWithinManifestBounds(
        int256 stockAnswer,
        int256 loanAnswer,
        uint256 stockStamp,
        uint256 loanStamp
    ) public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate g = new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND));
        _warp(MON_OPEN + 1 hours);
        stock.set(stockAnswer, 0, stockStamp);
        loan.set(loanAnswer, 0, loanStamp);
        PriceGate.Quote memory q = g.quote();
        PriceGate.Quote memory r = g.refresh();
        assertEq(q.reasons, r.reasons);
        bool stockIn = stockAnswer > 0 && uint256(stockAnswer) <= ANSWER_BOUND;
        bool loanIn = loanAnswer > 0 && uint256(loanAnswer) <= LOAN_BOUND;
        assertEq(q.reasons & Reasons.STOCK_BAD_ANSWER != 0, !stockIn);
        assertEq(q.reasons & Reasons.LOAN_BAD_ANSWER != 0, !loanIn);
        if (stockIn && loanIn) {
            assertEq(q.priceWad, uint256(stockAnswer) * 1e18 / uint256(loanAnswer));
            assertLe(q.priceWad, 1e32);
        } else {
            assertEq(q.priceWad, 0);
        }
    }

    // ------------------------------------------------------------ adversarial answers

    /// INV-GATE-18, INV-GATE-49, INV-GATE-21: int256 min, -1, 0, 1, the bound, bound + 1 and int256 max, for the
    /// stock feed (peg mode) and the loan feed. Only 0 < answer <= bound is in range; nothing reverts.
    function test_answers_adversarialValues() public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate peg = new PriceGate(_pegConfig(stock, 8, ANSWER_BOUND));
        PriceGate feed = new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND));
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();
        loan.set(1e8, t, t);

        int256[7] memory answers =
            [type(int256).min, -1, 0, 1, int256(ANSWER_BOUND), int256(ANSWER_BOUND) + 1, type(int256).max];
        for (uint256 i; i < answers.length; ++i) {
            stock.set(answers[i], t, t);
            bool ok = answers[i] > 0 && uint256(answers[i]) <= ANSWER_BOUND;
            PriceGate.Quote memory q = peg.quote();
            assertEq(q.reasons, ok ? 0 : Reasons.STOCK_BAD_ANSWER, "stock reasons");
            assertEq(q.priceWad, ok ? uint256(answers[i]) * 1e10 : 0, "stock price");
            assertEq(feed.quote().reasons, ok ? 0 : Reasons.STOCK_BAD_ANSWER, "feed mode, stock side");
        }

        stock.set(TSLA_400, t, t);
        int256[7] memory loanAnswers =
            [type(int256).min, -1, 0, 1, int256(LOAN_BOUND), int256(LOAN_BOUND) + 1, type(int256).max];
        for (uint256 i; i < loanAnswers.length; ++i) {
            loan.set(loanAnswers[i], t, t);
            bool ok = loanAnswers[i] > 0 && uint256(loanAnswers[i]) <= LOAN_BOUND;
            PriceGate.Quote memory q = feed.quote();
            assertEq(q.reasons, ok ? 0 : Reasons.LOAN_BAD_ANSWER, "loan reasons");
            assertEq(q.priceWad, ok ? 400e26 / uint256(loanAnswers[i]) : 0, "loan price");
        }
    }

    // ------------------------------------------------------------ adversarial timestamps and clocks

    /// INV-GATE-18, INV-GATE-30 (mutant: dropping the uint64 clamp). Timestamps 0, t, t - maxAge, t - maxAge - 1,
    /// t + 1, 2^64 - 1, 2^64, 2^64 + 1 and 2^256 - 1. Bound: age == maxAge is fresh, maxAge + 1 is stale; q.updatedAt
    /// is min(updatedAt, 2^64 - 1), never a truncation.
    function test_timestamps_adversarialValues() public {
        ScriptedFeed f = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.stockFeed.feed = IAggregatorV3(address(f));
        PriceGate g = new PriceGate(c);
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();

        uint256[9] memory stamps = [
            uint256(0),
            t,
            t - MOCK_MAX_AGE,
            t - MOCK_MAX_AGE - 1,
            t + 1,
            uint256(M64),
            uint256(M64) + 1,
            uint256(M64) + 2,
            M
        ];
        uint32[9] memory expected = [
            Reasons.STOCK_NO_TIMESTAMP,
            0,
            0,
            Reasons.STOCK_STALE,
            Reasons.STOCK_FUTURE_TIMESTAMP,
            Reasons.STOCK_FUTURE_TIMESTAMP,
            Reasons.STOCK_FUTURE_TIMESTAMP,
            Reasons.STOCK_FUTURE_TIMESTAMP,
            Reasons.STOCK_FUTURE_TIMESTAMP
        ];
        for (uint256 i; i < stamps.length; ++i) {
            f.set(TSLA_400, 0, stamps[i]);
            PriceGate.Quote memory q = g.quote();
            assertEq(q.reasons, expected[i], "reasons");
            assertEq(q.updatedAt, stamps[i] > M64 ? M64 : uint64(stamps[i]), "clamped stamp");
            assertEq(q.priceWad, 400e18, "the price does not depend on the timestamp");
        }

        f.setReverting(true);
        PriceGate.Quote memory down = g.quote();
        assertEq(down.updatedAt, 0, "zero when the feed call fails");
        assertEq(down.roundId, 0);
    }

    /// INV-GATE-49, INV-GATE-30. Clock at 0: nothing is fresh (0 is NO_TIMESTAMP, anything later is FUTURE) and
    /// refresh records nothing. Clock at 2^64 - 1: a round stamped 2^64 - 1 is fresh and accepted; 2^64 is FUTURE
    /// although it clamps to the clock time; t - updatedAt is computed only once updatedAt <= t.
    function test_clock_extremeTimes() public {
        GateArithFeed f = new GateArithFeed(8);
        PriceGate g = _clockGate(f, MOCK_MAX_AGE, ANSWER_BOUND);

        setClock.set(0);
        f.set(TSLA_400, 0, 0);
        assertEq(g.refresh().reasons, Reasons.STOCK_NO_TIMESTAMP);
        f.set(TSLA_400, 0, 1);
        assertEq(g.refresh().reasons, Reasons.STOCK_FUTURE_TIMESTAMP);
        assertEq(g.lastAcceptedAt(), 0);
        assertEq(g.admittedSession(), 0);

        setClock.set(M64);
        f.set(TSLA_400, 0, M64);
        PriceGate.Quote memory q = g.refresh();
        assertEq(q.reasons, 0);
        assertEq(g.lastAcceptedAt(), M64);
        assertEq(g.lastUpdatedAt(), M64);
        f.set(TSLA_400, 0, uint256(M64) + 1);
        q = g.quote();
        assertEq(q.reasons, Reasons.STOCK_FUTURE_TIMESTAMP);
        assertEq(q.updatedAt, M64);
        f.set(TSLA_400, 0, M64 - MOCK_MAX_AGE);
        assertEq(g.quote().reasons, 0);
        f.set(TSLA_400, 0, M64 - MOCK_MAX_AGE - 1);
        assertEq(g.quote().reasons, Reasons.STOCK_STALE);

        PriceGate wide = _clockGate(f, type(uint32).max, ANSWER_BOUND);
        f.set(TSLA_400, 0, M64 - type(uint32).max);
        assertEq(wide.quote().reasons, 0, "age == uint32 max is fresh");
        f.set(TSLA_400, 0, M64 - type(uint32).max - 1);
        assertEq(wide.quote().reasons, Reasons.STOCK_STALE);
    }

    /// INV-GATE-18, INV-GATE-30, INV-GATE-49, INV-GATE-20: for any answer, timestamp, clock time, maxAge and bound,
    /// the stock round bits follow the rules (bad answer iff answer <= 0 or > bound; at most one of no
    /// timestamp, future, stale), q.updatedAt is the clamped stamp and the price is answer * 1e10 when in range.
    function testFuzz_stockRound_followsTheRoundRules(
        int256 answer,
        uint256 stamp,
        uint64 t,
        uint32 maxAge,
        uint256 answerBound
    ) public {
        maxAge = uint32(bound(maxAge, 1, type(uint32).max));
        answerBound = bound(answerBound, 1, M / 1e10);
        GateArithFeed f = new GateArithFeed(8);
        PriceGate g = _clockGate(f, maxAge, answerBound);
        setClock.set(t);
        f.set(answer, 0, stamp);

        // In range: positive, within the bound, and priced at most MAX_PRICE_WAD (answer * 1e10 <= 1e36).
        bool inRange = answer > 0 && uint256(answer) <= answerBound && uint256(answer) <= 1e26;
        uint32 expected = inRange ? 0 : Reasons.STOCK_BAD_ANSWER;
        if (stamp == 0) expected |= Reasons.STOCK_NO_TIMESTAMP;
        else if (stamp > t) expected |= Reasons.STOCK_FUTURE_TIMESTAMP;
        else if (t - stamp > maxAge) expected |= Reasons.STOCK_STALE;

        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, expected);
        assertEq(q.updatedAt, stamp > M64 ? M64 : uint64(stamp));
        assertEq(q.priceWad, inRange ? uint256(answer) * 1e10 : 0);
        uint32 timeBits =
            q.reasons & (Reasons.STOCK_NO_TIMESTAMP | Reasons.STOCK_FUTURE_TIMESTAMP | Reasons.STOCK_STALE);
        assertTrue(timeBits == 0 || timeBits & (timeBits - 1) == 0, "at most one timestamp bit");
        PriceGate.Quote memory r = g.refresh();
        assertEq(r.reasons, expected, "refresh agrees");
        if (expected == 0) {
            assertEq(g.lastPriceWad(), q.priceWad);
            assertEq(g.lastUpdatedAt(), q.updatedAt);
            assertEq(g.lastAcceptedAt(), t);
            assertLe(g.lastAcceptedAt() - g.lastUpdatedAt(), maxAge, "accepted age within maxAge");
        } else {
            assertEq(g.lastAcceptedAt(), 0);
        }
    }

    /// INV-GATE-18, INV-GATE-21, INV-GATE-49: the same rules for the loan feed land on the LOAN_ bits (shift 7),
    /// and the loan answer enters the price only when 0 < answer <= bound.
    function testFuzz_loanRound_followsTheRoundRules(int256 answer, uint256 stamp, uint256 offset) public {
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        PriceGate g = new PriceGate(_feedConfig(stock, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND));
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();
        stock.set(TSLA_400, t, t);
        if (offset % 3 == 0) stamp = t - bound(stamp, 0, 2 * LOAN_MAX_AGE);
        loan.set(answer, 0, stamp);

        bool inRange = answer > 0 && uint256(answer) <= LOAN_BOUND;
        uint32 expected = inRange ? 0 : Reasons.LOAN_BAD_ANSWER;
        if (stamp == 0) expected |= Reasons.LOAN_NO_TIMESTAMP;
        else if (stamp > t) expected |= Reasons.LOAN_FUTURE_TIMESTAMP;
        else if (t - stamp > LOAN_MAX_AGE) expected |= Reasons.LOAN_STALE;

        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, expected);
        assertEq(q.updatedAt, t, "the quote's timestamp is the stock feed's");
        assertEq(q.priceWad, inRange ? uint256(TSLA_400) * 1e18 / uint256(answer) : 0);
    }

    // ------------------------------------------------------------ time additions

    /// INV-GATE-49, INV-GATE-12. Bound: requestResume computes t + 86400 in uint64, so it works up to
    /// t = 2^64 - 1 - 86400 (resumeAvailableAt = 2^64 - 1) and panics one second later.
    function test_requestResume_exactOverflowBound() public {
        GateArithFeed f = new GateArithFeed(8);
        PriceGate g = _clockGate(f, MOCK_MAX_AGE, ANSWER_BOUND);
        vm.startPrank(guardian);
        g.stop();
        setClock.set(M64 - uint64(SessionTiming.RESUME_DELAY));
        g.requestResume();
        assertEq(g.resumeAvailableAt(), M64);
        setClock.set(M64 - uint64(SessionTiming.RESUME_DELAY) + 1);
        vm.expectRevert(stdError.arithmeticError);
        g.requestResume();
        vm.stopPrank();
    }

    /// INV-GATE-49, INV-GATE-14. Bound: the grace check computes checkpointAt + 300 in uint64, so a checkpoint at
    /// 2^64 - 1 - 300 still reads (RECOVERY_GRACE, then usable once t reaches 2^64 - 1 with a newer round) and a
    /// checkpoint one second later makes quote() and refresh() panic. Only resume() can set such a checkpoint,
    /// and only with a clock near 2^64.
    function test_recoveryGrace_exactOverflowBound() public {
        GateArithFeed f = new GateArithFeed(8);
        PriceGate ok = _clockGate(f, MOCK_MAX_AGE, ANSWER_BOUND);
        PriceGate over = _clockGate(f, MOCK_MAX_AGE, ANSWER_BOUND);
        uint64 cp = M64 - uint64(SessionTiming.RECOVERY_GRACE);

        setClock.set(cp - uint64(SessionTiming.RESUME_DELAY));
        vm.startPrank(guardian);
        ok.stop();
        ok.requestResume();
        setClock.set(cp);
        ok.resume();
        vm.stopPrank();
        assertEq(ok.checkpointAt(), cp);
        f.set(TSLA_400, 0, cp);
        assertEq(ok.quote().reasons, Reasons.RECOVERY_GRACE);
        setClock.set(M64);
        f.set(TSLA_400, 0, M64);
        assertEq(ok.refresh().reasons, 0, "grace over at cp + 300 = 2^64 - 1 with a newer round");
        assertEq(ok.checkpointAt(), 0);

        setClock.set(cp + 1 - uint64(SessionTiming.RESUME_DELAY));
        vm.startPrank(guardian);
        over.stop();
        over.requestResume();
        setClock.set(cp + 1);
        over.resume();
        vm.stopPrank();
        vm.expectRevert(stdError.arithmeticError);
        over.quote();
        vm.expectRevert(stdError.arithmeticError);
        over.refresh();
    }

    function creditAtOf(uint64 open, uint64 admissionAt) external pure returns (uint64) {
        return SessionTiming.creditAt(open, admissionAt);
    }

    /// INV-GATE-49. Bound: creditAt(O, a) = max(O + 900, a + 600) in uint64, so O <= 2^64 - 1 - 900 and
    /// a <= 2^64 - 1 - 600. The gate passes only calendar opens and in-session admission times, which are 32-bit
    /// in the packed calendar, as are O + ADMIT_AFTER and O + FRESH_AFTER.
    function test_creditAt_exactOverflowBound() public {
        assertEq(this.creditAtOf(M64 - 900, 0), M64);
        vm.expectRevert(stdError.arithmeticError);
        this.creditAtOf(M64 - 899, 0);
        assertEq(this.creditAtOf(0, M64 - 600), M64);
        vm.expectRevert(stdError.arithmeticError);
        this.creditAtOf(0, M64 - 599);
        assertLt(cal.lastClose(), uint64(1) << 32, "every calendar time fits in 32 bits");
    }

    /// INV-GATE-49: for 32-bit times creditAt never reverts and is the later of the two recovery ends.
    function testFuzz_creditAt_isTheLaterRecoveryEnd(uint32 open, uint32 admissionAt) public view {
        uint64 a = uint64(open) + 900;
        uint64 b = uint64(admissionAt) + 600;
        assertEq(this.creditAtOf(open, admissionAt), a > b ? a : b);
    }

    // ------------------------------------------------------------ sequencer slot

    function _sequencerGate(GateArithFeed seq, uint32 grace) internal returns (PriceGate) {
        PriceGate.Config memory c = _config();
        c.sequencerFeed = IAggregatorV3(address(seq));
        c.sequencerGrace = grace;
        return new PriceGate(c);
    }

    /// INV-GATE-26, INV-GATE-49 (mutant: dropping `startedAt > t`). Bound: up for exactly `grace` seconds is
    /// usable, one second less is SEQUENCER_GRACE; a start in the future, a zero start, any non-zero status or a
    /// reverting call is SEQUENCER_DOWN, and nothing reverts: t - startedAt runs only once startedAt <= t.
    function test_sequencer_boundaryTable() public {
        GateArithFeed seq = new GateArithFeed(0);
        PriceGate g = _sequencerGate(seq, 3600);
        _pushAt(MON_OPEN + 3 hours, TSLA_400);
        uint256 t = _now();

        int256[12] memory status = [int256(0), 0, 0, 0, 0, 0, 1, -1, type(int256).min, type(int256).max, 0, 0];
        uint256[12] memory started = [t - 3600, t - 3599, t, t + 1, M, 0, t - 7200, t - 7200, 1, 1, 1, t - 1];
        uint32[12] memory expected = [
            uint32(0),
            Reasons.SEQUENCER_GRACE,
            Reasons.SEQUENCER_GRACE,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            Reasons.SEQUENCER_DOWN,
            0,
            Reasons.SEQUENCER_GRACE
        ];
        for (uint256 i; i < status.length; ++i) {
            seq.set(status[i], started[i], t);
            assertEq(g.quote().reasons, expected[i], "quote");
            assertEq(g.refresh().reasons, expected[i], "refresh");
        }
        for (uint8 mode = 1; mode < GateArithFail.MODES; ++mode) {
            seq.fail(mode, 0);
            assertEq(g.quote().reasons, Reasons.SEQUENCER_DOWN, "reverting uptime feed");
        }
    }

    /// INV-GATE-26, INV-GATE-09 (grace boundary). With grace 0 the strict `t - startedAt < grace` never holds, so
    /// a restart at t is already usable; with grace = uint32 max a restart in 1970 is still in its grace.
    function test_sequencer_graceExtremes() public {
        GateArithFeed seq = new GateArithFeed(0);
        PriceGate none = _sequencerGate(seq, 0);
        PriceGate forever = _sequencerGate(seq, type(uint32).max);
        _pushAt(MON_OPEN + 3 hours, TSLA_400);
        seq.set(0, _now(), _now());
        assertEq(none.quote().reasons, 0);
        seq.set(0, 1, _now());
        assertEq(forever.quote().reasons, Reasons.SEQUENCER_GRACE);
    }

    /// INV-GATE-26, INV-GATE-49: for any status, start, clock time and grace the uptime bits follow the rules.
    function testFuzz_sequencer_followsTheUptimeRules(int256 status, uint256 startedAt, uint64 t, uint32 grace) public {
        t = uint64(bound(t, 1, M64));
        if (status % 2 == 0) status = 0;
        if (startedAt % 3 == 0) startedAt = t - bound(startedAt, 0, uint256(grace) + 1 > t ? t : uint256(grace) + 1);
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed seq = new GateArithFeed(0);
        PriceGate.Config memory c = _pegConfig(stock, 8, ANSWER_BOUND);
        c.token = address(new GateArithToken(18));
        c.clock = setClock;
        c.sequencerFeed = seq;
        c.sequencerGrace = grace;
        PriceGate g = new PriceGate(c);
        setClock.set(t);
        stock.set(TSLA_400, 0, t);
        seq.set(status, startedAt, t);

        uint32 expected;
        if (status != 0 || startedAt == 0 || startedAt > t) expected = Reasons.SEQUENCER_DOWN;
        else if (t - startedAt < grace) expected = Reasons.SEQUENCER_GRACE;
        assertEq(g.quote().reasons, expected);
    }

    // ------------------------------------------------------------ reverting sources

    /// INV-GATE-27, INV-GATE-23, INV-GATE-24: every try/catch site turns every plain revert kind (empty, string,
    /// custom error, assert panic, division panic) into exactly its own reason bit; neither read reverts.
    function testFuzz_revertingSource_setsExactlyItsOwnBit(uint8 site, uint8 mode) public {
        site = uint8(bound(site, 0, 7));
        mode = uint8(bound(mode, 1, GateArithFail.MODES - 1));
        GateArithFeed stock = new GateArithFeed(8);
        GateArithFeed loan = new GateArithFeed(8);
        GateArithFeed seq = new GateArithFeed(0);
        GateArithToken token = new GateArithToken(18);
        PriceGate.Config memory c = _feedConfig(stock, 8, ANSWER_BOUND, loan, 8, LOAN_BOUND);
        c.token = address(token);
        c.sequencerFeed = seq;
        c.sequencerGrace = 600;
        c.pauseFlagRequired = site != 7; // site 7: the same pause failure with the flag optional
        PriceGate g = new PriceGate(c);
        _warp(MON_OPEN + 1 hours);
        uint256 t = _now();
        stock.set(TSLA_400, t, t);
        loan.set(1e8, t, t);
        seq.set(0, t - 1 days, t);
        assertEq(g.quote().reasons, 0);

        uint32 expected;
        if (site == 0) {
            stock.fail(mode, 0);
            expected = Reasons.STOCK_FEED_UNAVAILABLE;
        } else if (site == 1) {
            stock.fail(0, mode);
            expected = Reasons.STOCK_DECIMALS_CHANGED;
        } else if (site == 2) {
            loan.fail(mode, 0);
            expected = Reasons.LOAN_FEED_UNAVAILABLE;
        } else if (site == 3) {
            loan.fail(0, mode);
            expected = Reasons.LOAN_DECIMALS_CHANGED;
        } else if (site == 4) {
            token.fail(0, mode, 0);
            expected = Reasons.PAUSE_FLAG_UNAVAILABLE;
        } else if (site == 5) {
            token.fail(0, 0, mode);
            expected = Reasons.MULTIPLIER_UNAVAILABLE;
        } else if (site == 6) {
            seq.fail(mode, 0);
            expected = Reasons.SEQUENCER_DOWN;
        } else {
            token.fail(0, mode, 0); // the flag is optional on this gate
        }

        PriceGate.Quote memory q = g.quote();
        assertEq(q.reasons, expected);
        assertEq(q.priceWad, site == 0 || site == 2 ? 0 : 400e18, "no price without both answers");
        assertEq(g.refresh().reasons, expected);
    }

    // ------------------------------------------------------------ price formula, peg and feed mode

    /// INV-GATE-22, appendix R22: in feed mode priceWad is the floor of stock * 1e18 * 10^ld / (loan * 10^sd) for
    /// any in-range answers and decimals 0..18, checked against the defining inequality without mulDiv; an answer
    /// that would price above MAX_PRICE_WAD is a bad answer instead. The loan bound is the largest R22 allows.
    function testFuzz_priceWad_feedModeIsTheFlooredRatio(uint256 s, uint256 l, uint8 sd, uint8 ld) public {
        sd = uint8(bound(sd, 0, 18));
        ld = uint8(bound(ld, 0, 18));
        uint256 lBound = Math.min(1e30, 1e18 * 10 ** uint256(ld) / 10 ** uint256(sd));
        s = bound(s, 1, 1e30);
        l = bound(l, 1, lBound);
        GateArithFeed stock = new GateArithFeed(sd);
        GateArithFeed loan = new GateArithFeed(ld);
        PriceGate g = new PriceGate(_feedConfig(stock, sd, 1e30, loan, ld, lBound));
        _warp(MON_OPEN + 1 hours);
        stock.set(int256(s), _now(), _now());
        loan.set(int256(l), _now(), _now());
        PriceGate.Quote memory q = g.quote();
        uint256 num = s * 1e18 * 10 ** uint256(ld);
        uint256 den = l * 10 ** uint256(sd);
        if (s > Math.mulDiv(1e36, den, 1e18 * 10 ** uint256(ld))) {
            assertEq(q.reasons, Reasons.STOCK_BAD_ANSWER, "above the price ceiling");
            assertEq(q.priceWad, 0);
            return;
        }
        assertEq(q.reasons, 0);
        assertGe(q.priceWad, 1, "never zero");
        assertLe(q.priceWad, 1e36);
        assertLe(q.priceWad * den, num, "rounded down");
        assertGt((q.priceWad + 1) * den, num, "by less than one unit");
        assertEq(q.priceWad, _flooredRatio(s, sd, l, ld));
    }

    /// INV-GATE-21, INV-GATE-01: the peg prices floor(answer * 1e18 / 10^sd) for sd 0..18 (appendix R22) up to
    /// MAX_PRICE_WAD and never sets a LOAN_ bit, whatever the unused loan feed fields hold.
    function testFuzz_peg_pricesTheAnswerAndNeverSetsLoanBits(uint256 s, uint8 sd, uint256 stamp, uint32 junk) public {
        sd = uint8(bound(sd, 0, 18));
        s = bound(s, 1, 1e40);
        GateArithFeed stock = new GateArithFeed(sd);
        PriceGate.Config memory c = _pegConfig(stock, sd, 1e40);
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(0)), uint8(junk), junk, junk);
        PriceGate g = new PriceGate(c);
        _warp(MON_OPEN + 1 hours);
        stock.set(int256(s), 0, stamp);
        PriceGate.Quote memory q = g.quote();
        bool aboveCeiling = s > 1e18 * 10 ** uint256(sd);
        assertEq(q.priceWad, aboveCeiling ? 0 : s * 1e18 / 10 ** uint256(sd));
        assertEq(q.reasons & Reasons.STOCK_BAD_ANSWER != 0, aboveCeiling);
        uint32 loanBits = Reasons.LOAN_FEED_UNAVAILABLE | Reasons.LOAN_BAD_ANSWER | Reasons.LOAN_NO_TIMESTAMP
            | Reasons.LOAN_FUTURE_TIMESTAMP | Reasons.LOAN_STALE | Reasons.LOAN_DECIMALS_CHANGED;
        assertEq(q.reasons & loanBits, 0);
    }

    /// INV-GATE-22: the price is computed whenever both answers are in range, also while other reasons make the
    /// quote unusable, so consumers must test reasons; a refresh then keeps the last usable price.
    function test_priceWad_isComputedForAnUnusableQuote() public {
        _freshRefresh(MON_OPEN + 1 hours);
        _warp(block.timestamp + MOCK_MAX_AGE + 1);
        stockFeed.pushAt(TSLA_400 / 2, uint64(block.timestamp - MOCK_MAX_AGE - 1));
        tsla.setOraclePaused(true);
        PriceGate.Quote memory q = gate.refresh();
        assertEq(q.reasons, Reasons.STOCK_STALE | Reasons.ISSUER_PAUSED);
        assertEq(q.priceWad, 200e18);
        assertEq(gate.lastPriceWad(), 400e18);
    }

    /// INV-GATE-50, INV-GATE-49. Bound: valueOf(raw, p) = floor(raw * p / 1e30) reverts only when the result
    /// reaches 2^256; rawForValue divides by p and panics (0x12) for p = 0.
    function test_valueConversions_bounds() public {
        assertEq(gate.valueOf(M, 1e30), M, "result exactly M");
        vm.expectRevert(stdError.arithmeticError);
        gate.valueOf(M, 1e30 + 1);
        assertEq(gate.valueOf(M, 1e18), M / 1e12, "512-bit intermediate product");
        vm.expectRevert(stdError.divisionError);
        gate.rawForValue(1, 0, Math.Rounding.Floor);
        assertEq(gate.rawForValue(0, 1, Math.Rounding.Ceil), 0);
        assertEq(gate.rawForValue(1, 1e30, Math.Rounding.Ceil), 1);
        assertEq(gate.rawForValue(1, 1e30 + 1, Math.Rounding.Floor), 0);
        assertEq(gate.rawForValue(1, 1e30 + 1, Math.Rounding.Ceil), 1);
    }

    // ------------------------------------------------------------ gas withheld by the caller

    /// @dev Calls `data` on `g` with `gasLimit`, every touched account cold as in a fresh transaction; returns
    /// whether it completed and its reasons.
    function _callWithGas(PriceGate g, bytes memory data, address[7] memory touched, uint256 gasLimit)
        internal
        returns (bool ok, uint32 reasons)
    {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
        bytes memory ret;
        (ok, ret) = address(g).call{gas: gasLimit}(data);
        if (ok) reasons = abi.decode(ret, (PriceGate.Quote)).reasons;
        vm.revertToState(snap);
    }

    /// @dev Feed-mode gate with every try/catch site configured (stock round and decimals, loan round and
    /// decimals, pause flag, effectiveAt, sequencer), all valid, so an unlimited read has no reason.
    function _gasGate() internal returns (PriceGate g, address[7] memory touched) {
        GateArithFeed seq = new GateArithFeed(0);
        ScriptedFeed loan = new ScriptedFeed(8);
        PriceGate.Config memory c = _config();
        c.loanFeed = PriceGate.Feed(IAggregatorV3(address(loan)), 8, LOAN_MAX_AGE, LOAN_BOUND);
        c.sequencerFeed = seq;
        c.sequencerGrace = 600;
        g = new PriceGate(c);
        _pushAt(MON_OPEN + 8 minutes, TSLA_400);
        loan.set(1e8, block.timestamp, block.timestamp);
        seq.set(0, block.timestamp - 1 days, block.timestamp);
        assertEq(g.quote().reasons, 0);
        touched =
            [address(g), address(stockFeed), address(loan), address(seq), address(tsla), address(cal), address(clock)];
    }

    /// @dev Finds the smallest completing gas limit by bisection, then calls with every 97th gas limit below it
    /// (where try/catch sites starve), every 3rd just around it (where a starved site would have to leave enough
    /// gas to finish) and every 1009th above it. Returns the completing calls and those that reported a reason.
    function _scanGas(bytes memory data) internal returns (uint256 completed, uint256 spurious) {
        (PriceGate g, address[7] memory touched) = _gasGate();
        uint256 lo = 5_000;
        uint256 hi = 2_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _callWithGas(g, data, touched, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("smallest completing gas limit", hi);
        uint256 gasLimit = 5_000;
        while (gasLimit < 3 * hi) {
            (bool ok, uint32 reasons) = _callWithGas(g, data, touched, gasLimit);
            if (ok) completed++;
            if (ok && reasons != 0) spurious++;
            if (gasLimit + 2_000 < hi) gasLimit += 97;
            else if (gasLimit < hi + 6_000) gasLimit += 3;
            else gasLimit += 1_009;
        }
    }

    /// INV-GATE-29: whatever gas the caller gives, a refresh() that completes reports no reason that an unlimited
    /// call does not: a try/catch site starved by the caller keeps 1/64 of the gas, which cannot finish the read,
    /// so the call reverts instead of failing closed spuriously.
    function test_gasLimits_refreshNeverTurnsStarvationIntoAReason() public {
        (uint256 completed, uint256 spurious) = _scanGas(abi.encodeCall(PriceGate.refresh, ()));
        assertGt(completed, 0, "the scan reaches completing calls");
        assertEq(spurious, 0);
    }

    /// INV-GATE-29: the same scan for quote().
    function test_gasLimits_quoteNeverTurnsStarvationIntoAReason() public {
        (uint256 completed, uint256 spurious) = _scanGas(abi.encodeCall(PriceGate.quote, ()));
        assertGt(completed, 0, "the scan reaches completing calls");
        assertEq(spurious, 0);
    }
}
