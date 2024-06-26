// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface LuErc20Interface is IERC20Metadata {
    /**
     * @notice Underlying asset for this luToken
     */
    function underlying() external view returns (address);
}
