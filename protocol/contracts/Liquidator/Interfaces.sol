pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILuToken is IERC20 {}

interface ILuErc20 is ILuToken {
    function underlying() external view returns (address);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ILuToken luTokenCollateral
    ) external returns (uint256);
}

interface ILuNEON is ILuToken {
    function liquidateBorrow(address borrower, ILuToken luTokenCollateral) external payable;
}

interface ILUMUSDController {
    function liquidateLUMUSD(
        address borrower,
        uint256 repayAmount,
        ILuToken luTokenCollateral
    ) external returns (uint256, uint256);

    function getLUMUSDAddress() external view returns (address);
}

interface IComptroller {
    function liquidationIncentiveMantissa() external view returns (uint256);

    function lumUsdController() external view returns (ILUMUSDController);
}
