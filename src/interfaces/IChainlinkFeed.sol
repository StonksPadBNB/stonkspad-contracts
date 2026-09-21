// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Minimal Chainlink AggregatorV3 interface used for the manipulation-resistant price floor
///         in `StonksPadVault.buyStocks()`.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
