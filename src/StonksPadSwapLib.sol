// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IStonksPadVaultFactory} from "./interfaces/IStonksPadVaultFactory.sol";
import {
    IPancakeV2Router,
    IPancakeV2Factory,
    IPancakeV3Factory,
    IPancakeV3Pool,
    IPancakeV3SmartRouter,
    IPancakeV3QuoterV2
} from "./interfaces/IPancake.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IERC8056} from "./interfaces/IERC8056.sol";
import {PancakeV2Twap} from "./libs/PancakeV2Twap.sol";
import {PancakeV3Twap} from "./libs/PancakeV3Twap.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @title StonksPadSwapLib
/// @notice Quote, reference-price floor and swap execution shared by `StonksPadVault.buyStocks()`
///         and `StonksPadTreasury.buyAndBurn()`.
/// @dev    External library (DELEGATECALL): every call runs in the caller's storage/balance
///         context, so approvals and swaps are made by the vault / treasury itself. Split out of the
///         vault to keep its runtime bytecode under the EIP-170 limit.
///
///         Two floors are enforced on every swap:
///           1. DEX quote × (1 − maxSlippageBps)          — guards a mis-set `minOut`;
///           2. reference price × (1 − maxOracleDeviationBps) — guards against front-running, where
///              the reference is Chainlink (`OracleMode.Chainlink`), the ≥ 30-minute time-weighted
///              average price of the PancakeSwap V2 path from factory checkpoints (`OracleMode.TwapV2`),
///              or the 30-minute time-weighted average tick of the PancakeSwap V3 path read from the
///              pools' built-in oracle (`OracleMode.TwapV3`).
library StonksPadSwapLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @notice PancakeSwap V2 swap fee per hop, applied to the TWAP reference so that it is
    ///         comparable with an executable quote (the deviation band then covers only price
    ///         impact and manipulation, not protocol fees).
    uint256 internal constant V2_FEE_BPS = 25;

    /// @notice Swap `amountIn` WBNB (already wrapped and held by the caller) into `stock`.
    /// @dev    Output is measured as a balance delta and must be ≥ `minOut`. For TWAP-mode stocks a
    ///         fresh checkpoint is recorded in the factory after the swap.
    function buyOne(
        IStonksPadVaultFactory f,
        IStonksPadVaultFactory.StockInfo memory info,
        address stock,
        uint256 amountIn,
        uint256 minOut,
        uint16 maxSlippageBps,
        uint16 maxOracleDeviationBps
    ) external returns (uint256 out) {
        require(minOut > 0, unicode"minOut must be > 0 / minOut 必须大于 0");
        // Floor 1: DEX quote (guards against a mis-set minOut).
        uint256 quoted = quote(f, info, amountIn);
        require(
            minOut >= quoted * (BPS - maxSlippageBps) / BPS,
            unicode"minOut below slippage floor / minOut 低于滑点下限"
        );
        // Floor 2: reference price (Chainlink or ≥30-min TWAP; cannot be moved by a same-block front-run).
        uint256 oracle = oracleOut(f, info, stock, amountIn);
        require(
            minOut >= oracle * (BPS - maxOracleDeviationBps) / BPS,
            unicode"minOut below oracle floor / minOut 低于预言机下限"
        );

        IERC20 wbnb = IERC20(f.wbnb());
        uint256 before = IERC20(stock).balanceOf(address(this));
        if (info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV2) {
            address router = f.pancakeV2Router();
            wbnb.forceApprove(router, amountIn);
            IPancakeV2Router(router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amountIn, minOut, abi.decode(info.path, (address[])), address(this), block.timestamp
                );
        } else {
            address router = f.pancakeV3Router();
            wbnb.forceApprove(router, amountIn);
            IPancakeV3SmartRouter(router)
                .exactInput(
                    IPancakeV3SmartRouter.ExactInputParams({
                    path: info.path, recipient: address(this), amountIn: amountIn, amountOutMinimum: minOut
                })
                );
        }
        out = IERC20(stock).balanceOf(address(this)) - before;
        require(out >= minOut, unicode"Insufficient output / 输出不足");

        if (info.oracleMode == IStonksPadVaultFactory.OracleMode.TwapV2) {
            // Roll the TWAP window forward so the next buy has a checkpoint of the right age.
            f.updateTwapObservations(stock);
        }
    }

    /// @notice DEX quote for `amountIn` along the registered path.
    function quote(IStonksPadVaultFactory f, IStonksPadVaultFactory.StockInfo memory info, uint256 amountIn)
        public
        returns (uint256 quoted)
    {
        if (info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV2) {
            uint256[] memory amounts =
                IPancakeV2Router(f.pancakeV2Router()).getAmountsOut(amountIn, abi.decode(info.path, (address[])));
            quoted = amounts[amounts.length - 1];
        } else {
            (quoted,,,) = IPancakeV3QuoterV2(f.pancakeV3Quoter()).quoteExactInput(info.path, amountIn);
        }
    }

    /// @notice Reference output for `amountIn` wei of BNB according to the stock's oracle mode.
    function oracleOut(
        IStonksPadVaultFactory f,
        IStonksPadVaultFactory.StockInfo memory info,
        address stock,
        uint256 amountIn
    ) public view returns (uint256 out) {
        if (info.oracleMode == IStonksPadVaultFactory.OracleMode.Chainlink) {
            out = chainlinkOut(f, info, stock, amountIn);
        } else if (info.oracleMode == IStonksPadVaultFactory.OracleMode.TwapV2) {
            out = twapOut(f, info, amountIn);
        } else {
            out = twapV3Out(f, info, amountIn);
        }
    }

    /// @notice Expected stock output at Chainlink prices:
    ///         amountIn * bnbUsd * 10^stockDecimals / (1e18 * stockUsd), feed decimals normalised,
    ///         then divided by the token's EIP-8056 UI multiplier (1e18 when the token has none), because
    ///         the feed prices one real share while the DEX prices one raw token unit.
    function chainlinkOut(
        IStonksPadVaultFactory f,
        IStonksPadVaultFactory.StockInfo memory info,
        address stock,
        uint256 amountIn
    ) public view returns (uint256 out) {
        uint256 staleness = f.oracleStaleness();
        (uint256 bnbUsd, uint8 bnbDec) = readFeed(f.bnbUsdFeed(), staleness);
        (uint256 stockUsd, uint8 stockFeedDec) = readFeed(info.priceFeed, staleness);
        uint8 stockDec = IERC20Metadata(stock).decimals();
        out = amountIn * bnbUsd * (10 ** stockFeedDec) * (10 ** stockDec) / (1e18 * (10 ** bnbDec) * stockUsd);
        uint256 multiplier = uiMultiplier(stock);
        if (multiplier != 1e18) out = Math.mulDiv(out, 1e18, multiplier);
    }

    /// @notice EIP-8056 UI multiplier of `stock` (1e18 = 1.0x); 1e18 for plain ERC-20s.
    function uiMultiplier(address stock) public view returns (uint256 multiplier) {
        (bool ok, bytes memory data) = stock.staticcall(abi.encodeWithSelector(IERC8056.uiMultiplier.selector));
        if (ok && data.length == 32) {
            multiplier = abi.decode(data, (uint256));
            require(multiplier > 0, unicode"Zero UI multiplier / UI 乘数为零");
        } else {
            multiplier = 1e18;
        }
    }

    /// @notice Expected stock output at the time-weighted average price of every V2 pair along the
    ///         registered path, net of the V2 swap fee per hop. For each hop the newest factory
    ///         checkpoint that is at least `MIN_TWAP_WINDOW` old (and at most `MAX_TWAP_WINDOW`) is used.
    function twapOut(IStonksPadVaultFactory f, IStonksPadVaultFactory.StockInfo memory info, uint256 amountIn)
        public
        view
        returns (uint256 out)
    {
        require(
            info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV2,
            unicode"TWAP requires a V2 path / TWAP 需要 V2 路径"
        );
        address[] memory path = abi.decode(info.path, (address[]));
        IPancakeV2Factory v2Factory = IPancakeV2Factory(f.pancakeV2Factory());
        out = amountIn;
        for (uint256 i = 0; i + 1 < path.length; i++) {
            address pair = v2Factory.getPair(path[i], path[i + 1]);
            require(pair != address(0), unicode"Pair not found / 交易对不存在");
            (uint256 p0, uint256 p1, uint32 nowTs) = PancakeV2Twap.currentCumulativePrices(pair);
            IStonksPadVaultFactory.TwapObs memory obs = _pickObservation(f, pair, nowTs);
            out = PancakeV2Twap.consult(pair, path[i], out, obs, p0, p1, nowTs) * (BPS - V2_FEE_BPS) / BPS;
        }
    }

    /// @notice Expected stock output at the 30-minute time-weighted average tick of every V3 pool
    ///         along the registered packed path, net of each pool's fee. Reads the pools' own
    ///         oracle (`observe`), so no factory checkpoints are involved; a pool with too little
    ///         observation history makes the call revert (increase its cardinality first).
    function twapV3Out(IStonksPadVaultFactory f, IStonksPadVaultFactory.StockInfo memory info, uint256 amountIn)
        public
        view
        returns (uint256 out)
    {
        require(
            info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV3,
            unicode"TWAP V3 requires a V3 path / TWAP V3 需要 V3 路径"
        );
        IPancakeV3Factory v3Factory = IPancakeV3Factory(f.pancakeV3Factory());
        uint256 hops = PancakeV3Twap.hopCount(info.path);
        out = amountIn;
        for (uint256 i = 0; i < hops; i++) {
            (address tokenIn, uint24 fee, address tokenOut) = PancakeV3Twap.hop(info.path, i);
            address pool = v3Factory.getPool(tokenIn, tokenOut, fee);
            require(pool != address(0), unicode"Pool not found / 池不存在");
            int24 tick = PancakeV3Twap.consult(pool, PancakeV3Twap.TWAP_V3_WINDOW);
            out = PancakeV3Twap.quoteAtTick(tick, out, tokenIn, IPancakeV3Pool(pool).token0());
            out = out * (PancakeV3Twap.FEE_DENOMINATOR - fee) / PancakeV3Twap.FEE_DENOMINATOR;
        }
    }

    /// @notice Reverts unless every V3 pool along `path` exists and its oracle answers a
    ///         30-minute `observe` (used by the factory at TwapV3 registration).
    function checkV3TwapReady(address v3Factory, bytes memory path) external view {
        uint256 hops = PancakeV3Twap.hopCount(path);
        for (uint256 i = 0; i < hops; i++) {
            (address tokenIn, uint24 fee, address tokenOut) = PancakeV3Twap.hop(path, i);
            address pool = IPancakeV3Factory(v3Factory).getPool(tokenIn, tokenOut, fee);
            require(pool != address(0), unicode"Pool not found / 池不存在");
            require(IPancakeV3Pool(pool).liquidity() > 0, unicode"Pool has no liquidity / 池没有流动性");
            PancakeV3Twap.consult(pool, PancakeV3Twap.TWAP_V3_WINDOW);
        }
    }

    /// @notice Calls `increaseObservationCardinalityNext` on every V3 pool along `path`.
    function increaseV3Cardinality(address v3Factory, bytes memory path, uint16 cardinalityNext) external {
        uint256 hops = PancakeV3Twap.hopCount(path);
        for (uint256 i = 0; i < hops; i++) {
            (address tokenIn, uint24 fee, address tokenOut) = PancakeV3Twap.hop(path, i);
            address pool = IPancakeV3Factory(v3Factory).getPool(tokenIn, tokenOut, fee);
            require(pool != address(0), unicode"Pool not found / 池不存在");
            IPancakeV3Pool(pool).increaseObservationCardinalityNext(cardinalityNext);
        }
    }

    /// @dev Newest checkpoint whose age is within [MIN_TWAP_WINDOW, MAX_TWAP_WINDOW].
    function _pickObservation(IStonksPadVaultFactory f, address pair, uint32 nowTs)
        internal
        view
        returns (IStonksPadVaultFactory.TwapObs memory obs)
    {
        (IStonksPadVaultFactory.TwapObs memory latest, IStonksPadVaultFactory.TwapObs memory previous) =
            f.twapObservations(pair);
        obs = latest;
        if (obs.timestamp == 0 || PancakeV2Twap.age(obs, nowTs) < PancakeV2Twap.MIN_TWAP_WINDOW) {
            obs = previous;
        }
        require(obs.timestamp != 0, unicode"TWAP observation missing / 缺少 TWAP 观测");
        uint32 obsAge = PancakeV2Twap.age(obs, nowTs);
        require(
            obsAge >= PancakeV2Twap.MIN_TWAP_WINDOW && obsAge <= PancakeV2Twap.MAX_TWAP_WINDOW,
            unicode"TWAP observation out of window / TWAP 观测超出窗口"
        );
    }

    /// @notice Reads a Chainlink feed and rejects non-positive or stale answers.
    function readFeed(address feed, uint256 staleness) public view returns (uint256 price, uint8 dec) {
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        require(answer > 0, unicode"Invalid oracle price / 预言机价格无效");
        require(
            updatedAt <= block.timestamp && block.timestamp - updatedAt <= staleness,
            unicode"Stale oracle price / 预言机价格过期"
        );
        price = uint256(answer);
        dec = IChainlinkFeed(feed).decimals();
    }
}
