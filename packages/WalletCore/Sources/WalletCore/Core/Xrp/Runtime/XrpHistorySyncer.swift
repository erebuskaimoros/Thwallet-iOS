import Foundation

protocol IXrpHistoryStore: Sendable {
    func beginStaging(session: String) async throws
    func stage(records: [XrpHistoryRecord], session: String) async throws
    func commitStaged(session: String, checkpoint: UInt32) async throws
    func discardStaged(session: String) async
}

final class XrpHistorySyncer: @unchecked Sendable {
    private static let rippleEpochOffset: TimeInterval = 946_684_800
    private let rpc: IXrpRpcClient
    private let store: IXrpHistoryStore

    init(rpc: IXrpRpcClient, store: IXrpHistoryStore) {
        self.rpc = rpc
        self.store = store
    }

    func sync(address: String, fromLedger: UInt32, toLedger: UInt32) async throws {
        guard fromLedger <= toLedger else { return }
        let session = UUID().uuidString
        try await store.beginStaging(session: session)
        var marker: XrpJsonValue?
        var seenMarkers = [XrpJsonValue]()
        do {
            repeat {
                try Task.checkCancellation()
                let page = try await rpc.accountTransactions(
                    address: address,
                    fromLedger: fromLedger,
                    toLedger: toLedger,
                    marker: marker
                )
                guard page.ledgerIndexMin == fromLedger, page.ledgerIndexMax == toLedger else {
                    throw XrpRuntimeError.invalidResponse("XRPL account_tx returned a different ledger range")
                }
                var pageRecords = [XrpHistoryRecord]()
                pageRecords.reserveCapacity(page.entries.count)
                for entry in page.entries {
                    let ledger = try Self.ledgerIndex(entry: entry)
                    guard (fromLedger ... toLedger).contains(ledger) else {
                        throw XrpRuntimeError.invalidResponse("XRPL account_tx entry is outside the requested ledger range")
                    }
                    if let record = try Self.record(entry: entry, ownAddress: address) {
                        pageRecords.append(record)
                    }
                }
                try await store.stage(records: pageRecords, session: session)
                if let next = page.marker {
                    guard !seenMarkers.contains(next), seenMarkers.count < 10_000 else {
                        throw XrpRuntimeError.invalidResponse("XRPL account_tx marker cycle")
                    }
                    seenMarkers.append(next)
                }
                marker = page.marker
            } while marker != nil

            // The final store transaction publishes every staged page and advances the
            // checkpoint together. A failed page or crash never exposes a partial range.
            try await store.commitStaged(session: session, checkpoint: toLedger)
        } catch {
            await store.discardStaged(session: session)
            throw error
        }
    }

    static func record(entry: XrpJsonValue, ownAddress: String) throws -> XrpHistoryRecord? {
        guard let wrapper = entry.object,
              wrapper["validated"]?.bool == true,
              let tx = (wrapper["tx_json"] ?? wrapper["tx"])?.object
        else { throw XrpRuntimeError.invalidResponse("Malformed validated XRP transaction") }
        guard tx["TransactionType"]?.string == "Payment" else { return nil }
        let ledger = try ledgerIndex(wrapper: wrapper, transaction: tx)

        let wrapperHash = wrapper["hash"]?.string?.uppercased()
        let transactionHash = tx["hash"]?.string?.uppercased()
        if let wrapperHash, let transactionHash, wrapperHash != transactionHash {
            throw XrpRuntimeError.invalidResponse("XRPL transaction hash commitment mismatch")
        }
        guard let meta = wrapper["meta"]?.object,
              let hash = wrapperHash ?? transactionHash,
              isTransactionHash(hash),
              let source = tx["Account"]?.string,
              let destination = tx["Destination"]?.string,
              let fee = tx["Fee"]?.uint64,
              fee <= XrpAmount.maximumDrops,
              let result = meta["TransactionResult"]?.string,
              let timestamp = timestamp(wrapper: wrapper, transaction: tx)
        else { throw XrpRuntimeError.invalidResponse("Malformed native XRP Payment") }

        let outgoing = source == ownAddress
        let incoming = destination == ownAddress
        guard outgoing || incoming else {
            throw XrpRuntimeError.invalidResponse("XRPL account_tx returned an unrelated transaction")
        }

        let flags = tx["Flags"]?.uint32 ?? 0
        let partialPaymentFlag: UInt32 = 0x0002_0000
        if flags & partialPaymentFlag != 0
            || tx["SendMax"] != nil
            || tx["DeliverMin"] != nil
            || tx["Paths"] != nil
        {
            return nil
        }

        let deliverMaxV2 = tx["DeliverMax"]
        let amountV1 = tx["Amount"]
        guard (deliverMaxV2 == nil) != (amountV1 == nil),
              let deliverMax = deliverMaxV2 ?? amountV1
        else {
            throw XrpRuntimeError.invalidResponse("Malformed native XRP Payment")
        }
        if deliverMax.object != nil { return nil }
        guard let requestedNativeAmount = deliverMax.uint64,
              requestedNativeAmount <= XrpAmount.maximumDrops
        else {
            throw XrpRuntimeError.invalidResponse("Malformed native XRP Payment")
        }

        let amount: UInt64
        if result == "tesSUCCESS" {
            if meta["delivered_amount"]?.object != nil { return nil }
            if let delivered = meta["delivered_amount"], delivered.object == nil,
               let nativeDelivered = delivered.uint64,
               nativeDelivered <= XrpAmount.maximumDrops
            {
                amount = nativeDelivered
            } else if meta["delivered_amount"] == nil
                || meta["delivered_amount"]?.string?.caseInsensitiveCompare("unavailable") == .orderedSame
            {
                // Historical pre-delivered_amount direct Payments are exact after the
                // path/partial fields above have been excluded.
                amount = requestedNativeAmount
            } else {
                throw XrpRuntimeError.invalidResponse("Malformed native XRP Payment")
            }
        } else {
            amount = 0
        }

        let direction: XrpHistoryRecord.Direction = outgoing && incoming ? .selfTransfer : (outgoing ? .outgoing : .incoming)
        let counterparty = outgoing ? destination : source
        let memo = parseMemo(tx["Memos"])
        return XrpHistoryRecord(
            hash: hash,
            ledgerIndex: ledger,
            timestamp: timestamp,
            direction: direction,
            amountDrops: amount,
            feeDrops: fee,
            counterparty: counterparty,
            destinationTag: tx["DestinationTag"]?.uint32,
            resultCode: result,
            memo: memo
        )
    }

    private static func ledgerIndex(entry: XrpJsonValue) throws -> UInt32 {
        guard let wrapper = entry.object,
              let transaction = (wrapper["tx_json"] ?? wrapper["tx"])?.object
        else {
            throw XrpRuntimeError.invalidResponse("Malformed validated XRP transaction")
        }
        return try ledgerIndex(wrapper: wrapper, transaction: transaction)
    }

    private static func ledgerIndex(
        wrapper: [String: XrpJsonValue],
        transaction: [String: XrpJsonValue]
    ) throws -> UInt32 {
        let wrapperValue = wrapper["ledger_index"]
        let transactionValue = transaction["ledger_index"]
        let wrapperLedger = wrapperValue?.uint32
        let transactionLedger = transactionValue?.uint32

        guard wrapperValue == nil || wrapperLedger != nil,
              transactionValue == nil || transactionLedger != nil,
              let ledger = wrapperLedger ?? transactionLedger
        else {
            throw XrpRuntimeError.invalidResponse("Malformed XRP transaction ledger index")
        }
        if let wrapperLedger, let transactionLedger, wrapperLedger != transactionLedger {
            throw XrpRuntimeError.invalidResponse("XRPL transaction ledger commitment mismatch")
        }
        return ledger
    }

    private static func isTransactionHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0)
        }
    }

    private static func timestamp(
        wrapper: [String: XrpJsonValue],
        transaction: [String: XrpJsonValue]
    ) -> TimeInterval? {
        if let iso8601 = wrapper["close_time_iso"]?.string {
            return ISO8601DateFormatter().date(from: iso8601)?.timeIntervalSince1970
        }
        if let rippleDate = (transaction["date"] ?? wrapper["date"])?.uint64 {
            return TimeInterval(rippleDate) + rippleEpochOffset
        }
        return nil
    }

    private static func parseMemo(_ value: XrpJsonValue?) -> Data? {
        guard let first = value?.array?.first?.object?["Memo"]?.object,
              let hex = first["MemoData"]?.string,
              hex.count.isMultiple(of: 2), hex.count <= 512
        else { return nil }
        var output = Data(); output.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< end], radix: 16) else { return nil }
            output.append(byte); index = end
        }
        return output
    }
}
