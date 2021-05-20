require("@nomiclabs/hardhat-waffle")
require("@nomiclabs/hardhat-ethers")
require("hardhat-contract-sizer")
require("hardhat-deploy")
require("hardhat-prettier")
require("hardhat-abi-exporter")
require("hardhat-typechain")

module.exports = {
    solidity: {
        version: "0.8.0",
        settings: {
            optimizer: {
                enabled: true,
                runs: 1000,
            },
        },
    },
    networks: {
        hardhat: {
            blockGasLimit: 12450000,
        },
    },
    namedAccounts: {
        deployer: 0,
        acc1: 1,
        acc2: 2,
        acc3: 3,
    },
    contractSizer: {
        alphaSort: true,
        runOnCompile: true,
        disambiguatePaths: false,
    },
    typechain: {
        outDir: "./types",
        target: "web3-v1",
    },
}
