//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { ILUMENVaultDistributor, TLUMENVaultDistributorReward } from "./interfaces/ILUMENVaultDistributor.sol";
import { ILUMENVault } from "./interfaces/ILUMENVault.sol";


contract LUMENVaultDistributor is ILUMENVaultDistributor, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    struct Recipient {
        uint256 lastShareIndex;
        uint256 credit;
    }
    // token => account => recipient
    mapping(address => mapping(address => Recipient)) public recipients;

    // account => shares
    mapping(address => uint256) public shares;

    // token => shareIndex
    mapping(address => uint256) public shareIndex;

    // token => totalShares
    uint256 public totalShares;

    event AddReward(address indexed token, uint256 amount, uint256 newShareIndex);
    event UpdateCredit(address indexed token, address indexed account, uint256 lastShareIndex, uint256 credit);
    event EditRecipient(address indexed account, uint256 shares, uint256 totalShares);
    event Claim(address indexed token, address indexed account, uint256 amount);

    // Valid reward tokens
    address[] public tokens;
    mapping(address => uint256) public tokenIndexes;

    address public vault;
    address public rewardToken;
    address public backer;
    uint256 public pid;

    modifier onlyAllowed() {
        require(msg.sender == vault || msg.sender == owner(), "Only_Vault");
        _;
    }
    modifier onlyBacker() {
        require(msg.sender == backer || msg.sender == owner(), "401");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _vault, address _rewardToken, uint256 _pid) external initializer {
        require(_vault != address(0), "NO_VAULT");

        __Ownable_init_unchained(msg.sender);
        tokens.push(address(0));
        vault = _vault;
        rewardToken = _rewardToken;
        pid = _pid;
    }

    function addReward(address token, address treasury, uint256 amount) external onlyBacker returns (uint256 _shareIndex) {
        require(tokenIndexes[token] > 0, 'Distributor: Invalid token');
        require(amount > 0, 'Distributor: Invalid amount');

        ILUMENVault(vault).requestDistributorUpdate(rewardToken, pid);

        if (totalShares == 0) {
            return shareIndex[token];
        }
        // accRewardPerShare
        _shareIndex = amount * 2**160 / totalShares + shareIndex[token];
        shareIndex[token] = _shareIndex;

        IERC20(token).safeTransferFrom(treasury, address(this), amount);
        emit AddReward(token, amount, shareIndex[token]);
    }

    function updateCredit(address token, address account) public returns (uint256 credit) {
        require(tokenIndexes[token] > 0, 'Distributor: Invalid token');

        uint256 _shareIndex = shareIndex[token];
        if (_shareIndex == 0) return 0;

        Recipient storage recipient = recipients[token][account];
        uint256 lastShareIndex = recipient.lastShareIndex;
        uint256 lastCredit = recipient.credit;
        uint256 _shares = shares[account];

        credit = lastCredit + (_shareIndex - lastShareIndex) * _shares / 2**160;
        recipient.lastShareIndex = _shareIndex;
        recipient.credit = credit;

        emit UpdateCredit(token, account, _shareIndex, credit);
    }

    function claim(address token, address account) external onlyAllowed returns (uint256 amount) {
        return claimInternal(token, account);
    }

    function claimAll(address account) external onlyAllowed returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 1; i < tokens.length; i++) {
            amounts[i] = claimInternal(tokens[i], account);
        }
    }

    function getClaimable(address token, address account) external view returns (uint256 amount) {
        uint256 _shareIndex = shareIndex[token];
        if (_shareIndex == 0) return 0;

        Recipient memory recipient = recipients[token][account];
        uint256 lastShareIndex = recipient.lastShareIndex;
        uint256 lastCredit = recipient.credit;
        uint256 _shares = shares[account];

        amount = lastCredit + (_shareIndex - lastShareIndex) * _shares / 2**160;
    }

    function pendingRewards(address account, uint256 userShares_, uint256 totalShares_) external view returns (TLUMENVaultDistributorReward[] memory){
        TLUMENVaultDistributorReward[] memory rewards = new TLUMENVaultDistributorReward[](tokens.length - 1);

        for (uint256 i = 1; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = 0;
            uint256 _shareIndex = shareIndex[token];
            if (_shareIndex != 0) {
                Recipient memory recipient = recipients[token][account];
                uint256 lastShareIndex = recipient.lastShareIndex;
                uint256 lastCredit = recipient.credit;

                amount = lastCredit + (_shareIndex - lastShareIndex) * userShares_ / 2**160;
            }

            rewards[i - 1] = TLUMENVaultDistributorReward({
                token: token,
                pendingRewards: amount,
                shares: userShares_,
                totalShares: totalShares_
            });
        }
        return rewards;
    }

    function claimInternal(address token, address account) internal returns (uint256 amount) {
        require(tokenIndexes[token] > 0, 'Distributor: Invalid token');

        amount = updateCredit(token, account);
        if (amount > 0) {
            recipients[token][account].credit = 0;

            IERC20(token).transfer(account, amount);
            emit Claim(token, account, amount);
        }
    }

    function update(uint256 totalShares_) external onlyAllowed {
        totalShares = totalShares_;
    }

    function deposited (address account, uint256 prevUserShares_, uint256 newUserShares_, uint256 totalVaultShares_) external onlyAllowed {
        if (prevUserShares_ > 0 && shares[account] == 0) {
            // has deposited before distributor contract
            shares[account] = prevUserShares_;
        }

        for (uint256 i = 1; i < tokens.length; i++) {
            updateCredit(tokens[i], account);
        }

        totalShares = totalVaultShares_;
        shares[account] = newUserShares_;
    }
    function withdrawn (address account, uint256 prevUserShares_, uint256 newUserShares_, uint256 totalVaultShares_) external onlyAllowed {
        if (prevUserShares_ > 0 && shares[account] == 0) {
            // has deposited before distributor contract
            shares[account] = prevUserShares_;
        }

        for (uint256 i = 1; i < tokens.length; i++) {
            updateCredit(tokens[i], account);
        }

        totalShares = totalVaultShares_;
        shares[account] = newUserShares_;
    }

    /* Admin functions */
    function addToken(address token) external onlyOwner {
        require(tokenIndexes[token] == 0, 'Distributor: token already added');
        tokens.push(token);
        tokenIndexes[token] = tokens.length - 1;
    }

    function removeToken(address token) external onlyOwner {
        uint256 index = tokenIndexes[token];
        require(index > 0, 'Distributor: token not found');
        require(IERC20(token).balanceOf(address(this)) == 0, "BALANCE>0");
        uint256 lastIndex = tokens.length - 1;
        if (index < lastIndex) {
            address lastToken = tokens[lastIndex];
            tokens[index] = lastToken;
            tokenIndexes[lastToken] = index;
        }
        tokens.pop();
        delete tokenIndexes[token];
    }
    function withdrawToken (address token, address treasury, uint256 amount) external onlyOwner {
        IERC20(token).transfer(treasury, amount);
    }


    function setBacker (address backer_) external onlyOwner {
        backer = backer_;
    }
    function setVault (address vault_) external onlyOwner {
        vault = vault_;
    }
}
