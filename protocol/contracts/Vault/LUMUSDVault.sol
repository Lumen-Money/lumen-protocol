pragma solidity ^0.8.20;

import "../Utils/SafeERC20.sol";
import "../Utils/IERC20.sol";
import "./LUMUSDVaultStorage.sol";
import "./LUMUSDVaultErrorReporter.sol";
import "../../../governance/contracts/Governance/AccessControlledV5.sol";

interface ILUMUSDVaultProxy {
    function _acceptImplementation() external returns (uint);

    function admin() external returns (address);
}

contract LUMUSDVault is LUMUSDVaultStorage, AccessControlledV5 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Event emitted when LUMUSD deposit
    event Deposit(address indexed user, uint256 amount);

    /// @notice Event emitted when LUMUSD withrawal
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when vault is paused
    event VaultPaused(address indexed admin);

    /// @notice Event emitted when vault is resumed after pause
    event VaultResumed(address indexed admin);

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

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
     * @dev Prevents functions to execute when vault is paused.
     */
    modifier isActive() {
        require(!vaultPaused, "Vault is paused");
        _;
    }

    /**
     * @notice Pause vault
     */
    function pause() external {
        _checkAccessAllowed("pause()");
        require(!vaultPaused, "Vault is already paused");
        vaultPaused = true;
        emit VaultPaused(msg.sender);
    }

    /**
     * @notice Resume vault
     */
    function resume() external {
        _checkAccessAllowed("resume()");
        require(vaultPaused, "Vault is not paused");
        vaultPaused = false;
        emit VaultResumed(msg.sender);
    }

    /**
     * @notice Deposit LUMUSD to LUMUSDVault for LUMEN allocation
     * @param _amount The amount to deposit to vault
     */
    function deposit(uint256 _amount) external nonReentrant isActive {
        UserInfo storage user = userInfo[msg.sender];

        updateVault();

        // Transfer pending tokens to user
        updateAndPayOutPending(msg.sender);

        // Transfer in the amounts from user
        if (_amount > 0) {
            lumUsd.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user.amount.mul(accLUMENPerShare).div(1e18);
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw LUMUSD from LUMUSDVault
     * @param _amount The amount to withdraw from vault
     */
    function withdraw(uint256 _amount) external nonReentrant isActive {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Claim LUMEN from LUMUSDVault
     */
    function claim() external nonReentrant isActive {
        _withdraw(msg.sender, 0);
    }

    /**
     * @notice Claim LUMEN from LUMUSDVault
     * @param account The account for which to claim LUMEN
     */
    function claim(address account) external nonReentrant isActive {
        _withdraw(account, 0);
    }

    /**
     * @notice Low level withdraw function
     * @param account The account to withdraw from vault
     * @param _amount The amount to withdraw from vault
     */
    function _withdraw(address account, uint256 _amount) internal {
        UserInfo storage user = userInfo[account];
        require(user.amount >= _amount, "withdraw: not good");

        updateVault();
        updateAndPayOutPending(account); // Update balances of account this is not withdrawal but claiming LUMEN farmed

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            lumUsd.safeTransfer(address(account), _amount);
        }
        user.rewardDebt = user.amount.mul(accLUMENPerShare).div(1e18);

        emit Withdraw(account, _amount);
    }

    /**
     * @notice View function to see pending LUMEN on frontend
     * @param _user The user to see pending LUMEN
     * @return Amount of LUMEN the user can claim
     */
    function pendingLUMEN(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];

        return user.amount.mul(accLUMENPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @notice Update and pay out pending LUMEN to user
     * @param account The user to pay out
     */
    function updateAndPayOutPending(address account) internal {
        uint256 pending = pendingLUMEN(account);

        if (pending > 0) {
            safeLUMENTransfer(account, pending);
        }
    }

    /**
     * @notice Safe LUMEN transfer function, just in case if rounding error causes pool to not have enough LUMEN
     * @param _to The address that LUMEN to be transfered
     * @param _amount The amount that LUMEN to be transfered
     */
    function safeLUMENTransfer(address _to, uint256 _amount) internal {
        uint256 lumenBal = lumen.balanceOf(address(this));

        if (_amount > lumenBal) {
            lumen.transfer(_to, lumenBal);
            lumenBalance = lumen.balanceOf(address(this));
        } else {
            lumen.transfer(_to, _amount);
            lumenBalance = lumen.balanceOf(address(this));
        }
    }

    /**
     * @notice Function that updates pending rewards
     */
    function updatePendingRewards() public isActive {
        uint256 newRewards = lumen.balanceOf(address(this)).sub(lumenBalance);

        if (newRewards > 0) {
            lumenBalance = lumen.balanceOf(address(this)); // If there is no change the balance didn't change
            pendingRewards = pendingRewards.add(newRewards);
        }
    }

    /**
     * @notice Update reward variables to be up-to-date
     */
    function updateVault() internal {
        updatePendingRewards();

        uint256 lumUsdBalance = lumUsd.balanceOf(address(this));
        if (lumUsdBalance == 0) {
            // avoids division by 0 errors
            return;
        }

        accLUMENPerShare = accLUMENPerShare.add(pendingRewards.mul(1e18).div(lumUsdBalance));
        pendingRewards = 0;
    }

    /*** Admin Functions ***/

    function _become(ILUMUSDVaultProxy lumUsdVaultProxy) external {
        require(msg.sender == lumUsdVaultProxy.admin(), "only proxy admin can change brains");
        require(lumUsdVaultProxy._acceptImplementation() == 0, "change not authorized");
    }

    function setLumenInfo(address _lumen, address _vai) external onlyAdmin {
        require(_lumen != address(0) && _vai != address(0), "addresses must not be zero");
        require(address(lumen) == address(0) && address(lumUsd) == address(0), "addresses already set");
        lumen = IERC20(_lumen);
        lumUsd = IERC20(_vai);

        _notEntered = true;
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _setAccessControlManager(newAccessControlAddress);
    }
}
