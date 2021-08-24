// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "../TracerPerpetualSwaps.sol";
import "../Interfaces/deployers/IPerpsDeployer.sol";

/**
 * Deployer contract. Used by the Tracer Factory to deploy new Tracer markets
 */
contract PerpsDeployerV1 is IPerpsDeployer {
    function deploy(bytes calldata _data) external override returns (address) {
        (
            bytes32 _tracerId,
            address _tracerQuoteToken,
            address _gasPriceOracle,
            uint256 _maxLeverage,
            uint256 _fundingRateSensitivity,
            uint256 _feeRate,
            address _feeReceiver,
            uint256 _deleveragingCliff,
            uint256 _lowestMaxLeverage,
            uint256 _insurancePoolSwitchStage,
            uint256 _liquidationGasCost
        ) = abi.decode(
                _data,
                (bytes32, address, address, uint256, uint256, uint256, address, uint256, uint256, uint256, uint256)
            );
        require(_tracerQuoteToken != address(0), "TCRDeploy: _tracerQuoteToken = 0");
        require(_gasPriceOracle != address(0), "TCRDeploy: _gasPriceOracle = 0");
        require(_feeReceiver != address(0), "TCRDeploy: _feeReceiver = 0");
        TracerPerpetualSwaps tracer = new TracerPerpetualSwaps(
            _tracerId,
            _tracerQuoteToken,
            _gasPriceOracle,
            _maxLeverage,
            _fundingRateSensitivity,
            _feeRate,
            _feeReceiver,
            _deleveragingCliff,
            _lowestMaxLeverage,
            _insurancePoolSwitchStage,
            _liquidationGasCost
        );
        tracer.transferOwnership(msg.sender);
        return address(tracer);
    }
}
