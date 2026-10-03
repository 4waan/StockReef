// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StockReefMath
/// @notice The fixed-point formulas shared by the gate, market, escrow and lens: collateral value, LTV, debt
/// shares, the repayment that reaches a ratio, and the trim amounts (docs/SPEC.md §5 and §7). Each formula and its
/// rounding direction is defined once; a name ending in Down rounds down and one ending in Up rounds up, in the
/// style of Morpho Blue's MathLib and SharesMathLib.
/// @dev Units: loan amounts (debt, value, repayments) in loan-token base units; collateral in raw stock-token units;
/// ratios, bonuses, prices and the debt index in WAD (1e18 = 100% or 1.0), where `priceWad` is loan-token whole
/// units per collateral whole unit. `valueScale` is PriceGate.VALUE_SCALE = 10^(tokenDecimals + 18 - loanDecimals).
/// Every function uses checked arithmetic; products that can overflow go through Math.mulDiv where the original
/// formulas did.
library StockReefMath {
    using Math for uint256;

    /// @dev Fixed-point one for ratios, prices and the debt index.
    uint256 internal constant WAD = 1e18;
    /// @dev Debt shares per loan-token base unit at index 1.0, times WAD: debt = shares * index / SHARE_UNIT.
    uint256 internal constant SHARE_UNIT = 1e36;

    // ---------------------------------------------------------------- value

    /// @dev Collateral value: raw * priceWad / valueScale, rounded down. Zero when either input is zero.
    function toValueDown(uint256 raw, uint256 priceWad, uint256 valueScale) internal pure returns (uint256) {
        return raw.mulDiv(priceWad, valueScale);
    }

    /// @dev Raw collateral worth `value`: value * valueScale / priceWad, rounded as asked. Reverts when `priceWad`
    /// is zero.
    function toRaw(uint256 value, uint256 priceWad, uint256 valueScale, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return value.mulDiv(valueScale, priceWad, rounding);
    }

    // ---------------------------------------------------------------- debt shares

    /// @dev Debt of `shares` at index `idx`: shares * idx / SHARE_UNIT, rounded up (against the borrower).
    function toDebtUp(uint256 shares, uint256 idx) internal pure returns (uint256) {
        return shares.mulDiv(idx, SHARE_UNIT, Math.Rounding.Ceil);
    }

    /// @dev Shares minted for borrowing `amount` at index `idx`, rounded up (against the borrower).
    function toSharesUp(uint256 amount, uint256 idx) internal pure returns (uint256) {
        return amount.mulDiv(SHARE_UNIT, idx, Math.Rounding.Ceil);
    }

    /// @dev Shares burned for repaying `amount` at index `idx`, rounded down (against the payer).
    function toSharesDown(uint256 amount, uint256 idx) internal pure returns (uint256) {
        return amount.mulDiv(SHARE_UNIT, idx);
    }

    // ---------------------------------------------------------------- ratios

    /// @dev True when debt / value is strictly above `ratioWad`, compared exactly: debt * WAD > ratioWad * value.
    /// Zero debt never exceeds; non-zero debt against zero value always does.
    function exceeds(uint256 debt, uint256 value, uint256 ratioWad) internal pure returns (bool) {
        return debt * WAD > ratioWad * value;
    }

    /// @dev LTV = debt / value, WAD, rounded up: zero without debt, type(uint256).max when `value` is zero.
    function ltvUp(uint256 debt, uint256 value) internal pure returns (uint256) {
        if (debt == 0) return 0;
        return value == 0 ? type(uint256).max : debt.mulDiv(WAD, value, Math.Rounding.Ceil);
    }

    /// @dev Repayment that brings debt / value down to `ratioWad`: (debt * WAD - ratioWad * value) / WAD, rounded
    /// up, so paying it in full reaches the ratio. Callers check `exceeds(debt, value, ratioWad)` first.
    function repayToReachUp(uint256 debt, uint256 value, uint256 ratioWad) internal pure returns (uint256) {
        return Math.ceilDiv(debt * WAD - ratioWad * value, WAD);
    }

    /// @dev Collateral value at which debt / value equals `ratioWad`: debt * WAD / ratioWad, rounded up.
    function valueForRatioUp(uint256 debt, uint256 ratioWad) internal pure returns (uint256) {
        return debt.mulDiv(WAD, ratioWad, Math.Rounding.Ceil);
    }

    /// @dev a * bWad / WAD, rounded down.
    function mulWadDown(uint256 a, uint256 bWad) internal pure returns (uint256) {
        return a.mulDiv(bWad, WAD);
    }

    /// @dev a * WAD / b, rounded down. Reverts when `b` is zero.
    function divWadDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return a.mulDiv(WAD, b);
    }

    /// @dev Lender valuation of one loan: min(debt, value / (1 + haircut)), the quotient rounded down.
    function recoverableDown(uint256 debt, uint256 value, uint256 haircutWad) internal pure returns (uint256) {
        return Math.min(debt, value.mulDiv(WAD, WAD + haircutWad));
    }

    // ---------------------------------------------------------------- trims (docs/SPEC.md §5)

    /// @dev True when a trim at bonus b cannot leave a solvent position: debt * (1 + b) >= value.
    function insolventAt(uint256 debt, uint256 value, uint256 onePlusBWad) internal pure returns (bool) {
        return debt * onePlusBWad >= value * WAD;
    }

    /// @dev Solvent trim repayment that reaches target T: x = (D - T * V) / (1 - T * (1 + b)), rounded up, with D
    /// and V in base units and T, 1 + b in WAD. Callers check that the position is above T and solvent, and the
    /// snapshot keeps T * (1 + b) below 1.
    function trimRepayUp(uint256 debt, uint256 value, uint256 targetWad, uint256 onePlusBWad)
        internal
        pure
        returns (uint256)
    {
        return (debt * WAD - targetWad * value).mulDiv(WAD, WAD * WAD - targetWad * onePlusBWad, Math.Rounding.Ceil);
    }

    /// @dev Raw collateral worth `repaid` times (1 + b) at `priceWad`: repaid * (1 + b) * valueScale /
    /// (priceWad * WAD), rounded down (against the liquidator).
    function seizeDown(uint256 repaid, uint256 onePlusBWad, uint256 priceWad, uint256 valueScale)
        internal
        pure
        returns (uint256)
    {
        return (repaid * onePlusBWad).mulDiv(valueScale, priceWad * WAD);
    }
}
