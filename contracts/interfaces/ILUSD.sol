// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC2612.sol";

interface ILUSD is IERC20Metadata, IERC2612 {

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}
