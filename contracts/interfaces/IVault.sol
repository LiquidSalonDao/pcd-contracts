// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVault {
    function toShare(
        address token,
        uint256 amount,
        bool roundUp
    ) external view returns (uint256 share);

    function toAmount(
        address token,
        uint256 share,
        bool roundUp
    ) external view returns (uint256 amount);

    function deposit(address token, uint256 amount) external returns (uint256 share);

    function withdraw(address token, address to, uint256 share) external returns (uint256 amount);
}
