// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StonksPadVault} from "src/StonksPadVault.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @title DeployVaultImplV1_1
/// @notice Deploys the StonksPadVault v1.1 implementation (plus the changed `StonksPadVaultUISchema`
///         library; `StonksPadSwapLib` is unchanged and reused at its CREATE2 address). It does NOT
///         upgrade anything: only the beacon owner — the Flap Guardian — can call
///         `UpgradeableBeacon.upgradeTo(newImplementation)`. The script prints the exact calldata.
/// @dev Env: BEACON (the deployed UpgradeableBeacon). Works on chain 56 and 97.
///      forge script script/DeployVaultImplV1_1.s.sol:DeployVaultImplV1_1 --rpc-url $RPC --account <deployer> [--broadcast]
contract DeployVaultImplV1_1 is Script {
    function run() external {
        UpgradeableBeacon beacon = UpgradeableBeacon(vm.envAddress("BEACON"));
        address current = beacon.implementation();

        vm.startBroadcast();
        StonksPadVault impl = new StonksPadVault();
        vm.stopBroadcast();

        console.log("chain id:                 ", block.chainid);
        console.log("beacon:                   ", address(beacon));
        console.log("beacon owner (Guardian):  ", beacon.owner());
        console.log("current implementation:   ", current);
        console.log("NEW v1.1 implementation:  ", address(impl));
        console.log("Guardian call -> to:      ", address(beacon));
        console.log("Guardian call -> calldata:");
        console.logBytes(abi.encodeCall(UpgradeableBeacon.upgradeTo, (address(impl))));
    }
}
