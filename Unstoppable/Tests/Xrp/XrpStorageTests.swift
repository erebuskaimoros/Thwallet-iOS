import Foundation
import GRDB
import Testing
@testable import WalletCore

struct XrpStorageTests {
    @Test
    func exactSignedBlobAndLedgerGapSurviveDatabaseReopen() async throws {
        let fixture = try Fixture()
        var pending = try signedPending(privateKey: fixture.privateKey)
        pending.state = .unknownLedgerGap
        try await fixture.storage.save(pending)

        let reopened = try fixture.reopen()
        #expect(try await reopened.unresolved(account: fixture.account) == [pending])
    }

    @Test
    func historyHashIsImmutableAndConflictCannotAdvanceCheckpoint() async throws {
        let fixture = try Fixture()
        let first = record(hash: "A", amount: 1)
        let corrected = record(hash: "A", amount: 2)

        try await fixture.storage.apply(records: [first], checkpoint: 10)
        await #expect(throws: XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")) {
            try await fixture.storage.apply(records: [corrected], checkpoint: 11)
        }

        #expect(try fixture.storage.checkpoint() == 10)
        #expect(try fixture.storage.history(limit: 20) == [first])
    }

    @Test
    func stagedHistoryConflictCannotOverwriteCommittedTransactionOrCheckpoint() async throws {
        let fixture = try Fixture()
        let first = record(hash: "A", amount: 1)
        let corrected = record(hash: "A", amount: 2)
        try await fixture.storage.apply(records: [first], checkpoint: 10)

        try await fixture.storage.beginStaging(session: "conflict")
        try await fixture.storage.stage(records: [corrected], session: "conflict")
        await #expect(throws: XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")) {
            try await fixture.storage.commitStaged(session: "conflict", checkpoint: 11)
        }

        #expect(try fixture.storage.checkpoint() == 10)
        #expect(try fixture.storage.history(limit: 20) == [first])
    }

    @Test
    func stagingRejectsChangedDuplicateHashWithinSameSync() async throws {
        let fixture = try Fixture()
        let first = record(hash: "A", amount: 1)
        try await fixture.storage.beginStaging(session: "duplicate")
        try await fixture.storage.stage(records: [first], session: "duplicate")

        await #expect(throws: XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")) {
            try await fixture.storage.stage(records: [record(hash: "A", amount: 2)], session: "duplicate")
        }

        try await fixture.storage.commitStaged(session: "duplicate", checkpoint: 10)
        #expect(try fixture.storage.history(limit: 20) == [first])
    }

    @Test
    func historyCursorDoesNotSkipTransactionsSharingBoundaryLedger() async throws {
        let fixture = try Fixture()
        let records = [
            record(hash: "D", amount: 4, ledger: 11),
            record(hash: "C", amount: 3, ledger: 10),
            record(hash: "B", amount: 2, ledger: 10),
            record(hash: "A", amount: 1, ledger: 10),
        ]
        try await fixture.storage.apply(records: records, checkpoint: 11)

        let firstPage = try fixture.storage.history(before: nil, limit: 2)
        let cursor = try #require(firstPage.last).cursor
        let serializedCursor = cursor.rawValue
        let restoredCursor = try #require(XrpHistoryCursor(rawValue: serializedCursor))
        let secondPage = try fixture.storage.history(before: restoredCursor, limit: 2)

        #expect(firstPage.map(\.hash) == [historyHash("D"), historyHash("C")])
        #expect(secondPage.map(\.hash) == [historyHash("B"), historyHash("A")])
        #expect(restoredCursor == cursor)
        #expect(XrpHistoryCursor(rawValue: serializedCursor + "=") == nil)
        #expect(XrpHistoryCursor(rawValue: "not-a-cursor") == nil)
    }

    @Test
    func accountScopedClearCannotDeleteAnotherWalletHistory() async throws {
        let fixture = try Fixture()
        let other = XrpStorage(dbPool: fixture.pool, account: "rOther")
        try await fixture.storage.apply(records: [record(hash: "A", amount: 1)], checkpoint: 10)
        try await other.apply(records: [record(hash: "B", amount: 2)], checkpoint: 12)

        try fixture.storage.clear()

        #expect(try fixture.storage.history(limit: 20).isEmpty)
        #expect(try other.history(limit: 20).map(\.hash) == [historyHash("B")])
        #expect(try other.checkpoint() == 12)
    }

    @Test
    func globalCleanupDeletesOnlyAccountsOutsideKeepSet() async throws {
        let fixture = try Fixture()
        let keptPrivateKey = testPrivateKey(2)
        let keptAccount = try classicAccount(privateKey: keptPrivateKey)
        let kept = XrpStorage(dbPool: fixture.pool, account: keptAccount)
        try await fixture.storage.apply(records: [record(hash: "DELETE", amount: 1)], checkpoint: 10)
        try await kept.apply(records: [record(hash: "KEEP", amount: 2)], checkpoint: 12)
        let removedPending = try signedPending(privateKey: fixture.privateKey)
        let keptPending = try signedPending(privateKey: keptPrivateKey)
        try await fixture.storage.save(removedPending)
        try await kept.save(keptPending)

        try XrpStorage.clear(dbPool: fixture.pool, exceptAccounts: [keptAccount])

        #expect(try fixture.storage.history(limit: 20).isEmpty)
        #expect(try fixture.storage.checkpoint() == nil)
        #expect(try await fixture.storage.unresolved(account: fixture.account).isEmpty)
        #expect(try kept.history(limit: 20).map(\.hash) == [historyHash("KEEP")])
        #expect(try kept.checkpoint() == 12)
        #expect(try await kept.unresolved(account: keptAccount).map(\.hash) == [keptPending.hash])
    }

    @Test
    func durablePendingRejectsTamperedHashBlobAndSignedMetadata() async throws {
        let fixture = try Fixture()
        let pending = try signedPending(privateKey: fixture.privateKey)
        let replacementNibble = pending.blobHex.last == "0" ? "1" : "0"
        let tamperedBlobHex = String(pending.blobHex.dropLast()) + replacementNibble

        await #expect(throws: (any Error).self) {
            try await fixture.storage.save(pending.replacing(hash: String(repeating: "A", count: 64)))
        }
        await #expect(throws: (any Error).self) {
            try await fixture.storage.save(pending.replacing(blobHex: tamperedBlobHex))
        }
        await #expect(throws: (any Error).self) {
            try await fixture.storage.save(pending.replacing(sequence: pending.sequence + 1))
        }
        await #expect(throws: (any Error).self) {
            try await fixture.storage.save(pending.replacing(preparedLedger: pending.preparedLedger - 1))
        }
    }

    @Test
    func storageAllowsOnlyOneUnresolvedPaymentPerAccount() async throws {
        let fixture = try Fixture()
        let first = try signedPending(privateKey: fixture.privateKey, amountDrops: 1)
        let second = try signedPending(privateKey: fixture.privateKey, amountDrops: 2)

        try await fixture.storage.save(first)
        await #expect(throws: XrpRuntimeError.pendingTransactionExists) {
            try await fixture.storage.save(second)
        }
        #expect(try await fixture.storage.unresolved(account: fixture.account) == [first])
    }

    @Test
    func sequenceConflictSurvivesReopenBlocksReplacementAndRequiresAcknowledgement() async throws {
        let fixture = try Fixture()
        var conflict = try signedPending(privateKey: fixture.privateKey, amountDrops: 1)
        conflict.state = .sequenceConflict
        try await fixture.storage.save(conflict)

        let reopened = try fixture.reopen()
        #expect(try reopened.latestSubmission() == conflict)
        #expect(try reopened.blockingSubmission() == conflict)

        let replacement = try signedPending(privateKey: fixture.privateKey, amountDrops: 2)
        await #expect(throws: XrpRuntimeError.pendingTransactionExists) {
            try await reopened.save(replacement)
        }

        try reopened.acknowledgeSubmission(hash: conflict.hash)
        #expect(try reopened.latestSubmission() == nil)
        #expect(try reopened.blockingSubmission() == nil)
    }
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL
    let pool: DatabasePool
    let storage: XrpStorage
    let privateKey: Data
    let account: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("xrp.sqlite")
        pool = try DatabasePool(path: databaseURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        privateKey = testPrivateKey(1)
        account = try classicAccount(privateKey: privateKey)
        storage = XrpStorage(dbPool: pool, account: account)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reopen() throws -> XrpStorage {
        try pool.close()
        let reopenedPool = try DatabasePool(path: databaseURL.path)
        return XrpStorage(dbPool: reopenedPool, account: account)
    }
}

private func record(hash: String, amount: UInt64, ledger: UInt32 = 10) -> XrpHistoryRecord {
    XrpHistoryRecord(
        hash: historyHash(hash), ledgerIndex: ledger, timestamp: 1, direction: .incoming, amountDrops: amount,
        feeDrops: 10, counterparty: "rCounterparty", destinationTag: 0, resultCode: "tesSUCCESS", memo: nil
    )
}

private func historyHash(_ label: String) -> String {
    if label.utf8.count == 64,
       label.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0) })
    {
        return label
    }
    let encoded = Data(label.utf8).map { String(format: "%02X", $0) }.joined()
    precondition(encoded.count <= 64)
    return String(repeating: "0", count: 64 - encoded.count) + encoded
}

private func testPrivateKey(_ scalar: UInt8) -> Data {
    Data(repeating: 0, count: 31) + Data([scalar])
}

private func classicAccount(privateKey: Data) throws -> String {
    try XrpAddressCodec.classicAddress(
        publicKey: XrpKeyDerivation.compressedPublicKey(privateKey: privateKey)
    )
}

private func signedPending(privateKey: Data, amountDrops: UInt64 = 100) throws -> XrpPendingTransaction {
    let payment = XrpNativePayment(
        account: try classicAccount(privateKey: privateKey),
        destination: XrpDestination(
            classicAddress: "r3AgF9mMBFtaLhKcg96weMhbbEFLZ3mx17",
            destinationTag: nil
        ),
        amountDrops: amountDrops,
        feeDrops: 12,
        sequence: 1,
        lastLedgerSequence: 104,
        memo: nil
    )
    let signed = try XrpPaymentCodec.sign(transaction: payment, privateKey: privateKey)
    return XrpPendingTransaction(
        account: payment.account,
        hash: signed.transactionHash.hexUppercased,
        blobHex: signed.blob.hexUppercased,
        sequence: payment.sequence,
        lastLedgerSequence: payment.lastLedgerSequence,
        preparedLedger: 100,
        state: .pending
    )
}

private extension XrpPendingTransaction {
    func replacing(
        hash: String? = nil,
        blobHex: String? = nil,
        sequence: UInt32? = nil,
        preparedLedger: UInt32? = nil
    ) -> Self {
        .init(
            account: account,
            hash: hash ?? self.hash,
            blobHex: blobHex ?? self.blobHex,
            sequence: sequence ?? self.sequence,
            lastLedgerSequence: lastLedgerSequence,
            preparedLedger: preparedLedger ?? self.preparedLedger,
            state: state
        )
    }
}

private extension Data {
    var hexUppercased: String { map { String(format: "%02X", $0) }.joined() }
}
