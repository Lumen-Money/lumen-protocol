pragma solidity ^0.8.20;

import "../../Utils/SafeMath.sol";
import "../../Utils/IERC20.sol";
import "../LUMEN/ILUMENVesting.sol";

contract SRTConverterAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of SRTConverter
     */
    address public implementation;

    /**
     * @notice Pending brains of SRTConverter
     */
    address public pendingImplementation;
}

contract SRTConverterStorage is SRTConverterAdminStorage {
    /// @notice Guard variable for re-entrancy checks
    bool public _notEntered;

    /// @notice indicator to check if the contract is initialized
    bool public initialized;

    /// @notice The SRT TOKEN!
    IERC20 public srt;

    /// @notice The LUMEN TOKEN!
    IERC20 public lumen;

    /// @notice LUMENVesting Contract reference
    ILUMENVesting public lumenVesting;

    /// @notice Conversion ratio from SRT to LUMEN with decimal 18
    uint256 public conversionRatio;

    /// @notice total SRT converted to LUMEN
    uint256 public totalSrtConverted;

    /// @notice Conversion Start time in EpochSeconds
    uint256 public conversionStartTime;

    /// @notice ConversionPeriod in Seconds
    uint256 public conversionPeriod;

    /// @notice Conversion End time in EpochSeconds
    uint256 public conversionEndTime;
}
