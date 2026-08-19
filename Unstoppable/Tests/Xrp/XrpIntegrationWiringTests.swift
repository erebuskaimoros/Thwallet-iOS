import Combine
import Foundation
import GRDB
import MarketKit
import RxSwift
import Testing
@testable import WalletCore

struct XrpIntegrationWiringTests {
    private let classic = "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"
    private let destination = "r3AgF9mMBFtaLhKcg96weMhbbEFLZ3mx17"

    @Test
    func chainMetadataAndNativeAccountPolicyAreStable() {
        let token = xrpToken()
        let mnemonic = AccountType.mnemonic(words: [], salt: "", bip39Compliant: true)
        let watch = AccountType.xrpAddress(address: classic)

        #expect(BlockchainType.ripple.uid == "ripple")
        #expect(BlockchainType.supported.contains(.ripple))
        #expect(BlockchainType.ripple.defaultTokenQuery == TokenQuery(blockchainType: .ripple, tokenType: .native))
        #expect(BlockchainType.ripple.nativeTokenQueries == [TokenQuery(blockchainType: .ripple, tokenType: .native)])
        #expect(BlockchainType.ripple.uriScheme == "xrpl")
        #expect(BlockchainType.ripple.removeScheme)
        #expect(BlockchainType.ripple.description == "XRP")
        #expect(BlockchainType.ripple.blockTime == 4)
        #expect(mnemonic.supports(token: token))
        #expect(watch.supports(token: token))
        #expect(watch.watchAddress == classic)
        #expect(watch.statDescription == "xrp_address")
    }

    @Test
    func watchAccountBackupIdentityAndStorageRoundTrip() throws {
        let type = AccountType.xrpAddress(address: classic)
        let decoded = AccountType.decode(uniqueId: type.uniqueId(hashed: false), type: AccountType.Abstract(type))
        #expect(decoded == type)

        let environment = try XrpAccountStorageEnvironment()
        let account = Account(
            id: UUID().uuidString,
            level: 0,
            name: "XRP Watch",
            type: type,
            origin: .restored,
            backedUp: false,
            fileBackedUp: false
        )
        environment.storage.save(account: account)
        let (accounts, lost) = environment.storage.allAccounts
        #expect(lost.isEmpty)
        #expect(accounts.count == 1)
        #expect(accounts.first?.type == type)
        #expect(accounts.first?.watchAccount == true)
    }

    @Test
    func uriPreservesTagZeroByEncodingAnXAddress() throws {
        let parser = AddressUriParser(blockchainType: .ripple, tokenType: .native)
        let uri = try parser.parse(url: "xrpl:account?address=\(destination)&tag=0&amount=12.5&memo=THOR")
        let resolved = try XrpAddressCodec.resolve(uri.address, separateTag: nil, network: .mainnet)

        #expect(uri.scheme == "xrpl")
        #expect(resolved.classicAddress == destination)
        #expect(resolved.destinationTag == 0)
        #expect(uri.parameters[.destinationTag] == "0")
        #expect(uri.amount == .decimals(Decimal(string: "12.5")!))
        #expect(uri.memo == "THOR")
    }

    @Test
    func uriRejectsOverflowAndTestnetXAddress() throws {
        let parser = AddressUriParser(blockchainType: .ripple, tokenType: .native)
        #expect(throws: (any Error).self) {
            try parser.parse(url: "xrpl:account?address=\(destination)&tag=4294967296")
        }

        let testnet = try XrpAddressCodec.encodeXAddress(classicAddress: destination, destinationTag: 1, network: .testnet)
        #expect(throws: (any Error).self) {
            try parser.parse(url: "xrpl:\(testnet)")
        }
    }

    @Test
    func uriRejectsDuplicateCriticalKeysAndConflictingTagAliases() throws {
        let parser = AddressUriParser(blockchainType: .ripple, tokenType: .native)
        for duplicate in [
            "address=\(destination)&address=\(classic)",
            "address=\(destination)&tag=0&tag=1",
            "address=\(destination)&amount=1&amount=2",
            "address=\(destination)&memo=A&memo=B",
        ] {
            #expect(throws: AddressUriParser.ParseError.wrongUri) {
                try parser.parse(url: "xrpl:account?\(duplicate)")
            }
        }

        #expect(throws: AddressUriParser.ParseError.wrongUri) {
            try parser.parse(url: "xrpl:account?address=\(destination)&tag=0&dt=1")
        }
        let sameTag = try parser.parse(url: "xrpl:account?address=\(destination)&tag=0&dt=0")
        #expect(try XrpAddressCodec.resolve(sameTag.address, separateTag: nil, network: .mainnet).destinationTag == 0)

        let maximum = try parser.parse(url: "xrpl:account?address=\(destination)&tag=4294967295")
        #expect(try XrpAddressCodec.resolve(maximum.address, separateTag: nil, network: .mainnet).destinationTag == UInt32.max)
    }

    @Test
    func uriPreservesUnknownOptionalFieldsAndRejectsRequiredExtensions() throws {
        let parser = AddressUriParser(blockchainType: .ripple, tokenType: .native)
        let optional = try parser.parse(url: "xrpl:account?address=\(destination)&invoice=ABC")
        #expect(optional.unhandledParameters["invoice"] == "ABC")

        #expect(throws: AddressUriParser.ParseError.wrongUri) {
            try parser.parse(url: "xrpl:account?address=\(destination)&req-invoice=ABC")
        }
    }

    @Test
    func watchAccountRejectsTaggedXAddressIncludingTagZero() throws {
        let noTag = try XrpAddressCodec.encodeXAddress(
            classicAddress: destination,
            destinationTag: nil,
            network: .mainnet
        )
        let tagZero = try XrpAddressCodec.encodeXAddress(
            classicAddress: destination,
            destinationTag: 0,
            network: .mainnet
        )

        #expect(try xrpWatchAccountType(address: noTag) == .xrpAddress(address: destination))
        #expect(throws: XrpCodecError.invalidDestinationTag) {
            try xrpWatchAccountType(address: tagZero)
        }
    }

    @Test
    func sendDataKeepsExternalFeeDustAndTagFieldsDistinct() {
        let data = SendData.xrp(
            token: xrpToken(),
            amount: 100,
            destination: destination,
            destinationTag: 0,
            memo: "SWAP:THOR.RUNE",
            recommendedFeeDrops: 300,
            minimumSendAmountDrops: 100_000_000
        )

        guard case let .xrp(_, amount, target, tag, memo, fee, minimum) = data else {
            Issue.record("Expected native XRP send data")
            return
        }
        #expect(amount == 100)
        #expect(target == destination)
        #expect(tag == 0)
        #expect(memo == "SWAP:THOR.RUNE")
        #expect(fee == 300)
        #expect(minimum == 100_000_000)
    }

    @Test
    func selfTransferHistoryIsFeeOnlyAndNotAnInboundGain() {
        let token = xrpToken()
        let record = XrpHistoryRecord(
            hash: "SELF",
            ledgerIndex: 100,
            timestamp: 1,
            direction: .selfTransfer,
            amountDrops: 1_000_000,
            feeDrops: 12,
            counterparty: classic,
            destinationTag: 0,
            resultCode: "tesSUCCESS",
            memo: nil
        )
        let transaction = XrpTransactionRecord(
            record: record,
            token: token,
            source: TransactionSource(blockchainType: .ripple, meta: nil),
            ownAddress: classic
        )

        #expect(transaction.value.value == 0)
        #expect(transaction.fee?.value == Decimal(string: "0.000012"))
        #expect(transaction.sentToSelf)
    }

    private func xrpToken() -> Token {
        Token(
            coin: Coin(uid: "ripple", name: "XRP", code: "XRP"),
            blockchain: Blockchain(type: .ripple, name: "XRP Ledger", explorerUrl: nil),
            type: .native,
            decimals: 6
        )
    }
}

private struct XrpAccountStorageEnvironment {
    let storage: AccountStorage

    init() throws {
        let dbPool = try DatabasePool(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("xrp-account-storage-\(UUID().uuidString).sqlite").path)
        try dbPool.write { db in
            try db.create(table: AccountRecord.databaseTableName) { table in
                table.column(AccountRecord.Columns.id.rawValue, .text).notNull().primaryKey()
                table.column(AccountRecord.Columns.level.rawValue, .integer).notNull()
                table.column(AccountRecord.Columns.name.rawValue, .text).notNull()
                table.column(AccountRecord.Columns.type.rawValue, .text).notNull()
                table.column(AccountRecord.Columns.origin.rawValue, .text).notNull()
                table.column(AccountRecord.Columns.backedUp.rawValue, .boolean).notNull()
                table.column(AccountRecord.Columns.fileBackedUp.rawValue, .boolean).notNull()
                table.column(AccountRecord.Columns.wordsKey.rawValue, .text)
                table.column(AccountRecord.Columns.saltKey.rawValue, .text)
                table.column(AccountRecord.Columns.dataKey.rawValue, .text)
                table.column(AccountRecord.Columns.bip39Compliant.rawValue, .boolean)
            }
        }
        storage = AccountStorage(secureStorage: XrpTestSecureStorage(), storage: AccountRecordStorage(dbPool: dbPool))
    }
}

private final class XrpTestSecureStorage: AccountSecureStorage {
    func string(for _: String) -> String? { nil }
    func data(for _: String) -> Data? { nil }
    func set(string _: String?, for _: String) throws {}
    func set(data _: Data?, for _: String) throws {}
    func removeValue(for _: String) throws {}
}
