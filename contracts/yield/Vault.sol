// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./VaultStorage.sol";

/// @title A vault to earn more tokens
/// @author zk.link Benny
/// @notice Tokens deposited to PCD will be recorded by Vault, strategies of Vault can earn more tokens without loss
/// Any funds transferred directly onto the Vault will be lost, deposit through PCD instead
/// @dev Do not modify the inheritance order, or you may break the alignment of contract storage
contract Vault is UUPSUpgradeable, OwnableUpgradeable, VaultStorage {

    using RebaseLibrary for RebaseLibrary.Rebase;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event Deposit(address indexed token, uint256 amount, uint256 share);
    event Withdraw(address indexed token, address indexed to, uint256 share, uint256 amount);

    uint256 private constant SHARE_PRECISION = 1e18;

    /// @dev Only pcd contract can call
    modifier onlyPCD() {
        require(msg.sender == pcd, "Vault: caller is not pcd");
        _;
    }

    /// @dev Put `initializer` modifier here to prevent anyone call this function from proxy after we initialized
    /// No delegatecall exist in this contract, so it's ok to expose this function in logic
    /// @param _pcd The pcd contract
    function initialize(address _pcd) public initializer {
        require(_pcd != address(0), "Vault: pcd not set");

        __Ownable_init();
        __UUPSUpgradeable_init();
        pcd = _pcd;
    }

    /// @dev Only owner can upgrade logic contract
    // solhint-disable no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Helper function to represent an `amount` of `token` in shares
    /// @param token The ERC-20 token
    /// @param amount The `token` amount
    /// @param roundUp If the result `share` should be rounded up
    /// @return share The token amount represented in shares with accuracy improvement
    function toShare(
        address token,
        uint256 amount,
        bool roundUp
    ) public view returns (uint256 share) {
        share = totals[token].toBase(amount * SHARE_PRECISION, roundUp);
    }

    /// @dev Helper function to represent shares back into the `token` amount
    /// @param token The ERC-20 token
    /// @param share The amount of shares with accuracy improvement
    /// @param roundUp If the result should be rounded up
    /// @return amount The share amount back into native representation
    function toAmount(
        address token,
        uint256 share,
        bool roundUp
    ) public view returns (uint256 amount) {
        amount = totals[token].toElastic(share, roundUp);
    }

    /// @notice Deposit an amount of `token` from pcd and increase the share
    /// @dev Do not break the Checks-Effects-Interactions rule
    /// @param token The ERC-20 token to deposit
    /// @param amount Token amount in native representation to deposit
    /// @return share The deposited amount represented in shares
    function deposit(address token, uint256 amount) external onlyPCD returns (uint256 share) {
        // ===Checks===
        require(amount > 0, "Vault: amount not set");

        RebaseLibrary.Rebase memory total = totals[token];
        // all tokens that can be deposited to PCD are already deployed
        // so there is no need to check if the token has been deployed like in BentoBox

        // ===Effects===
        // value of the share may be lower than the amount due to rounding, that's ok
        share = toShare(token, amount, false);
        require(share > 0, "Vault: too small amount");
        total.base += share;
        total.elastic += amount;
        totals[token] = total;

        // ===Interactions===
        emit Deposit(token, amount, share);
    }

    /// @notice Withdraw an amount of `token` to user `to` and decrease the share
    /// @dev Do not break the Checks-Effects-Interactions rule
    /// @param token The ERC-20 token to withdraw
    /// @param to Which account to push the token
    /// @param share Share amount
    /// @return amount The withdraw amount represented in shares
    function withdraw(address token, address to, uint256 share) external onlyPCD returns (uint256 amount) {
        // ===Checks===
        require(to != address(0), "Vault: to not set");
        require(share > 0, "Vault: share not set");

        // ===Effects===
        // amount may be lower than the value of share due to rounding, that's ok
        RebaseLibrary.Rebase memory total = totals[token];
        amount = total.toElastic(share, false);
        require(amount > 0, "Vault: too small share");
        total.elastic -= amount;
        total.base -= share;
        totals[token] = total;

        // ===Interactions===
        IERC20Upgradeable(token).safeTransfer(to, amount);
        emit Withdraw(token, to, share, amount);
    }
}
