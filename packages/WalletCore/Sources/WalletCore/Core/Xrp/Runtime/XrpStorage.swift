import Foundation
import GRDB

struct XrpHistoryCursor: RawRepresentable, Equatable, Sendable {
    fileprivate let ledgerIndex: UInt32
    fileprivate let hash: String

    fileprivate init(ledgerIndex: UInt32, hash: String) {
        self.ledgerIndex = ledgerIndex
        self.hash = hash
    }

    var rawValue: String {
        var payload = Data([
            UInt8(truncatingIfNeeded: ledgerIndex >> 24),
            UInt8(truncatingIfNeeded: ledgerIndex >> 16),
            UInt8(truncatingIfNeeded: ledgerIndex >> 8),
            UInt8(truncatingIfNeeded: ledgerIndex),
        ])
        payload.append(Data(hash.utf8))
        return payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(rawValue: String) {
        var base64 = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let payload = Data(base64Encoded: base64),
              payload.count == 68
        else {
            return nil
        }

        let bytes = [UInt8](payload.prefix(4))
        let ledgerIndex = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        guard let hash = String(data: payload.dropFirst(4), encoding: .utf8),
              Self.isValid(ledgerIndex: ledgerIndex, hash: hash)
        else {
            return nil
        }

        self.ledgerIndex = ledgerIndex
        self.hash = hash
        guard self.rawValue == rawValue else { return nil }
    }

    fileprivate static func isValid(ledgerIndex: UInt32, hash: String) -> Bool {
        guard ledgerIndex > 0,
              hash.utf8.count == 64
        else {
            return false
        }
        return hash.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0)
                || (0x41 ... 0x46).contains($0)
        }
    }
}

extension XrpHistoryRecord {
    var cursor: XrpHistoryCursor {
        XrpHistoryCursor(ledgerIndex: ledgerIndex, hash: hash)
    }
}

final class XrpStorage: @unchecked Sendable {
    private enum Table {
        static let pending = "xrpPendingTransaction"
        static let history = "xrpHistoryRecord"
        static let historyStaging = "xrpHistoryRecordStaging"
        static let syncState = "xrpSyncState"
    }

    private let dbPool: DatabasePool
    private let account: String

    init(dbPool: DatabasePool, account: String) {
        self.dbPool = dbPool
        self.account = account
    }

    static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create XRP runtime storage") { db in
            try db.create(table: Table.pending) { table in
                table.column("account", .text).notNull()
                table.column("hash", .text).notNull()
                table.column("blobHex", .text).notNull()
                table.column("sequence", .integer).notNull()
                table.column("lastLedgerSequence", .integer).notNull()
                table.column("preparedLedger", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("failureCode", .text)
                table.column("finalLedger", .integer)
                table.primaryKey(["account", "hash"])
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX xrpPendingTransaction_oneUnresolvedPerAccount
                ON \(Table.pending)(account)
                WHERE state IN ('pending', 'unknownLedgerGap', 'sequenceConflict')
                """)

            try db.create(table: Table.history) { table in
                table.column("account", .text).notNull()
                table.column("hash", .text).notNull()
                table.column("ledgerIndex", .integer).notNull()
                table.column("timestamp", .double).notNull()
                table.column("direction", .text).notNull()
                table.column("amountDrops", .integer).notNull()
                table.column("feeDrops", .integer).notNull()
                table.column("counterparty", .text).notNull()
                table.column("destinationTag", .integer)
                table.column("resultCode", .text).notNull()
                table.column("memo", .blob)
                table.primaryKey(["account", "hash"], onConflict: .replace)
            }
            try db.create(
                index: "xrpHistoryRecordAccountLedger",
                on: Table.history,
                columns: ["account", "ledgerIndex", "hash"]
            )

            try createHistoryStagingTable(db: db)

            try db.create(table: Table.syncState) { table in
                table.column("account", .text).primaryKey(onConflict: .replace)
                table.column("checkpoint", .integer).notNull()
            }
        }
        migrator.registerMigration("Enforce one blocking XRP payment per account") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS xrpPendingTransaction_oneUnresolvedPerAccount")
            try db.execute(sql: """
                CREATE UNIQUE INDEX xrpPendingTransaction_oneUnresolvedPerAccount
                ON \(Table.pending)(account)
                WHERE state IN ('pending', 'unknownLedgerGap', 'sequenceConflict')
                """)
        }
        migrator.registerMigration("Create XRP history staging") { db in
            try createHistoryStagingTable(db: db, ifNotExists: true)
        }
    }

    static func clear(dbPool: DatabasePool, exceptAccounts: Set<String>) throws {
        try dbPool.write { db in
            let storedAccounts = try String.fetchAll(
                db,
                sql: """
                SELECT account FROM \(Table.pending)
                UNION SELECT account FROM \(Table.history)
                UNION SELECT account FROM \(Table.historyStaging)
                UNION SELECT account FROM \(Table.syncState)
                """
            )

            for storedAccount in storedAccounts where !exceptAccounts.contains(storedAccount) {
                try db.execute(sql: "DELETE FROM \(Table.pending) WHERE account = ?", arguments: [storedAccount])
                try db.execute(sql: "DELETE FROM \(Table.history) WHERE account = ?", arguments: [storedAccount])
                try db.execute(sql: "DELETE FROM \(Table.historyStaging) WHERE account = ?", arguments: [storedAccount])
                try db.execute(sql: "DELETE FROM \(Table.syncState) WHERE account = ?", arguments: [storedAccount])
            }
        }
    }

    func checkpoint() throws -> UInt32? {
        try dbPool.read { db in
            guard let value: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT checkpoint FROM \(Table.syncState) WHERE account = ?",
                arguments: [self.account]
            ) else { return nil }
            return try Self.uint32(value, field: "checkpoint")
        }
    }

    func history(before cursor: XrpHistoryCursor? = nil, limit: Int) throws -> [XrpHistoryRecord] {
        guard limit > 0 else { return [] }
        return try dbPool.read { db in
            var sql = "SELECT * FROM \(Table.history) WHERE account = ?"
            var arguments: StatementArguments = [account]
            if let cursor {
                sql += " AND (ledgerIndex < ? OR (ledgerIndex = ? AND hash < ?))"
                arguments += [Int64(cursor.ledgerIndex), Int64(cursor.ledgerIndex), cursor.hash]
            }
            sql += " ORDER BY ledgerIndex DESC, hash DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.historyRecord)
        }
    }

    func clear() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM \(Table.pending) WHERE account = ?", arguments: [account])
            try db.execute(sql: "DELETE FROM \(Table.history) WHERE account = ?", arguments: [account])
            try db.execute(sql: "DELETE FROM \(Table.historyStaging) WHERE account = ?", arguments: [account])
            try db.execute(sql: "DELETE FROM \(Table.syncState) WHERE account = ?", arguments: [account])
        }
    }
}

extension XrpStorage: IXrpPendingTransactionStore {
    func save(_ transaction: XrpPendingTransaction) async throws {
        guard transaction.account == account else {
            throw XrpRuntimeError.invalidResponse("XRP pending transaction belongs to another account")
        }
        try transaction.validateDurableCommitment()
        let encoded = Self.encode(state: transaction.state)
        try await dbPool.write { db in
            if transaction.blocksNewPayment,
               try String.fetchOne(
                   db,
                   sql: "SELECT hash FROM \(Table.pending) WHERE account = ? AND state IN (?, ?, ?) AND hash != ? LIMIT 1",
                   arguments: [self.account, "pending", "unknownLedgerGap", "sequenceConflict", transaction.hash]
               ) != nil
            {
                throw XrpRuntimeError.pendingTransactionExists
            }
            try db.execute(
                sql: """
                INSERT INTO \(Table.pending)
                (account, hash, blobHex, sequence, lastLedgerSequence, preparedLedger, state, failureCode, finalLedger)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account, hash) DO UPDATE SET
                    blobHex = excluded.blobHex,
                    sequence = excluded.sequence,
                    lastLedgerSequence = excluded.lastLedgerSequence,
                    preparedLedger = excluded.preparedLedger,
                    state = excluded.state,
                    failureCode = excluded.failureCode,
                    finalLedger = excluded.finalLedger
                """,
                arguments: [
                    transaction.account, transaction.hash, transaction.blobHex,
                    Int64(transaction.sequence), Int64(transaction.lastLedgerSequence), Int64(transaction.preparedLedger),
                    encoded.name, encoded.failureCode, encoded.finalLedger.map { Int64($0) },
                ]
            )
        }
    }

    func unresolved(account: String) async throws -> [XrpPendingTransaction] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(Table.pending) WHERE account = ? AND state IN (?, ?) ORDER BY preparedLedger, hash",
                arguments: [account, "pending", "unknownLedgerGap"]
            ).map(Self.pendingTransaction)
        }
    }

    func blockingSubmission() throws -> XrpPendingTransaction? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM \(Table.pending) WHERE account = ? AND state IN (?, ?, ?) ORDER BY preparedLedger DESC, hash DESC LIMIT 1",
                arguments: [account, "pending", "unknownLedgerGap", "sequenceConflict"]
            ).map(Self.pendingTransaction)
        }
    }

    func latestSubmission() throws -> XrpPendingTransaction? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM \(Table.pending) WHERE account = ? ORDER BY preparedLedger DESC, hash DESC LIMIT 1",
                arguments: [self.account]
            ).map(Self.pendingTransaction)
        }
    }

    func acknowledgeSubmission(hash: String) throws {
        try dbPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM \(Table.pending) WHERE account = ? AND hash = ?",
                arguments: [account, hash]
            ) else { throw XrpRuntimeError.invalidResponse("XRP submission status is unavailable") }
            let transaction = try Self.pendingTransaction(row)
            switch transaction.state {
            case .pending, .unknownLedgerGap:
                throw XrpRuntimeError.pendingTransactionExists
            case .validatedSuccess, .validatedFailure, .expired, .sequenceConflict:
                try db.execute(
                    sql: "DELETE FROM \(Table.pending) WHERE account = ? AND hash = ?",
                    arguments: [account, hash]
                )
            }
        }
    }
}

extension XrpStorage: IXrpHistoryStore {
    func beginStaging(session: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM \(Table.historyStaging) WHERE account = ?",
                arguments: [self.account]
            )
        }
    }

    func stage(records: [XrpHistoryRecord], session: String) async throws {
        try await dbPool.write { db in
            for record in records {
                guard XrpHistoryCursor.isValid(ledgerIndex: record.ledgerIndex, hash: record.hash) else {
                    throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor boundary")
                }
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM \(Table.historyStaging) WHERE account = ? AND session = ? AND hash = ?",
                    arguments: [self.account, session, record.hash]
                ) {
                    guard try Self.historyRecord(existing) == record else {
                        throw XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")
                    }
                    continue
                }
                try db.execute(
                    sql: """
                    INSERT OR ABORT INTO \(Table.historyStaging)
                    (account, session, hash, ledgerIndex, timestamp, direction, amountDrops, feeDrops, counterparty, destinationTag, resultCode, memo)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        self.account, session, record.hash, Int64(record.ledgerIndex), record.timestamp, record.direction.rawValue,
                        try Self.int64(record.amountDrops, field: "amountDrops"),
                        try Self.int64(record.feeDrops, field: "feeDrops"), record.counterparty,
                        record.destinationTag.map { Int64($0) }, record.resultCode, record.memo,
                    ]
                )
            }
        }
    }

    func commitStaged(session: String, checkpoint: UInt32) async throws {
        try await dbPool.write { db in
            let hasConflict = try Int.fetchOne(
                db,
                sql: """
                SELECT 1
                FROM \(Table.historyStaging) AS staged
                JOIN \(Table.history) AS committed
                  ON committed.account = staged.account AND committed.hash = staged.hash
                WHERE staged.account = ? AND staged.session = ?
                  AND NOT (
                    committed.ledgerIndex IS staged.ledgerIndex
                    AND committed.timestamp IS staged.timestamp
                    AND committed.direction IS staged.direction
                    AND committed.amountDrops IS staged.amountDrops
                    AND committed.feeDrops IS staged.feeDrops
                    AND committed.counterparty IS staged.counterparty
                    AND committed.destinationTag IS staged.destinationTag
                    AND committed.resultCode IS staged.resultCode
                    AND committed.memo IS staged.memo
                  )
                LIMIT 1
                """,
                arguments: [self.account, session]
            ) != nil
            guard !hasConflict else {
                throw XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")
            }
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO \(Table.history)
                    (account, hash, ledgerIndex, timestamp, direction, amountDrops, feeDrops, counterparty, destinationTag, resultCode, memo)
                SELECT account, hash, ledgerIndex, timestamp, direction, amountDrops, feeDrops, counterparty, destinationTag, resultCode, memo
                FROM \(Table.historyStaging)
                WHERE account = ? AND session = ?
                """,
                arguments: [self.account, session]
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO \(Table.syncState) (account, checkpoint) VALUES (?, ?)",
                arguments: [self.account, Int64(checkpoint)]
            )
            try db.execute(
                sql: "DELETE FROM \(Table.historyStaging) WHERE account = ? AND session = ?",
                arguments: [self.account, session]
            )
        }
    }

    func discardStaged(session: String) async {
        try? await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM \(Table.historyStaging) WHERE account = ? AND session = ?",
                arguments: [self.account, session]
            )
        }
    }

    func apply(records: [XrpHistoryRecord], checkpoint: UInt32) async throws {
        try await dbPool.write { db in
            for record in records {
                guard XrpHistoryCursor.isValid(ledgerIndex: record.ledgerIndex, hash: record.hash) else {
                    throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor boundary")
                }
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM \(Table.history) WHERE account = ? AND hash = ?",
                    arguments: [self.account, record.hash]
                ) {
                    guard try Self.historyRecord(existing) == record else {
                        throw XrpRuntimeError.invalidResponse("Conflicting XRP history transaction")
                    }
                    continue
                }
                try db.execute(
                    sql: """
                    INSERT OR ABORT INTO \(Table.history)
                    (account, hash, ledgerIndex, timestamp, direction, amountDrops, feeDrops, counterparty, destinationTag, resultCode, memo)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        self.account, record.hash, Int64(record.ledgerIndex), record.timestamp, record.direction.rawValue,
                        try Self.int64(record.amountDrops, field: "amountDrops"),
                        try Self.int64(record.feeDrops, field: "feeDrops"), record.counterparty,
                        record.destinationTag.map { Int64($0) }, record.resultCode, record.memo,
                    ]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO \(Table.syncState) (account, checkpoint) VALUES (?, ?)",
                arguments: [self.account, Int64(checkpoint)]
            )
        }
    }
}

private extension XrpStorage {
    static func createHistoryStagingTable(db: Database, ifNotExists: Bool = false) throws {
        let clause = ifNotExists ? "IF NOT EXISTS " : ""
        try db.execute(sql: """
            CREATE TABLE \(clause)\(Table.historyStaging) (
                account TEXT NOT NULL,
                session TEXT NOT NULL,
                hash TEXT NOT NULL,
                ledgerIndex INTEGER NOT NULL,
                timestamp DOUBLE NOT NULL,
                direction TEXT NOT NULL,
                amountDrops INTEGER NOT NULL,
                feeDrops INTEGER NOT NULL,
                counterparty TEXT NOT NULL,
                destinationTag INTEGER,
                resultCode TEXT NOT NULL,
                memo BLOB,
                PRIMARY KEY (account, session, hash) ON CONFLICT REPLACE
            )
            """)
    }

    static func encode(state: XrpPendingTransaction.State) -> (name: String, failureCode: String?, finalLedger: UInt32?) {
        switch state {
        case .pending: return ("pending", nil, nil)
        case let .validatedSuccess(ledger): return ("validatedSuccess", nil, ledger)
        case let .validatedFailure(code, ledger): return ("validatedFailure", code, ledger)
        case .expired: return ("expired", nil, nil)
        case .sequenceConflict: return ("sequenceConflict", nil, nil)
        case .unknownLedgerGap: return ("unknownLedgerGap", nil, nil)
        }
    }

    static func decode(state: String, failureCode: String?, finalLedger: Int64?) throws -> XrpPendingTransaction.State {
        switch state {
        case "pending": return .pending
        case "validatedSuccess": return .validatedSuccess(ledger: try uint32(finalLedger, field: "finalLedger"))
        case "validatedFailure":
            guard let failureCode else { throw XrpRuntimeError.invalidResponse("Missing XRP failure code") }
            return .validatedFailure(code: failureCode, ledger: try uint32(finalLedger, field: "finalLedger"))
        case "expired": return .expired
        case "sequenceConflict": return .sequenceConflict
        case "unknownLedgerGap": return .unknownLedgerGap
        default: throw XrpRuntimeError.invalidResponse("Unknown XRP pending state")
        }
    }

    static func pendingTransaction(_ row: Row) throws -> XrpPendingTransaction {
        let finalLedger: Int64? = row["finalLedger"]
        let transaction = XrpPendingTransaction(
            account: row["account"], hash: row["hash"], blobHex: row["blobHex"],
            sequence: try uint32(row["sequence"] as Int64, field: "sequence"),
            lastLedgerSequence: try uint32(row["lastLedgerSequence"] as Int64, field: "lastLedgerSequence"),
            preparedLedger: try uint32(row["preparedLedger"] as Int64, field: "preparedLedger"),
            state: try decode(state: row["state"], failureCode: row["failureCode"], finalLedger: finalLedger)
        )
        try transaction.validateDurableCommitment()
        return transaction
    }

    static func historyRecord(_ row: Row) throws -> XrpHistoryRecord {
        guard let direction = XrpHistoryRecord.Direction(rawValue: row["direction"]) else {
            throw XrpRuntimeError.invalidResponse("Unknown XRP history direction")
        }
        let destinationTag: Int64? = row["destinationTag"]
        let hash: String = row["hash"]
        let ledgerIndex = try uint32(row["ledgerIndex"] as Int64, field: "ledgerIndex")
        guard XrpHistoryCursor.isValid(ledgerIndex: ledgerIndex, hash: hash) else {
            throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor boundary")
        }
        return XrpHistoryRecord(
            hash: hash, ledgerIndex: ledgerIndex,
            timestamp: row["timestamp"], direction: direction,
            amountDrops: try uint64(row["amountDrops"] as Int64, field: "amountDrops"),
            feeDrops: try uint64(row["feeDrops"] as Int64, field: "feeDrops"), counterparty: row["counterparty"],
            destinationTag: try destinationTag.map { try uint32($0, field: "destinationTag") },
            resultCode: row["resultCode"], memo: row["memo"]
        )
    }

    static func int64(_ value: UInt64, field: String) throws -> Int64 {
        guard let value = Int64(exactly: value) else { throw XrpRuntimeError.invalidResponse("Invalid \(field)") }
        return value
    }

    static func uint64(_ value: Int64, field: String) throws -> UInt64 {
        guard let value = UInt64(exactly: value) else { throw XrpRuntimeError.invalidResponse("Invalid \(field)") }
        return value
    }

    static func uint32(_ value: Int64?, field: String) throws -> UInt32 {
        guard let value, let result = UInt32(exactly: value) else { throw XrpRuntimeError.invalidResponse("Invalid \(field)") }
        return result
    }
}
