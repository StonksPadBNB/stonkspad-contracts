// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {StonksPadTestBase} from "./StonksPadTestBase.sol";

import {StonksPadVault} from "../src/StonksPadVault.sol";
import {StonksPadVaultFactory} from "../src/StonksPadVaultFactory.sol";
import {AllocationRow} from "../src/StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "../src/interfaces/IStonksPadVaultFactory.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

interface IWBNBFull {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title Answers to an external reviewer's four questions, as executable checks (BSC mainnet fork)
/// @notice Every vault in this suite runs the DEPLOYED mainnet implementation v1.2
///         (0xf89953bfe1ECec08b147006C511E3c7E19B5bb6E, with its on-chain libraries) behind a fresh beacon:
///         the bytecode under test is the bytecode on mainnet, not a recompilation.
contract ReviewerQuestionsTest is StonksPadTestBase {
    address internal constant MAINNET_IMPL_V12 = 0xf89953bfe1ECec08b147006C511E3c7E19B5bb6E;

    function setUp() public {
        _forkBSCMainnet();
        UpgradeableBeacon beacon = new UpgradeableBeacon(MAINNET_IMPL_V12);
        beacon.transferOwnership(FLAP_GUARDIAN);
        factory = new StonksPadVaultFactory(
            address(beacon),
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
        factory.setOracleStaleness(7 days);
        vm.stopPrank();
        vault = _newVault(USDT, CAKE);
        assertEq(UpgradeableBeacon(factory.beacon()).implementation(), MAINNET_IMPL_V12);
    }

    /// @dev Vault with one fee route of `routeBps` and USDT as the only stock.
    function _vault(uint16 routeBps) internal returns (StonksPadVault v) {
        AllocationRow[] memory rows = new AllocationRow[](2);
        rows[0] = AllocationRow(ROUTE_A, routeBps, false, 0);
        rows[1] = AllocationRow(USDT, 10000 - routeBps, true, 0);
        vm.prank(VAULT_PORTAL);
        v = StonksPadVault(payable(factory.newVault(address(0xBEEF), address(0), USER, abi.encode(rows))));
    }

    /* =====================================================================
       Q1 — totalNet is cumulative; what bounds fees and the stock pool
       ===================================================================== */

    /// @dev The reviewer's sequence with a 40% fee route, 60% stock pool and no platform fee:
    ///      receive 100, claim 40, receive 40.
    function test_Q1_Receive100_Claim40_Receive40() public {
        vm.prank(ADMIN);
        factory.setPlatformFeeBps(0);
        StonksPadVault v = _vault(4000);

        _fund(v, 100 ether);
        assertEq(v.totalNet(), 100 ether);
        assertEq(v.claimableFees(ROUTE_A), 40 ether);
        assertEq(v.stockPoolAvailable(), 60 ether);

        uint256 before = ROUTE_A.balance;
        vm.prank(ROUTE_A);
        v.claimFees();
        assertEq(ROUTE_A.balance - before, 40 ether);
        assertEq(v.totalNet(), 100 ether, "totalNet is lifetime revenue: a claim does not reduce it");
        assertEq(v.claimableFees(ROUTE_A), 0, "the claim is tracked in route.claimed");
        assertEq(v.stockPoolAvailable(), 60 ether, "a fee claim does not touch the stock pool");
        assertEq(address(v).balance, 60 ether);
        vm.expectRevert(bytes(unicode"Nothing to claim / 无可领取金额"));
        vm.prank(ROUTE_A);
        v.claimFees();

        _fund(v, 40 ether);
        assertEq(v.totalNet(), 140 ether);
        assertEq(v.claimableFees(ROUTE_A), 16 ether, "40% of 140 minus the 40 already claimed");
        assertEq(v.stockPoolAvailable(), 84 ether, "60% of 140, nothing spent yet");
        assertEq(address(v).balance, 100 ether);
        assertEq(address(v).balance, v.claimableFees(ROUTE_A) + v.stockPoolAvailable(), "exactly backed");

        vm.prank(ROUTE_A);
        v.claimFees();
        assertEq(ROUTE_A.balance - before, 56 ether, "lifetime total = 40% of 140");
        assertEq(address(v).balance, v.stockPoolAvailable());
    }

    /// @dev Same property with the mainnet platform fee (1111 bps), two fee claims, a platform-fee
    ///      withdrawal and a stock purchase in between: the balance always covers every obligation.
    function test_Q1_BalanceCoversObligationsThroughClaimsAndBuys() public {
        vm.prank(ADMIN);
        factory.setPlatformFeeBps(1111);
        StonksPadVault v = _vault(4000);

        _fund(v, 100 ether);
        _assertBacked(v);
        vm.prank(ROUTE_A);
        v.claimFees();
        _assertBacked(v);
        v.withdrawPlatformFee();
        _assertBacked(v);
        _fund(v, 40 ether);
        _assertBacked(v);

        uint256 poolBefore = v.stockPoolAvailable();
        uint256 balanceBefore = address(v).balance;
        _buy(v);
        uint256 spent = balanceBefore - address(v).balance;
        assertEq(v.stockSpent(), spent, "purchases are tracked in stockSpent");
        assertEq(v.stockPoolAvailable(), poolBefore - spent);
        _assertBacked(v);

        vm.prank(ROUTE_A);
        v.claimFees();
        _assertBacked(v);
        assertEq(v.claimableFees(ROUTE_A), 0);
    }

    function _assertBacked(StonksPadVault v) internal view {
        uint256 owed = v.platformAccrued() + v.claimableFees(ROUTE_A) + v.stockPoolAvailable();
        assertGe(address(v).balance, owed, "balance below obligations");
        assertLe(address(v).balance - owed, 2, "only rounding dust above obligations");
    }

    /* =====================================================================
       Q2 — claim amounts are bound by the merkle leaf; no partial claims
       ===================================================================== */

    function _twoLeafEpoch()
        internal
        returns (
            uint256 epochId,
            address[] memory stocks,
            uint256[] memory mine,
            uint256[] memory theirs,
            bytes32[] memory myProof
        )
    {
        _fund(vault, 10 ether);
        _buy(vault);
        uint256 total = vault.stockUndistributed(USDT);
        stocks = new address[](1);
        stocks[0] = USDT;
        mine = new uint256[](1);
        mine[0] = total / 4; // HOLDER
        theirs = new uint256[](1);
        theirs[0] = total - total / 4; // USER
        epochId = vault.epochCount() + 1;
        bytes32 a = _leaf(epochId, HOLDER, stocks, mine);
        bytes32 b = _leaf(epochId, USER, stocks, theirs);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        uint256[] memory totals = new uint256[](1);
        totals[0] = total;
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        vault.publishDistribution(root, stocks, totals, "ipfs://two-leaves", uint64(block.number - 1));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        myProof = new bytes32[](1);
        myProof[0] = b;
    }

    function test_Q2_AmountsAndAccountAreBoundByTheLeaf() public {
        (
            uint256 epochId,
            address[] memory stocks,
            uint256[] memory mine,
            uint256[] memory theirs,
            bytes32[] memory proof
        ) = _twoLeafEpoch();
        bytes memory invalid = bytes(unicode"Invalid proof / 证明无效");
        uint256 reserve = vault.epochRemaining(epochId, USDT);
        assertEq(reserve, mine[0] + theirs[0]);

        // more than the leaf: the whole remaining reserve, or one unit more
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = reserve;
        vm.expectRevert(invalid);
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, amounts, proof));
        amounts[0] = mine[0] + 1;
        vm.expectRevert(invalid);
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, amounts, proof));

        // less than the leaf: a partial claim is not possible either
        amounts[0] = mine[0] - 1;
        vm.expectRevert(invalid);
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, amounts, proof));

        // another stock in place of the leaf's stock
        address[] memory otherStocks = new address[](1);
        otherStocks[0] = CAKE;
        vm.expectRevert(invalid);
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(otherStocks, mine, proof));

        // someone else presenting HOLDER's leaf data and proof: msg.sender is part of the leaf
        vm.expectRevert(invalid);
        vm.prank(MALLORY());
        vault.claimStocks(epochId, abi.encode(stocks, mine, proof));

        // nothing was paid or reserved away by the failed attempts
        assertEq(vault.epochRemaining(epochId, USDT), reserve);
        assertEq(IERC20(USDT).balanceOf(HOLDER), 0);

        // the exact leaf: paid in full, once
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, mine, proof));
        assertEq(IERC20(USDT).balanceOf(HOLDER), mine[0]);
        assertEq(vault.epochRemaining(epochId, USDT), theirs[0], "the other holder's share is untouched");
        vm.expectRevert(bytes(unicode"Already claimed / 已经领取过"));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, mine, proof));
    }

    /// @dev The epoch id is part of the leaf as well: a leaf of epoch 1 is worthless in epoch 2.
    function test_Q2_LeafIsBoundToTheEpoch() public {
        (uint256 epochId, address[] memory stocks, uint256[] memory mine,, bytes32[] memory proof) = _twoLeafEpoch();
        // a second epoch published with the SAME root (same leaves hashed with epoch id 1)
        _fund(vault, 10 ether);
        _buy(vault);
        uint256[] memory totals = new uint256[](1);
        totals[0] = vault.stockUndistributed(USDT);
        (bytes32 root,,,,) = vault.getEpoch(epochId);
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        vault.publishDistribution(root, stocks, totals, "ipfs://replayed-root", uint64(block.number - 1));
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        vm.expectRevert(bytes(unicode"Invalid proof / 证明无效"));
        vm.prank(HOLDER);
        vault.claimStocks(epochId + 1, abi.encode(stocks, mine, proof));
        vm.prank(HOLDER);
        vault.claimStocks(epochId, abi.encode(stocks, mine, proof)); // still valid where it belongs
    }

    function MALLORY() internal returns (address) {
        return makeAddr("reviewer:mallory");
    }

    /* =====================================================================
       Q3 — WBNB deposit is 1:1
       ===================================================================== */

    function test_Q3_WbnbIsFullyBackedAndDepositIsOneToOne() public {
        IWBNBFull wbnb = IWBNBFull(WBNB);
        // WBNB9: totalSupply() is the contract's BNB balance — every WBNB is backed by exactly one BNB
        assertEq(wbnb.totalSupply(), WBNB.balance);
        vm.deal(address(this), 3 ether);
        wbnb.deposit{value: 3 ether}();
        assertEq(wbnb.balanceOf(address(this)), 3 ether);
        assertEq(wbnb.totalSupply(), WBNB.balance);
    }

    /// @dev buyStocks wraps exactly `spend` and the swaps consume exactly `spend`: no WBNB is left in the
    ///      vault and the BNB that left the vault equals stockSpent.
    function test_Q3_BuyStocksWrapsAndSpendsExactlyTheSameAmount() public {
        _fund(vault, 10 ether);
        uint256 pool = vault.stockPoolAvailable();
        uint256 expectedSpend = pool < vault.maxSpendPerBuy() ? pool : vault.maxSpendPerBuy();
        uint256 balanceBefore = address(vault).balance;
        uint256 wbnbBackingBefore = WBNB.balance;
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0);

        _buy(vault);

        uint256 spent = balanceBefore - address(vault).balance;
        assertEq(spent, vault.stockSpent());
        assertEq(spent, expectedSpend, "spends min(stock pool, maxSpendPerBuy)");
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0, "every wrapped wei was consumed by the swaps");
        assertGe(WBNB.balance, wbnbBackingBefore, "the BNB sits in WBNB (pools may unwrap part of it later)");
        assertGt(vault.stockUndistributed(USDT), 0);
        assertGt(vault.stockUndistributed(CAKE), 0);
    }

    /* =====================================================================
       Q4 — stockUndistributed across publish / cancel / 24h path / claim
       ===================================================================== */

    /// @dev token balance == stockUndistributed + sum of the reserves of all epochs, at every step.
    function _assertStockBacked(uint256 epochs) internal view {
        uint256 reserved;
        for (uint256 id = 1; id <= epochs; id++) {
            reserved += vault.epochRemaining(id, USDT);
        }
        assertEq(IERC20(USDT).balanceOf(address(vault)), vault.stockUndistributed(USDT) + reserved, "USDT not backed");
    }

    function test_Q4_UndistributedIsMovedAtPublish_RestoredAtCancel_UntouchedAtClaim() public {
        _fund(vault, 10 ether);
        _buy(vault);
        uint256 bought = vault.stockUndistributed(USDT);
        assertEq(IERC20(USDT).balanceOf(address(vault)), bought, "buyStocks credits what arrived");

        address[] memory stocks = new address[](1);
        stocks[0] = USDT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = bought * 3 / 5;

        // publish #1: undistributed -> epoch reserve
        bytes32 root1 = _leaf(1, HOLDER, stocks, amounts);
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        vault.publishDistribution(root1, stocks, amounts, "ipfs://e1", uint64(block.number - 1));
        assertEq(vault.stockUndistributed(USDT), bought - amounts[0], "decremented at publish");
        assertEq(vault.epochRemaining(1, USDT), amounts[0]);
        _assertStockBacked(1);
        // the same tokens cannot be reserved twice
        uint256[] memory tooMuch = new uint256[](1);
        tooMuch[0] = bought - amounts[0] + 1;
        vm.expectRevert(bytes(unicode"Exceeds undistributed / 超出未分配数量"));
        vm.prank(KEEPER);
        vault.publishDistribution(root1, stocks, tooMuch, "ipfs://x", uint64(block.number - 1));

        // cancel #1: reserve -> undistributed
        vm.prank(ADMIN);
        vault.cancelEpoch(1);
        assertEq(vault.stockUndistributed(USDT), bought, "restored at cancel");
        assertEq(vault.epochRemaining(1, USDT), 0);
        _assertStockBacked(1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(bytes(unicode"Epoch cancelled / 分配期已取消"));
        vm.prank(HOLDER);
        vault.claimStocks(1, _claimData(stocks, amounts));

        // publish #2, then NOTHING: neither approved nor cancelled, it opens by the 24h path
        bytes32 root2 = _leaf(2, HOLDER, stocks, amounts);
        vm.roll(block.number + 5);
        vm.prank(KEEPER);
        vault.publishDistribution(root2, stocks, amounts, "ipfs://e2", uint64(block.number - 1));
        assertEq(vault.stockUndistributed(USDT), bought - amounts[0]);
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(bytes(unicode"Claims not open yet / 领取尚未开放"));
        vm.prank(HOLDER);
        vault.claimStocks(2, _claimData(stocks, amounts));
        vm.warp(vm.getBlockTimestamp() + 1);

        // once open, the epoch can no longer be cancelled or approved
        vm.expectRevert(bytes(unicode"Claim window already open / 领取窗口已开放"));
        vm.prank(ADMIN);
        vault.cancelEpoch(2);
        vm.expectRevert(bytes(unicode"Claim window already open / 领取窗口已开放"));
        vm.prank(FLAP_GUARDIAN);
        vault.approveEpoch(2, root2);
        assertEq(vault.stockUndistributed(USDT), bought - amounts[0], "opening the window changes nothing");
        _assertStockBacked(2);

        // claim: paid from the epoch reserve; stockUndistributed is not touched
        vm.prank(HOLDER);
        vault.claimStocks(2, _claimData(stocks, amounts));
        assertEq(IERC20(USDT).balanceOf(HOLDER), amounts[0]);
        assertEq(vault.epochRemaining(2, USDT), 0);
        assertEq(vault.stockUndistributed(USDT), bought - amounts[0], "untouched at claim");
        assertEq(IERC20(USDT).balanceOf(address(vault)), bought - amounts[0]);
        _assertStockBacked(2);
    }

    /// @dev Fast path: approval only moves claimsOpenAt; the reserve accounting is the same.
    function test_Q4_ApprovalDoesNotMoveAnyStock() public {
        _fund(vault, 10 ether);
        _buy(vault);
        (uint256 epochId, address[] memory stocks, uint256[] memory amounts) = _publishUsdtEpoch(vault, true);
        uint256 undistributed = vault.stockUndistributed(USDT);
        uint256 reserve = vault.epochRemaining(epochId, USDT);
        vm.prank(FLAP_GUARDIAN);
        vault.approveEpoch(epochId, _rootOf(epochId, stocks, amounts));
        assertEq(vault.stockUndistributed(USDT), undistributed);
        assertEq(vault.epochRemaining(epochId, USDT), reserve);
        _assertStockBacked(epochId);
    }
}
