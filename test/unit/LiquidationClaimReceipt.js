const { expect } = require("chai")
const { ethers, getNamedAccounts, deployments } = require("hardhat")
const { BigNumber } = require("ethers")
const {
    getFactory,
    getTracer,
    getLiquidation,
    getTrader,
    getQuoteToken,
    getInsurance,
} = require("../util/DeploymentUtil")

const provideOrders = async (tracer, liquidationAmount, timestamp) => {
    const sellWholeLiquidationAmount = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: liquidationAmount,
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 1,
    }

    const sellWholeLiquidationAmountTinySlippage = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.94").toString(),
        amount: liquidationAmount,
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 1,
    }

    const sellWholeLiquidationAmountZeroTokens = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: "0",
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 1,
    }

    const sellWholeLiquidationAmountUseNoSlippage = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.01").toString(),
        amount: liquidationAmount,
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 1,
    }

    const sellHalfLiquidationAmount = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).div(2).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 1,
    }

    const sellHalfLiquidationAmountSecond = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).div(2).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 2,
    }

    const sellHalfLiquidationAmountThird = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).div(2).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 3,
    }

    const sellLiquidationAmountNoSlippage = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.95").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp + 2,
    }

    const longOrder = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: liquidationAmount,
        side: "0", // Long, which is invalid
        expires: timestamp + 100,
        created: timestamp,
    }

    const zeroDollarOrder = {
        maker: accounts[1].address,
        market: tracer.address,
        price: "0", // $0
        amount: liquidationAmount,
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: timestamp,
    }

    const earlyCreationOrder = {
        maker: accounts[1].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).div(2).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: 0,
    }

    const wrongMakerOrder = {
        maker: accounts[2].address,
        market: tracer.address,
        price: ethers.utils.parseEther("0.5").toString(),
        amount: ethers.BigNumber.from(liquidationAmount).div(2).toString(),
        side: "1", // Short, because original position liquidated was long
        expires: timestamp + 100,
        created: 0,
    }

    orders = {
        sellWholeLiquidationAmount: sellWholeLiquidationAmount,
        sellWholeLiquidationAmountTinySlippage:
            sellWholeLiquidationAmountTinySlippage,
        sellHalfLiquidationAmount: sellHalfLiquidationAmount,
        sellHalfLiquidationAmountSecond: sellHalfLiquidationAmountSecond,
        sellHalfLiquidationAmountThird: sellHalfLiquidationAmountThird,
        longOrder: longOrder,
        zeroDollarOrder: zeroDollarOrder,
        earlyCreationOrder: earlyCreationOrder,
        wrongMakerOrder: wrongMakerOrder,
        sellWholeLiquidationAmountUseNoSlippage:
            sellWholeLiquidationAmountUseNoSlippage,
        sellLiquidationAmountNoSlippage: sellLiquidationAmountNoSlippage,
        sellWholeLiquidationAmountZeroTokens:
            sellWholeLiquidationAmountZeroTokens,
    }

    return orders
}

const addOrdersToTrader = async (trader, orders) => {
    for (const [key, order] of Object.entries(orders)) {
        let orderId = await trader.getOrderId(order)
        await trader.recordOrder(order)

        await trader.setFill(orderId, order.amount)

        if (key === "sellWholeLiquidationAmountUseNoSlippage") {
            await trader.setAverageExecutionPrice(
                orderId,
                ethers.utils.parseEther("0.95")
            )
        } else {
            await trader.setAverageExecutionPrice(orderId, order.price)
        }
    }
}

/**
 * accounts[0] is liquidatable
 */
const baseLiquidatableCase = deployments.createFixture(async () => {
    await deployments.fixture("GetIntoLiquidatablePosition")
    const _factory = await getFactory()
    const _tracer = await getTracer(_factory)

    return {
        tracer: _tracer,
        liquidation: await getLiquidation(_tracer),
        trader: await getTrader(),
        token: await getQuoteToken(_tracer),
        insurance: await getInsurance(_tracer),
    }
})

/**
 * accounts[1] liquidates half of accounts[0]'s position
 */
const halfLiquidatedCase = deployments.createFixture(async () => {
    const contracts = await baseLiquidatableCase()
    const { deployer } = await getNamedAccounts()
    accounts = await ethers.getSigners()
    const { tracer, liquidation } = contracts

    // Get half the base. Liquidate this amount
    const halfBase = (await tracer.getBalance(deployer)).position.base.div(2)

    await liquidation.connect(accounts[1]).liquidate(halfBase, deployer)

    const timestamp = (await ethers.provider.getBlock("latest")).timestamp

    return { ...contracts, timestamp }
})

/**
 * accounts[1] liquidates double of account[0]'s position
 */
const invalidLiquidatedCase = async () => {
    const { tracer, liquidation, trader } = await baseLiquidatableCase()
    const { deployer } = await getNamedAccounts()
    accounts = await ethers.getSigners()

    // Attempt to liquidate twice the amount of position
    const doubleBase = (await tracer.getBalance(deployer)).position.base.mul(2)

    const tx = liquidation.connect(accounts[1]).liquidate(doubleBase, deployer)
    await expect(tx).to.be.reverted

    return { tracer, liquidation, trader }
}

/**
 * accounts[1] liquidates half of account[0]'s position
 * accounts[1] orders to sell liquidated position are added to trader
 */
const liquidatedAndSoldCase = deployments.createFixture(async () => {
    const contracts = await halfLiquidatedCase()

    const liquidationAmount = (
        await contracts.liquidation.liquidationReceipts(0)
    ).amountLiquidated.toString()

    // create orders to sell liquidated position
    const orders = await provideOrders(
        contracts.tracer,
        liquidationAmount,
        contracts.timestamp
    )
    // add orders to trader to record them as executed
    await addOrdersToTrader(contracts.trader, orders)
    return { contracts: contracts, orders: orders }
})

describe("Unit tests: Liquidation.sol claimReceipt", async () => {
    let accounts
    let tracer
    let liquidation
    let trader
    const fifteenMinutes = 60 * 15

    context("calcAmountToReturn", async () => {
        context(
            "when units sold is greater than liquidation amount",
            async () => {
                it("Reverts ", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()

                    const tx = contracts.liquidation.calcAmountToReturn(
                        0,
                        [
                            orders.sellHalfLiquidationAmountSecond,
                            orders.sellHalfLiquidationAmount,
                            orders.sellHalfLiquidationAmountThird,
                        ],
                        contracts.trader.address
                    )
                    await expect(tx).to.be.revertedWith("LIQ: Unit mismatch")
                })
            }
        )

        context(
            "When execution price has no slippage, but order price is low",
            async () => {
                it("calculates no slippage", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()
                    tracer = contracts.tracer
                    liquidation = contracts.liquidation
                    trader = contracts.trader

                    const tx = await liquidation.callStatic.calcAmountToReturn(
                        0,
                        [orders.sellWholeLiquidationAmountUseNoSlippage],
                        trader.address
                    )
                    await expect(tx).to.equal(ethers.utils.parseEther("0"))
                })
            }
        )

        context("When there is slippage", async () => {
            it("Calculates accurately", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()

                const amountToReturn =
                    await contracts.liquidation.callStatic.calcAmountToReturn(
                        0,
                        [
                            orders.sellHalfLiquidationAmount,
                            orders.sellHalfLiquidationAmountSecond,
                        ],
                        contracts.trader.address
                    )

                // 5000 * 0.95 - 5000* 0.5 = 2250
                const expectedAmountToReturn = ethers.utils.parseEther("2250")
                expect(amountToReturn).to.equal(expectedAmountToReturn)
            })
        })

        context("When there is no slippage", async () => {
            it("Returns 0 ", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()

                const amountToReturn =
                    await contracts.liquidation.callStatic.calcAmountToReturn(
                        0,
                        [orders.sellLiquidationAmountNoSlippage],
                        contracts.trader.address
                    )
                expect(amountToReturn).to.equal(BigNumber.from("0"))
            })
        })
    })

    context("getLiquidationReceipt", async () => {
        context("after a receipt submission", async () => {
            it("Returns a valid receipt", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()
                const amountLiquidated = ethers.utils.parseEther("5000")
                // minMargin = 6 * (0.00006*63515) + 9500/12.5
                // escrowAmount = (margin - (minMargin - margin)) / 2 = (500 - (782.86 - 500))/2 = 108.56712
                const escrowedAmount = ethers.utils.parseEther("108.56712")
                const liquidationSide = 0 // long

                const expectedReceipt = [
                    contracts.tracer.address, // market
                    accounts[1].address, // liquidator
                    accounts[0].address, // liquidatee
                    ethers.utils.parseEther("0.95"), // price
                    BigNumber.from(contracts.timestamp), // time
                    escrowedAmount,
                    BigNumber.from(contracts.timestamp + fifteenMinutes),
                    amountLiquidated,
                    false, // escrow claimed
                    liquidationSide,
                    false, // liquidatorRefundClaimed
                ]
                let receipt = await contracts.liquidation.liquidationReceipts(0)
                receipt = receipt.slice(0, 11)
                for (let i = 0; i < receipt.length; i++) {
                    expect(receipt[i]).to.equal(expectedReceipt[i])
                }
            })
        })

        context("on invalid submission", async () => {
            it("Returns nothing", async () => {
                const contracts = await invalidLiquidatedCase()
                let receipt = await contracts.liquidation.liquidationReceipts(0)
                const zeroAddress = "0x0000000000000000000000000000000000000000"

                for (let i = 0; i < 3; i++) {
                    expect(receipt[i]).to.equal(zeroAddress)
                }

                for (let i = 3; i < 8; i++) {
                    expect(receipt[i].toString()).to.equal("0")
                }
                expect(receipt[8]).to.equal(false)
                expect(receipt[9].toString()).to.equal("0")
                expect(receipt[10]).to.equal(false)
            })
        })
    })

    context("claimReceipt", async () => {
        const liquidateAndDepositAccount2 = deployments.createFixture(
            async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()

                await contracts.token
                    .connect(accounts[2])
                    .approve(
                        contracts.insurance.address,
                        ethers.utils.parseEther("10000")
                    )

                return { contracts: contracts, orders: orders }
            }
        )

        context("when receipt doesn't exist", async () => {
            it("Reverts", async () => {
                const contracts = await halfLiquidatedCase()
                accounts = await ethers.getSigners()
                const tx = contracts.liquidation.claimReceipt(
                    32,
                    [],
                    accounts[0].address
                )

                // Revert with the first check that requires a field to not equal 0
                await expect(tx).to.be.revertedWith("LIQ: Liquidator mismatch")
            })
        })

        context("when non-whitelisted trader is given", async () => {
            it("Reverts", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()
                const tx = contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [], accounts[3].address)

                await expect(tx).to.be.revertedWith(
                    "LIQ: Trader is not whitelisted"
                )
            })
        })

        context("when claim time has passed", async () => {
            it("Reverts ", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()

                // Increase time by a bit over the claim receipt time
                await network.provider.send("evm_increaseTime", [
                    fifteenMinutes + 1,
                ])
                await network.provider.send("evm_mine", [])

                const tx = contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [], accounts[0].address)

                await expect(tx).to.be.revertedWith("LIQ: claim time passed")
            })
        })

        context("when sender isn't liquidator", async () => {
            it("reverts", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()

                const tx = contracts.liquidation
                    .connect(accounts[2])
                    .claimReceipt(0, [], accounts[0].address)

                await expect(tx).to.be.revertedWith("LIQ: Liquidator mismatch")
            })
        })

        context("on a receipt that's already claimed", async () => {
            it("reverts", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()

                const order = orders.sellLiquidationAmountNoSlippage

                // Whitelist the smoddit Trader
                await contracts.tracer
                    .connect(accounts[0])
                    .setWhitelist(contracts.trader.address, true)
                // Claim receipt then claim again
                await contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [order], contracts.trader.address)
                const tx = contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [order], contracts.trader.address)

                await expect(tx).to.be.revertedWith("LIQ: Already claimed")
            })
        })

        context("when slippage occurs - below escrow amount", async () => {
            it("Accurately updates accounts", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()
                const liquidationAmount = (
                    await contracts.liquidation.liquidationReceipts(0)
                ).amountLiquidated
                const escrowedAmount = (
                    await contracts.liquidation.liquidationReceipts(0)
                ).escrowedAmount

                // This order sells all liquidationAmount at $0.94, even though the receipt is $0.95,
                // so slippage is liquidationAmount*0.95 - liquidationAmount*0.94
                const order = orders.sellWholeLiquidationAmountTinySlippage

                const receiptValue = liquidationAmount
                    .mul(BigNumber.from("95"))
                    .div(BigNumber.from("100"))
                const sellValue = liquidationAmount
                    .mul(BigNumber.from("94"))
                    .div(BigNumber.from("100"))
                const slippageAmount = receiptValue.sub(sellValue)

                const liquidatorBefore = await contracts.tracer.balances(
                    accounts[1].address
                )
                const liquidatorQuoteBefore = liquidatorBefore.position.quote

                const liquidateeQuoteBefore = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote

                // Whitelist the smoddit Trader
                await contracts.tracer
                    .connect(accounts[0])
                    .setWhitelist(contracts.trader.address, true)
                // Claim receipt then claim again
                await contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [order], contracts.trader.address)

                const liquidatorAfter = await contracts.tracer.balances(
                    accounts[1].address
                )
                const liquidatorQuoteAfter = liquidatorAfter.position.quote
                const liquidateeQuoteAfter = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote

                expect(liquidatorQuoteAfter).to.equal(
                    liquidatorQuoteBefore.add(slippageAmount)
                )

                // Total leveraged value should go down by slippageAmount
                expect(liquidatorAfter.totalLeveragedValue).to.equal(
                    liquidatorBefore.totalLeveragedValue.sub(slippageAmount)
                )

                const expectedLiquidateeDifference =
                    escrowedAmount.sub(slippageAmount)
                expect(liquidateeQuoteAfter).to.equal(
                    liquidateeQuoteBefore.add(expectedLiquidateeDifference)
                )
            })
        })

        context(
            "when slippage occurs - above escrow amount & empty insurance pool",
            async () => {
                it("Accurately updates accounts", async () => {
                    const { contracts } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()
                    const escrowedAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).escrowedAmount

                    // This order sells all liquidationAmount at $0.5, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.5
                    const order = orders.sellWholeLiquidationAmount

                    const liquidatorQuoteBefore = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteBefore = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)

                    // Claim receipt then claim again
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)

                    const liquidatorQuoteAfter = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteAfter = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Amount should only increase by escrowed amount, since ins pool is empty
                    expect(liquidatorQuoteAfter).to.equal(
                        liquidatorQuoteBefore.add(escrowedAmount)
                    )
                    // Liquidatee's balance should not change
                    expect(liquidateeQuoteAfter).to.equal(liquidateeQuoteBefore)
                })
            }
        )

        context(
            "when slippage occurs - above escrow amount & indadequately-full insurance pool",
            async () => {
                it("Accurately updates accounts", async () => {
                    const { contracts, orders } =
                        await liquidateAndDepositAccount2()
                    accounts = await ethers.getSigners()

                    const liquidationAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).amountLiquidated
                    const escrowedAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).escrowedAmount

                    // This order sells all liquidationAmount at $0.5, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.5
                    const order = orders.sellWholeLiquidationAmount

                    const receiptValue = liquidationAmount
                        .mul(BigNumber.from("95"))
                        .div(BigNumber.from("100"))
                    const sellValue = liquidationAmount
                        .mul(BigNumber.from("50"))
                        .div(BigNumber.from("100"))
                    const slippageAmount = receiptValue.sub(sellValue)

                    // We want slippage > escrowedAmount + insurancePoolHoldings
                    await contracts.insurance
                        .connect(accounts[2])
                        .deposit(slippageAmount.sub(escrowedAmount).div(2))
                    await contracts.insurance
                        .connect(accounts[2])
                        .updatePoolAmount()

                    const poolHoldingsBefore =
                        await contracts.insurance.getPoolHoldings()
                    const liquidatorQuoteBefore = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteBefore = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)

                    const liquidatorQuoteAfter = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteAfter = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote
                    const expectedDifference = escrowedAmount
                        .add(poolHoldingsBefore)
                        .sub(ethers.utils.parseEther("1"))

                    // Should increase by amount escrowed + whatever was in the insurance pool
                    expect(liquidatorQuoteAfter).to.equal(
                        liquidatorQuoteBefore.add(expectedDifference)
                    )
                    expect(liquidateeQuoteAfter).to.equal(liquidateeQuoteBefore)
                    await contracts.insurance.updatePoolAmount()
                    expect(
                        await contracts.insurance.getPoolHoldings()
                    ).to.equal(ethers.utils.parseEther("1"))
                })
            }
        )

        context(
            "when slippage occurs - above escrow amount & full insurance pool",
            async () => {
                it("Accurately updates accounts", async () => {
                    const { contracts, orders } =
                        await liquidateAndDepositAccount2()
                    accounts = await ethers.getSigners()

                    const liquidationAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).amountLiquidated
                    const escrowedAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).escrowedAmount

                    // This order sells all liquidationAmount at $0.5, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.5
                    const order = orders.sellWholeLiquidationAmount
                    const receiptValue = liquidationAmount
                        .mul(BigNumber.from("95"))
                        .div(BigNumber.from("100"))
                    const sellValue = liquidationAmount
                        .mul(BigNumber.from("50"))
                        .div(BigNumber.from("100"))
                    const slippageAmount = receiptValue.sub(sellValue)

                    // We want slippage > escrowedAmount + insurancePoolHoldings
                    await contracts.insurance
                        .connect(accounts[2])
                        .deposit(ethers.utils.parseEther("10000"))
                    await contracts.insurance
                        .connect(accounts[2])
                        .updatePoolAmount()

                    const poolHoldingsBefore =
                        await contracts.insurance.getPoolHoldings()
                    const liquidatorQuoteBefore = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteBefore = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)

                    const liquidatorQuoteAfter = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteAfter = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Should increase by amount escrowed + whatever was in the insurance pool
                    expect(liquidatorQuoteAfter).to.equal(
                        liquidatorQuoteBefore.add(slippageAmount)
                    )
                    expect(liquidateeQuoteAfter).to.equal(liquidateeQuoteBefore)
                    await contracts.insurance.updatePoolAmount()

                    // Insurance pool should go down by (slippageAmount - escrowedAMount)
                    const expectedPoolHoldings = poolHoldingsBefore.sub(
                        slippageAmount.sub(escrowedAmount)
                    )
                    expect(
                        await contracts.insurance.getPoolHoldings()
                    ).to.equal(expectedPoolHoldings)
                })
            }
        )

        context(
            "when slippage occurs - above maxSlippage (caps at maxSlippage)",
            async () => {
                it("Accurately updates accounts", async () => {
                    const { contracts, orders } =
                        await liquidateAndDepositAccount2()
                    accounts = await ethers.getSigners()

                    // Set maxSlippage to 2%
                    await contracts.liquidation
                        .connect(accounts[0])
                        .setMaxSlippage(ethers.utils.parseEther("0.02"))

                    const liquidationAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).amountLiquidated
                    const escrowedAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).escrowedAmount

                    // This order sells all liquidationAmount at $0.5, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.5
                    // But that goes over the newly-set 2% cap
                    const order = orders.sellWholeLiquidationAmount
                    const receiptValue = liquidationAmount
                        .mul(BigNumber.from("95"))
                        .div(BigNumber.from("100"))

                    // percent slippage = slippage / total amount
                    // slippage = percent / total amount
                    const expectedSlippage = receiptValue
                        .mul(BigNumber.from("2"))
                        .div(BigNumber.from("100"))

                    const liquidatorQuoteBefore = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteBefore = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)

                    const liquidatorQuoteAfter = (
                        await contracts.tracer.balances(accounts[1].address)
                    ).position.quote
                    const liquidateeQuoteAfter = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote

                    // Should increase by amount escrowed + whatever was in the insurance pool
                    expect(liquidatorQuoteAfter).to.equal(
                        liquidatorQuoteBefore.add(expectedSlippage)
                    )

                    // liquidatee base should have gone up by (escrowedAmount - slippage)
                    expect(liquidateeQuoteAfter).to.equal(
                        liquidateeQuoteBefore.add(
                            escrowedAmount.sub(expectedSlippage)
                        )
                    )
                })
            }
        )

        context("when No slippage", async () => {
            it("Makes no changes (except liquidatee, who gets escrow) ", async () => {
                const { contracts, orders } =
                    await liquidateAndDepositAccount2()
                accounts = await ethers.getSigners()

                const order = orders.sellLiquidationAmountNoSlippage
                const escrowedAmount = (
                    await contracts.liquidation.liquidationReceipts(0)
                ).escrowedAmount

                const liquidatorQuoteBefore = (
                    await contracts.tracer.balances(accounts[1].address)
                ).position.quote
                const liquidateeQuoteBefore = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote

                await contracts.insurance.updatePoolAmount()
                const insuranceHoldingsBefore =
                    await contracts.insurance.getPoolHoldings()

                // Whitelist the smoddit Trader
                await contracts.tracer
                    .connect(accounts[0])
                    .setWhitelist(contracts.trader.address, true)
                await contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [order], contracts.trader.address)

                const liquidatorQuoteAfter = (
                    await contracts.tracer.balances(accounts[1].address)
                ).position.quote
                const liquidateeQuoteAfter = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote
                await contracts.insurance.updatePoolAmount()
                const insuranceHoldingsAfter =
                    await contracts.insurance.getPoolHoldings()

                // Should increase by amount escrowed + whatever was in the insurance pool
                expect(liquidatorQuoteAfter).to.equal(liquidatorQuoteBefore)

                // liquidatee base should have gone up by escrowedAMount
                expect(liquidateeQuoteAfter).to.equal(
                    liquidateeQuoteBefore.add(escrowedAmount)
                )
                expect(insuranceHoldingsBefore).to.equal(insuranceHoldingsAfter)
            })
        })

        context("when units sold is 0", async () => {
            it("Makes no changes (except to liquidatee, who gets escrow) ", async () => {
                const { contracts, orders } =
                    await liquidateAndDepositAccount2()
                accounts = await ethers.getSigners()

                const order = orders.sellWholeLiquidationAmountZeroTokens
                const escrowedAmount = (
                    await contracts.liquidation.liquidationReceipts(0)
                ).escrowedAmount

                const liquidatorQuoteBefore = (
                    await contracts.tracer.balances(accounts[1].address)
                ).position.quote
                const liquidateeQuoteBefore = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote

                await contracts.insurance.updatePoolAmount()
                const insuranceHoldingsBefore =
                    await contracts.insurance.getPoolHoldings()

                // Whitelist the smoddit Trader
                await contracts.tracer
                    .connect(accounts[0])
                    .setWhitelist(contracts.trader.address, true)
                await contracts.liquidation
                    .connect(accounts[1])
                    .claimReceipt(0, [order], contracts.trader.address)

                const liquidatorQuoteAfter = (
                    await contracts.tracer.balances(accounts[1].address)
                ).position.quote
                const liquidateeQuoteAfter = (
                    await contracts.tracer.balances(accounts[0].address)
                ).position.quote

                await contracts.insurance.updatePoolAmount()
                const insuranceHoldingsAfter =
                    await contracts.insurance.getPoolHoldings()

                // Should increase by amount escrowed + whatever was in the insurance pool
                expect(liquidatorQuoteAfter).to.equal(liquidatorQuoteBefore)

                // liquidatee base should have gone up by escrowedAmount
                expect(liquidateeQuoteAfter).to.equal(
                    liquidateeQuoteBefore.add(escrowedAmount)
                )
                expect(insuranceHoldingsAfter).to.equal(insuranceHoldingsBefore)
            })
        })
    })

    context("claimEscrow", async () => {
        const increaseFifteenMinutes = async () => {
            await network.provider.send("evm_increaseTime", [
                fifteenMinutes + 1,
            ])
            await network.provider.send("evm_mine", [])
        }

        context("when receipt does not exist", async () => {
            it("Reverts ", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()
                const tx = contracts.liquidation
                    .connect(accounts[0])
                    .claimEscrow(1)
                await expect(tx).to.be.revertedWith("LIQ: Invalid receipt")
            })
        })

        context(
            "when receipt already claimed through claimEscrow",
            async () => {
                it("Reverts ", async () => {
                    const { contracts } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()
                    await increaseFifteenMinutes()
                    await contracts.liquidation
                        .connect(accounts[0])
                        .claimEscrow(0)
                    const tx = contracts.liquidation
                        .connect(accounts[0])
                        .claimEscrow(0)
                    await expect(tx).to.be.revertedWith("LIQ: Escrow claimed")
                })
            }
        )

        context("when calling too early", async () => {
            it("Reverts ", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()
                const tx = contracts.liquidation
                    .connect(accounts[0])
                    .claimEscrow(0)
                await expect(tx).to.be.revertedWith("LIQ: Not released")
            })
        })

        context(
            "when receipt partially claimed by liquidator on claimReceipt",
            async () => {
                it("reverts", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()
                    // This order sells all liquidationAmount at $0.94, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.94
                    const order = orders.sellWholeLiquidationAmountTinySlippage

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)
                    // Claim receipt then claim again
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)
                    // Don't need to test balances because that is tested in context("claimReceipts")

                    await increaseFifteenMinutes()
                    const tx = contracts.liquidation
                        .connect(accounts[0])
                        .claimEscrow(0)
                    await expect(tx).to.be.revertedWith("LIQ: Escrow claimed")
                })
            }
        )

        context(
            "when receipt fully claimed by liquidator on claimReceipt",
            async () => {
                it("Reverts", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()

                    // This order sells all liquidationAmount at $0.5, even though the receipt is $0.95,
                    // so slippage is liquidationAmount*0.95 - liquidationAmount*0.5
                    const order = orders.sellWholeLiquidationAmount

                    // Whitelist the smoddit Trader
                    await contracts.tracer
                        .connect(accounts[0])
                        .setWhitelist(contracts.trader.address, true)

                    // Claim receipt then claim again
                    await contracts.liquidation
                        .connect(accounts[1])
                        .claimReceipt(0, [order], contracts.trader.address)
                    await increaseFifteenMinutes()
                    const tx = contracts.liquidation
                        .connect(accounts[0])
                        .claimEscrow(0)
                    await expect(tx).to.be.revertedWith("LIQ: Escrow claimed")
                })
            }
        )

        context(
            "when receipt not claimed by liquidator on claimReceipt",
            async () => {
                it("Claims accurately", async () => {
                    const { contracts } = await liquidatedAndSoldCase()
                    accounts = await ethers.getSigners()

                    const escrowedAmount = (
                        await contracts.liquidation.liquidationReceipts(0)
                    ).escrowedAmount
                    const quoteBefore = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote
                    const liquidatorBefore = await contracts.tracer.balances(
                        accounts[2].address
                    )

                    await increaseFifteenMinutes()
                    await contracts.liquidation
                        .connect(accounts[0])
                        .claimEscrow(0)

                    const quoteAfter = (
                        await contracts.tracer.balances(accounts[0].address)
                    ).position.quote
                    const liquidatorAfter = await contracts.tracer.balances(
                        accounts[2].address
                    )

                    expect(liquidatorAfter.position.quote).to.equal(
                        liquidatorBefore.position.quote
                    )
                    expect(liquidatorAfter.position.base).to.equal(
                        liquidatorBefore.position.base
                    )
                    expect(quoteAfter).to.equal(quoteBefore.add(escrowedAmount))
                })
            }
        )
    })

    context("currentLiquidationId", async () => {
        context("liquidation ID", async () => {
            it("Correctly increments", async () => {
                // liquidatedAndSoldCase() liquidates half, so check liquidation ID then liquidate rest
                const { contracts } = await liquidatedAndSoldCase()
                accounts = await ethers.getSigners()

                const firstLiquidationID =
                    await contracts.liquidation.currentLiquidationId()
                expect(firstLiquidationID).to.equal(BigNumber.from("1"))

                // Get half the base. Liquidate this amount
                const restOfBase = (
                    await contracts.tracer.getBalance(accounts[0].address)
                ).position.base.div(2)

                await contracts.liquidation
                    .connect(accounts[1])
                    .liquidate(restOfBase, accounts[0].address)

                const secondLiquidationID =
                    await contracts.liquidation.currentLiquidationId()
                expect(secondLiquidationID).to.equal(BigNumber.from("2"))
            })
        })
    })

    context("calcUnitsSold", async () => {
        context("When no orders given", async () => {
            it("Returns nothing ", async () => {
                const { contracts } = await liquidatedAndSoldCase()
                const result =
                    await contracts.liquidation.callStatic.calcUnitsSold(
                        [],
                        contracts.trader.address,
                        0
                    )
                expect(result[0]).to.equal(0)
                expect(result[1]).to.equal(0)
            })
        })

        context(
            "When execution price has no slippage, but order price is low",
            async () => {
                it("calculates no slippage", async () => {
                    const { contracts } = await liquidatedAndSoldCase()
                    tracer = contracts.tracer
                    liquidation = contracts.liquidation
                    trader = contracts.trader
                    const liquidationAmount = (
                        await liquidation.liquidationReceipts(0)
                    ).amountLiquidated
                    const orders = await provideOrders(
                        contracts.tracer,
                        liquidationAmount,
                        contracts.timestamp
                    )

                    const tx = await liquidation.callStatic.calcUnitsSold(
                        [orders.sellWholeLiquidationAmountUseNoSlippage],
                        trader.address,
                        0
                    )
                    await expect(tx[0]).to.equal(
                        ethers.utils.parseEther("5000")
                    )
                    await expect(tx[1]).to.equal(
                        ethers.utils.parseEther("0.95")
                    )
                })
            }
        )

        context("in the normal case", async () => {
            it("Calculates correctly", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                tracer = contracts.tracer
                liquidation = contracts.liquidation
                trader = contracts.trader

                const tx = await liquidation.callStatic.calcUnitsSold(
                    [
                        orders.sellHalfLiquidationAmount,
                        orders.sellHalfLiquidationAmountSecond,
                    ],
                    trader.address,
                    0
                )
                expect(tx[0]).to.equal(ethers.utils.parseEther("5000"))
                expect(tx[1]).to.equal(ethers.utils.parseEther("0.5"))
            })
        })

        context("when all invalid orders", async () => {
            it("Returns nothing ", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                const receiptId = 0
                const liquidationAmount = (
                    await contracts.liquidation.liquidationReceipts(receiptId)
                ).amountLiquidated

                const receipt = await (
                    await contracts.liquidation.calcUnitsSold(
                        [
                            orders.longOrder,
                            orders.wrongMakerOrder,
                            orders.earlyCreationOrder,
                            orders.longOrder,
                        ],
                        contracts.trader.address,
                        0
                    )
                ).wait()
                let eventCounter = 0
                // Make sure InvalidClaimOrder is emitted correct number of times
                receipt.events.filter((x) => {
                    if (
                        x.event === "InvalidClaimOrder" &&
                        x.args.receiptId == 0
                    ) {
                        eventCounter++
                    }
                })
                const expectedNumberOfEventEmissions = 4
                expect(eventCounter).to.equal(expectedNumberOfEventEmissions)
                const result =
                    await contracts.liquidation.callStatic.calcUnitsSold(
                        [
                            orders.longOrder,
                            orders.wrongMakerOrder,
                            orders.earlyCreationOrder,
                            orders.longOrder,
                        ],
                        contracts.trader.address,
                        0
                    )
                expect(result[0]).to.equal(0)
                expect(result[1]).to.equal(0)
            })
        })

        context("when some invalid orders", async () => {
            it("Calculates correctly", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                let result =
                    await contracts.liquidation.callStatic.calcUnitsSold(
                        [
                            orders.sellHalfLiquidationAmount,
                            orders.longOrder,
                            orders.earlyCreationOrder,
                        ],
                        contracts.trader.address,
                        0
                    )
                expect(result[0]).to.equal(ethers.utils.parseEther("2500")) // units sold
                expect(result[1]).to.equal(ethers.utils.parseEther("0.5")) // avg price
            })

            it("Emits events", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                const receiptId = 0

                const receipt = await (
                    await contracts.liquidation.calcUnitsSold(
                        [
                            orders.sellHalfLiquidationAmount,
                            orders.longOrder,
                            orders.earlyCreationOrder,
                        ],
                        contracts.trader.address,
                        0
                    )
                ).wait()
                let eventCounter = 0
                // Make sure InvalidClaimOrder is emitted correct number of times
                receipt.events.filter((x) => {
                    if (
                        x.event === "InvalidClaimOrder" &&
                        x.args.receiptId == 0
                    ) {
                        eventCounter++
                    }
                })
                const expectedNumberOfEventEmissions = 2
                expect(eventCounter).to.equal(expectedNumberOfEventEmissions)
            })
        })

        context("when duplicate orders", async () => {
            it("Reverts", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                let tx = contracts.liquidation.callStatic.calcUnitsSold(
                    [
                        orders.sellHalfLiquidationAmount,
                        orders.sellHalfLiquidationAmount,
                        orders.sellHalfLiquidationAmount,
                    ],
                    contracts.trader.address,
                    0
                )
                await expect(tx).to.be.revertedWith(
                    "LIQ: Order already claimed"
                )
            })
        })

        context("when orders were created before the receipt", async () => {
            it("Calculates correctly", async () => {
                const { contracts, orders } = await liquidatedAndSoldCase()
                const receiptId = 0

                const receipt = await (
                    await contracts.liquidation.calcUnitsSold(
                        [orders.earlyCreationOrder, orders.earlyCreationOrder],
                        contracts.trader.address,
                        0
                    )
                ).wait()
                let eventCounter = 0
                // Make sure InvalidClaimOrder is emitted correct number of times
                receipt.events.filter((x) => {
                    if (
                        x.event === "InvalidClaimOrder" &&
                        x.args.receiptId == 0
                    ) {
                        eventCounter++
                    }
                })
                const expectedNumberOfEventEmissions = 2
                expect(eventCounter).to.equal(expectedNumberOfEventEmissions)
                const result =
                    await contracts.liquidation.callStatic.calcUnitsSold(
                        [orders.earlyCreationOrder, orders.earlyCreationOrder],
                        contracts.trader.address,
                        0
                    )
                expect(result[0]).to.equal(ethers.utils.parseEther("0")) // units sold
                expect(result[1]).to.equal(ethers.utils.parseEther("0")) // avg price
            })
        })

        context(
            "when orders were created of the wrong side (e.g. long when they should be short)",
            async () => {
                it("Calculates correctly", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()

                    const receipt = await (
                        await contracts.liquidation.calcUnitsSold(
                            [orders.longOrder, orders.longOrder],
                            contracts.trader.address,
                            0
                        )
                    ).wait()
                    let eventCounter = 0
                    // Make sure InvalidClaimOrder is emitted correct number of times
                    receipt.events.filter((x) => {
                        if (
                            x.event === "InvalidClaimOrder" &&
                            x.args.receiptId == 0
                        ) {
                            eventCounter++
                        }
                    })
                    const expectedNumberOfEventEmissions = 2
                    expect(eventCounter).to.equal(
                        expectedNumberOfEventEmissions
                    )
                    const result =
                        await contracts.liquidation.callStatic.calcUnitsSold(
                            [orders.longOrder, orders.longOrder],
                            contracts.trader.address,
                            0
                        )
                    expect(result[0]).to.equal(ethers.utils.parseEther("0")) // units sold
                    expect(result[1]).to.equal(ethers.utils.parseEther("0")) // avg price
                })
            }
        )

        context(
            "when some orders have different maker to liquidator",
            async () => {
                it("Calculates correctly", async () => {
                    const { contracts, orders } = await liquidatedAndSoldCase()
                    const receiptId = 0

                    const receipt = await (
                        await contracts.liquidation.calcUnitsSold(
                            [orders.wrongMakerOrder, orders.wrongMakerOrder],
                            contracts.trader.address,
                            receiptId
                        )
                    ).wait()
                    let eventCounter = 0
                    // Make sure InvalidClaimOrder is emitted correct number of times
                    receipt.events.filter((x) => {
                        if (
                            x.event === "InvalidClaimOrder" &&
                            x.args.receiptId == 0
                        ) {
                            eventCounter++
                        }
                    })
                    const expectedNumberOfEventEmissions = 2
                    expect(eventCounter).to.equal(
                        expectedNumberOfEventEmissions
                    )
                    const result =
                        await contracts.liquidation.callStatic.calcUnitsSold(
                            [orders.wrongMakerOrder, orders.wrongMakerOrder],
                            contracts.trader.address,
                            0
                        )
                    expect(result[0]).to.equal(ethers.utils.parseEther("0")) // units sold
                    expect(result[1]).to.equal(ethers.utils.parseEther("0")) // avg price
                })
            }
        )
    })
})
