//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;
import "prb-math/contracts/PRBMathUD60x18.sol";

library LibInsurance {
    struct DelayedWithdrawal {
        bool executed;
        address account;
        uint256 id;
        uint256 creationTime;
        uint256 amount; // Pool tokens, In raw format (not WAD)
        uint256 collateralAmountAtTimeOfCommit; // So we know how much to take from pending
        uint256 previous;
        uint256 next;
    }

    /**
    * @notice calculates the amount of insurance pool tokens to mint
    * @dev wadAmount is the amount of quote tokens being provided, converted to WAD
           format.
    */
    function calcMintAmount(
        uint256 poolTokenSupply, // the total circulating supply of pool tokens
        uint256 poolTokenUnderlying, // the holding of the insurance pool in quote tokens
        uint256 wadAmount //the WAD amount of tokens being deposited
    ) internal pure returns (uint256) {
        if (poolTokenSupply == 0) {
            // Mint at 1:1 ratio if no users in the pool
            return wadAmount;
        } else if (poolTokenUnderlying == 0) {
            // avoid divide by 0
            return 0;
        } else {
            // Mint at the correct ratio =
            //          Pool tokens (the ones to be minted) / poolAmount (the collateral asset)
            // Note the difference between this and withdraw. Here we are calculating the amount of tokens
            // to mint, and `amount` is the amount to deposit.
            return PRBMathUD60x18.mul(PRBMathUD60x18.div(poolTokenSupply, poolTokenUnderlying), wadAmount);
        }
    }

    /**
     * @notice Given a WAD amount of insurance tokens, calculate how much
     *         of the underlying to return to the user.
     * @dev returns the underlying amount in WAD format. Ensure this is
     *      converted to raw token format before using transfer
     */
    function calcWithdrawAmount(
        uint256 poolTokenSupply, // the total circulating supply of pool tokens
        uint256 poolTokenUnderlying, // the holding of the insurance pool in quote tokens
        uint256 wadAmount //the WAD amount of tokens being withdrawn
    ) internal pure returns (uint256) {
        // avoid division by 0
        if (poolTokenSupply == 0) {
            return 0;
        }

        // (public collateral amount / pool token total supply) * pool token withdrawal amount
        return PRBMathUD60x18.mul(PRBMathUD60x18.div(poolTokenUnderlying, poolTokenSupply), wadAmount);
    }

    /**
     * @notice Calculate the immediate withdrawal fee a user must pay based on how much they want to withdraw,
     *         and how full the insurance pool is.
     * @dev fee = [(1- (Fund % of target after withdrawal))^2] * collateralWithdrawalAmount
     * @param target The insurance pool target
     * @param poolTokenUnderlying The holdings of the insurance pool collateral in quote tokens
     * @param pendingWithdrawals The total amount of withdrawals that are currently pending
     * @param collateralWithdrawalAmount the amount being withdrawn, in wad format
     */
    function calculateImmediateWithdrawalFee(
        uint256 target,
        uint256 poolTokenUnderlying,
        uint256 pendingWithdrawals,
        uint256 collateralWithdrawalAmount
    ) internal pure returns (uint256) {
        uint256 feeRate = immediateWithdrawalFeeRate(
            target,
            poolTokenUnderlying,
            pendingWithdrawals,
            collateralWithdrawalAmount
        );
        uint256 fee = PRBMathUD60x18.mul(feeRate, collateralWithdrawalAmount);
        return fee;
    }

    function immediateWithdrawalFeeRate(
        uint256 target,
        uint256 poolTokenUnderlying,
        uint256 pendingWithdrawals,
        uint256 collateralWithdrawalAmount
    ) internal pure returns (uint256) {
        uint256 oneInWad = 1 * (10**18);
        if (target == 0) {
            return 0;
        }
        uint256 percentLeftover = PRBMathUD60x18.div(
            poolTokenUnderlying - collateralWithdrawalAmount - pendingWithdrawals,
            target
        );
        if (percentLeftover > oneInWad) {
            return 0;
        }
        uint256 leftoverInverse = oneInWad - percentLeftover;
        uint256 feeRate = leftoverInverse**2 / oneInWad;

        return feeRate;
    }

    /**
     * @notice Calculate the delayed withdrawal fee a user must pay based on how much they want to withdraw,
     *         and how full the insurance pool is.
     * @dev fee = 0.2*(1-(Fund % of target after withdrawal))^2 * collateralWithdrawalAmount
     *          = 0.2 * immediate withdrawal fee
     * @param target The insurance pool target
     * @param poolTokenUnderlying The holdings of the insurance pool collateral in quote tokens
     * @param pendingWithdrawals The total amount of withdrawals that are currently pending
     * @param collateralWithdrawalAmount the amount being withdrawn, in wad format
     */
    function calculateDelayedWithdrawalFee(
        uint256 target,
        uint256 poolTokenUnderlying,
        uint256 pendingWithdrawals,
        uint256 collateralWithdrawalAmount
    ) internal pure returns (uint256) {
        uint256 fiveInWad = 5 * (10**18); // Divide by 5 is the same as multiplying by 0.2
        uint256 immediateWithdrawalFee = calculateImmediateWithdrawalFee(
            target,
            poolTokenUnderlying,
            pendingWithdrawals,
            collateralWithdrawalAmount
        );
        uint256 fee = PRBMathUD60x18.div(immediateWithdrawalFee, fiveInWad);
        return fee;
    }
}
