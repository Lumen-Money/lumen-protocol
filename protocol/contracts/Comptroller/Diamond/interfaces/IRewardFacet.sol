// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { LuToken } from "../../../Tokens/LuTokens/LuToken.sol";
import { ComptrollerV14Storage } from "../../ComptrollerStorage.sol";

interface IRewardFacet {
    function claimLumen(address holder) external;

    function claimLumen(address holder, LuToken[] calldata luTokens) external;

    function claimLumen(address[] calldata holders, LuToken[] calldata luTokens, bool borrowers, bool suppliers) external;

    function claimLumenAsCollateral(address holder) external;

    function _grantLUMEN(address recipient, uint256 amount) external;

    function claimLumen(
        address[] calldata holders,
        LuToken[] calldata luTokens,
        bool borrowers,
        bool suppliers,
        bool collateral
    ) external;
}
