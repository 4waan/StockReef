// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double for a Robinhood Stock Token: ERC-20 with the ERC-8056 multiplier getters, an
/// optional issuer pause flag and an issuer freeze list. When `hasPauseFlag` is false, oraclePaused()
/// reverts, like the testnet token version.
contract MockStockToken is ERC20 {
    address public immutable issuer;
    bool public immutable hasPauseFlag;

    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;
    bool private _oraclePaused;
    mapping(address => bool) public frozen;

    error NotIssuer();
    error PauseFlagUnsupported();
    error AccountFrozen(address account);

    constructor(string memory name_, string memory symbol_, bool hasPauseFlag_) ERC20(name_, symbol_) {
        issuer = msg.sender;
        hasPauseFlag = hasPauseFlag_;
    }

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer();
        _;
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        _mint(to, amount);
    }

    function oraclePaused() external view returns (bool) {
        if (!hasPauseFlag) revert PauseFlagUnsupported();
        return _oraclePaused;
    }

    function setOraclePaused(bool paused) external onlyIssuer {
        _oraclePaused = paused;
    }

    /// @notice Schedule a multiplier change (split or dividend adjustment) that takes effect at `when`.
    function scheduleMultiplier(uint256 multiplier, uint256 when) external onlyIssuer {
        uiMultiplier = newUIMultiplier;
        newUIMultiplier = multiplier;
        effectiveAt = when;
    }

    function setFrozen(address account, bool isFrozen) external onlyIssuer {
        frozen[account] = isFrozen;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return balanceOf(account) * uiMultiplier / 1e18;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert AccountFrozen(from);
        if (frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
