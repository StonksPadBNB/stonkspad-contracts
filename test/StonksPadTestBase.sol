// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {FlapBSCFixture} from "./FlapBSCFixture.sol";

import {StonksPadVault} from "../src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "../src/StonksPadVaultFactory.sol";
import {AllocationRow} from "../src/StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "../src/interfaces/IStonksPadVaultFactory.sol";
import {IPancakeV2Router, IPancakeV3QuoterV2} from "../src/interfaces/IPancake.sol";

/// @title StonksPadTestBase
/// @notice Addresses, actors and helpers shared by the fork suites of both launch paths. The helpers were
///         moved here unchanged from `StonksPadVaultV11.mainnet.t.sol`; the only addition is
///         `_launcherAddr()`, the caller of `factory.newVault()` (Flap: VaultPortal).
abstract contract StonksPadTestBase is FlapBSCFixture {
    // ── DEX / tokens ──────────────────────────────────────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant PANCAKE_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant STONKS = 0xc9d825E83AadA475bD4d38C8ca984eD746277777;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant CAKE_USD_FEED = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    address internal ADMIN = makeAddr("stonkspad:v11:admin");
    address internal KEEPER = makeAddr("stonkspad:v11:keeper");
    address internal VERIFIER = makeAddr("stonkspad:v11:verifier");
    address internal TREASURY = makeAddr("stonkspad:v11:treasury");
    address internal ROUTE_A = makeAddr("stonkspad:v11:routeA");
    address internal HOLDER = makeAddr("stonkspad:v11:holder");
    address internal USER = makeAddr("stonkspad:v11:user");

    StonksPadVaultFactory internal factory;
    StonksPadVault internal vault;

    /// @dev The contract allowed to call `factory.newVault()` on the launch path under test.
    function _launcherAddr() internal view virtual returns (address) {
        return VAULT_PORTAL;
    }

    /// @dev Sets the verifier and waits out its 24h activation time-lock.
    function _activateVerifier(StonksPadVault v) internal {
        vm.prank(ADMIN);
        v.setVerifier(VERIFIER);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
    }

    function _rootOf(uint256 epochId, address[] memory stocks, uint256[] memory amounts)
        internal
        view
        returns (bytes32)
    {
        return _leaf(epochId, HOLDER, stocks, amounts);
    }

    /* ========== helpers ========== */

    function _newVault(address stockA, address stockB) internal returns (StonksPadVault v) {
        AllocationRow[] memory rows = new AllocationRow[](stockB == address(0) ? 2 : 3);
        rows[0] = AllocationRow(ROUTE_A, 5000, false, 0);
        if (stockB == address(0)) {
            rows[1] = AllocationRow(stockA, 5000, true, 0);
        } else {
            rows[1] = AllocationRow(stockA, 2500, true, 0);
            rows[2] = AllocationRow(stockB, 2500, true, 0);
        }
        vm.prank(_launcherAddr());
        v = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
    }

    function _fund(StonksPadVault v, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(v).call{value: amount}("");
        assertTrue(ok, "fund failed");
    }

    /// @dev Mirrors `_opsCap`: min(per-call cap, today's remainder, 5% of the pool).
    function _opsCap(StonksPadVault v, uint256 pool) internal view returns (uint256 cap) {
        (, uint256 today, uint256 perCall, uint256 perDay,) = v.opsReserve();
        if (perCall == 0) return 0;
        cap = perCall;
        uint256 dayLeft = perDay > today ? perDay - today : 0;
        if (dayLeft < cap) cap = dayLeft;
        if (pool * 500 / 10000 < cap) cap = pool * 500 / 10000;
    }

    function _expectedSpend(StonksPadVault v) internal view returns (uint256 spend) {
        uint256 available = v.stockPoolAvailable();
        available -= _opsCap(v, available);
        spend = available < v.maxSpendPerBuy() ? available : v.maxSpendPerBuy();
    }

    /// @dev Keeper-side quote: 97% of the on-chain quote for each enabled stock.
    function _minOuts(StonksPadVault v) internal returns (uint256[] memory minOuts) {
        uint256 spend = _expectedSpend(v);
        StonksPadVault.StockView[] memory stocks = v.getStocks();
        uint256 weight;
        uint256 lastEnabled;
        for (uint256 i = 0; i < stocks.length; i++) {
            if (stocks[i].enabled) {
                weight += stocks[i].bps;
                lastEnabled = i;
            }
        }
        minOuts = new uint256[](stocks.length);
        uint256 allocated;
        for (uint256 i = 0; i < stocks.length; i++) {
            if (!stocks[i].enabled) continue;
            uint256 amountIn = i == lastEnabled ? spend - allocated : spend * stocks[i].bps / weight;
            allocated += amountIn;
            IStonksPadVaultFactory.StockInfo memory info = factory.getStock(stocks[i].token);
            uint256 quoted;
            if (info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV2) {
                uint256[] memory amounts =
                    IPancakeV2Router(PANCAKE_V2_ROUTER).getAmountsOut(amountIn, abi.decode(info.path, (address[])));
                quoted = amounts[amounts.length - 1];
            } else {
                (quoted,,,) = IPancakeV3QuoterV2(PANCAKE_V3_QUOTER).quoteExactInput(info.path, amountIn);
            }
            minOuts[i] = quoted * 9700 / 10000;
        }
    }

    function _buy(StonksPadVault v) internal {
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256[] memory minOuts = _minOuts(v);
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    function _leaf(uint256 epochId, address account, address[] memory stocks, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, stocks, amounts))));
    }

    /// @dev Buys stocks and publishes a single-leaf epoch for HOLDER (all USDT bought so far).
    function _publishUsdtEpoch(StonksPadVault v, bool withSnapshot)
        internal
        returns (uint256 epochId, address[] memory stocks, uint256[] memory amounts)
    {
        stocks = new address[](1);
        stocks[0] = USDT;
        amounts = new uint256[](1);
        amounts[0] = v.stockUndistributed(USDT);
        assertGt(amounts[0], 0, "nothing to distribute");
        epochId = v.epochCount() + 1;
        bytes32 root = _leaf(epochId, HOLDER, stocks, amounts);
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        if (withSnapshot) v.publishDistribution(root, stocks, amounts, "ipfs://snapshot", uint64(block.number - 3));
        else v.publishDistribution(root, stocks, amounts, "ipfs://snapshot");
    }

    function _claimData(address[] memory stocks, uint256[] memory amounts) internal pure returns (bytes memory) {
        return abi.encode(stocks, amounts, new bytes32[](0));
    }
}
