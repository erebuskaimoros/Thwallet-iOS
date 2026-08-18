# Dogecoin integration policy

Dogecoin is a native-only Bitcoin-family chain in the iOS wallet. Product
changes that affect chain support must be evaluated and implemented on both
iOS and Android going forward; neither platform is considered complete on its
own.

## Wallet behavior

- Mainnet derivation is BIP-44 coin type `3`, with legacy P2PKH receive and
  change addresses. Extended public/private keys use Bitcoin's xpub/xprv
  version bytes but derive on the Dogecoin coin-type path.
- Send validation accepts Dogecoin mainnet P2PKH and P2SH destinations.
  Single-address watch accounts are intentionally limited to P2PKH.
- Native DOGE has 8 decimals. RBF and Bitcoin's Hodler time-lock UI are not
  enabled for Dogecoin.
- Created wallets that use full sync start from the recent pinned checkpoint.
  Restored and watch wallets start from the BIP-44 checkpoint. Blockchair,
  hybrid, and full modes remain selectable for Dogecoin.
- The minimum relay fee exposed by the app is 100 koinu/byte and the normal
  recommendation is 1,000 koinu/byte. The chain kit enforces a 100,000-koinu
  hard dust threshold and a 1,000,000-koinu soft-dust policy.
- THORChain input selection uses P2PKH UTXOs and at most 10 inputs. The final
  fee rate is the maximum of the user-selected rate, THORChain's
  `recommended_gas_rate`, and the 100-koinu/byte floor. Quotes fail closed
  unless `gas_rate_units` is exactly `satsperbyte` (case-insensitive) and the
  recommended rate is in the validated 1...1,000,000 range. The quote must also
  provide a positive `dust_threshold` no greater than 1,000,000,000 base units.
- Direct THORChain swaps do not send affiliate or affiliate-bps parameters.
  Network, liquidity, outbound, slip, and gas costs still apply.
- OpenCryptoPay does not advertise or broadcast Dogecoin transactions.

## Release gates

Before enabling DOGE in a release:

1. Pin reviewed, immutable revisions of `DogecoinKit.Swift`, the compatible
   `BitcoinCore.Swift` fork, and the `MarketKit.Swift` fork containing the
   Dogecoin blockchain/token metadata. Record their licenses and hashes in the
   release evidence.
2. Run the WalletCore and app test suites with the supported Xcode version on
   clean hardware, including the `DogecoinIntegrationTests` derivation and
   address-policy coverage.
3. Exercise created, restored, extended-key, and P2PKH watch accounts against
   mainnet. Verify full historical restore, recent sync, reorg handling,
   balance/history persistence, database cleanup, and restart recovery.
4. Test P2PKH/P2SH sends, hard and soft dust behavior, low/high fee handling,
   broadcast ambiguity, and a live THORChain quote/send canary. Confirm the
   quote and memo contain no wallet affiliate.
5. Review Blockchair/API availability, P2P DNS seeds, Tor behavior, privacy
   disclosures, background-network behavior, App Store metadata, signing, and
   reproducible-build evidence. Do not ship from inherited upstream release
   automation or upstream-owned service configuration.

The app currently has Dogecoin alternate-icon artwork and a `dogecoin` URL
scheme. Token and chain imagery otherwise comes from pinned MarketKit metadata.

## Immutable dependencies

- `BitcoinCore.Swift`: `74331848b91ae39e90781872e2006665d3c4abf7`
- `DogecoinKit.Swift`: `367559c58f9d2c5e4c8cd649a9bcb61e5bc751bc`
- `MarketKit.Swift`: `612b3457dc01e484d6fe808db8c5f12e88bf98c2`

WalletCore pins these full revisions and mirrors both upstream BitcoinCore URL
spellings to the reviewed fork so every Bitcoin-family wrapper uses one core
implementation.
