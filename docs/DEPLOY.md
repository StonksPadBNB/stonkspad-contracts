# StonksPad Vault — Testnet Deployment Guide

This guide walks step by step through deploying the StonksPad Vault factory to **BSC testnet (chainId 97)**,
registering a stock token with a Chainlink price feed, and launching a test token through
**testnet.flap.sh** that uses our factory. Mainnet differences are summarized briefly at the end.

> No step runs automatically; you run every command yourself. Unless you add `--broadcast`,
> `forge script` only simulates and writes nothing to the chain.

---

## Mainnet deployment v2 (CURRENT) — BSC (chain 56), 2026-09-19, source commit `8145840`, block 122849333

The vault implementation is **v1.2** (fast distribution path + operations reserve + factory-level
defaults; DESIGN §18). New launches use **this factory only**. The detailed command list is kept
in an internal runbook that is not included in this repository. Deployer `0x46d8C1b2A3375ed4bA7aa9B73f14d91BE96a30D7` (the initial
`platformAdmin` in the factory constructor); after setup the admin role was transferred to
`0xBd86235E0EEB9b1659fc5090a0C8a160cD329Efb`.

| # | Contract / transaction | Address | Tx (all in block 122849333) |
|---|---|---|---|
| — | StonksPadSwapLib (reused, CREATE2) | `0x11c62d32763b2b7FB53b1d6c6a340B8DAF78d8A1` | v1 deployment |
| — | StonksPadVaultUISchema v1.1 (reused, CREATE2) | `0xC44D568612bc447cCAa5158586c83ca682ccA571` | `0xd6ce0228515661cfbc2df5a8f577d6582e9f4993f11a73444257c9ef550f009b` (block 122839334) |
| 1 | StonksPadVault implementation **v1.2** (24,256 B) | `0xf89953bfe1ECec08b147006C511E3c7E19B5bb6E` | `0x58c7d27bc364f974fa05c7b810e4303b4e5f256d53692b8c83a97f1f3c9621df` |
| 2 | UpgradeableBeacon (owner: Flap Guardian `0x9e27…8a4b`) | `0xFb634ef0808cc418A76a16B32a3C93049C69d0c0` | `0x0230667b18060482d9dd64129797db87fadbaa2461224d49895c4291322eb41e` |
| 3 | `beacon.transferOwnership(Guardian)` | — | `0xb6d8fb941ed50cc121686ffb77f8d4d782f6f443eeeba5d47b3786ed10d2d0b7` |
| 4 | StonksPadVaultFactory (with defaults) | `0x53Cc07A3Dd2015Cb84eFfcD0663B5Bd805a6bab4` | `0x2e7ee8f426a3effcd1b911495e39d1ae5d1e3d4698d15a201e47a41bc2be6d30` |
| 5 | StonksPadTreasury (80% STONKS buy&burn / 10% NFT / 10% platform) | `0x994EF72de824e4B116158a11b8250D4f11377CD3` | `0xf4194578b8b2711b42cd719691a21d0c7dd2125eef442dfb89834da0573841f6` |
| 6 | `factory.setPlatformTreasury(treasury)` | — | `0x7cb12ad7f821485fd50c1d49a6ffdb91d67f51342b4acf9149dcdfe9062b6ee9` |
| 7 | `factory.setPlatformFeeBps(1111)` | — | `0x0e5aeb413774c9287d7a0cabd982efc7f110864de0d0680a1d0640ca2f138939` |
| 8 | `factory.setDefaultVerifier(0x3a48dC39B9129B9FCb72233ae82914Be52F10c10)` | — | `0x10185ce2afa6acac730c71625fb1537cb741d8c90297c57959550c106dbbf8b3` |
| 9 | `factory.setDefaultOpsCaps(0.0002 BNB; 0.005 BNB; 0.1 gwei)` | — | `0x837168dcd1172bd54db6934c2f9ee64f1b31ac8721560922361a1d69c5ef36d5` |

Deployment cost: 12,357,008 gas, 0.00062 BNB (0.05 gwei); 13 stock registrations 2,862,557 gas, 0.00014 BNB.
**Note:** in the deployment broadcast records (not included in this repository) the transaction name ↔ hash mapping is again shifted;
the table above was derived from the **receipts** (`contractAddress`) and, for the configuration transactions, from the on-chain calldata
selectors (nonces 32, 35–38).

### Stock registrations (v2 factory; from the deployment broadcast records, not included in this repository)

| Stock | Address | Mode | Tx | Block |
|---|---|---|---|---|
| STONKS (mandatory) | `0xc9d825E83AadA475bD4d38C8ca984eD746277777` | TWAP_V2 | `0x08f837b12c85a7fd95ae2eefab613ff0ca40ea0339dcdfd22f5e3bf6aa005161` | 122849981 |
| AAPLB | `0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A` | Chainlink | `0x8dd606fabb2c19c7bcbbbfccfea15b21a6a4ab27d9d05ef0f4b711923e5c1dd4` | 122850277 |
| GOOGLB | `0x3F53De71c126BdaBAe20f9cD64848d317f6C3238` | Chainlink | `0xf0aa61e2edf9df16b28576f5794ca8037710ccdaf1172996a864253966889da2` | 122850298 |
| MSFTB | `0x80106cb3EAD06659A5ad19DF39D9b4733863B9b0` | Chainlink | `0xe5a6a6b444d8851b6d194b69d9f3d475fa9d897d8e921c50bffc6e4b2016f5af` | 122850315 |
| NVDAB | `0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436` | Chainlink | `0xe6a690a53da342505e1a6e11c0a15026710303ed1f28f6223bc8440782d99b05` | 122850334 |
| QQQB | `0x205812CdBed920aFf76C6580abD681a46D11efc7` | Chainlink | `0xf196f13e6d929b193d246fb203dac09856345c18082fb6ab725fda0507db8adb` | 122850352 |
| SPYB | `0x7138b48df7D98D7e3cc221BfE7192D0a178182D8` | Chainlink | `0xdebc48e83a2800b7e5500c994e2c1e226ea604d7f16f9804020fdc5f518cddb6` | 122850373 |
| TSLAB | `0x5b1910eAaD6450E50f816082Aa078C41F10C292f` | Chainlink | `0x5289387b0bfcd131ef542c141fe5bab736d34a470cfdadb9af6caff0b956b6bd` | 122850392 |
| GMEB | `0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C` | Chainlink | `0x1c4ab8d306f05cbbfe6c5446e196784b6f949df4b349c642da656d18a60cafc3` | 122850410 |
| SPCXB | `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1` | TWAP_V3 | `0x353b8e198dc9d83f8f2970f0d6db3475473a1a7ed584dd72988647bdf0cb5bd5` | 122850552 |
| SKHYB | `0xCA750eF65f295BBECd685Abf54e82CAf297BDB61` | TWAP_V3 | `0x9c1584ec6447481514ffd2f6a008fb342b43541fabdefa9f6c93bffe5e3ce3fc` | 122850571 |
| BABAB | `0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec` | TWAP_V3 | `0x8173a05fbb859c4b34f5c29f795e344ec234412128f1bc64e214781d717e2911` | 122850590 |
| MSTRB | `0xE87afb3076AeB0f9B14E368DE8145ae6a2826A14` | TWAP_V3 | `0xb5b03eeb9bb353bd44624b3c2c503dba3e800ceeaca7d6e9fbceeea2a22eb9a9` | 122850610 |

### State verified on-chain (2026-09-19)

`beacon() == 0xFb63…d0c0`, `beaconOwner() == 0x9e27…8a4b` (Flap Guardian),
`beaconImplementation() == 0xf899…bb6E` (runtime 24,256 B), `platformTreasury() == 0x994E…7CD3`,
`treasury.factory() == 0x53Cc…bab4`, `nftWallet == 0x6b06…Ab6c`, `platformWallet == 0xbFB9…8008`,
`maxSpendPerBurn() == 0.3 BNB`, `platformAdmin() == 0xBd86…9Efb`, `keeper() == 0x0364…ED4A`,
`platformFeeBps() == 1111`, `oracleStaleness() == 345600`, `mandatoryStock() == STONKS`,
`stockCount() == 13`, the first TWAP checkpoint is recorded for the STONKS/QQQB pair (ts 1789844618),
`vaultCount() == 0`.

`vaultDefaults()` = verifier `0x3a48dC39B9129B9FCb72233ae82914Be52F10c10`, `defaultVerifierSince`
1789844313 (2026-09-19 18:58:33 UTC), caps 200000000000000 / 5000000000000000 / 100000000 wei.
**The default verifier becomes active at 2026-09-20 18:58:33 UTC**; for vaults created before that moment
epochs open through the 24-hour path, afterwards the fast path works from launch on every new vault.

### BscScan verification (2026-09-19, confirmed via the API)

| Contract | Status |
|---|---|
| StonksPadSwapLib `0x11c6…d8A1` | Verified (from v1) |
| StonksPadVaultUISchema `0xC44D…A571` | Verified |
| StonksPadVault v1.2 `0xf899…bb6E` | Verified |
| UpgradeableBeacon `0xFb63…d0c0` | Verified (similar match: `0x5D8460ED6B2d6764843a39508806285b345bd74f`) |
| StonksPadVaultFactory `0x53Cc…bab4` | Verified |
| StonksPadTreasury `0x994E…7CD3` | Verified |

Build: solc 0.8.26, `via_ir`, `optimizer_runs = 200`, evm `cancun`; source commit `8145840`.

---

## Mainnet deployment v1 — **LEGACY** — BSC (chain 56), 2026-09-17, source commit `5275ef6`

> **Legacy (as of 2026-09-19):** factory `0x14B8425dd0F3fDd539Fd72e33c08D22a35013A11` is **not used**
> for new launches. The stack was not removed and still works: 1 live vault
> (`0xd4e29c3Aa30348AcF246F9D5C2b9fAE0faE13fE4`) stays on the v1.0 logic (24-hour claim delay,
> no gas reimbursement), and its commission flows to the v1 treasury. The keeper must keep calling `buyStocks` /
> the 4-argument `publishDistribution` for this vault, `buyAndBurn` / `distribute` for the v1 treasury, and
> `updateTwapObservations(STONKS)` **on the v1 factory**. Do not disable the v1 stocks (that would stop the live
> vault's buys). Details are in the internal v2 deployment runbook (§11), not included in this repository.


Deployer `0x46d8C1b2A3375ed4bA7aa9B73f14d91BE96a30D7` (passed as the initial `platformAdmin` in the factory
constructor); after deployment and registrations the admin role was transferred to
`0xBd86235E0EEB9b1659fc5090a0C8a160cD329Efb`. The detailed command list is kept in an internal runbook, not included in this repository.

| # | Contract / transaction | Address | Tx (blocks 122638392–122638393) |
|---|---|---|---|
| 1 | StonksPadSwapLib (library, CREATE2) | `0x11c62d32763b2b7FB53b1d6c6a340B8DAF78d8A1` | `0x775ee3694f13d3dcd9cf3cf9c9a5fd978ea04754a467cb00e3c0698b7ef00f11` |
| 2 | StonksPadVaultUISchema (library, CREATE2) | `0x1cE8B4e4359f161FD0b31b673Be2D51dC84854f3` | `0xdc7d64ebcfdf00298d3e06c0c28d79bc830bfd0780126f0eff2f0758cc8b25c1` |
| 3 | StonksPadVault implementation | `0x0Acc4ca5fA986d3431a4e4d0cF8BC652285dC559` | `0x261d050ed66f7609863dca50e55ee9c587fc09b742d65b163b88a45e4abcad43` |
| 4 | UpgradeableBeacon (owner: Flap Guardian `0x9e27…8a4b`) | `0xA9A7fE321e3510E6B2187DA4845cb618Edf1C5Af` | `0x4c80b32a1e36ed63db155e71bf7f33e3bbe36802ced6f0458ecbb0a0120a4a46` |
| 5 | `beacon.transferOwnership(Guardian)` | — | `0x459080f0ac1e0f97f110cf08b5433e0eda718c981a73b0988016fb57007a4e15` |
| 6 | StonksPadVaultFactory | `0x14B8425dd0F3fDd539Fd72e33c08D22a35013A11` | `0xfdc285e588fd8f34ddbd2d90b303e242d87ce7ab3b9ab5830064dcb233e76d93` |
| 7 | StonksPadTreasury (80% STONKS buy&burn / 10% NFT / 10% platform) | `0x542c9511D3f12419418374187aCfbA461D92F96c` | `0x2a8d24c6fb687c6b74cd961ba7d89f5da4b55db3548a5635637dbfcdc98901b8` |
| 8 | `factory.setPlatformTreasury(treasury)` | — | `0x6507dcf381c3cb7ef1b60e3b285bb68a5d70d471f639d009305d578a6618e2fd` |
| 9 | `factory.setPlatformFeeBps(1111)` | — | `0x725ec282424e60d8a10baabcc47cfc71143e55bc577b2f9feb04fe14770a9b49` |

Deployment cost: 16,165,318 gas, 0.00081 BNB. **Note:** in the deployment broadcast records (not included in this repository)
the name↔hash order is shifted; the mapping above was verified from each hash's on-chain receipt (created address /
target / selector / nonces 0–8). The local build (`5275ef6`) matches the on-chain bytecode:
the vault impl and UISchema are byte-for-byte identical; SwapLib differs only in the library's own
20-byte address written at deployment (offset 19–38).

Registered stocks (13; `RegisterStock.s.sol`, each with `status 0x1`):

| Stock | Address | Oracle mode | DEX | Registration tx | Block |
|---|---|---|---|---|---|
| Stonks | `0xc9d825E83AadA475bD4d38C8ca984eD746277777` | TWAP_V2 | V2 | `0xfbe45942a5cab4ba66dd1d43958bf5f8d2953d283063b061429873b4148f8498` | 122638507 |
| AAPLB | `0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A` | Chainlink | V3 | `0x900d23adf6954ec4fd6611e68a55b41e8bc10e6833227fc26bd801fa31af3241` | 122638691 |
| GOOGLB | `0x3F53De71c126BdaBAe20f9cD64848d317f6C3238` | Chainlink | V3 | `0x25ad2d03473eb978aabb73ca5899a6b892fd03800e8c25c466093c777d611f18` | 122638709 |
| MSFTB | `0x80106cb3EAD06659A5ad19DF39D9b4733863B9b0` | Chainlink | V3 | `0x859c243215e99a1a0fdb001969c999609f6e22fdd9e94fd148a1a89be108c403` | 122638728 |
| NVDAB | `0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436` | Chainlink | V3 | `0x117d19196383553ea9265e311171f79a4112c3e4f4a3a84e737627bfca6c92ab` | 122638746 |
| QQQB | `0x205812CdBed920aFf76C6580abD681a46D11efc7` | Chainlink | V3 | `0x9021047e3e7d75fb57711fa97250a115e5305b1bebed098f6b720add76e4eb84` | 122638764 |
| SPYB | `0x7138b48df7D98D7e3cc221BfE7192D0a178182D8` | Chainlink | V3 | `0x42b219af1ea1ba69d4683489289f2b4b56e0f9ccb92dbe0cb8ecaac1f9cfe10f` | 122638802 |
| TSLAB | `0x5b1910eAaD6450E50f816082Aa078C41F10C292f` | Chainlink | V3 | `0xddbee5bd915940315f27de982adbd20dc94755196b9ea673a0fb87793d920ba7` | 122638819 |
| GMEB | `0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C` | Chainlink | V3 | `0xc2a8055cce1d31341324a251854aac4931e2f26b143b975688e861430ac9fc40` | 122638838 |
| SPCXB | `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1` | TWAP_V3 | V3 | `0x1d362eab0b205683e9057ab58f8671d168057a4ce3e225eece7985e36cf1ea1b` | 122639152 |
| SKHYB | `0xCA750eF65f295BBECd685Abf54e82CAf297BDB61` | TWAP_V3 | V3 | `0xfe199ab426d964a846ad1616f04e1d04d8ab3e734bec7ee0d4bcf1a61c1147b8` | 122639176 |
| BABAB | `0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec` | TWAP_V3 | V3 | `0x34c376058e94c8902ec96cbd0a0eee126ac327b11f93bb99a1321e091c7df4bb` | 122639196 |
| MSTRB | `0xE87afb3076AeB0f9B14E368DE8145ae6a2826A14` | TWAP_V3 | V3 | `0x77720e41f1700d73d73bb26e6563208648a0ade321cc3228c13f440371762313` | 122639217 |

Settings verified on-chain (2026-09-18): `beaconOwner() == Guardian`, `platformAdmin() == 0xBd86…9Efb`,
`keeper() == 0x0364…ED4A`, `platformTreasury() == Treasury`, `treasury.factory() == Factory`,
`treasury.stonks() == STONKS`, `nftWallet == 0x6b06…Ab6c`, `platformWallet == 0xbFB9…8008`,
`platformFeeBps() == 1111` (`MAX_PLATFORM_FEE_BPS == 1200`), `oracleStaleness() == 345600`,
`mandatoryStock() == STONKS`, `stockCount() == 13`, `maxSpendPerBurn() == 0.3 BNB`, the first TWAP
checkpoint is recorded for the STONKS/QQQB pair (ts 1789749416), `vaultCount() == 0`.

---

## Mainnet — vault implementation v1.1 (2026-09-19, source commit `21583a7`, block 122839334)

Update: the v2-generation stack (see "Mainnet deployment v2" above) does **not use** this implementation; its own
script deploys the v1.2 implementation, which copies the factory defaults. The UISchema library
and SwapLib listed here are reused in v2. No beacon points to the v1.1 implementation
(ownerless, locked); it may become a candidate for the v1 beacon in the future. The v1 stack above (factory
`0x14B8…3A11`) becomes **legacy** once v2 is set up and stays on the v1.0 implementation.

| Contract | Address | Tx |
|---|---|---|
| `StonksPadVaultUISchema` (v1.1, CREATE2) | `0xC44D568612bc447cCAa5158586c83ca682ccA571` | `0xd6ce0228515661cfbc2df5a8f577d6582e9f4993f11a73444257c9ef550f009b` |
| `StonksPadVault` implementation v1.1 | `0x0f06059Ad1C0E421cccFbE8709BE792403A4f3fe` | `0x6815ab70b897d4d15ee06380cf6b1bd4e0239928819b7d60c2e8fd0093f031b4` |
| `StonksPadSwapLib` (unchanged) | `0x11c62d32763b2b7FB53b1d6c6a340B8DAF78d8A1` | — |

The on-chain runtime bytecode is byte-for-byte identical to the local build (impl 23,968 B, UISchema 14,057 B);
the implementation's initializers are locked (slot 0 = `0xff`).

## 0. Prerequisites

| Requirement | Note |
|---|---|
| Foundry (`forge`, `cast`) | Latest version via `foundryup` |
| Testnet BNB | ~0.5 tBNB is enough for deployment + registration + launch. Faucet: https://www.bnbchain.org/en/testnet-faucet |
| Three wallets | `deployer` (deploys the factory), `admin` (`platformAdmin`), `keeper`. On testnet they can all be the same wallet. |
| BscScan API key | Only for `--verify` (optional) |

Import the wallet into the Foundry keystore (the private key is written to disk encrypted and never appears in commands):

```bash
cast wallet import deployer --interactive
cast wallet import admin --interactive      # on testnet this can be the same as deployer
```

Prepare the environment variables:

```bash
cp .env.example .env
# fill in the PLATFORM_ADMIN, KEEPER, PLATFORM_TREASURY, NFT_WALLET, PLATFORM_WALLET addresses in .env
# (on testnet CAKE is used instead of STONKS; the STONKS env variable can be left empty)
set -a; source .env; set +a
export RPC=https://bsc-testnet-dataseed.bnbchain.org
```

### Testnet addresses (embedded as defaults in the scripts)

| Name | Address |
|---|---|
| Flap VaultPortal (testnet) | `0x027e3704fC5C16522e9393d04C60A3ac5c0d775f` |
| Flap Guardian (testnet) | `0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950` |
| WBNB | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| PancakeSwap V2 Router | `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` |
| PancakeSwap V3 SmartRouter | `0x9a489505a00cE272eAa5e07Dba6491314CaE3796` |
| PancakeSwap V3 QuoterV2 | `0xbC203d7f83677c7ed3F7acEc959963E7F4ECC5C2` |
| Chainlink BNB/USD | `0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526` |
| Chainlink CAKE/USD | `0x81faeDDfeBc2F8Ac524327d70Cf913001732224C` |
| Chainlink USDT/USD | `0xEca2605f0BCF2BA5966372C99837b1F182d3D620` |
| CAKE (testnet, a WBNB/CAKE V2 pool exists) | `0xFa60D973F7642B748046464e165A65B7323b0DEE` |
| USDT (testnet, a WBNB/USDT V2 pool exists) | `0x337610d27c682E347C9cD60BD4b3b107C9d34dDd` |

Because there are no tokenized stocks on testnet, **CAKE and USDT are used as test tokens standing in
for stocks**; the vault logic is token-agnostic.

### Deployed testnet contracts — v3 (2026-09-16, current: TwapV3 + EIP-8056 multiplier fix)

| # | Contract | Address | Deployment tx (block 131454576) |
|---|---|---|---|
| 1 | StonksPadSwapLib (library, CREATE2; linked into factory + vault + treasury) | `0x11c62d32763b2b7FB53b1d6c6a340B8DAF78d8A1` | `0xec8f56061c3d5a9da4705d13ab101365410ecf0673867435634a737cc40f4f21` |
| 2 | StonksPadVaultUISchema (library, CREATE2; v2 address because the bytecode is unchanged) | `0x1cE8B4e4359f161FD0b31b673Be2D51dC84854f3` | — (from the v2 deployment) |
| 3 | StonksPadVault implementation | `0x2C3c8D510Cbf24E229b4d746E5B1A1fEb4DAD4eE` | `0x3c3f72ba7f0138a4e10d563380b109f065f0f6e5a170d5f8e04dc2471fa95cfe` |
| 4 | UpgradeableBeacon (owner: Flap Guardian `0x76Fa…6950`) | `0xe3a9b768B1050a217fF1550a9abd8FB8c32296aD` | `0x0fdd6f07e1f59161acefe56d99cac6689f91a09579b2b74c0b745cd2a9190704` |
| 5 | `beacon.transferOwnership(Guardian)` | — | `0x82e720b3137b182a076735ef7ce9c62299c2bc6f780e504ade43a334a764a92e` |
| 6 | StonksPadVaultFactory | `0x68c6893412C8E82045a0271C9c5556CCA7907884` | `0x649067078a261be50e59df1e593893fd8dff0355ced79ca852553f30b7ffaa09` |
| 7 | StonksPadTreasury (80% CAKE buy&burn / 10% NFT / 10% platform) | `0xE3167664957C66F0Bd3D36B68F80EaA7934f4244` | `0x97d39e838e33da8c6cfc9ddb33d2a934debf789a87578d6a4b1a9696fc82e39a` |
| 8 | `factory.setPlatformTreasury(treasury)` | — | `0x732542bc6524560a33cc629ae7c2c0241ced20b629c2550ac728db21d7a5bc84` |
| — | platformAdmin / NFT wallet / platform wallet | `0x7C603d94523C17909bEDa569d555114f2154FB90` (deployer) | — |
| — | keeper (via `setKeeper`) | `0xaE161A966EA2f835A9a19285e55f5C01642E037f` | — |

State verified on-chain: `beaconOwner() == Guardian`, `platformTreasury() == Treasury`,
`treasury.factory() == Factory`, `pancakeV3Factory() == 0x0BFb…1865`, `platformFeeBps() == 1000`,
`mandatoryStock() == CAKE`, `keeper() == 0xaE16…037f`, `stockCount() == 1`.

Registered test stocks (v3):

| Stock | Oracle mode | DEX path | Chainlink feed | Registration tx (block 131454824) |
|---|---|---|---|---|
| CAKE `0xFa60…0DEE` (mandatory stock) | Chainlink | V2: WBNB → CAKE | CAKE/USD `0x81fa…224C` | `0x0c3c53c6a4cf74087c854bb52e5c5b9f28acb227fa0dda2b29259e7a90aa6548` |

<details>
<summary>v2 deployment (2026-09-13, <b>obsolete — superseded by v3</b>: no TwapV3 and no EIP-8056 multiplier fix)</summary>

#### v2 contracts

| # | Contract | Address | Deployment tx (blocks 130859623–130859624) |
|---|---|---|---|
| 1 | StonksPadSwapLib (library, CREATE2) | `0xa8EC87B6Ea2AFcAf3170D374aEd6C91965b0BdD4` | `0x5af5ce0e9dc219e9f538380d9aeccb1c45aacf931a6f7255725e15a43f4754e7` |
| 2 | StonksPadVaultUISchema (library, CREATE2) | `0x1cE8B4e4359f161FD0b31b673Be2D51dC84854f3` | `0x043aabe09e6b69531221d2d6cc46601526d7d198a37aac07f332ed2154fe6f1a` |
| 3 | StonksPadVault implementation | `0x9b752d6Abf19D6Aca1564F91fC48847C5eD31ed3` | `0x864cabc011d2d4b0f22bc3614ee62e5d9484dd27c57a482c37d766c907ddb60e` |
| 4 | UpgradeableBeacon (owner: Flap Guardian `0x76Fa…6950`) | `0x47651031C2db5d7630c052920aa53f89D4cd45ec` | `0x8d5b3271ae049005b3ab44142c0e3dcee1201ee73ff8a0f68d4cef31b6f39599` |
| 5 | `beacon.transferOwnership(Guardian)` | — | `0xeec0e1022bade29726483de15dff69b1f921dc3d2b6fd3818bf21c56ae74ca77` |
| 6 | StonksPadVaultFactory | `0xC65D2A62205e3B10b82d49269bea34f48ec3847B` | `0xb5f2b787bba16b42125497e6e2098c3c9feddd470d2a8a50e607c6031501f47d` |
| 7 | StonksPadTreasury (80% CAKE buy&burn / 10% NFT / 10% platform) | `0x55081978e3E84728c42335BCE45974Ca03f29ce8` | `0xcdfab408ed74288c12f9ebcf268e960b3006b28f476150294b6940e633b14993` |
| 8 | `factory.setPlatformTreasury(treasury)` | — | `0xbf6542efb4d96f51a83a033bb9aa50cadc820c92ed3f0760e3cca712e4c4df9c` |
| — | platformAdmin / keeper / NFT wallet / platform wallet | `0x7C603d94523C17909bEDa569d555114f2154FB90` (deployer) | — |

State verified on-chain: `beaconOwner() == Guardian`, `platformTreasury() == Treasury`,
`treasury.factory() == Factory`, `platformFeeBps() == 1000`, `mandatoryStock() == CAKE`,
`treasury.stonks() == CAKE` (testnet stand-in). Evidence: the deployment broadcast records
(not included in this repository) for the factory deployment and the stock registration on chain 97.

Registered test stocks (v2):

| Stock | Oracle mode | DEX path | Chainlink feed | Registration tx |
|---|---|---|---|---|
| CAKE `0xFa60…0DEE` (mandatory stock) | Chainlink | V2: WBNB → CAKE | CAKE/USD `0x81fa…224C` | `0xe484a824f33cf5c070691f673f6926024e63b02c4daf95fb0c998bac96c00dfa` (block 130859893) |

`setMandatoryStock(CAKE)` was executed directly with `cast send` (verified on-chain).


</details>

<details>
<summary>v1 deployment (2026-09-13, <b>obsolete — superseded by v2</b>)</summary>

| Contract | Address |
|---|---|
| StonksPadVaultFactory (v1) | `0xD186c663EaA724c03077e59887C2ad8628845adA` |
| UpgradeableBeacon (v1) | `0xefa75241127939DB8b0425243C12e128DC49c088` |
| StonksPadVault implementation (v1) | `0x7471A967942898a37e0af82146148fa05256Ae72` |
| StonksPadSwapLib / StonksPadVaultUISchema (v1) | `0xAA75…A99A` / `0x5854…0BD9` |

The v1 factory has no treasury, TWAP mode, mandatory stock or `minHolding`; test tokens launched with v1
(below) stay on the old vault implementation.
</details>

### Testnet test tokens — v2 factory (`0xC65D…847B`)

| # | Token | Vault (BeaconProxy) | Status |
|---|---|---|---|
| 3 | `0xdff7e4a6ee755d05c063e1e2d494fe08ba207777` | `0xF7321A9e88186D508ebA28d0D72ba317EaEa0c6B` | Full v2 flow verified: buy → `dispatch` → `withdrawPlatformFee` → treasury `distribute` (NFT/platform shares paid) → `buyAndBurn` (1 burn, 0.00076 BNB → CAKE sent to `0x…dEaD`). |

On-chain check: `VaultPortal.getVault(token)` returns the vault and the v2 factory; vault `stats()` →
received 0.0095 BNB, net 0.00855, platform share withdrawn (0); treasury `totalReceived` 0.00095 BNB,
`burnCount` 1, `burnPool` 0, `nftAccrued` 0.

### Testnet test tokens (launched with the v1 factory `0xD186…5adA` — old version)

| # | Token | Vault (BeaconProxy) | Status |
|---|---|---|---|
| 1 | `0xf1932cc3e2239b429b4231d85dce0dcab5c57777` | `0x89DA0f8711023f1f8BAF77c054c490557a5d8429` | Full flow verified: buy → `dispatch` → fee route / platform share → `buyStocks` (1 buy, 0.00342 BNB spent). |

On-chain check: `VaultPortal.getVault(token)` returns the vault and the factory `0xD186…5adA`;
the vault's `stats()` → received 0.0095 BNB, net 0.00855, platform 0.00095, `buys` 1.

State verified on-chain: `beaconOwner() == Guardian`, `platformFeeBps() == 1000`,
`bnbUsdFeed() == 0x2514…7526`.

Registered test stocks:

| Stock | DEX path | Chainlink feed | Registration tx |
|---|---|---|---|
| CAKE `0xFa60…0DEE` | V2: WBNB → CAKE | CAKE/USD `0x81fa…224C` | `0xfcad9cbceb3cc16fd13732a15e8f863de96c222132640867f27d532df3e3bd97` (block 130775573) |

---

## 1. Build and tests

```bash
forge build --sizes     # StonksPadVault runtime must be < 24,576 B (via-ir, optimizer_runs = 200)
forge test --fork-url https://bsc-dataseed.bnbchain.org -vv     # mainnet fork, 40 tests
```

Do not proceed to deployment until all tests pass.

---

## 2. Factory deployment (testnet)

Simulate first (writes nothing to the chain):

```bash
forge script script/testnet/bnb/DeployStonksPadVaultFactory.s.sol:DeployStonksPadVaultFactory \
    --rpc-url $RPC --account deployer
```

If you see `Beacon owner (Flap Guardian): 0x76Fa...6950` in the logs, the setup is correct. Now the real
deployment:

```bash
forge script script/testnet/bnb/DeployStonksPadVaultFactory.s.sol:DeployStonksPadVaultFactory \
    --rpc-url $RPC --account deployer --broadcast \
    --verify --etherscan-api-key $ETHERSCAN_API_KEY      # verify is optional
```

The script sends **eight transactions** in a single run; each one stays below the EIP-3860 initcode limit
(49,152 B):

| # | Transaction | Initcode (B) | Description |
|---|---|---|---|
| 1 | `StonksPadSwapLib` (CREATE2, automatic by forge) | 5,325 | swap/oracle library linked into the vault |
| 2 | `StonksPadVaultUISchema` (CREATE2, automatic by forge) | 10,704 | UI schema library linked into the vault |
| 3 | `StonksPadVault` implementation | 19,308 | runtime 19,116 B (limit 24,576) |
| 4 | `UpgradeableBeacon(impl)` | 1,154 | owner is temporarily the deployer |
| 5 | `beacon.transferOwnership(Guardian)` | — | upgrade authority passes to the Flap Guardian |
| 6 | `StonksPadVaultFactory(beacon, …)` | ~21,100 | the constructor verifies that the beacon owner is the Guardian |
| 7 | `StonksPadTreasury(factory, STONKS, NFT_WALLET, PLATFORM_WALLET)` | ~8,000 | platform commission: 80% STONKS buy&burn, 10% NFT, 10% platform |
| 8 | `factory.setPlatformTreasury(treasury)` | — | the script does this only if the broadcaster is `platformAdmin`; otherwise the admin multisig calls it afterwards ("ACTION REQUIRED" in the log) |

Note the addresses from the output and add them to `.env` (the library addresses are in the `libraries` field of
`broadcast/DeployStonksPadVaultFactory.s.sol/97/run-latest.json`, which forge generates locally on your machine):

```
FACTORY=0x...        # StonksPadVaultFactory
BEACON=0x...         # UpgradeableBeacon (owned by the Guardian)
IMPL=0x...           # StonksPadVault implementation
SWAP_LIB=0x...       # StonksPadSwapLib
SCHEMA_LIB=0x...     # StonksPadVaultUISchema
```

If you did not use `--verify`, pass the library links when verifying the implementation afterwards:

```bash
forge verify-contract $IMPL src/StonksPadVault.sol:StonksPadVault --chain 97 \
    --libraries src/StonksPadSwapLib.sol:StonksPadSwapLib:$SWAP_LIB \
    --libraries src/StonksPadVaultUISchema.sol:StonksPadVaultUISchema:$SCHEMA_LIB \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

Verification:

```bash
cast call $FACTORY "beaconOwner()(address)" --rpc-url $RPC        # must be the Guardian
cast call $FACTORY "platformFeeBps()(uint16)" --rpc-url $RPC      # 1000
cast call $FACTORY "keeper()(address)" --rpc-url $RPC
cast call $FACTORY "factorySpecVersion()(string)" --rpc-url $RPC  # "v2.2"
```

The factory takes the beacon as a constructor argument and reverts unless `beacon.owner() == Guardian`;
that is why the order is always implementation → beacon → `transferOwnership(Guardian)` → factory.
The factory has no upgrade authority; upgrades are performed by the Guardian calling `beacon.upgradeTo()`
directly (requires contacting the Flap team, ~24 hours).

> Why this order? In the first attempt the factory constructor deployed the implementation + beacon
> internally, and the factory initcode grew to 72,841 B and failed with `max initcode size exceeded`.
> Details: `docs/DESIGN.md §2.1`.

> Testnet Chainlink feeds update infrequently. If you see "Stale oracle price" on buys, widen the
> staleness window (at most 7 days):
> `cast send $FACTORY "setOracleStaleness(uint256)" 604800 --rpc-url $RPC --account admin`

---

## 3. Stock registration (with a Chainlink feed)

A token can be used as a stock row in `vaultData` only if it is **registered and enabled** in the
factory. Registration needs three things: the token address, the PancakeSwap swap path (starting with WBNB
and ending with the token) and the Chainlink `TOKEN/USD` feed.

Every stock has an **oracle mode**: `CHAINLINK` (requires a STOCK/USD feed), `TWAP_V2`
(a ≥ 30-minute time-weighted price of every pair on the PancakeSwap V2 path; factory
checkpoints) or `TWAP_V3` (the 30-minute average tick from the V3 pools' own `observe()` oracle;
no checkpoint required, but the pool's observation capacity must be sufficient).
Because STONKS has no Chainlink feed, on mainnet it is registered in TWAP mode with the path
`WBNB → QQQB → STONKS` and made mandatory for every launch with `setMandatoryStock(STONKS)`.

`RegisterStock.s.sol` `ORACLE_MODE` values: `CHAINLINK` (0, `PRICE_FEED` required), `TWAP` or
`TWAP_V2` (1, `DEX_KIND=V2` + `V2_PATH`), `TWAP_V3` (2, `DEX_KIND=V3` + `V3_PATH`); `PRICE_FEED` may be
omitted in the TWAP modes.

### 3a. With the script (recommended)

Add to `.env`:

```
FACTORY=0x...                                          # from step 2
STOCK=0xFa60D973F7642B748046464e165A65B7323b0DEE       # CAKE (testnet)
ORACLE_MODE=CHAINLINK                                  # or TWAP
PRICE_FEED=0x81faeDDfeBc2F8Ac524327d70Cf913001732224C  # Chainlink CAKE/USD (testnet); not needed for TWAP
DEX_KIND=V2
V2_PATH=0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,0xFa60D973F7642B748046464e165A65B7323b0DEE
ENABLED=true
```

Registration in TWAP mode and the observation flow for the first buy (mainnet STONKS example):

```bash
# registration (admin)
FACTORY=$FACTORY STOCK=0xc9d825E83AadA475bD4d38C8ca984eD746277777 ORACLE_MODE=TWAP DEX_KIND=V2 \
V2_PATH=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,0x205812CdBed920aFf76C6580abD681a46D11efc7,0xc9d825E83AadA475bD4d38C8ca984eD746277777 \
forge script script/RegisterStock.s.sol:RegisterStock --rpc-url $RPC --account admin --broadcast
cast send $FACTORY "setMandatoryStock(address)" 0xc9d825E83AadA475bD4d38C8ca984eD746277777 --rpc-url $RPC --account admin
# first TWAP checkpoint (anyone can call it); buys become possible at least 30 min later
cast send $FACTORY "updateTwapObservations(address)" 0xc9d825E83AadA475bD4d38C8ca984eD746277777 --rpc-url $RPC --account keeper
```

Registration in TWAP_V3 mode (mainnet SPCXB example; path WBNB →0.01%→ USDT →0.25%→ SPCXB):

```bash
FACTORY=$FACTORY STOCK=0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1 ORACLE_MODE=TWAP_V3 DEX_KIND=V3 \
V3_PATH=0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c00006455d398326f99059ff775485246999027b31979550009c4be9d156892e55e7154bcd3cb0fea677f9d3103e1 \
forge script script/RegisterStock.s.sol:RegisterStock --rpc-url $RPC --account admin --broadcast
# if the pool's observation capacity is insufficient ("observe" reverts), grow it first (anyone can call it):
cast send $FACTORY "increaseV3ObservationCardinality(address,uint16)" 0xbe9D…03E1 600 --rpc-url $RPC --account keeper
```

Every successful TWAP_V2 `buyStocks` / `buyAndBurn` advances the checkpoint automatically; the keeper should still
call `updateTwapObservations` once an hour so that the 24-hour upper window is never exceeded. Because the STONKS
pool is thin (~125 BNB), keep `maxSpendPerBuy` / `maxSpendPerBurn` at 0.2–0.5 BNB;
otherwise the price impact consumes the deviation band (default 5%) and the buy reverts with
`minOut below oracle floor`.

```bash
set -a; source .env; set +a
forge script script/RegisterStock.s.sol:RegisterStock --rpc-url $RPC --account admin            # simulation
forge script script/RegisterStock.s.sol:RegisterStock --rpc-url $RPC --account admin --broadcast
```

For a second stock, repeat the same script with USDT
(`STOCK=0x3376...4dDd`, `PRICE_FEED=0xEca2...D620`, `V2_PATH=<WBNB>,<USDT>`).

If you are going to use a V3 pool, set `DEX_KIND=V3` and provide a packed path
(`tokenIn(20 bytes) + fee(3 bytes) + tokenOut(20 bytes)`; e.g. fee `0009c4` for 0.25%):

```
V3_PATH=0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd0009c4FA60D973F7642B748046464e165A65B7323b0DEE
```

### 3b. Directly with `cast`

```bash
PATH_V2=$(cast abi-encode "f(address[])" "[0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,0xFa60D973F7642B748046464e165A65B7323b0DEE]")
cast send $FACTORY "registerStock(address,uint8,bytes,uint8,address,bool)" \
    0xFa60D973F7642B748046464e165A65B7323b0DEE 0 $PATH_V2 0 0x81faeDDfeBc2F8Ac524327d70Cf913001732224C true \
    --rpc-url $RPC --account admin
```

Check:

```bash
cast call $FACTORY "getStock(address)((bool,uint8,uint8,address,bytes))" 0xFa60D973F7642B748046464e165A65B7323b0DEE --rpc-url $RPC
cast call $FACTORY "getStockList()(address[])" --rpc-url $RPC
```

Registration validations (the transaction reverts otherwise): the path must start with WBNB and end with the stock,
the feed address cannot be zero and must respond to `decimals()`. Calls from anyone other than `platformAdmin`
or the Guardian are rejected with `Only platform admin or Guardian`.

---

## 4. Launching a test token through testnet.flap.sh

1. Go to https://testnet.flap.sh and connect your wallet to BSC testnet.
2. Select **Launch Token → Custom Vault** and paste the `FACTORY` address into the **Vault Factory**
   field. The Flap UI reads `factory.vaultDataSchema()` and renders the form automatically.
3. The vault form is filled in row by row (`target`, `bps`, `isStock`, `minHolding`); **the `bps` of all
   rows must sum to 10000**, and `minHolding` (the minimum token balance required to take part in
   distributions, informational) is written identically on every row (rows left at 0 are ignored):

   | target | bps | isStock | minHolding | Meaning |
   |---|---|---|---|---|
   | `0x<your wallet>` | 3000 | false | 1000 | Fee route: 30% of net revenue goes to this address (withdrawn with claimFees) |
   | `0x<second wallet>` | 2000 | false | 1000 | Fee route 20% |
   | `0xFa60…0DEE` (CAKE) | 2500 | true | 1000 | Stock pool share 25% → CAKE is bought |
   | `0x3376…4dDd` (USDT) | 2500 | true | 1000 | Stock pool share 25% → USDT is bought |

   If `mandatoryStock` is set on the factory (mainnet: STONKS), that token must be present as a stock
   row; otherwise the launch reverts with `Mandatory stock missing`.

   The tokens of the stock rows must have been registered in step 3; otherwise the launch reverts
   with `Stock not registered`. If a fee route is to be given by X handle, the StonksPad site creates the
   custodial wallet for that handle **in advance** and writes its address; the vault only knows addresses.
4. Token parameters:
   - **Quote token: BNB** (an ERC20 quote is rejected).
   - **`mktBps` > 0** (the vault share) and **`dividendBps` = 0**; Flap's deflation and LP shares are unrestricted.
     Otherwise the factory's `onBeforeLaunch` check rejects the launch. The UI also shows these constraints
     as hints via `tokenCreationPolicies()`.
   - Buy/sell tax: 5% / 5% is fine for testing.
5. Confirm the transaction. Flap first sets up the BeaconProxy vault via `factory.newVault()`, then creates
   the token. Note the token address (`TOKEN`).

If you prefer the CLI over the UI, `vaultData` is encoded as follows (an array of rows):

```bash
cast abi-encode "f((address,uint16,bool,uint256)[])" \
  "[(0xAAAA...,3000,false,1000000000000000000000),(0xBBBB...,2000,false,1000000000000000000000),(0xFa60D973F7642B748046464e165A65B7323b0DEE,2500,true,1000000000000000000000),(0x337610d27c682E347C9cD60BD4b3b107C9d34dDd,2500,true,1000000000000000000000)]"
```

These bytes go into the `NewTokenV6WithVaultParams.vaultData` field; the `salt` field must produce the vanity
suffix (`…7777`) — the UI finds it automatically, while on the CLI you need the logic in
`test/lib/VanityHelper.sol`. For this reason we recommend doing the first launch through the UI.

---

## 5. Post-launch verification

```bash
VAULT_PORTAL=0x027e3704fC5C16522e9393d04C60A3ac5c0d775f
cast call $VAULT_PORTAL "getVault(address)((address,address,string,bool,uint8))" $TOKEN --rpc-url $RPC
# → the first field is the VAULT address; the second field must be FACTORY
export VAULT=0x...

TAXP=$(cast call $TOKEN "taxProcessor()(address)" --rpc-url $RPC)
cast call $TAXP "marketAddress()(address)" --rpc-url $RPC        # == VAULT
cast call $VAULT "vaultUISchema()" --rpc-url $RPC | head -c 200   # must return the schema
cast call $VAULT "description()(string)" --rpc-url $RPC
```

Trigger the revenue flow: make a small buy of the token on testnet.flap.sh (e.g. 0.05 tBNB),
then send the accumulated tax to the vault:

```bash
cast send $TAXP "dispatch()" --rpc-url $RPC --account deployer
cast call $VAULT "stats()(uint256,uint256,uint256,uint256,uint256,uint256,uint256)" --rpc-url $RPC
# received, net, platformPending, stockPool, spentOnStocks, buys, epochs
cast call $VAULT "claimableFees(address)(uint256)" 0x<fee route wallet> --rpc-url $RPC
```

The fee route owner withdraws their own share:

```bash
cast send $VAULT "claimFees()" --rpc-url $RPC --account <route wallet>
```

Anyone can push the platform commission to the treasury (`StonksPadTreasury`); on the treasury side
`collect` is the batch pull, `distribute` pays the wallets, and `buyAndBurn` (keeper) is the STONKS buy-and-burn:

```bash
cast send $VAULT "withdrawPlatformFee()" --rpc-url $RPC --account deployer
cast send $TREASURY "collect(address[])" "[$VAULT]" --rpc-url $RPC --account deployer        # alternative
cast call $TREASURY "burnPool()(uint256)" --rpc-url $RPC                                       # 80%
cast send $TREASURY "distribute()" --rpc-url $RPC --account deployer                          # 10% NFT + 10% platform
# burn: minOut = getAmountsOut(min(burnPool, maxSpendPerBurn), WBNB→…→STONKS) × 0.97
cast send $TREASURY "buyAndBurn(uint256,uint256)" <minOut> $(( $(date +%s) + 300 )) --rpc-url $RPC --account keeper
```

---

## 6. Keeper flow (stock buys and distribution)

### 6a. Stock buys

`buyStocks(minOuts[], deadline)` can only be called by the keeper or the Guardian. `minOuts` is the
per-stock minimum output in `getStocks()` order and must be above **two floors**:
the DEX quote × (1 − `maxSlippageBps`, default 3%) and the Chainlink quote ×
(1 − `maxOracleDeviationBps`, default 5%). The spend amount is `min(stockPool, maxSpendPerBuy)`
(default 5 BNB; on testnet you can lower it with `setMaxSpendPerBuy(0.1 ether)`).

```bash
POOL=$(cast call $VAULT "stockPoolAvailable()(uint256)" --rpc-url $RPC)
MAX=$(cast call $VAULT "maxSpendPerBuy()(uint256)" --rpc-url $RPC)
# SPEND = min(POOL, MAX); each stock's amountIn = SPEND * bps / (sum of enabled stock bps)

# quote for CAKE (V2):
cast call 0xD99D1c33F9fC3444f8101754aBC46c52416550D1 \
  "getAmountsOut(uint256,address[])(uint256[])" <amountIn> \
  "[0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,0xFa60D973F7642B748046464e165A65B7323b0DEE]" --rpc-url $RPC
# minOut = quote * 0.97 (compute the same ratio for every stock)

DEADLINE=$(( $(date +%s) + 300 ))
cast send $VAULT "buyStocks(uint256[],uint256)" "[<minOutCAKE>,<minOutUSDT>]" $DEADLINE \
    --rpc-url $RPC --account keeper
cast call $VAULT "getStocks()((address,uint16,uint256,bool)[])" --rpc-url $RPC   # undistributed must increase
```

There must be at least 10 minutes between two buys (`Buy interval not elapsed`).

### 6b. Distribution epoch and claims

1. The backend takes a snapshot of the token holders and produces a leaf for every holder:
   `keccak256(bytes.concat(keccak256(abi.encode(epochId, holder, stocks[], amounts[]))))`
   (OpenZeppelin `MerkleProof`, sorted-pair hashing). It puts the snapshot on IPFS (`cid`).
2. The keeper publishes the epoch (the reserve is deducted from `stockUndistributed`):

   ```bash
   cast send $VAULT "publishDistribution(bytes32,address[],uint256[],string)" \
       $ROOT "[<CAKE>,<USDT>]" "[<totalCAKE>,<totalUSDT>]" "ipfs://<cid>" \
       --rpc-url $RPC --account keeper
   ```
3. **24-hour veto window**: during this time `platformAdmin` or the Guardian can cancel a faulty epoch
   with `cancelEpoch(epochId)`; the reserve is returned. Claims open once the window closes.
4. Holder claim (the StonksPad site produces the `claimData`):

   ```bash
   CLAIM=$(cast abi-encode "f(address[],uint256[],bytes32[])" "[<CAKE>,<USDT>]" "[<a1>,<a2>]" "[<proof...>]")
   cast send $VAULT "claimStocks(uint256,bytes)" 1 $CLAIM --rpc-url $RPC --account <holder>
   ```

   Check: `hasClaimed(1, holder)`, `epochRemaining(1, CAKE)`.

---

## 7. Common errors

| Error | Cause / fix |
|---|---|
| `UnsupportedChain` | The script ran against the wrong chain; `--rpc-url` must be testnet (97). |
| `Only VaultPortal / 仅限 VaultPortal 调用` | `newVault` was called directly; the launch must go through VaultPortal. |
| `Stock not registered / 股票未注册` | The token in the stock row is not registered/enabled in the factory (step 3). |
| `Allocations must sum to 10000` | The `bps` total is not 10000. |
| `mktBps must be 10000` | Only on the first testnet generation (v1): the market share was not 100%, or dividend/deflation/lp > 0. Later generations only require `mktBps > 0`. |
| `Stale oracle price / 预言机价格过期` | The testnet Chainlink feed is stale; `setOracleStaleness(604800)`. |
| `minOut below oracle floor` | The DEX price is more expensive than the oracle by more than `maxOracleDeviationBps`; wait, or have the admin widen the band (≤ 10%). |
| `Buy interval not elapsed` | 10 minutes have not passed since the last buy. |
| `Claims not open yet` | 24 hours have not passed since the epoch was published. |
| `TWAP observation missing` / `out of window` | There is no checkpoint aged 30 min–24 h for the stock in TWAP_V2 mode; call `updateTwapObservations(stock)` and wait 30 min. |
| `Pool has no liquidity` / `observe` reverts (TWAP_V3) | A V3 pool on the path is empty or its observation history does not cover 30 min; use the correct fee tier and, if needed, call `increaseV3ObservationCardinality` and wait. |
| `Mandatory stock missing` | The launch has no stock row for `mandatoryStock` (STONKS). |
| `Inconsistent minHolding` | The rows contain differing non-zero `minHolding` values. |

---

## 8. Mainnet differences

- Script: `script/mainnet/bnb/DeployStonksPadVaultFactory.s.sol`, RPC `https://bsc-dataseed.bnbchain.org`;
  the same eight transactions, Guardian `0x9e27…8a4b`.
  The mainnet addresses (WBNB `0xbb4C…095c`, V2 router `0x10ED…024E`, SmartRouter `0x13f4…8Dd4`,
  QuoterV2 `0xB048…5997`, Chainlink BNB/USD `0x0567…2aeE`) are embedded in the script.
- Recommendation: make `PLATFORM_ADMIN` a multisig (the epoch veto and the oracle band depend on this
  key). The current mainnet admin `0xBd86235E0EEB9b1659fc5090a0C8a160cD329Efb` is a single externally
  held wallet, not a multisig. `KEEPER` is only the backend's hot wallet.
- Stock registrations require real tokenized stock addresses; use a Chainlink stock/USD feed where
  one exists, otherwise one of the TWAP oracle modes (section 3).
- Before launch: `forge test --fork-url https://bsc-dataseed.bnbchain.org` and the AI spec-check
  (`audit_claude_fable_5_1.md`). The vault is built to Flap's public vault specification and its source is verified on BscScan. There is no third-party security audit yet.
