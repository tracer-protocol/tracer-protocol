// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./lib/LibMath.sol";
import "./Interfaces/IPricing.sol";
import "./Interfaces/ITracerPerpetualSwaps.sol";
import "./Interfaces/IInsurance.sol";
import "./Interfaces/IOracle.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

contract Pricing is IPricing {
    using LibMath for uint256;
    using LibMath for int256;
    using PRBMathSD59x18 for int256;

    address public immutable tracer;
    IInsurance public immutable insurance;
    IOracle public immutable oracle;

    // pricing metrics
    Prices.PriceInstant[24] internal hourlyTracerPrices;
    Prices.PriceInstant[24] internal hourlyOraclePrices;

    // funding index => funding rate
    mapping(uint256 => Prices.FundingRateInstant) public fundingRates;

    // funding index => insurance funding rate
    mapping(uint256 => Prices.FundingRateInstant) public insuranceFundingRates;

    // variables used to track time value
    int256 public override timeValue;
    mapping(uint256 => int256) public dailyDifferences;
    uint256 internal lastUpdatedDay;

    // the last established funding index
    uint256 public override lastUpdatedFundingIndex;

    // timing variables
    uint256 public startLastHour;
    uint256 public startLast24Hours;
    uint8 public override currentHour;

    // The funding rate is supposed to be 8-hourly, but because it's paid hourly
    // in the contracts, we offset the calculated rate by a factor of 8
    int256 private constant FUNDING_RATE_OFFSET = 8;

    event HourlyPriceUpdated(uint256 price, uint256 currentHour);
    event FundingRateUpdated(int256 fundingRate, int256 cumulativeFundingRate);
    event InsuranceFundingRateUpdated(int256 insuranceFundingRate, int256 insuranceFundingRateValue);

    /**
     * @dev Set tracer perps factory
     * @dev ensure that oracle contract is returning WAD values. This may be done
     *      by wrapping the raw oracle in an adapter (see contracts/oracle)
     * @param _tracer The address of the tracer this pricing contract links too
     */
    constructor(
        address _tracer,
        address _insurance,
        address _oracle
    ) {
        require(_tracer != address(0), "PRC: _tracer = address(0)");
        require(_insurance != address(0), "PRC: _insurance = address(0)");
        require(_oracle != address(0), "PRC: _oracle = address(0)");
        tracer = _tracer;
        insurance = IInsurance(_insurance);
        oracle = IOracle(_oracle);
        startLastHour = block.timestamp;
        startLast24Hours = block.timestamp;
        lastUpdatedDay = 90;
    }

    /**
     * @notice Updates pricing information given a trade of a certain volume at
     *         a set price
     * @param tradePrice The price the trade executed at
     * @param fillAmount The amount the trade was filled for
     */
    function recordTrade(uint256 tradePrice, uint256 fillAmount) external override onlyTracer {
        uint256 currentOraclePrice = oracle.latestAnswer();
        // Update pricing information if a trade has not been recorded in the last hour
        if (startLastHour <= block.timestamp - 1 hours) {
            // If 24 hours has passed, update the time value before entering new pricing info
            if (startLast24Hours <= block.timestamp - 24 hours) {
                // Update the interest rate every 24 hours
                uint256 elapsedDays = (block.timestamp - startLast24Hours) / (24 hours);
                updateTimeValue(elapsedDays);
                startLast24Hours += elapsedDays;
                lastUpdatedDay += elapsedDays;
            }

            // Get the last recorded hourly price, returns max integer if no trades occurred
            uint256 hourlyTracerPrice = getHourlyAvgTracerPrice(currentHour);

            // Emit the hourly average and udpate funding rate if trades occurred
            if (hourlyTracerPrice != type(uint256).max) {
                // Emit the old hourly average
                emit HourlyPriceUpdated(hourlyTracerPrice, currentHour);

                // Update funding rate for the previous hour
                updateFundingRate();
            }

            uint256 elapsedHours = (block.timestamp - startLastHour) / 3600;

            // Update the current hour and enter the new price
            currentHour = uint8((uint256(currentHour) + elapsedHours) % 24);
            createPriceEntry(tradePrice, currentOraclePrice, fillAmount, currentHour);

            // If more than one hour passed, update any skipped hour prices as 0 to remove stale entries
            if (elapsedHours > 1) {
                // Calculate the number of hours to overwrite
                // Cap elapsed hours to 24 hours to limit for loop iterations
                // Subtract 1 since the last elapsed hour is the recorded trade with data
                uint8 skippedHours = uint8(elapsedHours > 24 ? 24 : elapsedHours) - 1;

                uint8 staleHour = currentHour;
                for (uint256 i = 0; i < skippedHours; i++) {
                    // Decrement stale hour backwards from current time to update skipped entries
                    if (staleHour > 0) {
                        staleHour--;
                    } else {
                        staleHour = 23;
                    }
                    createPriceEntry(0, 0, 0, staleHour);
                }
            }

            // Update time of last hourly recording
            startLastHour += (elapsedHours * 3600);
        } else {
            updateCurrentPriceEntry(tradePrice, currentOraclePrice, fillAmount);
        }
    }

    /**
     * @notice Records the market price and the underlying asset price (from an oracle) for a given tracer market given a tracer price
     *         and an oracle price at a given hour
     * @param marketPrice The price that a tracer was bought at, returned by the TracerPerpetualSwaps.sol contract when an order is filled
     * @param oraclePrice The price of the underlying asset that the Tracer is based upon as returned by a Chainlink Oracle
     * @param fillAmount The amount of the order that was filled at some price
     * @param hour The hour to overwrite in the hourly Oracle and Tracer price arrays
     */
    function createPriceEntry(
        uint256 marketPrice,
        uint256 oraclePrice,
        uint256 fillAmount,
        uint8 hour
    ) internal {
        // Make new hourly record, total = marketPrice, numTrades set to the amount filled;
        Prices.PriceInstant memory newHourly = Prices.PriceInstant(
            PRBMathUD60x18.mul(marketPrice, fillAmount),
            fillAmount
        );
        hourlyTracerPrices[hour] = newHourly;
        // As above but with Oracle price
        Prices.PriceInstant memory oracleHour = Prices.PriceInstant(
            PRBMathUD60x18.mul(oraclePrice, fillAmount),
            fillAmount
        );
        hourlyOraclePrices[hour] = oracleHour;
    }

    /**
     * @notice Cumulatively adds a new Tracer and asset price to the existing prices recorded at the current hour
     * @param marketPrice The price that a tracer was bought at, returned by the TracerPerpetualSwaps.sol contract when an order is filled
     * @param oraclePrice The price of the underlying asset that the Tracer is based upon as returned by a Chainlink Oracle
     * @param fillAmount The amount of the order that was filled at some price
     */
    function updateCurrentPriceEntry(
        uint256 marketPrice,
        uint256 oraclePrice,
        uint256 fillAmount
    ) internal {
        // Add the total market price of the trade to a running total
        // and increment number of fill amounts
        hourlyTracerPrices[currentHour].cumulativePrice =
            hourlyTracerPrices[currentHour].cumulativePrice +
            PRBMathUD60x18.mul(marketPrice, fillAmount);
        hourlyTracerPrices[currentHour].trades = hourlyTracerPrices[currentHour].trades + fillAmount;
        // As above but with oracle price
        hourlyOraclePrices[currentHour].cumulativePrice =
            hourlyOraclePrices[currentHour].cumulativePrice +
            PRBMathUD60x18.mul(oraclePrice, fillAmount);
        hourlyOraclePrices[currentHour].trades = hourlyOraclePrices[currentHour].trades + fillAmount;
    }

    /**
     * @notice Updates the funding rate and the insurance funding rate
     */
    function updateFundingRate() internal {
        // Get 8 hour time-weighted-average price (TWAP) and calculate the new funding rate and store it a new variable
        ITracerPerpetualSwaps _tracer = ITracerPerpetualSwaps(tracer);
        Prices.TWAP memory twapPrices = getTWAPs(currentHour);
        int256 iPoolFundingRate = insurance.getPoolFundingRate().toInt256();
        uint256 underlyingTWAP = twapPrices.underlying;
        uint256 derivativeTWAP = twapPrices.derivative;

        int256 fundingRate = PRBMathSD59x18.mul(
            derivativeTWAP.toInt256() - underlyingTWAP.toInt256() - timeValue,
            _tracer.fundingRateSensitivity().toInt256()
        ) / FUNDING_RATE_OFFSET;

        // Create variable with value of old & new cumulative funding rate values
        int256 oldCumulativeFundingRate = fundingRates[lastUpdatedFundingIndex].cumulativeFundingRate;
        int256 newCumulativeFundingRate = oldCumulativeFundingRate + fundingRate;

        // as above but with the cumulative insurance funding rates
        int256 oldCumulativeIPoolFundingRate = insuranceFundingRates[lastUpdatedFundingIndex].cumulativeFundingRate;
        int256 newCumulativeIPoolFundingRate = oldCumulativeIPoolFundingRate + iPoolFundingRate;

        // Call setter functions on calculated variables
        setFundingRate(fundingRate, newCumulativeFundingRate);
        emit FundingRateUpdated(fundingRate, newCumulativeFundingRate);

        setInsuranceFundingRate(iPoolFundingRate, newCumulativeIPoolFundingRate);
        emit InsuranceFundingRateUpdated(iPoolFundingRate, newCumulativeIPoolFundingRate);

        // increment funding index
        lastUpdatedFundingIndex = lastUpdatedFundingIndex + 1;
    }

    /**
     * @notice Given the address of a tracer market this function will get the current fair price for that market
     */
    function fairPrice() external view override returns (uint256) {
        return Prices.fairPrice(oracle.latestAnswer(), timeValue);
    }

    /**
     * @notice Calculates and then updates the time value for a tracer market
     * @param elapsedDays number of days elapsed since last udpate to time value
     */
    function updateTimeValue(uint256 elapsedDays) internal {
        (uint256 avgPrice, uint256 oracleAvgPrice) = get24HourPrices();
        // get 24 hours returns max integer if no trades occurred
        // don't update in this case
        if (avgPrice != type(uint256).max) {
            int256 lastDailyDifference = Prices.timeValue(avgPrice, oracleAvgPrice);
            timeValue += lastDailyDifference;
            uint256 latestDay = lastUpdatedDay + elapsedDays;
            for (uint256 currentDay = lastUpdatedDay + 1; currentDay <= latestDay; currentDay++) {
                // add a new difference entry
                int256 dailyDifference = (currentDay == latestDay) ? lastDailyDifference : int256(0);
                dailyDifferences[currentDay] = dailyDifference;
                // remove the difference entry 90 days ago
                uint256 ninetyDaysAgo = currentDay - 90;
                timeValue -= dailyDifferences[ninetyDaysAgo];
            }
        }
    }

    ////////////////////////////
    ///  SETTER FUNCTIONS   ///
    //////////////////////////

    /**
     * @notice Sets the values of the fundingRate struct
     * @param fundingRate The funding Rate of the Tracer, calculated by updateFundingRate
     * @param cumulativeFundingRate The cumulativeFundingRate, incremented each time the funding rate is updated
     */
    function setFundingRate(int256 fundingRate, int256 cumulativeFundingRate) internal {
        fundingRates[lastUpdatedFundingIndex + 1] = Prices.FundingRateInstant(
            block.timestamp,
            fundingRate,
            cumulativeFundingRate
        );
    }

    /**
     * @notice Sets the values of the fundingRate struct for a particular Tracer Marker
     * @param fundingRate The insurance funding Rate of the Tracer, calculated by updateFundingRate
     * @param cumulativeFundingRate The cumulativeFundingRate, incremented each time the funding rate is updated
     */
    function setInsuranceFundingRate(int256 fundingRate, int256 cumulativeFundingRate) internal {
        insuranceFundingRates[lastUpdatedFundingIndex + 1] = Prices.FundingRateInstant(
            block.timestamp,
            fundingRate,
            cumulativeFundingRate
        );
    }

    /**
     * @return each variable of the fundingRate struct of a particular tracer at a particular funding rate index
     */
    function getFundingRate(uint256 index) external view override returns (Prices.FundingRateInstant memory) {
        return fundingRates[index];
    }

    /**
     * @return all of the variables in the funding rate struct (insurance rate) from a particular tracer market
     */
    function getInsuranceFundingRate(uint256 index) external view override returns (Prices.FundingRateInstant memory) {
        return insuranceFundingRates[index];
    }

    /**
     * @notice Gets an 8 hour time weighted avg price for a given tracer, at a particular hour. More recent prices are weighted more heavily.
     * @param hour An integer representing what hour of the day to collect from (0-24)
     * @return the time weighted average price for both the oraclePrice (derivative price) and the Tracer Price
     */
    function getTWAPs(uint256 hour) public view override returns (Prices.TWAP memory) {
        return Prices.calculateTWAP(hour, hourlyTracerPrices, hourlyOraclePrices);
    }

    /**
     * @notice Gets a 24 hour tracer and oracle price for a given tracer market
     * @notice Returns max integer (uint256) if there were no trades in the 24 hour period
     * @return the average price over a 24 hour period for oracle and Tracer price
     */
    function get24HourPrices() public view override returns (uint256, uint256) {
        return (Prices.averagePriceForPeriod(hourlyTracerPrices), Prices.averagePriceForPeriod(hourlyOraclePrices));
    }

    /**
     * @notice Gets the average tracer price for a given market during a certain hour
     * @notice Returns max integer (uint256) if there were no trades in the hour
     * @param hour The hour of which you want the hourly average Price
     * @return the average price of the tracer for a particular hour
     */
    function getHourlyAvgTracerPrice(uint256 hour) public view override returns (uint256) {
        return Prices.averagePrice(hourlyTracerPrices[hour]);
    }

    /**
     * @notice Gets the average oracle price for a given market during a certain hour
     * @notice Returns max integer (uint256) if there were no trades in the hour
     * @param hour The hour of which you want the hourly average Price
     */
    function getHourlyAvgOraclePrice(uint256 hour) external view override returns (uint256) {
        return Prices.averagePrice(hourlyOraclePrices[hour]);
    }

    /**
     * @dev Used when only valid tracers are allowed
     */
    modifier onlyTracer() {
        require(msg.sender == tracer, "PRC: Only Tracer");
        _;
    }
}
