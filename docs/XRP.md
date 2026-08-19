# XRP Ledger integration policy

XRP support is a native-asset, mainnet-only wallet integration. Chain changes
must be implemented and reviewed on Android and iOS together; neither platform
is considered complete on its own.

## Supported behavior

- Derivation is secp256k1 BIP-44 `m/44'/144'/0'/0/0` from the wallet mnemonic.
- Native XRP uses the persisted blockchain UID `ripple`, token query
  `ripple|native`, and 6 decimal places.
- Receive and send accept classic addresses and mainnet X-addresses. An
  embedded or separate destination tag is a distinct optional UInt32 value;
  tag `0` is present, not absent. Conflicting tags and testnet X-addresses fail
  closed. Watch wallets normalize to a classic account and reject tagged
  X-addresses because a tag cannot scope balance or history.
- The signer supports only a typed native `Payment`: amount in drops, optional
  DestinationTag and one inert MemoData value. It always commits Sequence,
  LastLedgerSequence, `tfFullyCanonicalSig`, compressed public key, strict
  low-S DER signature, and the mainnet transaction hash. Issued currencies,
  paths, partial payments, trust lines, NFTs, DEX orders, tickets, multisign,
  account configuration, raw JSON, and dApp signing remain unsupported.
- RPC reads are pinned to validated ledgers. Available balance excludes the
  dynamic base reserve plus OwnerCount reserve. Sends query the live fee,
  enforce a hard cap, honor destination `RequireDestTag`, and require an
  inactive destination to receive at least the current base reserve.
- The exact signed blob and deterministic hash are persisted before submit.
  A preliminary `tesSUCCESS` is never final. Restart recovery polls by hash;
  only a validated metadata result finalizes success or failure. Expiry needs
  continuous `complete_ledgers` coverage, and sequence conflicts remain a
  manual state instead of triggering a newly signed retry.
- History uses validated `account_tx`, opaque marker pagination, atomic
  checkpoint advancement, hash upserts, and a `(ledger, hash)` UI cursor so a
  busy ledger cannot be skipped. Incoming native value comes from metadata
  `delivered_amount`; the advertised Amount/DeliverMax is used only for legacy
  direct payments whose metadata explicitly says `unavailable`. Issued
  currency and unsafe partial-payment rows are not rendered as XRP.

## Swaps

Direct THORChain XRP swaps use the live XRP pool and preserve Thwallet's
zero-wallet-affiliate policy: both affiliate quote parameters are omitted.
The quote must use exact case-insensitive `drop` gas units, a bounded positive
recommended fee, and a bounded positive dust threshold. The quoted memo's
canonical output asset, exact destination, slippage-derived minimum output,
and rapid-streaming quantity are commitment-checked before signing. An
unrequested refund suffix, affiliate/DEX fields, a nonzero response affiliate
fee, or a mismatched fee asset fail closed. The memo is encoded as XRPL
MemoData and is never confused with a DestinationTag.

uSwap, OpenCryptoPay, WalletConnect, and arbitrary XRP transaction signing stay
disabled until each protocol has an explicit, tested destination-tag contract.

## Release gates

Before enabling XRP in a production release:

1. Run the shared public golden vectors byte-for-byte on both platforms:
   BIP-44 derivation, classic/X-addresses including tag 0 and UInt32.max,
   signing preimages, strict DER signatures, final blobs, and transaction
   hashes.
2. Run clean unit, full-Xcode app, database reopen/migration, backup/watch,
   malformed-RPC, marker-pagination, fee/reserve, RequireDestTag, inactive
   destination, crash-before-submit, ambiguous-submit, restart, ledger-gap,
   expiry, and sequence-conflict gates.
3. Use a funded mainnet account on both platforms to test inbound restoration,
   classic and tagged X-address sends, process death after durable signing,
   validated success/failure, explorer links, and a no-affiliate THORChain
   quote/send canary.
4. Replace or explicitly approve the provisional public XRPL endpoint, add an
   independently operated fallback, and verify network ID, complete history,
   rate limits, privacy behavior, and outage/failover semantics.
5. Independently review the codec, derivation, signature generation,
   transaction commitments, dependency pins/licenses, release signing, and
   reproducible builds. Do not ship from inherited upstream automation.

## Immutable metadata dependency

- `MarketKit.Swift`: `67f401499c86d958a215fc035c37def6c6c6a65e`
