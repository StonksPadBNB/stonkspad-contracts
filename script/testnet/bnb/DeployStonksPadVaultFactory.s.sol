// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StonksPadVault} from "src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "src/StonksPadVaultFactory.sol";
import {StonksPadTreasury} from "src/StonksPadTreasury.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @title DeployStonksPadVaultFactory (BNB testnet, chainId 97)
/// @notice Deploys the StonksPad vault stack in four transactions (plus the auto-linked
///         `StonksPadVaultUISchema` library), each under the EIP-3860 initcode limit:
///           1. `StonksPadVault` implementation
///           2. `UpgradeableBeacon(impl)` (owner = deployer)
///           3. `beacon.transferOwnership(FLAP_GUARDIAN)`
///           4. `StonksPadVaultFactory(beacon, …)` — its constructor refuses a beacon whose owner
///              is not the Flap Guardian.
///           5. `StonksPadTreasury(factory, STONKS, NFT_WALLET, PLATFORM_WALLET)`
///           6. `factory.setPlatformTreasury(treasury)` — only if the broadcaster is `platformAdmin`;
///              otherwise the admin (multisig) must call it afterwards (logged).
/// @dev Required env vars:
///        PLATFORM_ADMIN     StonksPad ops multisig (can change keeper / treasury / fee / stock registry)
///        KEEPER             StonksPad backend EOA (buyStocks / publishDistribution)
///        PLATFORM_TREASURY  initial receiver of the platform fee (replaced by the treasury in step 6)
///        NFT_WALLET         treasury: receiver of the 10% NFT holders share
///        PLATFORM_WALLET    treasury: receiver of the 10% platform share
///        STONKS             optional: buy & burn token (default below)
///        PLATFORM_FEE_BPS   optional: vault platform fee in bps of net revenue (default 1000; 1111 = 10% of
///                           gross at Flap's 10% fee; max 1200) — applied only when the broadcaster is admin
///        FLAP_GUARDIAN      optional override of the chain's Flap Guardian (default below)
///      Optional env vars (default to the canonical BSC testnet addresses below):
///        BNB_USD_FEED, WBNB, PANCAKE_V2_ROUTER, PANCAKE_V3_ROUTER, PANCAKE_V3_QUOTER
///
///      Usage:
///        forge script script/testnet/bnb/DeployStonksPadVaultFactory.s.sol:DeployStonksPadVaultFactory \
///            --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
///            --broadcast --verify \
///            --account deployer
contract DeployStonksPadVaultFactory is Script {
    uint256 internal constant CHAIN_ID = 97;

    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address internal constant PANCAKE_V2_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address internal constant PANCAKE_V3_ROUTER = 0x9a489505a00cE272eAa5e07Dba6491314CaE3796;
    address internal constant PANCAKE_V3_QUOTER = 0xbC203d7f83677c7ed3F7acEc959963E7F4ECC5C2;
    address internal constant FLAP_GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address internal constant STONKS = 0xFa60D973F7642B748046464e165A65B7323b0DEE;
    address internal constant CHAINLINK_BNB_USD = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

    struct Cfg {
        address platformAdmin;
        address keeper;
        address platformTreasury;
        address bnbUsdFeed;
        address wbnb;
        address v2Router;
        address v3Router;
        address v3Quoter;
        address guardian;
        address nftWallet;
        address platformWallet;
        address stonks;
        uint256 platformFeeBps;
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.platformAdmin = vm.envAddress("PLATFORM_ADMIN");
        c.keeper = vm.envAddress("KEEPER");
        c.platformTreasury = vm.envAddress("PLATFORM_TREASURY");
        c.bnbUsdFeed = vm.envOr("BNB_USD_FEED", CHAINLINK_BNB_USD);
        c.wbnb = vm.envOr("WBNB", WBNB);
        c.v2Router = vm.envOr("PANCAKE_V2_ROUTER", PANCAKE_V2_ROUTER);
        c.v3Router = vm.envOr("PANCAKE_V3_ROUTER", PANCAKE_V3_ROUTER);
        c.v3Quoter = vm.envOr("PANCAKE_V3_QUOTER", PANCAKE_V3_QUOTER);
        c.guardian = vm.envOr("FLAP_GUARDIAN", FLAP_GUARDIAN);
        c.nftWallet = vm.envAddress("NFT_WALLET");
        c.platformWallet = vm.envAddress("PLATFORM_WALLET");
        c.stonks = vm.envOr("STONKS", STONKS);
        c.platformFeeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(1000));
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "wrong chain: expected chain id in CHAIN_ID");
        Cfg memory c = _cfg();

        vm.startBroadcast();
        // 1. implementation (links the StonksPadVaultUISchema library, deployed automatically by forge)
        StonksPadVault impl = new StonksPadVault();
        // 2. beacon, owned by the deployer for one transaction only
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl));
        // 3. hand the upgrade authority to the Flap Guardian
        beacon.transferOwnership(c.guardian);
        // 4. factory — reverts unless beacon.owner() == _getGuardian()
        StonksPadVaultFactory factory = new StonksPadVaultFactory(
            address(beacon),
            c.wbnb,
            c.v2Router,
            c.v3Router,
            c.v3Quoter,
            c.bnbUsdFeed,
            c.platformAdmin,
            c.keeper,
            c.platformTreasury
        );
        // 5. treasury (80% STONKS buy & burn / 10% NFT / 10% platform)
        StonksPadTreasury treasury = new StonksPadTreasury(address(factory), c.stonks, c.nftWallet, c.platformWallet);
        // 6. point the vaults' platform fee at the treasury (admin-only; skipped if the broadcaster is not admin)
        bool treasuryWired;
        if (factory.platformAdmin() == msg.sender) {
            factory.setPlatformTreasury(address(treasury));
            treasuryWired = true;
            // 7. platform fee (only if different from the constructor default)
            if (c.platformFeeBps != 1000) factory.setPlatformFeeBps(uint16(c.platformFeeBps));
        }
        vm.stopBroadcast();

        console.log("StonksPadTreasury deployed at:    ", address(treasury));
        if (!treasuryWired) {
            console.log("ACTION REQUIRED: platformAdmin must call factory.setPlatformTreasury(treasury)");
        }
        console.log("StonksPadVault implementation:    ", address(impl));
        console.log("StonksPadVaultFactory deployed at:", address(factory));
        console.log("UpgradeableBeacon deployed at:    ", factory.beacon());
        console.log("Beacon implementation:            ", factory.beaconImplementation());
        console.log("Beacon owner (Flap Guardian):     ", factory.beaconOwner());
        console.log("platformAdmin:                    ", factory.platformAdmin());
        console.log("keeper:                           ", factory.keeper());
        console.log("platformTreasury:                 ", factory.platformTreasury());
        console.log("platformFeeBps:                   ", factory.platformFeeBps());
        console.log("bnbUsdFeed:                       ", factory.bnbUsdFeed());
    }
}
