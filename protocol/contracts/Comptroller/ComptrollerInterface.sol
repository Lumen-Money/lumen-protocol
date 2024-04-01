pragma solidity ^0.8.20;

import "../Tokens/LuTokens/LuToken.sol";
import "../../../oracle/contracts/PriceOracle.sol";
import "../Tokens/LUMUSD/LUMUSDControllerInterface.sol";

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata luTokens) virtual external returns (uint[] memory);

    function exitMarket(address luToken) virtual external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address luToken, address minter, uint mintAmount) virtual external returns (uint);

    function mintVerify(address luToken, address minter, uint mintAmount, uint mintTokens) virtual external;

    function redeemAllowed(address luToken, address redeemer, uint redeemTokens) virtual external returns (uint);

    function redeemVerify(address luToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowAllowed(address luToken, address borrower, uint borrowAmount) virtual external returns (uint);

    function borrowVerify(address luToken, address borrower, uint borrowAmount) virtual external;

    function repayBorrowAllowed(
        address luToken,
        address payer,
        address borrower,
        uint repayAmount
    ) virtual external returns (uint);

    function repayBorrowVerify(
        address luToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) virtual external;

    function liquidateBorrowAllowed(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) virtual external returns (uint);

    function liquidateBorrowVerify(
        address luTokenBorrowed,
        address luTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) virtual external;

    function seizeAllowed(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) virtual external returns (uint);

    function seizeVerify(
        address luTokenCollateral,
        address luTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) virtual external;

    function transferAllowed(address luToken, address src, address dst, uint transferTokens) virtual external returns (uint);

    function transferVerify(address luToken, address src, address dst, uint transferTokens) virtual external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address luTokenBorrowed,
        address luTokenCollateral,
        uint repayAmount
    ) virtual external view returns (uint, uint);

    function setMintedLUMUSDOf(address owner, uint amount) virtual external returns (uint);

    function liquidateLUMUSDCalculateSeizeTokens(
        address luTokenCollateral,
        uint repayAmount
    ) virtual external view returns (uint, uint);

    function getLUMENAddress() virtual public view returns (address);

    function markets(address) virtual external view returns (bool, uint);

    function oracle() virtual external view returns (PriceOracle);

    function getAccountLiquidity(address) virtual external view returns (uint, uint, uint);

    function getAssetsIn(address) virtual external view returns (LuToken[] memory);

    function claimLumen(address) virtual external;

    function lumenAccrued(address) virtual external view returns (uint);

    function lumenSupplySpeeds(address) virtual external view returns (uint);

    function lumenBorrowSpeeds(address) virtual external view returns (uint);

    function getAllMarkets() virtual external view returns (LuToken[] memory);

    function lumenSupplierIndex(address, address) virtual external view returns (uint);

    function lumenInitialIndex() virtual external view returns (uint224);

    function lumenBorrowerIndex(address, address) virtual external view returns (uint);

    function lumenBorrowState(address) virtual external view returns (uint224, uint32);

    function lumenSupplyState(address) virtual external view returns (uint224, uint32);

    function approvedDelegates(address borrower, address delegate) virtual external view returns (bool);

    function lumUsdController() virtual external view returns (LUMUSDControllerInterface);

    function liquidationIncentiveMantissa() virtual external view returns (uint);

    function protocolPaused() virtual external view returns (bool);

    function mintedLUMUSDs(address user) virtual external view returns (uint);

    function lumUsdMintRate() virtual external view returns (uint);
}

interface ILUMUSDVault {
    function updatePendingRewards() external;
}

interface IComptroller {
    function liquidationIncentiveMantissa() external view returns (uint);

    /*** Treasury Data ***/
    function treasuryAddress() external view returns (address);

    function treasuryPercent() external view returns (uint);
}
