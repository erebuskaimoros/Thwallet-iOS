# Thwallet iOS Agent Notes

## Project identity

- This checkout owns the iOS Thwallet product line.
- It is a public GitHub fork of `horizontalsystems/unstoppable-wallet-ios`.
- `origin` is `https://github.com/erebuskaimoros/Thwallet-iOS.git` and is the
  only push target.
- `upstream` is fetch-only. Never push to Horizontal Systems.
- Preserve the MIT license, upstream Git history, and attribution.
- Thwallet is independent and must not claim official THORChain, Nine Realms,
  or Horizontal Systems endorsement.

## Cross-platform parity

- Thwallet's Android peer is
  `https://github.com/erebuskaimoros/Thwallet`.
- Scope blockchain, protocol, swap, and wallet-format changes for both iOS and
  Android by default. "Complete" means both implementations are tested and
  pushed, unless an intentional platform exception is recorded in both
  repositories.
- Keep persisted chain/token identifiers, derivation paths, address policies,
  quote validation, fee rules, and user-visible safety behavior equivalent
  across platforms. Platform-native implementations do not need identical
  internal structure.
- Review upstream changes for cross-platform impact and record temporary parity
  gaps explicitly; do not let one platform silently become the reference
  implementation for the other.

## Product policy

- Direct THORChain swaps must not charge a wallet affiliate fee.
- Direct THORChain quote requests must omit both affiliate and affiliate-basis-
  points parameters. Keep a regression test covering this invariant.
- Do not describe swaps as entirely fee-free: network, liquidity, outbound,
  slip, and gas costs still apply.
- Other swap providers remain outside this narrow policy until independently
  audited and explicitly brought into scope.

## Security and releases

- Treat changes to key derivation, seed storage, signing, transaction assembly,
  destination addresses, quote validation, and dependency sources as
  security-critical.
- Never commit mnemonics, private keys, signing stores, credentials, signing
  certificates, provisioning profiles, or live service secrets.
- Inherited GitHub release and deployment workflows target upstream-owned
  services. Keep them disabled until Thwallet-owned CI and secrets are
  configured.
- Do not publish an App Store or TestFlight build before bundle identifiers,
  deep links, service endpoints, branding, signing identity, privacy policy,
  entitlements, and reproducible-build process are independently reviewed.

## Build and test

Use a full supported Xcode installation and the checked-in Swift package
manifests.

```bash
xcodebuild -workspace Wallet.xcworkspace -scheme Development \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -workspace Wallet.xcworkspace -scheme Development \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
swift test --package-path packages/WalletCore
```

- Select an installed simulator when the example destination is unavailable.
- Add unit tests for chain logic and integration tests for persistence,
  transaction construction, signing, and process-recovery paths.
- Prefer Swift concurrency for new asynchronous code where it fits existing
  architecture; preserve established reactive interfaces when bridging legacy
  modules.
- Use imperative commit messages without type prefixes; keep the summary at or
  below 60 characters.

## Upstream synchronization

1. Fetch `upstream` and inspect changes before merging or rebasing.
2. Re-run the zero-affiliate test and inspect every THORChain quote/memo path.
3. Review wallet/security changes separately from UI or translation changes.
4. Record material architecture, dependency, parity, or policy changes in the
   repository documentation and the shared THORChain workspace wiki.
