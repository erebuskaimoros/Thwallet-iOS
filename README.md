# Thwallet iOS

This repository is the iOS half of Thwallet, an experimental,
community-maintained wallet focused on THORChain-native self-custody and swaps.
The companion Android product is maintained in
[Thwallet](https://github.com/erebuskaimoros/Thwallet).

The project is derived from the MIT-licensed
[Unstoppable Wallet iOS](https://github.com/horizontalsystems/unstoppable-wallet-ios)
codebase. Its GitHub fork relationship and `upstream` Git remote preserve that
provenance and provide a path for security updates.

## Current status

Thwallet is in its initial bootstrap phase. It has not completed independent
bundle-ID, branding, signing, endpoint, reproducible-build, privacy, or security
review work and must not be treated as a production release.

Direct THORChain quote requests omit wallet affiliate parameters. Users still
pay unavoidable network, outbound, liquidity, slip, and gas costs. Other swap
providers have independent fee models and must be evaluated separately.

Blockchain and protocol features are scoped for iOS and Android together by
default. A feature is complete only when equivalent user-visible behavior and
security invariants are tested and pushed on both platforms, unless an
intentional exception is documented in both repositories.

## Development

The app is implemented in Swift and requires a full supported Xcode
installation.

```bash
xcodebuild -workspace Wallet.xcworkspace -scheme Development \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -workspace Wallet.xcworkspace -scheme Development \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Use an installed simulator when the example destination is unavailable.
Project-specific contribution and security rules are in
[AGENTS.md](./AGENTS.md).

## Independence and attribution

Thwallet is not an official THORChain, Nine Realms, or Horizontal Systems
product. The current user interface still contains upstream Unstoppable Wallet
branding while the independent identity is designed. Do not distribute builds
under either project's name or signing identity.

## License

The inherited source is available under the [MIT License](./LICENSE). Preserve
the license and upstream attribution when redistributing substantial portions
of the software.
