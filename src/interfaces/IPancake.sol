// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Subset of the PancakeSwap V2 router used by the vault and the treasury.
interface IPancakeV2Router {
    function factory() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Subset of the PancakeSwap V2 factory.
interface IPancakeV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Subset of a PancakeSwap V2 pair (UniswapV2-compatible cumulative price oracle).
interface IPancakeV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @notice Subset of the PancakeSwap V3 factory.
interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Subset of a PancakeSwap V3 pool (built-in TWAP oracle).
interface IPancakeV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function liquidity() external view returns (uint128);
}

/// @notice Subset of the PancakeSwap V3 SmartRouter used by the vault.
interface IPancakeV3SmartRouter {
    function factory() external view returns (address);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Subset of the PancakeSwap V3 QuoterV2 used by the vault.
/// @dev    `quoteExactInput` is not a view function (it simulates the swap and reverts internally);
///         the vault only calls it from state-changing keeper functions.
interface IPancakeV3QuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}
