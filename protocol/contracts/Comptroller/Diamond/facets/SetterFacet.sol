// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { ISetterFacet } from "../interfaces/ISetterFacet.sol";
import { PriceOracle } from "../../../../../oracle/contracts/PriceOracle.sol";
import { ComptrollerLensInterface } from "../../ComptrollerLensInterface.sol";
import { LUMUSDControllerInterface } from "../../../Tokens/LUMUSD/LUMUSDControllerInterface.sol";
import { FacetBase, LuToken } from "./FacetBase.sol";

/**
 * @title SetterFacet
 * @author LmnFi
 * @dev This facet contains all the setters for the states
 * @notice This facet contract contains all the configurational setter functions
 */
contract SetterFacet is ISetterFacet, FacetBase {
    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint256 oldCloseFactorMantissa, uint256 newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        LuToken indexed luToken,
        uint256 oldCollateralFactorMantissa,
        uint256 newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint256 oldLiquidationIncentiveMantissa, uint256 newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when borrow cap for a luToken is changed
    event NewBorrowCap(LuToken indexed luToken, uint256 newBorrowCap);

    /// @notice Emitted when LUMUSDController is changed
    event NewLUMUSDController(LUMUSDControllerInterface oldLUMUSDController, LUMUSDControllerInterface newLUMUSDController);

    /// @notice Emitted when LUMUSD mint rate is changed by admin
    event NewLUMUSDMintRate(uint256 oldLUMUSDMintRate, uint256 newLUMUSDMintRate);

    /// @notice Emitted when protocol state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice Emitted when treasury guardian is changed
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /// @notice Emitted when treasury address is changed
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /// @notice Emitted when treasury percent is changed
    event NewTreasuryPercent(uint256 oldTreasuryPercent, uint256 newTreasuryPercent);

    /// @notice Emitted when liquidator adress is changed
    event NewLiquidatorContract(address oldLiquidatorContract, address newLiquidatorContract);

    /// @notice Emitted when ComptrollerLens address is changed
    event NewComptrollerLens(address oldComptrollerLens, address newComptrollerLens);

    /// @notice Emitted when supply cap for a luToken is changed
    event NewSupplyCap(LuToken indexed luToken, uint256 newSupplyCap);

    /// @notice Emitted when access control address is changed by admin
    event NewAccessControl(address oldAccessControlAddress, address newAccessControlAddress);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused on a market
    event ActionPausedMarket(LuToken indexed luToken, Action indexed action, bool pauseState);

    /// @notice Emitted when LUMUSD Vault info is changed
    event NewLUMUSDVaultInfo(address indexed vault_, uint256 releaseStartBlock_, uint256 releaseInterval_);

    /// @notice Emitted when LmnFi LUMUSD Vault rate is changed
    event NewLumenLUMUSDVaultRate(uint256 oldLumenLUMUSDVaultRate, uint256 newLumenLUMUSDVaultRate);

    /// @notice Emitted when force liquidation enabled for a market
    event IsForcedLiquidationEnabledUpdated(address indexed luToken, bool enable);

    /**
     * @notice Compare two addresses to ensure they are different
     * @param oldAddress The original address to compare
     * @param newAddress The new address to compare
     */
    modifier compareAddress(address oldAddress, address newAddress) {
        require(oldAddress != newAddress, "old address is same as new address");
        _;
    }

    /**
     * @notice Compare two values to ensure they are different
     * @param oldValue The original value to compare
     * @param newValue The new value to compare
     */
    modifier compareValue(uint256 oldValue, uint256 newValue) {
        require(oldValue != newValue, "old value is same as new value");
        _;
    }

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Allows the contract admin to set a new price oracle used by the Comptroller
     * @return uint256 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(
        PriceOracle newOracle
    ) external compareAddress(address(oracle), address(newOracle)) returns (uint256) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(newOracle));

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Allows the contract admin to set the closeFactor used to liquidate borrows
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint256 0=success, otherwise will revert
     */
    function _setCloseFactor(
        uint256 newCloseFactorMantissa
    ) external compareValue(closeFactorMantissa, newCloseFactorMantissa) returns (uint256) {
        // Check caller is admin
        ensureAdmin();

        Exp memory newCloseFactorExp = Exp({ mantissa: newCloseFactorMantissa });

        //-- Check close factor <= 0.9
        Exp memory highLimit = Exp({ mantissa: closeFactorMaxMantissa });
        //-- Check close factor >= 0.05
        Exp memory lowLimit = Exp({ mantissa: closeFactorMinMantissa });

        if (lessThanExp(highLimit, newCloseFactorExp) || greaterThanExp(lowLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Allows the contract admin to set the address of access control of this contract
     * @param newAccessControlAddress New address for the access control
     * @return uint256 0=success, otherwise will revert
     */
    function _setAccessControl(
        address newAccessControlAddress
    ) external compareAddress(accessControl, newAccessControlAddress) returns (uint256) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(newAccessControlAddress);

        address oldAccessControlAddress = accessControl;

        accessControl = newAccessControlAddress;
        emit NewAccessControl(oldAccessControlAddress, newAccessControlAddress);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Allows a privileged role to set the collateralFactorMantissa
     * @param luToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint256 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        LuToken luToken,
        uint256 newCollateralFactorMantissa
    )
        external
        compareValue(markets[address(luToken)].collateralFactorMantissa, newCollateralFactorMantissa)
        returns (uint256)
    {
        // Check caller is allowed by access control manager
        ensureAllowed("_setCollateralFactor(address,uint256)");
        ensureNonzeroAddress(address(luToken));

        // Verify market is listed
        Market storage market = markets[address(luToken)];
        ensureListed(market);

        Exp memory newCollateralFactorExp = Exp({ mantissa: newCollateralFactorMantissa });

        //-- Check collateral factor <= 0.9
        Exp memory highLimit = Exp({ mantissa: collateralFactorMaxMantissa });
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(luToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(luToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Allows a privileged role to set the liquidationIncentiveMantissa
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint256 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(
        uint256 newLiquidationIncentiveMantissa
    ) external compareValue(liquidationIncentiveMantissa, newLiquidationIncentiveMantissa) returns (uint256) {
        ensureAllowed("_setLiquidationIncentive(uint256)");

        require(newLiquidationIncentiveMantissa >= 1e18, "incentive < 1e18");

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Update the address of the liquidator contract
     * @dev Allows the contract admin to update the address of liquidator contract
     * @param newLiquidatorContract_ The new address of the liquidator contract
     */
    function _setLiquidatorContract(
        address newLiquidatorContract_
    ) external compareAddress(liquidatorContract, newLiquidatorContract_) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(newLiquidatorContract_);
        address oldLiquidatorContract = liquidatorContract;
        liquidatorContract = newLiquidatorContract_;
        emit NewLiquidatorContract(oldLiquidatorContract, newLiquidatorContract_);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @dev Allows the contract admin to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint256 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(
        address newPauseGuardian
    ) external compareAddress(pauseGuardian, newPauseGuardian) returns (uint256) {
        ensureAdmin();
        ensureNonzeroAddress(newPauseGuardian);

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;
        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, newPauseGuardian);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set the given borrow caps for the given luToken market Borrowing that brings total borrows to or above borrow cap will revert
     * @dev Allows a privileged role to set the borrowing cap for a luToken market. A borrow cap of 0 corresponds to unlimited borrowing
     * @param luTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing
     */
    function _setMarketBorrowCaps(LuToken[] calldata luTokens, uint256[] calldata newBorrowCaps) external {
        ensureAllowed("_setMarketBorrowCaps(address[],uint256[])");

        uint256 numMarkets = luTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint256 i; i < numMarkets; ++i) {
            borrowCaps[address(luTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(luTokens[i], newBorrowCaps[i]);
        }
    }


    /**
     * @notice Updates the LUMEN token address
     */
    function _setLUMENAddress(address lumenToken) external {
        ensureAdmin();
        _lumenToken = lumenToken;
    }

    /**
     * @notice Updates the luUMEN token address
     */
    function _setLuLUMENAddress(address luumenToken) external {
        ensureAdmin();
        _luLumenToken = luumenToken;
    }

    /**
     * @notice Set the given supply caps for the given luToken market Supply that brings total Supply to or above supply cap will revert
     * @dev Allows a privileged role to set the supply cap for a luToken. A supply cap of 0 corresponds to Minting NotAllowed
     * @param luTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to Minting NotAllowed
     */
    function _setMarketSupplyCaps(LuToken[] calldata luTokens, uint256[] calldata newSupplyCaps) external {
        ensureAllowed("_setMarketSupplyCaps(address[],uint256[])");

        uint256 numMarkets = luTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint256 i; i < numMarkets; ++i) {
            supplyCaps[address(luTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(luTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Set whole protocol pause/unpause state
     * @dev Allows a privileged role to pause/unpause protocol
     * @param state The new state (true=paused, false=unpaused)
     * @return bool The updated state of the protocol
     */
    function _setProtocolPaused(bool state) external returns (bool) {
        ensureAllowed("_setProtocolPaused(bool)");

        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    /**
     * @notice Pause/unpause certain actions
     * @dev Allows a privileged role to pause/unpause the protocol action state
     * @param markets_ Markets to pause/unpause the actions on
     * @param actions_ List of action ids to pause/unpause
     * @param paused_ The new paused state (true=paused, false=unpaused)
     */
    function _setActionsPaused(address[] calldata markets_, Action[] calldata actions_, bool paused_) external {
        ensureAllowed("_setActionsPaused(address[],uint8[],bool)");

        uint256 numMarkets = markets_.length;
        uint256 numActions = actions_.length;
        for (uint256 marketIdx; marketIdx < numMarkets; ++marketIdx) {
            for (uint256 actionIdx; actionIdx < numActions; ++actionIdx) {
                setActionPausedInternal(markets_[marketIdx], actions_[actionIdx], paused_);
            }
        }
    }

    /**
     * @dev Pause/unpause an action on a market
     * @param market Market to pause/unpause the action on
     * @param action Action id to pause/unpause
     * @param paused The new paused state (true=paused, false=unpaused)
     */
    function setActionPausedInternal(address market, Action action, bool paused) internal {
        ensureListed(markets[market]);
        _actionPaused[market][uint256(action)] = paused;
        emit ActionPausedMarket(LuToken(market), action, paused);
    }

    /**
     * @notice Sets a new LUMUSD controller
     * @dev Admin function to set a new LUMUSD controller
     * @return uint256 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setLUMUSDController(
        LUMUSDControllerInterface lumUsdController_
    ) external compareAddress(address(lumUsdController), address(lumUsdController_)) returns (uint256) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(lumUsdController_));

        LUMUSDControllerInterface oldVaiController = lumUsdController;
        lumUsdController = lumUsdController_;
        emit NewLUMUSDController(oldVaiController, lumUsdController_);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set the LUMUSD mint rate
     * @param newLUMUSDMintRate The new LUMUSD mint rate to be set
     * @return uint256 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setLUMUSDMintRate(
        uint256 newLUMUSDMintRate
    ) external compareValue(lumUsdMintRate, newLUMUSDMintRate) returns (uint256) {
        // Check caller is admin
        ensureAdmin();
        uint256 oldLUMUSDMintRate = lumUsdMintRate;
        lumUsdMintRate = newLUMUSDMintRate;
        emit NewLUMUSDMintRate(oldLUMUSDMintRate, newLUMUSDMintRate);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set the minted LUMUSD amount of the `owner`
     * @param owner The address of the account to set
     * @param amount The amount of LUMUSD to set to the account
     * @return The number of minted LUMUSD by `owner`
     */
    function setMintedLUMUSDOf(address owner, uint256 amount) external returns (uint256) {
        checkProtocolPauseState();

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintLUMUSDGuardianPaused && !repayLUMUSDGuardianPaused, "LUMUSD is paused");
        // Check caller is lumUsdController
        if (msg.sender != address(lumUsdController)) {
            return fail(Error.REJECTION, FailureInfo.SET_MINTED_LUMUSD_REJECTION);
        }
        mintedLUMUSDs[owner] = amount;
        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set the treasury data.
     * @param newTreasuryGuardian The new address of the treasury guardian to be set
     * @param newTreasuryAddress The new address of the treasury to be set
     * @param newTreasuryPercent The new treasury percent to be set
     * @return uint256 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint256 newTreasuryPercent
    ) external returns (uint256) {
        // Check caller is admin
        ensureAdminOr(treasuryGuardian);

        require(newTreasuryPercent < 1e18, "percent >= 100%");
        ensureNonzeroAddress(newTreasuryGuardian);
        ensureNonzeroAddress(newTreasuryAddress);

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint256 oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint256(Error.NO_ERROR);
    }

    /*** LmnFi Distribution ***/

    /**
     * @dev Set ComptrollerLens contract address
     * @param comptrollerLens_ The new ComptrollerLens contract address to be set
     * @return uint256 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptrollerLens(
        ComptrollerLensInterface comptrollerLens_
    ) external compareAddress(address(comptrollerLens), address(comptrollerLens_)) returns (uint256) {
        ensureAdmin();
        ensureNonzeroAddress(address(comptrollerLens_));
        address oldComptrollerLens = address(comptrollerLens);
        comptrollerLens = comptrollerLens_;
        emit NewComptrollerLens(oldComptrollerLens, address(comptrollerLens));

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Set the amount of LUMEN distributed per block to LUMUSD Vault
     * @param lumenLUMUSDVaultRate_ The amount of LUMEN wei per block to distribute to LUMUSD Vault
     */
    function _setLumenLUMUSDVaultRate(
        uint256 lumenLUMUSDVaultRate_
    ) external compareValue(lumenLUMUSDVaultRate, lumenLUMUSDVaultRate_) {
        ensureAdmin();
        if (lumUsdVaultAddress != address(0)) {
            releaseToVault();
        }
        uint256 oldLumenLUMUSDVaultRate = lumenLUMUSDVaultRate;
        lumenLUMUSDVaultRate = lumenLUMUSDVaultRate_;
        emit NewLumenLUMUSDVaultRate(oldLumenLUMUSDVaultRate, lumenLUMUSDVaultRate_);
    }

    /**
     * @notice Set the LUMUSD Vault infos
     * @param vault_ The address of the LUMUSD Vault
     * @param releaseStartBlock_ The start block of release to LUMUSD Vault
     * @param minReleaseAmount_ The minimum release amount to LUMUSD Vault
     */
    function _setLUMUSDVaultInfo(
        address vault_,
        uint256 releaseStartBlock_,
        uint256 minReleaseAmount_
    ) external compareAddress(lumUsdVaultAddress, vault_) {
        ensureAdmin();
        ensureNonzeroAddress(vault_);
        if (lumUsdVaultAddress != address(0)) {
            releaseToVault();
        }

        lumUsdVaultAddress = vault_;
        releaseStartBlock = releaseStartBlock_;
        minReleaseAmount = minReleaseAmount_;
        emit NewLUMUSDVaultInfo(vault_, releaseStartBlock_, minReleaseAmount_);
    }

    /**
     * @notice Enables forced liquidations for a market. If forced liquidation is enabled,
     * borrows in the market may be liquidated regardless of the account liquidity
     * @param luTokenBorrowed Borrowed luToken
     * @param enable Whether to enable forced liquidations
     */
    function _setForcedLiquidation(address luTokenBorrowed, bool enable) external {
        ensureAllowed("_setForcedLiquidation(address,bool)");
        if (luTokenBorrowed != address(lumUsdController)) {
            ensureListed(markets[luTokenBorrowed]);
        }
        isForcedLiquidationEnabled[address(luTokenBorrowed)] = enable;
        emit IsForcedLiquidationEnabledUpdated(luTokenBorrowed, enable);
    }
}
