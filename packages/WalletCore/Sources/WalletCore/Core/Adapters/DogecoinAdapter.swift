import BitcoinCore
import DogecoinKit
import Foundation
import HdWalletKit
import MarketKit

class DogecoinAdapter: BitcoinBaseAdapter {
    static let networkType: DogecoinKit.Kit.NetworkType = .mainNet

    private let dogecoinKit: DogecoinKit.Kit

    init(wallet: Wallet, syncMode: BitcoinCore.SyncMode) throws {
        let logger = Core.shared.logger.scoped(with: "DogecoinKit")
        let useRecentPinnedStart = dogecoinUsesRecentPinnedFullSync(
            accountOrigin: wallet.account.origin,
            watchAccount: wallet.account.watchAccount
        )

        switch wallet.account.type {
        case .mnemonic:
            guard let seed = wallet.account.type.mnemonicSeed else {
                throw AdapterError.unsupportedAccount
            }

            dogecoinKit = try DogecoinKit.Kit(
                seed: seed,
                walletId: wallet.account.id,
                syncMode: syncMode,
                networkType: Self.networkType,
                confirmationsThreshold: Self.confirmationsThreshold,
                fullSyncStart: useRecentPinnedStart ? .recentPinned : .bip44,
                logger: logger
            )
        case let .hdExtendedKey(key):
            dogecoinKit = try DogecoinKit.Kit(
                extendedKey: key,
                walletId: wallet.account.id,
                syncMode: syncMode,
                networkType: Self.networkType,
                confirmationsThreshold: Self.confirmationsThreshold,
                fullSyncStart: useRecentPinnedStart ? .recentPinned : .bip44,
                logger: logger
            )
        case let .btcAddress(address, _, _):
            dogecoinKit = try DogecoinKit.Kit(
                watchAddress: address,
                walletId: wallet.account.id,
                syncMode: syncMode,
                networkType: Self.networkType,
                confirmationsThreshold: Self.confirmationsThreshold,
                fullSyncStart: .bip44,
                logger: logger
            )
        default:
            throw AdapterError.unsupportedAccount
        }

        super.init(abstractKit: dogecoinKit, wallet: wallet, syncMode: syncMode)

        dogecoinKit.delegate = self
    }

    override var explorerTitle: String {
        "blockchair.com"
    }

    override func explorerUrl(transactionHash: String) -> String? {
        "https://blockchair.com/dogecoin/transaction/" + transactionHash
    }

    override func explorerUrl(address: String) -> String? {
        "https://blockchair.com/dogecoin/address/" + address
    }
}

extension DogecoinAdapter: ISendBitcoinAdapter {
    var blockchainType: BlockchainType {
        .dogecoin
    }
}

extension DogecoinAdapter {
    static func clear(except excludedWalletIds: [String]) throws {
        try DogecoinKit.Kit.clear(exceptFor: excludedWalletIds)
    }

    static func firstAddress(accountType: AccountType) throws -> String {
        switch accountType {
        case .mnemonic:
            guard let seed = accountType.mnemonicSeed else {
                throw AdapterError.unsupportedAccount
            }

            return try DogecoinKit.Kit.firstAddress(
                seed: seed,
                networkType: networkType
            ).stringValue
        case let .hdExtendedKey(key):
            return try DogecoinKit.Kit.firstAddress(
                extendedKey: key,
                networkType: networkType
            ).stringValue
        case let .btcAddress(address, _, _):
            return address
        default:
            throw AdapterError.unsupportedAccount
        }
    }
}

func dogecoinUsesRecentPinnedFullSync(accountOrigin: AccountOrigin, watchAccount: Bool) -> Bool {
    accountOrigin == .created && !watchAccount
}
