// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./Interfaces/ITracerPerpetualSwaps.sol";
import "./Interfaces/IInsurance.sol";
import "./InsurancePoolToken.sol";
import "./lib/LibMath.sol";
import {Balances} from "./lib/LibBalances.sol";
import "./lib/LibInsurance.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "solidity-linked-list/contracts/StructuredLinkedList.sol";

contract Insurance is IInsurance {
    using LibMath for uint256;
    using LibMath for int256;
    using StructuredLinkedList for StructuredLinkedList.List;

    address public immutable collateralAsset; // Address of collateral asset
    uint256 public override publicCollateralAmount; // amount of underlying collateral in public pool, in WAD format
    uint256 public override bufferCollateralAmount; // amount of collateral in buffer pool, in WAD format
    address public immutable token; // token representation of a users holding in the pool

    uint256 private constant ONE_TOKEN = 1e18; // Constant for 10**18, i.e. one token in WAD format; used for drainPool

    // The insurance pool funding rate calculation can be refactored to have 0.00000570775
    // as the constant in front; see getPoolFundingRate for the formula
    // (182.648 / 8) * (5 ** 2) * (1 / (10_000 ** 2)) = 0.00000570775
    // 0.00000570775 as a WAD = 5.70775e12
    uint256 private constant INSURANCE_FUNDING_RATE_FACTOR = 5.70775e12;

    // Target percent of leveraged notional value in the market for the insurance pool to meet; 1% by default
    uint256 private constant INSURANCE_POOL_TARGET_PERCENT = 1e16;

    uint256 public delayedWithdrawalCounter;
    // Delayed withdrawal ID => DelayedWithdrawal
    mapping(uint256 => LibInsurance.DelayedWithdrawal) delayedWithdrawalAccess;
    // Address => Current delayedWithdrawal ID
    mapping(address => uint256) public override accountsDelayedWithdrawal;
    uint256 public override totalPendingCollateralWithdrawals;
    // After 5 days, withdrawal can be executed for a 5 day window period
    uint256 public constant delayedWithdrawalLock = 5 days;
    uint256 public constant delayedWithdrawalWindow = 5 days;
    StructuredLinkedList.List list;

    // Approximate average gas it costs for each iteration in `scanDelayedWithdrawals(...)`
    // AVERAGE_SCAN_GAS_PER_ACCOUNT = 41120;
    // Approximate gas it costs to call `commitToDelayedWithdrawal(...)`
    // AVERAGE_COMMIT_GAS = 384436;
    // Approximate gas it costs to call `executeDelayedWithdrawal()`
    // AVERAGE_EXECUTE_GAS = 132412;
    // COMMIT_EXECUTE_GAS_SUM = AVERAGE_COMMIT_GAS + AVERAGE_EXECUTE_GAS;
    // When committing, or executing a delayed withdrawal, spend half the amount of gas it would
    // cost to run the function on scanning through the delayed withdrawals and deleting any expired ones
    // SCAN_EXPIRED_WITHDRAWAL_COUNT = COMMIT_EXECUTE_GAS_SUM / 2 / AVERAGE_SCAN_GAS_PER_ACCOUNT;
    // This ends up being 6 iterations. i.e. At most do 6 iterations through the pending delayed withdrawals
    uint256 SCAN_EXPIRED_WITHDRAWAL_COUNT = 6;

    ITracerPerpetualSwaps public tracer; // Tracer associated with Insurance Pool

    event InsuranceDeposit(address indexed market, address indexed user, uint256 indexed amount);
    event InsuranceWithdraw(address indexed market, address indexed user, uint256 indexed amount);
    event InsuranceDelayedWithdrawalCommit(
        address indexed market,
        address indexed user,
        uint256 indexed collateralAmount,
        uint256 fee,
        uint256 id
    );
    event InsuranceDelayedWithdraw(address indexed market, address indexed user, uint256 indexed amount);

    constructor(address _tracer) {
        require(_tracer != address(0), "INS: _tracer = address(0)");
        tracer = ITracerPerpetualSwaps(_tracer);
        InsurancePoolToken _token = new InsurancePoolToken("Tracer Pool Token", "TPT");
        token = address(_token);
        collateralAsset = tracer.tracerQuoteToken();
        // Start with 1, so you can set 0 as null equivalent
        delayedWithdrawalCounter = 1;
    }

    /**
     * @notice Commit to a delayed withdrawal, which will be executable in 5 days
     * @param amount The amount of insurance pool tokens to burn
     * @param extraScanIterations The user can volunteer to do extra expired withdrawal iterations
     */
    function commitToDelayedWithdrawal(uint256 amount, uint256 extraScanIterations) external override {
        updatePoolAmount();
        scanDelayedWithdrawals(SCAN_EXPIRED_WITHDRAWAL_COUNT + extraScanIterations);
        uint256 balance = getPoolUserBalance(msg.sender);
        require(balance >= amount, "INS: balance < amount");

        clearUserDelayedWithdrawal(msg.sender);

        InsurancePoolToken poolToken = InsurancePoolToken(token);

        // tokens to return = (collateral holdings / pool token supply) * amount of pool tokens to withdraw
        uint256 wadTokensToSend = LibInsurance.calcWithdrawAmount(
            poolToken.totalSupply(),
            publicCollateralAmount,
            amount
        );

        uint256 fee = LibInsurance.calculateDelayedWithdrawalFee(
            getPoolTarget(),
            getPoolHoldings(),
            totalPendingCollateralWithdrawals,
            wadTokensToSend
        );

        // Tokens to send should be decreased by fee paid, so you do not have wadTokensToSend + fee > amount entitled
        wadTokensToSend = wadTokensToSend - fee;
        // fee can never be greater than publicCollateralAmount, since the `feeRate` in `feeRate * wadTokensToSend`
        // will always be less than 1, meaning fee < wadTokensToSend.
        // and wadTokensToSend <= publicCollateralAmount
        publicCollateralAmount -= fee;
        bufferCollateralAmount += fee;
        totalPendingCollateralWithdrawals += wadTokensToSend;

        uint256 id = addDelayedWithdrawal(amount, wadTokensToSend);
        emit InsuranceDelayedWithdrawalCommit(address(tracer), msg.sender, wadTokensToSend, fee, id);
    }

    /**
     * @notice Execute msg.sender's pending delayed withdrawal, if possible.
     * @param extraScanIterations User can volunteer to scan through extra expired withdrawals
     */
    function executeDelayedWithdrawal(uint256 extraScanIterations) external override {
        updatePoolAmount();
        scanDelayedWithdrawals(SCAN_EXPIRED_WITHDRAWAL_COUNT + extraScanIterations);
        uint256 balance = getPoolUserBalance(msg.sender);
        uint256 id = accountsDelayedWithdrawal[msg.sender];
        require(id != 0, "INS: No withdrawal pending");
        require(!removeIfExpired(id), "INS: Withdrawal expired");

        // It has not expired and has not yet been executed
        LibInsurance.DelayedWithdrawal memory withdrawal = delayedWithdrawalAccess[id];
        require(balance >= withdrawal.amount, "INS: balance < amount");
        require(block.timestamp >= withdrawal.creationTime + delayedWithdrawalLock, "INS: Withdrawal still pending");

        uint256 poolTokenWadAmount = withdrawal.amount;
        InsurancePoolToken poolToken = InsurancePoolToken(token);
        uint256 wadTokensToSend = LibInsurance.calcWithdrawAmount(
            poolToken.totalSupply(),
            publicCollateralAmount,
            poolTokenWadAmount
        );
        // todo comment this stuff
        uint256 quoteTokenDecimals = tracer.quoteTokenDecimals();
        uint256 rawTokenAmount = Balances.wadToToken(quoteTokenDecimals, wadTokensToSend);
        publicCollateralAmount = publicCollateralAmount - wadTokensToSend;
        delayedWithdrawalAccess[id].executed = true;
        // burn pool tokens, return collateral tokens
        poolToken.burnFrom(msg.sender, withdrawal.amount);
        IERC20 collateralToken = IERC20(collateralAsset);
        collateralToken.transfer(msg.sender, rawTokenAmount);
        deleteDelayedWithdrawal(id);
        emit InsuranceDelayedWithdraw(address(tracer), msg.sender, wadTokensToSend);
    }

    /**
     * @notice Adds a delayed withdrawal to the linked list and accountsDelayedWithdrawal mapping
     * @param poolTokenAmount The amount of insurance pool token to withdraw
     * @param collateralAmount The collateral token amount as per the ratio at time of addition
     * @dev The ratio of collateral:pool token will differ when execution occurs,
     *      and thus collateral amount will be recalculated upon execution
     */
    function addDelayedWithdrawal(uint256 poolTokenAmount, uint256 collateralAmount) internal returns (uint256 id) {
        list.pushBack(delayedWithdrawalCounter);
        delayedWithdrawalAccess[delayedWithdrawalCounter] = LibInsurance.DelayedWithdrawal(
            false,
            msg.sender,
            delayedWithdrawalCounter,
            block.timestamp,
            poolTokenAmount,
            collateralAmount,
            0,
            0
        );
        accountsDelayedWithdrawal[msg.sender] = delayedWithdrawalCounter;
        delayedWithdrawalCounter += 1;
        return delayedWithdrawalCounter - 1;
    }

    /**
     * @notice Scan through the list of delayed withdrawals, and delete any that are expired
     * @param scanAmount The maximum amount of iterations to perform
     * @dev Once a non-expired entry is reached, iteration is stopped
     */
    function scanDelayedWithdrawals(uint256 scanAmount) public override {
        for (uint256 i = 0; i < scanAmount; i++) {
            if (!removeHeadIfExpiredOrExecuted()) {
                // We have reached one that isn't expired/executed. We can stop iterating
                break;
            }
        }
    }

    /**
     * @notice If a given ID corresponds to a pending delayed withdrawal which has expired, delete it
     * @param id the ID to check and delete
     */
    function removeIfExpired(uint256 id) public override returns (bool removed) {
        (bool exists, , ) = list.getNode(id);
        if (
            (delayedWithdrawalAccess[id].executed == true ||
                block.timestamp >
                delayedWithdrawalAccess[id].creationTime + delayedWithdrawalWindow + delayedWithdrawalLock) && exists
        ) {
            // expired or executed
            deleteDelayedWithdrawal(id);
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice Delete the head of the list of delayed withdrawals, if expired
     */
    function removeHeadIfExpiredOrExecuted() public override returns (bool removed) {
        uint256 id = list.popFront();
        if (id == 0) {
            return false;
        }
        list.pushFront(id);
        return removeIfExpired(id);
    }

    /**
     * @notice Delete a pending withdrawal and remove it from pending collateral withdrawals
     */
    function deleteDelayedWithdrawal(uint256 id) internal {
        if (id == 0 || delayedWithdrawalAccess[id].creationTime == 0) {
            // Doesn't exist
            return;
        }
        list.remove(id);
        totalPendingCollateralWithdrawals -= delayedWithdrawalAccess[id].collateralAmountAtTimeOfCommit;
        // Set the ID of the account to 0, to indicate they have no pending withdrawals
        accountsDelayedWithdrawal[delayedWithdrawalAccess[id].account] = 0;
        delete delayedWithdrawalAccess[id];
    }

    function getDelayedWithdrawal(uint256 id) public override returns (LibInsurance.DelayedWithdrawal memory) {
        LibInsurance.DelayedWithdrawal memory ret = delayedWithdrawalAccess[id];
        return delayedWithdrawalAccess[id];
    }

    /**
     * @notice Allows a user to deposit to a given tracer market insurance pool
     * @dev Mints amount of the pool token to the user
     * @param amount the amount of tokens to deposit. Provided in WAD format
     */
    function deposit(uint256 amount) external override {
        IERC20 collateralToken = IERC20(collateralAsset);

        // convert token amount to WAD
        uint256 quoteTokenDecimals = tracer.quoteTokenDecimals();
        uint256 rawTokenAmount = Balances.wadToToken(quoteTokenDecimals, amount);
        require(collateralToken.transferFrom(msg.sender, address(this), rawTokenAmount), "INS: Transfer failed");

        // amount in wad format after being converted from token format
        uint256 wadAmount = uint256(Balances.tokenToWad(quoteTokenDecimals, rawTokenAmount));

        // Update pool balances and user
        updatePoolAmount();
        InsurancePoolToken poolToken = InsurancePoolToken(token);

        // tokens to mint = (pool token supply / collateral holdings) * collateral amount to stake
        uint256 tokensToMint = LibInsurance.calcMintAmount(poolToken.totalSupply(), publicCollateralAmount, wadAmount);

        // mint pool tokens, hold collateral tokens
        poolToken.mint(msg.sender, tokensToMint);
        publicCollateralAmount = publicCollateralAmount + wadAmount;
        emit InsuranceDeposit(address(tracer), msg.sender, wadAmount);
    }

    /**
     * @dev Delete any delayed withdrawal an account has pending
     * @param account Delete any pending delayed withdrawals of this account
     */
    function clearUserDelayedWithdrawal(address account) internal {
        uint256 delayedWithdrawalId = accountsDelayedWithdrawal[msg.sender];
        if (delayedWithdrawalId != 0) {
            deleteDelayedWithdrawal(delayedWithdrawalId);
        }
    }

    /**
     * @notice Allows a user to withdraw their assets from a given insurance pool
     * @dev burns amount of tokens from the pool token
     * @param amount the amount of pool tokens to burn. Provided in WAD format
     */
    function withdraw(uint256 amount) external override {
        updatePoolAmount();

        clearUserDelayedWithdrawal(msg.sender);

        uint256 balance = getPoolUserBalance(msg.sender);
        require(balance >= amount, "INS: balance < amount");

        IERC20 collateralToken = IERC20(collateralAsset);
        InsurancePoolToken poolToken = InsurancePoolToken(token);

        // tokens to return = (collateral holdings / pool token supply) * amount of pool tokens to withdraw
        uint256 wadTokensToSend = LibInsurance.calcWithdrawAmount(
            poolToken.totalSupply(),
            publicCollateralAmount,
            amount
        );

        uint256 fee = LibInsurance.calculateImmediateWithdrawalFee(
            getPoolTarget(),
            getPoolHoldings(),
            totalPendingCollateralWithdrawals,
            wadTokensToSend
        );

        wadTokensToSend -= fee;

        // convert token amount to raw amount from WAD
        uint256 rawTokenAmount = Balances.wadToToken(tracer.quoteTokenDecimals(), wadTokensToSend);

        // pool amount is always in WAD format
        publicCollateralAmount = publicCollateralAmount - wadTokensToSend - fee;
        bufferCollateralAmount = bufferCollateralAmount + fee;

        // burn pool tokens, return collateral tokens
        poolToken.burnFrom(msg.sender, amount);
        require(collateralToken.transfer(msg.sender, rawTokenAmount), "INS: Transfer failed");

        emit InsuranceWithdraw(address(tracer), msg.sender, wadTokensToSend);
    }

    /**
     * @notice Internally updates a given tracer's pool amount according to the tracer contract
     * @dev Withdraws from tracer, and adds amount to the pool's amount field.
     */
    function updatePoolAmount() public override {
        uint256 quote = uint256((tracer.getBalance(address(this))).position.quote);

        tracer.withdraw(quote);

        if (publicCollateralAmount > 0) {
            // Amount to pay to public is the ratio of public collateral amount to total funds
            uint256 payToPublic = PRBMathUD60x18.mul(
                quote,
                PRBMathUD60x18.div(publicCollateralAmount, getPoolHoldings())
            );

            publicCollateralAmount = publicCollateralAmount + payToPublic;

            // Amount to pay to buffer is the remainder
            bufferCollateralAmount = bufferCollateralAmount + quote - payToPublic;
        } else {
            // Pay to buffer if nothing in public insurance
            bufferCollateralAmount = bufferCollateralAmount + quote;
        }
    }

    /**
     * @notice Deposits some of the insurance pool's amount into the tracer contract
     * @dev If amount is greater than the insurance pool's balance, deposit total balance.
     *      This was done because in such an emergency situation, we want to recover as much as possible
     * @param amount The desired amount to take from the insurance pool
     */
    function drainPool(uint256 amount) external override onlyLiquidation {
        IERC20 tracerMarginToken = IERC20(tracer.tracerQuoteToken());

        uint256 poolHoldings = getPoolHoldings();

        if (amount >= poolHoldings) {
            // If public collateral left after draining is less than 1 token, we want to keep it at 1 token
            if (publicCollateralAmount > ONE_TOKEN) {
                // Leave 1 token for the public pool
                amount = poolHoldings - ONE_TOKEN;
                publicCollateralAmount = ONE_TOKEN;
            } else {
                amount = bufferCollateralAmount;
            }

            // Drain buffer
            bufferCollateralAmount = 0;
        } else if (amount > bufferCollateralAmount) {
            if (publicCollateralAmount < ONE_TOKEN) {
                // If there's not enough public collateral for there to be 1 token, cap amount being drained at the buffer
                amount = bufferCollateralAmount;
            } else if (poolHoldings - amount < ONE_TOKEN) {
                // If the amount of collateral left in the public insurance would be less than 1 token, cap amount being drained
                // from the public insurance such that 1 token is left in the public buffer
                amount = poolHoldings - ONE_TOKEN;
                publicCollateralAmount = ONE_TOKEN;
            } else {
                // Take out what you need from the public pool; there's enough for there to be >= 1 token left
                publicCollateralAmount = publicCollateralAmount - (amount - bufferCollateralAmount);
            }

            // Drain buffer
            bufferCollateralAmount = 0;
        } else {
            // Only need to take part of buffer pool out
            bufferCollateralAmount = bufferCollateralAmount - amount;
        }

        tracerMarginToken.approve(address(tracer), amount);
        tracer.deposit(amount);
    }

    /**
     * @notice gets a users balance in a given insurance pool
     * @param user the user whose balance is being retrieved
     */
    function getPoolUserBalance(address user) public view override returns (uint256) {
        return InsurancePoolToken(token).balanceOf(user);
    }

    /**
     * @notice Get total holdings of the insurance pool (= public + buffer collateral)
     */
    function getPoolHoldings() public view override returns (uint256) {
        return bufferCollateralAmount + publicCollateralAmount;
    }

    /**
     * @notice Get pool holdings, and subtract totalPendingCollateralWithdrawals
     */
    function getPoolHoldingsWithPending() public view override returns (uint256) {
        uint256 holdings = getPoolHoldings();
        if (totalPendingCollateralWithdrawals > holdings) {
            return 0;
        }
        return holdings - totalPendingCollateralWithdrawals;
    }

    function getPoolTokenTotalSupply() external view override returns (uint256) {
        InsurancePoolToken poolToken = InsurancePoolToken(token);

        return poolToken.totalSupply();
    }

    /**
     * @notice Gets the target fund amount for a given insurance pool
     * @dev The target amount is 1% of the leveraged notional value of the tracer being insured.
     */
    function getPoolTarget() public view override returns (uint256) {
        return PRBMathUD60x18.mul(tracer.leveragedNotionalValue(), INSURANCE_POOL_TARGET_PERCENT);
    }

    /**
     * @notice Gets the 8 hour funding rate for an insurance pool
     * @dev the funding rate is represented as
     *      (182.648 / 8) * (5 * ((fundTarget - fundHoldings) / (fundTarget * 10_000))) ** 2
     */
    function getPoolFundingRate() external view override returns (uint256) {
        uint256 poolHoldings = getPoolHoldingsWithPending();
        uint256 poolTarget = getPoolTarget();

        // If the pool is above the target, we don't pay the insurance funding rate
        if (poolTarget <= poolHoldings) {
            return 0;
        }

        // (poolFundingNeeded / poolTarget) is less than 10**18, which you cannot square using PRB-math;
        // thus, we do the multiplication manually
        uint256 poolFundingNeeded = poolTarget - poolHoldings;
        uint256 numerator = PRBMathUD60x18.mul(poolFundingNeeded, poolFundingNeeded);
        uint256 denominator = PRBMathUD60x18.mul(poolTarget, poolTarget);

        uint256 ratio = PRBMathUD60x18.div(numerator, denominator);

        return PRBMathUD60x18.mul(INSURANCE_FUNDING_RATE_FACTOR, ratio);
    }

    modifier onlyLiquidation() {
        require(msg.sender == tracer.liquidationContract(), "INS: sender not LIQ contract");
        _;
    }
}
