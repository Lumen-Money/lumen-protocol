pragma solidity ^0.8.20;


import "../Tokens/LuTokens/LuToken.sol";

interface ComptrollerLensInterface {
    function liquidateCalculateSeizeTokens(
        address comptroller,
        address luTokenBorrowed,
        address luTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function liquidateLUMUSDCalculateSeizeTokens(
        address comptroller,
        address luTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        LuToken luTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) external view returns (uint, uint, uint);
}
