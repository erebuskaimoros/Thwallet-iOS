# Upstream synchronization record

## November 2026

Branch `upstream-sync` merges `horizontalsystems/unstoppable-wallet-ios`
`master` through `1da5adb4d` (381 commits) onto Thwallet `master`. The Android
repository made the matching synchronization on its own `upstream-sync` branch.

### Maintainer decisions (2026-11-14)

- **Native THORChain swaps stay.** Upstream deleted its native THORChain and
  Maya swap providers and quotes both through its USwap backend. Thwallet keeps
  `ThorChainMultiSwapProvider` / `BaseThorChainMultiSwapProvider`, rebuilt on
  upstream's last native version and the current provider protocol, and
  registers it in `SwapProviderResolver` in place of the USwap THORChain entry.
  Quote requests still omit `affiliate` and `affiliate_bps`
  (`ThorChainAffiliatePolicy`). Maya follows upstream through USwap. A THORkit
  backend is expected to replace this path later.
- **XRP follows upstream.** Upstream's XRP Ledger integration (persisted UID
  `xrp`, `XrpKit`, issued tokens as `TokenType.xrpAsset`) is adopted. Thwallet's
  own `xrp-support` branch (`ripple|native`, hand-written codec) is superseded
  and must not be merged. Android made the same choice, so the identifier is
  equal on both platforms.
- **Robinhood Chain** uses upstream's first-class `.robinhood` type under the
  same `robinhood` UID and chain ID 4663; see `EVM_NETWORKS.md`.

### Thwallet hardening carried onto upstream's rewritten code

- EVM gas validation, the Mantle and OP-stack additional-fee handling and the
  value-plus-fee balance policy live in `EvmFeeEstimator` / `EvmSendHandler`.
  The legacy Rx fee services upstream removed as dead code are gone.
- WalletConnect EVM requests on the new stack (`WalletConnect/Requests/Evm/`):
  `from` must be the signing account; quantities, calldata, gas-price fields,
  `type` and access lists are parsed fail-closed; gas is validated against the
  chain cap before signing; a dApp-supplied gas limit still goes through the
  fee estimator and balance policy.
- USwap server-built EVM transactions are decoded by `USwapEvmSignableParser`:
  a present but malformed `value`, `gas` or `data` rejects the route.

### Dependency forks

| Fork | Pinned revision | Base |
| --- | --- | --- |
| `BitcoinCore.Swift` | `74331848b91ae39e90781872e2006665d3c4abf7` | upstream 3.2.0 (unchanged) |
| `DogecoinKit.Swift` | `a2e55ec94b406b9323cc6b38adf0f50a67b2b144` | HdWalletKit 1.3.2, HsToolKit 2.0.7 |
| `EvmKit.Swift` | `3171b644b0cd4b62adea1923cad47a53c8974d2a` | upstream 2.7.0 |
| `MarketKit.Swift` | `4270a46087932465a44b8218535730ee1a3d4be5` | upstream 3.6.22 |

EvmKit 2.7.0 lets the app replace the transaction syncer list; the fork keeps
the RPC-only pending-transaction reconciler across `set(syncers:)`.

`Package.resolved` cannot be produced without Xcode. Run the CI workflow with
`refresh_package_resolved` enabled, download the `package-resolved` artifact and
commit it.

### Open cross-platform items

- The native THORChain provider refuses a non-transparent ZEC destination on
  iOS (`validateDestination`). Android has no equivalent guard yet.
- The WalletConnect EVM parsing rules above are iOS rules inherited from
  Thwallet's earlier hardening; Android has not been compared rule by rule.
- The native THORChain provider is offered only while the swap backend's
  provider list includes `THORCHAIN` unsuspended, because provider availability
  is server-driven upstream.
