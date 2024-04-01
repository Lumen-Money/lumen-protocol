// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IRewardFacet } from "../interfaces/IRewardFacet.sol";
import { LUMENRewardsHelper, LuToken } from "./LUMENRewardsHelper.sol";
import { SafeERC20, IERC20 } from "../../../Utils/SafeERC20.sol";
import { LuErc20Interface } from "../../../Tokens/LuTokens/LuTokenInterfaces.sol";
import "../../../Swap/lib/TransferHelper.sol";

/**
 * @title RewardFacet
 * @author LmnFi
 * @dev This facet contains all the methods related to the reward functionality
 * @notice This facet contract provides the external functions related to all claims and rewards of the protocol
 */
contract RewardFacet is IRewardFacet, LUMENRewardsHelper {
    /// @notice Emitted when LmnFi is granted by admin
    event LumenGranted(address indexed recipient, uint256 amount);

    using SafeERC20 for IERC20;

    /**
     * @notice Claim all the lumen accrued by holder in all markets and LUMUSD
     * @param holder The address to claim LUMEN for
     */
    function claimLumen(address holder) public {
        return claimLumen(holder, allMarkets);
    }

    /**
     * @notice Claim all the lumen accrued by holder in the specified markets
     * @param holder The address to claim LUMEN for
     * @param luTokens The list of markets to claim LUMEN in
     */
    function claimLumen(address holder, LuToken[] memory luTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimLumen(holders, luTokens, true, true);
    }

    /**
     * @notice Claim all lumen accrued by the holders
     * @param holders The addresses to claim LUMEN for
     * @param luTokens The list of markets to claim LUMEN in
     * @param borrowers Whether or not to claim LUMEN earned by borrowing
     * @param suppliers Whether or not to claim LUMEN earned by supplying
     */
    function claimLumen(address[] memory holders, LuToken[] memory luTokens, bool borrowers, bool suppliers) public {
        claimLumen(holders, luTokens, borrowers, suppliers, false);
    }

    /**
     * @notice Claim all the lumen accrued by holder in all markets, a shorthand for `claimLumen` with collateral set to `true`
     * @param holder The address to claim LUMEN for
     */
    function claimLumenAsCollateral(address holder) external {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimLumen(holders, allMarkets, true, true, true);
    }

    /**
     * @notice Transfer LUMEN to the user with user's shortfall considered
     * @dev Note: If there is not enough LUMEN, we do not perform the transfer all
     * @param user The address of the user to transfer LUMEN to
     * @param amount The amount of LUMEN to (possibly) transfer
     * @param shortfall The shortfall of the user
     * @param collateral Whether or not we will use user's lumen reward as collateral to pay off the debt
     * @return The amount of LUMEN which was NOT transferred to the user
     */
    function grantLUMENInternal(
        address user,
        uint256 amount,
        uint256 shortfall,
        bool collateral
    ) internal returns (uint256) {
        if (_lumenToken == address(0)) {
            // Allocation is not enabled yet
            return 0;
        }

        if (amount == 0 || amount > IERC20(_lumenToken).balanceOf(address(this))) {
            return amount;
        }

        if (shortfall == 0) {
            IERC20(_lumenToken).safeTransfer(user, amount);
            return 0;
        }
        // If user's bankrupt and doesn't use pending lumen as collateral, don't grant
        // anything, otherwise, we will transfer the pending lumen as collateral to
        // luUMEN token and mint luUMEN for the user
        //
        // If mintBehalf failed, don't grant any lumen
        require(collateral, "bankrupt");

        if (_luLumenToken != address(0)) {
            TransferHelper.safeApprove(_lumenToken, _luLumenToken, 0);
            TransferHelper.safeApprove(_lumenToken, _luLumenToken, amount);
            require(
                LuErc20Interface(_luLumenToken).mintBehalf(user, amount) == uint256(Error.NO_ERROR),
                "mint behalf error"
            );
        }

        // set lumenAccrued[user] to 0
        return 0;
    }

    /*** LmnFi Distribution Admin ***/

    /**
     * @notice Transfer LUMEN to the recipient
     * @dev Allows the contract admin to transfer LUMEN to any recipient based on the recipient's shortfall
     *      Note: If there is not enough LUMEN, we do not perform the transfer all
     * @param recipient The address of the recipient to transfer LUMEN to
     * @param amount The amount of LUMEN to (possibly) transfer
     */
    function _grantLUMEN(address recipient, uint256 amount) external {
        ensureAdmin();
        uint256 amountLeft = grantLUMENInternal(recipient, amount, 0, false);
        require(amountLeft == 0, "no lumen");
        emit LumenGranted(recipient, amount);
    }

    /**
     * @notice Return the address of the LUMEN luToken
     * @return The address of LUMEN luToken
     */
    function getLUMENLuTokenAddress() public view returns (address) {
        return _luLumenToken;
    }

    /**
     * @notice Claim all lumen accrued by the holders
     * @param holders The addresses to claim LUMEN for
     * @param luTokens The list of markets to claim LUMEN in
     * @param borrowers Whether or not to claim LUMEN earned by borrowing
     * @param suppliers Whether or not to claim LUMEN earned by supplying
     * @param collateral Whether or not to use LUMEN earned as collateral, only takes effect when the holder has a shortfall
     */
    function claimLumen(
        address[] memory holders,
        LuToken[] memory luTokens,
        bool borrowers,
        bool suppliers,
        bool collateral
    ) public {
        uint256 j;
        uint256 holdersLength = holders.length;
        uint256 luTokensLength = luTokens.length;
        for (uint256 i; i < luTokensLength; ++i) {
            LuToken luToken = luTokens[i];
            ensureListed(markets[address(luToken)]);
            if (borrowers) {
                Exp memory borrowIndex = Exp({ mantissa: luToken.borrowIndex() });
                updateLumenBorrowIndex(address(luToken), borrowIndex);
                for (j = 0; j < holdersLength; ++j) {
                    distributeBorrowerLumen(address(luToken), holders[j], borrowIndex);
                }
            }
            if (suppliers) {
                updateLumenSupplyIndex(address(luToken));
                for (j = 0; j < holdersLength; ++j) {
                    distributeSupplierLumen(address(luToken), holders[j]);
                }
            }
        }

        for (j = 0; j < holdersLength; ++j) {
            address holder = holders[j];
            // If there is a positive shortfall, the LUMEN reward is accrued,
            // but won't be granted to this holder
            (, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(holder, LuToken(address(0)), 0, 0);

            uint256 value = lumenAccrued[holder];
            lumenAccrued[holder] = 0;

            uint256 returnAmount = grantLUMENInternal(holder, value, shortfall, collateral);

            // returnAmount can only be positive if balance of lumenAddress is less than grant amount(lumenAccrued[holder])
            if (returnAmount != 0) {
                lumenAccrued[holder] = returnAmount;
            }
        }
    }
}
