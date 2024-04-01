// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;


struct TLUMENVaultDistributorReward {
    address token;
    uint256 pendingRewards;
    uint256 shares;
    uint256 totalShares;
}

interface ILUMENVaultDistributor {

    function update(uint256 totalShares_) external;

    function deposited (address account, uint256 prevUserShares_, uint256 newUserShares_, uint256 totalVaultShares_) external;
    function withdrawn (address account, uint256 prevUserShares_, uint256 newUserShares_, uint256 totalVaultShares_) external;

    function pendingRewards(address account, uint256 userShares_, uint256 totalShares_) external view returns (TLUMENVaultDistributorReward[] memory);

    function claim(address token, address account) external returns (uint256 amount);
    function claimAll(address account) external returns (uint256[] memory amounts);
}
