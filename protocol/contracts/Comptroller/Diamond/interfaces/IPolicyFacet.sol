// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { LuToken } from "../../../Tokens/LuTokens/LuToken.sol";

interface IPolicyFacet {
    function mintAllowed(address luToken, address minter, uint256 mintAmount) external returns (uint256);

    function mintVerify(address luToken, address minter, uint256 mintAmount, uint256 mintTokens) external;

    function redeemAllowed(address luToken, address redeemer, uint256 redeemTokens) external returns (uint256);

    function redeemVerify(address luToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external pure;

    function borrowAllowed(address luToken, address borrower, uint256 borrowAmount) external returns (uint256);

    function borrowVerify(address luToken, address borrower, uint256 borrowAmount) external;

    function repayBorrowAllowed(
        address luToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function repayBorrowVerify(
        address luToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external;

    function liquidateBorrowAllowed(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256);

    function liquidateBorrowVerify(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external;

    function seizeAllowed(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256);

    function seizeVerify(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external;

    function transferAllowed(
        address luToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256);

    function transferVerify(address luToken, address src, address dst, uint256 transferTokens) external;

    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);

    function getHypotheticalAccountLiquidity(
        address account,
        address luTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256, uint256);

    function _setLumenSpeeds(
        LuToken[] calldata luTokens,
        uint256[] calldata supplySpeeds,
        uint256[] calldata borrowSpeeds
    ) external;
}
