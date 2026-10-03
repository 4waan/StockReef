// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDG
/// @notice Test double for USDG, the loan token: a 6-decimal ERC-20 with an issuer freeze list. Used by the unit
/// tests and by local (chain 31337) deployments; the testnet market lends the real Paxos USDG (appendix R7).
/// @dev The issuer (the deployer) alone can mint and freeze accounts; there is no burn and no transfer of the issuer
/// role. Mints and transfers to or from a frozen account revert with AccountFrozen, standing in for an issuer
/// transfer restriction (docs/SPEC.md §8, "Token transfer frozen"). Transfers charge no fee and balances do not
/// rebase.
contract MockUSDG is ERC20 {
    /// @notice The deployer; the only address that may call `mint` and `setFrozen`.
    address public immutable issuer;
    /// @notice True for accounts the issuer has frozen: mints and transfers to or from them revert.
    mapping(address => bool) public frozen;

    /// @notice The caller of `mint` or `setFrozen` is not `issuer`.
    error NotIssuer();
    /// @notice A mint or transfer involves a frozen account.
    /// @param account The frozen sender or receiver.
    error AccountFrozen(address account);

    /// @notice Deploys the token as "Mock Global Dollar" (mUSDG) with the caller as issuer and no supply.
    constructor() ERC20("Mock Global Dollar", "mUSDG") {
        issuer = msg.sender;
    }

    /// @inheritdoc ERC20
    /// @notice Number of decimals of the token: 6, as for USDG.
    /// @dev Returns 6, matching USDG, so amounts are loan-token base units of 1e-6 USDG.
    /// @return Token decimals: 6.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Create `amount` tokens for `to`. Only the issuer may call it.
    /// @dev Reverts with NotIssuer, with AccountFrozen when `to` is frozen, and with ERC20InvalidReceiver when `to`
    /// is the zero address.
    /// @param to Receiver of the new tokens.
    /// @param amount Amount to mint, loan-token base units (6 decimals).
    function mint(address to, uint256 amount) external {
        if (msg.sender != issuer) revert NotIssuer();
        _mint(to, amount);
    }

    /// @notice Freeze or unfreeze `account`. Only the issuer may call it.
    /// @dev Reverts with NotIssuer. A frozen account can neither send nor receive tokens, mints included; its
    /// balance is kept.
    /// @param account Account to update.
    /// @param isFrozen True to freeze, false to unfreeze.
    function setFrozen(address account, bool isFrozen) external {
        if (msg.sender != issuer) revert NotIssuer();
        frozen[account] = isFrozen;
    }

    /// @inheritdoc ERC20
    /// @dev Adds the issuer freeze list: reverts with AccountFrozen when `from` or `to` is frozen, checking `from`
    /// first, then applies the standard ERC-20 update. Covers transfers and mints.
    /// @param from Sender; the zero address for a mint.
    /// @param to Receiver.
    /// @param value Amount moved, loan-token base units (6 decimals).
    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert AccountFrozen(from);
        if (frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
