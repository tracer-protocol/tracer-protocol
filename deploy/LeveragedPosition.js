const perpsAbi = require("../abi/contracts/TracerPerpetualSwaps.sol/TracerPerpetualSwaps.json")

module.exports = async function (hre) {
    const { deployments, getNamedAccounts, ethers, BigNumber } = hre
    const { read, execute } = deployments
    const { deployer, acc1 } = await getNamedAccounts()
    const signers = await ethers.getSigners()

    await deployments.fixture("FullDeployTest")
    let tracerInstance = new ethers.Contract(
        await deployments.read("TracerPerpetualsFactory", "tracersByIndex", 0),
        perpsAbi
    ).connect(signers[0])
    // let tracerInstance = new ethers.Contract(perpsAddress, perpsAbi)
    const priceOracle = await deployments.get("PriceOracle")
    const traderDeployment = await deployments.get("Trader")
    let traderInstance = await ethers.getContractAt(
        traderDeployment.abi,
        traderDeployment.address
    )
    const price = (await read("PriceOracleAdapter", "latestAnswer")).toString()
    await execute(
        "QuoteToken",
        { from: deployer, log: true },
        "approve",
        tracerInstance.address,
        ethers.utils.parseEther("1000") // amount
    )
    await execute(
        "QuoteToken",
        { from: acc1, log: true },
        "approve",
        tracerInstance.address,
        ethers.utils.parseEther("1000") // amount
    )

    // tracerInstance = await tracerInstance.connect(accounts[1])

    await tracerInstance.deposit(ethers.utils.parseEther("1000"))
    tracerInstance = tracerInstance.connect(signers[1])
    await tracerInstance.deposit(ethers.utils.parseEther("1000"))
    const block = await ethers.provider.getBlock("latest")

    const makerOrder = [
        deployer, // maker
        tracerInstance.address, // market
        price, // price
        ethers.utils.parseEther("10000"), // amount
        0, // side (0 == Long)
        (block.timestamp + 100).toString(), // expiry
        0, // created
    ]
    const mockSignedMake = [
        makerOrder,
        ethers.utils.formatBytes32String("DummyString"),
        ethers.utils.formatBytes32String("DummyString"),
        0,
    ]
    const takerOrder = [
        acc1, // maker
        tracerInstance.address, // market
        price, // price
        ethers.utils.parseEther("10000"), // amount
        1, // side (1 == Short)
        (block.timestamp + 100).toString(), // expiry
        0, // created
    ]
    const mockSignedTake = [
        takerOrder,
        ethers.utils.formatBytes32String("DummyString"),
        ethers.utils.formatBytes32String("DummyString"),
        0,
    ]

    await traderInstance.executeTrade([mockSignedMake], [mockSignedTake])

    tracerInstance = tracerInstance.connect(signers[0])

    // Reduce price by 5%
    await execute(
        "PriceOracle",
        { from: deployer, log: true },
        "setPrice",
        "95000000" // $0.95
    )
}

module.exports.tags = ["LeveragedPosition"]
