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
/// @notice Decides whether the collateral price can be used right now. It converts the stock feed's USD price
/// into loan tokens per stock token, lists every reason that price cannot be used, and records the reopening
/// admission, outage and recovery checkpoints that SessionRiskPolicy reads (docs/SPEC.md §6 and §9, appendix
/// R3, R4, R11, R12, R14). The guardian (owner) can stop price-dependent actions at once and resume them only
/// after a 24-hour delay. It cannot set prices, thresholds or balances.
/// @dev Units: `priceWad` is loan-token whole units per collateral whole unit, scaled by 1e18. Collateral value
/// in loan-token base units is `raw * priceWad / VALUE_SCALE` with VALUE_SCALE = 10^(tokenDecimals + 18 -
/// loanDecimals). Feed answers and answer bounds are in each feed's own decimals (8 for the Robinhood feeds).
/// Times are UTC seconds from `clock`; durations are seconds.
///
/// Trust: feeds are trusted for answer and timestamp only within the checks in `_sourceQuote`; session status
/// comes from `calendar`, since AggregatorV3 feeds carry none. Every address, decimal and limit is immutable and
/// comes from the deployment manifest. The Robinhood stock feeds already include the ERC-8056 multiplier, so raw
/// balances are valued directly. Feed, token and sequencer reads use try/catch, so a reverting source sets a
/// reason bit instead of reverting (a reverting pause flag that the manifest does not require sets none); a call
/// whose return data cannot be decoded (for example a call to an address without code) still reverts the whole
/// read.
///
/// Records kept by `refresh` for the current calendar session (docs/SPEC.md §6 "Reopening decision"):
/// - admission: the first refresh inside a covered session with a valid source, no stop, no pending checkpoint,
///   a clock at or after O + 5 minutes and a stock update at or after O + 1 minute records `admissionAt`;
/// - interrupted recovery: an invalid source or a stop seen before `SessionTiming.creditAt` clears the
///   admission, which starts over once the source is valid again;
/// - outage: an invalid source or a stop seen after credit has returned marks the session; the next valid
///   in-session refresh clears the mark and records a recovery checkpoint. The mark lapses at the next session;
/// - checkpoint: recorded by that recovery or by `resume`. Prices stay unusable until RECOVERY_GRACE (5 minutes)
///   has passed and the stock feed has updated after the checkpoint.
/// A failure that no refresh observes leaves no record.
contract PriceGate is Ownable2Step {
    /// @notice One AggregatorV3 price feed and the checks applied to its answers.
    struct Feed {
        IAggregatorV3 feed; // the feed contract
        uint8 decimals; // expected answer decimals, checked against feed.decimals()
        uint32 maxAge; // seconds; a reading older than this is stale
        uint256 answerBound; // largest accepted answer, in the feed's own decimals (appendix R12)
    }

    /// @notice Deployment manifest for one gate. Every field is fixed at construction (docs/SPEC.md §6).
    struct Config {
        address token; // collateral stock token
        uint8 tokenDecimals; // must equal token.decimals()
        bool pauseFlagRequired; // a reverting oraclePaused() makes prices unusable (appendix R4)
        bool erc8056; // the token implements ERC-8056 and effectiveAt() is checked (appendix R11)
        address loanToken; // token the market lends (USDG)
        uint8 loanDecimals; // must equal loanToken.decimals() and be at most tokenDecimals + 18
        Feed stockFeed; // stock token price in USD
        Feed loanFeed; // feed == address(0): labelled 1:1 test peg, allowed on test chains only
        string pegLabel; // required with the peg, ignored when a loan feed is set
        IAggregatorV3 sequencerFeed; // address(0): no sequencer uptime feed configured
        uint32 sequencerGrace; // seconds after a sequencer restart during which prices stay unusable
        IClock clock; // time source (DemoClock on demo deployments)
        SessionCalendar calendar; // UTC session schedule
        address guardian; // initial owner, who may stop and resume the gate
    }

    /// @notice A price reading and every reason it cannot be used. `priceWad` is computed whenever the stock
    /// answer and, with a loan feed, the loan answer are positive and within their bounds, so it can be non-zero
    /// while `reasons` is non-zero; it is usable only when `reasons` is zero.
    struct Quote {
        uint256 priceWad; // WAD loan-token whole units per collateral whole unit, rounded down; zero if unknown
        uint80 roundId; // stock feed round id; zero if the feed call failed
        uint64 updatedAt; // stock feed timestamp, UTC seconds, capped at 2^64 - 1; zero if the feed call failed
        uint32 reasons; // Reasons bits; zero means usable
    }

    /// @notice Chain id of a local development chain, where the 1:1 test peg is allowed.
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    /// @notice Chain id of Robinhood Chain testnet (as listed in appendix R6), where the labelled 1:1 test peg is
    /// allowed (docs/SPEC.md §6).
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    /// @notice Collateral stock token; read for its issuer pause flag and, for ERC-8056 tokens, `effectiveAt`.
    IStockToken public immutable token;
    /// @notice Decimals of the collateral token (18 for Robinhood Stock Tokens).
    uint8 public immutable tokenDecimals;
    /// @notice True when a reverting `oraclePaused()` call makes prices unusable; false for a token version
    /// without the flag (appendix R4).
    bool public immutable pauseFlagRequired;
    /// @notice True when the token implements ERC-8056 and `effectiveAt()` is checked for multiplier lag
    /// (appendix R11).
    bool public immutable erc8056;
    /// @notice Token the market lends (USDG); prices are quoted in its whole units.
    address public immutable loanToken;
    /// @notice Decimals of the loan token (6 for USDG).
    uint8 public immutable loanDecimals;
    /// @notice AggregatorV3 feed for the stock token's USD price (MockAggregatorV3 on demo deployments); the
    /// Robinhood Chainlink feeds already include the token multiplier.
    IAggregatorV3 public immutable stockFeed;
    /// @notice Expected decimals of stock feed answers (8 for the Robinhood feeds).
    uint8 public immutable stockFeedDecimals;
    /// @notice Largest accepted age of a stock feed reading, in seconds (appendix R3).
    uint32 public immutable stockMaxAge;
    /// @notice Largest accepted stock feed answer, in the feed's decimals (appendix R12).
    uint256 public immutable stockAnswerBound;
    /// @notice Chainlink feed for the loan token's USD price, or address(0) for the labelled 1:1 test peg.
    IAggregatorV3 public immutable loanFeed;
    /// @notice Expected decimals of loan feed answers; unused with the peg.
    uint8 public immutable loanFeedDecimals;
    /// @notice Largest accepted age of a loan feed reading, in seconds; unused with the peg.
    uint32 public immutable loanMaxAge;
    /// @notice Largest accepted loan feed answer, in the feed's decimals; unused with the peg.
    uint256 public immutable loanAnswerBound;
    /// @notice Optional L2 sequencer uptime feed; address(0) when none is configured (appendix R14).
    IAggregatorV3 public immutable sequencerFeed;
    /// @notice Seconds after a sequencer restart during which prices stay unusable.
    uint32 public immutable sequencerGrace;
    /// @notice Time source for every check (DemoClock on demo deployments).
    IClock public immutable clock;
    /// @notice UTC session schedule that bounds admissions and outages.
    SessionCalendar public immutable calendar;
    /// @notice Divisor that turns raw collateral times `priceWad` into loan-token base units:
    /// 10^(tokenDecimals + 18 - loanDecimals), which is 1e30 for an 18-decimal stock token and 6-decimal USDG.
    uint256 public immutable VALUE_SCALE;
    /// @notice Label of the 1:1 test peg; empty when a loan feed is configured.
    string public pegLabel;

    /// @notice Most recently admitted session, as calendar index + 1; zero when none or after an admission reset.
    /// It is not cleared when a new session starts, so `admissionFor` compares it with the session asked about.
    uint32 public admittedSession;
    /// @notice Clock time of the admission of `admittedSession`, UTC seconds; zero after an admission reset.
    uint64 public admissionAt;
    /// @notice Session (calendar index + 1) in which an invalid source or a stop was seen after new credit had
    /// returned, with no valid in-session refresh or resume since; zero when none. It lapses when the next
    /// session opens: `quote` ignores it from then on and the next `refresh` clears it.
    uint32 public outageSession;
    /// @notice Clock time of the latest recovery checkpoint (source recovery or guardian resume), UTC seconds;
    /// zero when none has been recorded. The first refresh after its grace has ended clears it; until that
    /// refresh the ended checkpoint stays stored but no longer holds prices.
    uint64 public checkpointAt;

    /// @notice True while the guardian's stop is in force; every quote then carries Reasons.STOPPED.
    bool public stopped;
    /// @notice Clock time from which `resume` succeeds, UTC seconds; zero when no resume is requested.
    uint64 public resumeAvailableAt;

    /// @notice Price of the last quote that `refresh` found fully usable, WAD loan-token whole units per
    /// collateral whole unit; zero until a refresh accepts one. StockReefMarket.bookValuation uses it, flagged as
    /// indicative, while the current quote is unusable.
    uint256 public lastPriceWad;
    /// @notice Stock feed timestamp of that last usable quote, UTC seconds; zero until a refresh accepts one.
    uint64 public lastUpdatedAt;
    /// @notice Clock time of the refresh that accepted that last usable quote, UTC seconds; zero until a refresh
    /// accepts one.
    uint64 public lastAcceptedAt;

    /// @notice A reopening price was admitted for a session.
    /// @param session Calendar index of the session.
    /// @param admissionAt Clock time of the admission, UTC seconds.
    /// @param priceUpdatedAt Stock feed timestamp of the admitted price, UTC seconds.
    event Admitted(uint256 indexed session, uint64 admissionAt, uint64 priceUpdatedAt);
    /// @notice An invalid source or a stop interrupted the reopening recovery; admission starts over.
    /// @param session Calendar index of the session.
    /// @param at Clock time of the reset, UTC seconds.
    /// @param reasons Source Reasons bits, plus STOPPED when stopped, seen by that refresh.
    event AdmissionReset(uint256 indexed session, uint64 at, uint32 reasons);
    /// @notice An invalid source or a stop was seen after new credit had returned in this session.
    /// @param session Calendar index of the session.
    /// @param at Clock time of the detection, UTC seconds.
    /// @param reasons Source Reasons bits, plus STOPPED when stopped, seen by that refresh.
    event OutageDetected(uint256 indexed session, uint64 at, uint32 reasons);
    /// @notice A recovery checkpoint was recorded. Prices stay unusable until RECOVERY_GRACE has passed and the
    /// stock feed has updated after it.
    /// @param at Clock time of the checkpoint, UTC seconds.
    event RecoveryCheckpoint(uint64 at);
    /// @notice The guardian stopped price-dependent actions.
    /// @param at Clock time of the stop, UTC seconds.
    event Stopped(uint64 at);
    /// @notice The guardian started the resume delay.
    /// @param at Clock time of the request, UTC seconds.
    /// @param availableAt Earliest clock time at which `resume` succeeds, UTC seconds.
    event ResumeRequested(uint64 at, uint64 availableAt);
    /// @notice The guardian lifted the stop. A RecoveryCheckpoint at the same time follows.
    /// @param at Clock time of the resume, UTC seconds.
    event Resumed(uint64 at);

    /// @notice A token or feed reports different decimals from the manifest (deployment only).
    /// @param source Token or feed address.
    /// @param expected Decimals given in the manifest.
    /// @param actual Decimals the token or feed reports.
    error DecimalsMismatch(address source, uint8 expected, uint8 actual);
    /// @notice The 1:1 test peg was configured on a chain outside the test-chain allowlist.
    /// @param chainId Chain id of the deployment.
    error PegNotAllowed(uint256 chainId);
    /// @notice The 1:1 test peg was configured without a label.
    error MissingPegLabel();
    /// @notice A required address or limit is zero, or the loan token has more than tokenDecimals + 18 decimals.
    error InvalidConfig();
    /// @notice `requestResume` or `resume` was called while the gate is not stopped.
    error NotStopped();
    /// @notice `resume` was called without a pending resume request.
    error ResumeNotRequested();
    /// @notice `resume` was called before the resume delay ended.
    /// @param availableAt Earliest clock time at which `resume` succeeds, UTC seconds.
    error ResumeTooEarly(uint64 availableAt);
    /// @notice Ownership cannot be renounced.
    error RenounceDisabled();

    /// @notice Deploys a gate from a deployment manifest; `c.guardian` becomes the owner.
    /// @dev Checks that the token, loan token, stock feed, clock and calendar are set, that the stock feed's
    /// maxAge and answer bound are non-zero, that loanDecimals <= tokenDecimals + 18, and that the token, loan
    /// token and stock feed report the manifest's decimals. With `c.loanFeed.feed == address(0)` the 1:1 peg is
    /// used: only on LOCAL_CHAIN_ID or ROBINHOOD_TESTNET_CHAIN_ID and only with a label; the loan feed's other
    /// fields are then stored unchecked. Otherwise the loan feed's maxAge, answer bound and decimals are checked
    /// the same way. The sequencer feed and grace are not checked. Reverts with InvalidConfig, DecimalsMismatch,
    /// PegNotAllowed, MissingPegLabel, or OwnableInvalidOwner for a zero guardian; a token or feed without
    /// `decimals()` reverts the deployment.
    /// @param c Deployment manifest; see `Config`.
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

    /// @notice The current quote with every reason it cannot be used, including gate state. Changes nothing.
    /// @dev Adds STOPPED, OUTAGE_UNRESOLVED (an outage is recorded for the current session) and RECOVERY_GRACE
    /// to the source reasons. It does not apply the transitions `refresh` would record, so it can differ from a
    /// refresh at the same time: it still reports OUTAGE_UNRESOLVED where a refresh would record a recovery
    /// checkpoint and report RECOVERY_GRACE, and it never records an admission, so views show the reopening
    /// wait until someone refreshes. SessionRiskPolicy.snapshot and StockReefMarket.bookValuation use it. A
    /// reverting source sets a reason instead of reverting; a reverting clock or calendar call, or a source whose
    /// return data does not decode, reverts it.
    /// @return q The quote; `q.priceWad` is usable only when `q.reasons` is zero.
    function quote() public view returns (Quote memory q) {
        uint64 t = clock.time();
        q = _sourceQuote(t);
        if (stopped) q.reasons |= Reasons.STOPPED;
        if (outageSession != 0 && outageSession == _sessionId(t)) q.reasons |= Reasons.OUTAGE_UNRESOLVED;
        if (_gracePending(t, q.updatedAt)) q.reasons |= Reasons.RECOVERY_GRACE;
    }

    /// @notice Admission time recorded for session `index`, or zero if that session has none.
    /// @dev Only the most recently admitted session keeps its time; earlier sessions return zero. Reverts with an
    /// arithmetic panic for `index` = type(uint256).max.
    /// @param index Calendar session index.
    /// @return Clock time of the admission, UTC seconds, or zero.
    function admissionFor(uint256 index) external view returns (uint64) {
        return admittedSession == index + 1 ? admissionAt : 0;
    }

    /// @notice True when the price source uses the labelled test peg instead of a loan-token feed.
    /// @dev With the peg, `pegLabel` names it and the loan feed fields are unused.
    /// @return True when `loanFeed` is address(0), so one loan-token whole unit is valued at one USD.
    function usesPeg() external view returns (bool) {
        return address(loanFeed) == address(0);
    }

    /// @notice Collateral value in loan-token base units, rounded down.
    /// @dev `raw * priceWad / VALUE_SCALE` in full precision; reverts if the result overflows uint256.
    /// @param raw Collateral amount in raw stock-token units.
    /// @param priceWad Price in WAD loan-token whole units per collateral whole unit.
    /// @return Value in loan-token base units, rounded down.
    function valueOf(uint256 raw, uint256 priceWad) public view returns (uint256) {
        return Math.mulDiv(raw, priceWad, VALUE_SCALE);
    }

    /// @notice Raw collateral worth `value` loan-token base units at `priceWad`.
    /// @dev `value * VALUE_SCALE / priceWad` in full precision; reverts when `priceWad` is zero or the result
    /// overflows uint256.
    /// @param value Value in loan-token base units.
    /// @param priceWad Price in WAD loan-token whole units per collateral whole unit; must be non-zero.
    /// @param rounding Rounding direction (Math.Rounding); use Ceil for collateral a borrower must add.
    /// @return Collateral amount in raw stock-token units, rounded as `rounding` asks.
    function rawForValue(uint256 value, uint256 priceWad, Math.Rounding rounding) public view returns (uint256) {
        return Math.mulDiv(value, VALUE_SCALE, priceWad, rounding);
    }

    // ---------------------------------------------------------------- refresh

    /// @notice Record reopening admission, outages and recovery checkpoints for the current session and the last
    /// accepted price, then return the current quote. Permissionless; every price-dependent entry point calls it
    /// first.
    /// @dev First drops an outage mark from an earlier session and a checkpoint whose grace has ended. Then,
    /// only inside a session with a known next open, it acts on the source reasons plus STOPPED:
    /// - valid, with an outage marked this session: clears the mark and records a recovery checkpoint now;
    /// - valid, not yet admitted, no pending checkpoint, now >= O + ADMIT_AFTER and the stock feed stamped at or
    ///   after O + FRESH_AFTER: records the admission now (docs/SPEC.md §6 steps 1, 2 and 4);
    /// - invalid after admission and before SessionTiming.creditAt: clears the admission (interrupted recovery);
    /// - invalid after admission and at or after creditAt: marks an outage for this session unless one is marked;
    /// - invalid before admission: records nothing.
    /// A quote with no reasons left is stored as the last accepted price. If the calling transaction reverts,
    /// these records revert with it, so keepers can also call this function on its own (docs/SPEC.md §6). A
    /// reverting source sets a reason instead of reverting; a reverting clock or calendar call, or a source whose
    /// return data does not decode, reverts it.
    /// @return q The quote with source reasons, STOPPED, OUTAGE_UNRESOLVED and RECOVERY_GRACE; `q.priceWad` is
    /// usable only when `q.reasons` is zero.
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
    /// @dev Guardian (owner) only; reverts with OwnableUnauthorizedAccount otherwise. Allowed in any state, also
    /// when already stopped, and cancels a pending resume request. While stopped every quote carries
    /// Reasons.STOPPED, which SessionRiskPolicy treats as GUARDED in every phase. The market does not consult
    /// the gate for repayment or collateral deposits, so those stay available.
    function stop() external onlyOwner {
        stopped = true;
        resumeAvailableAt = 0;
        emit Stopped(clock.time());
    }

    /// @notice Start the 24-hour resume delay.
    /// @dev Guardian (owner) only; reverts with OwnableUnauthorizedAccount otherwise, and with NotStopped unless
    /// the gate is stopped. Sets `resumeAvailableAt` to the clock time plus SessionTiming.RESUME_DELAY; calling
    /// it again restarts the delay.
    function requestResume() external onlyOwner {
        if (!stopped) revert NotStopped();
        uint64 t = clock.time();
        resumeAvailableAt = t + SessionTiming.RESUME_DELAY;
        emit ResumeRequested(t, resumeAvailableAt);
    }

    /// @notice Resume after the delay. Sets a recovery checkpoint, so prices need a fresh update and a
    /// five-minute grace before price-dependent actions return.
    /// @dev Guardian (owner) only; reverts with OwnableUnauthorizedAccount otherwise. Reverts with NotStopped,
    /// ResumeNotRequested, or ResumeTooEarly while the clock is before `resumeAvailableAt`. Clears the stop, the
    /// request and any outage mark, then records a checkpoint at the clock time. It cannot override feed or
    /// calendar checks (docs/SPEC.md §6), and a reopening admission waits until the checkpoint no longer holds
    /// prices (RECOVERY_GRACE has passed and the stock feed has updated after it).
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

    /// @inheritdoc Ownable
    /// @notice Disabled: always reverts with RenounceDisabled.
    /// @dev A gate without a guardian could never resume after a stop, so ownership only moves through the
    /// two-step transfer.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- internals

    /// @dev Reads the stock feed, the loan feed (or peg), the token flags and the sequencer feed at clock time
    /// `t`, and returns the price-source reasons (bits inside Reasons.SOURCE_MASK). A reverting latestRoundData
    /// sets STOCK_FEED_UNAVAILABLE or LOAN_FEED_UNAVAILABLE; a reverting or different decimals() sets
    /// STOCK_DECIMALS_CHANGED or LOAN_DECIMALS_CHANGED; `_checkRound` supplies the answer and timestamp bits.
    /// `priceWad` is stockAnswer * 1e18 * 10^loanFeedDecimals / (loanAnswer * 10^stockFeedDecimals), rounded
    /// down, using the manifest decimals. The peg values one loan-token whole unit at one USD: it uses
    /// loanAnswer = 10^stockFeedDecimals and 10^stockFeedDecimals in place of 10^loanFeedDecimals, so the price
    /// is stockAnswer * 1e18 / 10^stockFeedDecimals. `priceWad` is set whenever the stock answer and, with a loan
    /// feed, the loan answer are positive and within their bounds, even when other reasons are set. The scale
    /// products use checked arithmetic, so only a manifest with extreme decimals or bounds could make them revert.
    /// @param t Current clock time, UTC seconds.
    /// @return q Quote with source reasons only (no STOPPED, OUTAGE_UNRESOLVED or RECOVERY_GRACE).
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
    /// shift them onto the STOCK_* (<< 1) or LOAN_* (<< 7) positions in Reasons. Bad answer: `answer` <= 0 or
    /// above `bound`. Stale: `t - updatedAt > maxAge`, so an age of exactly `maxAge` passes. The timestamp bits
    /// are exclusive: no timestamp, else future, else stale.
    /// @param answer Feed answer, in the feed's decimals.
    /// @param updatedAt Round timestamp, UTC seconds.
    /// @param t Current clock time, UTC seconds.
    /// @param maxAge Largest accepted age, seconds.
    /// @param bound Largest accepted answer, in the feed's decimals.
    /// @return bits The failed checks; zero when the round passes.
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

    /// @dev Issuer and multiplier checks (appendix R4, R11). ISSUER_PAUSED when `oraclePaused()` is true;
    /// PAUSE_FLAG_UNAVAILABLE when that call reverts and the flag is required (ignored otherwise). For ERC-8056
    /// tokens, MULTIPLIER_LAG when `effectiveAt` is non-zero, at or before `t` and later than the stock feed's
    /// timestamp; MULTIPLIER_UNAVAILABLE when `effectiveAt()` reverts.
    /// @param t Current clock time, UTC seconds.
    /// @param stockUpdatedAt Stock feed timestamp, UTC seconds; zero when the feed call failed.
    /// @return bits Reasons bits.
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

    /// @dev Sequencer uptime check (appendix R14); zero when no uptime feed is configured. As in Chainlink's
    /// uptime feeds, answer 0 means up and `startedAt` is when the status last changed. Returns SEQUENCER_DOWN
    /// when the answer is non-zero, `startedAt` is zero or after `t`, or the call reverts; SEQUENCER_GRACE when
    /// the sequencer came up less than `sequencerGrace` seconds before `t`.
    /// @param t Current clock time, UTC seconds.
    /// @return bits Reasons bits.
    function _sequencerReasons(uint64 t) internal view returns (uint32 bits) {
        if (address(sequencerFeed) == address(0)) return 0;
        try sequencerFeed.latestRoundData() returns (uint80, int256 status, uint256 startedAt, uint256, uint80) {
            if (status != 0 || startedAt == 0 || startedAt > t) return Reasons.SEQUENCER_DOWN;
            if (t - startedAt < sequencerGrace) return Reasons.SEQUENCER_GRACE;
        } catch {
            return Reasons.SEQUENCER_DOWN;
        }
    }

    /// @dev Reads `feed.latestRoundData()`; returns `ok = false` and zeros when the call reverts.
    /// @param feed Feed to read.
    /// @return ok False when the call reverted.
    /// @return roundId Latest round id.
    /// @return answer Latest answer, in the feed's decimals.
    /// @return updatedAt Latest round timestamp, UTC seconds.
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

    /// @dev True when `feed.decimals()` equals `expected`; false when it differs or the call reverts.
    /// @param feed Feed to read.
    /// @param expected Decimals given in the manifest.
    /// @return True when the feed reports `expected`.
    function _decimalsMatch(IAggregatorV3 feed, uint8 expected) internal view returns (bool) {
        try feed.decimals() returns (uint8 d) {
            return d == expected;
        } catch {
            return false;
        }
    }

    /// @dev True while a recovery checkpoint holds prices: a checkpoint is recorded and either less than
    /// RECOVERY_GRACE (5 minutes) has passed since it, or the stock feed has not updated strictly after it.
    /// @param t Current clock time, UTC seconds.
    /// @param stockUpdatedAt Stock feed timestamp of the quote being checked, UTC seconds.
    /// @return True while the checkpoint holds prices; false when none is recorded or it has ended.
    function _gracePending(uint64 t, uint64 stockUpdatedAt) internal view returns (bool) {
        uint64 cp = checkpointAt;
        return cp != 0 && (t < cp + SessionTiming.RECOVERY_GRACE || stockUpdatedAt <= cp);
    }

    /// @dev Session id in the form the admission and outage records use (`refresh` computes it inline): the
    /// calendar index at `t` plus one. `quote` uses it for the outage check. The calendar reports index zero
    /// before its first open and from its last close, so those times map to 1.
    /// @param t Clock time, UTC seconds.
    /// @return Calendar index at `t` plus one.
    function _sessionId(uint64 t) internal view returns (uint32) {
        SessionCalendar.Context memory ctx = calendar.context(t);
        return uint32(ctx.index + 1);
    }

    /// @dev Reverts with DecimalsMismatch when `actual` differs from `expected` (deployment checks).
    /// @param source Token or feed address, reported in the error.
    /// @param expected Decimals given in the manifest.
    /// @param actual Decimals the token or feed reports.
    function _expectDecimals(address source, uint8 expected, uint8 actual) internal pure {
        if (expected != actual) revert DecimalsMismatch(source, expected, actual);
    }
}
