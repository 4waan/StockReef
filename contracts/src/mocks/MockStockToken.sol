// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStockToken
/// @notice Test double for a Robinhood Stock Token: an 18-decimal ERC-20 with the ERC-8056 multiplier getters, an
/// optional issuer pause flag and an issuer freeze list. When `hasPauseFlag` is false, `oraclePaused()` reverts,
/// like the Robinhood Chain testnet token version (appendix R4). Used by the unit tests and by local (chain 31337)
/// deployments; the testnet market uses the real faucet stock token.
/// @dev Provides the getters of IStockToken without inheriting it. The issuer (the deployer) alone can mint, set the
/// pause flag, schedule multiplier changes and freeze accounts; there is no burn and no transfer of the issuer role.
/// Mints and transfers to or from a frozen account revert with AccountFrozen, standing in for an issuer transfer
/// restriction (docs/SPEC.md §8, "Token transfer frozen"). Multipliers are 18-decimal fixed point (1e18 = 1.0) and
/// times are UTC seconds. The stored multipliers change only when the issuer calls `scheduleMultiplier`: reaching
/// `effectiveAt` changes nothing here, so `uiMultiplier` and `balanceOfUI` keep the earlier multiplier until the
/// next call. StockReef values raw balances and never reads `uiMultiplier` (docs/SPEC.md §6, appendix R11).
contract MockStockToken is ERC20 {
    /// @notice The deployer; the only address that may call `mint`, `setOraclePaused`, `scheduleMultiplier` and
    /// `setFrozen`.
    address public immutable issuer;
    /// @notice True when `oraclePaused()` is implemented; when false it reverts with PauseFlagUnsupported, like the
    /// testnet token version. Fixed at deployment.
    bool public immutable hasPauseFlag;

    /// @notice Current multiplier from raw balances to displayed share amounts, 18-decimal fixed point
    /// (1e18 = 1.0). Starts at 1e18; `scheduleMultiplier` sets it to the previously scheduled `newUIMultiplier`.
    uint256 public uiMultiplier = 1e18;
    /// @notice Multiplier most recently scheduled by the issuer, 18-decimal fixed point (1e18 = 1.0); starts at
    /// 1e18. StockReefLens shows it as pending while `effectiveAt` is in the future.
    uint256 public newUIMultiplier = 1e18;
    /// @notice Time at which `newUIMultiplier` is scheduled to take effect, UTC seconds; zero until the first
    /// `scheduleMultiplier`, which may also store zero. When the manifest marks the token as ERC-8056, PriceGate
    /// compares it with the stock feed's timestamp (MULTIPLIER_LAG, appendix R11).
    uint256 public effectiveAt;
    /// @dev Issuer pause flag; readable through `oraclePaused()` only when `hasPauseFlag` is true.
    bool private _oraclePaused;
    /// @notice True for accounts the issuer has frozen: mints and transfers to or from them revert.
    mapping(address => bool) public frozen;

    /// @notice The caller is not `issuer`.
    error NotIssuer();
    /// @notice `oraclePaused()` was called on a token deployed without the pause flag.
    error PauseFlagUnsupported();
    /// @notice A mint or transfer involves a frozen account.
    /// @param account The frozen sender or receiver.
    error AccountFrozen(address account);

    /// @notice Deploys the token with the caller as issuer, a 1.0 multiplier, no scheduled change and no supply.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param hasPauseFlag_ Whether `oraclePaused()` is implemented.
    constructor(string memory name_, string memory symbol_, bool hasPauseFlag_) ERC20(name_, symbol_) {
        issuer = msg.sender;
        hasPauseFlag = hasPauseFlag_;
    }

    /// @dev Reverts with NotIssuer unless the caller is `issuer`.
    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer();
        _;
    }

    /// @notice Create `amount` tokens for `to`. Only the issuer may call it.
    /// @dev Reverts with NotIssuer, with AccountFrozen when `to` is frozen, and with ERC20InvalidReceiver when `to`
    /// is the zero address.
    /// @param to Receiver of the new tokens.
    /// @param amount Amount to mint, raw stock-token units (18 decimals).
    function mint(address to, uint256 amount) external onlyIssuer {
        _mint(to, amount);
    }

    /// @notice Issuer flag raised while a corporate action is in progress (IStockToken.oraclePaused).
    /// @dev Reverts with PauseFlagUnsupported when `hasPauseFlag` is false. PriceGate sets ISSUER_PAUSED while it is
    /// true, and PAUSE_FLAG_UNAVAILABLE on the revert when the manifest requires the flag (appendix R4).
    /// @return True while the issuer has paused the token's oracle.
    function oraclePaused() external view returns (bool) {
        if (!hasPauseFlag) revert PauseFlagUnsupported();
        return _oraclePaused;
    }

    /// @notice Raise or clear the issuer pause flag. Only the issuer may call it.
    /// @dev Reverts with NotIssuer. The flag is stored even when `hasPauseFlag` is false, but `oraclePaused()`
    /// cannot return it then.
    /// @param paused New flag value.
    function setOraclePaused(bool paused) external onlyIssuer {
        _oraclePaused = paused;
    }

    /// @notice Schedule a multiplier change (split or dividend adjustment) with effective time `when`. Only the
    /// issuer may call it.
    /// @dev Reverts with NotIssuer. First moves the previously scheduled `newUIMultiplier` into `uiMultiplier`,
    /// whether or not its effective time has passed, then stores `multiplier` and `when`. Neither value is checked:
    /// `when` may be zero or in the past. Nothing happens when `when` arrives; PriceGate reads `effectiveAt` to
    /// detect a stock price that predates the change (appendix R11).
    /// @param multiplier New multiplier, 18-decimal fixed point (1e18 = 1.0).
    /// @param when Effective time, UTC seconds.
    function scheduleMultiplier(uint256 multiplier, uint256 when) external onlyIssuer {
        uiMultiplier = newUIMultiplier;
        newUIMultiplier = multiplier;
        effectiveAt = when;
    }

    /// @notice Freeze or unfreeze `account`. Only the issuer may call it.
    /// @dev Reverts with NotIssuer. A frozen account can neither send nor receive tokens, mints included; its
    /// balance is kept.
    /// @param account Account to update.
    /// @param isFrozen True to freeze, false to unfreeze.
    function setFrozen(address account, bool isFrozen) external onlyIssuer {
        frozen[account] = isFrozen;
    }

    /// @notice Displayed share balance of `account`: its raw balance scaled by `uiMultiplier`.
    /// @dev `balanceOf(account) * uiMultiplier / 1e18`, rounded down. Not part of IStockToken and not read by
    /// StockReef, which values raw balances.
    /// @param account Account to read.
    /// @return Displayed balance, 18-decimal share units.
    function balanceOfUI(address account) external view returns (uint256) {
        return balanceOf(account) * uiMultiplier / 1e18;
    }

    /// @inheritdoc ERC20
    /// @dev Adds the issuer freeze list: reverts with AccountFrozen when `from` or `to` is frozen, checking `from`
    /// first, then applies the standard ERC-20 update. Covers transfers and mints.
    /// @param from Sender; the zero address for a mint.
    /// @param to Receiver.
    /// @param value Amount moved, raw stock-token units (18 decimals).
    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert AccountFrozen(from);
        if (frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
