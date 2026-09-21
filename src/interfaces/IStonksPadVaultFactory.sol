// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice The factory surface that `StonksPadVault`, `StonksPadSwapLib` and `StonksPadTreasury`
///         read at call time (roles, treasury, DEX addresses, stock registry, TWAP observations).
interface IStonksPadVaultFactory {
    enum DexKind {
        PancakeV2,
        PancakeV3
    }

    /// @notice How the `buyStocks()` price floor is anchored for a stock.
    ///         Chainlink: STOCK/USD feed (plus the shared BNB/USD feed).
    ///         TwapV2:    time-weighted price of every PancakeSwap V2 pair along the registered path,
    ///                    from cumulative-price observations recorded in the factory.
    ///         TwapV3:    30-minute time-weighted average tick of every PancakeSwap V3 pool along the
    ///                    registered packed path, read from the pools' built-in oracle (`observe`).
    enum OracleMode {
        Chainlink,
        TwapV2,
        TwapV3
    }

    /// @param enabled    Whether the stock may currently be bought by vaults.
    /// @param dexKind    Which PancakeSwap router/quoter pair to use (TwapV2 requires PancakeV2, TwapV3 requires PancakeV3).
    /// @param oracleMode Price-floor reference (see `OracleMode`).
    /// @param priceFeed  Chainlink STOCK/USD feed (required for `Chainlink`, ignored for the TWAP modes).
    /// @param path       V2: `abi.encode(address[])` starting at WBNB and ending at the stock.
    ///                   V3: packed `(tokenIn, fee, tokenOut, ...)` starting at WBNB and ending at the stock.
    struct StockInfo {
        bool enabled;
        DexKind dexKind;
        OracleMode oracleMode;
        address priceFeed;
        bytes path;
    }

    /// @notice A recorded cumulative-price checkpoint of a PancakeSwap V2 pair.
    struct TwapObs {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
    }

    function keeper() external view returns (address);
    function platformAdmin() external view returns (address);
    function guardian() external view returns (address);
    function platformTreasury() external view returns (address);
    function platformFeeBps() external view returns (uint16);
    function wbnb() external view returns (address);
    function pancakeV2Router() external view returns (address);
    function pancakeV2Factory() external view returns (address);
    function pancakeV3Router() external view returns (address);
    function pancakeV3Factory() external view returns (address);
    function pancakeV3Quoter() external view returns (address);
    function bnbUsdFeed() external view returns (address);
    function oracleStaleness() external view returns (uint256);
    function mandatoryStock() external view returns (address);
    function getStock(address stock) external view returns (StockInfo memory info);
    function isVault(address vault) external view returns (bool);

    /// @notice Latest and previous checkpoints of `pair` (zero timestamp = none).
    function twapObservations(address pair) external view returns (TwapObs memory latest, TwapObs memory previous);

    /// @notice Record a checkpoint for every V2 pair along `stock`'s registered path. Permissionless.
    function updateTwapObservations(address stock) external;
}
