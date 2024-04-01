pragma solidity ^0.8.20;

import "../../Utils/IERC20.sol";
import "../../Utils/SafeERC20.sol";
import "../LUMEN/ILUMENVesting.sol";
import "./SRTConverterStorage.sol";
import "./SRTConverterProxy.sol";

/**
 * @title LmnFi's SRTConversion Contract
 * @author LmnFi
 */
contract SRTConverter is SRTConverterStorage {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice decimal precision for SRT
    uint256 public constant srtDecimalsMultiplier = 1e18;

    /// @notice decimal precision for LUMEN
    uint256 public constant lumenDecimalsMultiplier = 1e18;

    /// @notice Emitted when an admin set conversion info
    event ConversionInfoSet(
        uint256 conversionRatio,
        uint256 conversionStartTime,
        uint256 conversionPeriod,
        uint256 conversionEndTime
    );

    /// @notice Emitted when token conversion is done
    event TokenConverted(
        address reedeemer,
        address srtAddress,
        uint256 srtAmount,
        address lumenAddress,
        uint256 lumenAmount
    );

    /// @notice Emitted when an admin withdraw converted token
    event TokenWithdraw(address token, address to, uint256 amount);

    /// @notice Emitted when LUMENVestingAddress is set
    event LUMENVestingSet(address lumenVestingAddress);

    function initialize(
        address _srtAddress,
        address _lumenAddress,
        uint256 _conversionRatio,
        uint256 _conversionStartTime,
        uint256 _conversionPeriod
    ) public {
        require(msg.sender == admin, "only admin may initialize the SRTConverter");
        require(initialized == false, "SRTConverter is already initialized");

        require(_srtAddress != address(0), "srtAddress cannot be Zero");
        srt = IERC20(_srtAddress);

        require(_lumenAddress != address(0), "lumenAddress cannot be Zero");
        lumen = IERC20(_lumenAddress);

        require(_conversionRatio > 0, "conversionRatio cannot be Zero");
        conversionRatio = _conversionRatio;

        require(_conversionStartTime >= block.timestamp, "conversionStartTime must be time in the future");
        require(_conversionPeriod > 0, "_conversionPeriod is invalid");

        conversionStartTime = _conversionStartTime;
        conversionPeriod = _conversionPeriod;
        conversionEndTime = conversionStartTime.add(conversionPeriod);
        emit ConversionInfoSet(conversionRatio, conversionStartTime, conversionPeriod, conversionEndTime);

        totalSrtConverted = 0;
        _notEntered = true;
        initialized = true;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /**
     * @notice sets LUMENVestingProxy Address
     * @dev Note: If LUMENVestingProxy is not set, then Conversion is not allowed
     * @param _lumenVestingAddress The LUMENVestingProxy Address
     */
    function setLUMENVesting(address _lumenVestingAddress) public {
        require(msg.sender == admin, "only admin may initialize the Vault");
        require(_lumenVestingAddress != address(0), "lumenVestingAddress cannot be Zero");
        lumenVesting = ILUMENVesting(_lumenVestingAddress);
        emit LUMENVestingSet(_lumenVestingAddress);
    }

    modifier isInitialized() {
        require(initialized == true, "SRTConverter is not initialized");
        _;
    }

    function isConversionActive() public view returns (bool) {
        uint256 currentTime = block.timestamp;
        if (currentTime >= conversionStartTime && currentTime <= conversionEndTime) {
            return true;
        }
        return false;
    }

    modifier checkForActiveConversionPeriod() {
        uint256 currentTime = block.timestamp;
        require(currentTime >= conversionStartTime, "Conversion did not start yet");
        require(currentTime <= conversionEndTime, "Conversion Period Ended");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    /**
     * @notice Transfer SRT and redeem LUMEN
     * @dev Note: If there is not enough LUMEN, we do not perform the conversion.
     * @param srtAmount The amount of SRT
     */
    function convert(uint256 srtAmount) external isInitialized checkForActiveConversionPeriod nonReentrant {
        require(
            address(lumenVesting) != address(0) && address(lumenVesting) != DEAD_ADDRESS,
            "LUMEN-Vesting Address is not set"
        );
        require(srtAmount > 0, "SRT amount must be non-zero");
        totalSrtConverted = totalSrtConverted.add(srtAmount);

        uint256 redeemAmount = srtAmount.mul(conversionRatio).mul(lumenDecimalsMultiplier).div(1e18).div(
            srtDecimalsMultiplier
        );

        emit TokenConverted(msg.sender, address(srt), srtAmount, address(lumen), redeemAmount);
        srt.safeTransferFrom(msg.sender, DEAD_ADDRESS, srtAmount);
        lumenVesting.deposit(msg.sender, redeemAmount);
    }

    /*** Admin Functions ***/
    function _become(SRTConverterProxy srtConverterProxy) public {
        require(msg.sender == srtConverterProxy.admin(), "only proxy admin can change brains");
        srtConverterProxy._acceptImplementation();
    }
}
