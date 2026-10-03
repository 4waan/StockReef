// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SessionCalendar
/// @notice The fixed list of scheduled US regular trading sessions, as UTC open and close times, that tells the
/// market when the stock trades and when it is closed. It is generated off-chain from NYSE's published holidays and
/// early closes by tools/calendar/gen_sessions.py, which converts 09:30 to 16:00 America/New_York (13:00 on
/// early-close days) to UTC with a pinned tzdata release (docs/SPEC.md §3 "Calendar implementation"). Outside the
/// loaded coverage the calendar reports `covered = false` and callers fail closed (docs/SPEC.md §3, appendix R17).
/// @dev Storage: four sessions per uint256 word; session k of a word occupies bits [64k, 64k + 63] as
/// (open << 32) | close, both UTC seconds, so every time is limited to 32 bits. Lookups are binary searches over
/// the opens, O(log sessionCount) storage reads.
///
/// Invariants checked by the constructor: at least one session, exactly ceil(count / 4) words, 0 < open < close for
/// every session, and every close strictly before the next open. The contract trusts the generator for everything
/// else (weekdays, holidays, early closes, DST) and does not require the unused slots of the last word to be zero.
///
/// Trust: there is no owner and no setter, so the schedule cannot change after deployment. It covers scheduled
/// sessions only; it does not predict unscheduled halts, and an emergency closure uses the PriceGate guardian stop
/// (docs/SPEC.md §3). Coverage ends at `lastOpen`, since the last loaded session has no known next open. From then
/// on SessionRiskPolicy reports the market as GUARDED and in wind-down, and a continuing market is a new deployment
/// with a longer calendar (appendix R17).
contract SessionCalendar {
    /// @notice Where one time falls in the schedule, as returned by `context`.
    /// @dev Before `firstOpen` and from `lastClose` every field is zero. From `lastOpen` until `lastClose` the fields
    /// describe the last session but `covered` is false and `nextOpen` is zero. All times are UTC seconds.
    struct Context {
        bool covered; // false before the first open, at or after the last close, or with no known next open
        bool inSession; // open <= t < close
        uint256 index; // the session containing t, or the last one that closed at or before t; 0 outside the list
        uint64 open; // open of `index`, UTC seconds
        uint64 close; // close of `index`, UTC seconds
        uint64 prevClose; // close of index - 1, UTC seconds (0 for the first session)
        uint64 nextOpen; // open of index + 1, UTC seconds (0 when `covered` is false)
    }

    /// @notice Number of loaded sessions. Valid session indexes are 0 to sessionCount - 1.
    uint256 public immutable sessionCount;
    /// @notice Open of the first loaded session, UTC seconds. Coverage starts here.
    uint64 public immutable firstOpen;
    /// @notice Close of the last loaded session, UTC seconds. `context` returns an all-zero result from here on.
    uint64 public immutable lastClose;
    /// @notice Open of the last loaded session, UTC seconds. Coverage ends here: that session has no known next
    /// open, so `context` reports `covered = false` from this time (appendix R17). The deploy script passes it to
    /// DemoController as `latest`, which rejects demo steps that would move the clock past it (appendix R18);
    /// DemoClock time still advances with block time.
    uint64 public immutable lastOpen;

    /// @dev Packed sessions, four per word; see the contract @dev for the bit layout.
    uint256[] private _words;

    /// @notice The constructor was given zero sessions.
    error EmptyCalendar();
    /// @notice The number of packed words is not ceil(sessions / 4).
    /// @param words Number of packed words supplied.
    /// @param sessions Session count supplied.
    error WordCountMismatch(uint256 words, uint256 sessions);
    /// @notice A session does not open strictly after the previous close (or after time zero for the first
    /// session), or does not close strictly after its open.
    /// @param index Index of the first session that breaks the order.
    error SessionsNotOrdered(uint256 index);

    /// @notice Stores the packed schedule and checks that it is non-empty and strictly ordered.
    /// @dev Reverts with EmptyCalendar when `count` is zero, WordCountMismatch when `words.length` is not
    /// ceil(count / 4), and SessionsNotOrdered(i) at the first session i that fails prevClose < open < close
    /// (prevClose is 0 for session 0). Unused slots of the last word are not checked. Deployments pass the
    /// `packed` and `count` fields of tools/calendar/sessions.json.
    /// @param words Packed sessions, four per word: session k of a word in bits [64k, 64k + 63] as
    /// (open << 32) | close, UTC seconds.
    /// @param count Number of sessions in `words`.
    constructor(uint256[] memory words, uint256 count) {
        if (count == 0) revert EmptyCalendar();
        if (words.length != (count + 3) / 4) revert WordCountMismatch(words.length, count);
        _words = words;
        sessionCount = count;

        uint64 prev;
        for (uint256 i; i < count; ++i) {
            (uint64 o, uint64 c) = _unpack(words[i / 4], i % 4);
            if (!(prev < o && o < c)) revert SessionsNotOrdered(i);
            prev = c;
        }
        (firstOpen,) = _unpack(words[0], 0);
        (lastOpen, lastClose) = _unpack(words[(count - 1) / 4], (count - 1) % 4);
    }

    /// @notice Open and close of session `i`, UTC seconds. Callable by anyone at any time.
    /// @dev Does not check `i` against `sessionCount`. An index past the last word reverts with an array
    /// out-of-bounds panic; an index in the unused tail of the last word returns that slot's bits (zero for
    /// calendars from the generator). Callers must check `i < sessionCount` first, as `context` and StockReefLens do.
    /// @param i Session index, 0 to sessionCount - 1.
    /// @return open Scheduled open, UTC seconds.
    /// @return close Scheduled close, UTC seconds.
    function sessionAt(uint256 i) public view returns (uint64 open, uint64 close) {
        return _unpack(_words[i / 4], i % 4);
    }

    /// @notice Where `t` falls relative to the schedule: the current or most recent session, whether it is in
    /// session, the previous close and the next open. Never reverts.
    /// @dev Before `firstOpen` or from `lastClose` it returns an all-zero Context. Otherwise a binary search finds
    /// the largest index whose open is at or before `t`; `inSession` is `t < close`, so a session covers
    /// [open, close) and a time between sessions maps to the session that closed before it. `covered` and
    /// `nextOpen` are set only when a next session exists, so from `lastOpen` the result is not covered.
    /// PriceGate.refresh records admissions, outages and recovery checkpoints only when `covered` and `inSession`
    /// are both true, and SessionRiskPolicy reports GUARDED whenever `covered` is false (docs/SPEC.md §3).
    /// @param t Time to look up, UTC seconds.
    /// @return c The position of `t` in the schedule; see Context for the fields.
    function context(uint64 t) external view returns (Context memory c) {
        if (t < firstOpen || t >= lastClose) return c;

        // Largest index with open <= t.
        uint256 lo;
        uint256 hi = sessionCount - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            (uint64 o,) = sessionAt(mid);
            if (o <= t) lo = mid;
            else hi = mid - 1;
        }

        c.index = lo;
        (c.open, c.close) = sessionAt(lo);
        c.inSession = t < c.close;
        if (lo > 0) (, c.prevClose) = sessionAt(lo - 1);
        if (lo + 1 < sessionCount) {
            (c.nextOpen,) = sessionAt(lo + 1);
            c.covered = true;
        }
    }

    /// @dev Reads slot `k` (0 to 3) of a packed word: bits [64k, 64k + 31] are the close and bits
    /// [64k + 32, 64k + 63] the open, both UTC seconds.
    /// @param word Packed word holding four sessions.
    /// @param k Slot within the word, 0 to 3.
    /// @return open Scheduled open, UTC seconds.
    /// @return close Scheduled close, UTC seconds.
    function _unpack(uint256 word, uint256 k) private pure returns (uint64 open, uint64 close) {
        uint64 packed = uint64(word >> (64 * k));
        open = packed >> 32;
        close = packed & 0xffffffff;
    }
}
