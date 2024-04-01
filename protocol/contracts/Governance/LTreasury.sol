pragma solidity ^0.8.20;

import "../Utils/IERC20.sol";
import "../Utils/SafeERC20.sol";
import "../Utils/Ownable.sol";

/**
 * @title LTreasury
 * @author LmnFi
 * @notice Protocol treasury that holds tokens owned by LmnFi
 */
contract LTreasury is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // WithdrawTreasuryERC20 Event
    event WithdrawTreasuryERC20(address tokenAddress, uint256 withdrawAmount, address withdrawAddress);

    // WithdrawTreasuryNEON Event
    event WithdrawTreasuryNEON(uint256 withdrawAmount, address withdrawAddress);

    /**
     * @notice To receive NEON
     */
    fallback() external payable {}

    /**
     * @notice Withdraw Treasury ERC20 Tokens, Only owner call it
     * @param tokenAddress The address of treasury token
     * @param withdrawAmount The withdraw amount to owner
     * @param withdrawAddress The withdraw address
     */
    function withdrawTreasuryERC20(
        address tokenAddress,
        uint256 withdrawAmount,
        address withdrawAddress
    ) external onlyOwner {
        uint256 actualWithdrawAmount = withdrawAmount;
        // Get Treasury Token Balance
        uint256 treasuryBalance = IERC20(tokenAddress).balanceOf(address(this));

        // Check Withdraw Amount
        if (withdrawAmount > treasuryBalance) {
            // Update actualWithdrawAmount
            actualWithdrawAmount = treasuryBalance;
        }

        // Transfer ERC20 Token to withdrawAddress
        IERC20(tokenAddress).safeTransfer(withdrawAddress, actualWithdrawAmount);

        emit WithdrawTreasuryERC20(tokenAddress, actualWithdrawAmount, withdrawAddress);
    }

    receive() external payable {

    }

    /**
     * @notice Withdraw Treasury NEON, Only owner call it
     * @param withdrawAmount The withdraw amount to owner
     * @param withdrawAddress The withdraw address
     */
    function withdrawTreasuryNEON(uint256 withdrawAmount, address payable withdrawAddress) external payable onlyOwner {
        uint256 actualWithdrawAmount = withdrawAmount;
        // Get Treasury NEON Balance
        uint256 nBalance = address(this).balance;

        // Check Withdraw Amount
        if (withdrawAmount > nBalance) {
            // Update actualWithdrawAmount
            actualWithdrawAmount = nBalance;
        }
        // Transfer NEON to withdrawAddress
        withdrawAddress.transfer(actualWithdrawAmount);

        emit WithdrawTreasuryNEON(actualWithdrawAmount, withdrawAddress);
    }
}
