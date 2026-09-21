// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {StonksPadVaultUISchema} from "./StonksPadVaultUISchema.sol";
import {AllocationRow, FeeRouteInit, StockAlloc} from "./StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "./interfaces/IStonksPadVaultFactory.sol";
import {IStonksPadVaultDefaults} from "./interfaces/IStonksPadVaultDefaults.sol";
import {IWBNB} from "./interfaces/IWBNB.sol";
import {StonksPadSwapLib} from "./StonksPadSwapLib.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/utils/cryptography/MerkleProof.sol";

/// @title StonksPadVault
/// @notice Flap Tax Vault for StonksPad launches on BNB Chain. Receives 100% of the post-Flap
///         tax revenue as native BNB and splits it:
///
///           1. platform fee (`platformFeeBps`, snapshot at init) → accrued and pushed to the StonksPad
///              treasury (`factory.platformTreasury()`) by `withdrawPlatformFee()` (permissionless; the
///              treasury's `collect()` batches it). `receive()` cannot push itself (Rule 005);
///           2. fee routes: fixed list of (recipient, bps) → each recipient claims BNB via `claimFees()`;
///           3. stock pool: the sum of stock-row bps → the keeper buys the configured stock tokens on
///              PancakeSwap via `buyStocks()`, publishes per-epoch merkle roots via
///              `publishDistribution()`, and holders claim via `claimStocks()`.
///
/// @dev  ── ACCOUNTING MODEL ────────────────────────────────────────────────
///
///       `receive()` only increments counters (`totalReceived`, `totalNet`, `platformAccrued`) and
///       emits one event. Every share is derived lazily from `totalNet`:
///
///           routeClaimable(i)  = totalNet * feeRoutes[i].bps / BPS - feeRoutes[i].claimed
///           stockPoolAvailable = totalNet * stockPoolBps / BPS - stockSpent
///
///       Because each term is a floor of a share of `totalNet`, the invariant
///       `balance >= platformAccrued + Σ routeClaimable + stockPoolAvailable` always holds; rounding
///       dust stays in the vault.
///
///       ── UPGRADEABILITY ──────────────────────────────────────────────────
///
///       Deployed behind an OpenZeppelin `BeaconProxy`. The beacon is owned by the Flap Guardian
///       only; there is no other owner, admin or upgrader, and no emergency-withdraw functions
///       (Rule 009 upgradeable exception). Storage is append-only; see `__gap`.
///
///       ── CODE SIZE ───────────────────────────────────────────────────────
///
///       Two external libraries are linked at deploy time to stay under EIP-170:
///       `StonksPadVaultUISchema` (static UI schema) and `StonksPadSwapLib` (quote, Chainlink
///       floor and swap execution, DELEGATECALLed in the vault's context).
///
///       ── ACCESS ──────────────────────────────────────────────────────────
///
///       Privileged functions are callable by the keeper (read live from the factory) AND the Flap
///       Guardian (`_getGuardian()`, hardcoded, irrevocable).
contract StonksPadVault is Initializable, VaultBaseV2, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    uint256 public constant BPS = 10_000;
    /// @notice Hard cap for `maxSlippageBps` (5%).
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant MAX_ROUTES = 16;
    uint256 public constant MAX_STOCKS = 10;
    /// @notice Hard cap for `maxOracleDeviationBps` (10%).
    uint16 public constant MAX_ORACLE_DEVIATION_BPS = 1000;
    /// @notice Hard bounds for `maxSpendPerBuy` (keeper cannot exceed 20 BNB per call nor starve buys).
    uint256 public constant MAX_SPEND_PER_BUY = 20 ether;
    uint256 public constant MIN_SPEND_PER_BUY = 0.1 ether;
    /// @notice Minimum time between two `buyStocks()` calls.
    uint256 public constant MIN_BUY_INTERVAL = 10 minutes;
    /// @notice Delay between `publishDistribution()` and the first `claimStocks()`; the veto window.
    uint256 public constant CLAIM_DELAY = 24 hours;
    /// @notice v1.1: claim delay after an independent verifier approved the epoch (veto window stays open).
    uint256 public constant FAST_CLAIM_DELAY = 30 minutes;
    /// @notice v1.1 operations reserve: hard maxima for the admin-tunable reimbursement caps.
    uint256 public constant OPS_HARD_MAX_PER_CALL = 0.01 ether;
    uint256 public constant OPS_HARD_MAX_PER_DAY = 0.1 ether;
    uint256 public constant OPS_HARD_MAX_GAS_PRICE = 1 gwei;
    /// @notice Minimum time between two reimbursed `pokeTwap` calls (a fresher checkpoint is a no-op).
    uint256 public constant POKE_INTERVAL = 30 minutes;
    /// @notice Upper bound for the snapshot CID (it is stored; its length drives measured gas).
    uint256 public constant MAX_CID_LENGTH = 128;
    /// @notice A single reimbursement never exceeds this share of the stock pool seen at call entry.
    uint256 public constant OPS_MAX_POOL_SHARE_BPS = 500;
    /// @notice Flat gas added to the measured usage (base transaction cost + the payout itself).
    uint256 public constant OPS_GAS_OVERHEAD = 40_000;

    /* ========== TYPES ========== */

    struct FeeRoute {
        address recipient;
        uint16 bps;
        uint256 claimed;
    }

    struct FeeRouteView {
        address recipient;
        uint16 bps;
        uint256 claimed;
        uint256 claimable;
    }

    struct StockView {
        address token;
        uint16 bps;
        uint256 undistributed;
        bool enabled;
    }

    /// @dev Locals of `buyStocks()` packed into memory to stay within the EVM stack limit.
    struct BuyCtx {
        IStonksPadVaultFactory f;
        uint256 n;
        uint256 spend;
        uint256 enabledWeight;
        uint256 lastEnabled;
        uint256 allocated;
        uint256 buyId;
        IStonksPadVaultFactory.StockInfo[] infos;
        address[] stocks;
        uint256[] amountsIn;
        uint256[] amountsOut;
    }

    struct Epoch {
        bytes32 root;
        uint64 publishedAt;
        uint64 claimsOpenAt;
        bool cancelled;
        string cid;
        address[] stocks;
        mapping(address => uint256) remaining;
        // ── v1.1 (appended; each epoch owns its own hashed slot region) ──
        uint64 snapshotBlock; // holder-snapshot block the root was built from (0 = legacy / not fast-trackable)
        uint64 approvedAt; // timestamp of approveEpoch (0 = not approved)
    }

    /* ========== STORAGE (append-only) ========== */

    // ── config (fixed after initialize) ──────────────────────────────────
    address public factory;
    address public taxToken;
    address public creator;
    uint16 public platformFeeBps;

    FeeRoute[] internal _feeRoutes;
    mapping(address => uint256) internal _routeIndexPlusOne;

    StockAlloc[] internal _stockAllocs;
    uint16 public stockPoolBps;

    // ── revenue accounting (touched by receive()) ────────────────────────
    uint256 public totalReceived;
    uint256 public totalNet;
    uint256 public platformAccrued;

    // ── stock pool ───────────────────────────────────────────────────────
    uint256 public stockSpent;
    mapping(address => uint256) public stockUndistributed;
    uint16 public maxSlippageBps;
    uint16 public maxOracleDeviationBps;
    uint256 public maxSpendPerBuy;
    uint256 public buyCount;
    uint256 public lastBuyAt;

    // ── merkle distribution ──────────────────────────────────────────────
    uint256 public epochCount;
    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ── appended after the first testnet deployment (storage layout is append-only) ──
    /// @notice Minimum tax-token balance for stock-distribution eligibility (informational; the
    ///         keeper applies it to the off-chain holder snapshot).
    uint256 public minHolding;

    // ── v1.1 (appended; gap 39 → 33). Upgraded proxies start with all of these at zero. ──
    /// @notice Independent second key whose only power is `approveEpoch`. Zero = fast path off.
    address public verifier;
    /// @notice When `verifier` was set. A new verifier can approve only `CLAIM_DELAY` later, so replacing
    ///         the verifier can never get an epoch open faster than the 24h veto window (packed, slot 71).
    uint64 public verifierSince;
    /// @dev Last `pokeTwap` (packed, slot 71).
    uint32 internal lastPokeAt;
    /// @notice Operations-reserve caps (admin | Guardian, bounded by the OPS_HARD_MAX_* constants).
    ///      Internal: read them through `opsReserve()` (separate getters would only cost code size).
    uint256 internal opsMaxPerCall;
    uint256 internal opsMaxPerDay;
    uint256 internal opsMaxGasPrice;
    uint256 internal opsReimbursedTotal;
    uint64 internal opsDay;
    uint192 internal opsReimbursedToday;

    uint256[33] private __gap;

    /* ========== EVENTS ========== */

    event Received(address indexed from, uint256 amount, uint256 platformFee);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event PlatformFeeWithdrawn(address indexed treasury, uint256 amount);
    event StocksBought(
        uint256 indexed buyId, uint256 bnbSpent, address[] stocks, uint256[] amountsIn, uint256[] amountsOut
    );
    event DistributionPublished(uint256 indexed epochId, bytes32 root, address[] stocks, uint256[] amounts, string cid);
    event StocksClaimed(uint256 indexed epochId, address indexed account, address[] stocks, uint256[] amounts);
    event EpochCancelled(uint256 indexed epochId, address indexed by);
    event MaxSlippageUpdated(uint16 bps);
    event MaxOracleDeviationUpdated(uint16 bps);
    event MaxSpendPerBuyUpdated(uint256 amount);
    event EpochApproved(uint256 indexed epochId, address indexed verifier, uint64 claimsOpenAt);
    event VerifierUpdated(address verifier);
    event OpsReimbursed(address indexed to, uint256 gasUsed, uint256 gasPrice, uint256 amount);
    event OpsCapsUpdated(uint256 perCall, uint256 perDay, uint256 maxGasPrice);

    /* ========== MODIFIERS ========== */

    /// @dev Guardian must always be able to call every privileged function (Flap Rule 001).
    modifier onlyKeeperOrGuardian() {
        require(
            msg.sender == IStonksPadVaultFactory(factory).keeper() || msg.sender == _getGuardian(),
            unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"
        );
        _;
    }

    /// @dev Veto path independent from the keeper key: platform admin (multisig) or Guardian.
    modifier onlyAdminOrGuardian() {
        require(
            msg.sender == IStonksPadVaultFactory(factory).platformAdmin() || msg.sender == _getGuardian(),
            unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"
        );
        _;
    }

    /// @dev v1.1 operations reserve: reimburses the caller's measured gas from the stock pool only,
    ///      within the per-call / per-day / gas-price / pool-share caps. Must sit inside `nonReentrant`.
    modifier reimbursed() {
        uint256 gasStart = gasleft();
        uint256 poolAtEntry = stockPoolAvailable();
        _;
        _reimburse(gasStart, poolAtEntry);
    }

    /* ========== INITIALIZER ========== */

    /// @dev Locks the implementation so only proxies can be initialised.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise a freshly deployed `BeaconProxy`. Called once by the factory.
    /// @param factory_        StonksPadVaultFactory address (source of keeper / treasury / stock registry).
    /// @param taxToken_       Predicted tax token address (deployed by VaultPortal right after this call).
    /// @param creator_        Token creator (informational).
    /// @param platformFeeBps_ Platform fee snapshot (bps of gross revenue).
    /// @param minHolding_     Minimum holding for distribution eligibility (informational).
    /// @param routes          Fee routes (already validated by the factory).
    /// @param stocks          Stock allocations (already validated by the factory).
    function initialize(
        address factory_,
        address taxToken_,
        address creator_,
        uint16 platformFeeBps_,
        uint256 minHolding_,
        FeeRouteInit[] calldata routes,
        StockAlloc[] calldata stocks
    ) external initializer {
        __ReentrancyGuard_init();

        require(factory_ != address(0), unicode"Zero factory / 工厂地址为零");
        require(platformFeeBps_ <= BPS, unicode"Platform fee too high / 平台费用过高");
        require(routes.length <= MAX_ROUTES, unicode"Too many fee routes / 手续费路由过多");
        require(stocks.length <= MAX_STOCKS, unicode"Too many stocks / 股票过多");

        factory = factory_;
        taxToken = taxToken_;
        creator = creator_;
        platformFeeBps = platformFeeBps_;
        minHolding = minHolding_;

        uint256 sumBps;
        for (uint256 i = 0; i < routes.length; i++) {
            require(routes[i].recipient != address(0), unicode"Zero recipient / 接收地址为零");
            require(routes[i].bps > 0, unicode"Zero bps / 份额为零");
            require(_routeIndexPlusOne[routes[i].recipient] == 0, unicode"Duplicate recipient / 重复的接收地址");
            // A registered stock token must never be a fee route: BNB pushed to a token contract is lost.
            require(
                IStonksPadVaultFactory(factory_).getStock(routes[i].recipient).path.length == 0,
                unicode"Stock address cannot be a fee route / 股票地址不能作为手续费路由"
            );
            _feeRoutes.push(FeeRoute({recipient: routes[i].recipient, bps: routes[i].bps, claimed: 0}));
            _routeIndexPlusOne[routes[i].recipient] = i + 1;
            sumBps += routes[i].bps;
        }

        uint256 stockBps;
        for (uint256 i = 0; i < stocks.length; i++) {
            require(stocks[i].token != address(0), unicode"Zero stock token / 股票代币地址为零");
            require(stocks[i].bps > 0, unicode"Zero bps / 份额为零");
            for (uint256 j = 0; j < i; j++) {
                require(stocks[j].token != stocks[i].token, unicode"Duplicate stock / 重复的股票");
            }
            _stockAllocs.push(stocks[i]);
            stockBps += stocks[i].bps;
        }
        require(sumBps + stockBps == BPS, unicode"Allocations must sum to 10000 / 份额总和必须为 10000");
        // casting to uint16 is safe because sumBps + stockBps == BPS (10000) was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        stockPoolBps = uint16(stockBps);

        maxSlippageBps = 300;
        maxOracleDeviationBps = 500;
        maxSpendPerBuy = 5 ether;

        // v1.2: start from the factory-level defaults (all zero = both features off). `verifierSince` is the
        // factory's timestamp, so the 24h activation lock is not restarted by a launch. A factory without
        // `vaultDefaults()` (the v1 generation) leaves everything off, as in v1.1. The hard maxima are
        // re-checked here because the vault must not trust the factory for a holder-protecting bound.
        try IStonksPadVaultDefaults(factory_).vaultDefaults() returns (
            address verifier_, uint64 since, uint256 perCall, uint256 perDay, uint256 maxGasPrice
        ) {
            if (
                perCall <= OPS_HARD_MAX_PER_CALL && perDay <= OPS_HARD_MAX_PER_DAY
                    && maxGasPrice <= OPS_HARD_MAX_GAS_PRICE
            ) {
                opsMaxPerCall = perCall;
                opsMaxPerDay = perDay;
                opsMaxGasPrice = maxGasPrice;
            }
            verifier = verifier_;
            verifierSince = since;
        } catch {}
    }

    /* ========== RECEIVE (Rule 005: accounting + event only) ========== */

    /// @notice Accept tax revenue from the Flap TaxProcessor. No loops, no external calls,
    ///         never reverts. Shares are derived lazily from `totalNet`.
    receive() external payable {
        uint256 value = msg.value;
        if (value == 0) return;
        uint256 fee = value * platformFeeBps / BPS;
        platformAccrued += fee;
        totalNet += value - fee;
        totalReceived += value;
        emit Received(msg.sender, value, fee);
    }

    /* ========== USER-FACING WRITES ========== */

    /// @notice Claim the caller's accrued fee-route BNB.
    function claimFees() external nonReentrant {
        uint256 idx = _routeIndexPlusOne[msg.sender];
        require(idx != 0, unicode"Not a fee recipient / 非手续费接收者");
        FeeRoute storage r = _feeRoutes[idx - 1];
        uint256 amount = totalNet * r.bps / BPS - r.claimed;
        require(amount > 0, unicode"Nothing to claim / 无可领取金额");

        r.claimed += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, unicode"Transfer failed / 转账失败");
        emit FeesClaimed(msg.sender, amount);
    }

    /// @notice Claim the caller's stock allocation for one distribution epoch.
    /// @param epochId   Epoch to claim from (1-based).
    /// @param claimData `abi.encode(address[] stocks, uint256[] amounts, bytes32[] proof)`, built by the
    ///                  StonksPad site. Leaf = keccak256(bytes.concat(keccak256(abi.encode(epochId, account, stocks, amounts)))).
    function claimStocks(uint256 epochId, bytes calldata claimData) external nonReentrant {
        (address[] memory stocks, uint256[] memory amounts, bytes32[] memory proof) =
            abi.decode(claimData, (address[], uint256[], bytes32[]));

        require(epochId >= 1 && epochId <= epochCount, unicode"Unknown epoch / 未知的分配期");
        require(!claimed[epochId][msg.sender], unicode"Already claimed / 已经领取过");
        require(stocks.length == amounts.length, unicode"Length mismatch / 长度不匹配");
        require(stocks.length > 0 && stocks.length <= MAX_STOCKS, unicode"Invalid stock count / 股票数量无效");

        Epoch storage ep = _epochs[epochId];
        require(!ep.cancelled, unicode"Epoch cancelled / 分配期已取消");
        require(block.timestamp >= ep.claimsOpenAt, unicode"Claims not open yet / 领取尚未开放");
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epochId, msg.sender, stocks, amounts))));
        require(MerkleProof.verify(proof, ep.root, leaf), unicode"Invalid proof / 证明无效");

        claimed[epochId][msg.sender] = true;
        for (uint256 i = 0; i < stocks.length; i++) {
            require(amounts[i] <= ep.remaining[stocks[i]], unicode"Exceeds epoch reserve / 超出本期储备");
            ep.remaining[stocks[i]] -= amounts[i];
        }
        for (uint256 i = 0; i < stocks.length; i++) {
            if (amounts[i] > 0) {
                IERC20(stocks[i]).safeTransfer(msg.sender, amounts[i]);
            }
        }
        emit StocksClaimed(epochId, msg.sender, stocks, amounts);
    }

    /// @notice Push the accrued platform fee to the factory's current treasury. Permissionless.
    function withdrawPlatformFee() external nonReentrant {
        address treasury = IStonksPadVaultFactory(factory).platformTreasury();
        require(treasury != address(0), unicode"Treasury not set / 未设置金库地址");
        uint256 amount = platformAccrued;
        require(amount > 0, unicode"Nothing to withdraw / 无可提取金额");

        platformAccrued = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, unicode"Transfer failed / 转账失败");
        emit PlatformFeeWithdrawn(treasury, amount);
    }

    /* ========== KEEPER / GUARDIAN WRITES ========== */

    /// @notice Swap up to `maxSpendPerBuy` BNB of the stock pool into the configured stock tokens.
    /// @dev    Stocks currently disabled in the factory registry are skipped (their share stays in the
    ///         pool). Each `minOuts[i]` must be at least the on-chain quote minus `maxSlippageBps`.
    /// @param minOuts  Minimum output per stock, index-aligned with `getStocks()`. Ignored for disabled stocks.
    /// @param deadline Unix timestamp after which the call reverts.
    function buyStocks(uint256[] calldata minOuts, uint256 deadline)
        external
        onlyKeeperOrGuardian
        nonReentrant
        reimbursed
    {
        require(block.timestamp <= deadline, unicode"Deadline passed / 已超过截止时间");
        require(block.timestamp >= lastBuyAt + MIN_BUY_INTERVAL, unicode"Buy interval not elapsed / 买入间隔未到");
        BuyCtx memory c;
        c.n = _stockAllocs.length;
        require(c.n > 0, unicode"No stocks configured / 未配置股票");
        require(minOuts.length == c.n, unicode"minOuts length mismatch / minOuts 长度不匹配");

        uint256 available = stockPoolAvailable();
        // v1.1: keep the reimbursement headroom in the pool, otherwise a buy that drains the pool could
        // never be reimbursed (the reimbursement is paid from the stock pool only).
        available -= _opsCap(available);
        c.spend = available < maxSpendPerBuy ? available : maxSpendPerBuy;
        require(c.spend > 0, unicode"Nothing to buy / 无可用资金");

        c.f = IStonksPadVaultFactory(factory);
        c.infos = new IStonksPadVaultFactory.StockInfo[](c.n);
        c.stocks = new address[](c.n);
        for (uint256 i = 0; i < c.n; i++) {
            c.stocks[i] = _stockAllocs[i].token;
            c.infos[i] = c.f.getStock(c.stocks[i]);
            if (c.infos[i].enabled) {
                c.enabledWeight += _stockAllocs[i].bps;
                c.lastEnabled = i;
            }
        }
        require(c.enabledWeight > 0, unicode"No enabled stocks / 无可用股票");

        // effects before interactions
        stockSpent += c.spend;
        lastBuyAt = block.timestamp;
        c.buyId = ++buyCount;

        IWBNB(c.f.wbnb()).deposit{value: c.spend}();

        c.amountsIn = new uint256[](c.n);
        c.amountsOut = new uint256[](c.n);
        for (uint256 i = 0; i < c.n; i++) {
            if (!c.infos[i].enabled) continue;
            uint256 amountIn =
                i == c.lastEnabled ? c.spend - c.allocated : c.spend * _stockAllocs[i].bps / c.enabledWeight;
            c.allocated += amountIn;
            uint256 out = StonksPadSwapLib.buyOne(
                c.f, c.infos[i], c.stocks[i], amountIn, minOuts[i], maxSlippageBps, maxOracleDeviationBps
            );
            stockUndistributed[c.stocks[i]] += out;
            c.amountsIn[i] = amountIn;
            c.amountsOut[i] = out;
        }
        emit StocksBought(c.buyId, c.spend, c.stocks, c.amountsIn, c.amountsOut);
    }

    /// @notice Publish a merkle root for a new distribution epoch, reserving stock amounts for it.
    /// @param root    Merkle root of leaves keccak256(bytes.concat(keccak256(abi.encode(epochId, account, stocks, amounts)))).
    /// @param stocks  Stock tokens included in this epoch.
    /// @param amounts Total amount of each stock reserved for this epoch (≤ `stockUndistributed`).
    /// @param cid     IPFS CID of the public snapshot / proofs (informational).
    function publishDistribution(
        bytes32 root,
        address[] calldata stocks,
        uint256[] calldata amounts,
        string calldata cid
    ) external onlyKeeperOrGuardian nonReentrant reimbursed {
        _publish(root, stocks, amounts, cid, 0);
    }

    /// @notice v1.1: same as above, additionally recording the holder-snapshot block so that the
    ///         independent verifier can recompute the root and fast-track the epoch.
    /// @param snapshotBlock Block number the holder snapshot was taken at (must be in the past).
    function publishDistribution(
        bytes32 root,
        address[] calldata stocks,
        uint256[] calldata amounts,
        string calldata cid,
        uint64 snapshotBlock
    ) external onlyKeeperOrGuardian nonReentrant reimbursed {
        require(snapshotBlock > 0 && snapshotBlock < block.number, unicode"Invalid snapshot block / 快照区块无效");
        _publish(root, stocks, amounts, cid, snapshotBlock);
    }

    function _publish(
        bytes32 root,
        address[] calldata stocks,
        uint256[] calldata amounts,
        string calldata cid,
        uint64 snapshotBlock
    ) internal {
        require(root != bytes32(0), unicode"Zero root / 根哈希为零");
        require(
            bytes(cid).length > 0 && bytes(cid).length <= MAX_CID_LENGTH,
            unicode"Snapshot CID required (max 128 bytes) / 必须提供快照 CID（最长 128 字节）"
        );
        require(stocks.length == amounts.length, unicode"Length mismatch / 长度不匹配");
        require(stocks.length > 0 && stocks.length <= MAX_STOCKS, unicode"Invalid stock count / 股票数量无效");

        uint256 epochId = ++epochCount;
        Epoch storage ep = _epochs[epochId];
        ep.root = root;
        ep.publishedAt = uint64(block.timestamp);
        ep.claimsOpenAt = uint64(block.timestamp + CLAIM_DELAY);
        ep.cid = cid;
        ep.snapshotBlock = snapshotBlock;
        for (uint256 i = 0; i < stocks.length; i++) {
            require(amounts[i] > 0, unicode"Zero amount / 数量为零");
            require(ep.remaining[stocks[i]] == 0, unicode"Duplicate stock / 重复的股票");
            require(amounts[i] <= stockUndistributed[stocks[i]], unicode"Exceeds undistributed / 超出未分配数量");
            stockUndistributed[stocks[i]] -= amounts[i];
            ep.remaining[stocks[i]] = amounts[i];
            ep.stocks.push(stocks[i]);
        }
        emit DistributionPublished(epochId, root, stocks, amounts, cid);
    }

    /// @notice v1.1 fast path: the independent verifier (or the Guardian) confirms that it recomputed
    ///         the epoch's merkle root from the snapshot at `snapshotBlock`. Claims then open 30 minutes
    ///         after the approval instead of 24 hours after publication. This is the verifier's only
    ///         power: it cannot publish, cancel, buy, change parameters or move funds. The veto
    ///         (`cancelEpoch`) stays available until claims open.
    /// @param expectedRoot The root the verifier recomputed. Binding the approval to the root means a
    ///        replaced / re-orged publish transaction can never inherit an approval meant for another root.
    function approveEpoch(uint256 epochId, bytes32 expectedRoot) external {
        // The Guardian is always allowed (Rule 001: no parameter, e.g. setKeeper, may lock it out). The
        // verifier must be a key distinct from the current keeper and active for at least CLAIM_DELAY.
        require(
            msg.sender == _getGuardian()
                || (msg.sender == verifier
                    && msg.sender != IStonksPadVaultFactory(factory).keeper()
                    && block.timestamp >= uint256(verifierSince) + CLAIM_DELAY),
            unicode"Only active verifier or Guardian / 仅限已生效的验证者或 Guardian"
        );
        require(epochId >= 1 && epochId <= epochCount, unicode"Unknown epoch / 未知的分配期");
        Epoch storage ep = _epochs[epochId];
        require(!ep.cancelled, unicode"Epoch cancelled / 分配期已取消");
        require(ep.snapshotBlock != 0, unicode"Epoch has no snapshot block / 分配期没有快照区块");
        require(ep.approvedAt == 0, unicode"Epoch already approved / 分配期已批准");
        require(ep.root == expectedRoot, unicode"Root mismatch / 根哈希不匹配");
        require(block.timestamp < ep.claimsOpenAt, unicode"Claim window already open / 领取窗口已开放");

        ep.approvedAt = uint64(block.timestamp);
        uint64 fastOpen = uint64(block.timestamp + FAST_CLAIM_DELAY);
        if (fastOpen < ep.claimsOpenAt) ep.claimsOpenAt = fastOpen; // approval can only shorten the delay
        emit EpochApproved(epochId, msg.sender, ep.claimsOpenAt);
    }

    /// @notice Veto a published epoch during its claim delay. Returns the reserved stock to
    ///         `stockUndistributed` so a corrected root can be published. Platform admin or Guardian only
    ///         (independent from the keeper key).
    function cancelEpoch(uint256 epochId) external onlyAdminOrGuardian {
        require(epochId >= 1 && epochId <= epochCount, unicode"Unknown epoch / 未知的分配期");
        Epoch storage ep = _epochs[epochId];
        require(!ep.cancelled, unicode"Epoch cancelled / 分配期已取消");
        require(block.timestamp < ep.claimsOpenAt, unicode"Claim window already open / 领取窗口已开放");
        ep.cancelled = true;
        for (uint256 i = 0; i < ep.stocks.length; i++) {
            address stock = ep.stocks[i];
            stockUndistributed[stock] += ep.remaining[stock];
            ep.remaining[stock] = 0;
        }
        emit EpochCancelled(epochId, msg.sender);
    }

    /// @notice v1.1: set the independent verifier (zero disables the fast path). It must not be the keeper.
    function setVerifier(address verifier_) external onlyAdminOrGuardian {
        require(
            verifier_ == address(0) || verifier_ != IStonksPadVaultFactory(factory).keeper(),
            unicode"Verifier must differ from keeper / 验证者不能是 keeper"
        );
        verifier = verifier_;
        verifierSince = uint64(block.timestamp);
        emit VerifierUpdated(verifier_);
    }

    /// @notice v1.1: set the operations-reserve caps (all zero = reimbursement off).
    function setOpsCaps(uint256 perCall, uint256 perDay, uint256 maxGasPrice) external onlyAdminOrGuardian {
        require(
            perCall <= OPS_HARD_MAX_PER_CALL && perDay <= OPS_HARD_MAX_PER_DAY && maxGasPrice <= OPS_HARD_MAX_GAS_PRICE,
            unicode"Ops cap above hard max / 运营上限超过硬上限"
        );
        opsMaxPerCall = perCall;
        opsMaxPerDay = perDay;
        opsMaxGasPrice = maxGasPrice;
        emit OpsCapsUpdated(perCall, perDay, maxGasPrice);
    }

    /// @notice v1.1: record TWAP checkpoints for one of this vault's TWAP_V2 stocks (reimbursed like the
    ///         other keeper operations). The factory call itself stays permissionless.
    function pokeTwap(address stock) external onlyKeeperOrGuardian nonReentrant reimbursed {
        bool found;
        for (uint256 i = 0; i < _stockAllocs.length; i++) {
            if (_stockAllocs[i].token == stock) found = true;
        }
        require(found, unicode"Not a stock of this vault / 不是本金库的股票");
        require(
            block.timestamp >= uint256(lastPokeAt) + POKE_INTERVAL,
            unicode"Poke interval not elapsed / 刷新间隔未到"
        );
        lastPokeAt = uint32(block.timestamp);
        IStonksPadVaultFactory(factory).updateTwapObservations(stock);
    }

    /// @dev Upper bound of one reimbursement for a pool reference `poolRef`:
    ///      min(per-call cap, what is left of today's cap, 5% of `poolRef`). Zero when the feature is off.
    function _opsCap(uint256 poolRef) internal view returns (uint256 cap) {
        cap = opsMaxPerCall;
        if (cap == 0) return 0;
        uint256 usedToday = opsDay == uint64(block.timestamp / 1 days) ? opsReimbursedToday : 0;
        uint256 other = opsMaxPerDay > usedToday ? opsMaxPerDay - usedToday : 0;
        if (other < cap) cap = other;
        other = poolRef * OPS_MAX_POOL_SHARE_BPS / BPS;
        if (other < cap) cap = other;
    }

    /// @dev Pays `msg.sender` its measured gas cost from the stock pool, clamped by every cap. Never
    ///      reverts: anything above a cap is simply not reimbursed and a failed payout is rolled back.
    function _reimburse(uint256 gasStart, uint256 poolAtEntry) internal {
        uint256 amount = _opsCap(poolAtEntry);
        if (amount == 0) return;
        uint256 price = tx.gasprice < opsMaxGasPrice ? tx.gasprice : opsMaxGasPrice;
        uint256 gasUsed = gasStart - gasleft() + OPS_GAS_OVERHEAD;
        if (gasUsed * price < amount) amount = gasUsed * price;
        uint256 left = stockPoolAvailable();
        if (left < amount) amount = left;
        if (amount == 0) return;

        // effects first: the reimbursement is a stock-pool expense (never fee routes / platform fee)
        uint64 today = uint64(block.timestamp / 1 days);
        uint256 usedToday = opsDay == today ? opsReimbursedToday : 0;
        stockSpent += amount;
        opsReimbursedTotal += amount;
        opsDay = today;
        opsReimbursedToday = uint192(usedToday + amount);
        // bounded gas: a receiver that burns everything must not be able to starve the rollback below
        (bool ok,) = msg.sender.call{value: amount, gas: 30_000}("");
        if (!ok) {
            stockSpent -= amount;
            opsReimbursedTotal -= amount;
            opsReimbursedToday = uint192(usedToday);
            return;
        }
        emit OpsReimbursed(msg.sender, gasUsed, price, amount);
    }

    /// @notice Set the maximum slippage tolerated against the on-chain quote in `buyStocks()`.
    function setMaxSlippageBps(uint16 bps) external onlyKeeperOrGuardian {
        require(bps <= MAX_SLIPPAGE_BPS, unicode"Slippage above hard cap / 滑点超过上限");
        maxSlippageBps = bps;
        emit MaxSlippageUpdated(bps);
    }

    /// @notice Set the maximum deviation tolerated between the DEX execution and the Chainlink price.
    ///         Platform admin or Guardian only (independent from the keeper key that executes buys).
    function setMaxOracleDeviationBps(uint16 bps) external onlyAdminOrGuardian {
        require(bps <= MAX_ORACLE_DEVIATION_BPS, unicode"Deviation above hard cap / 偏差超过上限");
        maxOracleDeviationBps = bps;
        emit MaxOracleDeviationUpdated(bps);
    }

    /// @notice Set the maximum BNB swapped per `buyStocks()` call (bounded to [0.1, 20] BNB).
    function setMaxSpendPerBuy(uint256 amount) external onlyKeeperOrGuardian {
        require(
            amount >= MIN_SPEND_PER_BUY && amount <= MAX_SPEND_PER_BUY,
            unicode"Spend out of bounds / 金额超出范围"
        );
        maxSpendPerBuy = amount;
        emit MaxSpendPerBuyUpdated(amount);
    }

    /* ========== VIEWS ========== */

    /// @notice BNB in the stock pool not yet spent on purchases.
    function stockPoolAvailable() public view returns (uint256) {
        return totalNet * stockPoolBps / BPS - stockSpent;
    }

    /// @notice Aggregate counters for the UI.
    function stats()
        external
        view
        returns (
            uint256 received,
            uint256 net,
            uint256 platformPending,
            uint256 stockPool,
            uint256 spentOnStocks,
            uint256 buys,
            uint256 epochs
        )
    {
        return (totalReceived, totalNet, platformAccrued, stockPoolAvailable(), stockSpent, buyCount, epochCount);
    }

    /// @notice All fee routes with their claimed / claimable amounts.
    function getFeeRoutes() external view returns (FeeRouteView[] memory routes) {
        uint256 n = _feeRoutes.length;
        routes = new FeeRouteView[](n);
        for (uint256 i = 0; i < n; i++) {
            FeeRoute storage r = _feeRoutes[i];
            routes[i] = FeeRouteView({
                recipient: r.recipient, bps: r.bps, claimed: r.claimed, claimable: totalNet * r.bps / BPS - r.claimed
            });
        }
    }

    /// @notice All stock allocations with their undistributed balance and registry status.
    function getStocks() external view returns (StockView[] memory stocks) {
        uint256 n = _stockAllocs.length;
        stocks = new StockView[](n);
        IStonksPadVaultFactory f = IStonksPadVaultFactory(factory);
        for (uint256 i = 0; i < n; i++) {
            address token = _stockAllocs[i].token;
            stocks[i] = StockView({
                token: token,
                bps: _stockAllocs[i].bps,
                undistributed: stockUndistributed[token],
                enabled: f.getStock(token).enabled
            });
        }
    }

    /// @notice Claimable fee-route BNB for `account` (0 if not a recipient).
    function claimableFees(address account) external view returns (uint256 amount) {
        uint256 idx = _routeIndexPlusOne[account];
        if (idx == 0) return 0;
        FeeRoute storage r = _feeRoutes[idx - 1];
        amount = totalNet * r.bps / BPS - r.claimed;
    }

    /// @notice Epoch metadata.
    function getEpoch(uint256 epochId)
        external
        view
        returns (bytes32 root, uint64 publishedAt, uint64 claimsOpenAt, bool cancelled, string memory cid)
    {
        Epoch storage ep = _epochs[epochId];
        return (ep.root, ep.publishedAt, ep.claimsOpenAt, ep.cancelled, ep.cid);
    }

    /// @notice v1.1: snapshot block and approval state of an epoch (`fastPath` = approved by the verifier).
    function getEpochApproval(uint256 epochId)
        external
        view
        returns (uint64 snapshotBlock, uint64 approvedAt, bool fastPath)
    {
        Epoch storage ep = _epochs[epochId];
        return (ep.snapshotBlock, ep.approvedAt, ep.approvedAt != 0);
    }

    /// @notice v1.1: operations-reserve counters and caps.
    function opsReserve()
        external
        view
        returns (uint256 reimbursedTotal, uint256 reimbursedToday, uint256 perCall, uint256 perDay, uint256 maxGasPrice)
    {
        uint256 today = opsDay == uint64(block.timestamp / 1 days) ? opsReimbursedToday : 0;
        return (opsReimbursedTotal, today, opsMaxPerCall, opsMaxPerDay, opsMaxGasPrice);
    }

    /// @notice Stocks reserved in an epoch.
    function epochStocks(uint256 epochId) external view returns (address[] memory) {
        return _epochs[epochId].stocks;
    }

    /// @notice Amount of `stock` still claimable in `epochId`.
    function epochRemaining(uint256 epochId, address stock) external view returns (uint256 amount) {
        amount = _epochs[epochId].remaining[stock];
    }

    /// @notice Whether `account` already claimed `epochId`.
    function hasClaimed(uint256 epochId, address account) external view returns (bool) {
        return claimed[epochId][account];
    }

    /// @notice Current keeper address (read from the factory).
    function keeper() external view returns (address) {
        return IStonksPadVaultFactory(factory).keeper();
    }

    function feeRouteCount() external view returns (uint256) {
        return _feeRoutes.length;
    }

    function stockCount() external view returns (uint256) {
        return _stockAllocs.length;
    }

    /// @notice Dynamic bilingual status banner (text assembled in the linked schema library to keep
    ///         this implementation under the EIP-170 size limit; output identical to v1.0).
    function description() public view override returns (string memory) {
        return StonksPadVaultUISchema.describe(totalReceived, buyCount, epochCount);
    }

    /// @inheritdoc VaultBaseV2
    /// @dev Delegates to the external `StonksPadVaultUISchema` library (pure) to keep the vault
    ///      runtime under the EIP-170 size limit.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema = StonksPadVaultUISchema.build();
    }
}
