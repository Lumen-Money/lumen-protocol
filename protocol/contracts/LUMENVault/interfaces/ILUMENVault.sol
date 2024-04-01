// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

interface ILUMENVault {
    function requestDistributorUpdate(address rewardToken, uint256 pid) external;
}
