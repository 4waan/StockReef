#!/usr/bin/env python3
"""Generate the StockReef regular-session calendar.

Reads nyse_holidays.json, builds every regular session (open, close) in UTC seconds for the coverage
range using the IANA America/New_York zone from the pinned `tzdata` package, and writes sessions.json.
Sessions are also packed for SessionCalendar: four sessions per uint256 word, session k of a word in
bits [64k, 64k+63], each session as (open << 32) | close.

    python tools/calendar/gen_sessions.py          # write sessions.json
    python tools/calendar/gen_sessions.py --check  # fail if sessions.json is out of date
"""
import json
import sys
import zoneinfo
from datetime import date, datetime, time, timedelta
from pathlib import Path

import tzdata  # pinned in tools/requirements.txt

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "nyse_holidays.json"
OUTPUT = HERE / "sessions.json"

# Use only the pinned tzdata package, never the host's zoneinfo directory.
zoneinfo.reset_tzpath(to=[])
ET = zoneinfo.ZoneInfo("America/New_York")


def hhmm(s: str) -> time:
    h, m = s.split(":")
    return time(int(h), int(m))


def utc_seconds(d: date, t: time) -> int:
    return int(datetime.combine(d, t, tzinfo=ET).timestamp())


def build() -> dict:
    src = json.loads(SOURCE.read_text())
    closed = {date.fromisoformat(d) for d in src["closed"]}
    early = {date.fromisoformat(d) for d in src["early_close_days"]}
    assert not closed & early, "a day cannot be both closed and an early close"
    first = date.fromisoformat(src["coverage"]["first_day"])
    last = date.fromisoformat(src["coverage"]["last_day"])
    t_open, t_close, t_early = hhmm(src["regular_open"]), hhmm(src["regular_close"]), hhmm(src["early_close"])

    sessions = []
    d = first
    while d <= last:
        if d.weekday() < 5 and d not in closed:
            close_t = t_early if d in early else t_close
            sessions.append([utc_seconds(d, t_open), utc_seconds(d, close_t)])
        d += timedelta(days=1)

    for (o, c), (o2, _) in zip(sessions, sessions[1:]):
        assert o < c < o2, "sessions must be strictly ordered and non-overlapping"
    assert sessions[-1][1] < 2**32, "timestamps must fit in uint32"

    words = []
    for i in range(0, len(sessions), 4):
        w = 0
        for k, (o, c) in enumerate(sessions[i : i + 4]):
            w |= ((o << 32) | c) << (64 * k)
        words.append("0x%064x" % w)

    return {
        "source": src["source"],
        "timezone": "America/New_York",
        "tzdata": tzdata.IANA_VERSION,
        "count": len(sessions),
        "first_open": sessions[0][0],
        "last_close": sessions[-1][1],
        "sessions": sessions,
        "opens": [o for o, _ in sessions],
        "closes": [c for _, c in sessions],
        "packed": words,
    }


def main() -> int:
    data = json.dumps(build(), indent=1) + "\n"
    if "--check" in sys.argv:
        if not OUTPUT.exists() or OUTPUT.read_text() != data:
            print("sessions.json is out of date; run tools/calendar/gen_sessions.py", file=sys.stderr)
            return 1
        print("sessions.json is up to date")
        return 0
    OUTPUT.write_text(data)
    print(f"wrote {OUTPUT.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
