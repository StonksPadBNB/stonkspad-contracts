// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IPancakeV3Pool} from "../interfaces/IPancake.sol";
import {TickMath} from "./TickMath.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @title PancakeV3Twap
/// @notice Time-weighted average tick / price helpers for PancakeSwap V3 pools (internal, inlined).
/// @dev    Uses the pool's own oracle (`observe`), so no checkpoints have to be stored by the
///         factory. The pool must have enough observation cardinality to cover the window
///         (`increaseObservationCardinalityNext` is permissionless); otherwise `observe` reverts.
library PancakeV3Twap {
    /// @notice Averaging window used for the price floor.
    uint32 internal constant TWAP_V3_WINDOW = 30 minutes;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Arithmetic mean tick over the last `window` seconds (rounded toward negative infinity).
    function consult(address pool, uint32 window) internal view returns (int24 averageTick) {
        require(window > 0, unicode"Zero TWAP window / TWAP 窗口为零");
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IPancakeV3Pool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 w = int56(uint56(window));
        averageTick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) averageTick--;
    }

    /// @notice Output amount of the other pool token for `amountIn` of `tokenIn` at `tick`
    ///         (mirrors Uniswap `OracleLibrary.getQuoteAtTick`).
    function quoteAtTick(int24 tick, uint256 amountIn, address tokenIn, address token0)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            amountOut = tokenIn == token0
                ? Math.mulDiv(ratioX192, amountIn, 1 << 192)
                : Math.mulDiv(1 << 192, amountIn, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            amountOut = tokenIn == token0
                ? Math.mulDiv(ratioX128, amountIn, 1 << 128)
                : Math.mulDiv(1 << 128, amountIn, ratioX128);
        }
    }

    /// @notice Number of hops in a packed V3 path (tokenIn(20) [fee(3) tokenOut(20)]*).
    function hopCount(bytes memory path) internal pure returns (uint256) {
        require(path.length >= 43 && (path.length - 20) % 23 == 0, unicode"Invalid V3 path / V3 路径无效");
        return (path.length - 20) / 23;
    }

    /// @notice Decodes hop `i` of a packed V3 path.
    function hop(bytes memory path, uint256 i) internal pure returns (address tokenIn, uint24 fee, address tokenOut) {
        uint256 o = i * 23;
        tokenIn = _readAddress(path, o);
        fee = _readUint24(path, o + 20);
        tokenOut = _readAddress(path, o + 23);
    }

    function _readAddress(bytes memory data, uint256 offset) private pure returns (address a) {
        require(data.length >= offset + 20, unicode"Path read out of bounds / 路径读取越界");
        assembly {
            a := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    function _readUint24(bytes memory data, uint256 offset) private pure returns (uint24 v) {
        require(data.length >= offset + 3, unicode"Path read out of bounds / 路径读取越界");
        assembly {
            v := shr(232, mload(add(add(data, 32), offset)))
        }
    }
}
