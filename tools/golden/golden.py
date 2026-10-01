#!/usr/bin/env python3
"""Independent golden values for StockReef.

Everything here is computed with exact rational arithmetic (fractions.Fraction) or high-precision
decimals, never with the Solidity implementation. Foundry tests read golden.json and assert the
contracts reproduce these numbers within the stated integer tolerance.

Units follow the contracts:
  * USDG amounts in base units (6 decimals)
  * stock token amounts in raw units (18 decimals)
  * ratios and prices as WAD (1e18)

    python tools/golden/golden.py          # write golden.json
    python tools/golden/golden.py --check  # fail if golden.json is out of date
"""
import json
import sys
from decimal import Decimal, getcontext
from fractions import Fraction as F
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "golden.json"

WAD = 10**18
USDG = 10**6
TOKEN = 10**18

# Illustrative policy fixtures (docs/SPEC.md §3 and appendix R1)
LT_OPEN = F(80, 100)
B_OPEN = F(75, 100)
TARGET_OPEN = F(75, 100)
BORROW_GAP = F(5, 100)
BONUS_SCHEDULING = F(2, 100)
BONUS_DISTRESS = F(5, 100)
RECOVERY_HAIRCUT = F(5, 100)  # lender valuation: recoverable = min(debt, value / 1.05)
CLASSES = {
    "EXTENDED": {"lt_final": F(70, 100), "target": F(65, 100)},
    "OVERNIGHT": {"lt_final": F(77, 100), "target": F(72, 100)},
}
PREP = 120 * 60  # A = C - 120 min
FINAL = 30 * 60  # F = C - 30 min
RATE_ANNUAL = F(10, 100)
YEAR = 365 * 24 * 3600


def ceil(x: F) -> int:
    return -((-x.numerator) // x.denominator)


def floor(x: F) -> int:
    return x.numerator // x.denominator


def wad(x: F) -> int:
    """Exact WAD representation; asserts the value is representable."""
    v = x * WAD
    assert v.denominator == 1, f"{x} is not exactly representable in WAD"
    return int(v)


def lt_at(lt_final: F, a: int, f: int, t: int) -> int:
    """LT during PRE_CLOSE as the contract computes it: the decrement is rounded up (LT rounds down)."""
    if t <= a:
        return wad(LT_OPEN)
    if t >= f:
        return wad(lt_final)
    dec = ceil((LT_OPEN - lt_final) * WAD * (t - a) / (f - a))
    return wad(LT_OPEN) - dec


def borrow_limit(lt_wad: int) -> int:
    return min(wad(B_OPEN), lt_wad - wad(BORROW_GAP))


def worked_example(collateral_raw: int = 25 * TOKEN, debt: int = 7_200 * USDG) -> dict:
    """Spec §5: V = 10,000 USDG, D = 7,200 USDG, Friday 16:00 close (EXTENDED class).

    The testnet demo uses the same case scaled by 1/100 (appendix R7)."""
    price = F(400)  # USDG per whole TSLA token
    value = floor(F(collateral_raw) * price * USDG / TOKEN)
    cls = CLASSES["EXTENDED"]
    target = cls["target"]
    b = BONUS_SCHEDULING

    cash_required = max(0, ceil(F(debt) - target * value))
    add_collateral_value = max(0, ceil(F(debt) / target - value))

    x_exact = (F(debt) - target * value) / (1 - target * (1 + b))
    x = ceil(x_exact)
    seized_value = F(x) * (1 + b)
    seized_raw = floor(seized_value * TOKEN / (price * USDG))
    debt_after = debt - x
    coll_after = collateral_raw - seized_raw
    value_after = floor(F(coll_after) * price * USDG / TOKEN)

    # LT at 15:15 for a 16:00 close: A = 14:00, F = 15:30 (offsets relative to C)
    c = 0
    a, f = c - PREP, c - FINAL
    t_1515 = c - 45 * 60
    lt_1515 = lt_at(cls["lt_final"], a, f, t_1515)

    # Simplified gap outcomes from spec §5 (35% gap, 5% recovery bonus), in USDG with 2 decimals
    gap = F(35, 100)
    def shortfall(d, v):
        return max(F(0), F(d) - F(v) * (1 - gap) / (1 + BONUS_DISTRESS))
    x_units = x_exact / USDG
    d_units, v_units = F(debt, USDG), F(value, USDG)
    trimmed_exact = shortfall(d_units - x_units, v_units - x_units * (1 + b))
    unmanaged_exact = shortfall(d_units, v_units)

    return {
        "price_wad": str(wad(price)),
        "collateral_raw": str(collateral_raw),
        "value_usdg": str(value),
        "debt_usdg": str(debt),
        "target_wad": str(wad(target)),
        "bonus_wad": str(wad(b)),
        "cash_required_usdg": str(cash_required),
        "add_collateral_value_usdg": str(add_collateral_value),
        "trim_repay_usdg": str(x),
        "trim_seized_raw": str(seized_raw),
        "trim_seized_value_usdg_exact": str(float(seized_value / USDG)),
        "debt_after_trim_usdg": str(debt_after),
        "collateral_after_trim_raw": str(coll_after),
        "value_after_trim_usdg": str(value_after),
        "ltv_after_trim_wad_floor": str(floor(F(debt_after) * WAD / value_after)),
        "lt_at_1515_wad": str(lt_1515),
        "eligible_at_1515": F(debt) / value > F(lt_1515, WAD),
        "gap35_shortfall_trimmed_usdg_2dp": f"{float(trimmed_exact):.2f}",
        "gap35_shortfall_unmanaged_usdg_2dp": f"{float(unmanaged_exact):.2f}",
    }


def ramp_points() -> dict:
    """LT and B at fixed offsets from the close C, per closure class."""
    out = {}
    offsets = {"A": -PREP, "midpoint": -PREP + 2700, "C-45m": -2700, "F": -FINAL, "C-1s": -1}
    for name, cls in CLASSES.items():
        a, f = -PREP, -FINAL
        rows = {}
        for label, t in offsets.items():
            lt = lt_at(cls["lt_final"], a, f, t)
            rows[label] = {"offset_s": t, "lt_wad": str(lt), "b_wad": str(borrow_limit(lt))}
        out[name] = {"lt_final_wad": str(wad(cls["lt_final"])), "target_wad": str(wad(cls["target"])), "points": rows}
    return out


def interest() -> dict:
    """Debt index index(t) = exp(r * t) with r = 10% / 365 days per second, as integer WAD inputs."""
    getcontext().prec = 60
    rate_per_s = (RATE_ANNUAL * WAD) // YEAR  # integer WAD per second, floored like the contract constant
    rate_per_s = int(rate_per_s)
    pts = {}
    for label, secs in {"1d": 86400, "30d": 30 * 86400, "1y": YEAR, "5y": 5 * YEAR}.items():
        x = Decimal(rate_per_s * secs) / Decimal(WAD)
        pts[label] = {"seconds": secs, "index_wad": str(int(x.exp() * WAD))}
    return {"rate_per_second_wad": str(rate_per_s), "points": pts}


def valuation() -> dict:
    """Lender valuation convention: recoverable_i = min(debt_i, value_i / 1.05)."""
    cases = []
    for debt, value in [(7_200, 10_000), (9_800, 10_000), (12_000, 10_000), (0, 5_000)]:
        d, v = debt * USDG, value * USDG
        rec = min(F(d), F(v) / (1 + RECOVERY_HAIRCUT))
        cases.append({"debt_usdg": str(d), "value_usdg": str(v), "recoverable_usdg_floor": str(floor(rec))})
    return {"haircut_wad": str(wad(RECOVERY_HAIRCUT)), "cases": cases}


def build() -> dict:
    return {
        "units": {"usdg_decimals": 6, "token_decimals": 18, "wad": str(WAD)},
        "fixtures": {
            "lt_open_wad": str(wad(LT_OPEN)),
            "b_open_wad": str(wad(B_OPEN)),
            "target_open_wad": str(wad(TARGET_OPEN)),
            "bonus_scheduling_wad": str(wad(BONUS_SCHEDULING)),
            "bonus_distress_wad": str(wad(BONUS_DISTRESS)),
            "prep_seconds": PREP,
            "final_seconds": FINAL,
        },
        "worked_example": worked_example(),
        "demo_example": worked_example(collateral_raw=TOKEN // 4, debt=72 * USDG),
        "ramp": ramp_points(),
        "interest": interest(),
        "valuation": valuation(),
    }


def main() -> int:
    data = json.dumps(build(), indent=1) + "\n"
    if "--check" in sys.argv:
        if not OUTPUT.exists() or OUTPUT.read_text() != data:
            print("golden.json is out of date; run tools/golden/golden.py", file=sys.stderr)
            return 1
        print("golden.json is up to date")
        return 0
    OUTPUT.write_text(data)
    print(f"wrote {OUTPUT.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
