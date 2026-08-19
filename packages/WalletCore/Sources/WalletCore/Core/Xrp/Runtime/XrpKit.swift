import Combine
import Foundation
import RxSwift

struct XrpKitSnapshot: Equatable, Sendable {
    enum SyncState: Equatable, Sendable {
        case syncing
        case synced
        case notSynced(String)
    }

    let syncState: SyncState
    let balanceDrops: UInt64
    let availableDrops: UInt64
    let validatedLedger: UInt32?
    let submission: XrpPendingTransaction?

    static let initial = XrpKitSnapshot(
        syncState: .syncing,
        balanceDrops: 0,
        availableDrops: 0,
        validatedLedger: nil,
        submission: nil
    )
}

actor XrpEngine {
    private static let firstMainnetLedger: UInt32 = 32_570
    private let address: String
    private let privateKey: Data?
    private let rpc: IXrpRpcClient
    private let storage: XrpStorage
    private let historySyncer: XrpHistorySyncer
    private let submission: XrpReliableSubmission
    private let preflight: XrpPaymentPreflight
    private let nowEpochSeconds: @Sendable () -> Int
    private var sendInFlight = false

    init(
        address: String,
        privateKey: Data?,
        rpc: IXrpRpcClient,
        storage: XrpStorage,
        preflight: XrpPaymentPreflight = .init(),
        nowEpochSeconds: @escaping @Sendable () -> Int = {
            Int(Date().timeIntervalSince1970)
        }
    ) {
        self.address = address
        self.privateKey = privateKey
        self.rpc = rpc
        self.storage = storage
        historySyncer = XrpHistorySyncer(rpc: rpc, store: storage)
        submission = XrpReliableSubmission(rpc: rpc, store: storage)
        self.preflight = preflight
        self.nowEpochSeconds = nowEpochSeconds
    }

    func refresh() async throws -> XrpKitSnapshot {
        let ledger = try await rpc.validatedLedger()
        let server = try await rpc.serverState()
        try Self.validate(server: server, ledger: ledger)
        let feeSettings = try await rpc.feeSettings(ledger: ledger)
        let accountState: XrpAccountState?
        do {
            accountState = try await rpc.accountState(address: address, ledger: ledger)
        } catch XrpRuntimeError.accountNotFound {
            accountState = nil
        }

        try await submission.reconcile(account: address)
        let checkpoint = try storage.checkpoint()
        if let checkpoint, checkpoint > ledger.index {
            throw XrpRuntimeError.invalidResponse("Stored XRP checkpoint is ahead of the validated ledger")
        }
        let start = try checkpoint.map {
            let (next, overflow) = $0.addingReportingOverflow(1)
            guard !overflow else { throw XrpRuntimeError.arithmeticOverflow }
            return next
        } ?? Self.firstMainnetLedger
        if start <= ledger.index {
            guard server.completeLedgers.contains(start ... ledger.index) else {
                throw XrpRuntimeError.invalidResponse("XRPL endpoint does not provide continuous account history")
            }
            // account_tx remains authoritative after AccountDelete, so inactive and
            // watch-only addresses must still synchronize their historical activity.
            try await historySyncer.sync(address: address, fromLedger: start, toLedger: ledger.index)
        }

        let balance = accountState?.balanceDrops ?? 0
        let available = try accountState?.availableDrops(feeSettings: feeSettings) ?? 0
        return XrpKitSnapshot(
            syncState: .synced,
            balanceDrops: balance,
            availableDrops: available,
            validatedLedger: ledger.index,
            submission: try storage.latestSubmission()
        )
    }

    func sendInfo(
        destination rawDestination: String,
        separateTag: UInt32?,
        amountDrops: UInt64,
        memo: Data?,
        minimumFeeDrops: UInt64? = nil
    ) async throws -> XrpSendInfo {
        if let blocking = try storage.blockingSubmission() {
            if let message = blocking.attentionMessage {
                throw XrpRuntimeError.submissionRequiresAttention(message)
            }
            throw XrpRuntimeError.pendingTransactionExists
        }
        if let memo, memo.count > 256 { throw XrpRuntimeError.memoTooLarge }

        let ledger = try await rpc.validatedLedger()
        let server = try await rpc.serverState()
        try Self.validate(server: server, ledger: ledger)
        let feeSettings = try await rpc.feeSettings(ledger: ledger)
        let sender = try await rpc.accountState(address: address, ledger: ledger)
        let destination = try XrpAddressCodec.resolve(rawDestination, separateTag: separateTag, network: .mainnet)
        let destinationState: XrpAccountState?
        do {
            destinationState = try await rpc.accountState(address: destination.classicAddress, ledger: ledger)
        } catch XrpRuntimeError.accountNotFound {
            destinationState = nil
        }

        let liveFee = try await rpc.openLedgerFeeDrops()
        if let minimumFeeDrops { _ = try preflight.fee(minimumFeeDrops) }
        let fee = try preflight.fee(max(feeSettings.baseFeeDrops, liveFee, minimumFeeDrops ?? 0))
        try preflight.validateDestination(state: destinationState, tag: destination.destinationTag, feeSettings: feeSettings, amountDrops: amountDrops)
        let (total, overflow) = amountDrops.addingReportingOverflow(fee)
        guard !overflow else { throw XrpRuntimeError.arithmeticOverflow }
        let available = try sender.availableDrops(feeSettings: feeSettings)
        guard total <= available else { throw XrpRuntimeError.insufficientBalance }

        let lastLedgerSequence = try preflight.lastLedgerSequence(validatedLedger: ledger.index)
        return XrpSendInfo(
            destination: destination,
            amountDrops: amountDrops,
            feeDrops: fee,
            availableBalanceDrops: available,
            sequence: sender.sequence,
            validatedLedger: ledger.index,
            lastLedgerSequence: lastLedgerSequence
        )
    }

    func prepareAndSubmit(
        destination rawDestination: String,
        separateTag: UInt32?,
        amountDrops: UInt64,
        memo: Data?,
        minimumFeeDrops: UInt64? = nil,
        maximumFeeDrops: UInt64? = nil,
        validUntilEpochSeconds: Int? = nil
    ) async throws -> String {
        guard !sendInFlight else { throw XrpRuntimeError.pendingTransactionExists }
        sendInFlight = true
        defer { sendInFlight = false }
        guard let privateKey else { throw XrpRuntimeError.signerUnavailable }
        let info = try await sendInfo(
            destination: rawDestination,
            separateTag: separateTag,
            amountDrops: amountDrops,
            memo: memo,
            minimumFeeDrops: minimumFeeDrops
        )
        if let maximumFeeDrops {
            _ = try preflight.fee(maximumFeeDrops)
            guard info.feeDrops <= maximumFeeDrops else {
                throw XrpRuntimeError.feeExceedsApproved(
                    actual: info.feeDrops,
                    approved: maximumFeeDrops
                )
            }
        }
        let payment = XrpNativePayment(
            account: address,
            destination: info.destination,
            amountDrops: info.amountDrops,
            feeDrops: info.feeDrops,
            sequence: info.sequence,
            lastLedgerSequence: info.lastLedgerSequence,
            memo: memo
        )
        try validateQuoteExpiry(validUntilEpochSeconds)
        let signed = try XrpPaymentCodec.sign(transaction: payment, privateKey: privateKey)
        try XrpPaymentCodec.assertCommitment(blob: signed.blob, expected: payment)
        try validateQuoteExpiry(validUntilEpochSeconds)
        let hash = signed.transactionHash.map { String(format: "%02X", $0) }.joined()
        let pending = XrpPendingTransaction(
            account: address, hash: hash, blobHex: signed.blob.map { String(format: "%02X", $0) }.joined(),
            sequence: info.sequence,
            lastLedgerSequence: info.lastLedgerSequence,
            preparedLedger: info.validatedLedger,
            state: .pending
        )
        return try await submission.persistAndSubmit(pending)
    }

    func history(before cursor: XrpHistoryCursor?, limit: Int) throws -> [XrpHistoryRecord] {
        try storage.history(before: cursor, limit: limit)
    }

    func clear() throws { try storage.clear() }

    func acknowledgeSubmission(hash: String) throws {
        try storage.acknowledgeSubmission(hash: hash)
    }

    func latestSubmission() throws -> XrpPendingTransaction? {
        try storage.latestSubmission()
    }

    private func validateQuoteExpiry(_ validUntilEpochSeconds: Int?) throws {
        guard let validUntilEpochSeconds else { return }
        guard nowEpochSeconds() < validUntilEpochSeconds else {
            throw XrpRuntimeError.quoteExpired
        }
    }

    private static func validate(server: XrpServerState, ledger: XrpLedgerReference) throws {
        guard server.networkId == 0 else { throw XrpRuntimeError.wrongNetwork(server.networkId) }
        guard ledger.index <= server.validatedLedger else {
            throw XrpRuntimeError.invalidResponse("XRPL endpoint returned inconsistent validated ledgers")
        }
        guard server.completeLedgers.contains(ledger.index ... ledger.index) else {
            throw XrpRuntimeError.invalidResponse("XRPL endpoint does not retain the pinned validated ledger")
        }
    }
}

final class XrpKit: @unchecked Sendable {
    typealias PollSleep = @Sendable (UInt64) async throws -> Void

    let address: String
    let canSign: Bool

    private let engine: XrpEngine
    private let lock = NSLock()
    private let pollSleep: PollSleep
    private var pollTask: Task<Void, Never>?
    private var _snapshot = XrpKitSnapshot.initial

    let snapshotSubject = PublishSubject<XrpKitSnapshot>()
    let receiveAddressSubject = PassthroughSubject<DataStatus<DepositAddress>, Never>()

    init(
        address: String,
        privateKey: Data?,
        rpc: IXrpRpcClient,
        storage: XrpStorage,
        nowEpochSeconds: @escaping @Sendable () -> Int = {
            Int(Date().timeIntervalSince1970)
        },
        pollSleep: @escaping PollSleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.address = address
        canSign = privateKey != nil
        self.pollSleep = pollSleep
        engine = XrpEngine(
            address: address,
            privateKey: privateKey,
            rpc: rpc,
            storage: storage,
            nowEpochSeconds: nowEpochSeconds
        )
    }

    var snapshot: XrpKitSnapshot { lock.xrpWithLock { _snapshot } }

    func start() {
        lock.lock()
        guard pollTask == nil else { lock.unlock(); return }
        pollTask = makePollTask(refreshImmediately: true, initialDelaySeconds: nil)
        lock.unlock()
        receiveAddressSubject.send(.completed(DepositAddress(address)))
    }

    func stop() {
        lock.xrpWithLock { pollTask?.cancel(); pollTask = nil }
    }

    func refresh() {
        guard restartPolling(refreshImmediately: true, initialDelaySeconds: nil) else {
            Task { [weak self] in await self?.refreshNow() }
            return
        }
    }

    func send(
        destination: String,
        destinationTag: UInt32?,
        amount: Decimal,
        memo: String?,
        minimumFeeDrops: UInt64? = nil,
        maximumFeeDrops: UInt64? = nil,
        validUntilEpochSeconds: Int? = nil
    ) async throws -> String {
        let data = memo.map { Data($0.utf8) }
        let result = try await engine.prepareAndSubmit(
            destination: destination, separateTag: destinationTag,
            amountDrops: XrpAmount.drops(amount), memo: data,
            minimumFeeDrops: minimumFeeDrops,
            maximumFeeDrops: maximumFeeDrops,
            validUntilEpochSeconds: validUntilEpochSeconds
        )
        await refreshNow()
        // Even when the immediate post-submit refresh fails, the signed blob is
        // already durable and ambiguous. Force the first reconciliation retry
        // onto the pending cadence instead of trusting a stale nil snapshot.
        _ = restartPolling(refreshImmediately: false, initialDelaySeconds: 4)
        return result
    }

    func sendInfo(
        destination: String,
        destinationTag: UInt32?,
        amount: Decimal,
        memo: String?,
        minimumFeeDrops: UInt64? = nil
    ) async throws -> XrpSendInfo {
        try await engine.sendInfo(
            destination: destination,
            separateTag: destinationTag,
            amountDrops: XrpAmount.drops(amount),
            memo: memo.map { Data($0.utf8) },
            minimumFeeDrops: minimumFeeDrops
        )
    }

    func history(before cursor: XrpHistoryCursor?, limit: Int) async throws -> [XrpHistoryRecord] {
        try await engine.history(before: cursor, limit: limit)
    }

    func acknowledgeSubmission(hash: String) async throws {
        try await engine.acknowledgeSubmission(hash: hash)
        await refreshNow()
        _ = restartPolling(refreshImmediately: false, initialDelaySeconds: nil)
    }

    static func pollIntervalSeconds(submission: XrpPendingTransaction?) -> UInt64 {
        guard let submission else { return 30 }
        switch submission.state {
        case .pending, .unknownLedgerGap: return 4
        case .validatedSuccess, .validatedFailure, .expired, .sequenceConflict: return 30
        }
    }

    private func makePollTask(
        refreshImmediately: Bool,
        initialDelaySeconds: UInt64?
    ) -> Task<Void, Never> {
        let pollSleep = pollSleep
        return Task { [weak self] in
            guard let self else { return }
            if !refreshImmediately {
                do {
                    try await pollSleep(initialDelaySeconds ?? Self.pollIntervalSeconds(submission: snapshot.submission))
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                await refreshNow()
                do {
                    try await pollSleep(Self.pollIntervalSeconds(submission: snapshot.submission))
                } catch {
                    return
                }
            }
        }
    }

    @discardableResult
    private func restartPolling(
        refreshImmediately: Bool,
        initialDelaySeconds: UInt64?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pollTask != nil else { return false }
        pollTask?.cancel()
        pollTask = makePollTask(
            refreshImmediately: refreshImmediately,
            initialDelaySeconds: initialDelaySeconds
        )
        return true
    }

    private func refreshNow() async {
        update(snapshot: XrpKitSnapshot(
            syncState: .syncing,
            balanceDrops: snapshot.balanceDrops,
            availableDrops: snapshot.availableDrops,
            validatedLedger: snapshot.validatedLedger,
            submission: snapshot.submission
        ))
        do {
            update(snapshot: try await engine.refresh())
        } catch is CancellationError {
            return
        } catch {
            var durableSubmission = snapshot.submission
            do {
                durableSubmission = try await engine.latestSubmission()
            } catch {
                // Preserve the last known presentation only when durable storage
                // itself is unreadable; never hide a newly persisted terminal row
                // merely because balance/history refresh failed afterward.
            }
            update(snapshot: XrpKitSnapshot(
                syncState: .notSynced(error.localizedDescription), balanceDrops: snapshot.balanceDrops,
                availableDrops: snapshot.availableDrops, validatedLedger: snapshot.validatedLedger,
                submission: durableSubmission
            ))
        }
    }

    private func update(snapshot: XrpKitSnapshot) {
        lock.xrpWithLock { _snapshot = snapshot }
        snapshotSubject.onNext(snapshot)
    }
}

private extension NSLock {
    func xrpWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
