// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice One row of the ABI-encoded `vaultData` accepted by `StonksPadVaultFactory.newVault()`.
///         `vaultData = abi.encode(AllocationRow[])`.
/// @param target     Fee recipient wallet (`isStock == false`) or registered stock token (`isStock == true`).
/// @param bps        Share of net revenue (after platform fee) in basis points. All rows must sum to 10000.
/// @param isStock    Row kind.
/// @param minHolding Minimum tax-token balance a holder needs to be included in the keeper's stock
///                   distribution snapshot (informational, enforced off-chain). The Flap schema only
///                   allows a flat tuple array, so the value is repeated on every row; rows may leave
///                   it at 0, all non-zero values must be equal.
struct AllocationRow {
    address target;
    uint16 bps;
    bool isStock;
    uint256 minHolding;
}

/// @notice Fee route initialisation data passed from the factory to `StonksPadVault.initialize()`.
struct FeeRouteInit {
    address recipient;
    uint16 bps;
}

/// @notice Stock allocation: a stock token and its weight (bps of net revenue).
struct StockAlloc {
    address token;
    uint16 bps;
}
