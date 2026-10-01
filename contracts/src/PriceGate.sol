// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IClock} from "./interfaces/IClock.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {SessionCalendar} from "./SessionCalendar.sol";
import {Reasons} from "./libraries/Reasons.sol";
import {SessionTiming} from "./libraries/SessionTiming.sol";

/// @title PriceGate
/// @notice Decides whether the collateral price can be used right now, and records the reopening and
/// recovery checkpoints that SessionRiskPolicy reads (docs/SPEC.md §6, appendix R3, R4, R11, R12, R14).
///
/// Units: `priceWad` is loan-token whole units per collateral whole unit, scaled by 1e18. Collateral value in
/// loan-token base units is `raw * priceWad / VALUE_SCALE` with VALUE_SCALE = 10^(tokenDecimals + 18 -
/// loanDecimals).
///
/// The guardian (owner) can stop price-dependent actions at once and resume them only after a 24-hour delay.
/// It cannot set prices, thresholds or balances.
contract PriceGate is Ownable2Step {
    struct Feed {
        IAggregatorV3 feed;
        uint8 decimals;
        uint32 maxAge;
        uint256 answerBound;
    }

    struct Config {
        address token;
        uint8 tokenDecimals;
        bool pauseFlagRequired;
        bool erc8056;
        address loanToken;
        uint8 loanDecimals;
        Feed stockFeed;
        Feed loanFeed; // feed == address(0): labelled 1:1 test peg, allowed on test chains only
        string pegLabel;
        IAggregatorV3 sequencerFeed; // address(0): no sequencer uptime feed configured
        uint32 sequencerGrace;
        IClock clock;
        SessionCalendar calendar;
        address guardian;
    }

    struct Quote {
        uint256 priceWad;
        uint80 roundId;
        uint64 updatedAt; // stock feed timestamp
        uint32 reasons; // Reasons bits; zero means usable
    }

    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    IStockToken public immutable token;
    uint8 public immutable tokenDecimals;
    bool public immutable pauseFlagRequired;
    bool public immutable erc8056;
    address public immutable loanToken;
    uint8 public immutable loanDecimals;
    IAggregatorV3 public immutable stockFeed;
    uint8 public immutable stockFeedDecimals;
    uint32 public immutable stockMaxAge;
    uint256 public immutable stockAnswerBound;
    IAggregatorV3 public immutable loanFeed;
    uint8 public immutable loanFeedDecimals;
    uint32 public immutable loanMaxAge;
    uint256 public immutable loanAnswerBound;
    IAggregatorV3 public immutable sequencerFeed;
    uint32 public immutable sequencerGrace;
    IClock public immutable clock;
    SessionCalendar public immutable calendar;
    uint256 public immutable VALUE_SCALE;
    string public pegLabel;

    // Reopening admission of the current session (session index + 1; zero means none).
    uint32 public admittedSession;
    uint64 public admissionAt;
    // Session (index + 1) in which an admitted price source failed and has not yet recovered.
    uint32 public outageSession;
    // Latest recovery checkpoint (source recovery or guardian resume); zero when none is pending.
    uint64 public checkpointAt;

    bool public stopped;
    uint64 public resumeAvailableAt;

    // Last fully usable quote, for indicative views while prices are locked.
    uint256 public lastPriceWad;
    uint64 public lastUpdatedAt;
    uint64 public lastAcceptedAt;

    event Admitted(uint256 indexed session, uint64 admissionAt, uint64 priceUpdatedAt);
    event AdmissionReset(uint256 indexed session, uint64 at, uint32 reasons);
    event OutageDetected(uint256 indexed session, uint64 at, uint32 reasons);
    event RecoveryCheckpoint(uint64 at);
    event Stopped(uint64 at);
    event ResumeRequested(uint64 at, uint64 availableAt);
    event Resumed(uint64 at);

    error DecimalsMismatch(address source, uint8 expected, uint8 actual);
    error PegNotAllowed(uint256 chainId);
    error MissingPegLabel();
    error InvalidConfig();
    error NotStopped();
    error ResumeNotRequested();
    error ResumeTooEarly(uint64 availableAt);
    error RenounceDisabled();

    constructor(Config memory c) Ownable(c.guardian) {
        if (c.token == address(0) || c.loanToken == address(0) || address(c.stockFeed.feed) == address(0)) {
            revert InvalidConfig();
        }
        if (address(c.clock) == address(0) || address(c.calendar) == address(0)) revert InvalidConfig();
        if (c.stockFeed.maxAge == 0 || c.stockFeed.answerBound == 0) revert InvalidConfig();
        if (uint256(c.tokenDecimals) + 18 < c.loanDecimals) revert InvalidConfig();

        _expectDecimals(c.token, c.tokenDecimals, IERC20Metadata(c.token).decimals());
        _expectDecimals(c.loanToken, c.loanDecimals, IERC20Metadata(c.loanToken).decimals());
        _expectDecimals(address(c.stockFeed.feed), c.stockFeed.decimals, c.stockFeed.feed.decimals());

        if (address(c.loanFeed.feed) == address(0)) {
            if (block.chainid != LOCAL_CHAIN_ID && block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) {
                revert PegNotAllowed(block.chainid);
            }
            if (bytes(c.pegLabel).length == 0) revert MissingPegLabel();
            pegLabel = c.pegLabel;
        } else {
            if (c.loanFeed.maxAge == 0 || c.loanFeed.answerBound == 0) revert InvalidConfig();
            _expectDecimals(address(c.loanFeed.feed), c.loanFeed.decimals, c.loanFeed.feed.decimals());
        }

        token = IStockToken(c.token);
        tokenDecimals = c.tokenDecimals;
        pauseFlagRequired = c.pauseFlagRequired;
        erc8056 = c.erc8056;
        loanToken = c.loanToken;
        loanDecimals = c.loanDecimals;
        stockFeed = c.stockFeed.feed;
        stockFeedDecimals = c.stockFeed.decimals;
        stockMaxAge = c.stockFeed.maxAge;
        stockAnswerBound = c.stockFeed.answerBound;
        loanFeed = c.loanFeed.feed;
        loanFeedDecimals = c.loanFeed.decimals;
        loanMaxAge = c.loanFeed.maxAge;
        loanAnswerBound = c.loanFeed.answerBound;
        sequencerFeed = c.sequencerFeed;
        sequencerGrace = c.sequencerGrace;
        clock = c.clock;
        calendar = c.calendar;
        VALUE_SCALE = 10 ** (uint256(c.tokenDecimals) + 18 - c.loanDecimals);
    }

    // ---------------------------------------------------------------- reads

    /// @notice The current quote with every reason it cannot be used, including gate state.
    function quote() public view returns (Quote memory q) {
        uint64 t = clock.time();
        q = _sourceQuote(t);
        if (stopped) q.reasons |= Reasons.STOPPED;
        if (outageSession != 0 && outageSession == _sessionId(t)) q.reasons |= Reasons.OUTAGE_UNRESOLVED;
        if (_gracePending(t, q.updatedAt)) q.reasons |= Reasons.RECOVERY_GRACE;
    }

    /// @notice Admission time recorded for session `index`, or zero if that session has none.
    function admissionFor(uint256 index) external view returns (uint64) {
        return admittedSession == index + 1 ? admissionAt : 0;
    }

    /// @notice True when the price source uses the labelled test peg instead of a loan-token feed.
    function usesPeg() external view returns (bool) {
        return address(loanFeed) == address(0);
    }

    /// @notice Collateral value in loan-token base units, rounded down.
    function valueOf(uint256 raw, uint256 priceWad) public view returns (uint256) {
        return Math.mulDiv(raw, priceWad, VALUE_SCALE);
    }

    /// @notice Raw collateral worth `value` loan-token base units at `priceWad`.
    function rawForValue(uint256 value, uint256 priceWad, Math.Rounding rounding) public view returns (uint256) {
        return Math.mulDiv(value, VALUE_SCALE, priceWad, rounding);
    }

    // ---------------------------------------------------------------- refresh

    /// @notice Record reopening admission, outages and recovery checkpoints for the current session, then
    /// return the current quote. Permissionless; every price-dependent entry point calls it first.
    function refresh() public returns (Quote memory q) {
        uint64 t = clock.time();
        q = _sourceQuote(t);
        if (stopped) q.reasons |= Reasons.STOPPED;
        uint32 base = q.reasons;

        SessionCalendar.Context memory ctx = calendar.context(t);
        uint32 sid = uint32(ctx.index + 1);
        if (outageSession != 0 && outageSession != sid) outageSession = 0;
        if (checkpointAt != 0 && !_gracePending(t, q.updatedAt)) checkpointAt = 0;

        if (ctx.covered && ctx.inSession) {
            bool admitted = admittedSession == sid;
            if (base == 0) {
                if (outageSession == sid) {
                    outageSession = 0;
                    checkpointAt = t;
                    emit RecoveryCheckpoint(t);
                } else if (
                    !admitted && checkpointAt == 0 && t >= ctx.open + SessionTiming.ADMIT_AFTER
                        && q.updatedAt >= ctx.open + SessionTiming.FRESH_AFTER
                ) {
                    admittedSession = sid;
                    admissionAt = t;
                    emit Admitted(ctx.index, t, q.updatedAt);
                }
            } else if (admitted) {
                if (t < SessionTiming.creditAt(ctx.open, admissionAt)) {
                    // Interrupted reopening recovery: admission starts over once the source is valid again.
                    admittedSession = 0;
                    admissionAt = 0;
                    emit AdmissionReset(ctx.index, t, base);
                } else if (outageSession != sid) {
                    outageSession = sid;
                    emit OutageDetected(ctx.index, t, base);
                }
            }
        }

        if (outageSession == sid) q.reasons |= Reasons.OUTAGE_UNRESOLVED;
        if (_gracePending(t, q.updatedAt)) q.reasons |= Reasons.RECOVERY_GRACE;

        if (q.reasons == 0) {
            lastPriceWad = q.priceWad;
            lastUpdatedAt = q.updatedAt;
            lastAcceptedAt = t;
        }
    }

    // ---------------------------------------------------------------- guardian

    /// @notice Stop price-dependent actions immediately. Repayment and top-ups stay available.
    function stop() external onlyOwner {
        stopped = true;
        resumeAvailableAt = 0;
        emit Stopped(clock.time());
    }

    /// @notice Start the 24-hour resume delay.
    function requestResume() external onlyOwner {
        if (!stopped) revert NotStopped();
        uint64 t = clock.time();
        resumeAvailableAt = t + SessionTiming.RESUME_DELAY;
        emit ResumeRequested(t, resumeAvailableAt);
    }

    /// @notice Resume after the delay. Sets a recovery checkpoint, so prices need a fresh update and a
    /// five-minute grace before price-dependent actions return.
    function resume() external onlyOwner {
        if (!stopped) revert NotStopped();
        if (resumeAvailableAt == 0) revert ResumeNotRequested();
        uint64 t = clock.time();
        if (t < resumeAvailableAt) revert ResumeTooEarly(resumeAvailableAt);
        stopped = false;
        resumeAvailableAt = 0;
        outageSession = 0;
        checkpointAt = t;
        emit Resumed(t);
        emit RecoveryCheckpoint(t);
    }

    /// @dev A gate without a guardian could never resume after a stop.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- internals

    function _sourceQuote(uint64 t) internal view returns (Quote memory q) {
        int256 stockAnswer;
        uint256 stockUpdatedAt;
        bool stockOk;
        (stockOk, q.roundId, stockAnswer, stockUpdatedAt) = _latest(stockFeed);
        if (!stockOk) {
            q.reasons |= Reasons.STOCK_FEED_UNAVAILABLE;
        } else {
            q.reasons |= _checkRound(stockAnswer, stockUpdatedAt, t, stockMaxAge, stockAnswerBound) << 1;
            q.updatedAt = stockUpdatedAt > type(uint64).max ? type(uint64).max : uint64(stockUpdatedAt);
        }
        if (!_decimalsMatch(stockFeed, stockFeedDecimals)) q.reasons |= Reasons.STOCK_DECIMALS_CHANGED;

        uint256 loanAnswer = 10 ** uint256(stockFeedDecimals); // peg: one loan unit per USD
        uint256 loanScale = 10 ** uint256(stockFeedDecimals);
        if (address(loanFeed) != address(0)) {
            (bool loanOk,, int256 answer, uint256 updatedAt) = _latest(loanFeed);
            if (!loanOk) {
                q.reasons |= Reasons.LOAN_FEED_UNAVAILABLE;
            } else {
                q.reasons |= _checkRound(answer, updatedAt, t, loanMaxAge, loanAnswerBound) << 7;
            }
            if (!_decimalsMatch(loanFeed, loanFeedDecimals)) q.reasons |= Reasons.LOAN_DECIMALS_CHANGED;
            loanAnswer = loanOk && answer > 0 && uint256(answer) <= loanAnswerBound ? uint256(answer) : 0;
            loanScale = 10 ** uint256(loanFeedDecimals);
        }

        q.reasons |= _tokenReasons(t, stockUpdatedAt);
        q.reasons |= _sequencerReasons(t);

        // Indicative price whenever both answers are in range; usable only if no reason is set.
        if (stockOk && stockAnswer > 0 && uint256(stockAnswer) <= stockAnswerBound && loanAnswer > 0) {
            // (USD per token / 10^sd) / (USD per loan unit / 10^ld) * 1e18, rounded down.
            q.priceWad =
                Math.mulDiv(uint256(stockAnswer), 1e18 * loanScale, loanAnswer * 10 ** uint256(stockFeedDecimals));
        }
    }

    /// @dev Returns the four round checks as bits 0..3 (bad answer, no timestamp, future, stale). Callers
    /// shift them onto the STOCK_* (<< 1) or LOAN_* (<< 7) positions in Reasons.
    function _checkRound(int256 answer, uint256 updatedAt, uint64 t, uint32 maxAge, uint256 bound)
        internal
        pure
        returns (uint32 bits)
    {
        if (answer <= 0 || uint256(answer) > bound) bits |= 1;
        if (updatedAt == 0) bits |= 2;
        else if (updatedAt > t) bits |= 4;
        else if (t - updatedAt > maxAge) bits |= 8;
    }

    function _tokenReasons(uint64 t, uint256 stockUpdatedAt) internal view returns (uint32 bits) {
        try token.oraclePaused() returns (bool paused) {
            if (paused) bits |= Reasons.ISSUER_PAUSED;
        } catch {
            if (pauseFlagRequired) bits |= Reasons.PAUSE_FLAG_UNAVAILABLE;
        }
        if (erc8056) {
            try token.effectiveAt() returns (uint256 effectiveAt) {
                if (effectiveAt != 0 && effectiveAt <= t && stockUpdatedAt < effectiveAt) {
                    bits |= Reasons.MULTIPLIER_LAG;
                }
            } catch {
                bits |= Reasons.MULTIPLIER_UNAVAILABLE;
            }
        }
    }

    function _sequencerReasons(uint64 t) internal view returns (uint32 bits) {
        if (address(sequencerFeed) == address(0)) return 0;
        try sequencerFeed.latestRoundData() returns (uint80, int256 status, uint256 startedAt, uint256, uint80) {
            if (status != 0 || startedAt == 0 || startedAt > t) return Reasons.SEQUENCER_DOWN;
            if (t - startedAt < sequencerGrace) return Reasons.SEQUENCER_GRACE;
        } catch {
            return Reasons.SEQUENCER_DOWN;
        }
    }

    function _latest(IAggregatorV3 feed)
        internal
        view
        returns (bool ok, uint80 roundId, int256 answer, uint256 updatedAt)
    {
        try feed.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80) {
            return (true, r, a, u);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    function _decimalsMatch(IAggregatorV3 feed, uint8 expected) internal view returns (bool) {
        try feed.decimals() returns (uint8 d) {
            return d == expected;
        } catch {
            return false;
        }
    }

    function _gracePending(uint64 t, uint64 stockUpdatedAt) internal view returns (bool) {
        uint64 cp = checkpointAt;
        return cp != 0 && (t < cp + SessionTiming.RECOVERY_GRACE || stockUpdatedAt <= cp);
    }

    function _sessionId(uint64 t) internal view returns (uint32) {
        SessionCalendar.Context memory ctx = calendar.context(t);
        return uint32(ctx.index + 1);
    }

    function _expectDecimals(address source, uint8 expected, uint8 actual) internal pure {
        if (expected != actual) revert DecimalsMismatch(source, expected, actual);
    }
}
