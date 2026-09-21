// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice EIP-8056 "Scaled UI Amount" subset. Tokenized stocks such as Binance bStocks keep raw
///         on-chain balances and expose a UI multiplier (1e18 = 1.0x) that maps one raw unit to
///         `uiMultiplier / 1e18` real shares (adjusted for splits, dividends, …). Price feeds quote
///         one real share, DEXes price one raw unit, so the reference floor must divide by it.
interface IERC8056 {
    function uiMultiplier() external view returns (uint256);
}
