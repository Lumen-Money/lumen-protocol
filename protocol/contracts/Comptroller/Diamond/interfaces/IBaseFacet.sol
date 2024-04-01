// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { LuToken } from "../../../Tokens/LuTokens/LuToken.sol";

interface IBaseFacet {
    function getLUMENAddress() external view returns (address);
}
