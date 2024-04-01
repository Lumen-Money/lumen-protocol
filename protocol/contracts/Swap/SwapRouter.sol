// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IAmmSwapV2Router.sol";
import "./interfaces/ILuToken.sol";
import "./RouterHelper.sol";
import "./interfaces/ILuNEON.sol";
import "./interfaces/ILuToken.sol";
import "./interfaces/InterfaceComptroller.sol";
import "./lib/TransferHelper.sol";

/**
 * @title LmnFi's Amm Swap Integration Contract
 * @notice This contracts allows users to swap a token for another one and supply/repay with the latter.
 * @dev For all functions that do not swap native NEON, user must approve this contract with the amount, prior the calling the swap function.
 * @author 0xlucian
 */

contract SwapRouter is Ownable2Step, RouterHelper, IAmmSwapV2Router {
    using SafeERC20 for IERC20;

    address public immutable comptrollerAddress;

    uint256 private constant _NOT_ENTERED = 1;

    uint256 private constant _ENTERED = 2;

    address public luNEONAddress;

    /**
     * @dev Guard variable for re-entrancy checks
     */
    uint256 internal _status;

    // ***************
    // ** MODIFIERS **
    // ***************
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert SwapDeadlineExpire(deadline, block.timestamp);
        }
        _;
    }

    modifier ensurePath(address[] calldata path) {
        if (path.length < 2) {
            revert InvalidPath();
        }
        _;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert ReentrantCheck();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @notice event emitted on sweep token success
    event SweepToken(address indexed token, address indexed to, uint256 sweepAmount);

    /// @notice event emitted on luNEONAddress update
    event LuNEONAddressUpdated(address indexed oldAddress, address indexed newAddress);

    // *********************
    // **** CONSTRUCTOR ****
    // *********************

    /// @notice Constructor for the implementation contract. Sets immutable variables.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address WNEON_,
        address factory_,
        address _comptrollerAddress,
        address _luNEONAddress
    ) RouterHelper(WNEON_, factory_) Ownable(_msgSender()) {
        if (_comptrollerAddress == address(0) || _luNEONAddress == address(0)) {
            revert ZeroAddress();
        }
        comptrollerAddress = _comptrollerAddress;
        _status = _NOT_ENTERED;
        luNEONAddress = _luNEONAddress;
    }

    receive() external payable {
        assert(msg.sender == WNEON); // only accept NEON via fallback from the WNEON contract
    }

    // ****************************
    // **** EXTERNAL FUNCTIONS ****
    // ****************************

    /**
     * @notice Setter for the luNEON address.
     * @param _luNEONAddress Address of the NEON luToken to update.
     */
    function setLuNEONAddress(address _luNEONAddress) external onlyOwner {
        if (_luNEONAddress == address(0)) {
            revert ZeroAddress();
        }

        _isLuTokenListed(_luNEONAddress);

        address oldAddress = luNEONAddress;
        luNEONAddress = _luNEONAddress;

        emit LuNEONAddressUpdated(oldAddress, luNEONAddress);
    }

    /**
     * @notice Swap token A for token B and supply to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupply(
        address luTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary (a small amount of fee is deducted at the time of transfer of token) token A for token B and supply to a LmnFi market.
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupplyAtSupportingFee(
        address luTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for another token and supply to a LmnFi market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping NEON
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactNEONForTokensAndSupply(
        address luTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactNEONForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and supply to a LmnFi market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping NEON
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactNEONForTokensAndSupplyAtSupportingFee(
        address luTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactNEONForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and supply to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForExactTokensAndSupply(
        address luTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for Exact tokens and supply to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapNEONForExactTokensAndSupply(
        address luTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapNEONForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for NEON and supply to a LmnFi market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactTokensForNEONAndSupply(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForNEON(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintLuNEONandTransfer(swapAmount);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for NEON and supply to a LmnFi market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactTokensForNEONAndSupplyAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForNEON(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        _mintLuNEONandTransfer(swapAmount);
    }

    /**
     * @notice Swap tokens for Exact NEON and supply to a LmnFi market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForExactNEONAndSupply(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactNEON(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintLuNEONandTransfer(swapAmount);
    }

    /**
     * @notice Swap token A for token B and repay a borrow from a LmnFi market
     * @param luTokenAddress The address of the luToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepay(
        address luTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary token (a small amount of fee is deducted at the time of transfer of token) token A for token B and repay a borrow from a LmnFi market
     * @param luTokenAddress The address of the luToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepayAtSupportingFee(
        address luTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for another token and repay a borrow from a LmnFi market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping NEON
     * @param luTokenAddress The address of the luToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactNEONForTokensAndRepay(
        address luTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactNEONForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and repay a borrow from a LmnFi market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping NEON
     * @param luTokenAddress The address of the luToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactNEONForTokensAndRepayAtSupportingFee(
        address luTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactNEONForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and repay to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForExactTokensAndRepay(
        address luTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for full tokens debt and repay to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForFullTokenDebtAndRepay(
        address luTokenAddress,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = ILuToken(luTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for Exact tokens and repay to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapNEONForExactTokensAndRepay(
        address luTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapNEONForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap NEON for Exact tokens and repay to a LmnFi market
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapNEONForFullTokenDebtAndRepay(
        address luTokenAddress,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureLuTokenChecks(luTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = ILuToken(luTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapNEONForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, luTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for NEON and repay to a LmnFi market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactTokensForNEONAndRepay(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForNEON(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ILuNEON(luNEONAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for NEON and repay to a LmnFi market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapExactTokensForNEONAndRepayAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForNEON(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        ILuNEON(luNEONAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact NEON and repay to a LmnFi market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForExactNEONAndRepay(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactNEON(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ILuNEON(luNEONAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact NEON and repay to a LmnFi market
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native NEON the first asset in path array should be the wNEON address
     */
    function swapTokensForFullNEONDebtAndRepay(
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        uint256 amountOut = ILuToken(luNEONAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactNEON(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ILuNEON(luNEONAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the luToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the luToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokensAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of NEON for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WNEON,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactNEONForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapExactNEONForTokens(amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of ETH for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WNEON,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactNEONForTokensAtSupportingFee(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactNEONForTokens(amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the luToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForNEON(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForNEON(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the luToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForNEONAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        uint256 balanceBefore = to.balance;
        _swapExactTokensForNEON(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = to.balance;
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactTokens(amountOut, amountInMax, path, to);
    }

    /**
     * @notice Swaps an as ETH as input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input WNEON,
     *         the last is the output as token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapNEONForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapNEONForExactTokens(amountOut, path, to);
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of ETH as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output as ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactNEON(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactNEON(amountOut, amountInMax, path, to);
    }

    /**
     * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to the address `to`, provided in input
     * @param token The address of the ERC-20 token to sweep
     * @param to Recipient of the output tokens.
     * @param sweepAmount The ampunt of the tokens to sweep
     * @custom:access Only Governance
     */
    function sweepToken(IERC20 token, address to, uint256 sweepAmount) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 balance = token.balanceOf(address(this));
        if (sweepAmount > balance) {
            revert InsufficientBalance(sweepAmount, balance);
        }
        token.safeTransfer(to, sweepAmount);

        emit SweepToken(address(token), to, sweepAmount);
    }

    /**
     * @notice Supply token to a LmnFi market
     * @param path The addresses of the underlying token
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param swapAmount The amount of tokens supply to LmnFi Market.
     */
    function _supply(address path, address luTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, luTokenAddress, 0);
        TransferHelper.safeApprove(path, luTokenAddress, swapAmount);
        uint256 response = ILuToken(luTokenAddress).mintBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert SupplyError(msg.sender, luTokenAddress, response);
        }
    }

    /**
     * @notice Repay a borrow from LmnFi market
     * @param path The addresses of the underlying token
     * @param luTokenAddress The address of the luToken contract for supplying assets.
     * @param swapAmount The amount of tokens repay to LmnFi Market.
     */
    function _repay(address path, address luTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, luTokenAddress, 0);
        TransferHelper.safeApprove(path, luTokenAddress, swapAmount);
        uint256 response = ILuToken(luTokenAddress).repayBorrowBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert RepayError(msg.sender, luTokenAddress, response);
        }
    }

    /**
     * @notice Check if the balance of to minus the balanceBefore is greater or equal to the amountOutMin.
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     * @param amountOutMin Min amount out threshold.
     * @param to Recipient of the output tokens.
     */
    function _checkForAmountOut(
        address asset,
        uint256 balanceBefore,
        uint256 amountOutMin,
        address to
    ) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(to);
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Returns the difference between the balance of this and the balanceBefore
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     */
    function _getSwapAmount(address asset, uint256 balanceBefore) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        swapAmount = balanceAfter - balanceBefore;
    }

    /**
     * @notice Check isLuTokenListed and last address in the path should be luToken underlying.
     * @param luTokenAddress Address of the luToken.
     * @param underlying Address of the underlying asset.
     */
    function _ensureLuTokenChecks(address luTokenAddress, address underlying) internal {
        _isLuTokenListed(luTokenAddress);
        if (ILuToken(luTokenAddress).underlying() != underlying) {
            revert LuTokenUnderlyingInvalid(underlying);
        }
    }

    /**
     * @notice Check is luToken listed in the pool.
     * @param luToken Address of the luToken.
     */
    function _isLuTokenListed(address luToken) internal view {
        bool isListed = InterfaceComptroller(comptrollerAddress).markets(luToken);
        if (!isListed) {
            revert LuTokenNotListed(luToken);
        }
    }

    /**
     * @notice Mint luNEON tokens to the market then transfer them to user
     * @param swapAmount Swapped NEON amount
     */
    function _mintLuNEONandTransfer(uint256 swapAmount) internal {
        uint256 luNEONBalanceBefore = ILuNEON(luNEONAddress).balanceOf(address(this));
        ILuNEON(luNEONAddress).mint{ value: swapAmount }();
        uint256 luNEONBalanceAfter = ILuNEON(luNEONAddress).balanceOf(address(this));
        IERC20(luNEONAddress).safeTransfer(msg.sender, (luNEONBalanceAfter - luNEONBalanceBefore));
    }
}
