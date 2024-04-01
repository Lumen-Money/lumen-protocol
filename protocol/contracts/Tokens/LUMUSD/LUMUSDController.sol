pragma solidity ^0.8.20;

import "../../../../oracle/contracts/PriceOracle.sol";
import "../../Utils/ErrorReporter.sol";
import "../../Utils/Exponential.sol";
import "../../Comptroller/ComptrollerStorage.sol";
import "../../Comptroller/ComptrollerInterface.sol";
import "../../Governance/IAccessControlManager.sol";
import "../LuTokens/LuToken.sol";
import "./LUMUSDControllerStorage.sol";
import "./LUMUSDUnitroller.sol";
import "./LUMUSD.sol";

/**
 * @title LUMUSD Comptroller
 * @author LmnFi
 * @notice This is the implementation contract for the LUMUSDUnitroller proxy
 */
contract LUMUSDController is LUMUSDControllerStorageG2, LUMUSDControllerErrorReporter, Exponential {
    /// @notice Initial index used in interest computations
    uint public constant INITIAL_LUMUSD_MINT_INDEX = 1e18;

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /// @notice Event emitted when LUMUSD is minted
    event MintLUMUSD(address minter, uint mintLUMUSDAmount);

    /// @notice Event emitted when LUMUSD is repaid
    event RepayLUMUSD(address payer, address borrower, uint repayLUMUSDAmount);

    /// @notice Event emitted when a borrow is liquidated
    event LiquidateLUMUSD(
        address liquidator,
        address borrower,
        uint repayAmount,
        address luTokenCollateral,
        uint seizeTokens
    );

    /// @notice Emitted when treasury guardian is changed
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /// @notice Emitted when treasury address is changed
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /// @notice Emitted when treasury percent is changed
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    /// @notice Event emitted when LUMUSDs are minted and fee are transferred
    event MintFee(address minter, uint feeAmount);

    /// @notice Emiitted when LUMUSD base rate is changed
    event NewLUMUSDBaseRate(uint256 oldBaseRateMantissa, uint256 newBaseRateMantissa);

    /// @notice Emiitted when LUMUSD float rate is changed
    event NewLUMUSDFloatRate(uint oldFloatRateMantissa, uint newFlatRateMantissa);

    /// @notice Emiitted when LUMUSD receiver address is changed
    event NewLUMUSDReceiver(address oldReceiver, address newReceiver);

    /// @notice Emiitted when LUMUSD mint cap is changed
    event NewLUMUSDMintCap(uint oldMintCap, uint newMintCap);

    /// @notice Emitted when access control address is changed by admin
    event NewAccessControl(address oldAccessControlAddress, address newAccessControlAddress);

    /*** Main Actions ***/
    struct MintLocalVars {
        uint oErr;
        MathError mathErr;
        uint mintAmount;
        uint accountMintLUMUSDNew;
        uint accountMintableLUMUSD;
    }

    function initialize() external onlyAdmin {
        require(lumUsdMintIndex == 0, "already initialized");

        lumUsdMintIndex = INITIAL_LUMUSD_MINT_INDEX;
        accrualBlockNumber = getBlockNumber();
        mintCap = type(uint256).max;

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    function _become(LUMUSDUnitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice The mintLUMUSD function mints and transfers LUMUSD from the protocol to the user, and adds a borrow balance.
     * The amount minted must be less than the user's Account Liquidity and the mint lumUsd limit.
     * @param mintLUMUSDAmount The amount of the LUMUSD to be minted.
     * @return 0 on success, otherwise an error code
     */
    // solhint-disable-next-line code-complexity
    function mintLUMUSD(uint mintLUMUSDAmount) external nonReentrant returns (uint) {
        if (address(comptroller) != address(0)) {
            require(mintLUMUSDAmount > 0, "mintLUMUSDAmount cannot be zero");
            require(!comptroller.protocolPaused(), "protocol is paused");

            accrueLUMUSDInterest();

            MintLocalVars memory vars;

            address minter = msg.sender;
            uint lumUsdTotalSupply = EIP20Interface(getLUMUSDAddress()).totalSupply();
            uint lumUsdNewTotalSupply;

            (vars.mathErr, lumUsdNewTotalSupply) = addUInt(lumUsdTotalSupply, mintLUMUSDAmount);
            require(lumUsdNewTotalSupply <= mintCap, "mint cap reached");

            if (vars.mathErr != MathError.NO_ERROR) {
                return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
            }

            (vars.oErr, vars.accountMintableLUMUSD) = getMintableLUMUSD(minter);
            if (vars.oErr != uint(Error.NO_ERROR)) {
                return uint(Error.REJECTION);
            }

            // check that user have sufficient mintableLUMUSD balance
            if (mintLUMUSDAmount > vars.accountMintableLUMUSD) {
                return fail(Error.REJECTION, FailureInfo.LUMUSD_MINT_REJECTION);
            }

            // Calculate the minted balance based on interest index
            uint totalMintedLUMUSD = comptroller.mintedLUMUSDs(minter);

            if (totalMintedLUMUSD > 0) {
                uint256 repayAmount = getLUMUSDRepayAmount(minter);
                uint remainedAmount;

                (vars.mathErr, remainedAmount) = subUInt(repayAmount, totalMintedLUMUSD);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, pastLUMUSDInterest[minter]) = addUInt(pastLUMUSDInterest[minter], remainedAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                totalMintedLUMUSD = repayAmount;
            }

            (vars.mathErr, vars.accountMintLUMUSDNew) = addUInt(totalMintedLUMUSD, mintLUMUSDAmount);
            require(vars.mathErr == MathError.NO_ERROR, "LUMUSD_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedLUMUSDOf(minter, vars.accountMintLUMUSDNew);
            if (error != 0) {
                return error;
            }

            uint feeAmount;
            uint remainedAmount;
            vars.mintAmount = mintLUMUSDAmount;
            if (treasuryPercent != 0) {
                (vars.mathErr, feeAmount) = mulUInt(vars.mintAmount, treasuryPercent);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, remainedAmount) = subUInt(vars.mintAmount, feeAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                LUMUSD(getLUMUSDAddress()).mint(treasuryAddress, feeAmount);

                emit MintFee(minter, feeAmount);
            } else {
                remainedAmount = vars.mintAmount;
            }

            LUMUSD(getLUMUSDAddress()).mint(minter, remainedAmount);
            lumUsdMinterInterestIndex[minter] = lumUsdMintIndex;

            emit MintLUMUSD(minter, remainedAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice The repay function transfers LUMUSD into the protocol and burn, reducing the user's borrow balance.
     * Before repaying an asset, users must first approve the LUMUSD to access their LUMUSD balance.
     * @param repayLUMUSDAmount The amount of the LUMUSD to be repaid.
     * @return 0 on success, otherwise an error code
     */
    function repayLUMUSD(uint repayLUMUSDAmount) external nonReentrant returns (uint, uint) {
        if (address(comptroller) != address(0)) {
            accrueLUMUSDInterest();

            require(repayLUMUSDAmount > 0, "repayLUMUSDAmount cannt be zero");

            require(!comptroller.protocolPaused(), "protocol is paused");

            return repayLUMUSDFresh(msg.sender, msg.sender, repayLUMUSDAmount);
        }
    }

    /**
     * @notice Repay LUMUSD Internal
     * @notice Borrowed LUMUSDs are repaid by another user (possibly the borrower).
     * @param payer the account paying off the LUMUSD
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of LUMUSD being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayLUMUSDFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        MathError mErr;

        (uint burn, uint partOfCurrentInterest, uint partOfPastInterest) = getLUMUSDCalculateRepayAmount(
            borrower,
            repayAmount
        );

        LUMUSD(getLUMUSDAddress()).burn(payer, burn);
        bool success = LUMUSD(getLUMUSDAddress()).transferFrom(payer, receiver, partOfCurrentInterest);
        require(success == true, "failed to transfer LUMUSD fee");

        uint lumUsdBalanceBorrower = comptroller.mintedLUMUSDs(borrower);
        uint accountLUMUSDNew;

        (mErr, accountLUMUSDNew) = subUInt(lumUsdBalanceBorrower, burn);
        require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, accountLUMUSDNew) = subUInt(accountLUMUSDNew, partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, pastLUMUSDInterest[borrower]) = subUInt(pastLUMUSDInterest[borrower], partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

        uint error = comptroller.setMintedLUMUSDOf(borrower, accountLUMUSDNew);
        if (error != 0) {
            return (error, 0);
        }
        emit RepayLUMUSD(payer, borrower, burn);

        return (uint(Error.NO_ERROR), burn);
    }

    /**
     * @notice The sender liquidates the lumUsd minters collateral. The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of lumUsd to be liquidated
     * @param luTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateLUMUSD(
        address borrower,
        uint repayAmount,
        LuTokenInterface luTokenCollateral
    ) external nonReentrant returns (uint, uint) {
        require(!comptroller.protocolPaused(), "protocol is paused");

        uint error = luTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.LUMUSD_LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateLUMUSDFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateLUMUSDFresh(msg.sender, borrower, repayAmount, luTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral by repay borrowers LUMUSD.
     *  The collateral seized is transferred to the liquidator.
     * @param liquidator The address repaying the LUMUSD and seizing collateral
     * @param borrower The borrower of this LUMUSD to be liquidated
     * @param luTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the LUMUSD to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment LUMUSD.
     */
    function liquidateLUMUSDFresh(
        address liquidator,
        address borrower,
        uint repayAmount,
        LuTokenInterface luTokenCollateral
    ) internal returns (uint, uint) {
        if (address(comptroller) != address(0)) {
            accrueLUMUSDInterest();

            /* Fail if liquidate not allowed */
            uint allowed = comptroller.liquidateBorrowAllowed(
                address(this),
                address(luTokenCollateral),
                liquidator,
                borrower,
                repayAmount
            );
            if (allowed != 0) {
                return (failOpaque(Error.REJECTION, FailureInfo.LUMUSD_LIQUIDATE_COMPTROLLER_REJECTION, allowed), 0);
            }

            /* Verify luTokenCollateral market's block number equals current block number */
            //if (luTokenCollateral.accrualBlockNumber() != accrualBlockNumber) {
            if (luTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
                return (fail(Error.REJECTION, FailureInfo.LUMUSD_LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
            }

            /* Fail if borrower = liquidator */
            if (borrower == liquidator) {
                return (fail(Error.REJECTION, FailureInfo.LUMUSD_LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
            }

            /* Fail if repayAmount = 0 */
            if (repayAmount == 0) {
                return (fail(Error.REJECTION, FailureInfo.LUMUSD_LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
            }

            /* Fail if repayAmount = -1 */
            if (repayAmount == type(uint256).max) {
                return (fail(Error.REJECTION, FailureInfo.LUMUSD_LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
            }

            /* Fail if repayLUMUSD fails */
            (uint repayBorrowError, uint actualRepayAmount) = repayLUMUSDFresh(liquidator, borrower, repayAmount);
            if (repayBorrowError != uint(Error.NO_ERROR)) {
                return (fail(Error(repayBorrowError), FailureInfo.LUMUSD_LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
            }

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /* We calculate the number of collateral tokens that will be seized */
            (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateLUMUSDCalculateSeizeTokens(
                address(luTokenCollateral),
                actualRepayAmount
            );
            require(
                amountSeizeError == uint(Error.NO_ERROR),
                "LUMUSD_LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED"
            );

            /* Revert if borrower collateral token balance < seizeTokens */
            require(luTokenCollateral.balanceOf(borrower) >= seizeTokens, "LUMUSD_LIQUIDATE_SEIZE_TOO_MUCH");

            uint seizeError;
            seizeError = luTokenCollateral.seize(liquidator, borrower, seizeTokens);

            /* Revert if seize tokens fails (since we cannot be sure of side effects) */
            require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

            /* We emit a LiquidateBorrow event */
            emit LiquidateLUMUSD(liquidator, borrower, actualRepayAmount, address(luTokenCollateral), seizeTokens);

            /* We call the defense hook */
            comptroller.liquidateBorrowVerify(
                address(this),
                address(luTokenCollateral),
                liquidator,
                borrower,
                actualRepayAmount,
                seizeTokens
            );

            return (uint(Error.NO_ERROR), actualRepayAmount);
        }
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new comptroller
     * @dev Admin function to set a new comptroller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptroller(ComptrollerInterface comptroller_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account total supply balance.
     *  Note that `luTokenBalance` is the number of luTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountAmountLocalVars {
        uint oErr;
        MathError mErr;
        uint sumSupply;
        uint marketSupply;
        uint sumBorrowPlusEffects;
        uint luTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    // solhint-disable-next-line code-complexity
    function getMintableLUMUSD(address minter) public view returns (uint, uint) {
        PriceOracle oracle = comptroller.oracle();
        LuToken[] memory enteredMarkets = comptroller.getAssetsIn(minter);

        AccountAmountLocalVars memory vars; // Holds all our calculation results

        uint accountMintableLUMUSD;
        uint i;

        /**
         * We use this formula to calculate mintable LUMUSD amount.
         * totalSupplyAmount * LUMUSDMintRate - (totalBorrowAmount + mintedLUMUSDOf)
         */
        for (i = 0; i < enteredMarkets.length; i++) {
            (vars.oErr, vars.luTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = enteredMarkets[i]
                .getAccountSnapshot(minter);
            if (vars.oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0);
            }
            vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(enteredMarkets[i]);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0);
            }
            vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

            (vars.mErr, vars.tokensToDenom) = mulExp(vars.exchangeRate, vars.oraclePrice);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // marketSupply = tokensToDenom * luTokenBalance
            (vars.mErr, vars.marketSupply) = mulScalarTruncate(vars.tokensToDenom, vars.luTokenBalance);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (, uint collateralFactorMantissa) = comptroller.markets(address(enteredMarkets[i]));
            (vars.mErr, vars.marketSupply) = mulUInt(vars.marketSupply, collateralFactorMantissa);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.marketSupply) = divUInt(vars.marketSupply, 1e18);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.sumSupply) = addUInt(vars.sumSupply, vars.marketSupply);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (vars.mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }
        }

        uint totalMintedLUMUSD = comptroller.mintedLUMUSDs(minter);
        uint256 repayAmount = 0;

        if (totalMintedLUMUSD > 0) {
            repayAmount = getLUMUSDRepayAmount(minter);
        }

        (vars.mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, repayAmount);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (vars.mErr, accountMintableLUMUSD) = mulUInt(vars.sumSupply, comptroller.lumUsdMintRate());
        require(vars.mErr == MathError.NO_ERROR, "LUMUSD_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableLUMUSD) = divUInt(accountMintableLUMUSD, 10000);
        require(vars.mErr == MathError.NO_ERROR, "LUMUSD_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableLUMUSD) = subUInt(accountMintableLUMUSD, vars.sumBorrowPlusEffects);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableLUMUSD);
    }

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint newTreasuryPercent
    ) external returns (uint) {
        // Check caller is admin
        if (!(msg.sender == admin || msg.sender == treasuryGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TREASURY_OWNER_CHECK);
        }

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint(Error.NO_ERROR);
    }

    function getLUMUSDRepayRate() public view returns (uint) {
        PriceOracle oracle = comptroller.oracle();
        MathError mErr;

        if (baseRateMantissa > 0) {
            if (floatRateMantissa > 0) {
                uint oraclePrice = oracle.getUnderlyingPrice(LuToken(getLUMUSDAddress()));
                if (1e18 > oraclePrice) {
                    uint delta;
                    uint rate;

                    (mErr, delta) = subUInt(1e18, oraclePrice);
                    require(mErr == MathError.NO_ERROR, "LUMUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = mulUInt(delta, floatRateMantissa);
                    require(mErr == MathError.NO_ERROR, "LUMUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = divUInt(delta, 1e18);
                    require(mErr == MathError.NO_ERROR, "LUMUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, rate) = addUInt(delta, baseRateMantissa);
                    require(mErr == MathError.NO_ERROR, "LUMUSD_REPAY_RATE_CALCULATION_FAILED");

                    return rate;
                } else {
                    return baseRateMantissa;
                }
            } else {
                return baseRateMantissa;
            }
        } else {
            return 0;
        }
    }

    function getLUMUSDRepayRatePerBlock() public view returns (uint) {
        uint yearlyRate = getLUMUSDRepayRate();

        MathError mErr;
        uint rate;

        (mErr, rate) = divUInt(yearlyRate, getBlocksPerYear());
        require(mErr == MathError.NO_ERROR, "LUMUSD_REPAY_RATE_CALCULATION_FAILED");

        return rate;
    }

    function getLUMUSDMinterInterestIndex(address minter) public view returns (uint) {
        uint storedIndex = lumUsdMinterInterestIndex[minter];
        // If the user minted LUMUSD before the stability fee was introduced, accrue
        // starting from stability fee launch
        if (storedIndex == 0) {
            return INITIAL_LUMUSD_MINT_INDEX;
        }
        return storedIndex;
    }

    /**
     * @notice Get the current total LUMUSD a user needs to repay
     * @param account The address of the LUMUSD borrower
     * @return (uint) The total amount of LUMUSD the user needs to repay
     */
    function getLUMUSDRepayAmount(address account) public view returns (uint) {
        MathError mErr;
        uint delta;

        uint amount = comptroller.mintedLUMUSDs(account);
        uint interest = pastLUMUSDInterest[account];
        uint totalMintedLUMUSD;
        uint newInterest;

        (mErr, totalMintedLUMUSD) = subUInt(amount, interest);
        require(mErr == MathError.NO_ERROR, "LUMUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, delta) = subUInt(lumUsdMintIndex, getLUMUSDMinterInterestIndex(account));
        require(mErr == MathError.NO_ERROR, "LUMUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = mulUInt(delta, totalMintedLUMUSD);
        require(mErr == MathError.NO_ERROR, "LUMUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = divUInt(newInterest, 1e18);
        require(mErr == MathError.NO_ERROR, "LUMUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, amount) = addUInt(amount, newInterest);
        require(mErr == MathError.NO_ERROR, "LUMUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        return amount;
    }

    /**
     * @notice Calculate how much LUMUSD the user needs to repay
     * @param borrower The address of the LUMUSD borrower
     * @param repayAmount The amount of LUMUSD being returned
     * @return (uint, uint, uint) Amount of LUMUSD to be burned, amount of LUMUSD the user needs to pay in current interest and amount of LUMUSD the user needs to pay in past interest
     */
    function getLUMUSDCalculateRepayAmount(address borrower, uint256 repayAmount) public view returns (uint, uint, uint) {
        MathError mErr;
        uint256 totalRepayAmount = getLUMUSDRepayAmount(borrower);
        uint currentInterest;

        (mErr, currentInterest) = subUInt(totalRepayAmount, comptroller.mintedLUMUSDs(borrower));
        require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, currentInterest) = addUInt(pastLUMUSDInterest[borrower], currentInterest);
        require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

        uint burn;
        uint partOfCurrentInterest = currentInterest;
        uint partOfPastInterest = pastLUMUSDInterest[borrower];

        if (repayAmount >= totalRepayAmount) {
            (mErr, burn) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");
        } else {
            uint delta;

            (mErr, delta) = mulUInt(repayAmount, 1e18);
            require(mErr == MathError.NO_ERROR, "LUMUSD_PART_CALCULATION_FAILED");

            (mErr, delta) = divUInt(delta, totalRepayAmount);
            require(mErr == MathError.NO_ERROR, "LUMUSD_PART_CALCULATION_FAILED");

            uint totalMintedAmount;
            (mErr, totalMintedAmount) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "LUMUSD_MINTED_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = mulUInt(totalMintedAmount, delta);
            require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = divUInt(burn, 1e18);
            require(mErr == MathError.NO_ERROR, "LUMUSD_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = mulUInt(currentInterest, delta);
            require(mErr == MathError.NO_ERROR, "LUMUSD_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = divUInt(partOfCurrentInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "LUMUSD_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = mulUInt(pastLUMUSDInterest[borrower], delta);
            require(mErr == MathError.NO_ERROR, "LUMUSD_PAST_INTEREST_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = divUInt(partOfPastInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "LUMUSD_PAST_INTEREST_CALCULATION_FAILED");
        }

        return (burn, partOfCurrentInterest, partOfPastInterest);
    }

    function accrueLUMUSDInterest() public {
        MathError mErr;
        uint delta;

        (mErr, delta) = mulUInt(getLUMUSDRepayRatePerBlock(), getBlockNumber() - accrualBlockNumber);
        require(mErr == MathError.NO_ERROR, "LUMUSD_INTEREST_ACCURE_FAILED");

        (mErr, delta) = addUInt(delta, lumUsdMintIndex);
        require(mErr == MathError.NO_ERROR, "LUMUSD_INTEREST_ACCURE_FAILED");

        lumUsdMintIndex = delta;
        accrualBlockNumber = getBlockNumber();
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _ensureNonzeroAddress(newAccessControlAddress);

        address oldAccessControlAddress = accessControl;
        accessControl = newAccessControlAddress;
        emit NewAccessControl(oldAccessControlAddress, accessControl);
    }

    /**
     * @notice Set LUMUSD borrow base rate
     * @param newBaseRateMantissa the base rate multiplied by 10**18
     */
    function setBaseRate(uint newBaseRateMantissa) external {
        _ensureAllowed("setBaseRate(uint256)");

        uint old = baseRateMantissa;
        baseRateMantissa = newBaseRateMantissa;
        emit NewLUMUSDBaseRate(old, baseRateMantissa);
    }

    /**
     * @notice Set LUMUSD borrow float rate
     * @param newFloatRateMantissa the LUMUSD float rate multiplied by 10**18
     */
    function setFloatRate(uint newFloatRateMantissa) external {
        _ensureAllowed("setFloatRate(uint256)");

        uint old = floatRateMantissa;
        floatRateMantissa = newFloatRateMantissa;
        emit NewLUMUSDFloatRate(old, floatRateMantissa);
    }

    /**
     * @notice Set LUMUSD stability fee receiver address
     * @param newReceiver the address of the LUMUSD fee receiver
     */
    function setReceiver(address newReceiver) external onlyAdmin {
        require(newReceiver != address(0), "invalid receiver address");

        address old = receiver;
        receiver = newReceiver;
        emit NewLUMUSDReceiver(old, newReceiver);
    }

    /**
     * @notice Set LUMUSD mint cap
     * @param _mintCap the amount of LUMUSD that can be minted
     */
    function setMintCap(uint _mintCap) external {
        _ensureAllowed("setMintCap(uint256)");

        uint old = mintCap;
        mintCap = _mintCap;
        emit NewLUMUSDMintCap(old, _mintCap);
    }

    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    function getBlocksPerYear() public view returns (uint) {
        return 10512000; //(24 * 60 * 60 * 365) / 3;
    }

    /**
     * @notice Return the address of the LUMUSD token
     * @return The address of LUMUSD
     */
    function getLUMUSDAddress() public view returns (address) {
        return 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    function _ensureAllowed(string memory functionSig) private view {
        require(IAccessControlManager(accessControl).isAllowedToCall(msg.sender, functionSig), "access denied");
    }

    /// @notice Reverts if the passed address is zero
    function _ensureNonzeroAddress(address someone) private pure {
        require(someone != address(0), "can't be zero address");
    }
}
