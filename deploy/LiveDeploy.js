const tracerAbi = require("../abi/contracts/TracerPerpetualSwaps.sol/TracerPerpetualSwaps.json")

module.exports = async function (hre) {
    const { deployments, getNamedAccounts, ethers } = hre
    const { deploy, execute } = deployments
    const { deployer } = await getNamedAccounts()
    const signers = await ethers.getSigners()
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
    const libPricing = await deploy("Prices", {
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
    // asset price oracle => ASSET / USD
    const priceOracle = await deploy("PriceOracle", {
        from: deployer,
        log: true,
        contract: "ChainlinkOracle",
    })

    // Gas price oracle => fast gas / gwei
    const gasOracle = await deploy("GasOracle", {
        from: deployer,
        log: true,
        contract: "ChainlinkOracle",
    })

    const ethOracle = await deploy("EthOracle", {
        from: deployer,
        log: true,
        contract: "ChainlinkOracle",
    })

    await execute(
        "EthOracle",
        { from: deployer, log: true },
        "setDecimals",
        "8"
    )

    await execute(
        "EthOracle",
        { from: deployer, log: true },
        "setPrice",
        "300000000000" // 3000 USD / ETH
    )

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
        "20000000000" // 20 Gwei
    )

    // adapter converting asset oracle to WAD
    const oracleAdapter = await deploy("PriceOracleAdapter", {
        from: deployer,
        log: true,
        args: [priceOracle.address],
        contract: "OracleAdapter",
    })

    const gasPriceOracle = await deploy("GasPriceOracle", {
        from: deployer,
        log: true,
        args: [ethOracle.address, gasOracle.address],
        contract: "GasOracle",
    })

    // deploy token with an initial supply of 100000
    const token = await deploy("QuoteToken", {
        args: [ethers.utils.parseEther("10000000"), "Test Token", "TST", 18], //10 mil supply
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
            Prices: libPricing.address,
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
            Prices: libPricing.address,
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

    console.log(`Factory Deployed: ${factory.address}`)

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
            ethers.utils.formatBytes32String("TEST1/USD"),
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
        oracleAdapter.address,
        gasOracle.address,
        maxLiquidationSlippage
    )

    const tracerInstance = new ethers.Contract(
        await deployments.read("TracerPerpetualsFactory", "tracersByIndex", 0),
        tracerAbi
    ).connect(signers[0])

    let insurance = await tracerInstance.insuranceContract()
    let pricing = await tracerInstance.pricingContract()
    let liquidation = await tracerInstance.liquidationContract()

    // Set Trader.sol to be whitelisted, as well as deployer (for testing purposes)
    await tracerInstance.setWhitelist(trader.address, true)
    await tracerInstance.setWhitelist(deployer, true)

    // verify
    await hre.run("verify:verify", {
        address: libLiquidation.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: libPerpetuals.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: libInsurance.address,
        constructorArguments: [],
        contract: "contracts/lib/LibInsurance.sol:LibInsurance",
    })
    await hre.run("verify:verify", {
        address: libPricing.address,
        constructorArguments: [],
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
        address: oracleAdapter.address,
        constructorArguments: [priceOracle.address],
    })
    await hre.run("verify:verify", {
        address: gasPriceOracle.address,
        constructorArguments: [ethOracle.address, gasOracle.address],
    })
    await hre.run("verify:verify", {
        address: gasOracle.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: ethOracle.address,
        constructorArguments: [],
    })
    await hre.run("verify:verify", {
        address: token.address,
        constructorArguments: [
            ethers.utils.parseEther("10000000"),
            "Test Token",
            "TST",
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
    await hre.run("verify:verify", {
        address: insurance,
        constructorArguments: [tracerInstance.address],
    })
    await hre.run("verify:verify", {
        address: pricing,
        constructorArguments: [
            tracerInstance.address,
            insurance,
            oracleAdapter.address,
        ],
    })
    await hre.run("verify:verify", {
        address: liquidation,
        constructorArguments: [
            pricing,
            tracerInstance.address,
            insurance,
            gasOracle.address,
            maxLiquidationSlippage,
        ],
    })
    await hre.run("verify:verify", {
        address: tracerInstance.address,
        constructorArguments: [
            ethers.utils.formatBytes32String("TEST1/USD"),
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
}
module.exports.tags = ["LiveDeploy"]
