// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IStonksPadVaultFactory} from "./interfaces/IStonksPadVaultFactory.sol";
import {IWBNB} from "./interfaces/IWBNB.sol";
import {StonksPadSwapLib} from "./StonksPadSwapLib.sol";
import {StonksPadVault} from "./StonksPadVault.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";

/// @title StonksPadTreasury
/// @notice Receives the platform commission pushed by every `StonksPadVault` and splits it:
///           80% → STONKS buy & burn (keeper-triggered, slippage + reference-price protected),
///           10% → NFT holders wallet,
///           10% → platform wallet.
///
/// @dev  `receive()` is accounting + event only (the vaults' `withdrawPlatformFee()` pushes here and
///       must never be blocked by treasury logic). All work happens in explicit functions:
///       `collect()` pulls accrued fees from vaults, `distribute()` pays the two wallets, and
///       `buyAndBurn()` swaps the burn pool into STONKS and sends it to the dead address.
///
///       Roles are read live from the factory: keeper (executes burns), platformAdmin (settings) and
///       the Flap Guardian (backup for every privileged function). Not upgradeable; no owner.
contract StonksPadTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    uint256 public constant BPS = 10_000;
    uint16 public constant BURN_BPS = 8000;
    uint16 public constant NFT_BPS = 1000;
    uint16 public constant PLATFORM_BPS = 1000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_ORACLE_DEVIATION_BPS = 1000;
    uint256 public constant MAX_SPEND_PER_BURN = 20 ether;
    uint256 public constant MIN_SPEND_PER_BURN = 0.1 ether;
    uint256 public constant MIN_BURN_INTERVAL = 10 minutes;

    /* ========== IMMUTABLES ========== */

    IStonksPadVaultFactory public immutable factory;
    /// @notice Token bought and burned with 80% of the commission (registered in the factory registry).
    address public immutable stonks;
    address public immutable wbnb;

    /* ========== STORAGE ========== */

    address public nftWallet;
    address public platformWallet;

    uint256 public totalReceived;
    uint256 public burnPool;
    uint256 public nftAccrued;
    uint256 public platformAccrued;
    uint256 public totalBurnedBnb;
    uint256 public totalBurnedStonks;
    uint256 public burnCount;
    uint256 public lastBurnAt;

    uint16 public maxSlippageBps = 300;
    uint16 public maxOracleDeviationBps = 500;
    uint256 public maxSpendPerBurn = 5 ether;

    /* ========== EVENTS ========== */

    event Received(address indexed from, uint256 amount, uint256 toBurn, uint256 toNft, uint256 toPlatform);
    event Collected(address indexed vault, uint256 amount);
    event Distributed(
        address indexed nftWallet, uint256 nftAmount, address indexed platformWallet, uint256 platformAmount
    );
    event BoughtAndBurned(uint256 indexed burnId, uint256 bnbSpent, uint256 stonksBurned);
    event WalletsUpdated(address nftWallet, address platformWallet);
    event MaxSlippageUpdated(uint16 bps);
    event MaxOracleDeviationUpdated(uint16 bps);
    event MaxSpendPerBurnUpdated(uint256 amount);

    /* ========== MODIFIERS ========== */

    modifier onlyKeeperOrGuardian() {
        require(
            msg.sender == factory.keeper() || msg.sender == factory.guardian(),
            unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"
        );
        _;
    }

    modifier onlyAdminOrGuardian() {
        require(
            msg.sender == factory.platformAdmin() || msg.sender == factory.guardian(),
            unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"
        );
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @param factory_        StonksPadVaultFactory (roles, DEX addresses, STONKS registry entry).
    /// @param stonks_         STONKS token (must be registered in the factory before the first burn).
    /// @param nftWallet_      Receiver of the 10% NFT holders share.
    /// @param platformWallet_ Receiver of the 10% platform share.
    constructor(address factory_, address stonks_, address nftWallet_, address platformWallet_) {
        require(factory_ != address(0), unicode"Zero factory / 工厂地址为零");
        require(stonks_ != address(0), unicode"Zero STONKS / STONKS 地址为零");
        require(nftWallet_ != address(0) && platformWallet_ != address(0), unicode"Zero wallet / 钱包地址为零");
        factory = IStonksPadVaultFactory(factory_);
        stonks = stonks_;
        wbnb = IStonksPadVaultFactory(factory_).wbnb();
        nftWallet = nftWallet_;
        platformWallet = platformWallet_;
    }

    /* ========== RECEIVE (accounting + event only) ========== */

    receive() external payable {
        uint256 value = msg.value;
        if (value == 0) return;
        uint256 toBurn = value * BURN_BPS / BPS;
        uint256 toNft = value * NFT_BPS / BPS;
        uint256 toPlatform = value - toBurn - toNft;
        burnPool += toBurn;
        nftAccrued += toNft;
        platformAccrued += toPlatform;
        totalReceived += value;
        emit Received(msg.sender, value, toBurn, toNft, toPlatform);
    }

    /* ========== PERMISSIONLESS ========== */

    /// @notice Pull the accrued platform fee from the given vaults into this treasury.
    function collect(address[] calldata vaults) external nonReentrant {
        for (uint256 i = 0; i < vaults.length; i++) {
            require(factory.isVault(vaults[i]), unicode"Not a StonksPad vault / 非 StonksPad 金库");
            StonksPadVault vault = StonksPadVault(payable(vaults[i]));
            uint256 amount = vault.platformAccrued();
            if (amount == 0) continue;
            vault.withdrawPlatformFee();
            emit Collected(vaults[i], amount);
        }
    }

    /// @notice Pay the accrued NFT-holders and platform shares to their wallets.
    function distribute() external nonReentrant {
        uint256 nftAmount = nftAccrued;
        uint256 platformAmount = platformAccrued;
        require(nftAmount > 0 || platformAmount > 0, unicode"Nothing to distribute / 无可分配金额");
        nftAccrued = 0;
        platformAccrued = 0;
        if (nftAmount > 0) {
            (bool ok,) = nftWallet.call{value: nftAmount}("");
            require(ok, unicode"Transfer failed / 转账失败");
        }
        if (platformAmount > 0) {
            (bool ok,) = platformWallet.call{value: platformAmount}("");
            require(ok, unicode"Transfer failed / 转账失败");
        }
        emit Distributed(nftWallet, nftAmount, platformWallet, platformAmount);
    }

    /* ========== KEEPER / GUARDIAN ========== */

    /// @notice Swap up to `maxSpendPerBurn` BNB of the burn pool into STONKS and burn it.
    /// @dev    Same protections as `StonksPadVault.buyStocks()`: `minOut` must clear the DEX-quote
    ///         floor and the reference-price floor (STONKS uses the factory's TWAP oracle mode).
    function buyAndBurn(uint256 minOut, uint256 deadline) external onlyKeeperOrGuardian nonReentrant {
        require(block.timestamp <= deadline, unicode"Deadline passed / 已超过截止时间");
        require(
            block.timestamp >= lastBurnAt + MIN_BURN_INTERVAL, unicode"Burn interval not elapsed / 销毁间隔未到"
        );
        uint256 spend = burnPool < maxSpendPerBurn ? burnPool : maxSpendPerBurn;
        require(spend > 0, unicode"Nothing to burn / 无可销毁资金");
        IStonksPadVaultFactory.StockInfo memory info = factory.getStock(stonks);
        require(info.enabled, unicode"STONKS not registered / STONKS 未注册");

        burnPool -= spend;
        lastBurnAt = block.timestamp;
        uint256 burnId = ++burnCount;

        IWBNB(wbnb).deposit{value: spend}();
        uint256 out =
            StonksPadSwapLib.buyOne(factory, info, stonks, spend, minOut, maxSlippageBps, maxOracleDeviationBps);
        IERC20(stonks).safeTransfer(DEAD, out);

        totalBurnedBnb += spend;
        totalBurnedStonks += out;
        emit BoughtAndBurned(burnId, spend, out);
    }

    /* ========== ADMIN / GUARDIAN ========== */

    function setWallets(address nftWallet_, address platformWallet_) external onlyAdminOrGuardian {
        require(nftWallet_ != address(0) && platformWallet_ != address(0), unicode"Zero wallet / 钱包地址为零");
        nftWallet = nftWallet_;
        platformWallet = platformWallet_;
        emit WalletsUpdated(nftWallet_, platformWallet_);
    }

    function setMaxSlippageBps(uint16 bps) external onlyAdminOrGuardian {
        require(bps <= MAX_SLIPPAGE_BPS, unicode"Slippage above hard cap / 滑点超过上限");
        maxSlippageBps = bps;
        emit MaxSlippageUpdated(bps);
    }

    function setMaxOracleDeviationBps(uint16 bps) external onlyAdminOrGuardian {
        require(bps <= MAX_ORACLE_DEVIATION_BPS, unicode"Deviation above hard cap / 偏差超过上限");
        maxOracleDeviationBps = bps;
        emit MaxOracleDeviationUpdated(bps);
    }

    function setMaxSpendPerBurn(uint256 amount) external onlyAdminOrGuardian {
        require(
            amount >= MIN_SPEND_PER_BURN && amount <= MAX_SPEND_PER_BURN,
            unicode"Spend out of bounds / 金额超出范围"
        );
        maxSpendPerBurn = amount;
        emit MaxSpendPerBurnUpdated(amount);
    }
}
