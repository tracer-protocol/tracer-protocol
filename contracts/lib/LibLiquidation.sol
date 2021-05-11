// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./LibMath.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

library LibLiquidation {
    using LibMath for uint256;
    using LibMath for int256;
    using PRBMathUD60x18 for uint256;

    uint256 private constant PERCENT_PRECISION = 10000;

    struct LiquidationReceipt {
        address tracer;
        address liquidator;
        address liquidatee;
        uint256 price;
        uint256 time;
        uint256 escrowedAmount;
        uint256 releaseTime;
        int256 amountLiquidated;
        bool escrowClaimed;
        bool liquidationSide;
        bool liquidatorRefundClaimed;
    }

    function calcEscrowLiquidationAmount(
        uint256 minMargin,
        int256 currentMargin
    ) internal pure returns (uint256) {
        int256 amountToEscrow =
            currentMargin - (minMargin.toInt256() - currentMargin);
        if (amountToEscrow < 0) {
            return 0;
        }
        return uint256(amountToEscrow);
    }

    /**
     * @notice Calculates the updated quote and base of the trader and liquidator on a liquidation event.
     * @param liquidatedQuote The quote of the account being liquidated
     * @param liquidatedBase The base of the account being liquidated
     * @param amount The amount that is to be liquidated from the position
     */
    function liquidationBalanceChanges(
        int256 liquidatedQuote,
        int256 liquidatedBase,
        int256 amount
    )
        public
        pure
        returns (
            int256 _liquidatorQuoteChange,
            int256 _liquidatorBaseChange,
            int256 _liquidateeQuoteChange,
            int256 _liquidateeBaseChange
        )
    {
        int256 liquidatorQuoteChange;
        int256 liquidatorBaseChange;
        int256 liquidateeQuoteChange;
        int256 liquidateeBaseChange;

        // The amount of quote to liquidate, given the supplied amount of base being liquidated
        // quote * (amount / base)
        // todo CASTING CHECK
        int256 portionOfQuote =
            ((liquidatedQuote *
                ((amount * PERCENT_PRECISION.toInt256()) /
                    liquidatedBase.abs())) / PERCENT_PRECISION.toInt256());

        liquidatorQuoteChange = portionOfQuote;
        liquidateeQuoteChange = portionOfQuote * (-1);

        liquidatorBaseChange = amount;
        liquidateeBaseChange = amount * (-1);

        return (
            liquidatorQuoteChange,
            liquidatorBaseChange,
            liquidateeQuoteChange,
            liquidateeBaseChange
        );
    }

    /**
     * @notice Calculates the amount of slippage experienced compared to value of position in a receipt
     * @param unitsSold Amount of quote units sold in the orders
     * @param maxSlippage The upper bound for slippage
     * @param avgPrice The average price of units sold in orders
     * @param receipt The receipt for the state during liquidation
     */
    function calculateSlippage(
        uint256 unitsSold,
        uint256 maxSlippage,
        uint256 avgPrice,
        LiquidationReceipt memory receipt
    ) internal pure returns (uint256) {
        // Check price slippage and update account states
        if (
            avgPrice == receipt.price || // No price change
            (avgPrice < receipt.price && !receipt.liquidationSide) || // Price dropped, but position is short
            (avgPrice > receipt.price && receipt.liquidationSide) // Price jumped, but position is long
        ) {
            // No slippage
            return 0;
        } else {
            // Liquidator took a long position, and price dropped
            uint256 amountSoldFor = PRBMathUD60x18.mul(avgPrice, unitsSold);
            uint256 amountExpectedFor =
                PRBMathUD60x18.mul(receipt.price, unitsSold);

            // The difference in how much was expected vs how much liquidator actually got.
            // i.e. The amount lost by liquidator
            uint256 amountToReturn = 0;
            uint256 percentSlippage = 0;
            if (avgPrice < receipt.price && receipt.liquidationSide) {
                amountToReturn = uint256(amountExpectedFor - amountSoldFor);
                if (amountToReturn <= 0) {
                    return 0;
                }
                percentSlippage =
                    (amountToReturn * PERCENT_PRECISION) /
                    amountExpectedFor;
            } else if (avgPrice > receipt.price && !receipt.liquidationSide) {
                amountToReturn = uint256(amountSoldFor - amountExpectedFor);
                if (amountToReturn <= 0) {
                    return 0;
                }
                percentSlippage =
                    (amountToReturn * PERCENT_PRECISION) /
                    amountExpectedFor;
            }
            if (percentSlippage > maxSlippage) {
                amountToReturn = uint256(
                    (maxSlippage * amountExpectedFor) / PERCENT_PRECISION
                );
            }
            return amountToReturn;
        }
    }
}
