// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {StonksPadVault} from "./StonksPadVault.sol";
import {AllocationRow, FeeRouteInit, StockAlloc} from "./StonksPadTypes.sol";
import {IStonksPadVaultFactory} from "./interfaces/IStonksPadVaultFactory.sol";
import {IStonksPadVaultDefaults} from "./interfaces/IStonksPadVaultDefaults.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IPancakeV2Router, IPancakeV2Factory, IPancakeV3SmartRouter} from "./interfaces/IPancake.sol";
import {PancakeV2Twap} from "./libs/PancakeV2Twap.sol";
import {StonksPadSwapLib} from "./StonksPadSwapLib.sol";

import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @title StonksPadVaultFactory
/// @notice Beacon-backed factory for `StonksPadVault` proxies plus the platform-level settings the
///         vaults read at call time (keeper, treasury, platform fee, DEX addresses, stock registry,
///         TWAP checkpoints).
///
/// @dev  ── UPGRADE AUTHORITY ───────────────────────────────────────────────
///
///       The vault implementation and the `UpgradeableBeacon` are deployed by the deploy script
///       *before* the factory (deploying them inline pushed the factory initcode past the EIP-3860
///       49,152-byte limit). The beacon address is a constructor argument and the constructor
///       refuses any beacon whose owner is not the Flap Guardian. The factory keeps no upgrade
///       path of its own: the Guardian calls `UpgradeableBeacon.upgradeTo()` directly. There is no
///       other owner / admin / upgrader.
///
///       ── COMMISSION (Rule 002 justification) ─────────────────────────────
///
///       Flap's recommended commission formula is 6% of revenue when the tax rate is ≤ 1% and
///       `6 / taxRateBps` above that. StonksPad instead targets a flat **10% of the gross tax**
///       collected by the token. Flap's TaxProcessor already deducts its own protocol fee
///       (`feeRate`, 10% on BNB Chain at the time of writing) before forwarding the market share to
///       the vault, so the vault-level `platformFeeBps` that yields 10% of gross is
///       `1000 * 10000 / (10000 - feeRate)` = 1111 for a 10% Flap fee. The constructor default stays
///       at 1000 (10% of net); `MAX_PLATFORM_FEE_BPS` = 1200 bounds the setting so the platform can
///       never take more than 12% of net (≈ 10.8% of gross at a 10% Flap fee). Each vault snapshots
///       the value at creation, so it can never be raised retroactively. Justification: the fee is
///       not operator profit — 80% is swapped into STONKS and burned, 10% goes to STONKS NFT
///       holders and 10% funds the platform; the flat structure keeps the launcher-facing split
///       independent of the tax rate.
///
///       ── ACCESS ──────────────────────────────────────────────────────────
///
///       Platform settings are changeable by `platformAdmin` AND the Flap Guardian (hardcoded,
///       irrevocable). Custom modifiers are used (no OZ AccessControl), so no `revokeRole` override
///       is needed.
contract StonksPadVaultFactory is VaultFactoryBaseV2, IStonksPadVaultFactory, IStonksPadVaultDefaults {
    /* ========== CONSTANTS ========== */

    uint256 public constant BPS = 10_000;
    /// @notice Hard cap for `platformFeeBps` (12% of net vault revenue; ≈ 10.8% of gross at a 10% Flap fee).
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1200;
    uint256 public constant MAX_ROUTES = 16;
    uint256 public constant MAX_STOCKS = 10;
    uint256 public constant MIN_ORACLE_STALENESS = 1 hours;
    uint256 public constant MAX_ORACLE_STALENESS = 7 days;
    /// @dev Hard maxima of the default operations-reserve caps; identical to the vault's own constants.
    uint256 public constant OPS_HARD_MAX_PER_CALL = 0.01 ether;
    uint256 public constant OPS_HARD_MAX_PER_DAY = 0.1 ether;
    uint256 public constant OPS_HARD_MAX_GAS_PRICE = 1 gwei;

    /* ========== IMMUTABLES ========== */

    /// @notice `UpgradeableBeacon` all vault proxies delegate to. Owner = Flap Guardian (checked at construction).
    address public immutable beacon;
    address public immutable override wbnb;
    address public immutable override pancakeV2Router;
    address public immutable override pancakeV2Factory;
    address public immutable override pancakeV3Router;
    address public immutable override pancakeV3Factory;
    address public immutable override pancakeV3Quoter;

    /* ========== STORAGE ========== */

    address public override platformAdmin;
    address public override keeper;
    /// @notice Receiver of the platform fee (the `StonksPadTreasury`).
    address public override platformTreasury;
    uint16 public override platformFeeBps;
    /// @notice Chainlink BNB/USD feed shared by every Chainlink-mode price floor.
    address public override bnbUsdFeed;
    /// @notice Maximum age of a Chainlink answer accepted by `buyStocks()`.
    uint256 public override oracleStaleness;
    /// @notice Stock token every launch must include as a stock row (zero = no requirement).
    address public override mandatoryStock;

    /// @notice v1.2: fast-path verifier copied into every new vault (zero = fast path off for new vaults).
    address public defaultVerifier;
    /// @notice When `defaultVerifier` was last set. New vaults copy it, so a default that has been in
    ///         place for 24h is active in a new vault at once, while a freshly changed default stays
    ///         inert in the vaults created after the change until 24h have passed since the change.
    uint64 public defaultVerifierSince;
    /// @notice v1.2: operations-reserve caps copied into every new vault (all zero = reimbursement off).
    uint256 public defaultOpsMaxPerCall;
    uint256 public defaultOpsMaxPerDay;
    uint256 public defaultOpsMaxGasPrice;

    mapping(address => StockInfo) internal _stocks;
    address[] internal _stockList;

    /// @dev pair → [latest, previous] cumulative-price checkpoints.
    mapping(address => TwapObs[2]) internal _twap;

    mapping(address => bool) public override isVault;
    address[] internal _vaults;

    /* ========== EVENTS ========== */

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);
    event PlatformFeeBpsUpdated(uint16 bps);
    event PlatformTreasuryUpdated(address treasury);
    event KeeperUpdated(address keeper);
    event PlatformAdminUpdated(address admin);
    event StockRegistered(
        address indexed stock, uint8 dexKind, uint8 oracleMode, address priceFeed, bytes path, bool enabled
    );
    event StockEnabledUpdated(address indexed stock, bool enabled);
    event BnbUsdFeedUpdated(address feed);
    event OracleStalenessUpdated(uint256 seconds_);
    event MandatoryStockUpdated(address stock);
    event TwapObservationRecorded(address indexed pair, uint32 timestamp);
    event DefaultVerifierUpdated(address verifier);
    event DefaultOpsCapsUpdated(uint256 perCall, uint256 perDay, uint256 maxGasPrice);

    /* ========== MODIFIERS ========== */

    /// @dev Guardian must always be able to call every privileged function (Flap Rule 001/002).
    modifier onlyAdminOrGuardian() {
        require(
            msg.sender == platformAdmin || msg.sender == _getGuardian(),
            unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"
        );
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @param beacon_           `UpgradeableBeacon` pointing at a `StonksPadVault` implementation; its
    ///                          owner MUST already be the Flap Guardian.
    /// @param wbnb_             Wrapped BNB.
    /// @param v2Router_         PancakeSwap V2 router (its `factory()` is used for TWAP pairs).
    /// @param v3Router_         PancakeSwap V3 SmartRouter.
    /// @param v3Quoter_         PancakeSwap V3 QuoterV2.
    /// @param bnbUsdFeed_       Chainlink BNB/USD feed.
    /// @param platformAdmin_    StonksPad ops address.
    /// @param keeper_           StonksPad backend keeper.
    /// @param platformTreasury_ Receiver of the platform fee (StonksPadTreasury once deployed).
    constructor(
        address beacon_,
        address wbnb_,
        address v2Router_,
        address v3Router_,
        address v3Quoter_,
        address bnbUsdFeed_,
        address platformAdmin_,
        address keeper_,
        address platformTreasury_
    ) {
        require(beacon_ != address(0), unicode"Zero beacon / beacon 地址为零");
        require(
            UpgradeableBeacon(beacon_).owner() == _getGuardian(),
            unicode"Beacon owner must be Guardian / beacon 所有者必须是 Guardian"
        );
        require(
            UpgradeableBeacon(beacon_).implementation() != address(0),
            unicode"Beacon has no implementation / beacon 没有实现合约"
        );
        require(wbnb_ != address(0), unicode"Zero WBNB / WBNB 地址为零");
        require(v2Router_ != address(0), unicode"Zero V2 router / V2 路由地址为零");
        require(v3Router_ != address(0), unicode"Zero V3 router / V3 路由地址为零");
        require(v3Quoter_ != address(0), unicode"Zero V3 quoter / V3 报价器地址为零");
        require(bnbUsdFeed_ != address(0), unicode"Zero BNB feed / BNB 价格源地址为零");
        require(platformAdmin_ != address(0), unicode"Zero admin / 管理员地址为零");
        require(keeper_ != address(0), unicode"Zero keeper / keeper 地址为零");
        require(platformTreasury_ != address(0), unicode"Zero treasury / 金库地址为零");

        beacon = beacon_;

        wbnb = wbnb_;
        pancakeV2Router = v2Router_;
        pancakeV2Factory = IPancakeV2Router(v2Router_).factory();
        require(pancakeV2Factory != address(0), unicode"Zero V2 factory / V2 工厂地址为零");
        pancakeV3Router = v3Router_;
        pancakeV3Factory = IPancakeV3SmartRouter(v3Router_).factory();
        require(pancakeV3Factory != address(0), unicode"Zero V3 factory / V3 工厂地址为零");
        pancakeV3Quoter = v3Quoter_;

        platformAdmin = platformAdmin_;
        keeper = keeper_;
        platformTreasury = platformTreasury_;
        platformFeeBps = 1000;
        bnbUsdFeed = bnbUsdFeed_;
        oracleStaleness = 36 hours;
    }

    /* ========== IVaultFactory ========== */

    /// @notice Deploy and initialise a new `BeaconProxy` vault. Only callable by the VaultPortal.
    /// @param taxToken   Predicted tax token address.
    /// @param quoteToken Must be `address(0)` (native BNB).
    /// @param creator    Original launcher.
    /// @param vaultData  `abi.encode(AllocationRow[])` — see `vaultDataSchema()`.
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal / 仅限 VaultPortal 调用");
        require(quoteToken == address(0), unicode"Native BNB only / 仅支持原生 BNB");

        AllocationRow[] memory rows = abi.decode(vaultData, (AllocationRow[]));
        require(rows.length > 0, unicode"Empty allocation / 分配为空");

        uint256 routeCount;
        uint256 stockCount_;
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].isStock) stockCount_++;
            else routeCount++;
        }
        require(routeCount <= MAX_ROUTES, unicode"Too many fee routes / 手续费路由过多");
        require(stockCount_ <= MAX_STOCKS, unicode"Too many stocks / 股票过多");

        FeeRouteInit[] memory routes = new FeeRouteInit[](routeCount);
        StockAlloc[] memory stocks = new StockAlloc[](stockCount_);
        uint256 ri;
        uint256 si;
        uint256 sum;
        uint256 minHolding;
        bool hasMandatory;
        for (uint256 i = 0; i < rows.length; i++) {
            AllocationRow memory row = rows[i];
            require(row.target != address(0), unicode"Zero target / 目标地址为零");
            require(row.bps > 0, unicode"Zero bps / 份额为零");
            for (uint256 j = 0; j < i; j++) {
                require(
                    rows[j].target != row.target || rows[j].isStock != row.isStock,
                    unicode"Duplicate target / 重复的目标地址"
                );
            }
            if (row.minHolding != 0) {
                require(
                    minHolding == 0 || minHolding == row.minHolding,
                    unicode"Inconsistent minHolding / minHolding 不一致"
                );
                minHolding = row.minHolding;
            }
            sum += row.bps;
            if (row.isStock) {
                require(_stocks[row.target].enabled, unicode"Stock not registered / 股票未注册");
                if (row.target == mandatoryStock) hasMandatory = true;
                stocks[si++] = StockAlloc({token: row.target, bps: row.bps});
            } else {
                routes[ri++] = FeeRouteInit({recipient: row.target, bps: row.bps});
            }
        }
        require(sum == BPS, unicode"Allocations must sum to 10000 / 份额总和必须为 10000");
        require(mandatoryStock == address(0) || hasMandatory, unicode"Mandatory stock missing / 缺少必选股票");

        vault = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    StonksPadVault.initialize,
                    (address(this), taxToken, creator, platformFeeBps, minHolding, routes, stocks)
                )
            )
        );
        isVault[vault] = true;
        _vaults.push(vault);
        emit VaultCreated(vault, taxToken, creator);
    }

    /// @notice Only native BNB is supported as the quote token.
    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    /* ========== PLATFORM SETTINGS (admin | Guardian) ========== */

    /// @notice Set the platform fee for vaults created from now on (existing vaults keep their snapshot).
    function setPlatformFeeBps(uint16 bps) external onlyAdminOrGuardian {
        require(bps <= MAX_PLATFORM_FEE_BPS, unicode"Fee above hard cap / 费用超过上限");
        platformFeeBps = bps;
        emit PlatformFeeBpsUpdated(bps);
    }

    function setPlatformTreasury(address treasury) external onlyAdminOrGuardian {
        require(treasury != address(0), unicode"Zero treasury / 金库地址为零");
        platformTreasury = treasury;
        emit PlatformTreasuryUpdated(treasury);
    }

    function setKeeper(address keeper_) external onlyAdminOrGuardian {
        require(keeper_ != address(0), unicode"Zero keeper / keeper 地址为零");
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    /// @notice v1.2: set the verifier new vaults start with. Existing vaults are not touched (they keep
    ///         their copy; use the vault's own `setVerifier`). Restarts the 24h activation lock for the
    ///         vaults created from now on.
    function setDefaultVerifier(address verifier_) external onlyAdminOrGuardian {
        require(
            verifier_ == address(0) || verifier_ != keeper,
            unicode"Verifier must differ from keeper / 验证者不能是 keeper"
        );
        defaultVerifier = verifier_;
        defaultVerifierSince = uint64(block.timestamp);
        emit DefaultVerifierUpdated(verifier_);
    }

    /// @notice v1.2: set the operations-reserve caps new vaults start with (bounded by the same hard
    ///         maxima as the vault's own `setOpsCaps`). Existing vaults are not touched.
    function setDefaultOpsCaps(uint256 perCall, uint256 perDay, uint256 maxGasPrice) external onlyAdminOrGuardian {
        require(
            perCall <= OPS_HARD_MAX_PER_CALL && perDay <= OPS_HARD_MAX_PER_DAY && maxGasPrice <= OPS_HARD_MAX_GAS_PRICE,
            unicode"Ops cap above hard max / 运营上限超过硬上限"
        );
        defaultOpsMaxPerCall = perCall;
        defaultOpsMaxPerDay = perDay;
        defaultOpsMaxGasPrice = maxGasPrice;
        emit DefaultOpsCapsUpdated(perCall, perDay, maxGasPrice);
    }

    /// @inheritdoc IStonksPadVaultDefaults
    function vaultDefaults() external view override returns (address, uint64, uint256, uint256, uint256) {
        return (defaultVerifier, defaultVerifierSince, defaultOpsMaxPerCall, defaultOpsMaxPerDay, defaultOpsMaxGasPrice);
    }

    function setPlatformAdmin(address admin) external onlyAdminOrGuardian {
        require(admin != address(0), unicode"Zero admin / 管理员地址为零");
        platformAdmin = admin;
        emit PlatformAdminUpdated(admin);
    }

    /// @notice Register (or update) a stock token, its PancakeSwap swap path and its oracle mode.
    /// @param stock      Stock token address.
    /// @param dexKind    PancakeV2 or PancakeV3 (TwapV2 requires PancakeV2, TwapV3 requires PancakeV3).
    /// @param path       V2: `abi.encode(address[])`; V3: packed path. Must start at WBNB and end at `stock`.
    /// @param oracleMode Chainlink (needs `priceFeed`), TwapV2 (every hop must be an existing V2 pair) or
    ///                   TwapV3 (every hop must be an existing V3 pool whose oracle already covers the
    ///                   30-minute window — call `increaseV3ObservationCardinality` first if not).
    /// @param priceFeed  Chainlink STOCK/USD feed (Chainlink mode only).
    /// @param enabled    Whether vaults may buy this stock.
    function registerStock(
        address stock,
        DexKind dexKind,
        bytes calldata path,
        OracleMode oracleMode,
        address priceFeed,
        bool enabled
    ) external onlyAdminOrGuardian {
        require(stock != address(0), unicode"Zero stock / 股票地址为零");
        require(stock != wbnb, unicode"Stock cannot be WBNB / 股票不能是 WBNB");
        if (dexKind == DexKind.PancakeV2) {
            address[] memory p = abi.decode(path, (address[]));
            require(p.length >= 2, unicode"Path too short / 路径过短");
            require(p[0] == wbnb, unicode"Path must start at WBNB / 路径必须以 WBNB 开始");
            require(p[p.length - 1] == stock, unicode"Path must end at stock / 路径必须以股票结束");
            if (oracleMode == OracleMode.TwapV2) {
                for (uint256 i = 0; i + 1 < p.length; i++) {
                    require(
                        IPancakeV2Factory(pancakeV2Factory).getPair(p[i], p[i + 1]) != address(0),
                        unicode"Pair not found / 交易对不存在"
                    );
                }
            }
        } else {
            require(oracleMode != OracleMode.TwapV2, unicode"TWAP requires a V2 path / TWAP 需要 V2 路径");
            require(path.length >= 43 && (path.length - 20) % 23 == 0, unicode"Invalid V3 path / V3 路径无效");
            require(
                address(bytes20(path[0:20])) == wbnb, unicode"Path must start at WBNB / 路径必须以 WBNB 开始"
            );
            require(
                address(bytes20(path[path.length - 20:])) == stock,
                unicode"Path must end at stock / 路径必须以股票结束"
            );
            if (oracleMode == OracleMode.TwapV3) _requireV3TwapReady(path);
        }
        if (oracleMode == OracleMode.TwapV3) {
            require(dexKind == DexKind.PancakeV3, unicode"TWAP V3 requires a V3 path / TWAP V3 需要 V3 路径");
        }
        if (oracleMode == OracleMode.Chainlink) {
            require(priceFeed != address(0), unicode"Zero price feed / 价格源地址为零");
            // sanity: the feed must answer
            IChainlinkFeed(priceFeed).decimals();
        }
        if (_stocks[stock].path.length == 0) {
            _stockList.push(stock);
        }
        _stocks[stock] =
            StockInfo({enabled: enabled, dexKind: dexKind, oracleMode: oracleMode, priceFeed: priceFeed, path: path});
        emit StockRegistered(stock, uint8(dexKind), uint8(oracleMode), priceFeed, path, enabled);
    }

    /// @notice Set the Chainlink BNB/USD feed used by every Chainlink-mode price floor.
    function setBnbUsdFeed(address feed) external onlyAdminOrGuardian {
        require(feed != address(0), unicode"Zero BNB feed / BNB 价格源地址为零");
        IChainlinkFeed(feed).decimals();
        bnbUsdFeed = feed;
        emit BnbUsdFeedUpdated(feed);
    }

    /// @notice Set the maximum accepted age of Chainlink answers (bounded to [1 hour, 7 days]).
    function setOracleStaleness(uint256 seconds_) external onlyAdminOrGuardian {
        require(
            seconds_ >= MIN_ORACLE_STALENESS && seconds_ <= MAX_ORACLE_STALENESS,
            unicode"Staleness out of bounds / 过期时间超出范围"
        );
        oracleStaleness = seconds_;
        emit OracleStalenessUpdated(seconds_);
    }

    /// @notice Enable / disable an already registered stock without changing its path.
    function setStockEnabled(address stock, bool enabled) external onlyAdminOrGuardian {
        require(_stocks[stock].path.length != 0, unicode"Stock not registered / 股票未注册");
        _stocks[stock].enabled = enabled;
        emit StockEnabledUpdated(stock, enabled);
    }

    /// @notice Set the stock every launch must include (zero disables the requirement).
    function setMandatoryStock(address stock) external onlyAdminOrGuardian {
        require(stock == address(0) || _stocks[stock].path.length != 0, unicode"Stock not registered / 股票未注册");
        mandatoryStock = stock;
        emit MandatoryStockUpdated(stock);
    }

    /// @dev Every hop pool must exist and its oracle must already answer a 30-minute `observe`
    ///      (delegated to the external swap library to keep the factory under EIP-170).
    function _requireV3TwapReady(bytes memory path) internal view {
        StonksPadSwapLib.checkV3TwapReady(pancakeV3Factory, path);
    }

    /// @notice Grow the observation buffer of every V3 pool along `stock`'s path so that a
    ///         30-minute TWAP becomes available. Permissionless (the caller pays the storage).
    function increaseV3ObservationCardinality(address stock, uint16 cardinalityNext) external {
        StockInfo storage info = _stocks[stock];
        require(info.path.length != 0, unicode"Stock not registered / 股票未注册");
        require(info.dexKind == DexKind.PancakeV3, unicode"TWAP V3 requires a V3 path / TWAP V3 需要 V3 路径");
        StonksPadSwapLib.increaseV3Cardinality(pancakeV3Factory, info.path, cardinalityNext);
    }

    /* ========== TWAP CHECKPOINTS (permissionless) ========== */

    /// @inheritdoc IStonksPadVaultFactory
    /// @dev A new checkpoint replaces `latest` only once `latest` is at least `MIN_TWAP_WINDOW` old
    ///      (the old `latest` becomes `previous`), so a usable ≥ 30-minute window always survives a
    ///      refresh. The checkpoint value is read from the pair's own cumulative counters: callers can
    ///      choose *when* to record, never *what*.
    function updateTwapObservations(address stock) external override {
        StockInfo storage info = _stocks[stock];
        require(info.path.length != 0, unicode"Stock not registered / 股票未注册");
        require(info.oracleMode == OracleMode.TwapV2, unicode"Stock is not in TWAP mode / 股票不是 TWAP 模式");
        address[] memory p = abi.decode(info.path, (address[]));
        for (uint256 i = 0; i + 1 < p.length; i++) {
            address pair = IPancakeV2Factory(pancakeV2Factory).getPair(p[i], p[i + 1]);
            require(pair != address(0), unicode"Pair not found / 交易对不存在");
            _recordObservation(pair);
        }
    }

    function _recordObservation(address pair) internal {
        (uint256 p0, uint256 p1, uint32 nowTs) = PancakeV2Twap.currentCumulativePrices(pair);
        TwapObs[2] storage slots = _twap[pair];
        if (slots[0].timestamp != 0 && PancakeV2Twap.age(slots[0], nowTs) < PancakeV2Twap.MIN_TWAP_WINDOW) {
            return; // latest is still fresh: keep the current window
        }
        slots[1] = slots[0];
        slots[0] = TwapObs({price0Cumulative: p0, price1Cumulative: p1, timestamp: nowTs});
        emit TwapObservationRecorded(pair, nowTs);
    }

    /* ========== VIEWS ========== */

    /// @inheritdoc IStonksPadVaultFactory
    function getStock(address stock) external view override returns (StockInfo memory info) {
        info = _stocks[stock];
    }

    /// @inheritdoc IStonksPadVaultFactory
    function twapObservations(address pair)
        external
        view
        override
        returns (TwapObs memory latest, TwapObs memory previous)
    {
        latest = _twap[pair][0];
        previous = _twap[pair][1];
    }

    /// @notice Flap Guardian for this chain (exposed for the treasury).
    function guardian() external view override returns (address) {
        return _getGuardian();
    }

    function stockCount() external view returns (uint256) {
        return _stockList.length;
    }

    function getStockList() external view returns (address[] memory) {
        return _stockList;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function getVaults(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = _vaults.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _vaults[i];
        }
    }

    /// @notice Current vault implementation behind the beacon.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @notice Beacon owner (expected to be the Flap Guardian).
    function beaconOwner() external view returns (address) {
        return UpgradeableBeacon(beacon).owner();
    }

    /* ========== LAUNCH VALIDATION (spec v2.2) ========== */

    /// @dev Native BNB only; Flap's dividend split is not supported (the vault distributes stocks
    ///      itself); Flap-native deflation and LP splits are allowed as long as a non-zero market
    ///      share reaches the vault.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, unicode"StonksPad vault supports native BNB only / StonksPad 金库仅支持原生 BNB");
        }
        if (data.dividendBps != 0) {
            return (
                false,
                unicode"Flap dividend split is not supported (dividendBps must be 0) / 不支持 Flap 分红拆分（dividendBps 必须为 0）"
            );
        }
        if (data.vaultBps == 0) {
            return (false, unicode"mktBps must be > 0 (vault share) / mktBps 必须大于 0（金库份额）");
        }
        return (true, "");
    }

    /// @notice Machine-readable form of the constraints enforced in `_validateBeforeLaunch`.
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](3);
        policies[0] = FactoryPolicy({
            target: "quoteToken",
            operator: "eq",
            value: abi.encode(address(0)),
            description: unicode"Quote token must be native BNB. / 底池币种必须为原生 BNB。"
        });
        policies[1] = FactoryPolicy({
            target: "dividendBps",
            operator: "eq",
            value: abi.encode(uint256(0)),
            description: unicode"Flap dividend split must be 0. / Flap 分红拆分必须为 0。"
        });
        policies[2] = FactoryPolicy({
            target: "mktBps",
            operator: "gt",
            value: abi.encode(uint256(0)),
            description: unicode"The vault (market) share must be greater than 0. / 金库（市场）份额必须大于 0。"
        });
    }

    /* ========== SCHEMA ========== */

    /// @inheritdoc VaultFactoryBaseV2
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Creates a StonksPad vault. Each row allocates a share (bps; all rows sum to 10000) of the "
            unicode"net tax revenue either to a fee recipient wallet (isStock = false, claimable BNB) or to a stock token "
            unicode"(isStock = true, bought on PancakeSwap by the keeper and distributed to holders via merkle claims). "
            unicode"Stock tokens must be registered in the factory and the mandatory stock (STONKS) must be included. "
            unicode"minHolding is the minimum token balance for distribution eligibility; enter the same value in every row. "
            unicode"A platform fee is deducted first. / "
            unicode"创建 StonksPad 金库。每一行将净税收的一部分（bps，所有行合计 10000）分配给手续费接收钱包"
            unicode"（isStock = false，可领取 BNB）或股票代币（isStock = true，由 keeper 在 PancakeSwap 买入并通过默克尔领取分配给持有者）。"
            unicode"股票代币必须已在工厂注册，且必须包含必选股票（STONKS）。minHolding 为参与分配的最低持仓，每行填写相同的值。"
            unicode"平台费用优先扣除。";
        schema.fields = new FieldDescriptor[](4);
        schema.fields[0] = FieldDescriptor("target", "address", "Fee recipient wallet or registered stock token", 0);
        schema.fields[1] =
            FieldDescriptor("bps", "uint16", "Share of net revenue in basis points (all rows sum to 10000)", 0);
        schema.fields[2] = FieldDescriptor("isStock", "bool", "true = stock token row, false = fee recipient row", 0);
        schema.fields[3] = FieldDescriptor(
            "minHolding",
            "uint256",
            "Minimum tax-token balance for stock distribution eligibility (same value in every row)",
            18
        );
        schema.isArray = true;
    }
}
