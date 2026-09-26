# StonksPad Contracts

Smart contracts behind [StonksPad](https://stonkspad.sh): a meme-token launchpad on BNB Chain, built on
[Flap](https://flap.sh) infrastructure, where every token's tax revenue buys tokenized stocks (and other
registered reward assets) for its holders.

Tokens are launched through Flap's `VaultPortal.newTokenV6WithVault()` with the
`StonksPadVaultFactory` as the vault factory. Each launch gets its own `StonksPadVault`
(a `BeaconProxy`) that receives the token's tax revenue in BNB and:

- routes the creator share to fee recipients (`claimFees`),
- buys the selected reward assets on PancakeSwap V2/V3 behind an oracle floor
  (Chainlink, PancakeSwap V2 TWAP or PancakeSwap V3 TWAP) — `buyStocks`,
- distributes them to holders per epoch through a merkle root that an independent verifier
  approves (`publishDistribution` → `approveEpoch` → `claimStocks`),
- forwards the platform fee to `StonksPadTreasury`, which buys and burns STONKS.

## Layout

| Path | Content |
|---|---|
| `src/` | `StonksPadVault`, `StonksPadVaultFactory`, `StonksPadTreasury`, `StonksPadSwapLib`, `StonksPadVaultUISchema`, interfaces, Flap base contracts |
| `test/` | BSC mainnet fork tests |
| `script/` | Deployment scripts (testnet / mainnet), `RegisterStock.s.sol`, implementation upgrade script |
| `docs/DESIGN.md` | Design document: revenue flow, oracle modes, limits, epochs, upgrade history |
| `docs/DEPLOY.md` | Deployment guide and the deployed addresses |
| `audit_claude_fable_5_1.md` | AI-generated audit report (not a substitute for a human audit) |
| `lib/` | Vendored dependencies: forge-std, OpenZeppelin Contracts and Contracts Upgradeable |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). Solidity 0.8.26, `via_ir`, EVM `cancun`.

```bash
forge build
# fork tests run against BSC mainnet state
forge test --fork-url https://bsc-dataseed.bnbchain.org
```

Copy `.env.example` to `.env` for the scripts. Never commit `.env`, keystores or broadcast logs;
`.gitignore` excludes them.

## Deployed addresses (BSC mainnet, chain 56)

| Contract | Address |
|---|---|
| StonksPadVaultFactory (v2, current) | `0x53Cc07A3Dd2015Cb84eFfcD0663B5Bd805a6bab4` |
| StonksPadTreasury | `0x994EF72de824e4B116158a11b8250D4f11377CD3` |
| Vault beacon | `0xFb634ef0808cc418A76a16B32a3C93049C69d0c0` |
| Vault implementation (v1.2) | `0xf89953bfe1ECec08b147006C511E3c7E19B5bb6E` |
| STONKS (mandatory reward asset) | `0xc9d825E83AadA475bD4d38C8ca984eD746277777` |

The legacy v1 generation and the testnet deployments are listed in `docs/DEPLOY.md`.

## Security

The vault is built to Flap's public vault specification and its source is verified on BscScan. There is no third-party security audit yet.

See `docs/DESIGN.md` for the trust model (keeper limits, spend caps, 24 h claim delay, verifier
approval, Guardian veto). Please report vulnerabilities privately to the StonksPad team before
disclosing them.

## License

Source files are MIT-licensed (see the SPDX identifiers). Vendored libraries keep their own licenses.
