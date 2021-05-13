// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./Interfaces/ITracerPerpetualSwaps.sol";
import "./Interfaces/IPricing.sol";
import "./Interfaces/ILiquidation.sol";
import "./Interfaces/IInsurance.sol";
import "./Interfaces/ITracerPerpetualsFactory.sol";
import "./Interfaces/IDeployer.sol";
import "./Interfaces/ILiquidationDeployer.sol";
import "./Interfaces/IInsuranceDeployer.sol";
import "./Interfaces/IPricingDeployer.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TracerPerpetualsFactory is Ownable, ITracerPerpetualsFactory {
    uint256 public tracerCounter;
    address public deployer;
    address public liquidationDeployer;
    address public insuranceDeployer;
    address public pricingDeployer;

    // Index of Tracer (where 0 is index of first Tracer market), corresponds to tracerCounter => market address
    mapping(uint256 => address) public override tracersByIndex;
    // Tracer market => whether that address is a valid Tracer or not
    mapping(address => bool) public override validTracers;
    // Tracer market => whether this address is a DAO approved market.
    // note markets deployed by the DAO are by default approved
    mapping(address => bool) public override daoApproved;

    event TracerDeployed(bytes32 indexed marketId, address indexed market);

    constructor(
        address _deployer,
        address _liquidationDeployer,
        address _insuranceDeployer,
        address _pricingDeployer,
        address _governance
    ) {
        setDeployerContract(_deployer);
        setLiquidationDeployerContract(_liquidationDeployer);
        setInsuranceDeployerContract(_insuranceDeployer);
        setPricingDeployerContract(_pricingDeployer);
        transferOwnership(_governance);
    }

    /**
     * @notice Allows any user to deploy a tracer market
     * @param _data The data that will be used as constructor parameters for the new Tracer market.
     */
    function deployTracer(
        bytes calldata _data,
        address oracle,
        uint256 maxLiquidationSlippage
    ) external {
        _deployTracer(_data, msg.sender, oracle, maxLiquidationSlippage);
    }

    /**
     * @notice Allows the Tracer DAO to deploy a DAO approved Tracer market
     * @param _data The data that will be used as constructor parameters for the new Tracer market.
     */
    function deployTracerAndApprove(
        bytes calldata _data,
        address oracle,
        uint256 maxLiquidationSlippage
    ) external onlyOwner() {
        address tracer =
            _deployTracer(_data, owner(), oracle, maxLiquidationSlippage);
        // DAO deployed markets are automatically approved
        setApproved(address(tracer), true);
    }

    /**
     * @notice internal function for the actual deployment of a Tracer market.
     */
    function _deployTracer(
        bytes calldata _data,
        address tracerOwner,
        address oracle,
        uint256 maxLiquidationSlippage
    ) internal returns (address) {
        // Create and link tracer to factory
        address market = IDeployer(deployer).deploy(_data);
        ITracerPerpetualSwaps tracer = ITracerPerpetualSwaps(market);

        validTracers[market] = true;
        tracersByIndex[tracerCounter] = market;
        tracerCounter++;

        // Instantiate Insurance contract for tracer
        address insurance =
            IInsuranceDeployer(insuranceDeployer).deploy(market, address(this));
        address pricing =
            IPricingDeployer(pricingDeployer).deploy(market, insurance, oracle);
        address liquidation =
            ILiquidationDeployer(liquidationDeployer).deploy(
                pricing,
                market,
                insurance,
                maxLiquidationSlippage,
                tracerOwner
            );

        // Perform admin operations on the tracer to finalise linking
        tracer.setInsuranceContract(insurance);
        tracer.setPricingContract(pricing);
        tracer.setLiquidationContract(liquidation);

        // Ownership either to the deployer or the DAO
        tracer.transferOwnership(tracerOwner);
        IInsurance(insurance).transferOwnership(tracerOwner);
        IPricing(pricing).transferOwnership(tracerOwner);
        ILiquidation(liquidation).transferOwnership(tracerOwner);
        emit TracerDeployed(tracer.marketId(), address(tracer));
        return market;
    }

    /**
     * @notice Sets the deployer contract for tracers markets.
     * @param newDeployer the new deployer contract address
     */
    function setDeployerContract(address newDeployer)
        public
        override
        onlyOwner()
    {
        deployer = newDeployer;
    }

    function setInsuranceDeployerContract(address newInsuranceDeployer)
        public
        override
        onlyOwner()
    {
        insuranceDeployer = newInsuranceDeployer;
    }

    function setPricingDeployerContract(address newPricingDeployer)
        public
        override
        onlyOwner()
    {
        pricingDeployer = newPricingDeployer;
    }

    function setLiquidationDeployerContract(address newLiquidationDeployer)
        public
        override
        onlyOwner()
    {
        liquidationDeployer = newLiquidationDeployer;
    }

    /**
     * @notice Sets a contracts approval by the DAO. This allows the factory to
     *         identify contracts that the DAO has "absorbed" into its control
     * @dev requires the contract to be owned by the DAO if being set to true.
     */
    function setApproved(address market, bool value)
        public
        override
        onlyOwner()
    {
        if (value) {
            require(Ownable(market).owner() == owner(), "TFC: Owner not DAO");
        }
        daoApproved[market] = value;
    }
}
