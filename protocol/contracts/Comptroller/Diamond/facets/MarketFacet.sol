// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IMarketFacet } from "../interfaces/IMarketFacet.sol";
import { FacetBase, LuToken } from "./FacetBase.sol";

/**
 * @title MarketFacet
 * @author LmnFi
 * @dev This facet contains all the methods related to the market's management in the pool
 * @notice This facet contract contains functions regarding markets
 */
contract MarketFacet is IMarketFacet, FacetBase {
    /// @notice Emitted when an admin supports a market
    event MarketListed(LuToken indexed luToken);

    /// @notice Emitted when an account exits a market
    event MarketExited(LuToken indexed luToken, address indexed account);

    /// @notice Emitted when the borrowing delegate rights are updated for an account
    event DelegateUpdated(address indexed borrower, address indexed delegate, bool allowDelegatedBorrows);

    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() public pure returns (bool) {
        return true;
    }

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (LuToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market
     * @return The list of market addresses
     */
    function getAllMarkets() external view returns (LuToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in luToken.liquidateBorrowFresh)
     * @param luTokenBorrowed The address of the borrowed luToken
     * @param luTokenCollateral The address of the collateral luToken
     * @param actualRepayAmount The amount of luTokenBorrowed underlying to convert into luTokenCollateral tokens
     * @return (errorCode, number of luTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address luTokenBorrowed,
        address luTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        (uint256 err, uint256 seizeTokens) = comptrollerLens.liquidateCalculateSeizeTokens(
            address(this),
            luTokenBorrowed,
            luTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in luToken.liquidateBorrowFresh)
     * @param luTokenCollateral The address of the collateral luToken
     * @param actualRepayAmount The amount of luTokenBorrowed underlying to convert into luTokenCollateral tokens
     * @return (errorCode, number of luTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateLUMUSDCalculateSeizeTokens(
        address luTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        (uint256 err, uint256 seizeTokens) = comptrollerLens.liquidateLUMUSDCalculateSeizeTokens(
            address(this),
            luTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param luToken The luToken to check
     * @return True if the account is in the asset, otherwise false
     */
    function checkMembership(address account, LuToken luToken) external view returns (bool) {
        return markets[address(luToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param luTokens The list of addresses of the luToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] calldata luTokens) external returns (uint256[] memory) {
        uint256 len = luTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            results[i] = uint256(addToMarketInternal(LuToken(luTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow
     * @param luTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address luTokenAddress) external returns (uint256) {
        checkActionPauseState(luTokenAddress, Action.EXIT_MARKET);

        LuToken luToken = LuToken(luTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the luToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = luToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(luTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(luToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set luToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete luToken from the account’s list of assets */
        // In order to delete luToken, copy last item in list to location of item to be removed, reduce length by 1
        LuToken[] storage userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 i;
        for (; i < len; ++i) {
            if (userAssetList[i] == luToken) {
                userAssetList[i] = userAssetList[len - 1];
                userAssetList.pop();
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(i < len);

        emit MarketExited(luToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Allows a privileged role to add and list markets to the Comptroller
     * @param luToken The address of the market (token) to list
     * @return uint256 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(LuToken luToken) external returns (uint256) {
        ensureAllowed("_supportMarket(address)");

        if (markets[address(luToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        luToken.isLuToken(); // Sanity check to make sure its really a LuToken

        // Note that isLumen is not in active use anymore
        Market storage newMarket = markets[address(luToken)];
        newMarket.isListed = true;
        newMarket.isLumen = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(luToken);
        _initializeMarket(address(luToken));

        emit MarketListed(luToken);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Grants or revokes the borrowing delegate rights to / from an account
     *  If allowed, the delegate will be able to borrow funds on behalf of the sender
     *  Upon a delegated borrow, the delegate will receive the funds, and the borrower
     *  will see the debt on their account
     * @param delegate The address to update the rights for
     * @param allowBorrows Whether to grant (true) or revoke (false) the rights
     */
    function updateDelegate(address delegate, bool allowBorrows) external {
        _updateDelegate(msg.sender, delegate, allowBorrows);
    }

    function _updateDelegate(address borrower, address delegate, bool allowBorrows) internal {
        approvedDelegates[borrower][delegate] = allowBorrows;
        emit DelegateUpdated(borrower, delegate, allowBorrows);
    }

    function _addMarketInternal(LuToken luToken) internal {
        uint256 allMarketsLength = allMarkets.length;
        for (uint256 i; i < allMarketsLength; ++i) {
            require(allMarkets[i] != luToken, "already added");
        }
        allMarkets.push(luToken);
    }

    function _initializeMarket(address luToken) internal {
        uint32 blockNumber = getBlockNumberAsUint32();

        LumenMarketState storage supplyState = lumenSupplyState[luToken];
        LumenMarketState storage borrowState = lumenBorrowState[luToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = lumenInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = lumenInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }
}
