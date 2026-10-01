#!/usr/bin/env python3
"""Scenario harness for docs/SPEC.md §10: baselines × price paths, in exact rational arithmetic.

This is an economic model of one loan through one closure (or several sessions), independent of the
Solidity code. It uses the same fixtures as the contracts (appendix R1) and the spec's worked example
as the starting position: 10,000 USDG of TSLA collateral at 400, 7,200 USDG of debt.

    python tools/scenarios/run.py          # write evidence/scenarios.json
    python tools/scenarios/run.py --check  # fail if evidence/scenarios.json is out of date

Baselines (identical starting debt, collateral, price path and interest):
  1. Fixed lender: 80% threshold, 5% bonus, borrowing open at the stale closing price during the closure.
  2. Fixed lender with a closed-session borrowing lock.
  3. StockReef, nobody acts before the close (recovery trims only after the reopening).
  4. StockReef with a funded buffer (4a) or a capital-funded trim (4b) before the close.
  5. Static 65% borrow limit (opens a smaller loan; compare separately).
"""
import json
import sys
from fractions import Fraction as F
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "evidence" / "scenarios.json"

LT_OPEN, T_OPEN, B_OPEN = F(80, 100), F(75, 100), F(75, 100)
CLASSES = {"EXTENDED": (F(70, 100), F(65, 100)), "OVERNIGHT": (F(77, 100), F(72, 100))}
BONUS_SCHED, BONUS_DISTRESS = F(2, 100), F(5, 100)
RATE = F(10, 100)
YEAR_H = 365 * 24
CLOSURE_HOURS = {"EXTENDED": F(655, 10), "OVERNIGHT": F(35, 2)}  # Fri 16:00 -> Mon 09:30, weeknight

PRICE0 = F(400)
COLL_UNITS = F(25)  # 10,000 USDG at 400
DEBT0 = F(7200)


def interest(debt: F, hours: F) -> F:
    # Linear approximation of exp(r t) over a closure; the contracts compound continuously (difference < 0.01%).
    return debt * (1 + RATE * hours / YEAR_H)


def trim_amount(debt: F, value: F, target: F, bonus: F) -> F:
    """Repayment that brings debt/value to the target when the liquidator takes value worth x(1+b)."""
    return max(F(0), (debt - target * value) / (1 - target * (1 + bonus)))


def liquidate(debt, units, price, lt, target, bonus):
    """One liquidation at `price` if debt/value > lt. Returns (debt, units, repaid, seized_units, loss)."""
    value = units * price
    if value == 0 or debt / value <= lt:
        return debt, units, F(0), F(0), F(0)
    if debt * (1 + bonus) >= value:  # insolvent: exhaust collateral, write off the residual
        repaid = value / (1 + bonus)
        return F(0), F(0), repaid, units, debt - repaid
    x = trim_amount(debt, value, target, bonus)
    seized = x * (1 + bonus) / price
    return debt - x, units - seized, x, seized, F(0)


def run(baseline: str, path: dict) -> dict:
    """One closure. `path`: pre (price change before the close, as a factor), gap (factor at the reopening),
    cls (closure class), buffer (USDG funded), stale_borrow (borrower tops up during the closure if allowed)."""
    cls = path.get("cls", "EXTENDED")
    lt_f, target = CLASSES[cls]
    debt = DEBT0 if baseline != "5 static 65%" else F(6500)
    units = COLL_UNITS
    p_pre = PRICE0 * path.get("pre", 1)
    p_open = p_pre * path["gap"]
    r = {"credit": debt, "borrower_cash": F(0), "bonus_paid": F(0), "sold_pre_close": F(0), "liq_capital": F(0),
         "liq_gap_pnl": F(0), "lender_loss": F(0), "unexecuted": F(0)}

    # Before the close (StockReef only).
    if baseline.startswith("4a"):
        need = max(F(0), debt - target * units * p_pre)
        paid = min(need, F(path.get("buffer", 10**9)))
        debt -= paid
        r["borrower_cash"] += paid
        if debt / (units * p_pre) > lt_f:  # a partial buffer leaves a trim for the rest
            b = BONUS_DISTRESS if debt / (units * p_pre) > LT_OPEN else BONUS_SCHED
            debt, units, x, seized, _ = liquidate(debt, units, p_pre, lt_f, target, b)
            r["bonus_paid"] += x * b
            r["sold_pre_close"] += seized * p_pre
            r["liq_capital"] += x
            r["liq_gap_pnl"] += seized * (p_open - p_pre)  # inventory held through the gap
    elif baseline.startswith("4b"):
        ltv = debt / (units * p_pre)
        b = BONUS_DISTRESS if ltv > LT_OPEN else BONUS_SCHED
        debt, units, x, seized, _ = liquidate(debt, units, p_pre, lt_f, target, b)
        r["bonus_paid"] += x * b
        r["sold_pre_close"] += seized * p_pre
        r["liq_capital"] += x
        r["liq_gap_pnl"] += seized * (p_open - p_pre)
    elif baseline.startswith("3"):
        r["unexecuted"] = max(F(0), debt - target * units * p_pre) if debt / (units * p_pre) > lt_f else F(0)

    # During the closure: the fixed lender without a lock lets the borrower top up at the stale price.
    if baseline.startswith("1") and path.get("stale_borrow"):
        extra = max(F(0), B_OPEN * units * p_pre - debt)
        debt += extra
        r["credit"] += extra

    debt = interest(debt, CLOSURE_HOURS[cls])

    # Reopening at the gapped price.
    if baseline.startswith(("1", "2", "5")):
        lt, tgt = LT_OPEN, T_OPEN
    else:
        lt, tgt = lt_f, target
    debt, units, x, seized, loss = liquidate(debt, units, p_open, lt, tgt, BONUS_DISTRESS)
    r["bonus_paid"] += x * BONUS_DISTRESS  # also when insolvent: the liquidator receives x(1+b) of collateral
    r["liq_capital"] += x
    r["lender_loss"] += loss
    r["debt_after"] = debt
    r["collateral_after"] = units * p_open
    return r


def five_sessions(baseline: str) -> dict:
    """Unchanged prices Mon-Fri: the borrower re-borrows to 75% every open (StockReef) and the policy trims
    only before the weekend (EXTENDED class); weeknights stay at 75% under the 77% overnight threshold."""
    debt, units, price = F(7500), COLL_UNITS, PRICE0
    bonus_paid = F(0)
    for day in range(5):
        cls = "EXTENDED" if day == 4 else "OVERNIGHT"
        lt_f, target = CLASSES[cls]
        if baseline.startswith("4b"):
            debt = max(debt, B_OPEN * units * price)  # borrow back to 75% at the open
            if debt / (units * price) > lt_f:
                debt, units, x, seized, _ = liquidate(debt, units, price, lt_f, target, BONUS_SCHED)
                bonus_paid += x * BONUS_SCHED
        debt = interest(debt, CLOSURE_HOURS[cls])
    return {"credit": F(7500), "borrower_cash": F(0), "bonus_paid": bonus_paid, "sold_pre_close": F(0),
            "liq_capital": F(0), "liq_gap_pnl": F(0), "lender_loss": F(0), "unexecuted": F(0),
            "debt_after": debt, "collateral_after": units * price}


PATHS = [
    ("Unchanged price, weekend", {"gap": F(1)}),
    ("Moderate gap −10%", {"gap": F(90, 100)}),
    ("Severe gap −35%", {"gap": F(65, 100)}),
    ("Rally +10%", {"gap": F(110, 100)}),
    ("Decline during the ramp −8%, then gap −5%", {"pre": F(92, 100), "gap": F(95, 100)}),
    ("Stale-price top-up, then gap −20%", {"gap": F(80, 100), "stale_borrow": True}),
    ("Partial buffer (300 of 700), gap −20%", {"gap": F(80, 100), "buffer": 300}),
    ("Weeknight close, gap −8%", {"gap": F(92, 100), "cls": "OVERNIGHT"}),
]
BASELINES = ["1 fixed lender", "2 fixed + lock", "3 StockReef, nobody acts", "4a StockReef, buffer", "4b StockReef, trim", "5 static 65%"]

# Behaviour scenarios from §10 that are protocol mechanics rather than economics, with the test that shows them.
BEHAVIOURS = [
    ("Absent keeper", "Debt stays; the close blocks borrowing; missed execution and exposure are reported", "StockReefLens.t.sol: test_account_missedExecutionIsDetectedAtTheClose"),
    ("Unfunded liquidator", "No trim happens; the position stays eligible; recovery trims after the reopening", "StockReefMarket.t.sol: test_trim_reopeningGapExhaustsCollateralAndWritesOffTheResidual"),
    ("Corporate-action pause", "Issuer pause or a multiplier change after the last price stops price-dependent actions", "PriceGate.t.sol: test_quote_honoursIssuerPause, test_quote_waitsForTheFeedAfterAMultiplierChange"),
    ("USDG conversion failure", "Stale, missing or out-of-range USDG price makes the quote unusable", "PriceGate.t.sol: test_quote_rejectsBrokenLoanConversion"),
    ("Holiday and early close", "The day before a holiday is an extended close; an early close moves the whole ramp", "SessionRiskPolicy.t.sol: test_class_weekdayCloseBeforeAHolidayIsExtended, test_class_earlyCloseMovesTheWholeRamp"),
    ("Missing opening quote", "Waits for a fresh price, guarded after 30 minutes; a Sunday quote never qualifies", "SessionRiskPolicy.t.sol: test_reopen_guardedWithoutAdmissionByOpenPlus30, test_reopen_sundayQuoteKeepsTheMarketWaiting"),
]


def fmt(x: F) -> str:
    return f"{float(x):,.2f}"


def build() -> dict:
    rows = []
    for name, path in PATHS:
        for b in BASELINES:
            r = run(b, path)
            rows.append(_row(name, b, r))
    for b in ["1 fixed lender", "4b StockReef, trim"]:
        rows.append(_row("Unchanged price, five sessions with daily re-borrowing", b, five_sessions(b)))
    return {
        "start": {"collateral_usdg": "10,000.00", "debt_usdg": "7,200.00", "price": "400.00"},
        "rows": rows,
        "behaviours": [{"scenario": s, "behaviour": d, "test": t} for s, d, t in BEHAVIOURS],
        "notes": [
            "Static 65% opens 6,500 USDG of credit rather than 7,200; compare it separately.",
            "Liquidator gap P&L is the change in value of collateral bought before the close and held through the gap.",
            "Interest is 10% a year over the closure; buffer cash is the borrower's own extra capital.",
        ],
    }


def _row(scenario: str, baseline: str, r: dict) -> dict:
    return {
        "scenario": scenario,
        "baseline": baseline,
        "credit": fmt(r["credit"]),
        "borrower cash": fmt(r["borrower_cash"]),
        "bonus paid": fmt(r["bonus_paid"]),
        "sold before close": fmt(r["sold_pre_close"]),
        "liquidator capital": fmt(r["liq_capital"]),
        "liquidator gap P&L": fmt(r["liq_gap_pnl"]),
        "lender loss": fmt(r["lender_loss"]),
        "unexecuted": fmt(r["unexecuted"]),
        "debt after": fmt(r["debt_after"]),
    }


def main() -> int:
    data = json.dumps(build(), indent=1, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != data:
            print("evidence/scenarios.json is out of date; run tools/scenarios/run.py", file=sys.stderr)
            return 1
        print("scenarios.json is up to date")
        return 0
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(data)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(json.loads(data)['rows'])} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
