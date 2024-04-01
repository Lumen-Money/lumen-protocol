pragma solidity ^0.8.20;

import "../LuTokens/LuTokenInterfaces.sol";

abstract contract LUMUSDControllerInterface {
    function getLUMUSDAddress() virtual public view returns (address);

    function getMintableLUMUSD(address minter) virtual public view returns (uint, uint);

    function mintLUMUSD(address minter, uint mintLUMUSDAmount) virtual external returns (uint);

    function repayLUMUSD(address repayer, uint repayLUMUSDAmount) virtual external returns (uint);

    function liquidateLUMUSD(
        address borrower,
        uint repayAmount,
        LuTokenInterface luTokenCollateral
    ) virtual external returns (uint, uint);

    function _initializeLumenLUMUSDState(uint blockNumber) virtual external returns (uint);

    function updateLumenLUMUSDMintIndex() virtual external returns (uint);

    function calcDistributeLUMUSDMinterLumen(address lumUsdMinter) virtual external returns (uint, uint, uint, uint);

    function getLUMUSDRepayAmount(address account) virtual public view returns (uint);
}
