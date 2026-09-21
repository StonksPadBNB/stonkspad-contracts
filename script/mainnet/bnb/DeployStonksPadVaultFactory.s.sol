// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StonksPadVault} from "src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "src/StonksPadVaultFactory.sol";
import {StonksPadTreasury} from "src/StonksPadTreasury.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @title DeployStonksPadVaultFactory (BNB mainnet, chainId 56)
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
///        VAULT_IMPL         optional: reuse an already deployed StonksPadVault implementation. Step 1 is then
///                           skipped; the script checks that the address has code and answers the v1.1 probes.
///                           NOT used for the v2 generation: its vaults need the v1.2 implementation (factory
///                           defaults), which this script deploys. The libraries are CREATE2-deployed, so forge
///                           reuses the existing ones either way.
///        DEFAULT_VERIFIER   optional: factory-level default fast-path verifier (must differ from KEEPER)
///        DEFAULT_OPS_PER_CALL / DEFAULT_OPS_PER_DAY / DEFAULT_OPS_GAS_PRICE
///                           optional: factory-level default operations-reserve caps in wei (all three or none)
///                           — both defaults are applied only when the broadcaster is admin (steps 8-9)
///      Optional env vars (default to the canonical BSC mainnet addresses below):
///        BNB_USD_FEED, WBNB, PANCAKE_V2_ROUTER, PANCAKE_V3_ROUTER, PANCAKE_V3_QUOTER
///
///      Usage:
///        forge script script/mainnet/bnb/DeployStonksPadVaultFactory.s.sol:DeployStonksPadVaultFactory \
///            --rpc-url https://bsc-dataseed.bnbchain.org \
///            --broadcast --verify \
///            --account deployer
contract DeployStonksPadVaultFactory is Script {
    uint256 internal constant CHAIN_ID = 56;

    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant PANCAKE_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address internal constant FLAP_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address internal constant STONKS = 0xc9d825E83AadA475bD4d38C8ca984eD746277777;
    address internal constant CHAINLINK_BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

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
        address vaultImpl;
        address defaultVerifier;
        uint256 opsPerCall;
        uint256 opsPerDay;
        uint256 opsGasPrice;
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
        c.vaultImpl = vm.envOr("VAULT_IMPL", address(0));
        c.defaultVerifier = vm.envOr("DEFAULT_VERIFIER", address(0));
        c.opsPerCall = vm.envOr("DEFAULT_OPS_PER_CALL", uint256(0));
        c.opsPerDay = vm.envOr("DEFAULT_OPS_PER_DAY", uint256(0));
        c.opsGasPrice = vm.envOr("DEFAULT_OPS_GAS_PRICE", uint256(0));
    }

    /// @dev A reused implementation must be a deployed, locked (initializers disabled) v1.1 vault.
    function _checkReusedImpl(address implAddr) internal view {
        require(implAddr.code.length > 0, "VAULT_IMPL has no code");
        StonksPadVault v = StonksPadVault(payable(implAddr));
        require(v.FAST_CLAIM_DELAY() == 30 minutes, "VAULT_IMPL is not a v1.1 vault");
        require(v.OPS_HARD_MAX_GAS_PRICE() == 1 gwei, "VAULT_IMPL is not a v1.1 vault");
        require(v.factory() == address(0), "VAULT_IMPL must be a bare implementation");
        require(uint256(vm.load(implAddr, bytes32(0))) & 0xff == 0xff, "VAULT_IMPL initializers not disabled");
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "wrong chain: expected chain id in CHAIN_ID");
        Cfg memory c = _cfg();
        if (c.vaultImpl != address(0)) _checkReusedImpl(c.vaultImpl);

        vm.startBroadcast();
        // 1. implementation (links the StonksPadVaultUISchema library, deployed automatically by forge),
        //    or the already deployed one given in VAULT_IMPL
        StonksPadVault impl = c.vaultImpl != address(0) ? StonksPadVault(payable(c.vaultImpl)) : new StonksPadVault();
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
            // 8-9. factory-level vault defaults (v1.2): every later launch starts with them
            if (c.defaultVerifier != address(0)) factory.setDefaultVerifier(c.defaultVerifier);
            if (c.opsPerCall != 0) factory.setDefaultOpsCaps(c.opsPerCall, c.opsPerDay, c.opsGasPrice);
        }
        vm.stopBroadcast();

        console.log("StonksPadTreasury deployed at:    ", address(treasury));
        if (!treasuryWired) {
            console.log("ACTION REQUIRED: platformAdmin must call factory.setPlatformTreasury(treasury)");
        }
        console.log("StonksPadVault implementation:    ", address(impl));
        console.log("implementation reused (VAULT_IMPL):", c.vaultImpl != address(0));
        console.log("StonksPadVaultFactory deployed at:", address(factory));
        console.log("UpgradeableBeacon deployed at:    ", factory.beacon());
        console.log("Beacon implementation:            ", factory.beaconImplementation());
        console.log("Beacon owner (Flap Guardian):     ", factory.beaconOwner());
        console.log("platformAdmin:                    ", factory.platformAdmin());
        console.log("keeper:                           ", factory.keeper());
        console.log("platformTreasury:                 ", factory.platformTreasury());
        console.log("platformFeeBps:                   ", factory.platformFeeBps());
        console.log("bnbUsdFeed:                       ", factory.bnbUsdFeed());
        console.log("defaultVerifier:                  ", factory.defaultVerifier());
        console.log("defaultVerifierSince:             ", factory.defaultVerifierSince());
        console.log("defaultOpsMaxPerCall (wei):       ", factory.defaultOpsMaxPerCall());
        console.log("defaultOpsMaxPerDay (wei):        ", factory.defaultOpsMaxPerDay());
        console.log("defaultOpsMaxGasPrice (wei):      ", factory.defaultOpsMaxGasPrice());
        if (!treasuryWired && (c.defaultVerifier != address(0) || c.opsPerCall != 0)) {
            console.log("ACTION REQUIRED: platformAdmin must call setDefaultVerifier / setDefaultOpsCaps");
        }
    }
}
