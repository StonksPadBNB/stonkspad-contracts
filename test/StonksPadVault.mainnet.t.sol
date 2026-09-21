// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {VaultUISchema, VaultDataSchema, FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";

import {StonksPadVault} from "../src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "../src/StonksPadVaultFactory.sol";
import {StonksPadTreasury} from "../src/StonksPadTreasury.sol";
import {AllocationRow, FeeRouteInit, StockAlloc} from "../src/StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "../src/interfaces/IStonksPadVaultFactory.sol";
import {
    IPancakeV2Router,
    IPancakeV3QuoterV2,
    IPancakeV3SmartRouter,
    IPancakeV3Pool
} from "../src/interfaces/IPancake.sol";
import {PancakeV2Twap} from "../src/libs/PancakeV2Twap.sol";
import {PancakeV3Twap} from "../src/libs/PancakeV3Twap.sol";
import {TickMath} from "../src/libs/TickMath.sol";
import {StonksPadSwapLib} from "../src/StonksPadSwapLib.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Configurable Chainlink-style feed used to exercise the oracle floor deterministically.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

interface IWBNBLike {
    function deposit() external payable;
}

/// @dev Minimal EIP-8056 token stub: only what the Chainlink floor reads.
contract MockScaledToken {
    uint256 public uiMultiplier;
    uint8 public constant decimals = 18;

    constructor(uint256 multiplier_) {
        uiMultiplier = multiplier_;
    }
}

/// @dev Recipient contract that rejects native transfers (used to test claimFees failure rollback).
contract RejectingRecipient {
    receive() external payable {
        revert("reject");
    }

    function claim(address vault) external {
        StonksPadVault(payable(vault)).claimFees();
    }
}

/// @title StonksPadVault mainnet-fork integration tests
/// @notice Run with: forge test --fork-url https://bsc-dataseed.bnbchain.org -vv
/// @dev USDT (PancakeSwap V2 path) and CAKE (PancakeSwap V3 path) stand in for tokenized stock
///      tokens; the vault logic is token-agnostic.
contract StonksPadVaultMainnetTest is FlapBSCFixture {
    // ── BSC mainnet DEX addresses ─────────────────────────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant PANCAKE_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    // STONKS (Flap token) and its PancakeSwap V2 quote token QQQB
    address internal constant STONKS = 0xc9d825E83AadA475bD4d38C8ca984eD746277777;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // bStocks (EIP-8056) tokenized stocks: SpaceX (V3-only liquidity) and Apple (registered, multiplier > 1)
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    // Chainlink feeds (BSC mainnet)
    address internal constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant CAKE_USD_FEED = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    // ── actors ────────────────────────────────────────────────────────────
    address internal ADMIN = makeAddr("stonkspad:platformAdmin");
    address internal KEEPER = makeAddr("stonkspad:keeper");
    address internal TREASURY = makeAddr("stonkspad:treasury");
    address internal ROUTE_A = makeAddr("stonkspad:routeA");
    address internal ROUTE_B = makeAddr("stonkspad:routeB");
    address internal HOLDER_1 = makeAddr("stonkspad:holder1");
    address internal HOLDER_2 = makeAddr("stonkspad:holder2");
    address internal USER = makeAddr("stonkspad:user");
    address internal WHALE = makeAddr("stonkspad:whale");
    address internal NFT_WALLET = makeAddr("stonkspad:nftWallet");
    address internal PLATFORM_WALLET = makeAddr("stonkspad:platformWallet");

    uint16 internal constant ROUTE_A_BPS = 3000;
    uint16 internal constant ROUTE_B_BPS = 2000;
    uint16 internal constant USDT_BPS = 2500;
    uint16 internal constant CAKE_BPS = 2500;

    StonksPadVaultFactory internal factory;
    StonksPadTreasury internal treasury;
    StonksPadVault internal vault;
    address internal token;
    bytes internal vaultData;

    function setUp() public {
        _forkBSCMainnet();

        // deploy order mirrors the deploy scripts: impl → beacon → transferOwnership(Guardian) → factory
        StonksPadVault impl = new StonksPadVault();
        UpgradeableBeacon beaconInst = new UpgradeableBeacon(address(impl));
        beaconInst.transferOwnership(FLAP_GUARDIAN);
        factory = new StonksPadVaultFactory(
            address(beaconInst),
            WBNB,
            PANCAKE_V2_ROUTER,
            PANCAKE_V3_ROUTER,
            PANCAKE_V3_QUOTER,
            BNB_USD_FEED,
            ADMIN,
            KEEPER,
            TREASURY
        );
        vm.label(address(factory), "StonksPadVaultFactory");

        address[] memory v2Path = new address[](2);
        v2Path[0] = WBNB;
        v2Path[1] = USDT;
        vm.startPrank(ADMIN);
        factory.registerStock(
            USDT,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(v2Path),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            USDT_USD_FEED,
            true
        );
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            abi.encodePacked(WBNB, uint24(2500), CAKE),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            CAKE_USD_FEED,
            true
        );
        factory.registerStock(
            STONKS,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(_stonksPath()),
            IStonksPadVaultFactory.OracleMode.TwapV2,
            address(0),
            true
        );
        vm.stopPrank();

        treasury = new StonksPadTreasury(address(factory), STONKS, NFT_WALLET, PLATFORM_WALLET);
        vm.label(address(treasury), "StonksPadTreasury");

        vaultData = _defaultVaultData();

        bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
            _buildV3TaxTokenParams("Stonks Test", "STNK", salt, address(factory), vaultData);
        token = vaultPortal.newTokenV6WithVault{value: params.quoteAmt}(params);
        vm.label(token, "STNK");

        vault = StonksPadVault(payable(vaultPortal.getVault(token).vault));
        vm.label(address(vault), "StonksPadVault");

        vm.deal(USER, 100 ether);
        vm.deal(WHALE, 500 ether);
        vm.deal(KEEPER, 10 ether);
    }

    /* ========== helpers ========== */

    function _defaultVaultData() internal view returns (bytes memory) {
        AllocationRow[] memory rows = new AllocationRow[](4);
        rows[0] = AllocationRow(ROUTE_A, ROUTE_A_BPS, false, 0);
        rows[1] = AllocationRow(ROUTE_B, ROUTE_B_BPS, false, 0);
        rows[2] = AllocationRow(USDT, USDT_BPS, true, 0);
        rows[3] = AllocationRow(CAKE, CAKE_BPS, true, 0);
        return abi.encode(rows);
    }

    function _stonksPath() internal pure returns (address[] memory p) {
        p = new address[](3);
        p[0] = WBNB;
        p[1] = QQQB;
        p[2] = STONKS;
    }

    /// @dev Sends BNB straight into the vault's receive() (simulates a TaxProcessor dispatch).
    function _fund(uint256 amount) internal {
        _fundVault(vault, amount);
    }

    function _fundVault(StonksPadVault v, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(v).call{value: amount}("");
        assertTrue(ok, "fund failed");
    }

    /// @dev Creates a vault directly through the factory (as the VaultPortal) with a STONKS stock row.
    function _newStonksVault(uint16 stonksBps, uint256 minHolding_) internal returns (StonksPadVault v) {
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, 10000 - stonksBps, false, minHolding_);
        rows[1] = AllocationRow(STONKS, stonksBps, true, minHolding_);
        vm.prank(VAULT_PORTAL);
        v = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
    }

    /// @dev Pushes the STONKS spot price up by buying with `bnb` through the registered path.
    function _pumpStonks(uint256 bnb) internal {
        vm.deal(WHALE, WHALE.balance + bnb);
        vm.startPrank(WHALE);
        IWBNBLike(WBNB).deposit{value: bnb}();
        IERC20(WBNB).approve(PANCAKE_V2_ROUTER, bnb);
        IPancakeV2Router(PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                bnb, 0, _stonksPath(), WHALE, vm.getBlockTimestamp() + 60
            );
        vm.stopPrank();
    }

    /// @dev Buys on the bonding curve until the token graduates to the DEX.
    function _graduate() internal {
        vm.startPrank(WHALE);
        for (uint256 i = 0; i < 80; i++) {
            if (portal.getTokenV8(token).status == IPortalTypes.TokenStatus.DEX) break;
            _buyOnBC(token, 3 ether);
        }
        vm.stopPrank();
        assertTrue(portal.getTokenV8(token).status == IPortalTypes.TokenStatus.DEX, "token did not graduate");
    }

    /// @dev Computes keeper minOuts as 97% of the on-chain quote for the next buyStocks() call.
    function _quoteMinOuts() internal returns (uint256[] memory minOuts) {
        return _quoteMinOutsFor(vault);
    }

    function _quoteMinOutsFor(StonksPadVault v) internal returns (uint256[] memory minOuts) {
        uint256 available = v.stockPoolAvailable();
        uint256 spend = available < v.maxSpendPerBuy() ? available : v.maxSpendPerBuy();
        StonksPadVault.StockView[] memory stocks = v.getStocks();
        uint256 weight;
        for (uint256 i = 0; i < stocks.length; i++) {
            if (stocks[i].enabled) weight += stocks[i].bps;
        }
        minOuts = new uint256[](stocks.length);
        uint256 allocated;
        uint256 lastEnabled;
        for (uint256 i = 0; i < stocks.length; i++) {
            if (stocks[i].enabled) lastEnabled = i;
        }
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

    function _leaf(uint256 epochId, address account, address[] memory stocks, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, stocks, amounts))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _twoStocks() internal pure returns (address[] memory s) {
        s = new address[](2);
        s[0] = USDT;
        s[1] = CAKE;
    }

    /// @dev Funds the vault, buys stocks as keeper, and returns the bought amounts.
    function _fundAndBuy() internal returns (uint256 usdtBought, uint256 cakeBought) {
        _fund(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256[] memory minOuts = _quoteMinOuts();
        vm.startPrank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        vm.stopPrank();
        usdtBought = vault.stockUndistributed(USDT);
        cakeBought = vault.stockUndistributed(CAKE);
    }

    function _assertEpochMeta(uint256 epochId, bytes32 expectedRoot, string memory expectedCid) internal view {
        (bytes32 r, uint64 at, uint64 opensAt, bool cancelled, string memory cid) = vault.getEpoch(epochId);
        assertEq(r, expectedRoot);
        assertEq(at, uint64(vm.getBlockTimestamp()));
        assertEq(opensAt, uint64(vm.getBlockTimestamp() + 24 hours));
        assertFalse(cancelled);
        assertEq(cid, expectedCid);
        assertEq(vault.epochStocks(epochId).length, 2);
    }

    /* ========== 1–2: deploy & wiring ========== */

    function test_factoryDeploysVaultOnLaunch() public view {
        assertTrue(address(vault) != address(0), "vault not created");
        assertTrue(factory.isVault(address(vault)), "factory should track vault");
        assertEq(factory.vaultCount(), 1);
        assertEq(vault.factory(), address(factory));
        assertEq(vault.taxToken(), token);
        assertEq(vault.creator(), address(this));
        assertEq(vault.platformFeeBps(), 1000);
        assertEq(vault.stockPoolBps(), USDT_BPS + CAKE_BPS);
        assertEq(vault.feeRouteCount(), 2);
        assertEq(vault.stockCount(), 2);
        assertEq(vault.maxSlippageBps(), 300);
        assertEq(vault.maxSpendPerBuy(), 5 ether);
    }

    function test_vaultWiredAsTaxProcessorMarketAddress() public view {
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        assertEq(ITaxProcessor(taxProcessor).marketAddress(), address(vault), "vault should be market address");
    }

    /* ========== 3: buy on bonding curve → dispatch ========== */

    function test_buyOnBCAndDispatch() public {
        vm.startPrank(USER);
        _buyOnBC(token, 1 ether);
        vm.stopPrank();

        uint256 pending = _pendingMarketBalance(token);
        assertGt(pending, 0, "tax should accumulate for the vault");

        _dispatchTax(token);

        assertEq(vault.totalReceived(), pending, "vault should receive the market share");
        assertEq(address(vault).balance, pending);
        uint256 fee = pending * 1000 / 10000;
        assertEq(vault.platformAccrued(), fee);
        uint256 net = pending - fee;
        assertEq(vault.totalNet(), net);
        assertEq(vault.claimableFees(ROUTE_A), net * ROUTE_A_BPS / 10000);
        assertEq(vault.claimableFees(ROUTE_B), net * ROUTE_B_BPS / 10000);
        assertEq(vault.stockPoolAvailable(), net * (USDT_BPS + CAKE_BPS) / 10000);
    }

    /* ========== 4: graduate → sell → dispatch ========== */

    function test_graduateSellAndDispatch() public {
        _graduate();
        _dispatchTax(token);
        uint256 receivedBefore = vault.totalReceived();
        assertGt(receivedBefore, 0, "curve-phase tax should have reached the vault");

        uint256 bal = IERC20(token).balanceOf(WHALE);
        assertGt(bal, 0);
        vm.startPrank(WHALE);
        _sell(token, bal / 2);
        vm.stopPrank();

        uint256 pending = _pendingMarketBalance(token);
        _dispatchTax(token);
        assertEq(vault.totalReceived(), receivedBefore + pending, "sell tax should reach the vault after DEX");
        assertEq(address(vault).balance, vault.totalReceived());
    }

    /* ========== receive() ========== */

    function test_receiveGasUnder1M() public {
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok, "receive() should not revert");
        assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
        assertLt(gasUsed, 120_000, "receive() should be cheap");
    }

    function test_receiveZeroValueIsNoOp() public {
        (bool ok,) = address(vault).call{value: 0}("");
        assertTrue(ok);
        assertEq(vault.totalReceived(), 0);
    }

    function test_receiveWithinDispatchGasBudget() public {
        // the fixture dispatches with a 1M gas cap for the whole TaxProcessor fan-out
        vm.startPrank(USER);
        _buyOnBC(token, 0.5 ether);
        vm.stopPrank();
        _dispatchTax(token);
        assertGt(vault.totalReceived(), 0);
    }

    /* ========== 5–6: claimFees ========== */

    function test_claimFees_HappyPath() public {
        _fund(10 ether);
        uint256 net = 9 ether;
        uint256 expected = net * ROUTE_A_BPS / 10000;

        uint256 before = ROUTE_A.balance;
        vm.startPrank(ROUTE_A);
        vault.claimFees();
        vm.stopPrank();
        assertEq(ROUTE_A.balance - before, expected);
        assertEq(vault.claimableFees(ROUTE_A), 0);

        // new revenue accrues again
        _fund(1 ether);
        assertEq(vault.claimableFees(ROUTE_A), uint256(0.9 ether) * ROUTE_A_BPS / 10000);
    }

    function test_claimFees_RevertPaths() public {
        vm.expectRevert(bytes(unicode"Not a fee recipient / 非手续费接收者"));
        vm.prank(USER);
        vault.claimFees();

        vm.expectRevert(bytes(unicode"Nothing to claim / 无可领取金额"));
        vm.prank(ROUTE_A);
        vault.claimFees();

        _fund(1 ether);
        vm.prank(ROUTE_A);
        vault.claimFees();
        vm.expectRevert(bytes(unicode"Nothing to claim / 无可领取金额"));
        vm.prank(ROUTE_A);
        vault.claimFees();
    }

    function test_claimFees_RevertsWhenRecipientRejectsAndRollsBack() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        AllocationRow[] memory rows = new AllocationRow[](1);
        rows[0] = AllocationRow(address(rejecting), 10000, false, 0);
        vm.prank(VAULT_PORTAL);
        StonksPadVault v =
            StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectRevert(bytes(unicode"Transfer failed / 转账失败"));
        rejecting.claim(address(v));
        assertEq(v.claimableFees(address(rejecting)), 0.9 ether, "failed claim must not consume the balance");
    }

    /* ========== withdrawPlatformFee ========== */

    function test_withdrawPlatformFee() public {
        _fund(10 ether);
        uint256 before = TREASURY.balance;
        vm.prank(USER);
        vault.withdrawPlatformFee();
        assertEq(TREASURY.balance - before, 1 ether);
        assertEq(vault.platformAccrued(), 0);

        vm.expectRevert(bytes(unicode"Nothing to withdraw / 无可提取金额"));
        vault.withdrawPlatformFee();

        // treasury change applies immediately to withdrawals
        address newTreasury = makeAddr("stonkspad:newTreasury");
        vm.prank(ADMIN);
        factory.setPlatformTreasury(newTreasury);
        _fund(1 ether);
        vault.withdrawPlatformFee();
        assertEq(newTreasury.balance, 0.1 ether);
    }

    /* ========== buyStocks ========== */

    function test_buyStocks_HappyPath() public {
        (uint256 usdtBought, uint256 cakeBought) = _fundAndBuy();

        assertGt(usdtBought, 0, "USDT should be bought via V2");
        assertGt(cakeBought, 0, "CAKE should be bought via V3");
        assertEq(IERC20(USDT).balanceOf(address(vault)), usdtBought);
        assertEq(IERC20(CAKE).balanceOf(address(vault)), cakeBought);
        // pool = 9 BNB net * 50% = 4.5 BNB, below the 5 BNB cap → whole pool is spent
        assertEq(vault.stockSpent(), 4.5 ether);
        assertEq(vault.stockPoolAvailable(), 0);
        assertEq(vault.buyCount(), 1);
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0, "no WBNB dust");
    }

    function test_buyStocks_SpendIsMinOfPoolAndCap() public {
        _fund(10 ether); // net 9 → pool 4.5 BNB
        uint256[] memory minOuts = _quoteMinOuts();
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(vault.stockSpent(), 4.5 ether);
        assertEq(vault.stockPoolAvailable(), 0);

        _fund(40 ether); // pool += 18 BNB → cap applies
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        minOuts = _quoteMinOuts();
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(vault.stockSpent(), 9.5 ether);
        assertEq(vault.stockPoolAvailable(), 13 ether);
        // fee routes and platform are untouched by stock purchases
        assertEq(vault.claimableFees(ROUTE_A), uint256(45 ether) * ROUTE_A_BPS / 10000);
        assertEq(vault.platformAccrued(), 5 ether);
    }

    function test_buyStocks_Gating() public {
        _fund(10 ether);
        uint256[] memory minOuts = _quoteMinOuts();

        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vm.prank(USER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        vm.expectRevert(bytes(unicode"Deadline passed / 已超过截止时间"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() - 1);

        uint256[] memory wrongLen = new uint256[](1);
        vm.expectRevert(bytes(unicode"minOuts length mismatch / minOuts 长度不匹配"));
        vm.prank(KEEPER);
        vault.buyStocks(wrongLen, vm.getBlockTimestamp() + 300);

        uint256[] memory tooLow = new uint256[](2);
        tooLow[0] = minOuts[0] / 2; // below the 97% floor
        tooLow[1] = minOuts[1];
        vm.expectRevert(bytes(unicode"minOut below slippage floor / minOut 低于滑点下限"));
        vm.prank(KEEPER);
        vault.buyStocks(tooLow, vm.getBlockTimestamp() + 300);

        uint256[] memory zero = new uint256[](2);
        vm.expectRevert(bytes(unicode"minOut must be > 0 / minOut 必须大于 0"));
        vm.prank(KEEPER);
        vault.buyStocks(zero, vm.getBlockTimestamp() + 300);

        // impossible minOut (above quote) → swap output check fails
        uint256[] memory tooHigh = new uint256[](2);
        tooHigh[0] = minOuts[0] * 2;
        tooHigh[1] = minOuts[1];
        vm.expectRevert();
        vm.prank(KEEPER);
        vault.buyStocks(tooHigh, vm.getBlockTimestamp() + 300);
    }

    function test_buyStocks_NothingToBuyReverts() public {
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1;
        minOuts[1] = 1;
        vm.expectRevert(bytes(unicode"Nothing to buy / 无可用资金"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    function test_buyStocks_DisabledStockIsSkipped() public {
        vm.prank(ADMIN);
        factory.setStockEnabled(CAKE, false);

        _fund(10 ether);
        uint256[] memory minOuts = _quoteMinOuts();
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        assertGt(vault.stockUndistributed(USDT), 0);
        assertEq(vault.stockUndistributed(CAKE), 0, "disabled stock must be skipped");
        assertEq(vault.stockSpent(), 4.5 ether, "whole spend goes to the enabled stock");

        vm.prank(ADMIN);
        factory.setStockEnabled(USDT, false);
        _fund(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(bytes(unicode"No enabled stocks / 无可用股票"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    function test_setMaxSlippageAndSpend() public {
        vm.prank(KEEPER);
        vault.setMaxSlippageBps(500);
        assertEq(vault.maxSlippageBps(), 500);

        vm.expectRevert(bytes(unicode"Slippage above hard cap / 滑点超过上限"));
        vm.prank(KEEPER);
        vault.setMaxSlippageBps(501);

        vm.prank(KEEPER);
        vault.setMaxSpendPerBuy(1 ether);
        assertEq(vault.maxSpendPerBuy(), 1 ether);

        vm.expectRevert(bytes(unicode"Spend out of bounds / 金额超出范围"));
        vm.prank(KEEPER);
        vault.setMaxSpendPerBuy(0.05 ether);
        vm.expectRevert(bytes(unicode"Spend out of bounds / 金额超出范围"));
        vm.prank(KEEPER);
        vault.setMaxSpendPerBuy(21 ether);

        vm.prank(ADMIN);
        vault.setMaxOracleDeviationBps(1000);
        assertEq(vault.maxOracleDeviationBps(), 1000);
        vm.expectRevert(bytes(unicode"Deviation above hard cap / 偏差超过上限"));
        vm.prank(ADMIN);
        vault.setMaxOracleDeviationBps(1001);
        // the keeper (executor) cannot widen its own oracle band
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vm.prank(KEEPER);
        vault.setMaxOracleDeviationBps(100);

        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vm.prank(USER);
        vault.setMaxSlippageBps(100);
    }

    /* ========== publishDistribution + claimStocks ========== */

    function test_publishDistributionAndClaimStocks() public {
        (uint256 usdtBought, uint256 cakeBought) = _fundAndBuy();

        // holder1 gets 60%, holder2 gets 40%
        address[] memory stocks = _twoStocks();
        uint256[] memory a1 = new uint256[](2);
        a1[0] = usdtBought * 60 / 100;
        a1[1] = cakeBought * 60 / 100;
        uint256[] memory a2 = new uint256[](2);
        a2[0] = usdtBought - a1[0];
        a2[1] = cakeBought - a1[1];

        uint256 epochId = 1;
        bytes32 l1 = _leaf(epochId, HOLDER_1, stocks, a1);
        bytes32 l2 = _leaf(epochId, HOLDER_2, stocks, a2);
        bytes32 root = _hashPair(l1, l2);

        uint256[] memory totals = new uint256[](2);
        totals[0] = usdtBought;
        totals[1] = cakeBought;

        vm.prank(KEEPER);
        vault.publishDistribution(root, stocks, totals, "ipfs://snapshot-1");
        assertEq(vault.epochCount(), 1);
        _assertEpochMeta(1, root, "ipfs://snapshot-1");
        assertEq(vault.stockUndistributed(USDT), 0);
        assertEq(vault.stockUndistributed(CAKE), 0);
        assertEq(vault.epochRemaining(1, USDT), usdtBought);

        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l2;
        // claims are gated by the 24h veto window
        vm.expectRevert(bytes(unicode"Claims not open yet / 领取尚未开放"));
        vm.prank(HOLDER_1);
        vault.claimStocks(1, abi.encode(stocks, a1, p1));
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        vm.prank(HOLDER_1);
        vault.claimStocks(1, abi.encode(stocks, a1, p1));
        assertEq(IERC20(USDT).balanceOf(HOLDER_1), a1[0]);
        assertEq(IERC20(CAKE).balanceOf(HOLDER_1), a1[1]);
        assertTrue(vault.hasClaimed(1, HOLDER_1));
        assertEq(vault.epochRemaining(1, USDT), a2[0]);

        vm.expectRevert(bytes(unicode"Already claimed / 已经领取过"));
        vm.prank(HOLDER_1);
        vault.claimStocks(1, abi.encode(stocks, a1, p1));

        bytes32[] memory p2 = new bytes32[](1);
        p2[0] = l1;
        // wrong amounts → invalid proof
        vm.expectRevert(bytes(unicode"Invalid proof / 证明无效"));
        vm.prank(HOLDER_2);
        vault.claimStocks(1, abi.encode(stocks, a1, p2));
        // wrong caller → invalid proof
        vm.expectRevert(bytes(unicode"Invalid proof / 证明无效"));
        vm.prank(USER);
        vault.claimStocks(1, abi.encode(stocks, a2, p2));
        // unknown epoch
        vm.expectRevert(bytes(unicode"Unknown epoch / 未知的分配期"));
        vm.prank(HOLDER_2);
        vault.claimStocks(2, abi.encode(stocks, a2, p2));

        vm.prank(HOLDER_2);
        vault.claimStocks(1, abi.encode(stocks, a2, p2));
        assertEq(IERC20(USDT).balanceOf(HOLDER_2), a2[0]);
        assertEq(vault.epochRemaining(1, USDT), 0);
        assertEq(vault.epochRemaining(1, CAKE), 0);
        assertEq(IERC20(USDT).balanceOf(address(vault)), 0);
    }

    function test_claimStocks_CannotExceedEpochReserve() public {
        (uint256 usdtBought,) = _fundAndBuy();

        // keeper reserves only half of the USDT for the epoch but a leaf claims all of it
        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amt = new uint256[](1);
        amt[0] = usdtBought;
        bytes32 leaf = _leaf(1, HOLDER_1, stocks, amt);
        uint256[] memory reserve = new uint256[](1);
        reserve[0] = usdtBought / 2;
        vm.prank(KEEPER);
        vault.publishDistribution(leaf, stocks, reserve, "ipfs://x");
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(bytes(unicode"Exceeds epoch reserve / 超出本期储备"));
        vm.prank(HOLDER_1);
        vault.claimStocks(1, abi.encode(stocks, amt, proof));
        // the un-reserved half is still undistributed and safe
        assertEq(vault.stockUndistributed(USDT), usdtBought - usdtBought / 2);
    }

    function test_publishDistribution_Gating() public {
        (uint256 usdtBought,) = _fundAndBuy();
        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amt = new uint256[](1);
        amt[0] = usdtBought;

        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vm.prank(USER);
        vault.publishDistribution(bytes32(uint256(1)), stocks, amt, "ipfs://x");

        vm.expectRevert(bytes(unicode"Zero root / 根哈希为零"));
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(0), stocks, amt, "ipfs://x");

        vm.expectRevert(
            bytes(unicode"Snapshot CID required (max 128 bytes) / 必须提供快照 CID（最长 128 字节）")
        );
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(uint256(1)), stocks, amt, "");

        amt[0] = usdtBought + 1;
        vm.expectRevert(bytes(unicode"Exceeds undistributed / 超出未分配数量"));
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(uint256(1)), stocks, amt, "ipfs://x");

        address[] memory dup = _twoStocks();
        dup[1] = USDT;
        uint256[] memory dupAmt = new uint256[](2);
        dupAmt[0] = 1;
        dupAmt[1] = 1;
        vm.expectRevert(bytes(unicode"Duplicate stock / 重复的股票"));
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(uint256(1)), dup, dupAmt, "ipfs://x");
    }

    function test_cancelEpoch_ReturnsReserveDuringVetoWindow() public {
        (uint256 usdtBought, uint256 cakeBought) = _fundAndBuy();
        address[] memory stocks = _twoStocks();
        uint256[] memory totals = new uint256[](2);
        totals[0] = usdtBought;
        totals[1] = cakeBought;
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(uint256(1)), stocks, totals, "ipfs://bad");
        assertEq(vault.stockUndistributed(USDT), 0);

        // keeper itself cannot veto
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vm.prank(KEEPER);
        vault.cancelEpoch(1);

        vm.prank(ADMIN);
        vault.cancelEpoch(1);
        (,,, bool cancelled,) = vault.getEpoch(1);
        assertTrue(cancelled);
        assertEq(vault.stockUndistributed(USDT), usdtBought, "reserve returned");
        assertEq(vault.stockUndistributed(CAKE), cakeBought, "reserve returned");
        assertEq(vault.epochRemaining(1, USDT), 0);

        vm.expectRevert(bytes(unicode"Epoch cancelled / 分配期已取消"));
        vm.prank(ADMIN);
        vault.cancelEpoch(1);

        // claims on a cancelled epoch revert even after the window
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(bytes(unicode"Epoch cancelled / 分配期已取消"));
        vm.prank(HOLDER_1);
        vault.claimStocks(1, abi.encode(stocks, totals, proof));

        // a corrected epoch can be published with the returned reserve; once open it cannot be cancelled
        vm.prank(KEEPER);
        vault.publishDistribution(bytes32(uint256(2)), stocks, totals, "ipfs://good");
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(bytes(unicode"Claim window already open / 领取窗口已开放"));
        vm.prank(FLAP_GUARDIAN);
        vault.cancelEpoch(2);
        vm.expectRevert(bytes(unicode"Unknown epoch / 未知的分配期"));
        vm.prank(FLAP_GUARDIAN);
        vault.cancelEpoch(3);
    }

    function test_buyStocks_IntervalEnforced() public {
        _fund(40 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256[] memory minOuts = _quoteMinOuts();
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(vault.lastBuyAt(), vm.getBlockTimestamp());

        minOuts = _quoteMinOuts();
        vm.expectRevert(bytes(unicode"Buy interval not elapsed / 买入间隔未到"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(vault.buyCount(), 2);
    }

    function test_buyStocks_OracleFloorBlocksOverpricedExecution() public {
        // USDT feed says $0.50 → the oracle expects twice as much USDT per BNB as the DEX gives,
        // so a DEX-quoted minOut falls below the oracle floor and the buy is rejected.
        address[] memory v2Path = new address[](2);
        v2Path[0] = WBNB;
        v2Path[1] = USDT;
        MockFeed cheap = new MockFeed(0.5e8);
        vm.prank(ADMIN);
        factory.registerStock(
            USDT,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(v2Path),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            address(cheap),
            true
        );

        _fund(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        cheap.set(0.5e8, vm.getBlockTimestamp());
        uint256[] memory minOuts = _quoteMinOuts();
        vm.expectRevert(bytes(unicode"minOut below oracle floor / minOut 低于预言机下限"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        // a feed close to the market price lets the buy through
        cheap.set(1e8, vm.getBlockTimestamp());
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertGt(vault.stockUndistributed(USDT), 0);
    }

    function test_buyStocks_StaleOracleReverts() public {
        address[] memory v2Path = new address[](2);
        v2Path[0] = WBNB;
        v2Path[1] = USDT;
        MockFeed feed = new MockFeed(1e8);
        vm.prank(ADMIN);
        factory.registerStock(
            USDT,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(v2Path),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            address(feed),
            true
        );

        _fund(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        feed.set(1e8, vm.getBlockTimestamp() - 37 hours);
        uint256[] memory minOuts = _quoteMinOuts();
        vm.expectRevert(bytes(unicode"Stale oracle price / 预言机价格过期"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        feed.set(0, vm.getBlockTimestamp());
        vm.expectRevert(bytes(unicode"Invalid oracle price / 预言机价格无效"));
        vm.prank(KEEPER);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    /* ========== Guardian access ========== */

    function test_guardianCanCallEveryPrivilegedVaultFunction() public {
        _fund(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.startPrank(FLAP_GUARDIAN);
        vault.setMaxSlippageBps(400);
        vault.setMaxOracleDeviationBps(700);
        vault.setMaxSpendPerBuy(3 ether);
        vm.stopPrank();
        uint256[] memory minOuts = _quoteMinOuts();

        vm.startPrank(FLAP_GUARDIAN);
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amt = new uint256[](1);
        amt[0] = vault.stockUndistributed(USDT);
        vault.publishDistribution(bytes32(uint256(1)), stocks, amt, "ipfs://x");
        vault.cancelEpoch(1);
        vm.stopPrank();

        assertEq(vault.maxSlippageBps(), 400);
        assertEq(vault.maxOracleDeviationBps(), 700);
        assertEq(vault.stockSpent(), 3 ether);
        assertEq(vault.epochCount(), 1);
        assertEq(vault.stockUndistributed(USDT), amt[0]);
    }

    function test_guardianCanCallEveryPrivilegedFactoryFunction() public {
        address[] memory p = new address[](2);
        p[0] = WBNB;
        p[1] = CAKE;
        vm.startPrank(FLAP_GUARDIAN);
        factory.setPlatformFeeBps(500);
        factory.setPlatformTreasury(USER);
        factory.setKeeper(USER);
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(p),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            CAKE_USD_FEED,
            true
        );
        factory.setStockEnabled(CAKE, false);
        factory.setBnbUsdFeed(BNB_USD_FEED);
        factory.setOracleStaleness(2 hours);
        factory.setMandatoryStock(STONKS);
        factory.setMandatoryStock(address(0));
        factory.setPlatformAdmin(USER);
        vm.stopPrank();
        assertEq(factory.oracleStaleness(), 2 hours);
        assertEq(factory.platformFeeBps(), 500);
        assertEq(factory.keeper(), USER);
        assertEq(factory.platformAdmin(), USER);
        assertEq(vault.keeper(), USER, "vault reads keeper live");

        // guardian access survives an admin change
        vm.prank(FLAP_GUARDIAN);
        factory.setPlatformAdmin(ADMIN);
        assertEq(factory.platformAdmin(), ADMIN);
    }

    function test_factorySettersGating() public {
        vm.startPrank(USER);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        factory.setPlatformFeeBps(1);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        factory.setKeeper(USER);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        factory.setStockEnabled(USDT, false);
        vm.stopPrank();

        vm.startPrank(ADMIN);
        vm.expectRevert(bytes(unicode"Fee above hard cap / 费用超过上限"));
        factory.setPlatformFeeBps(1201);
        factory.setPlatformFeeBps(1200);
        assertEq(factory.platformFeeBps(), 1200);
        factory.setPlatformFeeBps(1000);
        vm.expectRevert(bytes(unicode"Path must start at WBNB / 路径必须以 WBNB 开始"));
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            abi.encodePacked(CAKE, uint24(2500), WBNB),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            CAKE_USD_FEED,
            true
        );
        address[] memory bad = new address[](2);
        bad[0] = WBNB;
        bad[1] = USDT;
        vm.expectRevert(bytes(unicode"Path must end at stock / 路径必须以股票结束"));
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(bad),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            CAKE_USD_FEED,
            true
        );
        bad[1] = CAKE;
        vm.expectRevert(bytes(unicode"Zero price feed / 价格源地址为零"));
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(bad),
            IStonksPadVaultFactory.OracleMode.Chainlink,
            address(0),
            true
        );
        vm.expectRevert(bytes(unicode"Staleness out of bounds / 过期时间超出范围"));
        factory.setOracleStaleness(30 minutes);
        vm.expectRevert(bytes(unicode"Staleness out of bounds / 过期时间超出范围"));
        factory.setOracleStaleness(8 days);
        vm.expectRevert(bytes(unicode"Stock not registered / 股票未注册"));
        factory.setStockEnabled(address(0x1234), true);
        vm.stopPrank();
    }

    function test_platformFee1111_TakesTenPercentOfGross() public {
        // Flap keeps feeRate = 10% of the gross tax before forwarding; 1111 bps of the net equals
        // 10% of gross: gross 100 → vault receives 90 → platform 90 * 1111 / 10000 = 9.999 ≈ 10.
        vm.prank(ADMIN);
        factory.setPlatformFeeBps(1111);
        assertEq(factory.MAX_PLATFORM_FEE_BPS(), 1200);
        vm.prank(VAULT_PORTAL);
        StonksPadVault v = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, vaultData)));
        assertEq(v.platformFeeBps(), 1111);
        _fundVault(v, 90 ether); // what the vault sees from a 100 BNB gross tax at a 10% Flap fee
        assertEq(v.platformAccrued(), 90 ether * 1111 / 10000);
        assertApproxEqRel(v.platformAccrued(), 10 ether, 1e14, "approx 10% of gross");
        assertEq(v.totalNet(), 90 ether - v.platformAccrued());
    }

    function test_platformFeeChangeOnlyAffectsFutureVaults() public {
        vm.prank(ADMIN);
        factory.setPlatformFeeBps(500);
        assertEq(vault.platformFeeBps(), 1000, "existing vault keeps its snapshot");

        vm.prank(VAULT_PORTAL);
        StonksPadVault v2 = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, vaultData)));
        assertEq(v2.platformFeeBps(), 500);
    }

    /* ========== beacon / upgrade authority ========== */

    function test_beaconOwnedByGuardianOnly() public {
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.beacon());
        assertEq(beacon.owner(), FLAP_GUARDIAN, "beacon owner must be the Guardian");
        assertEq(factory.beaconOwner(), FLAP_GUARDIAN);

        StonksPadVault newImpl = new StonksPadVault();
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ADMIN);
        beacon.upgradeTo(address(newImpl));
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(address(factory));
        beacon.upgradeTo(address(newImpl));

        _fund(1 ether);
        vm.prank(FLAP_GUARDIAN);
        beacon.upgradeTo(address(newImpl));
        assertEq(factory.beaconImplementation(), address(newImpl));
        assertEq(vault.totalReceived(), 1 ether, "state must survive the upgrade");
        assertEq(vault.claimableFees(ROUTE_A), uint256(0.9 ether) * ROUTE_A_BPS / 10000);
    }

    function test_factoryRejectsBeaconNotOwnedByGuardian() public {
        StonksPadVault impl = new StonksPadVault();
        UpgradeableBeacon rogue = new UpgradeableBeacon(address(impl)); // owner = this test, not Guardian
        vm.expectRevert(bytes(unicode"Beacon owner must be Guardian / beacon 所有者必须是 Guardian"));
        new StonksPadVaultFactory(
            address(rogue),
            WBNB,
            PANCAKE_V2_ROUTER,
            PANCAKE_V3_ROUTER,
            PANCAKE_V3_QUOTER,
            BNB_USD_FEED,
            ADMIN,
            KEEPER,
            TREASURY
        );

        vm.expectRevert(bytes(unicode"Zero beacon / beacon 地址为零"));
        new StonksPadVaultFactory(
            address(0),
            WBNB,
            PANCAKE_V2_ROUTER,
            PANCAKE_V3_ROUTER,
            PANCAKE_V3_QUOTER,
            BNB_USD_FEED,
            ADMIN,
            KEEPER,
            TREASURY
        );

        // once ownership is handed to the Guardian the same beacon is accepted
        rogue.transferOwnership(FLAP_GUARDIAN);
        StonksPadVaultFactory ok = new StonksPadVaultFactory(
            address(rogue),
            WBNB,
            PANCAKE_V2_ROUTER,
            PANCAKE_V3_ROUTER,
            PANCAKE_V3_QUOTER,
            BNB_USD_FEED,
            ADMIN,
            KEEPER,
            TREASURY
        );
        assertEq(ok.beacon(), address(rogue));
        assertEq(ok.beaconImplementation(), address(impl));
    }

    function test_initializeLocked() public {
        FeeRouteInit[] memory r;
        StockAlloc[] memory s;
        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(address(factory), token, USER, 0, 0, r, s);
        StonksPadVault impl = StonksPadVault(payable(factory.beaconImplementation()));
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(address(factory), token, USER, 0, 0, r, s);
    }

    function test_noEmergencyFunctionsOnUpgradeableVault() public {
        (bool ok1,) = address(vault).call(abi.encodeWithSignature("emergencyWithdrawNative(address)", USER));
        assertFalse(ok1);
        (bool ok2,) =
            address(vault).call(abi.encodeWithSignature("emergencyWithdrawToken(address,address)", USDT, USER));
        assertFalse(ok2);
    }

    /* ========== factory: newVault gating & vaultData validation ========== */

    function test_newVault_OnlyVaultPortal() public {
        vm.expectRevert(bytes(unicode"Only VaultPortal / 仅限 VaultPortal 调用"));
        factory.newVault(address(0xBEEF), address(0), USER, vaultData);
    }

    function test_newVault_RejectsInvalidVaultData() public {
        vm.startPrank(VAULT_PORTAL);

        vm.expectRevert(bytes(unicode"Native BNB only / 仅支持原生 BNB"));
        factory.newVault(address(0xBEEF), USDT, USER, vaultData);

        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, 5000, false, 0);
        rows[1] = AllocationRow(USDT, 4000, true, 0);
        vm.expectRevert(bytes(unicode"Allocations must sum to 10000 / 份额总和必须为 10000"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        rows[1] = AllocationRow(address(0x1234), 5000, true, 0);
        vm.expectRevert(bytes(unicode"Stock not registered / 股票未注册"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        rows[1] = AllocationRow(ROUTE_A, 5000, false, 0);
        vm.expectRevert(bytes(unicode"Duplicate target / 重复的目标地址"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        // a registered stock token (enabled or disabled) must not be usable as a fee route
        rows[1] = AllocationRow(CAKE, 5000, false, 0);
        vm.expectRevert(bytes(unicode"Stock address cannot be a fee route / 股票地址不能作为手续费路由"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));
        vm.stopPrank();
        vm.prank(ADMIN);
        factory.setStockEnabled(CAKE, false);
        vm.startPrank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Stock address cannot be a fee route / 股票地址不能作为手续费路由"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));
        vm.stopPrank();
        vm.prank(ADMIN);
        factory.setStockEnabled(CAKE, true);
        vm.startPrank(VAULT_PORTAL);

        rows[1] = AllocationRow(address(0), 5000, false, 0);
        vm.expectRevert(bytes(unicode"Zero target / 目标地址为零"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        rows[0] = AllocationRow(ROUTE_A, 10000, false, 0);
        rows[1] = AllocationRow(ROUTE_B, 0, false, 0);
        vm.expectRevert(bytes(unicode"Zero bps / 份额为零"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        AllocationRow[] memory empty = new AllocationRow[](0);
        vm.expectRevert(bytes(unicode"Empty allocation / 分配为空"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(empty));

        AllocationRow[] memory tooMany = new AllocationRow[](17);
        for (uint256 i = 0; i < 17; i++) {
            tooMany[i] = AllocationRow(address(uint160(i + 1)), 1, false, 0);
        }
        vm.expectRevert(bytes(unicode"Too many fee routes / 手续费路由过多"));
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(tooMany));

        // routes-only and stocks-only configurations are valid
        rows[0] = AllocationRow(ROUTE_A, 6000, false, 0);
        rows[1] = AllocationRow(ROUTE_B, 4000, false, 0);
        StonksPadVault routesOnly =
            StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
        assertEq(routesOnly.stockPoolBps(), 0);
        rows[0] = AllocationRow(USDT, 10000, true, 0);
        AllocationRow[] memory one = new AllocationRow[](1);
        one[0] = rows[0];
        StonksPadVault stocksOnly =
            StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(one))));
        assertEq(stocksOnly.stockPoolBps(), 10000);
        assertEq(stocksOnly.feeRouteCount(), 0);
        vm.stopPrank();
    }

    /* ========== launch validation ========== */

    function test_onBeforeLaunch() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d = IVaultFactoryValidationV2.LaunchValidationDataV1({
            tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3,
            quoteToken: address(0),
            buyTaxRate: 500,
            sellTaxRate: 500,
            vaultBps: 10000,
            deflationBps: 0,
            dividendBps: 0,
            lpBps: 0,
            dividendToken: address(0),
            minimumShareBalance: 0
        });
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(d));
        assertTrue(ok, reason);

        // Flap-native deflation and LP splits are allowed as long as the vault share is > 0
        d.vaultBps = 5000;
        d.deflationBps = 3000;
        d.lpBps = 2000;
        (ok, reason) = factory.onBeforeLaunch(abi.encode(d));
        assertTrue(ok, reason);

        d.vaultBps = 0;
        (ok,) = factory.onBeforeLaunch(abi.encode(d));
        assertFalse(ok, "must reject zero vault share");

        d.vaultBps = 5000;
        d.dividendBps = 100;
        (ok,) = factory.onBeforeLaunch(abi.encode(d));
        assertFalse(ok, "must reject Flap dividend split");

        d.dividendBps = 0;
        d.quoteToken = USDT;
        (ok,) = factory.onBeforeLaunch(abi.encode(d));
        assertFalse(ok, "must reject ERC20 quote");

        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(USDT));
        assertEq(factory.factorySpecVersion(), "v2.2");
        FactoryPolicy[] memory policies = factory.tokenCreationPolicies();
        assertEq(policies.length, 3);
        assertEq(policies[0].target, "quoteToken");
        assertEq(policies[1].target, "dividendBps");
        assertEq(policies[2].target, "mktBps");
        assertEq(policies[2].operator, "gt");
    }

    /* ========== schemas & description ========== */

    function test_vaultUISchema() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.vaultType, "StonksPadVault");
        assertTrue(bytes(schema.description).length > 0);
        assertEq(schema.methods.length, 14);

        string[14] memory names = [
            "stats",
            "getFeeRoutes",
            "getStocks",
            "claimableFees",
            "getEpoch",
            "epochRemaining",
            "hasClaimed",
            "minHolding",
            "epochStocks",
            "getEpochApproval",
            "opsReserve",
            "claimFees",
            "claimStocks",
            "withdrawPlatformFee"
        ];
        for (uint256 i = 0; i < 14; i++) {
            assertEq(schema.methods[i].name, names[i]);
            assertTrue(bytes(schema.methods[i].description).length > 0);
            assertEq(schema.methods[i].isWriteMethod, i >= 11, "write flag");
            assertEq(schema.methods[i].approvals.length, 0);
        }
        assertTrue(schema.methods[1].isOutputArray);
        assertTrue(schema.methods[2].isOutputArray);
        assertTrue(schema.methods[8].isOutputArray);
        assertEq(schema.methods[0].outputs.length, 7);
        assertEq(schema.methods[7].outputs[0].decimals, 18);
        assertEq(schema.methods[12].inputs.length, 2);
        assertEq(schema.methods[12].inputs[1].fieldType, "bytes");
        assertEq(schema.methods[9].outputs.length, 3);
        assertEq(schema.methods[10].outputs.length, 5);
        assertEq(schema.methods[4].outputs.length, 5);
        assertEq(schema.methods[4].outputs[1].fieldType, "time");
        assertEq(schema.methods[4].outputs[2].fieldType, "time");
    }

    function test_vaultDataSchema() public view {
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertTrue(bytes(schema.description).length > 0);
        assertTrue(schema.isArray);
        assertEq(schema.fields.length, 4);
        assertEq(schema.fields[0].name, "target");
        assertEq(schema.fields[0].fieldType, "address");
        assertEq(schema.fields[1].name, "bps");
        assertEq(schema.fields[1].fieldType, "uint16");
        assertEq(schema.fields[2].name, "isStock");
        assertEq(schema.fields[2].fieldType, "bool");
        assertEq(schema.fields[3].name, "minHolding");
        assertEq(schema.fields[3].fieldType, "uint256");
        assertEq(schema.fields[3].decimals, 18);
    }

    function test_descriptionChangesWithState() public {
        string memory before = vault.description();
        assertTrue(bytes(before).length > 0);
        _fund(1.5 ether);
        string memory after_ = vault.description();
        assertTrue(keccak256(bytes(before)) != keccak256(bytes(after_)), "description should reflect revenue");
    }

    function test_views() public {
        _fund(10 ether);
        (
            uint256 received,
            uint256 net,
            uint256 platformPending,
            uint256 pool,
            uint256 spent,
            uint256 buys,
            uint256 epochs
        ) = vault.stats();
        assertEq(received, 10 ether);
        assertEq(net, 9 ether);
        assertEq(platformPending, 1 ether);
        assertEq(pool, 4.5 ether);
        assertEq(spent, 0);
        assertEq(buys, 0);
        assertEq(epochs, 0);

        StonksPadVault.FeeRouteView[] memory routes = vault.getFeeRoutes();
        assertEq(routes.length, 2);
        assertEq(routes[0].recipient, ROUTE_A);
        assertEq(routes[0].bps, ROUTE_A_BPS);
        assertEq(routes[0].claimable, uint256(9 ether) * ROUTE_A_BPS / 10000);
        assertEq(routes[1].recipient, ROUTE_B);

        StonksPadVault.StockView[] memory stocks = vault.getStocks();
        assertEq(stocks.length, 2);
        assertEq(stocks[0].token, USDT);
        assertEq(stocks[1].token, CAKE);
        assertTrue(stocks[0].enabled && stocks[1].enabled);
        assertEq(vault.claimableFees(USER), 0);
        assertEq(factory.stockCount(), 3);
        assertEq(factory.getStockList().length, 3);
        assertEq(factory.getVaults(0, 10).length, 1);
        assertEq(factory.getVaults(5, 10).length, 0);
    }

    /* ========== solvency invariant ========== */

    function test_balanceCoversAllObligations() public {
        _fund(7.777777777777777777 ether);
        _fund(0.000000000000000123 ether);
        uint256 obligations = vault.platformAccrued() + vault.claimableFees(ROUTE_A) + vault.claimableFees(ROUTE_B)
            + vault.stockPoolAvailable();
        assertLe(obligations, address(vault).balance, "vault must be solvent");
    }

    /* ========== minHolding & mandatory stock ========== */

    function test_minHoldingStoredAndValidated() public {
        assertEq(vault.minHolding(), 0, "default vault has no minHolding");
        StonksPadVault v = _newStonksVault(5000, 1000 ether);
        assertEq(v.minHolding(), 1000 ether);

        // only some rows carry the value → accepted (zero rows are ignored)
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, 5000, false, 0);
        rows[1] = AllocationRow(STONKS, 5000, true, 42 ether);
        vm.prank(VAULT_PORTAL);
        StonksPadVault v2 =
            StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
        assertEq(v2.minHolding(), 42 ether);

        // two different non-zero values → rejected
        rows[0].minHolding = 41 ether;
        vm.expectRevert(bytes(unicode"Inconsistent minHolding / minHolding 不一致"));
        vm.prank(VAULT_PORTAL);
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));
    }

    function test_mandatoryStockEnforced() public {
        vm.prank(ADMIN);
        factory.setMandatoryStock(STONKS);
        assertEq(factory.mandatoryStock(), STONKS);

        // default vaultData (USDT + CAKE, no STONKS) is now rejected
        vm.expectRevert(bytes(unicode"Mandatory stock missing / 缺少必选股票"));
        vm.prank(VAULT_PORTAL);
        factory.newVault(address(0xBEEF), address(0), USER, vaultData);

        // a launch including STONKS passes
        StonksPadVault v = _newStonksVault(2500, 0);
        assertEq(v.stockCount(), 1);

        // STONKS as a fee route does not satisfy the requirement
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(STONKS, 5000, false, 0);
        rows[1] = AllocationRow(CAKE, 5000, true, 0);
        vm.expectRevert(bytes(unicode"Mandatory stock missing / 缺少必选股票"));
        vm.prank(VAULT_PORTAL);
        factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows));

        vm.expectRevert(bytes(unicode"Stock not registered / 股票未注册"));
        vm.prank(ADMIN);
        factory.setMandatoryStock(address(0x1234));
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vm.prank(KEEPER);
        factory.setMandatoryStock(address(0));
    }

    /* ========== TWAP oracle mode (STONKS) ========== */

    function test_registerStock_TwapRequiresV2PathWithPairs() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(bytes(unicode"TWAP requires a V2 path / TWAP 需要 V2 路径"));
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            abi.encodePacked(WBNB, uint24(2500), CAKE),
            IStonksPadVaultFactory.OracleMode.TwapV2,
            address(0),
            true
        );
        address[] memory p = new address[](2);
        p[0] = WBNB;
        p[1] = address(0x1234);
        vm.expectRevert(bytes(unicode"Pair not found / 交易对不存在"));
        factory.registerStock(
            address(0x1234),
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(p),
            IStonksPadVaultFactory.OracleMode.TwapV2,
            address(0),
            true
        );
        vm.stopPrank();

        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(STONKS);
        assertTrue(info.enabled);
        assertTrue(info.oracleMode == IStonksPadVaultFactory.OracleMode.TwapV2);
        assertEq(info.priceFeed, address(0));

        vm.expectRevert(bytes(unicode"Stock is not in TWAP mode / 股票不是 TWAP 模式"));
        factory.updateTwapObservations(CAKE);
    }

    function test_twapObservationsRollForward() public {
        address pair = 0xDb6f1D044b8b2887a6C450D0D13176C81E3F936d; // QQQB/STONKS
        (IStonksPadVaultFactory.TwapObs memory latest,) = factory.twapObservations(pair);
        assertEq(latest.timestamp, 0);

        factory.updateTwapObservations(STONKS);
        (latest,) = factory.twapObservations(pair);
        assertEq(latest.timestamp, uint32(vm.getBlockTimestamp()));

        // a refresh inside the minimum window is a no-op (keeps the current window)
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        factory.updateTwapObservations(STONKS);
        (IStonksPadVaultFactory.TwapObs memory again,) = factory.twapObservations(pair);
        assertEq(again.timestamp, latest.timestamp);

        // after MIN_TWAP_WINDOW the checkpoint rolls: old latest becomes previous
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        factory.updateTwapObservations(STONKS);
        (IStonksPadVaultFactory.TwapObs memory newest, IStonksPadVaultFactory.TwapObs memory previous) =
            factory.twapObservations(pair);
        assertEq(previous.timestamp, latest.timestamp);
        assertEq(newest.timestamp, uint32(vm.getBlockTimestamp()));
    }

    function test_buyStocks_TwapMode_StonksFlow() public {
        StonksPadVault v = _newStonksVault(5000, 0);
        vm.prank(KEEPER);
        v.setMaxSpendPerBuy(0.2 ether); // STONKS liquidity is thin (~70 BNB/hop): keep price impact small
        _fundVault(v, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);

        // no checkpoint yet → the floor cannot be computed
        uint256[] memory minOuts = _quoteMinOutsFor(v);
        vm.expectRevert(bytes(unicode"TWAP observation missing / 缺少 TWAP 观测"));
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        // checkpoint too fresh → still rejected
        factory.updateTwapObservations(STONKS);
        vm.expectRevert(bytes(unicode"TWAP observation missing / 缺少 TWAP 观测"));
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        // after 30 minutes the ≥30-min average is available and the buy goes through
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        minOuts = _quoteMinOutsFor(v);
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertGt(v.stockUndistributed(STONKS), 0, "STONKS bought");
        assertEq(IERC20(STONKS).balanceOf(address(v)), v.stockUndistributed(STONKS));
        assertEq(v.stockSpent(), 0.2 ether);

        // the buy rolled the window: a second buy 10 minutes later uses the previous checkpoint
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        minOuts = _quoteMinOutsFor(v);
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(v.buyCount(), 2);
    }

    function test_buyStocks_TwapFloorBlocksManipulatedSpot() public {
        StonksPadVault v = _newStonksVault(5000, 0);
        vm.prank(KEEPER);
        v.setMaxSpendPerBuy(0.5 ether);
        _fundVault(v, 10 ether);
        factory.updateTwapObservations(STONKS);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);

        // attacker pushes the spot price up right before the keeper buys (front-run)
        _pumpStonks(40 ether);
        uint256[] memory minOuts = _quoteMinOutsFor(v); // 97% of the manipulated spot quote
        vm.expectRevert(bytes(unicode"minOut below oracle floor / minOut 低于预言机下限"));
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);

        // a stale checkpoint (> 24h) is refused as well
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vm.expectRevert(bytes(unicode"TWAP observation out of window / TWAP 观测超出窗口"));
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    /* ========== treasury ========== */

    function _wireTreasury() internal {
        vm.prank(ADMIN);
        factory.setPlatformTreasury(address(treasury));
    }

    function test_treasury_ReceiveSplitCollectAndDistribute() public {
        _wireTreasury();
        _fund(10 ether); // platform fee = 1 BNB
        assertEq(vault.platformAccrued(), 1 ether);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        treasury.collect(vaults);
        assertEq(vault.platformAccrued(), 0);
        assertEq(address(treasury).balance, 1 ether);
        assertEq(treasury.totalReceived(), 1 ether);
        assertEq(treasury.burnPool(), 0.8 ether);
        assertEq(treasury.nftAccrued(), 0.1 ether);
        assertEq(treasury.platformAccrued(), 0.1 ether);

        // vaults with nothing accrued are skipped; foreign addresses are rejected
        treasury.collect(vaults);
        vaults[0] = USER;
        vm.expectRevert(bytes(unicode"Not a StonksPad vault / 非 StonksPad 金库"));
        treasury.collect(vaults);

        treasury.distribute();
        assertEq(NFT_WALLET.balance, 0.1 ether);
        assertEq(PLATFORM_WALLET.balance, 0.1 ether);
        assertEq(treasury.nftAccrued(), 0);
        assertEq(address(treasury).balance, 0.8 ether, "burn pool stays in the treasury");
        vm.expectRevert(bytes(unicode"Nothing to distribute / 无可分配金额"));
        treasury.distribute();

        // the vault's own withdrawPlatformFee() also lands in the treasury
        _fund(1 ether);
        vault.withdrawPlatformFee();
        assertEq(treasury.burnPool(), 0.88 ether);
    }

    function test_treasury_BuyAndBurn() public {
        _wireTreasury();
        vm.expectRevert(bytes(unicode"Nothing to burn / 无可销毁资金"));
        vm.prank(KEEPER);
        treasury.buyAndBurn(1, vm.getBlockTimestamp() + 300);

        vm.prank(ADMIN);
        treasury.setMaxSpendPerBurn(0.2 ether); // thin STONKS liquidity: small burns
        _fund(10 ether);
        vault.withdrawPlatformFee(); // 0.8 BNB burn pool
        factory.updateTwapObservations(STONKS);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);

        uint256[] memory amounts = IPancakeV2Router(PANCAKE_V2_ROUTER).getAmountsOut(0.2 ether, _stonksPath());
        uint256 minOut = amounts[2] * 9700 / 10000;
        uint256 deadBefore = IERC20(STONKS).balanceOf(DEAD);

        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vm.prank(USER);
        treasury.buyAndBurn(minOut, vm.getBlockTimestamp() + 300);

        vm.prank(KEEPER);
        treasury.buyAndBurn(minOut, vm.getBlockTimestamp() + 300);
        uint256 burned = IERC20(STONKS).balanceOf(DEAD) - deadBefore;
        assertGe(burned, minOut, "STONKS sent to the dead address");
        assertEq(treasury.totalBurnedStonks(), burned);
        assertEq(treasury.totalBurnedBnb(), 0.2 ether);
        assertEq(treasury.burnPool(), 0.6 ether);
        assertEq(treasury.burnCount(), 1);
        assertEq(IERC20(STONKS).balanceOf(address(treasury)), 0, "treasury keeps no STONKS");
        assertEq(IERC20(WBNB).balanceOf(address(treasury)), 0, "no WBNB dust");

        vm.expectRevert(bytes(unicode"Burn interval not elapsed / 销毁间隔未到"));
        vm.prank(KEEPER);
        treasury.buyAndBurn(minOut, vm.getBlockTimestamp() + 300);

        // Guardian can execute as well (10 minutes later, previous checkpoint is used)
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        amounts = IPancakeV2Router(PANCAKE_V2_ROUTER).getAmountsOut(0.2 ether, _stonksPath());
        vm.prank(FLAP_GUARDIAN);
        treasury.buyAndBurn(amounts[2] * 9700 / 10000, vm.getBlockTimestamp() + 300);
        assertEq(treasury.burnPool(), 0.4 ether);
        assertEq(treasury.burnCount(), 2);
        assertGt(treasury.totalBurnedStonks(), burned);

        // a deadline in the past is rejected
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(bytes(unicode"Deadline passed / 已超过截止时间"));
        vm.prank(KEEPER);
        treasury.buyAndBurn(1, vm.getBlockTimestamp() - 1);
    }

    function test_treasury_SettingsGating() public {
        vm.startPrank(ADMIN);
        treasury.setWallets(USER, HOLDER_1);
        treasury.setMaxSlippageBps(500);
        treasury.setMaxOracleDeviationBps(1000);
        treasury.setMaxSpendPerBurn(20 ether);
        vm.expectRevert(bytes(unicode"Slippage above hard cap / 滑点超过上限"));
        treasury.setMaxSlippageBps(501);
        vm.expectRevert(bytes(unicode"Deviation above hard cap / 偏差超过上限"));
        treasury.setMaxOracleDeviationBps(1001);
        vm.expectRevert(bytes(unicode"Spend out of bounds / 金额超出范围"));
        treasury.setMaxSpendPerBurn(21 ether);
        vm.expectRevert(bytes(unicode"Zero wallet / 钱包地址为零"));
        treasury.setWallets(address(0), HOLDER_1);
        vm.stopPrank();
        assertEq(treasury.nftWallet(), USER);
        assertEq(treasury.platformWallet(), HOLDER_1);

        vm.startPrank(FLAP_GUARDIAN);
        treasury.setWallets(NFT_WALLET, PLATFORM_WALLET);
        treasury.setMaxSpendPerBurn(1 ether);
        vm.stopPrank();

        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vm.prank(KEEPER);
        treasury.setWallets(USER, USER);
        assertEq(address(treasury.factory()), address(factory));
        assertEq(treasury.stonks(), STONKS);
    }

    /* ========== TWAP V3 oracle mode (SPCXB) & EIP-8056 multiplier ========== */

    function _spcxbPath() internal pure returns (bytes memory) {
        return abi.encodePacked(WBNB, uint24(100), USDT, uint24(2500), SPCXB);
    }

    function _registerSpcxbTwapV3() internal {
        vm.prank(ADMIN);
        factory.registerStock(
            SPCXB,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            _spcxbPath(),
            IStonksPadVaultFactory.OracleMode.TwapV3,
            address(0),
            true
        );
    }

    function _newSpcxbVault(uint16 bps) internal returns (StonksPadVault v) {
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, 10000 - bps, false, 0);
        rows[1] = AllocationRow(SPCXB, bps, true, 0);
        vm.prank(VAULT_PORTAL);
        v = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
    }

    /// @dev Pushes the SPCXB spot price up through the registered V3 route.
    function _pumpSpcxb(uint256 bnb) internal {
        vm.deal(WHALE, WHALE.balance + bnb);
        vm.startPrank(WHALE);
        IWBNBLike(WBNB).deposit{value: bnb}();
        IERC20(WBNB).approve(PANCAKE_V3_ROUTER, bnb);
        IPancakeV3SmartRouter(PANCAKE_V3_ROUTER)
            .exactInput(
                IPancakeV3SmartRouter.ExactInputParams({
                path: _spcxbPath(), recipient: WHALE, amountIn: bnb, amountOutMinimum: 0
            })
            );
        vm.stopPrank();
    }

    function test_tickMathMatchesLivePools() public view {
        address[5] memory pools = [
            0x977DaFFC095b33872E2741c19568925015C35b4d, // SPCXB/USDT 2500
            0x66faaD27cf481f82d0089ec8156B3AA3636010C7, // SPCXB/WBNB 2500
            0x36696169C63e42cd08ce11f5deeBbCeBae652050, // WBNB/USDT 100
            0x908d49048EB3a7bEdfd238972403842805EAF2bE, // GMEB/USDT 2500
            0x692081209619735f25700557078aB084d3E5D007 // MSTRB/USDT 2500
        ];
        for (uint256 i = 0; i < pools.length; i++) {
            (uint160 sqrtP, int24 tick,,,,,) = IPancakeV3Pool(pools[i]).slot0();
            assertLe(TickMath.getSqrtRatioAtTick(tick), sqrtP, "ratio(tick) <= sqrtP");
            assertGt(TickMath.getSqrtRatioAtTick(tick + 1), sqrtP, "sqrtP < ratio(tick+1)");
        }
        // 30-minute average tick of the live SPCXB/USDT pool is close to spot
        (, int24 spot,,,,,) = IPancakeV3Pool(pools[0]).slot0();
        int24 avg = PancakeV3Twap.consult(pools[0], 30 minutes);
        int256 diff = int256(avg) - int256(spot);
        assertLt(diff < 0 ? -diff : diff, 2000, "avg tick within 20% of spot");
    }

    function test_registerStock_TwapV3Rules() public {
        vm.startPrank(ADMIN);
        // TwapV3 needs a V3 path
        address[] memory p = new address[](2);
        p[0] = WBNB;
        p[1] = CAKE;
        vm.expectRevert(bytes(unicode"TWAP V3 requires a V3 path / TWAP V3 需要 V3 路径"));
        factory.registerStock(
            CAKE,
            IStonksPadVaultFactory.DexKind.PancakeV2,
            abi.encode(p),
            IStonksPadVaultFactory.OracleMode.TwapV3,
            address(0),
            true
        );
        // TwapV2 still needs a V2 path
        vm.expectRevert(bytes(unicode"TWAP requires a V2 path / TWAP 需要 V2 路径"));
        factory.registerStock(
            SPCXB,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            _spcxbPath(),
            IStonksPadVaultFactory.OracleMode.TwapV2,
            address(0),
            true
        );
        // a hop through a non-existent pool is rejected (STONKS has no V3 pools)
        vm.expectRevert(bytes(unicode"Pool not found / 池不存在"));
        factory.registerStock(
            STONKS,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            abi.encodePacked(WBNB, uint24(100), STONKS),
            IStonksPadVaultFactory.OracleMode.TwapV3,
            address(0),
            true
        );
        // an existing but empty pool (WBNB/SPCXB 0.01%) is rejected as well
        vm.expectRevert(bytes(unicode"Pool has no liquidity / 池没有流动性"));
        factory.registerStock(
            SPCXB,
            IStonksPadVaultFactory.DexKind.PancakeV3,
            abi.encodePacked(WBNB, uint24(100), SPCXB),
            IStonksPadVaultFactory.OracleMode.TwapV3,
            address(0),
            true
        );
        vm.stopPrank();

        _registerSpcxbTwapV3();
        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(SPCXB);
        assertTrue(info.oracleMode == IStonksPadVaultFactory.OracleMode.TwapV3);
        assertTrue(info.dexKind == IStonksPadVaultFactory.DexKind.PancakeV3);
        assertEq(factory.pancakeV3Factory(), 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);

        // V2 checkpoints are not used by TwapV3 stocks
        vm.expectRevert(bytes(unicode"Stock is not in TWAP mode / 股票不是 TWAP 模式"));
        factory.updateTwapObservations(SPCXB);

        // anyone can grow the pools' observation buffers
        factory.increaseV3ObservationCardinality(SPCXB, 1000);
        (,,, uint16 card, uint16 cardNext,,) = IPancakeV3Pool(0x977DaFFC095b33872E2741c19568925015C35b4d).slot0();
        assertGe(cardNext, 1000);
        assertGe(card, 1);
        vm.expectRevert(bytes(unicode"TWAP V3 requires a V3 path / TWAP V3 需要 V3 路径"));
        factory.increaseV3ObservationCardinality(STONKS, 10);
    }

    function test_buyStocks_TwapV3_SpcxbFlow() public {
        _registerSpcxbTwapV3();
        StonksPadVault v = _newSpcxbVault(5000);
        _fundVault(v, 10 ether); // pool 4.5 BNB, below the 5 BNB cap → whole pool is spent
        vm.warp(vm.getBlockTimestamp() + 10 minutes);

        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(SPCXB);
        uint256 twap = StonksPadSwapLib.twapV3Out(factory, info, 4.5 ether);
        uint256 q = StonksPadSwapLib.quote(factory, info, 4.5 ether);
        assertGt(twap, 0);
        // the fee-aware 30-minute reference is within 3% of the executable quote on a calm pool
        uint256 d = twap > q ? twap - q : q - twap;
        assertLt(d * 100 / q, 3, "twapV3 vs quote");

        uint256[] memory minOuts = _quoteMinOutsFor(v);
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertGt(v.stockUndistributed(SPCXB), 0, "SPCXB bought");
        assertEq(IERC20(SPCXB).balanceOf(address(v)), v.stockUndistributed(SPCXB));
        assertEq(v.stockSpent(), 4.5 ether);
        assertEq(IERC20(WBNB).balanceOf(address(v)), 0, "no WBNB dust");

        // a second buy 10 minutes later needs no checkpoint management at all
        _fundVault(v, 2 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        minOuts = _quoteMinOutsFor(v);
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        assertEq(v.buyCount(), 2);
    }

    function test_buyStocks_TwapV3FloorBlocksManipulatedSpot() public {
        _registerSpcxbTwapV3();
        StonksPadVault v = _newSpcxbVault(5000);
        _fundVault(v, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(SPCXB);
        uint256 twapBefore = StonksPadSwapLib.twapV3Out(factory, info, 4.5 ether);
        uint256 quoteBefore = StonksPadSwapLib.quote(factory, info, 4.5 ether);

        // attacker pushes the spot price up right before the keeper's buy (same block)
        // (kept moderate: a larger swap crosses hundreds of ticks and public RPCs time out on the fork)
        _pumpSpcxb(800 ether);
        uint256 quoteAfter = StonksPadSwapLib.quote(factory, info, 4.5 ether);
        assertLt(quoteAfter * 100 / quoteBefore, 96, "spot moved by more than 4%");
        assertEq(StonksPadSwapLib.twapV3Out(factory, info, 4.5 ether), twapBefore, "TWAP unchanged in-block");

        uint256[] memory minOuts = _quoteMinOutsFor(v); // 97% of the manipulated spot quote
        vm.expectRevert(bytes(unicode"minOut below oracle floor / minOut 低于预言机下限"));
        vm.prank(KEEPER);
        v.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
    }

    function test_chainlinkFloor_AppliesUiMultiplier() public {
        // AAPLB is a live EIP-8056 token with uiMultiplier ≈ 1.0006e18
        uint256 m = StonksPadSwapLib.uiMultiplier(AAPLB);
        assertGt(m, 1e18);
        assertLt(m, 1.01e18);
        assertEq(StonksPadSwapLib.uiMultiplier(CAKE), 1e18, "plain ERC-20 -> 1.0x");

        // mock: $100 stock with a 4x UI multiplier → one raw unit is worth 4 shares
        MockScaledToken scaled = new MockScaledToken(4e18);
        MockFeed feed = new MockFeed(100e8);
        IStonksPadVaultFactory.StockInfo memory info = IStonksPadVaultFactory.StockInfo({
            enabled: true,
            dexKind: IStonksPadVaultFactory.DexKind.PancakeV2,
            oracleMode: IStonksPadVaultFactory.OracleMode.Chainlink,
            priceFeed: address(feed),
            path: ""
        });
        uint256 outScaled = StonksPadSwapLib.chainlinkOut(factory, info, address(scaled), 1 ether);
        MockScaledToken plain = new MockScaledToken(1e18);
        uint256 outPlain = StonksPadSwapLib.chainlinkOut(factory, info, address(plain), 1 ether);
        assertEq(outScaled, outPlain / 4, "expected raw output divided by the multiplier");
        (, int256 bnbUsd,,,) = MockFeed(BNB_USD_FEED).latestRoundData();
        assertEq(outPlain, uint256(bnbUsd) * 1e18 / 100e8, "plain: 1 BNB worth of $100 shares");
    }
}
