// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "../interfaces/ILUSD.sol";

contract LUSD is ERC20Permit, ILUSD {

    address public immutable pcd;

    /// @dev Only pcd contract can call
    modifier onlyPCD() {
        require(msg.sender == pcd, "LUSD: caller is not pcd");
        _;
    }

    // solhint-disable func-visibility
    constructor(address _pcd) ERC20("LUSD", "Liquidity USD") ERC20Permit("LUSD") {
        pcd = _pcd;
    }

    function mint(address to, uint256 amount) external override onlyPCD {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyPCD {
        _burn(from, amount);
    }
}
