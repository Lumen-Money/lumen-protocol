// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { LuToken } from "../../../Tokens/LuTokens/LuToken.sol";

interface IMarketFacet {
    function isComptroller() external pure returns (bool);

    function liquidateCalculateSeizeTokens(
        address luTokenBorrowed,
        address luTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256);

    function liquidateLUMUSDCalculateSeizeTokens(
        address luTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256);

    function checkMembership(address account, LuToken luToken) external view returns (bool);

    function enterMarkets(address[] calldata luTokens) external returns (uint256[] memory);

    function exitMarket(address luToken) external returns (uint256);

    function _supportMarket(LuToken luToken) external returns (uint256);

    function getAssetsIn(address account) external view returns (LuToken[] memory);

    function getAllMarkets() external view returns (LuToken[] memory);

    function updateDelegate(address delegate, bool allowBorrows) external;
}
