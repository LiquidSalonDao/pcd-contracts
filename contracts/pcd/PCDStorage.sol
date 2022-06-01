// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ILUSD.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IOracle.sol";

/// @title PCD storage
/// @author zk.link Benny
/// @dev Do not initialize any variables of this contract
/// Do not break the alignment of contract storage
contract PCDStorage {

    event SetStableCoin(address indexed token, bool enableExchangeIn);
    event SetCollateralToken(address indexed token, bool enableBorrow, bool enableLiquidate, uint256 debtLimit, uint32 collateralRate, uint32 liquidationRate, uint32 liquidationBonusRate);
    event ExchangeIn(address indexed token, address indexed from, address indexed to, uint256 amountIn, uint256 amountOut);
    event ExchangeOut(address indexed token, address indexed from, address indexed to, uint256 amountIn, uint256 fee, uint256 amountOut);
    event AddCollateral(address indexed token, address indexed from, address indexed to, uint256 amount, uint256 share);
    event RemoveCollateral(address indexed token, address indexed from, address indexed to, uint256 collateralAmount);
    event Borrow(address indexed token, address indexed from, address to, uint256 amount);
    event Repay(address indexed token, address indexed from, address indexed to, uint256 amount);

    // rate precision, when rate = 1000, it means 1%
    uint32 public constant RATE_PRECISION = 1e5;
    // price precision
    uint256 public constant PRICE_PRECISION = 1e18;

    struct USDData {
        bool active; // When set this value to false, all operations related will be prohibited
        bool enableExchangeIn; // When set this value to false, exchangeIn will be prohibited
    }

    struct CollateralData {
        bool active; // When set this value to false, all operations related will be prohibited
        bool enableBorrow; // When set this value to false, borrow will be prohibited
        bool enableLiquidate; // When set this value to false, liquidate will be prohibited
        uint256 debtLimit; // The maximum amount of LUSD that can be borrowed from PCD
        uint32 collateralRate; // The collateral rate control the maximum debt that can be generated
        uint32 liquidationRate; // The liquidation rate control when to liquidate after debt ratio is unhealthy
        uint32 liquidationBonusRate; // The liquidation bonus rate give a discount to liquidator as profit
        uint256 collateralShare; // The total amount of collateral share that PCD accepted
        uint256 debtAmount; // The total amount of debt that user owned
    }

    struct UserDebt {
        uint256 collateralShare; // The amount of collateral share that user own
        uint256 debtAmount; // The amount of debt that user own
    }

    // LUSD backed by stablecoins
    ILUSD public lusd;

    // The vault where tokens deposited to for income
    IVault public vault;

    // The oracle from where to get collateral exchange rate
    IOracle public oracle;

    // Stable USD tokens that can be exchanged 1:1 to LUSD
    mapping(address => USDData) public usds;

    // Tokens that can be mortgaged for LUSD
    mapping(address => CollateralData) public collaterals;

    // User debt info of collateral
    mapping(address => mapping(address => UserDebt)) public userDebts;

    // The address which fees collected to send to
    address public treasury;

    // Fee rate when exchange out from LUSD to USD tokens
    uint256 public exchangeOutFeeRate;
}
