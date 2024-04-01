pragma solidity ^0.8.20;


import "../Tokens/LuTokens/LuErc20.sol";
import "../Tokens/LuTokens/LuToken.sol";
import "../../../oracle/contracts/PriceOracle.sol";
import "../Tokens/EIP20Interface.sol";
import "../Governance/GovernorAlpha.sol";
import "../Tokens/LUMEN/LUMEN.sol";
import "../Comptroller/ComptrollerInterface.sol";
import "../Utils/SafeMath.sol";

contract LumenLens is ExponentialNoError {
    using SafeMath for uint;

    /// @notice Blocks Per Day
    uint public immutable BLOCKS_PER_DAY;

    struct LumenMarketState {
        uint224 index;
        uint32 block;
    }

    struct LuTokenMetadata {
        address luToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint luTokenDecimals;
        uint underlyingDecimals;
        uint lumenSupplySpeed;
        uint lumenBorrowSpeed;
        uint dailySupplyLumen;
        uint dailyBorrowLumen;
    }

    struct LuTokenBalances {
        address luToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    struct LuTokenUnderlyingPrice {
        address luToken;
        uint underlyingPrice;
    }

    struct AccountLimits {
        LuToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    struct GovReceipt {
        uint proposalId;
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    struct GovProposal {
        uint proposalId;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
    }

    struct LUMENBalanceMetadata {
        uint balance;
        uint votes;
        address delegate;
    }

    struct LUMENBalanceMetadataExt {
        uint balance;
        uint votes;
        address delegate;
        uint allocated;
    }

    struct LumenVotes {
        uint blockNumber;
        uint votes;
    }

    struct ClaimLumenLocalVariables {
        uint totalRewards;
        uint224 borrowIndex;
        uint32 borrowBlock;
        uint224 supplyIndex;
        uint32 supplyBlock;
    }

    /**
     * @dev Struct for Pending Rewards for per market
     */
    struct PendingReward {
        address luTokenAddress;
        uint256 amount;
    }

    /**
     * @dev Struct for Reward of a single reward token.
     */
    struct RewardSummary {
        address distributorAddress;
        address rewardTokenAddress;
        uint256 totalRewards;
        PendingReward[] pendingRewards;
    }


    constructor (uint256 blocksPerDay) {
        BLOCKS_PER_DAY = blocksPerDay;
    }

    /**
     * @notice Query the metadata of a luToken by its address
     * @param luToken The address of the luToken to fetch LuTokenMetadata
     * @return LuTokenMetadata struct with luToken supply and borrow information.
     */
    function luTokenMetadata(LuToken luToken) public returns (LuTokenMetadata memory) {
        uint exchangeRateCurrent = luToken.exchangeRateCurrent();
        address comptrollerAddress = address(luToken.comptroller());
        ComptrollerInterface comptroller = ComptrollerInterface(comptrollerAddress);
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(address(luToken));
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(luToken.symbol(), "luNEON")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            LuErc20 luep20 = LuErc20(address(luToken));
            underlyingAssetAddress = luep20.underlying();
            underlyingDecimals = EIP20Interface(luep20.underlying()).decimals();
        }

        uint lumenSupplySpeedPerBlock = comptroller.lumenSupplySpeeds(address(luToken));
        uint lumenBorrowSpeedPerBlock = comptroller.lumenBorrowSpeeds(address(luToken));

        return
            LuTokenMetadata({
                luToken: address(luToken),
                exchangeRateCurrent: exchangeRateCurrent,
                supplyRatePerBlock: luToken.supplyRatePerBlock(),
                borrowRatePerBlock: luToken.borrowRatePerBlock(),
                reserveFactorMantissa: luToken.reserveFactorMantissa(),
                totalBorrows: luToken.totalBorrows(),
                totalReserves: luToken.totalReserves(),
                totalSupply: luToken.totalSupply(),
                totalCash: luToken.getCash(),
                isListed: isListed,
                collateralFactorMantissa: collateralFactorMantissa,
                underlyingAssetAddress: underlyingAssetAddress,
                luTokenDecimals: luToken.decimals(),
                underlyingDecimals: underlyingDecimals,
                lumenSupplySpeed: lumenSupplySpeedPerBlock,
                lumenBorrowSpeed: lumenBorrowSpeedPerBlock,
                dailySupplyLumen: lumenSupplySpeedPerBlock.mul(BLOCKS_PER_DAY),
                dailyBorrowLumen: lumenBorrowSpeedPerBlock.mul(BLOCKS_PER_DAY)
            });
    }

    /**
     * @notice Get LuTokenMetadata for an array of luToken addresses
     * @param luTokens Array of luToken addresses to fetch LuTokenMetadata
     * @return Array of structs with luToken supply and borrow information.
     */
    function luTokenMetadataAll(LuToken[] calldata luTokens) external returns (LuTokenMetadata[] memory) {
        uint luTokenCount = luTokens.length;
        LuTokenMetadata[] memory res = new LuTokenMetadata[](luTokenCount);
        for (uint i = 0; i < luTokenCount; i++) {
            res[i] = luTokenMetadata(luTokens[i]);
        }
        return res;
    }

    /**
     * @notice Get amount of LUMEN distributed daily to an account
     * @param account Address of account to fetch the daily LUMEN distribution
     * @param comptrollerAddress Address of the comptroller proxy
     * @return Amount of LUMEN distributed daily to an account
     */
    function getDailyLUMEN(address payable account, address comptrollerAddress) external returns (uint) {
        ComptrollerInterface comptrollerInstance = ComptrollerInterface(comptrollerAddress);
        LuToken[] memory luTokens = comptrollerInstance.getAllMarkets();
        uint dailyLumenPerAccount = 0;

        for (uint i = 0; i < luTokens.length; i++) {
            LuToken luToken = luTokens[i];
            if (!compareStrings(luToken.symbol(), "luST") && !compareStrings(luToken.symbol(), "luUNA")) {
                LuTokenMetadata memory metaDataItem = luTokenMetadata(luToken);

                //get balanceOfUnderlying and borrowBalanceCurrent from luTokenBalance
                LuTokenBalances memory luTokenBalanceInfo = luTokenBalances(luToken, account);

                LuTokenUnderlyingPrice memory underlyingPriceResponse = luTokenUnderlyingPrice(luToken);
                uint underlyingPrice = underlyingPriceResponse.underlyingPrice;
                Exp memory underlyingPriceMantissa = Exp({ mantissa: underlyingPrice });

                //get dailyLumenSupplyMarket
                uint dailyLumenSupplyMarket = 0;
                uint supplyInUsd = mul_ScalarTruncate(underlyingPriceMantissa, luTokenBalanceInfo.balanceOfUnderlying);
                uint marketTotalSupply = (metaDataItem.totalSupply.mul(metaDataItem.exchangeRateCurrent)).div(1e18);
                uint marketTotalSupplyInUsd = mul_ScalarTruncate(underlyingPriceMantissa, marketTotalSupply);

                if (marketTotalSupplyInUsd > 0) {
                    dailyLumenSupplyMarket = (metaDataItem.dailySupplyLumen.mul(supplyInUsd)).div(marketTotalSupplyInUsd);
                }

                //get dailyLumenBorrowMarket
                uint dailyLumenBorrowMarket = 0;
                uint borrowsInUsd = mul_ScalarTruncate(underlyingPriceMantissa, luTokenBalanceInfo.borrowBalanceCurrent);
                uint marketTotalBorrowsInUsd = mul_ScalarTruncate(underlyingPriceMantissa, metaDataItem.totalBorrows);

                if (marketTotalBorrowsInUsd > 0) {
                    dailyLumenBorrowMarket = (metaDataItem.dailyBorrowLumen.mul(borrowsInUsd)).div(marketTotalBorrowsInUsd);
                }

                dailyLumenPerAccount += dailyLumenSupplyMarket + dailyLumenBorrowMarket;
            }
        }

        return dailyLumenPerAccount;
    }

    /**
     * @notice Get the current luToken balance (outstanding borrows) for an account
     * @param luToken Address of the token to check the balance of
     * @param account Account address to fetch the balance of
     * @return LuTokenBalances with token balance information
     */
    function luTokenBalances(LuToken luToken, address payable account) public returns (LuTokenBalances memory) {
        uint balanceOf = luToken.balanceOf(account);
        uint borrowBalanceCurrent = luToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = luToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (compareStrings(luToken.symbol(), "luNEON")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            LuErc20 luep20 = LuErc20(address(luToken));
            EIP20Interface underlying = EIP20Interface(luep20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(luToken));
        }

        return
            LuTokenBalances({
                luToken: address(luToken),
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                balanceOfUnderlying: balanceOfUnderlying,
                tokenBalance: tokenBalance,
                tokenAllowance: tokenAllowance
            });
    }

    /**
     * @notice Get the current luToken balances (outstanding borrows) for all luTokens on an account
     * @param luTokens Addresses of the tokens to check the balance of
     * @param account Account address to fetch the balance of
     * @return LuTokenBalances Array with token balance information
     */
    function luTokenBalancesAll(
        LuToken[] calldata luTokens,
        address payable account
    ) external returns (LuTokenBalances[] memory) {
        uint luTokenCount = luTokens.length;
        LuTokenBalances[] memory res = new LuTokenBalances[](luTokenCount);
        for (uint i = 0; i < luTokenCount; i++) {
            res[i] = luTokenBalances(luTokens[i], account);
        }
        return res;
    }

    /**
     * @notice Get the price for the underlying asset of a luToken
     * @param luToken address of the luToken
     * @return response struct with underlyingPrice info of luToken
     */
    function luTokenUnderlyingPrice(LuToken luToken) public view returns (LuTokenUnderlyingPrice memory) {
        ComptrollerInterface comptroller = ComptrollerInterface(address(luToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return
            LuTokenUnderlyingPrice({ luToken: address(luToken), underlyingPrice: priceOracle.getUnderlyingPrice(luToken) });
    }

    /**
     * @notice Query the underlyingPrice of an array of luTokens
     * @param luTokens Array of luToken addresses
     * @return array of response structs with underlying price information of luTokens
     */
    function luTokenUnderlyingPriceAll(
        LuToken[] calldata luTokens
    ) external view returns (LuTokenUnderlyingPrice[] memory) {
        uint luTokenCount = luTokens.length;
        LuTokenUnderlyingPrice[] memory res = new LuTokenUnderlyingPrice[](luTokenCount);
        for (uint i = 0; i < luTokenCount; i++) {
            res[i] = luTokenUnderlyingPrice(luTokens[i]);
        }
        return res;
    }

    /**
     * @notice Query the account liquidity and shortfall of an account
     * @param comptroller Address of comptroller proxy
     * @param account Address of the account to query
     * @return Struct with markets user has entered, liquidity, and shortfall of the account
     */
    function getAccountLimits(
        ComptrollerInterface comptroller,
        address account
    ) public view returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0, "account liquidity error");

        return AccountLimits({ markets: comptroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall });
    }

    /**
     * @notice Query the voting information of an account for a list of governance proposals
     * @param governor Governor address
     * @param voter Voter address
     * @param proposalIds Array of proposal ids
     * @return Array of governor receipts
     */
    function getGovReceipts(
        GovernorAlpha governor,
        address voter,
        uint[] memory proposalIds
    ) public view returns (GovReceipt[] memory) {
        uint proposalCount = proposalIds.length;
        GovReceipt[] memory res = new GovReceipt[](proposalCount);
        for (uint i = 0; i < proposalCount; i++) {
            GovernorAlpha.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
            res[i] = GovReceipt({
                proposalId: proposalIds[i],
                hasVoted: receipt.hasVoted,
                support: receipt.support,
                votes: receipt.votes
            });
        }
        return res;
    }

    /**
     * @dev Given a GovProposal struct, fetches and sets proposal data
     * @param res GovernProposal struct
     * @param governor Governor address
     * @param proposalId Id of a proposal
     */
    function setProposal(GovProposal memory res, GovernorAlpha governor, uint proposalId) internal view {
        (
            ,
            address proposer,
            uint eta,
            uint startBlock,
            uint endBlock,
            uint forVotes,
            uint againstVotes,
            bool canceled,
            bool executed
        ) = governor.proposals(proposalId);
        res.proposalId = proposalId;
        res.proposer = proposer;
        res.eta = eta;
        res.startBlock = startBlock;
        res.endBlock = endBlock;
        res.forVotes = forVotes;
        res.againstVotes = againstVotes;
        res.canceled = canceled;
        res.executed = executed;
    }

    /**
     * @notice Query the details of a list of governance proposals
     * @param governor Address of governor contract
     * @param proposalIds Array of proposal Ids
     * @return GovProposal structs for provided proposal Ids
     */
    function getGovProposals(
        GovernorAlpha governor,
        uint[] calldata proposalIds
    ) external view returns (GovProposal[] memory) {
        GovProposal[] memory res = new GovProposal[](proposalIds.length);
        for (uint i = 0; i < proposalIds.length; i++) {
            (
                address[] memory targets,
                uint[] memory values,
                string[] memory signatures,
                bytes[] memory calldatas
            ) = governor.getActions(proposalIds[i]);
            res[i] = GovProposal({
                proposalId: 0,
                proposer: address(0),
                eta: 0,
                targets: targets,
                values: values,
                signatures: signatures,
                calldatas: calldatas,
                startBlock: 0,
                endBlock: 0,
                forVotes: 0,
                againstVotes: 0,
                canceled: false,
                executed: false
            });
            setProposal(res[i], governor, proposalIds[i]);
        }
        return res;
    }

    /**
     * @notice Query the LUMENBalance info of an account
     * @param lumen LUMEN contract address
     * @param account Account address
     * @return Struct with LUMEN balance and voter details
     */
    function getLUMENBalanceMetadata(LUMEN lumen, address account) external view returns (LUMENBalanceMetadata memory) {
        return
            LUMENBalanceMetadata({
                balance: lumen.balanceOf(account),
                votes: uint256(lumen.getCurrentVotes(account)),
                delegate: lumen.delegates(account)
            });
    }

    /**
     * @notice Query the LUMENBalance extended info of an account
     * @param lumen LUMEN contract address
     * @param comptroller Comptroller proxy contract address
     * @param account Account address
     * @return Struct with LUMEN balance and voter details and LUMEN allocation
     */
    function getLUMENBalanceMetadataExt(
        LUMEN lumen,
        ComptrollerInterface comptroller,
        address account
    ) external returns (LUMENBalanceMetadataExt memory) {
        uint balance = lumen.balanceOf(account);
        comptroller.claimLumen(account);
        uint newBalance = lumen.balanceOf(account);
        uint accrued = comptroller.lumenAccrued(account);
        uint total = add_(accrued, newBalance, "sum lumen total");
        uint allocated = sub_(total, balance, "sub allocated");

        return
            LUMENBalanceMetadataExt({
                balance: balance,
                votes: uint256(lumen.getCurrentVotes(account)),
                delegate: lumen.delegates(account),
                allocated: allocated
            });
    }

    /**
     * @notice Query the voting power for an account at a specific list of block numbers
     * @param lumen LUMEN contract address
     * @param account Address of the account
     * @param blockNumbers Array of blocks to query
     * @return Array of LumenVotes structs with block number and vote count
     */
    function getLumenVotes(
        LUMEN lumen,
        address account,
        uint32[] calldata blockNumbers
    ) external view returns (LumenVotes[] memory) {
        LumenVotes[] memory res = new LumenVotes[](blockNumbers.length);
        for (uint i = 0; i < blockNumbers.length; i++) {
            res[i] = LumenVotes({
                blockNumber: uint256(blockNumbers[i]),
                votes: uint256(lumen.getPriorVotes(account, blockNumbers[i]))
            });
        }
        return res;
    }

    /**
     * @dev Queries the current supply to calculate rewards for an account
     * @param supplyState LumenMarketState struct
     * @param luToken Address of a luToken
     * @param comptroller Address of the comptroller proxy
     */
    function updateLumenSupplyIndex(
        LumenMarketState memory supplyState,
        address luToken,
        ComptrollerInterface comptroller
    ) internal view {
        uint supplySpeed = comptroller.lumenSupplySpeeds(luToken);
        uint blockNumber = block.number;
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = LuToken(luToken).totalSupply();
            uint lumenAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(lumenAccrued, supplyTokens) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: supplyState.index }), ratio);
            supplyState.index = safe224(index.mantissa, "new index overflows");
            supplyState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @dev Queries the current borrow to calculate rewards for an account
     * @param borrowState LumenMarketState struct
     * @param luToken Address of a luToken
     * @param comptroller Address of the comptroller proxy
     */
    function updateLumenBorrowIndex(
        LumenMarketState memory borrowState,
        address luToken,
        Exp memory marketBorrowIndex,
        ComptrollerInterface comptroller
    ) internal view {
        uint borrowSpeed = comptroller.lumenBorrowSpeeds(luToken);
        uint blockNumber = block.number;
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(LuToken(luToken).totalBorrows(), marketBorrowIndex);
            uint lumenAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(lumenAccrued, borrowAmount) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: borrowState.index }), ratio);
            borrowState.index = safe224(index.mantissa, "new index overflows");
            borrowState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @dev Calculate available rewards for an account's supply
     * @param supplyState LumenMarketState struct
     * @param luToken Address of a luToken
     * @param supplier Address of the account supplying
     * @param comptroller Address of the comptroller proxy
     * @return Undistributed earned LUMEN from supplies
     */
    function distributeSupplierLumen(
        LumenMarketState memory supplyState,
        address luToken,
        address supplier,
        ComptrollerInterface comptroller
    ) internal view returns (uint) {
        Double memory supplyIndex = Double({ mantissa: supplyState.index });
        Double memory supplierIndex = Double({ mantissa: comptroller.lumenSupplierIndex(luToken, supplier) });
        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = comptroller.lumenInitialIndex();
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = LuToken(luToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        return supplierDelta;
    }

    /**
     * @dev Calculate available rewards for an account's borrows
     * @param borrowState LumenMarketState struct
     * @param luToken Address of a luToken
     * @param borrower Address of the account borrowing
     * @param marketBorrowIndex luToken Borrow index
     * @param comptroller Address of the comptroller proxy
     * @return Undistributed earned LUMEN from borrows
     */
    function distributeBorrowerLumen(
        LumenMarketState memory borrowState,
        address luToken,
        address borrower,
        Exp memory marketBorrowIndex,
        ComptrollerInterface comptroller
    ) internal view returns (uint) {
        Double memory borrowIndex = Double({ mantissa: borrowState.index });
        Double memory borrowerIndex = Double({ mantissa: comptroller.lumenBorrowerIndex(luToken, borrower) });
        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(LuToken(luToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            return borrowerDelta;
        }
        return 0;
    }

    /**
     * @notice Calculate the total LUMEN tokens pending and accrued by a user account
     * @param holder Account to query pending LUMEN
     * @param comptroller Address of the comptroller
     * @return Reward object contraining the totalRewards and pending rewards for each market
     */
    function pendingRewards(
        address holder,
        ComptrollerInterface comptroller
    ) external view returns (RewardSummary memory) {
        LuToken[] memory luTokens = comptroller.getAllMarkets();
        ClaimLumenLocalVariables memory vars;
        RewardSummary memory rewardSummary;
        rewardSummary.distributorAddress = address(comptroller);
        rewardSummary.rewardTokenAddress = comptroller.getLUMENAddress();
        rewardSummary.totalRewards = comptroller.lumenAccrued(holder);
        rewardSummary.pendingRewards = new PendingReward[](luTokens.length);
        for (uint i; i < luTokens.length; ++i) {
            (vars.borrowIndex, vars.borrowBlock) = comptroller.lumenBorrowState(address(luTokens[i]));
            LumenMarketState memory borrowState = LumenMarketState({
                index: vars.borrowIndex,
                block: vars.borrowBlock
            });

            (vars.supplyIndex, vars.supplyBlock) = comptroller.lumenSupplyState(address(luTokens[i]));
            LumenMarketState memory supplyState = LumenMarketState({
                index: vars.supplyIndex,
                block: vars.supplyBlock
            });

            Exp memory borrowIndex = Exp({ mantissa: luTokens[i].borrowIndex() });

            PendingReward memory marketReward;
            marketReward.luTokenAddress = address(luTokens[i]);

            updateLumenBorrowIndex(borrowState, address(luTokens[i]), borrowIndex, comptroller);
            uint256 borrowReward = distributeBorrowerLumen(
                borrowState,
                address(luTokens[i]),
                holder,
                borrowIndex,
                comptroller
            );

            updateLumenSupplyIndex(supplyState, address(luTokens[i]), comptroller);
            uint256 supplyReward = distributeSupplierLumen(supplyState, address(luTokens[i]), holder, comptroller);

            marketReward.amount = add_(borrowReward, supplyReward);
            rewardSummary.pendingRewards[i] = marketReward;
        }
        return rewardSummary;
    }

    // utilities
    /**
     * @notice Compares if two strings are equal
     * @param a First string to compare
     * @param b Second string to compare
     * @return Boolean depending on if the strings are equal
     */
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
