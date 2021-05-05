// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./lib/LibMath.sol";
import "./lib/LibLiquidation.sol";
import "./lib/LibBalances.sol";
import "./Interfaces/ILiquidation.sol";
import "./Interfaces/IAccount.sol";
import "./Interfaces/ITrader.sol";
import "./Interfaces/ITracerPerpetualSwaps.sol";
import "./Interfaces/ITracerPerpetualsFactory.sol";
import "./Interfaces/IOracle.sol";
import "./Interfaces/IPricing.sol";

/**
* Each call enforces that the contract calling the account is only updating the balance
* of the account for that contract.
*/
contract Liquidation is ILiquidation, Ownable {
    using LibMath for uint256;
    using LibMath for int256;

    uint256 public override currentLiquidationId;
    int256 public override maxSlippage;
    uint256 releaseTime = 15 minutes;
    IPricing public pricing;
    ITracerPerpetualsFactory public perpsFactory;
    ITracerPerpetualSwaps public tracer;

    // Receipt ID => LiquidationReceipt
    mapping(uint256 => LibLiquidation.LiquidationReceipt) internal liquidationReceipts;
    // Factor to keep precision in percent calculations
    int256 private constant PERCENT_PRECISION = 10000;

    event ClaimedReceipts(address indexed liquidator, address indexed market, uint256[] ids);
    event ClaimedEscrow(address indexed liquidatee, address indexed market, uint256 id);
    event Liquidate(address indexed account, address indexed liquidator, int256 liquidationAmount, bool side, address indexed market, uint liquidationId);
    event InvalidClaimOrder(uint256 receiptId, address indexed liquidator);

    // On contract deployment set the account contract. 
    constructor(
        address _pricing,
        address _tracer,
        address _perpsFactory,
        int256 _maxSlippage,
        address gov
    ) {
        pricing = IPricing(_pricing);
        perpsFactory = ITracerPerpetualsFactory(_perpsFactory);
        tracer = ITracerPerpetualSwaps(_tracer);
        maxSlippage = _maxSlippage;
        transferOwnership(gov);
    }


    /**
     * @notice Creates a liquidation receipt for a given trader
     * @param market the Tracer that this receipt belongs too
     * @param liquidator the account executing the liquidation
     * @param liquidatee the account being liquidated
     * @param price the price at which this liquidation event occurred 
     * @param escrowedAmount the amount of funds required to be locked into escrow 
     *                       by the liquidator
     * @param amountLiquidated the amount of positions that were liquidated
     * @param liquidationSide the side of the positions being liquidated. true for long
     *                        false for short.
     */
    function submitLiquidation(
        address market,
        address liquidator,
        address liquidatee,
        int256 price,
        uint256 escrowedAmount,
        int256 amountLiquidated,
        bool liquidationSide
    ) public override onlyTracer {
        liquidationReceipts[currentLiquidationId] = LibLiquidation.LiquidationReceipt(
            market,
            liquidator,
            liquidatee,
            price,
            block.timestamp,
            escrowedAmount,
            block.timestamp + releaseTime,
            amountLiquidated,
            false,
            liquidationSide,
            false
        );
        currentLiquidationId += 1;
    }

    /**
     * @notice Marks receipts as claimed and returns the refund amount
     * @param escrowId the id of the receipt created during the liquidation event
     * @param orders the orders that sell the liquidated positions
     * @param market the address of the tracer contract the liquidation occurred on
     * @param traderContract the address of the trader contract the selling orders were made by
     * @param liquidator the account who executed the liquidation
     */
    function claimReceipts(
        uint256 escrowId,
        Types.Order[] memory orders,
        uint256 priceMultiplier,
        address market,
        address traderContract,
        address liquidator
    ) external override onlyTracer returns (uint256) {
        LibLiquidation.LiquidationReceipt memory receipt = liquidationReceipts[escrowId];
        require(receipt.liquidator == liquidator, "LIQ: Liquidator mismatch");
        require(block.timestamp < receipt.releaseTime, "LIQ: claim time passed");
        require(!receipt.liquidatorRefundClaimed, "LIQ: Already claimed");
        // Validate the escrowed order was fully sold
        // TODO fix calcUnitsSold
        (uint256 unitsSold, int256 avgPrice) = calcUnitsSold(orders, traderContract, escrowId);
        require(
            unitsSold == uint256(receipt.amountLiquidated.abs()),
            "LIQ: Unit mismatch"
        );

        require(
            ITracerPerpetualSwaps(market).tradingWhitelist(traderContract),
            "LIQ: Trader is not whitelisted"
        );

        // Mark refund as claimed
        liquidationReceipts[escrowId].liquidatorRefundClaimed = true;

        uint256 amountToReturn =
            LibLiquidation.calculateSlippage(
                unitsSold,
                escrowId,
                priceMultiplier,
                maxSlippage,
                avgPrice,
                receipt
            );

        if (amountToReturn > receipt.escrowedAmount) {
            liquidationReceipts[escrowId].escrowedAmount = 0;
        } else {
            liquidationReceipts[escrowId].escrowedAmount = receipt.escrowedAmount - amountToReturn;
        }
        return amountToReturn;
    }

    /**
     * @notice Used to claim funds owed to you through your receipt. 
     * @dev Marks escrowed funds as claimed and returns amount to return
     * @param receiptID the id of the receipt from which escrow is being claimed from
     * @param liquidatee The address of the account that is getting liquidated (the liquidatee)
     */
    function claimEscrow(uint256 receiptID, address liquidatee) public override onlyTracer returns (int256) {
        LibLiquidation.LiquidationReceipt memory receipt = liquidationReceipts[receiptID];
        require(receipt.liquidatee == liquidatee, "LIQ: Liquidatee mismatch");
        require(!receipt.escrowClaimed, "LIQ: Escrow claimed");
        require(block.timestamp > receipt.releaseTime, "LIQ: Not released");
        liquidationReceipts[receiptID].escrowClaimed = true;
        return (receipt.escrowedAmount.toInt256());
    }
    

    /**
     * @notice Calculates the number of units sold and the average price of those units by a trader
     *         given multiple order
     * @param orders a list of orders for which the units sold is being calculated from
     * @param traderContract The trader contract with which the orders were made
     * @param receiptId the id of the liquidation receipt the orders are being claimed against
    */
    function calcUnitsSold(
        Types.Order[] memory orders,
        address traderContract,
        uint256 receiptId
    ) public override returns (uint256, int256) {
        LibLiquidation.LiquidationReceipt memory receipt = liquidationReceipts[receiptId];
        uint256 unitsSold;
        int256 avgPrice;
        for (uint256 i; i < orders.length; i++) {
            Types.Order memory order = ITrader(traderContract).getOrder(orders[i]);
            if (
                order.creation < receipt.time // Order made before receipt
                || order.maker != receipt.liquidator // Order made by someone who isn't liquidator
                || order.side == receipt.liquidationSide // Order is in same direction as liquidation
                /* Order should be the opposite to the position acquired on liquidation */
            ) {
                emit InvalidClaimOrder(receiptId, receipt.liquidator);
                continue;
            }

            /* order.creation >= receipt.time
             * && order.maker == receipt.liquidator
             * && order.side != receipt.liquidationSide */
            unitsSold = unitsSold + order.filled;
            avgPrice = avgPrice + (order.price * order.filled.toInt256());
        }

        // Avoid divide by 0 if no orders sold
        if (unitsSold == 0) {
            return (0, 0);
        }
        return (unitsSold, avgPrice / unitsSold.toInt256());
    }

    /**
     * @notice Returns liquidation receipt data for a given receipt id.
     * @param id the receipt id to get data for
    */
    function getLiquidationReceipt(uint256 id)
        external
        override
        view
        returns (
            address,
            address,
            address,
            int256,
            uint256,
            uint256,
            uint256,
            int256,
            bool,
            bool,
            bool
        )
    {
        LibLiquidation.LiquidationReceipt memory _receipt = liquidationReceipts[id];
        return (
            _receipt.tracer,
            _receipt.liquidator,
            _receipt.liquidatee,
            _receipt.price,
            _receipt.time,
            _receipt.escrowedAmount,
            _receipt.releaseTime,
            _receipt.amountLiquidated,
            _receipt.escrowClaimed,
            _receipt.liquidationSide,
            _receipt.liquidatorRefundClaimed
        );
    }


    function verifyAndSubmitLiquidation(
        int256 quote,
        int256 price,
        int256 base,
        int256 amount,
        uint256 priceMultiplier,
        int256 gasPrice,
        address account,
        address market
    ) internal returns (uint256) {
        int256 gasCost = gasPrice * tracer.LIQUIDATION_GAS_COST().toInt256();
        int256 minMargin =
            Balances.calcMinMargin(quote, price, base, gasCost, tracer.maxLeverage(), priceMultiplier);

        require(
            Balances.calcMargin(quote, price, base, priceMultiplier) < minMargin,
            "LIQ: Account above margin"
        );
        require(amount <= quote.abs(), "LIQ: Liquidate Amount > Position");

        // calc funds to liquidate and move to Escrow
        uint256 amountToEscrow = LibLiquidation.calcEscrowLiquidationAmount(
            minMargin,
            Balances.calcMargin(quote, price, base, priceMultiplier)
        );

        // create a liquidation receipt
        bool side = quote < 0 ? false : true;
        submitLiquidation(
            market,
            msg.sender,
            account,
            price,
            amountToEscrow,
            amount,
            side
        );
        return amountToEscrow;
        return 0;
    }

    function calcLiquidationBalanceChanges(
        int256 liquidatedBase, int256 liquidatedQuote, address liquidator, int256 amount, address market
    ) internal view returns (
            int256 liquidatorBaseChange,
            int256 liquidatorQuoteChange,
            int256 liquidateeBaseChange,
            int256 liquidateeQuoteChange
    ) {

        /* Liquidator's balance */
        Types.AccountBalance memory liquidatorBalance = tracer.getBalance(liquidator);
        
        // Calculates what the updated state of both accounts will be if the liquidation is fully processed
        return LibLiquidation.liquidationBalanceChanges(liquidatedBase, liquidatedQuote, liquidatorBalance.quote, amount);
    }

    /**
     * @notice Liquidates the margin account of a particular user. A deposit is needed from the liquidator. 
     *         Generates a liquidation receipt for the liquidator to use should they need a refund.
     * @param amount The amount of tokens to be liquidated 
     * @param account The account that is to be liquidated. 
     * @param market The Tracer market in which this margin account will be liquidated.
     */
    function liquidate(
        int256 amount, 
        address account,
        address market
    ) external override isValidTracer(market) {
        require(amount > 0, "LIQ: Liquidation amount <= 0");

        /* Liquidated account's balance */
        Types.AccountBalance memory liquidatedBalance = tracer.getBalance(account);

        uint256 amountToEscrow = verifyAndSubmitLiquidation(
            liquidatedBalance.quote,
            pricing.fairPrice(),
            liquidatedBalance.base,
            amount,
            tracer.priceMultiplier(),
            liquidatedBalance.lastUpdatedGasPrice,
            account,
            market
        );
        
        // Limits the gas use when liquidating 
        require(
            tx.gasprice <= uint256(IOracle(ITracerPerpetualSwaps(market).gasPriceOracle()).latestAnswer().abs()),
            "LIQ: GasPrice > FGasPrice"
        );

        (
            int256 liquidatorBaseChange,
            int256 liquidatorQuoteChange,
            int256 liquidateeBaseChange,
            int256 liquidateeQuoteChange
        ) = calcLiquidationBalanceChanges(
            liquidatedBalance.base, liquidatedBalance.quote, msg.sender, amount, market
        );

        tracer.updateAccountsOnLiquidation(
            msg.sender,
            account,
            liquidatorBaseChange,
            liquidatorQuoteChange,
            liquidateeBaseChange,
            liquidateeQuoteChange,
            amountToEscrow
        );

        emit Liquidate(account, msg.sender, amount, (liquidatedBalance.quote < 0 ? false : true), market, currentLiquidationId - 1);
    }

    /**
     * @notice Allows a liquidator to submit a single liquidation receipt and multiple order ids. If the
     *         liquidator experienced slippage, will refund them a proportional amount of their deposit.
     * @param receiptID Used to identify the receipt that will be claimed
     * @param orderIds The IDs of the orders contained in the liquidation, these are emitted when an order is made
     * @param market The address of the tracer market where the liquidation and receipt originated
     */
    function claimReceipts(
        uint256 receiptID,
        uint256[] memory orderIds,
        address market
    ) public override {
        // Claim the receipts from the escrow system, get back amount to return
        /*
        (, address receiptLiquidator, address receiptLiquidatee, , , uint256 escrowedAmount, , , , ,) = receipt 
            .getLiquidationReceipt(receiptID);
        int256 liquidatorMargin = balances[market][receiptLiquidator].base;
        int256 liquidateeMargin = balances[market][receiptLiquidatee].base;
        ITracerPerpetualSwaps tracer = ITracerPerpetualSwaps(market);
        uint256 amountToReturn = receipt.claimReceipts(receiptID, orderIds, tracer.priceMultiplier(), market, msg.sender);

         */
        /* 
         * If there was not enough escrowed, we want to call the insurance pool to help out.
         * First, check the margin of the insurance Account. If this is enough, just drain from there.
         * If this is not enough, call Insurance.drainPool to get some tokens from the insurance pool.
         * If drainPool is able to drain enough, drain from the new margin.
         * If the margin still does not have enough after calling drainPool, we are not able to fully
         * claim the receipt, only up to the amount the insurance pool allows for.
         */
        /* 
        if (amountToReturn > escrowedAmount) { // Need to cover some loses with the insurance contract
            // Amount needed from insurance
            uint256 amountWantedFromInsurance = amountToReturn - escrowedAmount;
            // Keep track of how much was actually taken out of insurance
            uint256 amountTakenFromInsurance = 0;

            Types.AccountBalance storage insuranceBalance = balances[market][insuranceContract];
            if (insuranceBalance.base >= amountWantedFromInsurance.toInt256()) { // We don't need to drain insurance contract
                insuranceBalance.base = insuranceBalance.base - amountWantedFromInsurance.toInt256();
                amountTakenFromInsurance = amountWantedFromInsurance;
            } else { // insuranceBalance.base < amountWantedFromInsurance
                if (insuranceBalance.base <= 0) {
                    // attempt to drain entire balance that is needed from the pool
                    IInsurance(insuranceContract).drainPool(market, amountWantedFromInsurance);
                } else {
                    // attempt to drain the required balance taking into account the insurance balance in the account contract
                    IInsurance(insuranceContract).drainPool(market, amountWantedFromInsurance.sub(uint256(insuranceBalance.base)));
                }
                if (insuranceBalance.base < amountWantedFromInsurance.toInt256()) { // Still not enough
                    amountTakenFromInsurance = uint(insuranceBalance.base);
                    insuranceBalance.base = 0;
                } else { // insuranceBalance.base >= amountWantedFromInsurance
                    insuranceBalance.base = insuranceBalance.base - amountWantedFromInsurance.toInt256();
                    amountTakenFromInsurance = amountWantedFromInsurance;
                }
            }

            balances[market][receiptLiquidator].base =
                    liquidatorMargin.add((escrowedAmount.add(amountTakenFromInsurance).toInt256()));
            // Don't add any to liquidatee
        } else {
            balances[market][receiptLiquidator].base = liquidatorMargin.add(amountToReturn.toInt256());
            balances[market][receiptLiquidatee].base = liquidateeMargin.add(escrowedAmount.toInt256().sub(amountToReturn.toInt256()));
        }
        emit ClaimedReceipts(msg.sender, market, orderIds);
        */
    }

    /**
     * @notice Allows a trader to claim escrowed funds after the escrow period has expired
     * @param receiptId The ID number of the insurance receipt from which funds are being claimed from
     */
    function claimEscrow(uint256 receiptId) public override {
        // Get receipt
        /* TODO awaiting account + tracer merge
        (address receiptTracer, , address liquidatee , , , , uint256 releaseTime, ,bool escrowClaimed , ,) = receipt.getLiquidationReceipt(receiptId);
        require(liquidatee == msg.sender, "LIQ: Not Entitled");
        require(!escrowClaimed, "LIQ: Already claimed");
        require(block.timestamp > releaseTime, "LIQ: Not yet released");
        
        // Update balance and mark as claimed
        int256 accountMargin = balances[receiptTracer][msg.sender].base;
        int256 amountToReturn = receipt.claimEscrow(receiptId, liquidatee);
        balances[receiptTracer][msg.sender].base = accountMargin.add(amountToReturn);
        emit ClaimedEscrow(msg.sender, receiptTracer, receiptId);
        */
    }

    /**
     * @notice Modifies the release time
     * @param _releaseTime new release time
     */
    function setReleaseTime(uint256 _releaseTime) external onlyOwner() {
        releaseTime = _releaseTime;
    }

    function setMaxSlippage(int256 _maxSlippage) public override onlyOwner() {
        maxSlippage = _maxSlippage;
    }

    modifier onlyTracer() {
        require(msg.sender == address(tracer), "LIQ: Caller not Tracer market");
        _;
    }

    /**
     * @dev Checks if that passed address is a valid tracer address (i.e. is part of a perpsFactory)
     * @param market The Tracer market to check
     */
    modifier isValidTracer(address market) {
        require(perpsFactory.validTracers(market), "ACT: Target not valid tracer");
        _;
    }
}
