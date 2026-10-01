// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double for USDG (6 decimals) with an issuer freeze list. Used in local tests only; the
/// testnet market lends the real Paxos USDG.
contract MockUSDG is ERC20 {
    address public immutable issuer;
    mapping(address => bool) public frozen;

    error NotIssuer();
    error AccountFrozen(address account);

    constructor() ERC20("Mock Global Dollar", "mUSDG") {
        issuer = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != issuer) revert NotIssuer();
        _mint(to, amount);
    }

    function setFrozen(address account, bool isFrozen) external {
        if (msg.sender != issuer) revert NotIssuer();
        frozen[account] = isFrozen;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert AccountFrozen(from);
        if (frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
