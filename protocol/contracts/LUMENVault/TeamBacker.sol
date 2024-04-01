//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

struct TExpectedSwap {
    address token;
    uint256 minAmountOut;
}

contract TeamBacker is Ownable2StepUpgradeable {

    address[] public tokens;

    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant LUMEN  = 0x5dE40C1152c990492eaeaEECc4ECAab788BbC4fD;
    address public constant THE  = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;

    IWNEON public constant WNEON = IWNEON(address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakeFactory public constant PANCAKE_FACTORY = IPancakeFactory(address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73));
    IPancakeRouter public constant PANCAKE_ROUTER = IPancakeRouter(address(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    IPancakeFactoryV3 public constant PANCAKE_FACTORY_V3 = IPancakeFactoryV3(address(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865));
    IPancakeRouterV3 public constant PANCAKE_ROUTER_V3 = IPancakeRouterV3(address(0x1b81D678ffb9C0263b24A97847620C99d213eB14));

    IThenaFactory public constant THENA_FACTORY = IThenaFactory(address(0xAFD89d21BdB66d00817d4153E055830B1c2B3970));
    IThenaRouter public constant THENA_ROUTER = IThenaRouter(address(0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109));


    event BackerSwapped (address from, uint256 fromAmount, address to, uint256 toAmount);
    event BackerTransfer (address to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {

        __Ownable_init_unchained(msg.sender);

        tokens.push(address(WNEON));
        // usdc
        tokens.push(address(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d));
        // usdt
        tokens.push(address(0x55d398326f99059fF775485246999027B3197955));
        // eth
        tokens.push(address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8));
        // btc
        tokens.push(address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c));
    }

    function distribute(address recipient, TExpectedSwap[] memory swaps, uint256 lumenUsdtPrice) external onlyOwner {

        swapTokensToUSDT(swaps);

        uint usdtBalance = IERC20(USDT).balanceOf(address(this));
        swapToLUMEN(usdtBalance, lumenUsdtPrice);

        uint lumenBalance = IERC20(LUMEN).balanceOf(address(this));
        IERC20(LUMEN).transfer(recipient, lumenBalance);
        emit BackerTransfer(recipient, lumenBalance);
    }

    function swapTokensToUSDT (TExpectedSwap[] memory swaps) internal  {
        if (address(this).balance > 0) {
            WNEON.deposit{ value: address(this).balance }();
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == USDT || tokens[i] == THE) {
                continue;
            }
            uint amount = IERC20(tokens[i]).balanceOf(address(this));
            if (amount == 0) {
                continue;
            }
            TExpectedSwap memory expected = swaps[i];
            require(expected.token == tokens[i], "Invalid token at index");
            uint minAmountOut = expected.minAmountOut;

            uint amountOut = swapToUSDTFromV2(tokens[i], amount, minAmountOut);
            emit BackerSwapped(tokens[i], amount, USDT, amountOut);
        }
    }

    function swapToUSDTFromV3 (address token, uint256 amount) internal returns (uint256){
        uint24 poolFee = 100;
        address pool = PANCAKE_FACTORY_V3.getPool(token, USDT, poolFee);
        if (pool == address(0)) {
            poolFee = 500;
        }

        IERC20(token).approve(address(PANCAKE_ROUTER_V3), amount);

        IPancakeRouterV3.ExactInputSingleParams memory params = IPancakeRouterV3.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: USDT,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint amountOut = PANCAKE_ROUTER_V3.exactInputSingle(params);
        return amountOut;
    }

    function swapToUSDTFromV2 (address token, uint256 amount, uint256 minAmountOut) internal returns (uint256){
        IERC20(token).approve(address(PANCAKE_ROUTER), amount);

        address pair = PANCAKE_FACTORY.getPair(token, USDT);
        require(pair != address(0), "PAIR_NOT_FOUND");

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDT;

        uint balanceBefore = IERC20(USDT).balanceOf(address(this));
        PANCAKE_ROUTER.swapExactTokensForTokens(amount, minAmountOut, path, address(this), block.timestamp);
        uint balanceAfter = IERC20(USDT).balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }



    function swapToLUMEN (uint256 amount, uint256 lumenUsdtPrice) internal {
        IERC20(USDT).approve(address(THENA_ROUTER), amount);

        TThenaRoute[] memory path = new TThenaRoute[](1);
        path[0] = TThenaRoute({
            from: USDT,
            to: LUMEN,
            stable: false
        });

        uint minAmountOut = amount * 1 ether / lumenUsdtPrice * 95 / 100;

        uint balanceBefore = IERC20(LUMEN).balanceOf(address(this));
        THENA_ROUTER.swapExactTokensForTokens(amount, minAmountOut, path, address(this), block.timestamp);
        uint balanceAfter = IERC20(LUMEN).balanceOf(address(this));

        emit BackerSwapped(USDT, amount, LUMEN, balanceAfter - balanceBefore);
    }

    function withdrawRecovery(address token, address receiver) external onlyOwner {
        uint amount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(receiver, amount);
    }
    function withdrawRecoveryNative(address receiver) external onlyOwner {
        uint amount = address(this).balance;
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "NOT_SENT");
    }

    receive() external payable  {

    }
}


interface IPancakeRouter {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);


    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
interface IPancakePair is IERC20 {

}

interface IPancakeFactoryV3 {
    function getPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}
interface IPancakeRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint deadline;
        uint amountIn;
        uint amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps amountIn of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as ExactInputSingleParams in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint deadline;
        uint amountIn;
        uint amountOutMinimum;
    }

    /// @notice Swaps amountIn of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as ExactInputParams in calldata
    /// @return amountOut The amount of the received token
    function exactInput(
        ExactInputParams calldata params
    ) external payable returns (uint amountOut);
}


interface IThenaFactory {
    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);
}
interface IThenaRouter {
    function getAmountOut(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint amount, bool stable);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        TThenaRoute[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}
interface IThenaPair is IERC20 {

}


interface IWNEON {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);

    function withdraw(uint256) external;
}

interface ILUMENVault {
    function poolTotalSupply(address _rewardToken, uint256 _pid) external view returns (uint256);
}

interface ILUMENVaultDistributor {
    function addReward(address token, address treasury, uint256 amount) external returns (uint256 _shareIndex);
}

struct TThenaRoute {
    address from;
    address to;
    bool stable;
}
