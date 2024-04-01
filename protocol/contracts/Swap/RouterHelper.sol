// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./lib/AmmLibrary.sol";
import "./interfaces/IWNEON.sol";
import "./lib/TransferHelper.sol";

import "./interfaces/CustomErrors.sol";
import "./IRouterHelper.sol";

abstract contract RouterHelper is IRouterHelper {
    /// @notice Select the type of Token for which either a supporting fee would be deducted or not at the time of transfer.
    enum TypesOfTokens {
        NON_SUPPORTING_FEE,
        SUPPORTING_FEE
    }

    /// @notice Address of WNEON contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WNEON;

    /// @notice Address of amm swap factory contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable factory;

    // **************
    // *** EVENTS ***
    // **************
    /// @notice This event is emitted whenever a successful swap (tokenA -> tokenB) occurs
    event SwapTokensForTokens(address indexed swapper, address[] indexed path, uint256[] indexed amounts);

    /// @notice This event is emitted whenever a successful swap (tokenA -> tokenB) occurs
    event SwapTokensForTokensAtSupportingFee(address indexed swapper, address[] indexed path);

    /// @notice This event is emitted whenever a successful swap (NEON -> token) occurs
    event SwapNeonForTokens(address indexed swapper, address[] indexed path, uint256[] indexed amounts);

    /// @notice This event is emitted whenever a successful swap (NEON -> token) occurs
    event SwapNeonForTokensAtSupportingFee(address indexed swapper, address[] indexed path);

    /// @notice This event is emitted whenever a successful swap (token -> NEON) occurs
    event SwapTokensForNeon(address indexed swapper, address[] indexed path, uint256[] indexed amounts);

    /// @notice This event is emitted whenever a successful swap (token -> NEON) occurs
    event SwapTokensForNeonAtSupportingFee(address indexed swapper, address[] indexed path);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address WNEON_, address factory_) {
        if (WNEON_ == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        WNEON = WNEON_;
        factory = factory_;
    }

    /**
     * @notice Perform swap on the path(pairs)
     * @param amounts Araay of amounts of tokens after performing the swap
     * @param path Array with addresses of the underlying assets to be swapped
     * @param _to Recipient of the output tokens.
     */
    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint256 i; i < path.length - 1; ) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = AmmLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2 ? AmmLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IAmmPair(AmmLibrary.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
            unchecked {
                i += 1;
            }
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****

    /**
     * @notice Perform swap on the path(pairs) for supporting fee
     * @dev requires the initial amount to have already been sent to the first pair
     * @param path Array with addresses of the underlying assets to be swapped
     * @param _to Recipient of the output tokens.
     */
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint256 i; i < path.length - 1; ) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = AmmLibrary.sortTokens(input, output);
            IAmmPair pair = IAmmPair(AmmLibrary.pairFor(factory, input, output));
            uint256 amountInput;
            uint256 amountOutput;
            {
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) = input == token0
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);

                uint256 balance = IERC20(input).balanceOf(address(pair));
                amountInput = balance - reserveInput;
                amountOutput = AmmLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput)
                : (amountOutput, uint256(0));
            address to = i < path.length - 2 ? AmmLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
            unchecked {
                i += 1;
            }
        }
    }

    /**
     * @notice Swap token A for token B
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param swapFor TypesOfTokens, either supporing fee or non supporting fee
     * @return amounts Array of amounts after performing swap for respective pairs in path
     */
    function _swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        TypesOfTokens swapFor
    ) internal returns (uint256[] memory amounts) {
        address pairAddress = AmmLibrary.pairFor(factory, path[0], path[1]);
        if (swapFor == TypesOfTokens.NON_SUPPORTING_FEE) {
            amounts = AmmLibrary.getAmountsOut(factory, amountIn, path);
            if (amounts[amounts.length - 1] < amountOutMin) {
                revert OutputAmountBelowMinimum(amounts[amounts.length - 1], amountOutMin);
            }
            TransferHelper.safeTransferFrom(path[0], msg.sender, pairAddress, amounts[0]);
            _swap(amounts, path, to);
            emit SwapTokensForTokens(msg.sender, path, amounts);
        } else {
            TransferHelper.safeTransferFrom(path[0], msg.sender, pairAddress, amountIn);
            _swapSupportingFeeOnTransferTokens(path, to);
            emit SwapTokensForTokensAtSupportingFee(msg.sender, path);
        }
    }

    /**
     * @notice Swap exact NEON for token
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param swapFor TypesOfTokens, either supporing fee or non supporting fee
     * @return amounts Array of amounts after performing swap for respective pairs in path
     */
    function _swapExactNEONForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        TypesOfTokens swapFor
    ) internal returns (uint256[] memory amounts) {
        address wNEONAddress = WNEON;
        if (path[0] != wNEONAddress) {
            revert WrongAddress(wNEONAddress, path[0]);
        }
        IWNEON(wNEONAddress).deposit{ value: msg.value }();
        TransferHelper.safeTransfer(wNEONAddress, AmmLibrary.pairFor(factory, path[0], path[1]), msg.value);
        if (swapFor == TypesOfTokens.NON_SUPPORTING_FEE) {
            amounts = AmmLibrary.getAmountsOut(factory, msg.value, path);
            if (amounts[amounts.length - 1] < amountOutMin) {
                revert OutputAmountBelowMinimum(amounts[amounts.length - 1], amountOutMin);
            }
            _swap(amounts, path, to);
            emit SwapNeonForTokens(msg.sender, path, amounts);
        } else {
            _swapSupportingFeeOnTransferTokens(path, to);
            emit SwapNeonForTokensAtSupportingFee(msg.sender, path);
        }
    }

    /**
     * @notice Swap token A for NEON
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of NEON to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param swapFor TypesOfTokens, either supporing fee or non supporting fee
     * @return amounts Array of amounts after performing swap for respective pairs in path
     */
    function _swapExactTokensForNEON(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        TypesOfTokens swapFor
    ) internal returns (uint256[] memory amounts) {
        if (path[path.length - 1] != WNEON) {
            revert WrongAddress(WNEON, path[path.length - 1]);
        }
        uint256 WNEONAmount;
        if (swapFor == TypesOfTokens.NON_SUPPORTING_FEE) {
            amounts = AmmLibrary.getAmountsOut(factory, amountIn, path);
            if (amounts[amounts.length - 1] < amountOutMin) {
                revert OutputAmountBelowMinimum(amounts[amounts.length - 1], amountOutMin);
            }
            TransferHelper.safeTransferFrom(
                path[0],
                msg.sender,
                AmmLibrary.pairFor(factory, path[0], path[1]),
                amounts[0]
            );
            _swap(amounts, path, address(this));
            WNEONAmount = amounts[amounts.length - 1];
        } else {
            uint256 balanceBefore = IWNEON(WNEON).balanceOf(address(this));
            TransferHelper.safeTransferFrom(
                path[0],
                msg.sender,
                AmmLibrary.pairFor(factory, path[0], path[1]),
                amountIn
            );
            _swapSupportingFeeOnTransferTokens(path, address(this));
            uint256 balanceAfter = IWNEON(WNEON).balanceOf(address(this));
            WNEONAmount = balanceAfter - balanceBefore;
        }
        IWNEON(WNEON).withdraw(WNEONAmount);
        if (to != address(this)) {
            TransferHelper.safeTransferNEON(to, WNEONAmount);
        }
        if (swapFor == TypesOfTokens.NON_SUPPORTING_FEE) {
            emit SwapTokensForNeon(msg.sender, path, amounts);
        } else {
            emit SwapTokensForNeonAtSupportingFee(msg.sender, path);
        }
    }

    /**
     * @notice Swap token A for exact amount of token B
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @return amounts Array of amounts after performing swap for respective pairs in path
     **/
    function _swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) internal returns (uint256[] memory amounts) {
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        if (amounts[0] > amountInMax) {
            revert InputAmountAboveMaximum(amounts[0], amountInMax);
        }
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            AmmLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
        emit SwapTokensForTokens(msg.sender, path, amounts);
    }

    /**
     * @notice Swap NEON for exact amount of token B
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @return amounts Array of amounts after performing swap for respective pairs in path
     **/
    function _swapNEONForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to
    ) internal returns (uint256[] memory amounts) {
        if (path[0] != WNEON) {
            revert WrongAddress(WNEON, path[0]);
        }
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        if (amounts[0] > msg.value) {
            revert ExcessiveInputAmount(amounts[0], msg.value);
        }
        IWNEON(WNEON).deposit{ value: amounts[0] }();
        TransferHelper.safeTransfer(WNEON, AmmLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
        // refund dust NEON, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferNEON(msg.sender, msg.value - amounts[0]);
        emit SwapNeonForTokens(msg.sender, path, amounts);
    }

    /**
     * @notice Swap token A for exact NEON
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @return amounts Array of amounts after performing swap for respective pairs in path
     **/
    function _swapTokensForExactNEON(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) internal returns (uint256[] memory amounts) {
        if (path[path.length - 1] != WNEON) {
            revert WrongAddress(WNEON, path[path.length - 1]);
        }
        amounts = AmmLibrary.getAmountsIn(factory, amountOut, path);
        if (amounts[0] > amountInMax) {
            revert InputAmountAboveMaximum(amounts[amounts.length - 1], amountInMax);
        }
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            AmmLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWNEON(WNEON).withdraw(amounts[amounts.length - 1]);
        if (to != address(this)) {
            TransferHelper.safeTransferNEON(to, amounts[amounts.length - 1]);
        }
        emit SwapTokensForNeon(msg.sender, path, amounts);
    }

    // **** LIBRARY FUNCTIONS ****

    /**
     * @notice Given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
     * @param amountA The amount of token A
     * @param reserveA The amount of reserves for token A before swap
     * @param reserveB The amount of reserves for token B before swap
     * @return amountB An equivalent amount of the token B
     **/
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure virtual override returns (uint256 amountB) {
        return AmmLibrary.quote(amountA, reserveA, reserveB);
    }

    /**
     * @notice Given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
     * @param amountIn The amount of token A need to swap
     * @param reserveIn The amount of reserves for token A before swap
     * @param reserveOut The amount of reserves for token B after swap
     * @return amountOut The maximum output amount of the token B
     **/
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure virtual override returns (uint256 amountOut) {
        return AmmLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /**
     * @notice Given an output amount of an asset and pair reserves, returns a required input amount of the other asset
     * @param amountOut The amount of token B after swap
     * @param reserveIn The amount of reserves for token A before swap
     * @param reserveOut The amount of reserves for token B after swap
     * @return amountIn Required input amount of the token A
     **/
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure virtual override returns (uint256 amountIn) {
        return AmmLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /**
     * @notice performs chained getAmountOut calculations on any number of pairs.
     * @param amountIn The amount of tokens to swap.
     * @param path Array with addresses of the underlying assets to be swapped.
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) external view virtual override returns (uint256[] memory amounts) {
        return AmmLibrary.getAmountsOut(factory, amountIn, path);
    }

    /**
     * @notice performs chained getAmountIn calculations on any number of pairs.
     * @param amountOut amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped.
     */
    function getAmountsIn(
        uint256 amountOut,
        address[] memory path
    ) external view virtual override returns (uint256[] memory amounts) {
        return AmmLibrary.getAmountsIn(factory, amountOut, path);
    }
}
