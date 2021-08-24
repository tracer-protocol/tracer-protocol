const tracerAbi = require("../abi/contracts/TracerPerpetualSwaps.sol/TracerPerpetualSwaps.json")

/**
 * A fork of `LiveDeploy` made specifically for the Lion's Mane
 * testnet deployment to Kovan
 */
module.exports = async function (hre) {
    const { deployments, getNamedAccounts, ethers } = hre
    const { deploy, execute } = deployments
    const { deployer } = await getNamedAccounts()
    const signers = await ethers.getSigners()

    // kovan specific config for tests
    const ethOracle = "0x9326BFA02ADD2366b30bacB125260Af641031331"

    // deploy libs
    const libMath = await deploy("LibMath", {
        from: deployer,
        log: true,
    })
    const libPerpetuals = await deploy("Perpetuals", {
        from: deployer,
        log: true,
    })
    const libBalances = await deploy("Balances", {
        from: deployer,
        log: true,
    })
    const libLiquidation = await deploy("LibLiquidation", {
        from: deployer,
        log: true,
    })
    const libPrices = await deploy("Prices", {
        from: deployer,
        log: true,
    })
    const libInsurance = await deploy("LibInsurance", {
        from: deployer,
        log: true,
    })

    // deploy trader
    const trader = await deploy("Trader", {
        from: deployer,
        log: true,
    })

    // deploy oracles
    const gasOracle = await deploy("GasOracle", {
        from: deployer,
        log: true,
        contract: "ChainlinkOracle",
    })

    // deploy second asset oracle for custom testing
    const customOracle = await deploy("CustomOracle", {
        from: deployer,
        log: true,
        contract: "ChainlinkOracle",
    })

    await execute(
        "GasOracle",
        { from: deployer, log: true },
        "setDecimals",
        "9"
    )

    await execute(
        "GasOracle",
        { from: deployer, log: true },
        "setPrice",
        "1000000000" // 1 Gwei
    )

    const ethOracleAdapter = await deploy("PriceOracleAdapter", {
        from: deployer,
        log: true,
        args: [ethOracle],
        contract: "OracleAdapter",
    })

    // wrap the custom oracle in an adapter
    const customOracleAdapter = await deploy("PriceOracleAdapter", {
        from: deployer,
        log: true,
        args: [customOracle.address],
        contract: "OracleAdapter",
    })

    // takes in the Fast Gas/Gwei and ETH/USD Chainlink oracles (not wrapped in adapter)
    // provides the USD/Gas price in WAD format
    const gasPriceOracle = await deploy("GasPriceOracle", {
        from: deployer,
        log: true,
        args: [ethOracle, gasOracle.address],
        contract: "GasOracle",
    })

    // deploy token with an initial supply of 100000
    const token = await deploy("QuoteToken", {
        args: [
            ethers.utils.parseEther("10000000"),
            "Tracer Test USDC",
            "tUSDC",
            8,
        ], //10 mil supply
        from: deployer,
        log: true,
        contract: "TestToken",
    })

    // deploy deployers
    const liquidationDeployer = await deploy("LiquidationDeployerV1", {
        from: deployer,
        libraries: {
            LibLiquidation: libLiquidation.address,
            Balances: libBalances.address,
            LibMath: libMath.address,
        },
        log: true,
    })

    const insuranceDeployer = await deploy("InsuranceDeployerV1", {
        from: deployer,
        libraries: {
            LibMath: libMath.address,
            Balances: libBalances.address,
            Insurance: libInsurance.address,
        },
        log: true,
    })

    const pricingDeployer = await deploy("PricingDeployerV1", {
        from: deployer,
        libraries: {
            LibMath: libMath.address,
            Prices: libPrices.address,
        },
        log: true,
    })

    // deploy Tracer perps deployer
    const perpsDeployer = await deploy("PerpsDeployerV1", {
        from: deployer,
        libraries: {
            Perpetuals: libPerpetuals.address,
            LibMath: libMath.address,
            Balances: libBalances.address,
            Prices: libPrices.address,
        },
        log: true,
    })

    // deploy Tracer perps factory
    let factory = await deploy("TracerPerpetualsFactory", {
        args: [
            perpsDeployer.address,
            liquidationDeployer.address,
            insuranceDeployer.address,
            pricingDeployer.address,
            deployer, // governance address
        ],
        from: deployer,
        log: true,
    })

    // deploy ETH/USDC Market using Chainlink Oracle
    let maxLeverage = ethers.utils.parseEther("12.5")
    let feeRate = 0 // 0 percent
    let fundingRateSensitivity = ethers.utils.parseEther("1")
    let maxLiquidationSlippage = ethers.utils.parseEther("0.5") // 50 percent
    let deleveragingCliff = ethers.utils.parseEther("20") // 20 percent
    let lowestMaxLeverage = ethers.utils.parseEther("12.5") // Default -> Doesn't go down
    let insurancePoolSwitchStage = ethers.utils.parseEther("1") // Switches mode at 1%
    let liquidationGasCost = 63516

    var deployTracerData = ethers.utils.defaultAbiCoder.encode(
        [
            "bytes32", //_marketId,a
            "address", //_tracerQuoteToken,
            "address", //_gasPriceOracle,
            "uint256", //_maxLeverage,
            "uint256", //_fundingRateSensitivity,
            "uint256", //_feeRate
            "address", // _feeReceiver,
            "uint256", // _deleveragingCliff
            "uint256", // _lowestMaxLeverage
            "uint256", // _insurancePoolSwitchStage
            "uint256", // _liquidationGasCost
        ],
        [
            ethers.utils.formatBytes32String("ETH/USD"),
            token.address,
            gasPriceOracle.address,
            maxLeverage,
            fundingRateSensitivity,
            feeRate,
            deployer,
            deleveragingCliff,
            lowestMaxLeverage,
            insurancePoolSwitchStage,
            liquidationGasCost,
        ]
    )

    // this deploys a tracer, insurance, pricing and liquidation contract
    await deployments.execute(
        "TracerPerpetualsFactory",
        {
            from: deployer,
            log: true,
        },
        "deployTracer",
        deployTracerData,
        ethOracleAdapter.address,
        gasOracle.address,
        maxLiquidationSlippage
    )

    // Deploy CUSTOM/USDC market using custom controlled oracle
    let maxLeverage2 = ethers.utils.parseEther("50")

    var deployCustomTracerData = ethers.utils.defaultAbiCoder.encode(
        [
            "bytes32", //_marketId,a
            "address", //_tracerQuoteToken,
            "address", //_gasPriceOracle,
            "uint256", //_maxLeverage,
            "uint256", //_fundingRateSensitivity,
            "uint256", //_feeRate
            "address", // _feeReceiver,
            "uint256", // _deleveragingCliff
            "uint256", // _lowestMaxLeverage
            "uint256", // _insurancePoolSwitchStage
            "uint256", // _liquidationGasCost
        ],
        [
            ethers.utils.formatBytes32String("CUSTOM/USD"),
            token.address,
            gasPriceOracle.address,
            maxLeverage2,
            fundingRateSensitivity,
            feeRate,
            deployer,
            deleveragingCliff,
            lowestMaxLeverage,
            insurancePoolSwitchStage,
            liquidationGasCost,
        ]
    )

    // this deploys a tracer, insurance, pricing and liquidation contract
    await deployments.execute(
        "TracerPerpetualsFactory",
        {
            from: deployer,
            log: true,
        },
        "deployTracer",
        deployCustomTracerData,
        customOracleAdapter.address,
        gasOracle.address,
        maxLiquidationSlippage
    )

    const ethUsdTracerInstance = new ethers.Contract(
        await deployments.read("TracerPerpetualsFactory", "tracersByIndex", 0),
        tracerAbi
    ).connect(signers[0])

    const customTracerInstance = new ethers.Contract(
        await deployments.read("TracerPerpetualsFactory", "tracersByIndex", 1),
        tracerAbi
    ).connect(signers[0])

    let insurance = await ethUsdTracerInstance.insuranceContract()
    let pricing = await ethUsdTracerInstance.pricingContract()
    let liquidation = await ethUsdTracerInstance.liquidationContract()

    let customInsurance = await customTracerInstance.insuranceContract()
    let customPricing = await customTracerInstance.pricingContract()
    let customLiquidation = await customTracerInstance.liquidationContract()

    // Set Trader.sol to be whitelisted, as well as deployer (for testing purposes)
    await ethUsdTracerInstance.setWhitelist(trader.address, true)
    await ethUsdTracerInstance.setWhitelist(deployer, true)
    await customTracerInstance.setWhitelist(trader.address, true)
    await customTracerInstance.setWhitelist(deployer, true)

    await hre.run("verify:verify", {
        address: libLiquidation.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: libPerpetuals.address,
        constructorArguments: [],
        contracts: "contracts/lib/LibPerpetuals.sol:Perpetuals",
    })
    await hre.run("verify:verify", {
        address: libInsurance.address,
        constructorArguments: [],
        contract: "contracts/lib/LibInsurance.sol:LibInsurance",
    })
    await hre.run("verify:verify", {
        address: libPrices.address,
        constructorArguments: [],
        contracts: "contracts/lib/LibPrices.sol:Prices",
    })
    await hre.run("verify:verify", {
        address: trader.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: libBalances.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: ethOracleAdapter.address,
        constructorArguments: [ethOracle],
    })
    await hre.run("verify:verify", {
        address: gasPriceOracle.address,
        constructorArguments: [ethOracle, gasOracle.address],
    })
    await hre.run("verify:verify", {
        address: token.address,
        constructorArguments: [
            ethers.utils.parseEther("10000000"),
            "Tracer Test USDC",
            "tUSDC",
            8,
        ],
        contract: "contracts/TestToken.sol:TestToken",
    })
    await hre.run("verify:verify", {
        address: factory.address,
        constructorArguments: [
            perpsDeployer.address,
            liquidationDeployer.address,
            insuranceDeployer.address,
            pricingDeployer.address,
            deployer, // governance address
        ],
    })

    // verify ETH/USD market
    await hre.run("verify:verify", {
        address: insurance,
        constructorArguments: [ethUsdTracerInstance.address],
    })
    await hre.run("verify:verify", {
        address: pricing,
        constructorArguments: [
            ethUsdTracerInstance.address,
            insurance,
            ethOracleAdapter.address,
        ],
    })
    await hre.run("verify:verify", {
        address: liquidation,
        constructorArguments: [
            pricing,
            ethUsdTracerInstance.address,
            insurance,
            gasOracle.address,
            maxLiquidationSlippage,
        ],
    })
    await hre.run("verify:verify", {
        address: ethUsdTracerInstance.address,
        constructorArguments: [
            ethers.utils.formatBytes32String("ETH/USD"),
            token.address,
            gasPriceOracle.address,
            maxLeverage,
            fundingRateSensitivity,
            feeRate,
            deployer,
            deleveragingCliff,
            lowestMaxLeverage,
            insurancePoolSwitchStage,
            liquidationGasCost,
        ],
    })

    // verify CUSTOM/USD market
    await hre.run("verify:verify", {
        address: customInsurance,
        constructorArguments: [customTracerInstance.address],
    })
    await hre.run("verify:verify", {
        address: customPricing,
        constructorArguments: [
            customTracerInstance.address,
            customInsurance,
            customOracleAdapter.address,
        ],
    })
    await hre.run("verify:verify", {
        address: customLiquidation,
        constructorArguments: [
            customPricing,
            customTracerInstance.address,
            customInsurance,
            gasOracle.address,
            maxLiquidationSlippage,
        ],
    })
    await hre.run("verify:verify", {
        address: customTracerInstance.address,
        constructorArguments: [
            ethers.utils.formatBytes32String("CUSTOM/USD"),
            token.address,
            gasPriceOracle.address,
            maxLeverage2,
            fundingRateSensitivity,
            feeRate,
            deployer,
            deleveragingCliff,
            lowestMaxLeverage,
            insurancePoolSwitchStage,
            liquidationGasCost,
        ],
    })
}
module.exports.tags = ["KovanDeploy"]
