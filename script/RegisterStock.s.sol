// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StonksPadVaultFactory} from "src/StonksPadVaultFactory.sol";
import {IStonksPadVaultFactory} from "src/interfaces/IStonksPadVaultFactory.sol";

/// @title RegisterStock
/// @notice Registers (or updates) one stock token in a deployed `StonksPadVaultFactory`.
///         Chain-agnostic: works on testnet (97) and mainnet (56). Must be broadcast from the
///         `platformAdmin` account (or the Flap Guardian).
/// @dev Env vars:
///        FACTORY      StonksPadVaultFactory address
///        STOCK        stock token address
///        ORACLE_MODE  "CHAINLINK" (oracleMode 0, needs PRICE_FEED),
///                     "TWAP" / "TWAP_V2" (oracleMode 1: PancakeSwap V2 time-weighted price from factory
///                     checkpoints; DEX_KIND=V2 and an existing V2 pair for every hop), or
///                     "TWAP_V3" (oracleMode 2: 30-minute mean tick from the V3 pools' own oracle;
///                     DEX_KIND=V3 + V3_PATH, every pool must exist, hold liquidity and answer a
///                     30-minute observe — see factory.increaseV3ObservationCardinality)
///        PRICE_FEED   Chainlink STOCK/USD aggregator address (CHAINLINK mode only)
///        DEX_KIND     "V2" or "V3"
///        V2_PATH      (DEX_KIND=V2) comma-separated addresses, WBNB first, stock last
///                     e.g. 0xae13...a7cd,0xFa60...0DEE
///        V3_PATH      (DEX_KIND=V3) packed hex path: tokenIn(20) fee(3) tokenOut(20) [...]
///                     e.g. 0xbb4c...095c 0009c4 0e09...ce82  → "0xbb4c...095c0009c40e09...ce82"
///        ENABLED      optional, default true
///
///      Usage:
///        forge script script/RegisterStock.s.sol:RegisterStock \
///            --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
///            --broadcast --account admin
contract RegisterStock is Script {
    function run() external {
        StonksPadVaultFactory factory = StonksPadVaultFactory(vm.envAddress("FACTORY"));
        address stock = vm.envAddress("STOCK");
        address priceFeed = vm.envOr("PRICE_FEED", address(0));
        bool enabled = vm.envOr("ENABLED", true);
        string memory kind = vm.envString("DEX_KIND");
        string memory mode = vm.envString("ORACLE_MODE");

        IStonksPadVaultFactory.OracleMode oracleMode;
        if (keccak256(bytes(mode)) == keccak256("CHAINLINK")) {
            oracleMode = IStonksPadVaultFactory.OracleMode.Chainlink;
            require(priceFeed != address(0), "PRICE_FEED required for CHAINLINK");
        } else if (keccak256(bytes(mode)) == keccak256("TWAP") || keccak256(bytes(mode)) == keccak256("TWAP_V2")) {
            oracleMode = IStonksPadVaultFactory.OracleMode.TwapV2;
        } else if (keccak256(bytes(mode)) == keccak256("TWAP_V3")) {
            oracleMode = IStonksPadVaultFactory.OracleMode.TwapV3;
        } else {
            revert("ORACLE_MODE must be CHAINLINK, TWAP (= TWAP_V2) or TWAP_V3");
        }

        IStonksPadVaultFactory.DexKind dexKind;
        bytes memory path;
        if (keccak256(bytes(kind)) == keccak256("V2")) {
            dexKind = IStonksPadVaultFactory.DexKind.PancakeV2;
            address[] memory route = vm.envAddress("V2_PATH", ",");
            path = abi.encode(route);
        } else if (keccak256(bytes(kind)) == keccak256("V3")) {
            dexKind = IStonksPadVaultFactory.DexKind.PancakeV3;
            path = vm.envBytes("V3_PATH");
        } else {
            revert("DEX_KIND must be V2 or V3");
        }

        vm.startBroadcast();
        factory.registerStock(stock, dexKind, path, oracleMode, priceFeed, enabled);
        vm.stopBroadcast();

        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(stock);
        console.log("Registered stock:", stock);
        console.log("  enabled:      ", info.enabled);
        console.log("  dexKind:      ", uint256(info.dexKind));
        console.log("  oracleMode:   ", uint256(info.oracleMode));
        console.log("  priceFeed:    ", info.priceFeed);
        console.log("  registered stocks in factory:", factory.stockCount());
    }
}
