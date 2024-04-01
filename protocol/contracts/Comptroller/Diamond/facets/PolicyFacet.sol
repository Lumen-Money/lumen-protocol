// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IPolicyFacet } from "../interfaces/IPolicyFacet.sol";

import { LUMENRewardsHelper, LuToken } from "./LUMENRewardsHelper.sol";

/**
 * @title PolicyFacet
 * @author LmnFi
 * @dev This facet contains all the hooks used while transferring the assets
 * @notice This facet contract contains all the external pre-hook functions related to luToken
 */
contract PolicyFacet is IPolicyFacet, LUMENRewardsHelper {
    /// @notice Emitted when a new borrow-side LUMEN speed is calculated for a market
    event LumenBorrowSpeedUpdated(LuToken indexed luToken, uint256 newSpeed);

    /// @notice Emitted when a new supply-side LUMEN speed is calculated for a market
    event LumenSupplySpeedUpdated(LuToken indexed luToken, uint256 newSpeed);

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param luToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address luToken, address minter, uint256 mintAmount) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(luToken, Action.MINT);
        ensureListed(markets[luToken]);

        uint256 supplyCap = supplyCaps[luToken];
        require(supplyCap != 0, "market supply cap is 0");

        uint256 luTokenSupply = LuToken(luToken).totalSupply();
        Exp memory exchangeRate = Exp({ mantissa: LuToken(luToken).exchangeRateStored() });
        uint256 nextTotalSupply = mul_ScalarTruncateAddUInt(exchangeRate, luTokenSupply, mintAmount);
        require(nextTotalSupply <= supplyCap, "market supply cap reached");

        // Keep the flywheel moving
        updateLumenSupplyIndex(luToken);
        distributeSupplierLumen(luToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param luToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address luToken, address minter, uint256 actualMintAmount, uint256 mintTokens) external {}

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param luToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of luTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address luToken, address redeemer, uint256 redeemTokens) external returns (uint256) {
        checkProtocolPauseState();
        checkActionPauseState(luToken, Action.REDEEM);

        uint256 allowed = redeemAllowedInternal(luToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateLumenSupplyIndex(luToken);
        distributeSupplierLumen(luToken, redeemer);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit log
     * @param luToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    // solhint-disable-next-line no-unused-vars
    function redeemVerify(address luToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external pure {
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param luToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address luToken, address borrower, uint256 borrowAmount) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(luToken, Action.BORROW);

        ensureListed(markets[luToken]);

        if (!markets[luToken].accountMembership[borrower]) {
            // only luTokens may call borrowAllowed if borrower not in market
            require(msg.sender == luToken, "sender must be luToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(LuToken(luToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }
        }

        if (oracle.getUnderlyingPrice(LuToken(luToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[luToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 nextTotalBorrows = add_(LuToken(luToken).totalBorrows(), borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            LuToken(luToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall != 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: LuToken(luToken).borrowIndex() });
        updateLumenBorrowIndex(luToken, borrowIndex);
        distributeBorrowerLumen(luToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit log
     * @param luToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    // solhint-disable-next-line no-unused-vars
    function borrowVerify(address luToken, address borrower, uint256 borrowAmount) external {}

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param luToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address luToken,
        // solhint-disable-next-line no-unused-vars
        address payer,
        address borrower,
        // solhint-disable-next-line no-unused-vars
        uint256 repayAmount
    ) external returns (uint256) {
        checkProtocolPauseState();
        checkActionPauseState(luToken, Action.REPAY);
        ensureListed(markets[luToken]);

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: LuToken(luToken).borrowIndex() });
        updateLumenBorrowIndex(luToken, borrowIndex);
        distributeBorrowerLumen(luToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit log
     * @param luToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address luToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external {}

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param luTokenBorrowed Asset which was borrowed by the borrower
     * @param luTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256) {
        checkProtocolPauseState();

        // if we want to pause liquidating to luTokenCollateral, we should pause seizing
        checkActionPauseState(luTokenBorrowed, Action.LIQUIDATE);

        if (liquidatorContract != address(0) && liquidator != liquidatorContract) {
            return uint256(Error.UNAUTHORIZED);
        }

        ensureListed(markets[luTokenCollateral]);

        uint256 borrowBalance;
        if (address(luTokenBorrowed) != address(lumUsdController)) {
            ensureListed(markets[luTokenBorrowed]);
            borrowBalance = LuToken(luTokenBorrowed).borrowBalanceStored(borrower);
        } else {
            borrowBalance = lumUsdController.getLUMUSDRepayAmount(borrower);
        }

        if (isForcedLiquidationEnabled[luTokenBorrowed]) {
            if (repayAmount > borrowBalance) {
                return uint(Error.TOO_MUCH_REPAY);
            }
            return uint(Error.NO_ERROR);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(borrower, LuToken(address(0)), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall == 0) {
            return uint256(Error.INSUFFICIENT_SHORTFALL);
        }

        // The liquidator may not repay more than what is allowed by the closeFactor
        //-- maxClose = multipy of closeFactorMantissa and borrowBalance
        if (repayAmount > mul_ScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance)) {
            return uint256(Error.TOO_MUCH_REPAY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param luTokenBorrowed Asset which was borrowed by the borrower
     * @param luTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     * @param seizeTokens The amount of collateral token that will be seized
     */
    function liquidateBorrowVerify(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external {}

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param luTokenCollateral Asset which was used as collateral and will be seized
     * @param luTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens // solhint-disable-line no-unused-vars
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(luTokenCollateral, Action.SEIZE);

        Market storage market = markets[luTokenCollateral];

        // We've added LUMUSDController as a borrowed token list check for seize
        ensureListed(market);

        if (!market.accountMembership[borrower]) {
            return uint256(Error.MARKET_NOT_COLLATERAL);
        }

        if (address(luTokenBorrowed) != address(lumUsdController)) {
            ensureListed(markets[luTokenBorrowed]);
        }

        if (LuToken(luTokenCollateral).comptroller() != LuToken(luTokenBorrowed).comptroller()) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateLumenSupplyIndex(luTokenCollateral);
        distributeSupplierLumen(luTokenCollateral, borrower);
        distributeSupplierLumen(luTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit log
     * @param luTokenCollateral Asset which was used as collateral and will be seized
     * @param luTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    // solhint-disable-next-line no-unused-vars
    function seizeVerify(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external {}

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param luToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of luTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address luToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(luToken, Action.TRANSFER);

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(luToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateLumenSupplyIndex(luToken);
        distributeSupplierLumen(luToken, src);
        distributeSupplierLumen(luToken, dst);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit log
     * @param luToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of luTokens to transfer
     */
    // solhint-disable-next-line no-unused-vars
    function transferVerify(address luToken, address src, address dst, uint256 transferTokens) external {}

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            LuToken(address(0)),
            0,
            0
        );

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param luTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address luTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            LuToken(luTokenModify),
            redeemTokens,
            borrowAmount
        );
        return (uint256(err), liquidity, shortfall);
    }

    // setter functionality
    /**
     * @notice Set LUMEN speed for a single market
     * @dev Allows the contract admin to set LUMEN speed for a market
     * @param luTokens The market whose LUMEN speed to update
     * @param supplySpeeds New LUMEN speed for supply
     * @param borrowSpeeds New LUMEN speed for borrow
     */
    function _setLumenSpeeds(
        LuToken[] calldata luTokens,
        uint256[] calldata supplySpeeds,
        uint256[] calldata borrowSpeeds
    ) external {
        ensureAdmin();

        uint256 numTokens = luTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid input");

        for (uint256 i; i < numTokens; ++i) {
            ensureNonzeroAddress(address(luTokens[i]));
            setLumenSpeedInternal(luTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    function setLumenSpeedInternal(LuToken luToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        ensureListed(markets[address(luToken)]);

        if (lumenSupplySpeeds[address(luToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. LUMEN accrued properly for the old speed, and
            //  2. LUMEN accrued at the new speed starts after this block.

            updateLumenSupplyIndex(address(luToken));
            // Update speed and emit event
            lumenSupplySpeeds[address(luToken)] = supplySpeed;
            emit LumenSupplySpeedUpdated(luToken, supplySpeed);
        }

        if (lumenBorrowSpeeds[address(luToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. LUMEN accrued properly for the old speed, and
            //  2. LUMEN accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: luToken.borrowIndex() });
            updateLumenBorrowIndex(address(luToken), borrowIndex);

            // Update speed and emit event
            lumenBorrowSpeeds[address(luToken)] = borrowSpeed;
            emit LumenBorrowSpeedUpdated(luToken, borrowSpeed);
        }
    }
}
