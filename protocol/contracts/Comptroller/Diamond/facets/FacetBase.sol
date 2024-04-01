// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { LuToken, ComptrollerErrorReporter, ExponentialNoError } from "../../../Tokens/LuTokens/LuToken.sol";
import { ILUMUSDVault } from "../../../Comptroller/ComptrollerInterface.sol";
import { ComptrollerV14Storage } from "../../../Comptroller/ComptrollerStorage.sol";
import { IAccessControlManager } from "../../../Governance/IAccessControlManager.sol";
import { SafeERC20, IERC20 } from "../../../Utils/SafeERC20.sol";
import { IBaseFacet } from "../interfaces/IBaseFacet.sol";

/**
 * @title FacetBase
 * @author LmnFi
 * @notice This facet contract contains functions related to access and checks
 */
contract FacetBase is IBaseFacet, ComptrollerV14Storage, ExponentialNoError, ComptrollerErrorReporter {
    /// @notice Emitted when an account enters a market
    event MarketEntered(LuToken indexed luToken, address indexed account);

    /// @notice Emitted when LUMEN is distributed to LUMUSD Vault
    event DistributedLUMUSDVaultLumen(uint256 amount);

    using SafeERC20 for IERC20;

    /// @notice The initial LmnFi index for a market
    uint224 public constant lumenInitialIndex = 1e36;
    // closeFactorMantissa must be strictly greater than this value
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05
    // closeFactorMantissa must not exceed this value
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9
    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    /// @notice Reverts if the protocol is paused
    function checkProtocolPauseState() internal view {
        require(!protocolPaused, "protocol is paused");
    }

    /// @notice Reverts if a certain action is paused on a market
    function checkActionPauseState(address market, Action action) internal view {
        require(!actionPaused(market, action), "action is paused");
    }

    /// @notice Reverts if the caller is not admin
    function ensureAdmin() internal view {
        require(msg.sender == admin, "only admin can");
    }

    /// @notice Checks the passed address is nonzero
    function ensureNonzeroAddress(address someone) internal pure {
        require(someone != address(0), "can't be zero address");
    }

    /// @notice Reverts if the market is not listed
    function ensureListed(Market storage market) internal view {
        require(market.isListed, "market not listed");
    }

    /// @notice Reverts if the caller is neither admin nor the passed address
    function ensureAdminOr(address privilegedAddress) internal view {
        require(msg.sender == admin || msg.sender == privilegedAddress, "access denied");
    }

    /// @notice Checks the caller is allowed to call the specified fuction
    function ensureAllowed(string memory functionSig) internal view {
        require(IAccessControlManager(accessControl).isAllowedToCall(msg.sender, functionSig), "access denied");
    }

    /**
     * @notice Checks if a certain action is paused on a market
     * @param action Action id
     * @param market luToken address
     */
    function actionPaused(address market, Action action) public view returns (bool) {
        return _actionPaused[market][uint256(action)];
    }

    /**
     * @notice Get the latest block number
     */
    function getBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    /**
     * @notice Get the latest block number with the safe32 check
     */
    function getBlockNumberAsUint32() internal view returns (uint32) {
        return safe32(getBlockNumber(), "block # > 32 bits");
    }

    /**
     * @notice Transfer LUMEN to LUMUSD Vault
     */
    function releaseToVault() internal {
        if (releaseStartBlock == 0 || _lumenToken == address(0) || getBlockNumber() < releaseStartBlock) {
            return;
        }

        uint256 lumenBalance = IERC20(_lumenToken).balanceOf(address(this));
        if (lumenBalance == 0) {
            return;
        }

        uint256 actualAmount;
        uint256 deltaBlocks = sub_(getBlockNumber(), releaseStartBlock);
        // releaseAmount = lumenLUMUSDVaultRate * deltaBlocks
        uint256 _releaseAmount = mul_(lumenLUMUSDVaultRate, deltaBlocks);

        if (lumenBalance >= _releaseAmount) {
            actualAmount = _releaseAmount;
        } else {
            actualAmount = lumenBalance;
        }

        if (actualAmount < minReleaseAmount) {
            return;
        }

        releaseStartBlock = getBlockNumber();

        IERC20(_lumenToken).safeTransfer(lumUsdVaultAddress, actualAmount);
        emit DistributedLUMUSDVaultLumen(actualAmount);

        ILUMUSDVault(lumUsdVaultAddress).updatePendingRewards();
    }

    /**
     * @notice Return the address of the LUMEN token
     * @return The address of LUMEN
     */
    function getLUMENAddress() external view returns (address) {
        return _lumenToken;
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param luTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral luToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        LuToken luTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view returns (Error, uint256, uint256) {
        (uint256 err, uint256 liquidity, uint256 shortfall) = comptrollerLens.getHypotheticalAccountLiquidity(
            address(this),
            account,
            luTokenModify,
            redeemTokens,
            borrowAmount
        );
        return (Error(err), liquidity, shortfall);
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param luToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(LuToken luToken, address borrower) internal returns (Error) {
        checkActionPauseState(address(luToken), Action.ENTER_MARKET);
        Market storage marketToJoin = markets[address(luToken)];
        ensureListed(marketToJoin);
        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return Error.NO_ERROR;
        }
        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(luToken);

        emit MarketEntered(luToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks for the user is allowed to redeem tokens
     * @param luToken Address of the market
     * @param redeemer Address of the user
     * @param redeemTokens Amount of tokens to redeem
     * @return Success indicator for redeem is allowed or not
     */
    function redeemAllowedInternal(
        address luToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view returns (uint256) {
        ensureListed(markets[luToken]);
        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[luToken].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }
        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            LuToken(luToken),
            redeemTokens,
            0
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall != 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }
        return uint256(Error.NO_ERROR);
    }
}
