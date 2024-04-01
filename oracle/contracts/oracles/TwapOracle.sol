// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../../protocol/contracts/Swap/lib/AmmLibrary.sol";
import "../interfaces/OracleInterface.sol";
import "../interfaces/LuErc20Interface.sol";
import "../../../governance/contracts/Governance/AccessControlledV8.sol";
import { FixedPoint, AmmOracleLibrary } from "../libraries/PancakeLibrary.sol";

/**
 * @title TwapOracle
 * @author LmnFi
 * @notice This oracle fetches price of assets from AmmSwap.
 */
contract TwapOracle is AccessControlledV8, TwapInterface {
    using FixedPoint for *;

    struct Observation {
        uint256 timestamp;
        uint256 acc;
    }

    struct TokenConfig {
        /// @notice Asset address, which can't be zero address and can be used for existance check
        address asset;
        /// @notice Decimals of asset represented as 1e{decimals}
        uint256 baseUnit;
        /// @notice The address of Amm pair
        address ammPool;
        /// @notice Whether the token is paired with WNEON
        bool isNeonBased;
        /// @notice A flag identifies whether the Amm pair is reversed
        /// e.g. LUMEN-WNEON is reversed, while WNEON-LUMEN is not.
        bool isReversedPool;
        /// @notice The minimum window in seconds required between TWAP updates
        uint256 anchorPeriod;
    }

    /// @notice Set this as asset address for NEON. This is the underlying for luNEON
    address public constant NEON_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice WNEON address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WNEON;

    /// @notice the base unit of WNEON and BUSD, which are the paired tokens for all assets
    uint256 public constant NEON_BASE_UNIT = 1e18;
    uint256 public constant BUSD_BASE_UNIT = 1e18;

    /// @notice Configs by token
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Stored price by token
    mapping(address => uint256) public prices;

    /// @notice Keeps a record of token observations mapped by address, updated on every updateTwap invocation.
    mapping(address => Observation[]) public observations;

    /// @notice Observation array index which probably falls in current anchor period mapped by asset address
    mapping(address => uint256) public windowStart;

    /// @notice Emit this event when TWAP window is updated
    event TwapWindowUpdated(
        address indexed asset,
        uint256 oldTimestamp,
        uint256 oldAcc,
        uint256 newTimestamp,
        uint256 newAcc
    );

    /// @notice Emit this event when TWAP price is updated
    event AnchorPriceUpdated(address indexed asset, uint256 price, uint256 oldTimestamp, uint256 newTimestamp);

    /// @notice Emit this event when new token configs are added
    event TokenConfigAdded(address indexed asset, address indexed ammPool, uint256 indexed anchorPeriod);

    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    /// @notice Constructor for the implementation contract. Sets immutable variables.
    /// @param wNeonAddress The address of the WNEON
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address wNeonAddress) notNullAddress(wNeonAddress) {
        WNEON = wNeonAddress;
        _disableInitializers();
    }

    /**
     * @notice Adds multiple token configs at the same time
     * @param configs Config array
     * @custom:error Zero length error thrown, if length of the config array is 0
     */
    function setTokenConfigs(TokenConfig[] memory configs) external {
        if (configs.length == 0) revert("length can't be 0");
        uint256 numTokenConfigs = configs.length;
        for (uint256 i; i < numTokenConfigs; ) {
            setTokenConfig(configs[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Initializes the owner of the contract
     * @param accessControlManager_ Address of the access control manager contract
     */
    function initialize(address accessControlManager_) external initializer {
        __AccessControlled_init(accessControlManager_);
    }

    /**
     * @notice Get the TWAP price for the given asset
     * @param asset asset address
     * @return price asset price in USD
     * @custom:error Missing error is thrown if the token config does not exist
     * @custom:error Range error is thrown if TWAP price is not greater than zero
     */
    function getPrice(address asset) external view override returns (uint256) {
        uint256 decimals;

        if (asset == NEON_ADDR) {
            decimals = 18;
            asset = WNEON;
        } else {
            IERC20Metadata token = IERC20Metadata(asset);
            decimals = token.decimals();
        }

        if (tokenConfigs[asset].asset == address(0)) revert("asset not exist");
        uint256 price = prices[asset];

        // if price is 0, it means the price hasn't been updated yet and it's meaningless, revert
        if (price == 0) revert("TWAP price must be positive");
        return (price * (10 ** (18 - decimals)));
    }

    /**
     * @notice Adds a single token config
     * @param config token config struct
     * @custom:access Only Governance
     * @custom:error Range error is thrown if anchor period is not greater than zero
     * @custom:error Range error is thrown if base unit is not greater than zero
     * @custom:error Value error is thrown if base unit decimals is not the same as asset decimals
     * @custom:error NotNullAddress error is thrown if address of asset is null
     * @custom:error NotNullAddress error is thrown if AmmSwap pool address is null
     * @custom:event Emits TokenConfigAdded event if new token config are added with
     * asset address, AmmPool address, anchor period address
     */
    function setTokenConfig(
        TokenConfig memory config
    ) public notNullAddress(config.asset) notNullAddress(config.ammPool) {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");

        if (config.anchorPeriod == 0) revert("anchor period must be positive");
        if (config.baseUnit != 10 ** IERC20Metadata(config.asset).decimals())
            revert("base unit decimals must be same as asset decimals");

        uint256 cumulativePrice = currentCumulativePrice(config);

        // Initialize observation data
        observations[config.asset].push(Observation(block.timestamp, cumulativePrice));
        tokenConfigs[config.asset] = config;
        emit TokenConfigAdded(config.asset, config.ammPool, config.anchorPeriod);
    }

    /**
     * @notice Updates the current token/BUSD price from AmmSwap, with 18 decimals of precision.
     * @return anchorPrice anchor price of the asset
     * @custom:error Missing error is thrown if token config does not exist
     */
    function updateTwap(address asset) public returns (uint256) {
        if (asset == NEON_ADDR) {
            asset = WNEON;
        }

        if (tokenConfigs[asset].asset == address(0)) revert("asset not exist");
        // Update & fetch WNEON price first, so we can calculate the price of WNEON paired token
        if (asset != WNEON && tokenConfigs[asset].isNeonBased) {
            if (tokenConfigs[WNEON].asset == address(0)) revert("WNEON not exist");
            _updateTwapInternal(tokenConfigs[WNEON]);
        }
        return _updateTwapInternal(tokenConfigs[asset]);
    }

    /**
     * @notice Fetches the current token/WNEON and token/BUSD price accumulator from AmmSwap.
     * @return cumulative price of target token regardless of pair order
     */
    function currentCumulativePrice(TokenConfig memory config) public view returns (uint256) {
        (uint256 price0, uint256 price1, ) = AmmOracleLibrary.currentCumulativePrices(config.ammPool);
        if (config.isReversedPool) {
            return price1;
        } else {
            return price0;
        }
    }

    /**
     * @notice Fetches the current token/BUSD price from AmmSwap, with 18 decimals of precision.
     * @return price Asset price in USD, with 18 decimals
     * @custom:error Timing error is thrown if current time is not greater than old observation timestamp
     * @custom:error Zero price error is thrown if token is NEON based and price is zero
     * @custom:error Zero price error is thrown if fetched anchorPriceMantissa is zero
     * @custom:event Emits AnchorPriceUpdated event on successful update of observation with assset address,
     * AnchorPrice, old observation timestamp and current timestamp
     */
    function _updateTwapInternal(TokenConfig memory config) private returns (uint256) {
        // pokeWindowValues already handled reversed pool cases,
        // priceAverage will always be Token/NEON or Token/BUSD *twap** price.
        (uint256 nowCumulativePrice, uint256 oldCumulativePrice, uint256 oldTimestamp) = pokeWindowValues(config);

        if (block.timestamp == oldTimestamp) return prices[config.asset];

        // This should be impossible, but better safe than sorry
        if (block.timestamp < oldTimestamp) revert("now must come after before");

        uint256 timeElapsed;
        unchecked {
            timeElapsed = block.timestamp - oldTimestamp;
        }

        // Calculate Amm *twap**
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((nowCumulativePrice - oldCumulativePrice) / timeElapsed)
        );
        // *twap** price with 1e18 decimal mantissa
        uint256 priceAverageMantissa = priceAverage.decode112with18();

        // To cancel the decimals in cumulative price, we need to mulitply the average price with
        // tokenBaseUnit / (NEON_BASE_UNIT or BUSD_BASE_UNIT, which is 1e18)
        uint256 pairedTokenBaseUnit = config.isNeonBased ? NEON_BASE_UNIT : BUSD_BASE_UNIT;
        uint256 anchorPriceMantissa = (priceAverageMantissa * config.baseUnit) / pairedTokenBaseUnit;

        // if this token is paired with NEON, convert its price to USD
        if (config.isNeonBased) {
            uint256 bnbPrice = prices[WNEON];
            if (bnbPrice == 0) revert("bnb price is invalid");
            anchorPriceMantissa = (anchorPriceMantissa * bnbPrice) / NEON_BASE_UNIT;
        }

        if (anchorPriceMantissa == 0) revert("twap price cannot be 0");

        emit AnchorPriceUpdated(config.asset, anchorPriceMantissa, oldTimestamp, block.timestamp);

        // save anchor price, which is 1e18 decimals
        prices[config.asset] = anchorPriceMantissa;

        return anchorPriceMantissa;
    }

    /**
     * @notice Appends current observation and pick an observation with a timestamp equal
     * or just greater than the window start timestamp. If one is not available,
     * then pick the last availableobservation. The window start index is updated in both the cases.
     * Only the current observation is saved, prior observations are deleted during this operation.
     * @return Tuple of cumulative price, old observation and timestamp
     * @custom:event Emits TwapWindowUpdated on successful calculation of cumulative price with asset address,
     * new observation timestamp, current timestamp, new observation price and cumulative price
     */
    function pokeWindowValues(
        TokenConfig memory config
    ) private returns (uint256, uint256 startCumulativePrice, uint256 startCumulativeTimestamp) {
        uint256 cumulativePrice = currentCumulativePrice(config);
        uint256 currentTimestamp = block.timestamp;
        uint256 windowStartTimestamp = currentTimestamp - config.anchorPeriod;
        Observation[] memory storedObservations = observations[config.asset];

        uint256 storedObservationsLength = storedObservations.length;
        for (uint256 windowStartIndex = windowStart[config.asset]; windowStartIndex < storedObservationsLength; ) {
            if (
                (storedObservations[windowStartIndex].timestamp >= windowStartTimestamp) ||
                (windowStartIndex == storedObservationsLength - 1)
            ) {
                startCumulativePrice = storedObservations[windowStartIndex].acc;
                startCumulativeTimestamp = storedObservations[windowStartIndex].timestamp;
                windowStart[config.asset] = windowStartIndex;
                break;
            } else {
                delete observations[config.asset][windowStartIndex];
            }

            unchecked {
                ++windowStartIndex;
            }
        }

        observations[config.asset].push(Observation(currentTimestamp, cumulativePrice));
        emit TwapWindowUpdated(
            config.asset,
            startCumulativeTimestamp,
            startCumulativePrice,
            block.timestamp,
            cumulativePrice
        );
        return (cumulativePrice, startCumulativePrice, startCumulativeTimestamp);
    }
}
