// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./PCDStorage.sol";

/// @title Protocol control debt(PCD)
/// @author zk.link Benny
/// @notice User can deposit stable coins or mortgage other collaterals to get LUSD
/// @dev Do not modify the inheritance order, or you may break the alignment of contract storage
/// Specifications of stable coins or collateral tokens that PCD accepted:
/// It MUST be a pure ERC20 token, no external call before or after transfer
/// It MUST be a no deflation or inflation token
/// It SHOULD not be an upgradeable token(eg. TUSD)
contract PCD is ReentrancyGuardUpgradeable, UUPSUpgradeable, OwnableUpgradeable, PCDStorage {
    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;

    /// @dev Put `initializer` modifier here to prevent anyone call this function from proxy after we initialized
    /// No delegatecall exist in this contract, so it's ok to expose this function in logic
    /// @param _lusd The LUSD token
    /// @param _vault The vault contract
    /// @param _usds The USD token list
    function initialize(ILUSD _lusd, IVault _vault, address[] calldata _usds) public initializer {
        require(address(_lusd) != address(0), "PCD: lusd not set");
        require(address(_vault) != address(0), "PCD: vault not set");
        require(_usds.length > 0, "PCD: usd tokens not set");

        __Ownable_init();
        __UUPSUpgradeable_init();

        lusd = _lusd;
        vault = _vault;
        for (uint i; i < _usds.length; i++) {
            address token = _usds[i];
            setStableCoin(token, true);
        }
    }

    /// @dev Only owner can upgrade logic contract
    // solhint-disable no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Set stable coin that can be exchanged 1:1 with LUSD
    /// @dev We can add a new stable coin, enable or disable exchangeIn
    /// But we can not disable exchangeOut if stable coin is already exist
    /// @param token The USD token
    /// @param enableExchangeIn When set this value to false, exchangeIn will be prohibited
    function setStableCoin(address token, bool enableExchangeIn) public onlyOwner {
        require(IERC20MetadataUpgradeable(token).decimals() <= lusd.decimals(), "PCD: usd decimals too large");

        USDData memory data = usds[token];
        // always set active to true
        data.active = true;
        data.enableExchangeIn = enableExchangeIn;
        usds[token] = data;
        emit SetStableCoin(token, enableExchangeIn);
    }

    /// @notice Set collateral than that can be mortgaged for LUSD
    /// @dev We can add or update collateral token config
    /// Great care needs to be taken when lowering the liquidation rate, which can lead to liquidations
    /// The precision of `collateralRate`, `liquidationRate` and `liquidationBonusRate` MUST be improved by `RATE_PRECISION`
    /// @param token The collateral token
    /// @param enableBorrow When set this value to false, borrow are prohibited
    /// @param enableLiquidate When set this value to false, liquidate will be prohibited
    /// @param debtLimit The maximum LUSD that can be borrowed for this collateral
    /// @param collateralRate The collateral rate control the maximum debt that can be generated
    /// @param liquidationRate The liquidation rate control when to liquidate after debt ratio is unhealthy
    /// @param liquidationBonusRate The liquidation bonus rate give a discount to liquidator as profit
    function setCollateralToken(address token,
        bool enableBorrow,
        bool enableLiquidate,
        uint256 debtLimit,
        uint32 collateralRate,
        uint32 liquidationRate,
        uint32 liquidationBonusRate) external onlyOwner {
        require(collateralRate > 0 && collateralRate < RATE_PRECISION, "PCD: invalid collateralRate");
        require(liquidationRate > collateralRate && liquidationRate <= RATE_PRECISION, "PCD: invalid liquidationRate");
        require(liquidationBonusRate < RATE_PRECISION, "PCD: invalid liquidationBonusRate");

        CollateralData memory data = collaterals[token];
        // always set active to true
        data.active = true;
        data.enableBorrow = enableBorrow;
        data.enableLiquidate = enableLiquidate;
        data.debtLimit = debtLimit;
        data.collateralRate = collateralRate;
        data.liquidationRate = liquidationRate;
        data.liquidationBonusRate = liquidationBonusRate;
        collaterals[token] = data;
        emit SetCollateralToken(token, enableBorrow, enableLiquidate, debtLimit, collateralRate, liquidationRate, liquidationBonusRate);
    }

    /// @notice Exchange an amount of USD token for LUSD
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The USD token to exchange with LUSD
    /// @param to Which account to receive LUSD
    /// @param amount USD amount deposited
    /// @return lusdAmount LUSD amount minted to sender
    function exchangeIn(address token, address to, uint256 amount) external nonReentrant returns (uint256 lusdAmount) {
        // ===Checks===
        USDData memory data = usds[token];
        require(data.active, "PCD: not usd");
        require(data.enableExchangeIn, "PCD: exchangeIn disabled");

        // ===Interactions===
        // convert from usd token to lusd
        lusdAmount = _convertToLUSDDecimals(token, amount);
        IERC20MetadataUpgradeable(token).safeTransferFrom(_msgSender(), address(vault), amount);
        vault.deposit(token, amount);
        lusd.mint(to, lusdAmount);
        emit ExchangeIn(token, _msgSender(), to, amount, lusdAmount);
    }

    /// @notice Burn an amount of lusd for usd token
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The USD token to exchange out
    /// @param amount LUSD amount to burn
    /// @param to Which account to receive the USD token
    /// @return tokenAmountOut The USD token amount that `to` received
    function exchangeOut(address token, uint256 amount, address to) public nonReentrant returns (uint256 tokenAmountOut) {
        // ===Checks===
        USDData memory data = usds[token];
        require(data.active, "PCD: not usd");
        require(amount > 0, "PCD: amount not set");
        require(to != address(0), "PCD: to not set");

        // ===Effects===
        // cal fee
        uint256 fee = amount * exchangeOutFeeRate / RATE_PRECISION;
        uint256 amountLeft = amount - fee;
        // convert from lusd to usd token
        uint256 tokenAmountLeft = _convertToTokenDecimals(token, amountLeft);
        // set roundUp to false and the real amount represented by `share` may be smaller than `tokenAmountLeft`, it's ok
        uint256 share = vault.toShare(token, tokenAmountLeft, false);

        // ===Interactions===
        // burn lusd from sender
        lusd.burn(_msgSender(), amount);
        // mint fee to `treasury`
        lusd.mint(treasury, fee);
        // withdraw `token` from vault to `to`, it should be reverted if the amount of `token` that vault hold is not enough
        tokenAmountOut = vault.withdraw(token, to, share);
        emit ExchangeOut(token, _msgSender(), to, amount, fee, tokenAmountOut);
    }

    /// @notice Burn LUSD for different USD tokens
    /// @param tokens The USD tokens to exchange out
    /// @param amounts LUSD amounts to burn
    /// @param to Which account to receive the USD tokens
    /// @return tokenAmountOuts The USD token amounts that `to` received
    function exchangeOut(address[] calldata tokens, uint256[] calldata amounts, address to) public returns (uint256[] memory tokenAmountOuts) {
        require(tokens.length == amounts.length, "PCD: tl != al");

        tokenAmountOuts = new uint256[](tokens.length);
        for (uint i; i < tokens.length; i++) {
            tokenAmountOuts[i] = exchangeOut(tokens[i], amounts[i], to);
        }
    }

    /// @notice Add collateral
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The collateral token
    /// @param amount The collateral token amount that added
    /// @param to Which account to receive the collateral
    /// @return share The collateral share amount
    function addCollateral(address token, uint256 amount, address to) public nonReentrant returns (uint256 share) {
        // ===Checks===
        require(amount > 0, "PCD: amount not set");
        require(to != address(0), "PCD: to not set");
        // collateral must be active
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");

        // ===Effects===
        UserDebt memory userDebt = userDebts[to][token];
        // set roundUp to false and the real amount represented by `share` may be smaller than `amount`, it's ok
        share = vault.toShare(token, amount, false);
        data.collateralShare += share;
        userDebt.collateralShare += share;
        collaterals[token] = data;
        userDebts[to][token] = userDebt;

        // ===Interactions===
        // PCD hold the collateral of user
        IERC20MetadataUpgradeable(token).safeTransferFrom(_msgSender(), address(vault), amount);
        uint256 returnedShare = vault.deposit(token, amount);
        require(returnedShare == share, "PCD: internal error of share");
        emit AddCollateral(token, _msgSender(), to, amount, share);
    }

    /// @notice Borrow an amount of LUSD with collateral, no open position fee or debt interest
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The collateral token
    /// @param amount The LUSD amount to borrow
    /// @param to Which account to receive the LUSD
    function borrow(address token, uint256 amount, address to) public nonReentrant {
        // ===Checks===
        require(amount > 0, "PCD: amount not set");
        require(to != address(0), "PCD: to not set");
        // collateral must be active to borrow
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");
        require(data.enableBorrow, "PCD: borrow disabled");
        // must not exceed the debt limit
        uint256 newTotalDebt = data.debtAmount + amount;
        require(newTotalDebt <= data.debtLimit, "PCD: exceeded debt limit");

        // ===Effects===
        UserDebt memory userDebt = userDebts[_msgSender()][token];
        data.debtAmount += amount;
        userDebt.debtAmount += amount;
        collaterals[token] = data;
        userDebts[_msgSender()][token] = userDebt;

        // ===Interactions===
        // after borrow user's debt ratio MUST be healthy
        require(_isDebtRatioHealth(token, data.collateralRate, userDebt.collateralShare, userDebt.debtAmount),
            "PCD: unhealthy debt ratio");

        lusd.mint(to, amount);
        emit Borrow(token, _msgSender(), to, amount);
    }

    /// @notice Add collateral firstly and then borrow
    /// @param token The collateral token
    /// @param collateralAmount The collateral token amount that added
    /// @param debtAmount The LUSD amount to borrow
    /// @param to Which account to receive the LUSD
    /// @param collateralShare The collateral share
    function addCollateralAndBorrow(address token, uint256 collateralAmount, uint256 debtAmount, address to) external returns (uint256 collateralShare) {
        collateralShare = addCollateral(token, collateralAmount, _msgSender());
        borrow(token, debtAmount, to);
    }

    /// @notice Repay LUSD to PCD for user `to`
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The collateral token
    /// @param amount The LUSD amount to repay
    /// @param to Which account to decrease debt
    function repay(address token, uint256 amount, address to) public nonReentrant {
        // ===Checks===
        require(amount > 0, "PCD: amount not set");
        require(to != address(0), "PCD: to not set");
        // collateral must be active
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");

        // ===Effects===
        UserDebt memory userDebt = userDebts[to][token];
        data.debtAmount -= amount;
        userDebt.debtAmount -= amount;
        collaterals[token] = data;
        userDebts[to][token] = userDebt;

        // ===Interactions===
        lusd.burn(_msgSender(), amount);
        emit Repay(token, _msgSender(), to, amount);
    }

    /// @notice Remove the collateral
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The collateral token
    /// @param share The collateral amount represented by `share` that want to withdraw
    /// @param to Which account to receive the collateral
    /// @return amount The collateral amount send to `to`
    function removeCollateral(address token, uint256 share, address to) public nonReentrant returns (uint256 amount) {
        // ===Checks===
        require(share > 0, "PCD: share not set");
        require(to != address(0), "PCD: to not set");
        // collateral must be active
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");

        // ===Effects===
        UserDebt memory userDebt = userDebts[_msgSender()][token];
        // set roundUp to false and the `amount` may be smaller than real amount represented by `share`, it's ok
        amount = vault.toAmount(token, share, false);
        data.collateralShare -= share;
        userDebt.collateralShare -= share;
        collaterals[token] = data;
        userDebts[_msgSender()][token] = userDebt;

        // ===Interactions===
        // after remove collateral user's debt ratio MUST be healthy
        require(_isDebtRatioHealth(token, data.collateralRate, userDebt.collateralShare, userDebt.debtAmount),
            "PCD: unhealthy debt ratio");

        uint256 returnedAmount = vault.withdraw(token, to, share);
        require(returnedAmount == amount, "PCD: internal error of amount");
        emit RemoveCollateral(token, _msgSender(), to, amount);
    }

    /// @notice Repay the debt and the collateral back
    /// @param token The collateral token
    /// @param debtAmount The LUSD amount to repay
    /// @param collateralShare The collateral amount represented by `collateralShare` that want to withdraw
    /// @param to Which account to receive the collateral
    /// @return collateralAmount The collateral amount send to `to`
    function repayAndRemoveCollateral(address token, uint256 debtAmount, uint256 collateralShare, address to) external returns (uint256 collateralAmount) {
        repay(token, debtAmount, _msgSender());
        collateralAmount = removeCollateral(token, collateralShare, to);
    }

    /// @notice Get user current debt ratio
    /// @param token The collateral token
    /// @param user The user who own debt
    function getUserDebtRatio(address token, address user) external view returns (uint256 debtRatio) {
        require(user != address(0), "PCD: user not set");
        // collateral must be active
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");

        UserDebt memory userDebt = userDebts[user][token];
        uint256 debtMax = _calMaxDebt(token, RATE_PRECISION, userDebt.collateralShare);
        if (debtMax == 0) {
            return 0;
        }
        return userDebt.debtAmount * RATE_PRECISION / debtMax;
    }

    /// @notice Repay LUSD for user and get collateral at a discount
    /// @dev Prevent reentrancy
    /// Do not break the Checks-Effects-Interactions rule
    /// @param token The collateral token to liquidate
    /// @param user Liquidated user who's debt ratio is not healthy
    /// @param debtAmount The amount liquidator want to repay for the liquidated user
    /// @param to Which account to receive the collateral token
    /// @return tokenAmountOut The collateral token amount that `to` received
    function liquidate(address token, address user, uint256 debtAmount, address to) public nonReentrant returns (uint256 tokenAmountOut) {
        // ===Checks===
        require(debtAmount > 0, "PCD: debt amount not set");
        require(to != address(0), "PCD: to not set");
        // collateral must be active to liquidate
        CollateralData memory data = collaterals[token];
        require(data.active, "PCD: collateral not active");
        require(data.enableLiquidate, "PCD: liquidate disabled");
        // user debt ratio must be larger than liquidationRate
        UserDebt memory userDebt = userDebts[user][token];
        require(!_isDebtRatioHealth(token, data.liquidationRate, userDebt.collateralShare, userDebt.debtAmount),
            "PCD: invalid liquidate");

        // ===Effects===
        // the collateral liquidator received = (1 + bonus) * debtAmount / collateralPrice
        // set roundUp to false to reduce the loss of user
        uint256 price = oracle.getPrice(address(token));
        uint256 collateralShare = vault.toShare(token,
            (RATE_PRECISION + data.liquidationBonusRate) * debtAmount * PRICE_PRECISION / (price * RATE_PRECISION),
            false);
        data.debtAmount -= debtAmount;
        data.collateralShare -= collateralShare;
        userDebt.debtAmount -= debtAmount;
        userDebt.collateralShare -= collateralShare;
        // liquidator can not repay all amount of debt for user
        // after liquidate, user's debt ratio must be higher than `collateralRate`
        // this can reduces the loss of user
        require(!_isDebtRatioHealth(token, data.collateralRate, userDebt.collateralShare, userDebt.debtAmount),
            "PCD: liquidate too much debt");

        // ===Interactions===
        // burn lusd from sender
        lusd.burn(_msgSender(), debtAmount);
        emit Repay(token, _msgSender(), user, debtAmount);
        // withdraw `token` from vault to `to`
        tokenAmountOut = vault.withdraw(token, to, collateralShare);
        emit RemoveCollateral(token, user, to, tokenAmountOut);
    }

    function _isDebtRatioHealth(address token,
        uint32 collateralRate,
        uint256 collateralShare,
        uint256 debtAmount) internal view returns (bool) {
        if (debtAmount == 0) {
            return true;
        }
        uint256 debtMax = _calMaxDebt(token, collateralRate, collateralShare);
        return debtAmount <= debtMax;
    }

    /// @dev maximum debt that collateral can generate
    function _calMaxDebt(address token,
        uint32 collateralRate,
        uint256 collateralShare) internal view returns (uint256 debtMax) {
        if (collateralShare == 0) {
            return 0;
        }

        // set roundUp to false and the returned `collateralAmount` may be smaller than real amount represented by `collateralShare`, it's ok
        uint256 collateralAmount = vault.toAmount(token, collateralShare, false);
        if (collateralAmount == 0) {
            return 0;
        }

        // get exchange rate(with accuracy improvement) from oracle
        // check debt ratio must be reverted if `getPrice` failed
        uint256 price = oracle.getPrice(address(token));
        uint256 collateralValue = collateralAmount * price / PRICE_PRECISION;

        // maximum debt that collateral can generate
        debtMax = collateralValue * collateralRate / RATE_PRECISION;
    }

    // solhint-disable no-inline-assembly
    function _convertToLUSDDecimals(address token, uint256 amount) internal view returns (uint256 lusdAmount) {
        uint256 decimalsDiff = lusd.decimals() - IERC20MetadataUpgradeable(token).decimals();
        if (decimalsDiff == 0) {
            // most case
            lusdAmount = amount;
        } else {
            assembly {
                lusdAmount := mul(amount, exp(10, decimalsDiff))
            }
        }
    }

    // solhint-disable no-inline-assembly
    function _convertToTokenDecimals(address token, uint256 amount) internal view returns (uint256 tokenAmount) {
        uint256 decimalsDiff = lusd.decimals() - IERC20MetadataUpgradeable(token).decimals();
        if (decimalsDiff == 0) {
            // most case
            tokenAmount = amount;
        } else {
            assembly {
                tokenAmount := div(amount, exp(10, decimalsDiff))
            }
        }
    }
}
