pragma solidity ^0.8.20;

import "../LUMENVault/LUMENVault.sol";
import "../Utils/IERC20.sol";

contract LUMENStakingLens {
    /**
     * @notice Get the LUMEN stake balance of an account
     * @param account The address of the account to check
     * @param lumenAddress The address of the LUMENToken
     * @param lumenVaultProxyAddress The address of the LUMENVaultProxy
     * @return stakedAmount The balance that user staked
     * @return pendingWithdrawalAmount pending withdrawal amount of user.
     */
    function getStakedData(
        address account,
        address lumenAddress,
        address lumenVaultProxyAddress
    ) external view returns (uint256 stakedAmount, uint256 pendingWithdrawalAmount) {
        LUMENVault lumenVaultInstance = LUMENVault(lumenVaultProxyAddress);
        uint256 poolLength = lumenVaultInstance.poolLength(lumenAddress);

        for (uint256 pid = 0; pid < poolLength; ++pid) {
            (IERC20 token, , , , , , , ) = lumenVaultInstance.poolInfos(lumenAddress, pid);
            if (address(token) == address(lumenAddress)) {
                // solhint-disable-next-line no-unused-vars
                (uint256 userAmount, uint256 userRewardDebt, uint256 userPendingWithdrawals) = lumenVaultInstance
                    .getUserInfo(lumenAddress, pid, account);
                stakedAmount = userAmount;
                pendingWithdrawalAmount = userPendingWithdrawals;
                break;
            }
        }

        return (stakedAmount, pendingWithdrawalAmount);
    }
}
