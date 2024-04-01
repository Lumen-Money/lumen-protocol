pragma solidity ^0.8.20;

import "../../Comptroller/ComptrollerInterface.sol";

contract LUMUSDUnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of Unitroller
     */
    address public lumUsdControllerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingLUMUSDControllerImplementation;
}

contract LUMUSDControllerStorageG1 is LUMUSDUnitrollerAdminStorage {
    ComptrollerInterface public comptroller;

    struct LumenLUMUSDState {
        /// @notice The last updated lumenLUMUSDMintIndex
        uint224 index;
        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice The LmnFi LUMUSD state
    LumenLUMUSDState public lumenLUMUSDState;

    /// @notice The LmnFi LUMUSD state initialized
    bool public isLumenLUMUSDInitialized;

    /// @notice The LmnFi LUMUSD minter index as of the last time they accrued LUMEN
    mapping(address => uint) public lumenLUMUSDMinterIndex;
}

contract LUMUSDControllerStorageG2 is LUMUSDControllerStorageG1 {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice The base rate for stability fee
    uint public baseRateMantissa;

    /// @notice The float rate for stability fee
    uint public floatRateMantissa;

    /// @notice The address for LUMUSD interest receiver
    address public receiver;

    /// @notice Accumulator of the total earned interest rate since the opening of the market. For example: 0.6 (60%)
    uint public lumUsdMintIndex;

    /// @notice Block number that interest was last accrued at
    uint internal accrualBlockNumber;

    /// @notice Global lumUsdMintIndex as of the most recent balance-changing action for user
    mapping(address => uint) internal lumUsdMinterInterestIndex;

    /// @notice Tracks the amount of mintedLUMUSD of a user that represents the accrued interest
    mapping(address => uint) public pastLUMUSDInterest;

    /// @notice LUMUSD mint cap
    uint public mintCap;

    /// @notice Access control manager address
    address public accessControl;
}
