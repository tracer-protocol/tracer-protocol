//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "../lib/LibInsurance.sol";

interface IInsurance {
    function publicCollateralAmount() external view returns (uint256);

    function bufferCollateralAmount() external view returns (uint256);

    function totalPendingCollateralWithdrawals() external view returns (uint256);

    function accountsDelayedWithdrawal(address account) external view returns (uint256);

    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function updatePoolAmount() external;

    function drainPool(uint256 amount) external;

    function commitToDelayedWithdrawal(uint256 amount, uint256 extraScanIterations) external;

    function executeDelayedWithdrawal(uint256 extraScanIterations) external;

    function scanDelayedWithdrawals(uint256 scanAmount) external;

    function removeIfExpired(uint256 id) external returns (bool removed);

    function removeHeadIfExpiredOrExecuted() external returns (bool removed);

    function getDelayedWithdrawal(uint256 id) external returns (LibInsurance.DelayedWithdrawal memory);

    function getPoolUserBalance(address user) external view returns (uint256);

    function getPoolHoldings() external view returns (uint256);

    function getPoolHoldingsWithPending() external view returns (uint256);

    function getPoolTokenTotalSupply() external view returns (uint256);

    function getPoolTarget() external view returns (uint256);

    function getPoolFundingRate() external view returns (uint256);
}
