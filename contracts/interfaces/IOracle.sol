// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracle {

    /// @dev Oracle MUST cache the price of collateral when multiple queries happen at the same block
    function getPrice(address collateral) external view returns (uint256);
}
