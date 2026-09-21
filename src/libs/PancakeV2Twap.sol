// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IPancakeV2Pair} from "../interfaces/IPancake.sol";
import {IStonksPadVaultFactory} from "../interfaces/IStonksPadVaultFactory.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @title PancakeV2Twap
/// @notice UniswapV2-style time-weighted average price helpers (internal, inlined by callers).
/// @dev    Cumulative prices are UQ112x112 fixed-point sums of `reserveOther / reserveThis * dt`,
///         maintained by the pair on every `_update`. The average price over a window is
///         `(cumulativeNow - cumulativeThen) / elapsed`. Arithmetic on cumulatives is intentionally
///         unchecked: the pair's counters wrap, and the subtraction wraps consistently.
library PancakeV2Twap {
    uint256 internal constant Q112 = 2 ** 112;
    /// @notice Minimum age of the checkpoint used for a price floor (manipulation must be sustained
    ///         at least this long to move the average).
    uint32 internal constant MIN_TWAP_WINDOW = 30 minutes;
    /// @notice Maximum age of a usable checkpoint (protects against a long-stale average).
    uint32 internal constant MAX_TWAP_WINDOW = 24 hours;

    /// @notice Cumulative prices of `pair` as of now (extrapolated from the last reserve update).
    function currentCumulativePrices(address pair)
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        // uint32 truncation is the UniswapV2 convention; only differences are used.
        // forge-lint: disable-next-line(unsafe-typecast)
        blockTimestamp = uint32(block.timestamp);
        price0Cumulative = IPancakeV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IPancakeV2Pair(pair).price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IPancakeV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                uint32 elapsed = blockTimestamp - blockTimestampLast;
                price0Cumulative += (uint256(reserve1) << 112) / reserve0 * elapsed;
                price1Cumulative += (uint256(reserve0) << 112) / reserve1 * elapsed;
            }
        }
    }

    /// @notice Age in seconds of `obs` relative to `nowTs` (uint32 wrap-safe).
    function age(IStonksPadVaultFactory.TwapObs memory obs, uint32 nowTs) internal pure returns (uint32) {
        unchecked {
            return nowTs - obs.timestamp;
        }
    }

    /// @notice Output of `amountIn` of `tokenIn` at the average price between `obs` and now.
    /// @dev    Caller must have validated the observation window.
    function consult(
        address pair,
        address tokenIn,
        uint256 amountIn,
        IStonksPadVaultFactory.TwapObs memory obs,
        uint256 price0CumulativeNow,
        uint256 price1CumulativeNow,
        uint32 nowTs
    ) internal view returns (uint256 amountOut) {
        uint256 averagePrice;
        unchecked {
            uint32 elapsed = nowTs - obs.timestamp;
            if (tokenIn == IPancakeV2Pair(pair).token0()) {
                averagePrice = (price0CumulativeNow - obs.price0Cumulative) / elapsed;
            } else {
                averagePrice = (price1CumulativeNow - obs.price1Cumulative) / elapsed;
            }
        }
        amountOut = Math.mulDiv(amountIn, averagePrice, Q112);
    }
}
