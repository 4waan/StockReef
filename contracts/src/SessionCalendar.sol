// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SessionCalendar
/// @notice Immutable list of scheduled US regular sessions in UTC, generated off-chain from NYSE's published
/// holidays and early closes (tools/calendar/gen_sessions.py). Lookups are binary searches over the list.
/// Outside the loaded coverage the calendar reports `covered = false` and callers fail closed.
/// @dev Four sessions per storage word; session k of a word occupies bits [64k, 64k + 63] as
/// (open << 32) | close, both UTC seconds.
contract SessionCalendar {
    struct Context {
        bool covered; // false before the first open, at or after the last close, or with no known next open
        bool inSession; // open <= t < close
        uint256 index; // the session containing t, or the last session that closed before t
        uint64 open; // open of `index`
        uint64 close; // close of `index`
        uint64 prevClose; // close of index - 1 (0 for the first session)
        uint64 nextOpen; // open of index + 1
    }

    uint256 public immutable sessionCount;
    uint64 public immutable firstOpen;
    uint64 public immutable lastClose;
    /// @notice Open of the last loaded session. Coverage ends here: that session has no known next open.
    uint64 public immutable lastOpen;

    uint256[] private _words;

    error EmptyCalendar();
    error WordCountMismatch(uint256 words, uint256 sessions);
    error SessionsNotOrdered(uint256 index);

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

    /// @notice Open and close of session `i`.
    function sessionAt(uint256 i) public view returns (uint64 open, uint64 close) {
        return _unpack(_words[i / 4], i % 4);
    }

    /// @notice Where `t` falls relative to the schedule.
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

    function _unpack(uint256 word, uint256 k) private pure returns (uint64 open, uint64 close) {
        uint64 packed = uint64(word >> (64 * k));
        open = packed >> 32;
        close = packed & 0xffffffff;
    }
}
