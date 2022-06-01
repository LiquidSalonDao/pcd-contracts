// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/BoringRebase.sol";

/// @title Vault storage
/// @author zk.link Benny
/// @dev Do not initialize any variables of this contract
/// Do not break the alignment of contract storage
contract VaultStorage {

    // PCD contract address who can deposit and withdraw from vault
    address public pcd;

    // Rebase from amount to share
    mapping(address => RebaseLibrary.Rebase) public totals;
}
