import Foundation

struct XrpPendingTransaction: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case pending
        case validatedSuccess(ledger: UInt32)
        case validatedFailure(code: String, ledger: UInt32)
        case expired
        case sequenceConflict
        case unknownLedgerGap
    }

    let account: String
    let hash: String
    let blobHex: String
    let sequence: UInt32
    let lastLedgerSequence: UInt32
    let preparedLedger: UInt32
    var state: State
}

extension XrpPendingTransaction {
    var blocksNewPayment: Bool {
        switch state {
        case .pending, .unknownLedgerGap, .sequenceConflict: return true
        case .validatedSuccess, .validatedFailure, .expired: return false
        }
    }

    var attentionMessage: String? {
        switch state {
        case .pending: return nil
        case .unknownLedgerGap: return "The previous XRP payment cannot be finalized until a continuous ledger source is available."
        case let .validatedFailure(code, _): return "The previous XRP payment failed with ledger result \(code)."
        case .expired: return "The previous XRP payment expired without validation."
        case .sequenceConflict: return "The XRP account sequence changed before the previous payment could be finalized. Review it before sending again."
        case .validatedSuccess: return nil
        }
    }

    var canAcknowledge: Bool {
        switch state {
        case .validatedSuccess, .validatedFailure, .expired, .sequenceConflict: return true
        case .pending, .unknownLedgerGap: return false
        }
    }

    @discardableResult
    func validateDurableCommitment() throws -> XrpNativePayment {
        guard hash.count == 64,
              hash.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0) }),
              !blobHex.isEmpty,
              blobHex.count <= 4_096,
              let blob = Data(xrpCanonicalHex: blobHex)
        else { throw XrpRuntimeError.invalidResponse("Invalid durable XRP transaction") }

        let payment = try XrpPaymentCodec.decodeSigned(blob)
        let committedHash = XrpPaymentCodec.transactionHash(blob: blob).xrpHexUppercased
        let (expectedLastLedger, overflow) = preparedLedger.addingReportingOverflow(
            XrpPaymentPreflight.defaultLastLedgerOffset
        )
        guard !overflow,
              committedHash == hash,
              payment.account == account,
              payment.sequence == sequence,
              payment.lastLedgerSequence == lastLedgerSequence,
              expectedLastLedger == lastLedgerSequence
        else { throw XrpRuntimeError.invalidResponse("Invalid durable XRP transaction") }

        switch state {
        case let .validatedSuccess(ledger), let .validatedFailure(_, ledger):
            guard (preparedLedger ... lastLedgerSequence).contains(ledger) else {
                throw XrpRuntimeError.invalidResponse("Invalid durable XRP transaction")
            }
        case .pending, .expired, .sequenceConflict, .unknownLedgerGap:
            break
        }
        return payment
    }
}

protocol IXrpPendingTransactionStore: Sendable {
    func save(_ transaction: XrpPendingTransaction) async throws
    /// Returns every transaction that still needs reconciliation. This includes
    /// ledger-gap rows: a later endpoint may have the missing continuous range.
    func unresolved(account: String) async throws -> [XrpPendingTransaction]
}

actor XrpReliableSubmission {
    private let rpc: IXrpRpcClient
    private let store: IXrpPendingTransactionStore

    init(rpc: IXrpRpcClient, store: IXrpPendingTransactionStore) {
        self.rpc = rpc
        self.store = store
    }

    /// Durably records the exact hash/blob before the first network side effect. A timeout
    /// deliberately leaves the row pending; callers must retry this same blob, never rebuild.
    @discardableResult
    func persistAndSubmit(_ transaction: XrpPendingTransaction) async throws -> String {
        guard transaction.state == .pending else { return transaction.hash }
        try transaction.validateDurableCommitment()
        try await store.save(transaction)
        do {
            _ = try await rpc.submit(blobHex: transaction.blobHex)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Submission is deliberately treated as ambiguous. The exact signed
            // blob is already durable and reconciliation decides finality.
        }
        return transaction.hash
    }

    @discardableResult
    func resubmitSameBlob(hash: String, account: String) async throws -> String {
        guard let transaction = try await store.unresolved(account: account).first(where: { $0.hash == hash }) else {
            throw XrpRuntimeError.invalidResponse("Pending XRP transaction is unavailable")
        }
        try transaction.validateDurableCommitment()
        _ = try await rpc.submit(blobHex: transaction.blobHex)
        return transaction.hash
    }

    func reconcile(account: String) async throws {
        // Pin a validated ledger first, then prove that a subsequently observed
        // server state retains it. This remains coherent across a normal ledger
        // close between the two calls (N followed by N+1).
        let ledger = try await rpc.validatedLedger()
        let server = try await rpc.serverState()
        guard server.networkId == 0 else { throw XrpRuntimeError.wrongNetwork(server.networkId) }
        guard ledger.index <= server.validatedLedger,
              server.completeLedgers.contains(ledger.index ... ledger.index)
        else {
            throw XrpRuntimeError.invalidResponse("XRPL endpoint returned an inconsistent validated ledger")
        }
        for var pending in try await store.unresolved(account: account) {
            try Task.checkCancellation()
            try pending.validateDurableCommitment()
            if let transaction = try await rpc.transaction(hash: pending.hash) {
                guard transaction.hash == pending.hash else {
                    throw XrpRuntimeError.invalidResponse("XRPL transaction lookup hash mismatch")
                }
                if transaction.validated {
                    guard let result = transaction.resultCode,
                          let transactionLedger = transaction.ledgerIndex,
                          transactionLedger <= server.validatedLedger,
                          server.completeLedgers.contains(transactionLedger ... transactionLedger),
                          (pending.preparedLedger ... pending.lastLedgerSequence).contains(transactionLedger)
                    else { throw XrpRuntimeError.invalidResponse("Validated XRP transaction is outside its signed ledger window") }
                    pending.state = result == "tesSUCCESS"
                        ? .validatedSuccess(ledger: transactionLedger)
                        : .validatedFailure(code: result, ledger: transactionLedger)
                    try await store.save(pending)
                    continue
                }
                // An unvalidated/queued lookup is not final. Once the pinned
                // ledger is beyond LastLedgerSequence, continue into the same
                // continuous-window expiry/sequence proof as a lookup miss.
            }

            guard ledger.index > pending.lastLedgerSequence else {
                do {
                    _ = try await rpc.submit(blobHex: pending.blobHex)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // A retry is ambiguous for the same reason as the initial submit.
                    // Reconciliation keeps the exact durable blob pending.
                }
                continue
            }
            guard server.completeLedgers.contains(pending.preparedLedger ... ledger.index) else {
                pending.state = .unknownLedgerGap
                try await store.save(pending)
                continue
            }

            let accountState: XrpAccountState
            do {
                accountState = try await rpc.accountState(address: account, ledger: ledger)
            } catch XrpRuntimeError.accountNotFound {
                // With a continuous ledger window beyond LastLedgerSequence, an
                // absent account means it was deleted. AccountDelete consumes the
                // account sequence, so the signed Payment cannot still validate.
                pending.state = .sequenceConflict
                try await store.save(pending)
                continue
            }
            guard accountState.sequence >= pending.sequence else {
                throw XrpRuntimeError.invalidResponse("XRPL account sequence regressed below the signed transaction")
            }
            pending.state = accountState.sequence > pending.sequence ? .sequenceConflict : .expired
            try await store.save(pending)
        }
    }
}

struct XrpPaymentPreflight: Sendable {
    static let defaultLastLedgerOffset: UInt32 = 4
    let maxFeeDrops: UInt64
    let lastLedgerOffset: UInt32

    init(maxFeeDrops: UInt64 = 100_000, lastLedgerOffset: UInt32 = Self.defaultLastLedgerOffset) {
        self.maxFeeDrops = maxFeeDrops
        self.lastLedgerOffset = lastLedgerOffset
    }

    func fee(_ proposed: UInt64) throws -> UInt64 {
        guard proposed > 0, proposed <= maxFeeDrops else {
            throw XrpRuntimeError.feeExceedsCap(actual: proposed, cap: maxFeeDrops)
        }
        return proposed
    }

    func lastLedgerSequence(validatedLedger: UInt32) throws -> UInt32 {
        let (result, overflow) = validatedLedger.addingReportingOverflow(lastLedgerOffset)
        guard !overflow else { throw XrpRuntimeError.arithmeticOverflow }
        return result
    }

    func validateDestination(state: XrpAccountState?, tag: UInt32?, feeSettings: XrpFeeSettings, amountDrops: UInt64) throws {
        if let state {
            if state.requiresDestinationTag, tag == nil { throw XrpRuntimeError.destinationTagRequired }
        } else if amountDrops < feeSettings.reserveBaseDrops {
            throw XrpRuntimeError.destinationInactive(minimumDrops: feeSettings.reserveBaseDrops)
        }
    }
}

private extension Data {
    init?(xrpCanonicalHex string: String) {
        guard string.count.isMultiple(of: 2),
              string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0) })
        else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var xrpHexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
