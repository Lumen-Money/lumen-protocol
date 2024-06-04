// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: 2022 LmnFi
pragma solidity 0.8.20;

import { LuErc20Interface } from "./interfaces/LuErc20Interface.sol";
import { SimpleOracleInterface} from "./interfaces/OracleInterface.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { IAccessControlManagerV8, AccessControlledV8 } from "../../governance/contracts/Governance/AccessControlledV8.sol";

/**
 * @title ChainlinkResilientOracle
 * @author LmnFi
 * @notice The optimized version of the ResilientOracle to support the chainlink only
 *
 *
 */
contract ChainlinkResilientOracle is AccessControlledV8, SimpleOracleInterface {

    IAccessControlManagerV8 _accessControlManager;

    struct TokenConfig {
        /// @notice Underlying or Lu token address, which can't be a null address
        /// @notice 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for NEON
        address asset;
        /// @notice Chainlink feed address
        address feed;
        /// @notice Price expiration period of this asset
        uint64 maxStalePeriod;

        uint64 uDecimals;
        uint64 fDecimals;
    }


    /// @notice Token config by assets
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Emit when a token config is added
    event TokenConfigAdded(address indexed asset, address feed, uint64 maxStalePeriod);

    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    constructor(address accessControlManager_) {
        _accessControlManager = IAccessControlManagerV8(accessControlManager_);
    }

    /**
     * @notice Add multiple token configs at the same time
     * @param tokenConfigs_ config array
     * @custom:access Only Governance
     * @custom:error Zero length error thrown, if length of the array in parameter is 0
     */
    function setTokenConfigs(TokenConfig[] memory tokenConfigs_) external {
        if (tokenConfigs_.length == 0) revert("length can't be 0");
        uint256 count = tokenConfigs_.length;
        for (uint256 i = 0; i < count; i++) {
            setTokenConfig(tokenConfigs_[i]);
        }
    }


    /**
     * @notice Add single token config. asset & feed cannot be null addresses and maxStalePeriod must be positive
     * @param tokenConfig Token config struct
     * @custom:access Only Governance
     * @custom:error NotNullAddress error is thrown if asset address is null
     * @custom:error NotNullAddress error is thrown if token feed address is null
     * @custom:error Range error is thrown if maxStale period of token is not greater than zero
     * @custom:event Emits TokenConfigAdded event on succesfully setting of the token config
     */
    function setTokenConfig(
        TokenConfig memory tokenConfig
    ) public notNullAddress(tokenConfig.asset) notNullAddress(tokenConfig.feed) {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");

        require(tokenConfig.maxStalePeriod > 0, "stale period can't be zero");

        uint8 uDecimals = IDecimals(tokenConfig.asset).decimals();
        require(tokenConfig.uDecimals == uDecimals, "invalid_uDecimals");

        uint8 fDecimals = IDecimals(tokenConfig.feed).decimals();
        require(tokenConfig.fDecimals == fDecimals, "invalid_fDecimals");

        tokenConfigs[tokenConfig.asset] = tokenConfig;
        emit TokenConfigAdded(tokenConfig.asset, tokenConfig.feed, tokenConfig.maxStalePeriod);
    }

    /**
     * @notice Gets the price of a asset from the chainlink oracle
     * @param asset Address of the asset
     * @return Price in USD from Chainlink or a manually set price for the asset
     */
    function getPrice(address asset) public view returns (uint256) {
        return _getPriceInternal(asset);
    }

    function getUnderlyingPrice(address luToken) external view returns (uint256) {
        return _getPriceInternal(luToken);
    }

    /**
     * @notice Gets the Chainlink price for a given asset
     * @param asset address of the asset
     * @return price Asset price in USD or a manually set price of the asset
     */
    function _getPriceInternal(address asset) internal view returns (uint256) {
        TokenConfig memory config = tokenConfigs[asset];
        uint64 decimals = config.uDecimals;
        require(decimals > 0, "Config_not_Set");

        uint price = _getChainlinkPrice(config.feed, config.fDecimals, config.maxStalePeriod);
        uint64 decimalDelta = 18 - decimals;
        return price * (10 ** decimalDelta);
    }

    /**
     * @notice Get the Chainlink price for an asset, revert if token config doesn't exist
     * @dev The precision of the price feed is used to ensure the returned price has 18 decimals of precision
     * @param feed Address of the feed
     * @param decimals Feeds decumals
     * @param maxStalePeriod MaxStalePeriod in seconds
     * @return price Price in USD, with 18 decimals of precision
     * @custom:error NotNullAddress error is thrown if the asset address is null
     * @custom:error Price error is thrown if the Chainlink price of asset is not greater than zero
     * @custom:error Timing error is thrown if current timestamp is less than the last updatedAt timestamp
     * @custom:error Timing error is thrown if time difference between current time and last updated time
     * is greater than maxStalePeriod
     */
    function _getChainlinkPrice(
        address feed,
        uint64 decimals,
        uint64 maxStalePeriod
    ) internal view notNullAddress(feed) returns (uint256) {

        // Chainlink USD-denominated feeds store answers at 8 decimals, mostly

        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) revert("chainlink price must be positive");

    // Neon EVM timestamp could be behind the Solana-Feeds updatedAt
        uint256 deltaTime = block.timestamp > updatedAt
            ? block.timestamp - updatedAt
            : updatedAt - block.timestamp;

        require(deltaTime < maxStalePeriod, "Chainlink_Expired");

        uint256 decimalDelta = 18 - decimals;
        return uint256(answer) * (10 ** decimalDelta);
    }

}


interface IDecimals {
    function decimals() external view returns (uint8);
}
