# Additional EVM network policy

Thwallet supports the following additional EVM networks on both iOS and
Android. Persisted blockchain UIDs and chain IDs are cross-platform contracts;
changing either requires an explicit storage migration.

| Network | UID | Chain ID | Native asset | Fee model | History |
| --- | --- | ---: | --- | --- | --- |
| Cronos | `cronos` | 25 | CRO / 18 | standard EVM | RPC-only |
| Blast | `blast` | 81457 | ETH / 18 | OP-stack L1 + L2 | Etherscan V2 |
| Mantle | `mantle` | 5000 | MNT / 18 | `eth_estimateTotalFee` + execution | Etherscan V2 |
| Sei EVM | `sei-network` | 1329 | SEI / 18 | standard EVM | Etherscan V2 |
| HyperEVM | `hyperevm` | 999 | HYPE / 18 | standard EVM, 3,000,000 gas cap | Etherscan V2 |
| Robinhood Chain | `robinhood` | 4663 | ETH / 18 | standard EVM | Blockscout |

`hyperevm` is the blockchain UID while `hyperliquid` remains the native coin
UID. `sei-network` intentionally matches the current MarketKit/BlocksDecoded
catalog; a future move to `sei-v2` needs an alias and persisted-ID migration.

## Wallet behavior

- All six networks use Ethereum coin type 60 derivation, EIP-155 replay
  protection, EIP-1559 transactions, local signing, native transfers, EIP-20
  transfers, WalletConnect, custom RPC selection, database cleanup, and
  transaction explorer links.
- Market metadata is normalized at the dependency storage boundary. Every
  managed network receives one authoritative native token. Contract rows with
  missing decimals, malformed addresses, ambiguous metadata, or Mantle's
  pseudo-native address are rejected rather than made spendable.
- Blast preserves the signed/surcharged gas limit while including its L1 fee.
  Mantle separates execution gas from the additional network fee. Normal,
  send-all, predefined-gas, and WalletConnect paths use checked arithmetic and
  validate value plus the complete fee against the available balance.
- Cronos intentionally has no indexed history provider in the current fork.
  Local sends work, but inbound history may be incomplete until a reviewed
  indexer is added.
- Direct THORChain quote paths continue to omit wallet affiliate and
  affiliate-bps parameters. uSwap availability remains controlled by its
  backend and is not implied by local chain support.

## Immutable dependencies

- `MarketKit.Swift`: `612b3457dc01e484d6fe808db8c5f12e88bf98c2`
- `EvmKit.Swift`: `e9cfc0367211346ca7864109e8a5c7c24380186b`

WalletCore pins both full revisions and commits SwiftPM mirrors for both
upstream URL spellings. This keeps transitive EVM consumers on the same audited
fork revisions.

## Release gates

Before enabling these networks in a production build:

1. Run dependency and integrated app tests with the supported full Xcode
   version and a locked package graph.
2. Provision and verify Etherscan V2 credentials, then test inbound/outbound
   history and explorer links on every network.
3. Exercise native and contract sends, send-all, WalletConnect, explicit gas,
   insufficient-balance, failed-RPC, restart, and database-cleanup paths.
4. Add independently operated RPC fallbacks and monitor rate limits and chain
   identity; the initial catalog has one endpoint per new network.
5. Review chain imagery, localization, privacy disclosures, signing identity,
   service ownership, and reproducible archive evidence. Do not ship through
   inherited upstream release automation.
