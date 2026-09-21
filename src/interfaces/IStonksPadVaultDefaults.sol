// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title IStonksPadVaultDefaults
/// @notice v1.2 factory-level defaults a new vault copies at initialization. Kept out of
///         `IStonksPadVaultFactory` on purpose: that file is compiled into `StonksPadSwapLib`, and touching
///         it would change the library's metadata hash and therefore its CREATE2 address, although the
///         library code is identical (the deployed, verified mainnet library is reused).
interface IStonksPadVaultDefaults {
    /// @notice The fast-path verifier together with the time it was set at the factory (so its 24h
    ///         activation lock keeps running across vaults) and the operations-reserve caps.
    ///         All zero = both features off for new vaults.
    function vaultDefaults()
        external
        view
        returns (address verifier, uint64 verifierSince, uint256 opsPerCall, uint256 opsPerDay, uint256 opsGasPrice);
}
