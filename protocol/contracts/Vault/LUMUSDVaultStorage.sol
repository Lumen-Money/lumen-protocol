pragma solidity ^0.8.20;
import "../Utils/SafeMath.sol";
import "../Utils/IERC20.sol";

contract LUMUSDVaultAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of LUMUSD Vault
     */
    address public lumUsdVaultImplementation;

    /**
     * @notice Pending brains of LUMUSD Vault
     */
    address public pendingLUMUSDVaultImplementation;
}

contract LUMUSDVaultStorage is LUMUSDVaultAdminStorage {
    /// @notice The LUMEN TOKEN!
    IERC20 public lumen;

    /// @notice The LUMUSD TOKEN!
    IERC20 public lumUsd;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice LUMEN balance of vault
    uint256 public lumenBalance;

    /// @notice Accumulated LUMEN per share
    uint256 public accLUMENPerShare;

    //// pending rewards awaiting anyone to update
    uint256 public pendingRewards;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    /// @notice pause indicator for Vault
    bool public vaultPaused;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
