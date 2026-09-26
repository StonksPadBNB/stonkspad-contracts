# StonksPad Vault — Design Document

Status: **APPROVED — all open questions in §11 accepted as recommended (2026-09-12); §14–§16 record the post-audit hardening, the deployment restructuring and the product-owner update of 2026-09-13**
Target chain: BNB Chain (56) / BNB Testnet (97)
Flap spec: VaultBaseV2 + VaultFactoryBaseV2 (factory spec `v2.2`, native BNB quote only)

---

## 1. Overview

StonksPad launches tax tokens on Flap (`VaultPortal.newTokenV6WithVault`). Every launch gets its
own **StonksPadVault** (a `BeaconProxy`), created by the single **StonksPadVaultFactory**.

Flap's TaxProcessor sends 100% of the post-Flap tax revenue (`mktBps = 10000`) to the vault as
native BNB via a plain `call{value}("")`, which lands in `receive()`.

Revenue flow inside the vault:

```
                     receive()  (accounting + event only)
                         │
        ┌────────────────┴────────────────┐
        │ platformFeeBps (snapshot at init)│  → platformAccrued  → withdrawPlatformFee() → factory.platformTreasury()
        └────────────────┬────────────────┘
                         │ net  (totalNet += net)
        ┌────────────────┼────────────────────────────┐
        │                │                            │
  fee route #1 …    fee route #n              stock pool (Σ stock bps)
  (bps_i of net)    (bps_n of net)            (lazy: totalNet*stockPoolBps/1e4 − stockSpent)
  claimFees()       claimFees()                       │ buyStocks()  [keeper | Guardian]
                                                      ▼
                                       stockUndistributed[stock] (ERC20 held by vault)
                                                      │ publishDistribution(root, …)  [keeper | Guardian]
                                                      ▼
                                       epochs[id].remaining[stock]  → claimStocks(epochId, claimData)  [holders]
```

Everything that does real work (swaps, merkle publication, transfers) lives in explicit
functions. `receive()` only updates two counters and emits one event.

---

## 2. Contracts

| Contract | File | Base | Deployed as |
|---|---|---|---|
| `StonksPadVault` | `src/StonksPadVault.sol` | `Initializable`, `VaultBaseV2`, `ReentrancyGuardUpgradeable` | implementation behind `UpgradeableBeacon`; one `BeaconProxy` per token |
| `StonksPadVaultFactory` | `src/StonksPadVaultFactory.sol` | `VaultFactoryBaseV2` | single non-upgradeable contract; takes the beacon address as a constructor arg |
| `StonksPadVaultUISchema` | `src/StonksPadVaultUISchema.sol` | external `library` | deployed once, linked into the vault; holds the static `vaultUISchema()` payload |
| `StonksPadSwapLib` | `src/StonksPadSwapLib.sol` | external `library` | deployed once, linked into the vault and the treasury; DEX quote, reference-price floor (Chainlink or V2 TWAP) and swap execution (DELEGATECALL in caller context) |
| `PancakeV2Twap` | `src/libs/PancakeV2Twap.sol` | internal `library` | UniswapV2-style cumulative-price TWAP helpers (inlined) |
| `PancakeV3Twap` / `TickMath` | `src/libs/PancakeV3Twap.sol`, `src/libs/TickMath.sol` | internal `library` | V3 `observe()`-based average tick → price (MIT TickMath port, tick → sqrt-price only), packed-path parsing |
| `StonksPadTreasury` | `src/StonksPadTreasury.sol` | `ReentrancyGuard` | single contract; receives the platform commission and splits it 80% STONKS buy & burn / 10% NFT wallet / 10% platform wallet |

### 2.1 Code size and deployment order

Keeping the schema strings and swap helpers inline pushed the vault runtime to ~48 KB (EIP-170
limit 24,576 B) and deploying the implementation + beacon inside the factory constructor pushed the
factory initcode to ~72 KB (EIP-3860 limit 49,152 B). Resolution:

- compiler: `via_ir = true`, `optimizer_runs = 200` (`foundry.toml`);
- `vaultUISchema()` body → `StonksPadVaultUISchema.build()` (pure external library);
- `_buyOne` / `_quote` / `_oracleOut` / `_readFeed` → `StonksPadSwapLib` (external library);
- the deploy script creates the stack in order and the factory only *receives* the beacon:

| # | Transaction | Initcode (B) | Runtime (B) |
|---|---|---|---|
| 1 | `StonksPadSwapLib` (auto-deployed by forge, CREATE2) | 5,325 | 5,261 |
| 2 | `StonksPadVaultUISchema` (auto-deployed by forge, CREATE2) | 10,704 | 10,642 |
| 3 | `StonksPadVault` implementation | 19,308 | 19,116 |
| 4 | `UpgradeableBeacon(impl)` (owner = deployer) | 1,154 | 798 |
| 5 | `beacon.transferOwnership(FLAP_GUARDIAN)` | — | — |
| 6 | `StonksPadVaultFactory(beacon, …)` | 17,036 | 14,852 |

The factory constructor reverts unless `UpgradeableBeacon(beacon).owner() == _getGuardian()` and the
beacon has an implementation, so a mis-ordered or mis-owned deployment cannot produce a working
factory. Verification on BscScan needs the two library addresses (`--libraries`).

External dependencies (all already in `lib/`, OpenZeppelin 4.9.6):
`BeaconProxy`, `UpgradeableBeacon`, `Initializable`, `ReentrancyGuardUpgradeable`,
`SafeERC20`, `MerkleProof`, `Strings`.

External protocol interfaces (declared locally in `src/interfaces/`):
`IWBNB` (deposit/withdraw), `IPancakeV2Router` (`getAmountsOut`,
`swapExactTokensForTokensSupportingFeeOnTransferTokens`), `IPancakeV3SmartRouter` (`exactInput`),
`IPancakeV3QuoterV2` (`quoteExactInput`), `IChainlinkFeed` (`latestRoundData`, `decimals`).

BSC mainnet addresses used by the deploy script (constructor params, not hardcoded):

| Name | Address |
|---|---|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| PancakeSwap V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| PancakeSwap V3 SmartRouter | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| PancakeSwap V3 QuoterV2 | `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997` |
| Chainlink BNB/USD | `0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE` |

---

## 3. Authority model

| Role | Who | How resolved | Can be changed by |
|---|---|---|---|
| **Guardian** | Flap Guardian multisig | `_getGuardian()` (hardcoded in `VaultBase` / `VaultFactoryBaseV2`) | nobody — irrevocable |
| **Beacon owner / upgrader** | Guardian only | `UpgradeableBeacon.owner()`; the deploy script transfers ownership to the Guardian before the factory is deployed and the factory constructor **requires** `owner() == _getGuardian()` | Guardian (via `Ownable` on the beacon) |
| **platformAdmin** | StonksPad ops wallet (multisig recommended; currently a single externally held wallet) | `factory.platformAdmin` | `platformAdmin` or Guardian |
| **keeper** | StonksPad backend EOA | `factory.keeper` (vault reads it live) | `platformAdmin` or Guardian |
| **Fee route recipients** | addresses in `vaultData` | vault storage, fixed at init | nobody |
| **Holders** | anyone with a merkle leaf | proof | — |

Modifiers (custom, not OZ AccessControl — so no `revokeRole` override is required):

```solidity
// factory
modifier onlyAdminOrGuardian()  { require(msg.sender == platformAdmin || msg.sender == _getGuardian(), unicode"Only platform admin or Guardian / 仅限平台管理员或 Guardian"); _; }
// vault
modifier onlyKeeperOrGuardian() { require(msg.sender == IStonksPadVaultFactory(factory).keeper() || msg.sender == _getGuardian(), unicode"Only keeper or Guardian / 仅限 keeper 或 Guardian"); _; }
```

Every privileged function on both contracts is reachable by the Guardian. There is **no** owner,
proxy admin, upgrader role or emergency-withdraw function. The only emergency mechanism is the
Guardian-owned beacon upgrade (Rule 009 upgradeable exception).

---

## 4. Factory — `StonksPadVaultFactory`

### 4.1 Storage

```solidity
address public immutable beacon;          // UpgradeableBeacon, owner = Guardian
address public immutable wbnb;
address public immutable pancakeV2Router;
address public immutable pancakeV3Router; // SmartRouter
address public immutable pancakeV3Quoter; // QuoterV2

address public platformAdmin;
address public keeper;
address public platformTreasury;
uint16  public platformFeeBps;            // default 1000 (10% of net), hard cap MAX_PLATFORM_FEE_BPS = 1200; mainnet target 1111 (= 10% of gross at Flap's 10% fee)
address public bnbUsdFeed;                // Chainlink BNB/USD, shared by every stock price floor
uint256 public oracleStaleness;           // default 36h, bounded to [1h, 7d]

enum DexKind { PancakeV2, PancakeV3 }
struct StockInfo {
    bool    enabled;
    DexKind dexKind;
    address priceFeed; // Chainlink STOCK/USD feed — mandatory (anchors the buyStocks() price floor)
    bytes   path;      // V2: abi.encode(address[]) ; V3: packed (tokenIn, fee, tokenOut, …)
}
mapping(address => StockInfo) public stocks;   // stock token → swap config
address[] public stockList;                     // enumeration for the UI / site

mapping(address => bool) public isVault;        // vaults created by this factory
address[] public vaults;
```

Constants: `BPS = 10_000`, `MAX_PLATFORM_FEE_BPS = 1200`, `MAX_ROUTES = 16`, `MAX_STOCKS = 10`.

### 4.2 Constructor

```solidity
constructor(address beacon_, address wbnb_, address v2Router_, address v3Router_, address v3Quoter_,
            address bnbUsdFeed_, address platformAdmin_, address keeper_, address platformTreasury_)
```
1. `require(beacon_ != 0)`, `require(UpgradeableBeacon(beacon_).owner() == _getGuardian())`,
   `require(UpgradeableBeacon(beacon_).implementation() != 0)` — the implementation and beacon are
   deployed by the script beforehand (§2.1).
2. Stores immutables; sets `platformFeeBps = 1000`, `oracleStaleness = 36 hours`.

Code comment (required by the product specification): Flap's recommended commission is 6% for tax ≤ 1% and
`6 / taxRateBps` above; StonksPad charges a flat 10% of vault revenue; the justification is
documented here.

### 4.3 `newVault` (IVaultFactory)

```solidity
function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
    external override returns (address vault)
```
- `require(msg.sender == _getVaultPortal(), "Only VaultPortal / 仅限 VaultPortal 调用")`
- `require(quoteToken == address(0), "Native BNB only / 仅支持原生 BNB")`
- `abi.decode(vaultData, (AllocationRow[]))` — see §6.
- Validation (all `require` with bilingual literals):
  - `1 ≤ rows.length`; routes ≤ `MAX_ROUTES`; stocks ≤ `MAX_STOCKS`
  - every `target != address(0)`, every `bps > 0`
  - no duplicate targets (routes and stocks each)
  - `Σ bps == 10000`
  - every stock row: `stocks[target].enabled == true` (must be pre-registered in the factory)
  - every fee-route row: `target` must **not** be a registered stock token (enabled or disabled) —
    enforced in `StonksPadVault.initialize()` (`"Stock address cannot be a fee route / …"`); BNB pushed
    to a token contract would be unrecoverable. Added after a testnet launch used CAKE as a route.
- Deploys `new BeaconProxy(beacon, abi.encodeCall(StonksPadVault.initialize, (address(this), taxToken, creator, platformFeeBps, routes, stockRows)))`.
- Records `isVault[vault] = true`, pushes to `vaults`, emits `VaultCreated(vault, taxToken, creator)`.

### 4.4 Launch validation (spec v2.2)

```solidity
function _validateBeforeLaunch(LaunchValidationDataV1 memory d) internal view override returns (bool, string memory)
```
Rejects with a reason when `d.quoteToken != address(0)` or `d.vaultBps != 10000`
(StonksPad does not use Flap's dividend/deflation/lp splits). `tokenCreationPolicies()` mirrors
these two constraints (`quoteToken eq address(0)`, `vaultBps eq 10000`) for the Flap UI.

### 4.5 Platform settings — `onlyAdminOrGuardian`

| Function | Notes | Event |
|---|---|---|
| `setPlatformFeeBps(uint16 bps)` | `bps ≤ MAX_PLATFORM_FEE_BPS`; affects **future** vaults only (each vault snapshots the value at init → no retroactive change, no DoS) | `PlatformFeeBpsUpdated` |
| `setPlatformTreasury(address)` | non-zero; read live by vaults at withdrawal time | `PlatformTreasuryUpdated` |
| `setKeeper(address)` | non-zero; read live by vaults | `KeeperUpdated` |
| `setPlatformAdmin(address)` | non-zero | `PlatformAdminUpdated` |
| `registerStock(address stock, DexKind kind, bytes path, address priceFeed, bool enabled)` | validates path: V2 → decoded `address[]`, `length ≥ 2`, `[0] == wbnb`, `[last] == stock`; V3 → `length ≥ 43`, first 20 bytes == wbnb, last 20 bytes == stock; `priceFeed != 0` and answers `decimals()`. Adds to `stockList` on first registration. | `StockRegistered` |
| `setBnbUsdFeed(address)` | non-zero, answers `decimals()` | `BnbUsdFeedUpdated` |
| `setOracleStaleness(uint256)` | bounded to `[1 hours, 7 days]` | `OracleStalenessUpdated` |
| `setStockEnabled(address stock, bool enabled)` | quick on/off without changing the path | `StockEnabledUpdated` |

### 4.6 Views

`isQuoteTokenSupported(address q) → q == address(0)`, `vaultDataSchema()` (§6),
`beaconImplementation()`, `beaconOwner()`, `stockCount()`, `getStockList()`, `vaultCount()`, `getVaults(offset, limit)`,
`factorySpecVersion()` (inherited default `"v2.2"`).

---

## 5. Vault — `StonksPadVault`

### 5.1 Storage (upgradeable layout; append-only; `uint256[40] __gap` at the end)

```solidity
// ── immutable-after-init config ─────────────────────────────────────────────
address public factory;          // StonksPadVaultFactory (keeper / treasury / stock registry source)
address public taxToken;         // predicted tax token address (exists after launch)
address public creator;          // token creator (informational)
uint16  public platformFeeBps;   // snapshot from factory at init

struct FeeRoute { address recipient; uint16 bps; uint256 claimed; }
FeeRoute[] public feeRoutes;                       // ≤ MAX_ROUTES
mapping(address => uint256) internal routeIndexPlusOne; // recipient → index+1 (0 = none)

struct StockAlloc { address token; uint16 bps; }
StockAlloc[] public stockAllocs;                   // ≤ MAX_STOCKS
uint16  public stockPoolBps;                       // Σ stockAllocs.bps

// ── revenue accounting (touched by receive()) ───────────────────────────────
uint256 public totalReceived;    // gross BNB ever received
uint256 public totalNet;         // cumulative net after platform fee
uint256 public platformAccrued;  // platform fee not yet withdrawn

// ── stock pool ──────────────────────────────────────────────────────────────
uint256 public stockSpent;                          // BNB spent on stock purchases (cumulative)
mapping(address => uint256) public stockUndistributed; // bought but not yet assigned to an epoch
uint16  public maxSlippageBps;                      // default 300, hard cap MAX_SLIPPAGE_BPS = 500 (vs DEX quote)
uint16  public maxOracleDeviationBps;               // default 500, hard cap MAX_ORACLE_DEVIATION_BPS = 1000 (vs Chainlink)
uint256 public maxSpendPerBuy;                      // default 5 BNB, bounded to [MIN_SPEND_PER_BUY = 0.1, MAX_SPEND_PER_BUY = 20]
uint256 public buyCount;
uint256 public lastBuyAt;                           // MIN_BUY_INTERVAL = 10 minutes between buys

// ── merkle distribution ─────────────────────────────────────────────────────
struct Epoch {
    bytes32 root;
    uint64  publishedAt;
    uint64  claimsOpenAt;                            // publishedAt + CLAIM_DELAY (24h) — veto window
    bool    cancelled;
    string  cid;                                     // off-chain snapshot / proofs (IPFS), required
    address[] stocks;                                // stocks reserved in this epoch (for cancelEpoch)
    mapping(address => uint256) remaining;           // stock → still-claimable amount in this epoch
}
uint256 public epochCount;
mapping(uint256 => Epoch) internal epochs;
mapping(uint256 => mapping(address => bool)) public claimed; // epochId → account → claimed
```

### 5.2 `initialize`

```solidity
function initialize(address factory_, address taxToken_, address creator_, uint16 platformFeeBps_,
                    FeeRouteInit[] calldata routes, StockAlloc[] calldata stocks) external initializer
```
`__ReentrancyGuard_init()`, copies config, builds `routeIndexPlusOne`, computes `stockPoolBps`,
sets `maxSlippageBps = 300`, `maxSpendPerBuy = 5 ether`. Only callable once per proxy; the
implementation itself is locked by `_disableInitializers()`.

### 5.3 `receive()` — Rule 005

```solidity
receive() external payable {
    uint256 value = msg.value;
    if (value == 0) return;                          // tolerate zero-value pings, never revert
    uint256 fee = value * platformFeeBps / BPS;       // platformFeeBps ≤ 1000 → no overflow risk
    platformAccrued += fee;
    totalNet        += value - fee;
    totalReceived   += value;
    emit Received(msg.sender, value, fee);
}
```
No loops, no external calls, no `require`. Three SSTOREs + one event; measured on the BSC fork:
≈ 71k gas inside the implementation, ≈ 81k including the `BeaconProxy` hop (cold slots). Route and stock-pool shares are derived lazily from `totalNet` (pull accounting),
which is what keeps `receive()` O(1).

### 5.4 Lazy share accounting (pure functions of state)

```
routeClaimable(i)   = totalNet * feeRoutes[i].bps / BPS − feeRoutes[i].claimed
stockPoolAvailable  = totalNet * stockPoolBps / BPS − stockSpent
platformWithdrawable = platformAccrued
```
Invariant: `address(this).balance ≥ platformAccrued + Σ routeClaimable(i) + stockPoolAvailable`
(each term is a floor of a share of `totalNet`, so rounding dust stays in the vault and is never
over-promised).

### 5.5 Public / user-facing functions

| Function | Access | Behaviour |
|---|---|---|
| `claimFees()` | route recipient | looks up `routeIndexPlusOne[msg.sender]` (`require` found), computes claimable (`require > 0`), effects first (`claimed += amt`), then `call{value: amt}` to `msg.sender`, `require(ok)`. `nonReentrant`. Emits `FeesClaimed`. |
| `claimStocks(uint256 epochId, bytes claimData)` | any holder | `claimData = abi.encode(address[] stocks, uint256[] amounts, bytes32[] proof)`. Leaf = `keccak256(bytes.concat(keccak256(abi.encode(epochId, msg.sender, stocks, amounts))))` (OZ double-hash). Checks: epoch exists, not cancelled, `block.timestamp ≥ claimsOpenAt`, `!claimed[epochId][msg.sender]`, lengths match and ≤ `MAX_STOCKS`, proof valid, each `amounts[i] ≤ epochs[epochId].remaining[stocks[i]]`. Effects: mark claimed, decrement `remaining`; then `safeTransfer` each stock. `nonReentrant`. Emits `StocksClaimed`. |
| `withdrawPlatformFee()` | anyone | `amt = platformAccrued; platformAccrued = 0; call{value: amt}(factory.platformTreasury())`. `nonReentrant`. Emits `PlatformFeeWithdrawn`. Permissionless so the platform cannot be griefed and no extra role is needed. |

### 5.6 Privileged functions — `onlyKeeperOrGuardian`

| Function | Behaviour |
|---|---|
| `buyStocks(uint256[] calldata minOuts, uint256 deadline)` | `require(block.timestamp ≤ deadline)`; `require(block.timestamp ≥ lastBuyAt + MIN_BUY_INTERVAL)`; `minOuts.length == stockAllocs.length`. `spend = min(stockPoolAvailable(), maxSpendPerBuy)`, `require(spend > 0)`. `stockSpent += spend`, `lastBuyAt = now` (effects before any external call). Computes the enabled weight sum over `stockAllocs` (skipping stocks currently disabled in the factory registry, `require(enabledWeight > 0)`). Wraps `spend` BNB → WBNB once. For each enabled stock *i*: `amountIn = spend * bps_i / enabledWeight` (last enabled stock takes the remainder); `require(minOuts[i] > 0)`; **floor 1** `quoted = _quote(path, amountIn)` (V2 `getAmountsOut` / V3 `QuoterV2.quoteExactInput`), `require(minOuts[i] ≥ quoted * (BPS − maxSlippageBps) / BPS)`; **floor 2** `oracleOut = amountIn × BNB/USD ÷ STOCK/USD` from Chainlink (staleness-checked, decimals-normalised), `require(minOuts[i] ≥ oracleOut * (BPS − maxOracleDeviationBps) / BPS)`; approve router; swap (V2 / V3); `out = balanceAfter − balanceBefore`; `require(out ≥ minOuts[i])`; `stockUndistributed[stock] += out`. `nonReentrant`. Emits `StocksBought(buyCount, spend, stocks[], amountsIn[], amountsOut[])`. |
| `publishDistribution(bytes32 root, address[] calldata stocks, uint256[] calldata amounts, string calldata cid)` | `root != 0`, `cid` non-empty, lengths match and ≤ `MAX_STOCKS`, no duplicate stock, each `amounts[i] ≤ stockUndistributed[stocks[i]]` and `> 0`. `epochId = ++epochCount`; `claimsOpenAt = now + CLAIM_DELAY`; moves amounts from `stockUndistributed` into `epochs[epochId].remaining`; stores the stock list. Emits `DistributionPublished(epochId, root, stocks, amounts, cid)`. Roots are immutable once published (no `setMerkleRoot` overwrite → a published epoch can never be re-pointed away from holders). |
| `cancelEpoch(uint256 epochId)` — **platformAdmin or Guardian only (not keeper)** | Veto during the 24h window: `require(!cancelled && now < claimsOpenAt)`; marks cancelled and returns every `remaining[stock]` to `stockUndistributed` so a corrected root can be published. Emits `EpochCancelled`. |
| `setMaxSlippageBps(uint16 bps)` | `bps ≤ MAX_SLIPPAGE_BPS (500)`. Emits `MaxSlippageUpdated`. |
| `setMaxOracleDeviationBps(uint16 bps)` — **platformAdmin or Guardian only** | `bps ≤ MAX_ORACLE_DEVIATION_BPS (1000)`. The executing keeper cannot widen its own band. Emits `MaxOracleDeviationUpdated`. |
| `setMaxSpendPerBuy(uint256 amount)` | `MIN_SPEND_PER_BUY ≤ amount ≤ MAX_SPEND_PER_BUY`. Emits `MaxSpendPerBuyUpdated`. |

### 5.7 Views

| Function | Returns |
|---|---|
| `stats()` | `(totalReceived, totalNet, platformAccrued, stockPoolAvailable, stockSpent, buyCount, epochCount)` |
| `getFeeRoutes()` | `(address recipient, uint16 bps, uint256 claimed, uint256 claimable)[]` |
| `getStocks()` | `(address token, uint16 bps, uint256 undistributed, bool enabled)[]` |
| `claimableFees(address account)` | `uint256` (0 if not a route recipient) |
| `stockPoolAvailable()` | `uint256` |
| `getEpoch(uint256 epochId)` | `(bytes32 root, uint64 publishedAt, uint64 claimsOpenAt, bool cancelled, string cid)` |
| `epochStocks(uint256 epochId)` | `address[]` reserved in the epoch |
| `epochRemaining(uint256 epochId, address stock)` | `uint256` |
| `hasClaimed(uint256 epochId, address account)` | `bool` |
| `keeper()` | `factory.keeper()` passthrough (convenience for the UI) |
| `feeRouteCount()` / `stockCount()` | array lengths |
| `description()` | dynamic bilingual status, e.g. `"StonksPad Vault: 12.34 BNB received, 3 stock buys, 2 distribution epochs. Fee routes and stock buybacks are claim-based. / StonksPad 金库：已收到 12.34 BNB，3 次股票买入，2 轮分配。…"` |
| `vaultUISchema()` | §7 |

### 5.8 Events

```solidity
event Received(address indexed from, uint256 amount, uint256 platformFee);
event FeesClaimed(address indexed recipient, uint256 amount);
event PlatformFeeWithdrawn(address indexed treasury, uint256 amount);
event StocksBought(uint256 indexed buyId, uint256 bnbSpent, address[] stocks, uint256[] amountsIn, uint256[] amountsOut);
event DistributionPublished(uint256 indexed epochId, bytes32 root, address[] stocks, uint256[] amounts, string cid);
event StocksClaimed(uint256 indexed epochId, address indexed account, address[] stocks, uint256[] amounts);
event EpochCancelled(uint256 indexed epochId, address indexed by);
event MaxSlippageUpdated(uint16 bps);
event MaxOracleDeviationUpdated(uint16 bps);
event MaxSpendPerBuyUpdated(uint256 amount);
// factory
event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator);
event PlatformFeeBpsUpdated(uint16 bps);
event PlatformTreasuryUpdated(address treasury);
event KeeperUpdated(address keeper);
event PlatformAdminUpdated(address admin);
event StockRegistered(address indexed stock, uint8 dexKind, address priceFeed, bytes path, bool enabled);
event StockEnabledUpdated(address indexed stock, bool enabled);
event BnbUsdFeedUpdated(address feed);
event OracleStalenessUpdated(uint256 seconds_);
```

---

## 6. `vaultData` ABI and `vaultDataSchema()`

The Flap schema only supports a flat tuple or a flat array of tuples with primitive field
types, so fee routes and stocks share one row type:

```solidity
struct AllocationRow { address target; uint16 bps; bool isStock; }
// vaultData = abi.encode(AllocationRow[])
```

| Field | Type | Meaning |
|---|---|---|
| `target` | `address` | fee recipient wallet (`isStock=false`) or stock token (`isStock=true`, must be registered in the factory) |
| `bps` | `uint16` | share of net revenue (after platform fee); all rows must sum to 10000 |
| `isStock` | `bool` | row kind |

Stock rows' `bps` define the stock pool (`stockPoolBps = Σ`) **and** the weight of each stock
inside `buyStocks()`. Equal weights give the equal split described in the product specification; the site can
simply emit equal `bps` for every stock row. (See open question Q1.)

```solidity
function vaultDataSchema() public pure override returns (VaultDataSchema memory s) {
    s.description = unicode"Creates a StonksPad vault. Each row allocates a share (bps, all rows sum to 10000) of the net tax revenue "
        unicode"either to a fee recipient wallet (isStock = false, claimable BNB) or to a stock token (isStock = true, "
        unicode"bought on PancakeSwap by the keeper and distributed to holders via merkle claims). "
        unicode"Stock tokens must be registered in the factory. A platform fee is deducted first. / 创建 StonksPad 金库。…";
    s.fields = new FieldDescriptor[](3);
    s.fields[0] = FieldDescriptor("target",  "address", "Fee recipient wallet or registered stock token", 0);
    s.fields[1] = FieldDescriptor("bps",     "uint16",  "Share of net revenue in basis points (all rows sum to 10000)", 0);
    s.fields[2] = FieldDescriptor("isStock", "bool",    "true = stock token row, false = fee recipient row", 0);
    s.isArray = true;
}
```

---

## 7. `vaultUISchema()`

`vaultType = "StonksPadVault"`. Methods, in render order (only user-facing methods; keeper /
Guardian-only functions are documented in NatSpec and excluded from the schema):

| # | name | write | inputs | outputs | notes |
|---|---|---|---|---|---|
| 0 | `stats` | no | — | 7 × `uint256` (BNB amounts `decimals=18`, counters `0`) | |
| 1 | `getFeeRoutes` | no | — | `(recipient address, bps uint16, claimed uint256/18, claimable uint256/18)` `isOutputArray=true` | |
| 2 | `getStocks` | no | — | `(token address, bps uint16, undistributed uint256/18, enabled bool)` `isOutputArray=true` | |
| 3 | `claimableFees` | no | `account address` | `amount uint256/18` | |
| 4 | `getEpoch` | no | `epochId uint256/0` | `root bytes32, publishedAt time, claimsOpenAt time, cancelled bool, cid string` | |
| 5 | `epochRemaining` | no | `epochId uint256/0, stock address` | `amount uint256/18` | |
| 6 | `hasClaimed` | no | `epochId uint256/0, account address` | `claimed bool` | |
| 7 | `epochStocks` | no | `epochId uint256/0` | `(stock address)` `isOutputArray=true` | |
| 8 | `claimFees` | **yes** | — | — | `approvals = []` |
| 9 | `claimStocks` | **yes** | `epochId uint256/0, claimData bytes` | — | `claimData` is produced by the StonksPad site (abi-encoded stocks/amounts/proof); `approvals = []` |
| 10 | `withdrawPlatformFee` | **yes** | — | — | `approvals = []` |

All `fieldType` values are from the spec set; every method has an initialised `approvals`
array; `decimals` is 18 for BNB/token amounts and 0 for raw integers/ids.

---

## 8. Spec-checker compliance map

| Rule | How the design satisfies it |
|---|---|
| 001 inheritance | vault `is VaultBaseV2`; `description()` + `vaultUISchema()` overridden |
| 001 Guardian access | every privileged modifier has a `msg.sender == _getGuardian()` branch; Guardian hardcoded, no setter |
| 001 no-DoS | `platformFeeBps` snapshot at init; registry disable only skips that stock (BNB stays in pool); no parameter can block `claimFees`/`claimStocks`/`withdrawPlatformFee` |
| 002 factory | `is VaultFactoryBaseV2`; `newVault` portal-gated; `isQuoteTokenSupported`; fee formula deviation documented in code for audit justification |
| 003 fairness | see §9 |
| 004 UI-friendly | all reverts `require(cond, unicode"English / 中文")`; no custom errors in our code (base contracts' `UnsupportedChain` are Flap's own) |
| 005 receive gas | §5.3 — accounting + event, ≈70k gas, no loops/external calls, never reverts |
| 006 tests | §10 |
| 007 / 008 | not used (no AI oracle, no trigger service) |
| 009 emergency | upgradeable exception: no emergency functions; beacon owner = Guardian only |
| 010 V3 accounting | not applicable (native-only, `vaultQuoteToken()` not implemented, `isQuoteTokenSupported` rejects ERC20) |

---

## 9. Fairness & sandwich-risk assessment (Rule 003)

Privileged actors: `platformAdmin`, `keeper`, Guardian.

| Knob | Who | Exposure | Mitigation |
|---|---|---|---|
| `buyStocks` timing | keeper/Guardian | keeper chooses when the vault buys → could sandwich its own buy | Two independent price floors on every swap: (1) `minOuts[i] ≥ DEX quote × (1 − maxSlippageBps)` guards a mis-set `minOut`; (2) `minOuts[i] ≥ Chainlink-implied output × (1 − maxOracleDeviationBps)` — the Chainlink reference cannot be moved by a same-block front-run, so a sandwich that pushes the DEX price more than `maxOracleDeviationBps` (≤ 10%, default 5%) above the oracle price makes the buy revert. Size is bounded by `maxSpendPerBuy ≤ 20 BNB` and `MIN_BUY_INTERVAL = 10 min`; every buy emits amounts in/out; the backend submits through a private/MEV-protected BSC RPC (operational). |
| `maxSlippageBps` (keeper/Guardian) / `maxOracleDeviationBps` (platformAdmin/Guardian) | see left | raising them widens acceptable execution | hard caps `MAX_SLIPPAGE_BPS = 500`, `MAX_ORACLE_DEVIATION_BPS = 1000`; the oracle band is not settable by the executing keeper; events on change. |
| `maxSpendPerBuy` | keeper/Guardian | larger single swaps are more sandwichable; tiny values could starve the pool | bounded to `[0.1, 20] BNB`; only affects how much of the *already accrued* pool is swapped per tx; event on change. |
| stock swap path / enable / price feed | platformAdmin/Guardian | routing change could point to a thin pool; a bad feed could disable the oracle floor | path must start at WBNB and end at the stock token; a Chainlink feed is mandatory and staleness-checked (`oracleStaleness` bounded to `[1h, 7d]`); disable only skips that stock, leaving BNB in the pool; events on change. |
| merkle root | keeper/Guardian | could publish a root that favours insiders | root per epoch is immutable; claims open only after `CLAIM_DELAY = 24h`; during that window `platformAdmin` (multisig) or Guardian — never the keeper — can `cancelEpoch`, returning the reserve; leaves are bounded by `remaining[stock]` reserved at publish time, so one epoch can never consume another epoch's or the undistributed balance; `cid` (required) points to the public snapshot for verification. |
| `platformFeeBps` | platformAdmin/Guardian | increases platform take | hard cap 12% of net (≈ 10.8% of gross); applies only to vaults created afterwards. |
| `platformTreasury` / `keeper` | platformAdmin/Guardian | redirect platform fee / change operator | only affects platform's own share / operator identity; user shares are untouched. |

Residual risk: a colluding keeper can still front-run its own buy inside the oracle-deviation band
(≤ 10%) on a bounded amount (≤ 20 BNB per 10 minutes). This is disclosed here; the
Chainlink floor guarantees the band, and Guardian / platformAdmin retain independent execution
and veto paths.

## 10. Test plan (Workflow step 3, mainnet fork via `FlapBSCFixture`)

| # | Test | Asserts |
|---|---|---|
| 1 | deploy via `newTokenV6WithVault` | `vaultPortal.getVault(token).vault != 0`, `factory.isVault(vault)` |
| 2 | wiring | `taxProcessor.marketAddress() == vault` |
| 3 | buy on BC → `dispatch` | vault `totalReceived` increases, `platformAccrued == 10%`, routes claimable correct |
| 4 | graduate → sell → `dispatch` | same after DEX |
| 5 | core actions | `claimFees` pays route; `buyStocks` (keeper) swaps and credits `stockUndistributed`; `publishDistribution` + `claimStocks` with a real merkle tree transfers stock; `withdrawPlatformFee` reaches treasury |
| 6 | gating | non-keeper `buyStocks` reverts; non-recipient `claimFees` reverts; double `claimStocks` reverts; bad proof reverts; over-claim vs `remaining` reverts; `minOut` below floor reverts; `setMaxSlippageBps(501)` reverts; non-portal `newVault` reverts; invalid `vaultData` (sum ≠ 10000, unregistered stock, duplicates) reverts |
| 7 | `receive()` gas | `≤ 1_000_000` (expect ≈ 70k), zero-value call is a no-op |
| 8 | Guardian access | Guardian can call every privileged function on vault and factory (incl. `cancelEpoch`); Guardian can `upgradeTo` on the beacon; non-Guardian cannot; nobody can change the beacon owner except Guardian; factory constructor rejects a beacon not owned by the Guardian |
| 8b | fairness guards | oracle floor rejects an overpriced execution (mock feed); stale / invalid feed reverts; buy interval enforced; `maxSpendPerBuy` bounds; claim delay; `cancelEpoch` by admin/Guardian only and only inside the window |
| 9 | schemas | `vaultUISchema().methods.length == 11` with correct `isWriteMethod` flags; `vaultDataSchema()` has 3 fields, `isArray == true` |
| 10 | `description()` | non-empty and changes after revenue |
| 11 | launch validation | `onBeforeLaunch` rejects `vaultBps != 10000` and ERC20 quote |

---

## 11. Open questions — resolved (all accepted as recommended)

- **Q1 — Stock weights.** The flat `vaultData` row format forces a `bps` column on stock rows.
  Design uses those as weights inside the stock pool (equal bps = the "equal split" in
  the product specification). Alternative: ignore stock-row `bps` except for summing and always split equally.
  Recommendation: keep weights (strict superset, no extra storage).
- **Q2 — DEX support.** Both PancakeSwap V2 and V3 (SmartRouter + QuoterV2) are supported per
  registered stock. Dropping V3 would remove ~60 lines but tokenized stocks on BSC are mostly
  in V3 pools. Recommendation: keep both.
- **Q3 — `claimStocks(uint256 epochId, bytes claimData)`.** Arrays are not renderable by the
  Flap UI, so the claim payload is one `bytes` blob built by the StonksPad site (one tx per
  epoch for all stocks). Alternative: one leaf per (epoch, holder, stock) with fully typed
  inputs but one tx per stock. Recommendation: blob.
- **Q4 — `_validateBeforeLaunch` enforcing `vaultBps == 10000` and native quote.** Prevents
  misconfigured launches through the generic Flap UI. Recommendation: enforce.
- **Q5 — `MAX_PLATFORM_FEE_BPS`.** Originally 1000; raised to 1200 on 2026-09-18 (§17) so that 1111 bps of net = 10% of gross at Flap's 10% protocol fee.
- **Q6 — Defaults.** `maxSlippageBps = 300`, `maxSpendPerBuy = 5 BNB`, `MAX_ROUTES = 16`,
  `MAX_STOCKS = 10`.

---

## 12. Off-chain requirements

- **Fee routes are addresses, never X handles.** The vault only understands `address` targets.
  When a token creator configures a fee route by X handle, the StonksPad site **must pre-create
  a custodial wallet for that handle at launch time** and put that wallet's address into the
  `vaultData` row, so the vault always receives a concrete, non-zero recipient address. Handle
  → address resolution, custody and later hand-over to the handle's owner are entirely off-chain.
- The keeper backend computes holder snapshots and merkle trees, pins the snapshot to IPFS
  (`cid`), and calls `publishDistribution`. Holders claim through the site, which builds the
  `claimData` blob.
- `buyStocks` transactions are submitted through a private / MEV-protected BSC RPC with a fresh
  off-chain quote for `minOuts`.

## 13. Future work

- **Unclaimed epoch reserves have no expiry.** Stock amounts reserved in an epoch that are never
  claimed stay in the vault indefinitely (no sweep, no roll-over). A future beacon upgrade may
  add an expiry that rolls unclaimed reserves back into `stockUndistributed` for a later epoch.

## 14. Post-audit hardening (applied in step 4)

The first spec-checker pass flagged one Rule 003 FAIL (keeper could sandwich its own `buyStocks`
because the only floor was a same-block DEX quote; keeper could publish an arbitrary merkle root
with no veto). The following was added, all within the approved architecture:

1. **Chainlink price floor** in `buyStocks()` (`_oracleOut`), mandatory `priceFeed` per registered
   stock, factory-level `bnbUsdFeed` and bounded `oracleStaleness`, vault-level
   `maxOracleDeviationBps` (cap 10%).
2. **Bounded spend and cadence**: `maxSpendPerBuy ∈ [0.1, 20] BNB`, `MIN_BUY_INTERVAL = 10 min`.
3. **Claim delay + veto**: `CLAIM_DELAY = 24h` before `claimStocks`, `cancelEpoch` by
   `platformAdmin` or Guardian (not the keeper), `cid` required.

Product implication to note: only stock tokens with a Chainlink USD feed (or a compatible adapter)
can be registered.

## 15. Deployment restructuring (post testnet dry-run)

The first testnet deploy failed with `max initcode size exceeded: code size 72841, limit 49152`.
§2.1 records the fix: two external libraries, `via_ir` + `optimizer_runs = 200`, and a script that
deploys implementation → beacon → `transferOwnership(Guardian)` → factory. The factory constructor
now takes the beacon address and enforces Guardian ownership. All 40 fork tests pass; the testnet
dry-run shows six transactions, the largest 19,308 bytes of initcode.

## 16. Product-owner update (2026-09-13)

### 16.1 StonksPadTreasury

`factory.platformTreasury` now points at `StonksPadTreasury`. Vaults keep accruing the commission
in `receive()` (Rule 005 forbids a push there) and `withdrawPlatformFee()` pushes it to the treasury;
`treasury.collect(address[] vaults)` batches that call and is permissionless.

| Function | Access | Behaviour |
|---|---|---|
| `receive()` | anyone | accounting + event: `burnPool += 80%`, `nftAccrued += 10%`, `platformAccrued += 10%` |
| `collect(vaults[])` | anyone | `require(factory.isVault)`; calls `withdrawPlatformFee()` on vaults with a non-zero accrual |
| `distribute()` | anyone | pushes `nftAccrued` → `nftWallet`, `platformAccrued` → `platformWallet` |
| `buyAndBurn(minOut, deadline)` | keeper or Guardian | `spend = min(burnPool, maxSpendPerBurn)`; wraps to WBNB; `StonksPadSwapLib.buyOne` with the **same two floors as vaults** (DEX quote × (1 − maxSlippageBps), reference × (1 − maxOracleDeviationBps), reference = STONKS registry entry = TWAP); transfers the bought STONKS to `0x…dEaD`; `MIN_BURN_INTERVAL = 10 min` |
| `setWallets`, `setMaxSlippageBps (≤500)`, `setMaxOracleDeviationBps (≤1000)`, `setMaxSpendPerBurn ([0.1, 20] BNB)` | platformAdmin or Guardian | settings |

Roles are read live from the factory (`keeper()`, `platformAdmin()`, `guardian()`); no owner, not
upgradeable, holds no STONKS after a burn. Deploy order: factory → treasury(factory, STONKS,
nftWallet, platformWallet) → `factory.setPlatformTreasury(treasury)` (admin action; the script does it
only when the broadcaster is the admin).

### 16.2 Launch validation relaxed

`_validateBeforeLaunch` now requires only: native BNB quote, `dividendBps == 0` and `mktBps > 0`.
Flap-native deflation and LP splits are allowed; the vault receives whatever market share the
launcher configured. `tokenCreationPolicies()` mirrors the three constraints.

### 16.3 Mandatory stock and per-stock oracle mode (TWAP)

- `factory.mandatoryStock` (admin/Guardian settable, zero = off): every launch must contain a stock
  row for it (`"Mandatory stock missing"`). On mainnet this is STONKS
  (`0xc9d825E83AadA475bD4d38C8ca984eD746277777`).
- `StockInfo.oracleMode ∈ {Chainlink, TwapV2, TwapV3}`. STONKS has no Chainlink feed, so it is registered in
  **TwapV2** mode with the PancakeSwap V2 path `WBNB → QQQB → STONKS` (the direct WBNB/STONKS pair is
  dust and must not be used).
- TWAP mechanics (`PancakeV2Twap`, `StonksPadSwapLib.twapOut`, `factory.updateTwapObservations`):
  the factory stores two cumulative-price checkpoints per V2 pair (`latest`, `previous`). Anyone can
  record a checkpoint, but a new one only replaces `latest` once it is ≥ `MIN_TWAP_WINDOW = 30 min`
  old, so a usable window always survives a refresh. At buy time the newest checkpoint aged within
  `[30 min, 24 h]` is used per hop; the reference output is the product of the hop averages, net of
  the 0.25% V2 fee per hop (so it is comparable to an executable quote). `buyOne` refreshes the
  checkpoints after a TWAP-mode swap. The deviation cap is the same `maxOracleDeviationBps` (≤ 10%).

**Fairness justification for the audit (Rule 003).** A same-block front-run cannot move a ≥ 30-minute
time-weighted average: to shift it by the deviation cap `d` an attacker must hold the pool price
`≥ d × 30 min / (time held)` away from fair value for the whole window, paying swap fees twice and
carrying the inventory risk against arbitrage the entire time; with the current STONKS/QQQB pool
(~125 BNB of quote liquidity) moving a 30-minute average by 5% requires roughly a 5% price
displacement sustained for 30 minutes (≈ 3 BNB of net buying held against arbitrageurs), while the
gain is capped at `d` of a single bounded buy (≤ `maxSpendPerBuy` ≤ 20 BNB, default 5 BNB, and
≤ 0.2–0.5 BNB per 10-minute interval is recommended while liquidity is thin, because the DEX quote already includes the previous buy's price impact and the band must absorb it). The keeper cannot choose *what* a checkpoint
contains (it is the pair's own cumulative), only *when* one is recorded, and the window bounds are
constants. Residual: sustained multi-block manipulation of a thin pool remains possible in theory;
it is bounded by liquidity × window and by the spend/interval caps, and every buy emits its
amounts for public auditing. Chainlink remains the preferred mode wherever a feed exists.

### 16.4 `minHolding`

`vaultData` rows gain a fourth field `minHolding` (`uint256`, decimals 18). The Flap schema is a flat
tuple array, so the value is repeated per row; zero rows are ignored and all non-zero values must be
equal (`"Inconsistent minHolding"`). The vault stores it (`minHolding()` getter, UI schema method 7)
and it is **informational**: the keeper applies it to the off-chain holder snapshot before building
the merkle tree. Storage is appended after `claimed` (gap reduced 40 → 39).

### 16.5 Sizes after the update (`forge build --sizes`)

| Contract | Runtime (B) | Initcode (B) |
|---|---|---|
| StonksPadVault | 19,489 | 19,681 |
| StonksPadVaultFactory | 18,966 | 21,091 |
| StonksPadTreasury | 7,263 | 8,023 |
| StonksPadSwapLib | 7,500 | 7,532 |
| StonksPadVaultUISchema | 11,183 | 11,213 |

### 16.3b TwapV3 oracle mode (added 2026-09-15)

Tokenized stocks with V3-only liquidity and no Chainlink feed (SPCXB $2.2M, SKHYB, BABAB, MSTRB)
use `OracleMode.TwapV3`:

- The registered path is a packed V3 path (`WBNB → fee → USDT → fee → STOCK`). For every hop the
  factory's `pancakeV3Factory` (read from `SmartRouter.factory()`) resolves the pool and
  `PancakeV3Twap.consult(pool, 30 min)` reads the pool's **own** oracle (`observe([1800, 0])`) to get
  the arithmetic-mean tick of the last 30 minutes; `quoteAtTick` (Uniswap `OracleLibrary` maths with
  the vendored `TickMath`) converts it to an output amount, net of the pool fee. No factory
  checkpoints are needed, so nothing has to be kept alive by the keeper.
- Registration (`registerStock` with `TwapV3`) requires `dexKind == PancakeV3`, and for every hop an
  existing pool with non-zero liquidity whose oracle already answers a 30-minute `observe`
  (`StonksPadSwapLib.checkV3TwapReady`). Pools with a short observation buffer can be prepared by
  anyone through `factory.increaseV3ObservationCardinality(stock, n)` (the live PancakeSwap pools
  for SPCXB/USDT, SPCXB/WBNB, WBNB/USDT, GMEB/USDT and MSTRB/USDT already have cardinality 500–900).
- Fairness: identical band (`maxOracleDeviationBps ≤ 10%`) and spend/interval caps as the other
  modes. A same-block front-run cannot move the 30-minute average because V3 pools write at most
  one observation per block using the tick *before* the swap
  (`test_buyStocks_TwapV3FloorBlocksManipulatedSpot`: an 800 BNB pump moves spot > 4% while the TWAP
  reference is byte-for-byte unchanged and the keeper's spot-based `minOut` is rejected). Sustained
  manipulation must hold the pool price away from fair value for the whole window against
  arbitrage; with ≈ $2.2M in SPCXB/USDT the cost dominates the ≤ 10% gain on a ≤ 20 BNB buy.
  `TickMath` correctness is asserted on chain against `slot0` of five live pools.

### 16.6 Tokenized-stock token mechanics (bStocks, EIP-8056) — investigation 2026-09-15

Verified source (Sourcify full match, `SecuritiesToken` = `ERC8056BaseUpgradeable` +
`AccessControlEnumerable` + compliance client + pause-manager client; all bStocks share beacon
`0x156d…93a3`, implementation `0xCFEd…4e46`):

| Property | Finding | Effect on StonksPad |
|---|---|---|
| Balances / transfers | **raw** amounts; `uiMultiplier` (1e18 = 1.0x) only scales the UI view (`balanceOfUI`, `toUIAmount`). No on-chain rebase. | Vault accounting (`stockUndistributed`, epoch reserves, claims) is unaffected. |
| UI multiplier | Issuer/admin-settable with an effective time (splits, dividends…). Live: AAPLB 1.000604x, NVDAB 1.000778x, GMEB/SPCXB/QQQB 1.0x. | Chainlink quotes one **share**, the DEX prices one **raw unit** (= `uiMultiplier` shares). `StonksPadSwapLib.chainlinkOut` now divides the expected raw output by `uiMultiplier()` (1e18 for plain ERC-20s, read via `staticcall`, so non-8056 tokens are untouched). Without this a 4:1 split would have blocked every buy (floor 4× too high) and a reverse split would have loosened the floor. TWAP modes price raw units natively and need no correction. |
| Compliance | `checkIsCompliant(token, account)` on `0x53dB…14F4` for `msg.sender`, `from`, `to`: **blocklist + sanctions list** (`addToBlocklist`, `addToSanctionsList`); arbitrary addresses, vaults and `0x…dEaD` pass today. | A blocked/sanctioned holder cannot claim (per-account revert only); a blocked vault would freeze that vault's stock until unblocked. Accepted residual (issuer-controlled). |
| Pause | `pauseManager.isTokenPaused(token)` (OPS_ROLE) can pause all transfers; currently not paused. | `buyStocks`/`claimStocks` of that stock revert while paused; other stocks and BNB flows are unaffected. |
| Mint / burn | Issuer-only, `burn` only of the caller's own balance; no forced transfer or seizure function. | No issuer path to remove tokens from the vault. |
| Metadata | `name`/`symbol` changeable by admin. | Registry mirrors symbols from chain (registrySync). |

Web-side follow-up: display `toUIAmount(raw)` (or `balanceOfUI`) for bStocks amounts and the
`uiMultiplier` on the token page; merkle leaves keep raw amounts.

## 17. Platform fee vs. Flap protocol fee (decision 2026-09-18)

Flap's TaxProcessor deducts its protocol fee (`feeRate`, measured 1000 bps = 10% on the mainnet
STONKS token) before forwarding the market share to the vault, so `platformFeeBps` applies to a
*net* amount. Product decision: the platform takes **10% of gross**. Hence

```
platformFeeBps = 1000 × 10000 / (10000 − feeRate) = 1111  (feeRate = 1000)
```

`MAX_PLATFORM_FEE_BPS` was raised from 1000 to 1200 (≈ 10.8% of gross at a 10% Flap fee) to admit
this value while keeping a hard ceiling; the constructor default stays 1000 and every vault still
snapshots the value at creation (no retroactive change). The deploy scripts accept
`PLATFORM_FEE_BPS` and apply it when the broadcaster is the admin. Rule 002 justification (also in
the factory NatSpec): the commission is not operator profit — 80% is bought & burned as STONKS,
10% goes to STONKS NFT holders, 10% funds the platform — and a flat share keeps the launcher-facing
split independent of the token's tax rate.

## 18. Vault upgrade v1.1 (beacon upgrade via the Flap Guardian)

Scope: **vault implementation only**. The factory, treasury and beacon are not upgradeable and are
untouched; the Guardian calls `UpgradeableBeacon(0xA9A7…C5Af).upgradeTo(newImpl)`. Every existing
proxy (mainnet vault `0xd4e2…3fE4` included) switches atomically. `StonksPadSwapLib` is unchanged
(same CREATE2 address); `StonksPadVaultUISchema` changes (two new view methods, `describe()`) and
gets a new library address linked into the new implementation.

### 18.1 Storage additions (append-only)

Contract level — appended after `minHolding`, `__gap` shrinks 39 → 33 (6 new slots):

| Slot | Variable | Default (upgraded proxies **and** new vaults) | Recommended by the runbook |
|---|---|---|---|
| 71 | `address verifier` + `uint64 verifierSince` + `uint32 lastPokeAt` (packed) | `0` (fast path off) | the verifier service key |
| 72 | `uint256 opsMaxPerCall` | `0` (reimbursement off) | `0.0002 BNB` |
| 73 | `uint256 opsMaxPerDay` | `0` | `0.005 BNB` |
| 74 | `uint256 opsMaxGasPrice` | `0` | `0.1 gwei` |
| 75 | `uint256 opsReimbursedTotal` | `0` | — |
| 76 | `uint64 opsDay` + `uint192 opsReimbursedToday` (packed) | `0` | — |

`verifier` and `verifierSince` are public; the ops variables and `lastPokeAt` are `internal` and
exposed through the `opsReserve()` view (code size, §18.4).

Both features are opt-in per vault: nothing changes for any vault until the admin calls
`setVerifier` / `setOpsCaps`. `forge inspect` diff v1.0 → v1.1: all 27 v1.0 variables keep slot,
offset and type; `__gap` moves 71 → 77 and shrinks 39 → 33, ending at slot 110 as before.

`Epoch` struct (value of `mapping(uint256 => Epoch)`; each epoch owns its own hashed slot region, so
appending members after `remaining` cannot collide with anything):

| Member | Meaning |
|---|---|
| `uint64 snapshotBlock` | block number of the holder snapshot the root was built from (0 for epochs published with the legacy 4-argument call or before the upgrade) |
| `uint64 approvedAt` | timestamp of `approveEpoch` (0 = not approved) |

No existing variable, struct member, type or order changes. The verifier lives in the vault (not
the factory) because the deployed factory is immutable; the consequence is a per-vault
`setVerifier` call (post-upgrade runbook, internal).

### 18.2 Feature 1 — distribution fast path (second key)

```solidity
function publishDistribution(bytes32 root, address[] stocks, uint256[] amounts, string cid, uint64 snapshotBlock) // new overload, keeper | Guardian
function publishDistribution(bytes32 root, address[] stocks, uint256[] amounts, string cid)                      // legacy, snapshotBlock = 0 → never fast-tracked
function approveEpoch(uint256 epochId, bytes32 expectedRoot)   // active verifier | Guardian
function setVerifier(address verifier_)                        // platformAdmin | Guardian
function getEpochApproval(uint256 epochId) view returns (uint64 snapshotBlock, uint64 approvedAt, bool fastPath)
event EpochApproved(uint256 indexed epochId, address indexed verifier, uint64 claimsOpenAt);
event VerifierUpdated(address verifier);
```

- `publishDistribution(…, snapshotBlock)`: `0 < snapshotBlock < block.number`; everything else
  identical (reserve accounting, `claimsOpenAt = now + 24h`). Both overloads now bound the CID to
  `MAX_CID_LENGTH = 128` bytes (the call is gas-reimbursed, so its calldata must be bounded).
- `approveEpoch(epochId, expectedRoot)`: requires an existing, non-cancelled, not-yet-approved epoch
  with `snapshotBlock != 0` whose claims are not open yet **and whose stored root equals
  `expectedRoot`**; sets `approvedAt = now` and
  `claimsOpenAt = min(claimsOpenAt, now + FAST_CLAIM_DELAY)` with `FAST_CLAIM_DELAY = 30 minutes`
  (approval can only shorten the window, never extend it).
  *Deviation from the original one-argument request, on purpose:* binding the approval to the root
  the verifier recomputed makes the on-chain approval self-describing (an approval of "whatever is
  in epoch N" can be mis-targeted by an id mix-up or a confused verifier service; an approval of
  root R cannot).
- **Who may approve.** The Guardian — always, unconditionally (Rule 001: no parameter, including a
  keeper rotated onto the Guardian address, can lock it out). Or the vault's `verifier`, if it is
  (a) not the factory's current keeper and (b) **active**: `now ≥ verifierSince + 24h`.
  `setVerifier` stamps `verifierSince = now` and rejects the current keeper.
- The verifier has exactly one capability. It cannot publish, cancel, buy, change any parameter or
  move funds. `cancelEpoch` is unchanged: platformAdmin | Guardian, any time before `claimsOpenAt`
  — so an approved epoch still has a 30-minute veto window.
- Without a verifier, without approval, or for legacy epochs, behaviour is the v1.0 24-hour delay.

**Fairness (Rule 003) — why 30 minutes is acceptable with a second key.** The 24-hour delay exists
because in v1.0 a single key (the keeper) both computes and publishes the merkle root; time was the
only control giving the admin/Guardian a chance to veto a wrong or malicious root. v1.1 replaces
"time as the control" with "an independent recomputation as the control": the verifier is a separate
key on separate infrastructure that re-derives the holder snapshot at the on-chain-recorded
`snapshotBlock`, rebuilds the tree from the published `cid`, and approves only on an exact root
match (enforced on chain by `expectedRoot`). Shortening the window below 24 hours therefore requires
**both** keys:

- A rogue keeper alone still faces the full 24 hours (no approval comes) — identical to v1.0.
- A rogue verifier alone can only approve a root the keeper published; it can never create one.
- **The platform admin is not a shortcut around the two keys.** The admin appoints both the keeper
  (factory) and the verifier (vault), so without a guard a compromised admin could install its own
  verifier and fast-track a root in the same hour. The 24-hour activation lock closes this: any
  newly set verifier is inert for exactly the length of the normal claim delay, so an epoch
  published before or around a verifier swap always gets at least the v1.0 veto window, and the
  `VerifierUpdated` event gives the Guardian 24 hours of notice before the new key can act.
  Operational cost: rotating the verifier suspends the fast path for 24 hours (epochs simply take
  the 24h path meanwhile).
- The residual 30 minutes keeps the human/automated veto (`cancelEpoch`) alive on the fast path. It
  is a monitoring window, not a re-org defence (BSC finality is seconds; a re-orged publish would
  take its approval with it because the approval names the root).
- Per-epoch reserves still bound any damage to that epoch's published amounts.

Residual (accepted): the contract cannot check that `snapshotBlock` is *recent* or that it is the
block the keeper really used — it is a commitment the verifier recomputes against; the verifier
service must refuse snapshots older than its policy window (runbook). Holders gain: claims in
~30 minutes instead of 24 hours.

### 18.3 Feature 2 — operations reserve (keeper gas reimbursement)

```solidity
function pokeTwap(address stock)                         // keeper | Guardian; calls factory.updateTwapObservations(stock)
function setOpsCaps(uint256 perCall, uint256 perDay, uint256 maxGasPrice)  // platformAdmin | Guardian
function opsReserve() view returns (uint256 reimbursedTotal, uint256 reimbursedToday, uint256 perCall, uint256 perDay, uint256 maxGasPrice)
event OpsReimbursed(address indexed to, uint256 gasUsed, uint256 gasPrice, uint256 amount);
event OpsCapsUpdated(uint256 perCall, uint256 perDay, uint256 maxGasPrice);
```

`buyStocks`, both `publishDistribution` overloads and `pokeTwap` run under a `reimbursed` modifier
(inside `nonReentrant`): it records `gasleft()` and the stock-pool balance at entry and, after the
body, pays `msg.sender`

```
amount = min( (gasStart − gasleft() + OPS_GAS_OVERHEAD) × min(tx.gasprice, opsMaxGasPrice),
              opsMaxPerCall,
              opsMaxPerDay − reimbursedToday,
              poolAtEntry × OPS_MAX_POOL_SHARE_BPS / 10000,      // 5% of the stock pool seen at entry
              stockPoolAvailable() )                              // what is actually left after the body
```

- **Source of funds:** only the stock pool. The amount is added to `stockSpent` (the same counter
  purchases use), so `stockPoolAvailable()` drops by exactly the reimbursement and the solvency
  invariant `balance ≥ platformAccrued + Σ routeClaimable + stockPoolAvailable` is preserved. Fee-route
  balances, the platform commission and already-bought stock tokens / epoch reserves are
  arithmetically unreachable.
- **Caps:** admin-tunable within hard maxima — `OPS_HARD_MAX_PER_CALL = 0.01 BNB`,
  `OPS_HARD_MAX_PER_DAY = 0.1 BNB`, `OPS_HARD_MAX_GAS_PRICE = 1 gwei` (BSC runs at ~0.05 gwei;
  1 gwei is 20× headroom); `OPS_GAS_OVERHEAD = 40,000` (base tx cost + the payout itself); the day
  bucket is `block.timestamp / 1 days`. Anything above a cap is simply not reimbursed; the
  reimbursement step itself never reverts the action.
- **Payout:** `msg.sender.call{value, gas: 30,000}` after the accounting (effects first, inside the
  reentrancy guard). If the receiver rejects the BNB or runs out of the 30,000 gas, the accounting
  is rolled back and the main action still succeeds. Known consequence: the Flap Guardian contract
  does not accept plain BNB, so Guardian-executed actions are not reimbursed (they still work).
- `pokeTwap(stock)`: `stock` must be one of the vault's stocks and at least `POKE_INTERVAL = 30
  minutes` must have passed since this vault's previous poke — a poke inside the factory's own
  checkpoint interval would be a paid no-op.
- All vaults (upgraded or new) start with every cap at zero: the feature is off until the admin opts
  in per vault.
- `buyStocks` sets aside the reimbursement headroom (`min(per-call cap, day remainder, 5% of pool)`)
  **before** sizing the purchase. Without this a buy that spends the whole pool — the normal case
  while the pool is below `maxSpendPerBuy` — would leave nothing to reimburse from. Unused headroom
  simply stays in the pool for the next purchase.

**Fairness (Rule 003).** The reimbursement is paid from holders' stock pool, so it must be small,
bounded and not steerable by the recipient:

- The keeper cannot set the caps (admin | Guardian only, hard maxima in code).
- `tx.gasprice` is clamped to `opsMaxGasPrice`: bidding above the cap earns nothing extra. Below the
  cap the keeper is paid the price it actually bid — a validator-colluding keeper could recycle
  that, which is why the hard ceiling is 1 gwei and the recommended setting 0.1 gwei, and why the
  per-call/per-day caps exist independently of the price.
- Measured gas includes whatever the keeper makes the call do (e.g. a long stock list in
  `publishDistribution`); the per-call cap bounds that, and the CID length is bounded.
- Frequency: `buyStocks` is limited to one per 10 minutes and `pokeTwap` to one per 30 minutes;
  `publishDistribution` is not rate-limited, so **the binding bound on total extraction is the day
  cap**, together with the 5%-of-pool rule which keeps any single call proportionate for small
  vaults. Worst case per vault per day = `opsMaxPerDay` (≤ 0.1 BNB hard, 0.005 BNB recommended) —
  a hostile keeper can take the day cap and nothing more, and every payout emits `OpsReimbursed`
  with the measured gas, so abuse is visible and the admin can zero the caps.

Rationale: without it the platform subsidises every vault's operations from its own commission,
which does not scale with the number of vaults; with it each vault pays its own, capped, operating
cost.

### 18.4 Compatibility and rollout

- ABI: all v1.0 functions keep their signatures (`getEpoch` unchanged; approval data has its own
  view). The keeper should switch to the 5-argument `publishDistribution`; the 4-argument form keeps
  working (24h path). One revert string changed (`Snapshot CID required (max 128 bytes) / …`).
- UI schema: +2 view methods (`getEpochApproval`, `opsReserve`) → 14 methods; privileged methods
  (`approveEpoch`, `setVerifier`, `setOpsCaps`, `pokeTwap`) stay out of the schema like the others.
- Code size: the v1.1 implementation is **23,968 B** (EIP-170 limit 24,576 B, margin 608 B). To get
  there `description()`'s text assembly moved into the already-linked `StonksPadVaultUISchema`
  library (output unchanged) and the ops variables are internal behind one view. **Constraint for
  the next upgrade:** further features must first move more code out (e.g. the view assemblers into
  a lens contract).
- Tests (`test/StonksPadVaultV11.mainnet.t.sol`, 22 fork tests): slots 0–110 and the epoch-1 region
  of the live mainnet proxy are equal before/after `upgradeTo`, state continuity, approval path,
  fallback, root binding, verifier limits and activation lock, Guardian never locked out, caps,
  gas-price clamp, pool-share rule, poke rate limit, rejecting / re-entering / gas-burning receivers.
- Rollout: deploy new implementation → Guardian `upgradeTo` (request text in
  the internal upgrade runbook) → admin `setVerifier` + `setOpsCaps` per vault.

### 18.5 v1.2 — factory-level defaults (v2-generation stack)

Problem: verifier and ops caps are per-vault and admin-only, so every launch needed two admin
transactions, and the fast path of every new vault was dead for its first 24 hours. The v2 stack is
a fresh factory, so the defaults can live there.

Factory (`StonksPadVaultFactory`, new in the v2 generation; not upgradeable, no layout concern):

```solidity
address public defaultVerifier;          uint64 public defaultVerifierSince;
uint256 public defaultOpsMaxPerCall;     uint256 public defaultOpsMaxPerDay;     uint256 public defaultOpsMaxGasPrice;
function setDefaultVerifier(address verifier_)                                   // platformAdmin | Guardian; rejects the keeper; stamps defaultVerifierSince = now
function setDefaultOpsCaps(uint256 perCall, uint256 perDay, uint256 maxGasPrice) // platformAdmin | Guardian; same hard maxima as the vault (0.01 BNB / 0.1 BNB / 1 gwei)
function vaultDefaults() view returns (address, uint64, uint256, uint256, uint256)   // IStonksPadVaultDefaults
event DefaultVerifierUpdated(address verifier);   event DefaultOpsCapsUpdated(uint256, uint256, uint256);
```

Vault (`initialize`, no new storage — layout identical to v1.1): copies `verifier`,
`verifierSince`, and the three caps from `factory.vaultDefaults()`.

- **Copy, not reference.** Like `platformFeeBps`, the values are snapshotted at launch. A later
  change of the factory defaults never reaches into existing vaults — a compromised admin cannot
  swap the verifier of every live vault with one transaction. The price: rotating a verifier key
  means `setVerifier` on each existing vault plus `setDefaultVerifier` for future ones.
- **The 24h rule is preserved, not bypassed.** The vault copies the factory's *timestamp*, so the
  activation lock is measured from the moment the key was introduced, wherever that happened:
  a default that has been in place ≥ 24h is active in a new vault at once (nothing new was
  introduced; `DefaultVerifierUpdated` gave the 24h notice once, for all future vaults), while a
  default changed 1h ago is inert for another 23h in every vault launched after the change.
  The M1 attack (admin installs its own verifier and fast-tracks a root) therefore still needs 24h
  in every case: via the vault setter (lock restarts), via the factory (new vaults inherit the fresh
  timestamp; existing vaults are untouched). Launching a vault neither restarts nor skips the lock.
- **Keeper distinctness** is still enforced at approval time against the live `factory.keeper()`,
  so a keeper later rotated onto the default verifier's address cannot approve anywhere.
- **Hard maxima** are enforced by the factory setter and re-checked by the vault at initialization
  (out-of-range caps are ignored → reimbursement off); a test pins factory and vault constants equal.
- **Per-vault overrides unchanged:** `setVerifier` (restarts that vault's 24h lock) and `setOpsCaps`.
- **Legacy factory compatibility:** the call is wrapped in `try/catch`; a factory without
  `vaultDefaults()` (v1 generation) yields a vault with both features off, exactly as v1.1. The same
  implementation can therefore also serve the v1 beacon should that upgrade ever be requested.
- `vaultDefaults()` lives in its own interface file (`IStonksPadVaultDefaults`):
  `IStonksPadVaultFactory.sol` is compiled into `StonksPadSwapLib`, and editing it would change the
  library's metadata hash and CREATE2 address although its code is identical. Both deployed mainnet
  libraries (SwapLib `0x11c6…d8A1`, UISchema `0xC44D…A571`) are reused unchanged.
- Code size: vault **24,256 B** (margin 320 B), factory 21,090 B (margin 3,486 B). No lens contract
  was needed; the constraint of §18.4 for any further vault feature is now hard.
- Tests: +5 (copy + immediate activation, fresh default inert until factory time + 24h, existing
  vaults untouched + overrides, gating/hard maxima/constant equality, keeper rotated onto the default
  verifier) and a legacy-factory launch inside the live-proxy test → 27 v1.x tests, suite 82/82.
