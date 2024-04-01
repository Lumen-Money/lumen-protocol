// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { FacetBase, LuToken } from "./FacetBase.sol";

/**
 * @title LUMENRewardsHelper
 * @author LmnFi
 * @dev This contract contains internal functions used in RewardFacet and PolicyFacet
 * @notice This facet contract contains the shared functions used by the RewardFacet and PolicyFacet
 */
contract LUMENRewardsHelper is FacetBase {
    /// @notice Emitted when LUMEN is distributed to a borrower
    event DistributedBorrowerLumen(
        LuToken indexed luToken,
        address indexed borrower,
        uint256 lumenDelta,
        uint256 lumenBorrowIndex
    );

    /// @notice Emitted when LUMEN is distributed to a supplier
    event DistributedSupplierLumen(
        LuToken indexed luToken,
        address indexed supplier,
        uint256 lumenDelta,
        uint256 lumenSupplyIndex
    );

    /**
     * @notice Accrue LUMEN to the market by updating the borrow index
     * @param luToken The market whose borrow index to update
     */
    function updateLumenBorrowIndex(address luToken, Exp memory marketBorrowIndex) internal {
        LumenMarketState storage borrowState = lumenBorrowState[luToken];
        uint256 borrowSpeed = lumenBorrowSpeeds[luToken];
        uint32 blockNumber = getBlockNumberAsUint32();
        uint256 deltaBlocks = sub_(blockNumber, borrowState.block);
        if (deltaBlocks != 0 && borrowSpeed != 0) {
            uint256 borrowAmount = div_(LuToken(luToken).totalBorrows(), marketBorrowIndex);
            uint256 accruedLumen = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount != 0 ? fraction(accruedLumen, borrowAmount) : Double({ mantissa: 0 });
            borrowState.index = safe224(add_(Double({ mantissa: borrowState.index }), ratio).mantissa, "224");
            borrowState.block = blockNumber;
        } else if (deltaBlocks != 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue LUMEN to the market by updating the supply index
     * @param luToken The market whose supply index to update
     */
    function updateLumenSupplyIndex(address luToken) internal {
        LumenMarketState storage supplyState = lumenSupplyState[luToken];
        uint256 supplySpeed = lumenSupplySpeeds[luToken];
        uint32 blockNumber = getBlockNumberAsUint32();

        uint256 deltaBlocks = sub_(blockNumber, supplyState.block);
        if (deltaBlocks != 0 && supplySpeed != 0) {
            uint256 supplyTokens = LuToken(luToken).totalSupply();
            uint256 accruedLumen = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens != 0 ? fraction(accruedLumen, supplyTokens) : Double({ mantissa: 0 });
            supplyState.index = safe224(add_(Double({ mantissa: supplyState.index }), ratio).mantissa, "224");
            supplyState.block = blockNumber;
        } else if (deltaBlocks != 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate LUMEN accrued by a supplier and possibly transfer it to them
     * @param luToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute LUMEN to
     */
    function distributeSupplierLumen(address luToken, address supplier) internal {
        if (address(lumUsdVaultAddress) != address(0)) {
            releaseToVault();
        }
        uint256 supplyIndex = lumenSupplyState[luToken].index;
        uint256 supplierIndex = lumenSupplierIndex[luToken][supplier];
        // Update supplier's index to the current index since we are distributing accrued LUMEN
        lumenSupplierIndex[luToken][supplier] = supplyIndex;
        if (supplierIndex == 0 && supplyIndex >= lumenInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with LUMEN accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = lumenInitialIndex;
        }
        // Calculate change in the cumulative sum of the LUMEN per luToken accrued
        Double memory deltaIndex = Double({ mantissa: sub_(supplyIndex, supplierIndex) });
        // Multiply of supplierTokens and supplierDelta
        uint256 supplierDelta = mul_(LuToken(luToken).balanceOf(supplier), deltaIndex);
        // Addition of supplierAccrued and supplierDelta
        lumenAccrued[supplier] = add_(lumenAccrued[supplier], supplierDelta);
        emit DistributedSupplierLumen(LuToken(luToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate LUMEN accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol
     * @param luToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute LUMEN to
     */
    function distributeBorrowerLumen(address luToken, address borrower, Exp memory marketBorrowIndex) internal {
        if (address(lumUsdVaultAddress) != address(0)) {
            releaseToVault();
        }
        uint256 borrowIndex = lumenBorrowState[luToken].index;
        uint256 borrowerIndex = lumenBorrowerIndex[luToken][borrower];
        // Update borrowers's index to the current index since we are distributing accrued LUMEN
        lumenBorrowerIndex[luToken][borrower] = borrowIndex;
        if (borrowerIndex == 0 && borrowIndex >= lumenInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with LUMEN accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = lumenInitialIndex;
        }
        // Calculate change in the cumulative sum of the LUMEN per borrowed unit accrued
        Double memory deltaIndex = Double({ mantissa: sub_(borrowIndex, borrowerIndex) });
        uint256 borrowerDelta = mul_(div_(LuToken(luToken).borrowBalanceStored(borrower), marketBorrowIndex), deltaIndex);
        lumenAccrued[borrower] = add_(lumenAccrued[borrower], borrowerDelta);
        emit DistributedBorrowerLumen(LuToken(luToken), borrower, borrowerDelta, borrowIndex);
    }
}
