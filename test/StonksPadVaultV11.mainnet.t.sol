// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Vm} from "forge-std/Vm.sol";
import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

import {StonksPadVault} from "../src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "../src/StonksPadVaultFactory.sol";
import {AllocationRow, FeeRouteInit, StockAlloc} from "../src/StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "../src/interfaces/IStonksPadVaultFactory.sol";
import {IPancakeV2Router, IPancakeV3QuoterV2} from "../src/interfaces/IPancake.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Keeper contract that cannot receive BNB: the reimbursement payout fails, the action must not.
contract RejectingKeeper {
    function poke(address vault, address stock) external {
        StonksPadVault(payable(vault)).pokeTwap(stock);
    }
}

/// @dev Keeper that tries to re-enter the vault while it is being reimbursed. It accepts the payout only when
///      the re-entry was rejected by the reentrancy guard; any other outcome reverts (and so rolls the payout back).
contract ReentrantKeeper {
    StonksPadVault internal immutable vault;
    address internal immutable stock;

    constructor(StonksPadVault vault_, address stock_) {
        vault = vault_;
        stock = stock_;
    }

    function poke() external {
        vault.pokeTwap(stock);
    }

    receive() external payable {
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(StonksPadVault.pokeTwap, (stock)));
        require(!ok, "re-entered");
        require(
            keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")),
            "not the guard"
        );
    }
}

/// @dev Keeper whose receive() burns every unit of gas it is given.
contract GasBurningKeeper {
    function poke(address vault, address stock) external {
        StonksPadVault(payable(vault)).pokeTwap(stock);
    }

    receive() external payable {
        while (true) {}
    }
}

/// @title StonksPadVault v1.1 upgrade tests (BSC mainnet fork)
/// @notice Part A upgrades the LIVE mainnet beacon on a fork and checks storage / state continuity of
///         the live vault proxy. Part B exercises the two v1.1 features on a locally deployed stack.
contract StonksPadVaultV11Test is FlapBSCFixture {
    // ── live mainnet deployment (v1.0) ────────────────────────────────────
    address internal constant MAINNET_FACTORY = 0x14B8425dd0F3fDd539Fd72e33c08D22a35013A11;
    address internal constant MAINNET_BEACON = 0xA9A7fE321e3510E6B2187DA4845cb618Edf1C5Af;
    address internal constant MAINNET_IMPL_V10 = 0x0Acc4ca5fA986d3431a4e4d0cF8BC652285dC559;
    address payable internal constant LIVE_VAULT = payable(0xd4e29c3Aa30348AcF246F9D5C2b9fAE0faE13fE4);
    address internal constant MAINNET_ADMIN = 0xBd86235E0EEB9b1659fc5090a0C8a160cD329Efb;
    /// @dev `forge inspect StonksPadVault storage-layout`: slot of `_epochs`; v1.1 variables start at 71.
    uint256 internal constant EPOCHS_SLOT = 68;
    uint256 internal constant FIRST_V11_SLOT = 71;
    uint256 internal constant LAST_V11_SLOT = 76;

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

    function setUp() public {
        _forkBSCMainnet();

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
        address[] memory v2Path = new address[](2);
        v2Path[0] = WBNB;
        v2Path[1] = USDT;
        address[] memory stonksPath = new address[](3);
        stonksPath[0] = WBNB;
        stonksPath[1] = QQQB;
        stonksPath[2] = STONKS;
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
            abi.encode(stonksPath),
            IStonksPadVaultFactory.OracleMode.TwapV2,
            address(0),
            true
        );
        factory.setOracleStaleness(7 days); // tests warp past the 24h verifier time-lock
        vm.stopPrank();

        vault = _newVault(USDT, CAKE);
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
        vm.prank(VAULT_PORTAL);
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

    /* =====================================================================
       PART A — upgrade of the LIVE mainnet beacon (storage-layout compatibility)
       ===================================================================== */

    function test_liveMainnetProxy_StorageAndStateSurviveUpgrade() public {
        StonksPadVault live = StonksPadVault(LIVE_VAULT);
        UpgradeableBeacon beacon = UpgradeableBeacon(MAINNET_BEACON);
        assertEq(beacon.implementation(), MAINNET_IMPL_V10, "fork must start on the deployed v1.0 implementation");
        assertEq(beacon.owner(), FLAP_GUARDIAN);
        assertTrue(StonksPadVaultFactory(MAINNET_FACTORY).isVault(LIVE_VAULT));

        // ── snapshot: raw slots (contract level + epoch 1 region) ──
        bytes32[] memory slotsBefore = new bytes32[](111);
        for (uint256 i = 0; i <= 110; i++) {
            slotsBefore[i] = vm.load(LIVE_VAULT, bytes32(i));
        }
        uint256 epochBase = uint256(keccak256(abi.encode(uint256(1), EPOCHS_SLOT)));
        bytes32[] memory epochBefore = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            epochBefore[i] = vm.load(LIVE_VAULT, bytes32(epochBase + i));
        }
        for (uint256 i = FIRST_V11_SLOT; i <= LAST_V11_SLOT; i++) {
            assertEq(slotsBefore[i], bytes32(0), "slots claimed by v1.1 must be unused gap on the live proxy");
        }
        assertEq(epochBefore[5], bytes32(0), "epoch slot 5 (v1.1 members) must be unused on the live proxy");

        // ── snapshot: decoded state through the v1.0 ABI ──
        (uint256 r0, uint256 n0, uint256 p0, uint256 pool0, uint256 spent0, uint256 buys0, uint256 epochs0) =
            live.stats();
        assertGt(r0, 0, "live vault has revenue");
        assertGe(epochs0, 1, "live vault has at least one epoch");
        bytes32 stateHashBefore = _liveStateHash(live);
        string memory descBefore = live.description();
        assertEq(live.vaultUISchema().methods.length, 12, "v1.0 schema");

        // ── the upgrade, exactly as the Guardian will perform it ──
        StonksPadVault newImpl = new StonksPadVault();
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(MAINNET_ADMIN);
        beacon.upgradeTo(address(newImpl));
        vm.prank(FLAP_GUARDIAN);
        beacon.upgradeTo(address(newImpl));
        assertEq(beacon.implementation(), address(newImpl));

        // ── raw storage is untouched ──
        for (uint256 i = 0; i <= 110; i++) {
            assertEq(vm.load(LIVE_VAULT, bytes32(i)), slotsBefore[i], "contract-level slot changed by the upgrade");
        }
        for (uint256 i = 0; i < 7; i++) {
            assertEq(vm.load(LIVE_VAULT, bytes32(epochBase + i)), epochBefore[i], "epoch slot changed by the upgrade");
        }

        // ── decoded state is identical through the v1.1 ABI ──
        (uint256 r1, uint256 n1, uint256 p1, uint256 pool1, uint256 spent1, uint256 buys1, uint256 epochs1) =
            live.stats();
        assertEq(r1, r0);
        assertEq(n1, n0);
        assertEq(p1, p0);
        assertEq(pool1, pool0);
        assertEq(spent1, spent0);
        assertEq(buys1, buys0);
        assertEq(epochs1, epochs0);
        assertEq(_liveStateHash(live), stateHashBefore, "decoded v1.0 state changed");
        assertEq(live.description(), descBefore, "description text must be identical (now built in the library)");

        // ── v1.1 surface starts switched off ──
        assertEq(live.verifier(), address(0));
        (uint256 total, uint256 today, uint256 perCall, uint256 perDay, uint256 gasCap) = live.opsReserve();
        assertEq(total + today + perCall + perDay + gasCap, 0, "ops reserve must start off");
        (uint64 snap, uint64 approvedAt, bool fast) = live.getEpochApproval(1);
        assertEq(snap, 0);
        assertEq(approvedAt, 0);
        assertFalse(fast);
        assertEq(live.vaultUISchema().methods.length, 14, "v1.1 schema");

        // a pre-upgrade epoch can never be fast-tracked (no snapshot block recorded)
        (bytes32 liveRoot,,,,) = live.getEpoch(1);
        vm.expectRevert(bytes(unicode"Epoch has no snapshot block / 分配期没有快照区块"));
        vm.prank(FLAP_GUARDIAN);
        live.approveEpoch(1, liveRoot);

        // the proxy stays locked and keeps accounting revenue with its v1.0 fee snapshot
        _assertStillLocked(live);
        uint256 feeBps = live.platformFeeBps();
        vm.deal(address(this), 1 ether);
        (bool ok,) = LIVE_VAULT.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(live.totalReceived(), r0 + 1 ether);
        assertEq(live.platformAccrued(), p0 + 1 ether * feeBps / 10000);

        // the real admin can opt the live vault into both features
        vm.startPrank(MAINNET_ADMIN);
        live.setVerifier(VERIFIER);
        live.setOpsCaps(0.003 ether, 0.03 ether, 0.1 gwei);
        vm.stopPrank();
        assertEq(live.verifier(), VERIFIER);
        // slot 71 packs verifier (low 160 bits) + verifierSince (next 64 bits)
        uint256 slot71 = uint256(vm.load(LIVE_VAULT, bytes32(FIRST_V11_SLOT)));
        assertEq(address(uint160(slot71)), VERIFIER);
        assertEq(uint64(slot71 >> 160), uint64(vm.getBlockTimestamp()));
        assertEq(live.verifierSince(), uint64(vm.getBlockTimestamp()));

        // v1.2: the legacy v1 factory has no vaultDefaults(); launches through it must keep working after
        // such an upgrade, with both features simply off.
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, 5000, false, 0);
        rows[1] = AllocationRow(STONKS, 5000, true, 0);
        vm.prank(VAULT_PORTAL);
        StonksPadVault fresh = StonksPadVault(
            payable(StonksPadVaultFactory(MAINNET_FACTORY)
                    .newVault(address(0xBEEF), address(0), USER, abi.encode(rows)))
        );
        assertEq(fresh.verifier(), address(0));
        (,, uint256 freshPerCall, uint256 freshPerDay, uint256 freshGasPrice) = fresh.opsReserve();
        assertEq(freshPerCall + freshPerDay + freshGasPrice, 0);
    }

    /// @dev Hash of everything readable through the v1.0 ABI (routes, stocks, epoch 1, parameters).
    function _liveStateHash(StonksPadVault live) internal view returns (bytes32) {
        StonksPadVault.FeeRouteView[] memory routes = live.getFeeRoutes();
        StonksPadVault.StockView[] memory stocks = live.getStocks();
        (bytes32 root, uint64 publishedAt, uint64 claimsOpenAt, bool cancelled, string memory cid) = live.getEpoch(1);
        address[] memory epochStocks = live.epochStocks(1);
        uint256[] memory remaining = new uint256[](epochStocks.length);
        for (uint256 i = 0; i < epochStocks.length; i++) {
            remaining[i] = live.epochRemaining(1, epochStocks[i]);
        }
        return keccak256(
            abi.encode(
                abi.encode(routes, stocks),
                abi.encode(root, publishedAt, claimsOpenAt, cancelled, cid, epochStocks, remaining),
                abi.encode(live.factory(), live.taxToken(), live.creator(), live.platformFeeBps(), live.stockPoolBps()),
                abi.encode(
                    live.maxSlippageBps(),
                    live.maxOracleDeviationBps(),
                    live.maxSpendPerBuy(),
                    live.lastBuyAt(),
                    live.minHolding(),
                    live.totalNet()
                )
            )
        );
    }

    function _assertStillLocked(StonksPadVault v) internal {
        // build the arguments first: vm.expectRevert must be followed directly by the call under test
        FeeRouteInit[] memory routes = new FeeRouteInit[](0);
        StockAlloc[] memory stocks = new StockAlloc[](0);
        vm.expectRevert("Initializable: contract is already initialized");
        v.initialize(address(1), address(2), address(3), 0, 0, routes, stocks);
    }

    /* =====================================================================
       PART B — feature 1: distribution fast path
       ===================================================================== */

    function test_fastPath_ApprovalOpensClaimsAfter30Minutes() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);

        (,, uint64 openBefore,,) = vault.getEpoch(epochId);
        assertEq(openBefore, uint64(vm.getBlockTimestamp() + 24 hours), "published with the 24h delay");
        (uint64 snap,, bool fast) = vault.getEpochApproval(epochId);
        assertEq(snap, uint64(block.number - 3));
        assertFalse(fast);

        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        (,, uint64 openAfter,,) = vault.getEpoch(epochId);
        assertEq(openAfter, uint64(vm.getBlockTimestamp() + 30 minutes), "approvedAt + 30 minutes");
        (, uint64 approvedAt, bool fastNow) = vault.getEpochApproval(epochId);
        assertEq(approvedAt, uint64(vm.getBlockTimestamp()));
        assertTrue(fastNow);

        // still closed inside the 30-minute veto window …
        vm.warp(vm.getBlockTimestamp() + 29 minutes);
        vm.expectRevert(bytes(unicode"Claims not open yet / 领取尚未开放"));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, _claimData(stocks, amounts));
        // … and open right after it
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.prank(HOLDER);
        vault.claimStocks(epochId, _claimData(stocks, amounts));
        assertEq(IERC20(USDT).balanceOf(HOLDER), amounts[0]);

        vm.expectRevert(bytes(unicode"Epoch already approved / 分配期已批准"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
    }

    function test_fastPath_NoApprovalKeeps24hDelay() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);

        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(bytes(unicode"Claims not open yet / 领取尚未开放"));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, _claimData(stocks, amounts));
        vm.warp(vm.getBlockTimestamp() + 1);
        // once claims are open an approval is pointless and rejected
        vm.expectRevert(bytes(unicode"Claim window already open / 领取窗口已开放"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, _claimData(stocks, amounts));
        assertEq(IERC20(USDT).balanceOf(HOLDER), amounts[0]);
    }

    function test_fastPath_LegacyPublishAndLateApprovalNeverShortenOrExtend() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);

        // legacy 4-argument publish: works, but has no snapshot block → cannot be fast-tracked
        (uint256 legacyId,,) = _publishUsdtEpoch(vault, false);
        vm.expectRevert(bytes(unicode"Epoch has no snapshot block / 分配期没有快照区块"));
        vm.prank(VERIFIER);
        vault.approveEpoch(legacyId, bytes32(0));

        // an approval arriving 23h50m after publication must not push claimsOpenAt beyond 24h
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        (,, uint64 open24h,,) = vault.getEpoch(epochId);
        vm.warp(vm.getBlockTimestamp() + 23 hours + 50 minutes);
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        (,, uint64 openAfter,,) = vault.getEpoch(epochId);
        assertEq(openAfter, open24h, "approval can only shorten the delay");

        // invalid snapshot blocks and an oversized CID
        address[] memory s1 = new address[](1);
        s1[0] = USDT;
        uint256[] memory a1 = new uint256[](1);
        a1[0] = 1;
        bytes memory longCid = new bytes(129);
        vm.startPrank(KEEPER);
        vm.expectRevert(bytes(unicode"Invalid snapshot block / 快照区块无效"));
        vault.publishDistribution(bytes32(uint256(1)), s1, a1, "ipfs://x", 0);
        vm.expectRevert(bytes(unicode"Invalid snapshot block / 快照区块无效"));
        vault.publishDistribution(bytes32(uint256(1)), s1, a1, "ipfs://x", uint64(block.number));
        vm.expectRevert(
            bytes(unicode"Snapshot CID required (max 128 bytes) / 必须提供快照 CID（最长 128 字节）")
        );
        vault.publishDistribution(bytes32(uint256(1)), s1, a1, string(longCid), uint64(block.number - 1));
        vm.stopPrank();
    }

    function test_fastPath_VetoStillWorksAfterApproval() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));

        // admin vetoes inside the 30-minute window: reserve returns, claims are dead
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        vm.prank(ADMIN);
        vault.cancelEpoch(epochId);
        assertEq(vault.stockUndistributed(USDT), amounts[0]);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(bytes(unicode"Epoch cancelled / 分配期已取消"));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, _claimData(stocks, amounts));
        vm.expectRevert(bytes(unicode"Epoch cancelled / 分配期已取消"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
    }

    function test_verifier_HasExactlyOnePower() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        uint256[] memory minOuts = new uint256[](2);

        vm.startPrank(VERIFIER);
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vault.publishDistribution(bytes32(uint256(1)), stocks, amounts, "ipfs://x", uint64(block.number - 1));
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vault.publishDistribution(bytes32(uint256(1)), stocks, amounts, "ipfs://x");
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vault.buyStocks(minOuts, vm.getBlockTimestamp() + 300);
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vault.pokeTwap(USDT);
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vault.setMaxSpendPerBuy(1 ether);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vault.cancelEpoch(epochId);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vault.setVerifier(VERIFIER);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vault.setOpsCaps(1, 1, 1);
        vm.expectRevert(bytes(unicode"Not a fee recipient / 非手续费接收者"));
        vault.claimFees();
        vm.stopPrank();
        assertEq(VERIFIER.balance, 0, "the verifier never receives funds");

        // nobody else can approve: random user, keeper, admin
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(USER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(KEEPER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(ADMIN);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));

        // the two keys are kept distinct on chain
        vm.expectRevert(bytes(unicode"Verifier must differ from keeper / 验证者不能是 keeper"));
        vm.prank(ADMIN);
        vault.setVerifier(KEEPER);
        vm.prank(ADMIN);
        factory.setKeeper(VERIFIER); // keeper later rotated onto the verifier key
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        vm.prank(ADMIN);
        factory.setKeeper(KEEPER);

        // unknown epoch, then the Guardian as the backup approver (Flap Rule 001)
        vm.expectRevert(bytes(unicode"Unknown epoch / 未知的分配期"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId + 1, bytes32(0));
        vm.prank(FLAP_GUARDIAN);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        (,, bool fast) = vault.getEpochApproval(epochId);
        assertTrue(fast);

        // with no verifier configured only the Guardian remains
        vm.prank(ADMIN);
        vault.setVerifier(address(0));
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(address(0));
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
    }

    /* =====================================================================
       PART B — feature 2: operations reserve
       ===================================================================== */

    function test_opsReserve_OffByDefault() public {
        (uint256 total, uint256 today, uint256 perCall, uint256 perDay, uint256 gasCap) = vault.opsReserve();
        assertEq(total + today + perCall + perDay + gasCap, 0);
        vm.txGasPrice(1 gwei);
        _fund(vault, 10 ether);
        uint256 before = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance, before, "no reimbursement while the caps are zero");
        assertEq(vault.stockSpent(), 4.5 ether, "whole pool spent exactly as in v1.0");
    }

    function test_opsReserve_ReimbursesFromStockPoolOnly() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(vault, 10 ether); // platform 1, net 9: route 4.5, stock pool 4.5

        uint256 spend = _expectedSpend(vault);
        assertEq(spend, 4.5 ether - 0.003 ether, "headroom for the reimbursement is kept in the pool");
        uint256 keeperBefore = KEEPER.balance;
        vm.recordLogs();
        _buy(vault);
        uint256 paid = KEEPER.balance - keeperBefore;

        assertGt(paid, 0, "keeper reimbursed");
        assertLe(paid, 0.003 ether, "per-call cap");
        (uint256 gasUsed, uint256 gasPrice, uint256 amount) = _lastReimbursement();
        assertEq(amount, paid);
        assertEq(gasPrice, 1 gwei);
        assertEq(paid, gasUsed * 1 gwei, "actual measured gas x tx gas price");
        assertGt(gasUsed, 200_000);

        // paid from the stock pool and nowhere else
        assertEq(vault.stockSpent(), spend + paid);
        assertEq(vault.stockPoolAvailable(), 4.5 ether - spend - paid);
        assertEq(vault.claimableFees(ROUTE_A), 4.5 ether, "fee route untouched");
        assertEq(vault.platformAccrued(), 1 ether, "platform commission untouched");
        (uint256 total, uint256 today,,,) = vault.opsReserve();
        assertEq(total, paid);
        assertEq(today, paid);
        assertLe(
            vault.platformAccrued() + vault.claimableFees(ROUTE_A) + vault.stockPoolAvailable(),
            address(vault).balance,
            "solvency invariant"
        );

        // publishDistribution is reimbursed too
        keeperBefore = KEEPER.balance;
        _publishUsdtEpoch(vault, true);
        assertGt(KEEPER.balance, keeperBefore, "publish reimbursed");
    }

    function test_opsReserve_GasPriceIsClamped() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.01 ether, 0.1 ether, 0.1 gwei);
        vm.txGasPrice(500 gwei); // keeper tries to inflate its reimbursement
        _fund(vault, 100 ether);
        vm.recordLogs();
        _buy(vault);
        (uint256 gasUsed, uint256 gasPrice, uint256 amount) = _lastReimbursement();
        assertEq(gasPrice, 0.1 gwei, "clamped to opsMaxGasPrice");
        assertEq(amount, gasUsed * 0.1 gwei, "inflated tx.gasprice earns nothing above the cap");
    }

    function test_opsReserve_PerCallAndPerDayCaps() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.0001 ether, 0.00015 ether, 1 gwei); // per call 0.0001, per day 0.00015
        vm.txGasPrice(1 gwei); // a buy (> 300k gas) costs well above 0.0001 BNB at 1 gwei
        _fund(vault, 100 ether);

        uint256 b0 = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance - b0, 0.0001 ether, "clamped to the per-call cap");
        uint256 b1 = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance - b1, 0.00005 ether, "only the remainder of today's cap");
        uint256 b2 = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance - b2, 0, "day cap exhausted: not reimbursed, buy still succeeds");
        assertEq(vault.buyCount(), 3);
        (, uint256 today,,,) = vault.opsReserve();
        assertEq(today, 0.00015 ether);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        (, today,,,) = vault.opsReserve();
        assertEq(today, 0, "new day bucket");
        uint256 b3 = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance - b3, 0.0001 ether);
        (uint256 total,,,,) = vault.opsReserve();
        assertEq(total, 0.00025 ether);
    }

    function test_opsReserve_PoolShareCapProtectsSmallVaults() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.01 ether, 0.1 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(vault, 0.002 ether); // net 0.0018 → stock pool 0.0009 BNB → 5% = 0.000045 BNB (< gas cost)
        uint256 pool = vault.stockPoolAvailable();
        assertEq(pool, 0.0009 ether);
        uint256 b0 = KEEPER.balance;
        _buy(vault);
        assertEq(KEEPER.balance - b0, pool * 500 / 10000, "at most 5% of the pool seen at entry");
        assertEq(vault.stockSpent(), pool, "buy + reimbursement never exceed the stock pool");
        assertEq(vault.claimableFees(ROUTE_A), 0.0009 ether);
    }

    function test_opsReserve_CapsGatingAndHardMax() public {
        vm.startPrank(ADMIN);
        vault.setOpsCaps(0.01 ether, 0.1 ether, 1 gwei); // exactly the hard maxima
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        vault.setOpsCaps(0.01 ether + 1, 0.1 ether, 1 gwei);
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        vault.setOpsCaps(0.01 ether, 0.1 ether + 1, 1 gwei);
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        vault.setOpsCaps(0.01 ether, 0.1 ether, 1 gwei + 1);
        vm.stopPrank();

        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        vm.prank(KEEPER); // the beneficiary cannot raise its own caps
        vault.setOpsCaps(0.01 ether, 0.1 ether, 1 gwei);

        vm.startPrank(FLAP_GUARDIAN);
        vault.setOpsCaps(0, 0, 0);
        vault.setVerifier(VERIFIER);
        vm.stopPrank();
        (,, uint256 perCall,,) = vault.opsReserve();
        assertEq(perCall, 0);
        assertEq(vault.verifier(), VERIFIER);
    }

    function test_pokeTwap_ReimbursedAndScopedToOwnStocks() public {
        StonksPadVault v = _newVault(STONKS, address(0));
        vm.prank(ADMIN);
        v.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(v, 10 ether);

        vm.expectRevert(bytes(unicode"Not a stock of this vault / 不是本金库的股票"));
        vm.prank(KEEPER);
        v.pokeTwap(USDT);
        vm.expectRevert(bytes(unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"));
        vm.prank(USER);
        v.pokeTwap(STONKS);

        uint256 b0 = KEEPER.balance;
        vm.prank(KEEPER);
        v.pokeTwap(STONKS);
        (IStonksPadVaultFactory.TwapObs memory latest,) =
            factory.twapObservations(0xDb6f1D044b8b2887a6C450D0D13176C81E3F936d);
        assertEq(latest.timestamp, uint32(vm.getBlockTimestamp()), "checkpoint recorded");
        uint256 paid = KEEPER.balance - b0;
        assertGt(paid, 0);
        assertEq(v.stockSpent(), paid, "reimbursement is a stock-pool expense");
    }

    function test_opsReserve_FailedPayoutDoesNotBlockTheAction() public {
        StonksPadVault v = _newVault(STONKS, address(0));
        RejectingKeeper rejecting = new RejectingKeeper();
        vm.startPrank(ADMIN);
        v.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        factory.setKeeper(address(rejecting));
        vm.stopPrank();
        vm.txGasPrice(1 gwei);
        _fund(v, 10 ether);

        rejecting.poke(address(v), STONKS); // payout to a contract without receive() fails
        (IStonksPadVaultFactory.TwapObs memory latest,) =
            factory.twapObservations(0xDb6f1D044b8b2887a6C450D0D13176C81E3F936d);
        assertEq(latest.timestamp, uint32(vm.getBlockTimestamp()), "the action itself succeeded");
        (uint256 total, uint256 today,,,) = v.opsReserve();
        assertEq(total + today, 0, "accounting rolled back");
        assertEq(v.stockSpent(), 0);
        assertEq(address(rejecting).balance, 0);
    }

    /* =====================================================================
       Review findings (F1, M1, M2, W2, W4, W6)
       ===================================================================== */

    /// @dev F1 / Rule 001: no parameter change (here: keeper rotated onto the Guardian) may lock the Guardian out.
    function test_guardianApprovalSurvivesKeeperRotation() public {
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        vm.prank(ADMIN);
        factory.setKeeper(FLAP_GUARDIAN);
        vm.prank(FLAP_GUARDIAN);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        (,, bool fast) = vault.getEpochApproval(epochId);
        assertTrue(fast);
    }

    /// @dev M1: a freshly set verifier is inert for 24h, so an admin swapping both keys cannot beat the veto window.
    function test_newVerifierIsTimeLockedFor24h() public {
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        bytes32 root = _rootOf(epochId, stocks, amounts);
        (,, uint64 open24h,,) = vault.getEpoch(epochId);

        vm.prank(ADMIN);
        vault.setVerifier(VERIFIER);
        assertEq(vault.verifierSince(), uint64(vm.getBlockTimestamp()));
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, root);
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, root);
        // by the time the new verifier is active, this epoch's own 24h window has already elapsed
        assertGe(vm.getBlockTimestamp() + 1, open24h);

        // re-setting the verifier restarts the lock
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ADMIN);
        vault.setVerifier(USER);
        assertEq(vault.verifierSince(), uint64(vm.getBlockTimestamp()));
    }

    /// @dev M2: the approval is bound to the root the verifier recomputed.
    function test_approvalIsBoundToTheRoot() public {
        _activateVerifier(vault);
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        vm.expectRevert(bytes(unicode"Root mismatch / 根哈希不匹配"));
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, bytes32(uint256(0xBAD)));
        (,, bool fast) = vault.getEpochApproval(epochId);
        assertFalse(fast);
        vm.prank(VERIFIER);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
    }

    /// @dev W2: a second poke inside 30 minutes would be a reimbursed no-op; it is rejected instead.
    function test_pokeTwap_RateLimited() public {
        StonksPadVault v = _newVault(STONKS, address(0));
        vm.prank(ADMIN);
        v.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(v, 10 ether);
        vm.prank(KEEPER);
        v.pokeTwap(STONKS);
        uint256 spentAfterFirst = v.stockSpent();
        vm.warp(vm.getBlockTimestamp() + 29 minutes);
        vm.expectRevert(bytes(unicode"Poke interval not elapsed / 刷新间隔未到"));
        vm.prank(KEEPER);
        v.pokeTwap(STONKS);
        assertEq(v.stockSpent(), spentAfterFirst, "no reimbursement for a rejected poke");
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.prank(FLAP_GUARDIAN); // Guardian can run it too (Rule 001)
        v.pokeTwap(STONKS);
    }

    /// @dev W6: a reimbursed publish books the payout against the stock pool only and leaves reserves untouched.
    function test_reimbursedPublish_LeavesReservesUntouched() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(vault, 10 ether);
        _buy(vault);
        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = vault.stockUndistributed(USDT);
        uint256 cakeBefore = vault.stockUndistributed(CAKE);
        uint256 spentBefore = vault.stockSpent();
        uint256 keeperBefore = KEEPER.balance;
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        vault.publishDistribution(
            _leaf(1, HOLDER, stocks, amounts), stocks, amounts, "ipfs://k", uint64(block.number - 1)
        );

        uint256 paid = KEEPER.balance - keeperBefore;
        assertGt(paid, 0, "caller reimbursed");
        assertEq(vault.stockSpent(), spentBefore + paid, "booked against the stock pool");
        assertEq(vault.epochRemaining(1, USDT), amounts[0], "epoch reserve is exactly what was published");
        assertEq(vault.stockUndistributed(USDT), 0);
        assertEq(vault.stockUndistributed(CAKE), cakeBefore, "other stock balances untouched");
        assertEq(IERC20(USDT).balanceOf(address(vault)), amounts[0], "no stock token moved");
    }

    /// @dev W6 / Rule 001: the Guardian can use the 5-argument publish. The Flap Guardian contract rejects plain
    ///      BNB transfers, so it is simply not reimbursed; the action itself must still succeed.
    function test_guardianPublishWithSnapshot_SucceedsWithoutReimbursement() public {
        vm.prank(ADMIN);
        vault.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        vm.txGasPrice(1 gwei);
        _fund(vault, 10 ether);
        _buy(vault);
        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = vault.stockUndistributed(USDT);
        uint256 spentBefore = vault.stockSpent();
        uint256 guardianBefore = FLAP_GUARDIAN.balance;
        vm.roll(block.number + 5);
        vm.prank(FLAP_GUARDIAN);
        vault.publishDistribution(
            _leaf(1, HOLDER, stocks, amounts), stocks, amounts, "ipfs://g", uint64(block.number - 1)
        );

        assertEq(vault.epochCount(), 1, "published");
        (uint64 snap,,) = vault.getEpochApproval(1);
        assertEq(snap, uint64(block.number - 1));
        assertEq(FLAP_GUARDIAN.balance, guardianBefore, "Guardian contract does not accept plain BNB");
        assertEq(vault.stockSpent(), spentBefore, "failed payout fully rolled back");
    }

    /// @dev W6: the payout happens inside the reentrancy guard.
    function test_reentrantKeeperCannotReenterDuringPayout() public {
        StonksPadVault v = _newVault(STONKS, address(0));
        ReentrantKeeper evil = new ReentrantKeeper(v, STONKS);
        vm.startPrank(ADMIN);
        v.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        factory.setKeeper(address(evil));
        vm.stopPrank();
        vm.txGasPrice(1 gwei);
        _fund(v, 10 ether);
        evil.poke();
        // the receiver only accepts the payout when its re-entry attempt was stopped by the reentrancy guard
        (uint256 total,,,,) = v.opsReserve();
        assertGt(total, 0, "re-entry hit the guard, payout accepted");
        assertEq(address(evil).balance, total, "paid exactly once");
    }

    /// @dev W4: a receiver that burns all forwarded gas cannot starve the rollback.
    function test_gasBurningKeeperCannotBreakTheAction() public {
        StonksPadVault v = _newVault(STONKS, address(0));
        GasBurningKeeper burner = new GasBurningKeeper();
        vm.startPrank(ADMIN);
        v.setOpsCaps(0.003 ether, 0.03 ether, 1 gwei);
        factory.setKeeper(address(burner));
        vm.stopPrank();
        vm.txGasPrice(1 gwei);
        _fund(v, 10 ether);
        burner.poke{gas: 1_500_000}(address(v), STONKS);
        (uint256 total,,,,) = v.opsReserve();
        assertEq(total, 0);
        assertEq(v.stockSpent(), 0);
    }

    /* =====================================================================
       v1.2 — factory-level defaults
       ===================================================================== */

    /// @dev One admin transaction per setting at the factory; every later launch starts configured.
    function test_factoryDefaults_CopiedIntoNewVaults() public {
        assertEq(vault.verifier(), address(0), "no defaults yet: features off");

        vm.startPrank(ADMIN);
        factory.setDefaultVerifier(VERIFIER);
        factory.setDefaultOpsCaps(0.0002 ether, 0.005 ether, 0.1 gwei);
        vm.stopPrank();
        uint64 setAt = uint64(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 3 days);

        StonksPadVault v = _newVault(USDT, CAKE);
        assertEq(v.verifier(), VERIFIER);
        assertEq(v.verifierSince(), setAt, "the factory's timestamp, not the launch time");
        (,, uint256 perCall, uint256 perDay, uint256 gasPrice) = v.opsReserve();
        assertEq(perCall, 0.0002 ether);
        assertEq(perDay, 0.005 ether);
        assertEq(gasPrice, 0.1 gwei);
        // vaults created before the defaults existed are untouched
        assertEq(vault.verifier(), address(0));

        // the default verifier has been in place for > 24h: the fast path works in the new vault at once
        _fund(v, 10 ether);
        _buy(v);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(v, true);
        vm.prank(VERIFIER);
        v.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        (,, bool fast) = v.getEpochApproval(epochId);
        assertTrue(fast);
    }

    /// @dev The 24h inertness rule survives: a freshly changed default is inert in the vaults created after
    ///      the change until 24h have passed since the change (a launch neither restarts nor skips the lock).
    function test_factoryDefaults_FreshDefaultVerifierIsInertInNewVaults() public {
        vm.prank(ADMIN);
        factory.setDefaultVerifier(VERIFIER);
        uint256 setAt = vm.getBlockTimestamp();
        vm.warp(setAt + 1 hours);

        StonksPadVault v = _newVault(USDT, CAKE);
        _fund(v, 10 ether);
        _buy(v);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(v, true);
        bytes32 root = _rootOf(epochId, stocks, amounts);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        v.approveEpoch(epochId, root);

        vm.warp(setAt + 24 hours - 1);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        v.approveEpoch(epochId, root);

        // active exactly 24h after the factory change; this epoch (published at +1h) is still inside its own 24h
        vm.warp(setAt + 24 hours);
        vm.prank(VERIFIER);
        v.approveEpoch(epochId, root);
    }

    /// @dev Changing the factory default never reaches into existing vaults; the per-vault override still
    ///      works and restarts that vault's own 24h lock.
    function test_factoryDefaults_ExistingVaultsKeepTheirCopyAndOverridesStillWork() public {
        vm.startPrank(ADMIN);
        factory.setDefaultVerifier(VERIFIER);
        factory.setDefaultOpsCaps(0.0002 ether, 0.005 ether, 0.1 gwei);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        StonksPadVault v = _newVault(USDT, CAKE);

        vm.startPrank(ADMIN);
        factory.setDefaultVerifier(USER); // e.g. a hostile or mistaken change
        factory.setDefaultOpsCaps(0.01 ether, 0.1 ether, 1 gwei);
        vm.stopPrank();
        assertEq(v.verifier(), VERIFIER, "existing vault keeps its verifier");
        (,, uint256 perCall,,) = v.opsReserve();
        assertEq(perCall, 0.0002 ether, "existing vault keeps its caps");

        // per-vault override: new key, inert for 24h in this vault
        vm.prank(ADMIN);
        v.setVerifier(ROUTE_A);
        assertEq(v.verifierSince(), uint64(vm.getBlockTimestamp()));
        _fund(v, 10 ether);
        _buy(v);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(v, true);
        bytes32 root = _rootOf(epochId, stocks, amounts);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(ROUTE_A);
        v.approveEpoch(epochId, root);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER); // the replaced key lost its power immediately
        v.approveEpoch(epochId, root);

        vm.prank(ADMIN);
        v.setOpsCaps(0, 0, 0);
        (,, perCall,,) = v.opsReserve();
        assertEq(perCall, 0);
    }

    function test_factoryDefaults_GatingAndHardMaxima() public {
        assertEq(factory.OPS_HARD_MAX_PER_CALL(), vault.OPS_HARD_MAX_PER_CALL());
        assertEq(factory.OPS_HARD_MAX_PER_DAY(), vault.OPS_HARD_MAX_PER_DAY());
        assertEq(factory.OPS_HARD_MAX_GAS_PRICE(), vault.OPS_HARD_MAX_GAS_PRICE());

        vm.startPrank(KEEPER);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        factory.setDefaultVerifier(VERIFIER);
        vm.expectRevert(bytes(unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"));
        factory.setDefaultOpsCaps(1, 1, 1);
        vm.stopPrank();

        vm.startPrank(ADMIN);
        vm.expectRevert(bytes(unicode"Verifier must differ from keeper / 验证者不能是 keeper"));
        factory.setDefaultVerifier(KEEPER);
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        factory.setDefaultOpsCaps(0.01 ether + 1, 0.1 ether, 1 gwei);
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        factory.setDefaultOpsCaps(0.01 ether, 0.1 ether + 1, 1 gwei);
        vm.expectRevert(bytes(unicode"Ops cap above hard max / 运营上限超过硬上限"));
        factory.setDefaultOpsCaps(0.01 ether, 0.1 ether, 1 gwei + 1);
        factory.setDefaultOpsCaps(0.01 ether, 0.1 ether, 1 gwei); // exactly the hard maxima
        vm.stopPrank();

        // Guardian can do both (Rule 001) and can switch the defaults off again
        vm.startPrank(FLAP_GUARDIAN);
        factory.setDefaultVerifier(VERIFIER);
        factory.setDefaultOpsCaps(0, 0, 0);
        factory.setDefaultVerifier(address(0));
        vm.stopPrank();
        (address ver, uint64 since, uint256 a, uint256 b, uint256 c) = factory.vaultDefaults();
        assertEq(ver, address(0));
        assertEq(since, uint64(vm.getBlockTimestamp()));
        assertEq(a + b + c, 0);
    }

    /// @dev A default verifier that later becomes the keeper is refused at approval time in every vault.
    function test_factoryDefaults_KeeperRotatedOntoDefaultVerifierCannotApprove() public {
        vm.prank(ADMIN);
        factory.setDefaultVerifier(VERIFIER);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        StonksPadVault v = _newVault(USDT, CAKE);
        _fund(v, 10 ether);
        _buy(v);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(v, true);
        bytes32 root = _rootOf(epochId, stocks, amounts);
        vm.prank(ADMIN);
        factory.setKeeper(VERIFIER);
        vm.expectRevert(bytes(unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"));
        vm.prank(VERIFIER);
        v.approveEpoch(epochId, root);
    }

    /// @dev Decodes the last OpsReimbursed(address,uint256,uint256,uint256) from the recorded logs.
    function _lastReimbursement() internal returns (uint256 gasUsed, uint256 gasPrice, uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("OpsReimbursed(address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (gasUsed, gasPrice, amount) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "OpsReimbursed not emitted");
    }
}
