// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { PriceOracle } from "../../../../../oracle/contracts/PriceOracle.sol";
import { LuToken } from "../../../Tokens/LuTokens/LuToken.sol";
import { ComptrollerV14Storage } from "../../ComptrollerStorage.sol";
import { LUMUSDControllerInterface } from "../../../Tokens/LUMUSD/LUMUSDController.sol";
import { ComptrollerLensInterface } from "../../../Comptroller/ComptrollerLensInterface.sol";

interface ISetterFacet {
    function _setPriceOracle(PriceOracle newOracle) external returns (uint256);

    function _setCloseFactor(uint256 newCloseFactorMantissa) external returns (uint256);

    function _setAccessControl(address newAccessControlAddress) external returns (uint256);

    function _setCollateralFactor(LuToken luToken, uint256 newCollateralFactorMantissa) external returns (uint256);

    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external returns (uint256);

    function _setLiquidatorContract(address newLiquidatorContract_) external;

    function _setPauseGuardian(address newPauseGuardian) external returns (uint256);

    function _setMarketBorrowCaps(LuToken[] calldata luTokens, uint256[] calldata newBorrowCaps) external;

    function _setMarketSupplyCaps(LuToken[] calldata luTokens, uint256[] calldata newSupplyCaps) external;

    function _setProtocolPaused(bool state) external returns (bool);

    function _setActionsPaused(
        address[] calldata markets,
        ComptrollerV14Storage.Action[] calldata actions,
        bool paused
    ) external;

    function _setLUMUSDController(LUMUSDControllerInterface lumUsdController_) external returns (uint256);

    function _setLUMUSDMintRate(uint256 newLUMUSDMintRate) external returns (uint256);

    function setMintedLUMUSDOf(address owner, uint256 amount) external returns (uint256);

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint256 newTreasuryPercent
    ) external returns (uint256);

    function _setComptrollerLens(ComptrollerLensInterface comptrollerLens_) external returns (uint256);

    function _setLumenLUMUSDVaultRate(uint256 lumenLUMUSDVaultRate_) external;

    function _setLUMUSDVaultInfo(address vault_, uint256 releaseStartBlock_, uint256 minReleaseAmount_) external;

    function _setForcedLiquidation(address luToken, bool enable) external;

    function _setLUMENAddress(address lumenToken) external;
    function _setLuLUMENAddress(address luumenToken) external;
}
