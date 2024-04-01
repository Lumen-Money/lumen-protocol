pragma solidity ^0.8.20;

import "../../Utils/SafeMath.sol";
import "../../Utils/IERC20.sol";

contract LUMENVestingAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of LUMENVesting
     */
    address public implementation;

    /**
     * @notice Pending brains of LUMENVesting
     */
    address public pendingImplementation;
}

contract LUMENVestingStorage is LUMENVestingAdminStorage {
    struct VestingRecord {
        address recipient;
        uint256 startTime;
        uint256 amount;
        uint256 withdrawnAmount;
    }

    /// @notice Guard variable for re-entrancy checks
    bool public _notEntered;

    /// @notice indicator to check if the contract is initialized
    bool public initialized;

    /// @notice The LUMEN TOKEN!
    IERC20 public lumen;

    /// @notice SRTConversion Contract Address
    address public srtConversionAddress;

    /// @notice mapping of VestingRecord(s) for user(s)
    mapping(address => VestingRecord[]) public vestings;
}
