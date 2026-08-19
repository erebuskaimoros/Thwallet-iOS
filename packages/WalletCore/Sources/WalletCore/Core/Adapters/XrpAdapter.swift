import Combine
import Foundation
import MarketKit
import RxRelay
import RxSwift

final class XrpAdapter {
    private let kit: XrpKit
    private let wallet: Wallet
    private let disposeBag = DisposeBag()
    private var historyTask: Task<Void, Never>?

    private let balanceStateSubject = PublishSubject<AdapterState>()
    private let balanceDataSubject = PublishSubject<BalanceData>()
    private let lastBlockSubject = PublishSubject<Void>()
    private let recordsRelay = BehaviorRelay<[XrpTransactionRecord]>(value: [])

    private(set) var balanceState: AdapterState
    private(set) var balanceData: BalanceData

    init(kit: XrpKit, wallet: Wallet) {
        self.kit = kit
        self.wallet = wallet
        balanceState = Self.adapterState(kit.snapshot)
        balanceData = Self.balanceData(kit.snapshot)

        kit.snapshotSubject
            .subscribe(onNext: { [weak self] snapshot in self?.handle(snapshot: snapshot) })
            .disposed(by: disposeBag)
    }

    deinit { historyTask?.cancel() }

    private func handle(snapshot: XrpKitSnapshot) {
        balanceState = Self.adapterState(snapshot)
        balanceData = Self.balanceData(snapshot)
        balanceStateSubject.onNext(balanceState)
        balanceDataSubject.onNext(balanceData)
        lastBlockSubject.onNext(())

        guard snapshot.syncState == .synced else { return }
        historyTask?.cancel()
        historyTask = Task { [weak self, kit] in
            do {
                let records = try await kit.history(before: nil, limit: 100)
                guard !Task.isCancelled, let self else { return }
                recordsRelay.accept(convert(records))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func convert(_ records: [XrpHistoryRecord]) -> [XrpTransactionRecord] {
        records.map { XrpTransactionRecord(record: $0, token: wallet.token, source: wallet.transactionSource, ownAddress: kit.address) }
    }

    private func load(paginationData: String?, limit: Int) async throws -> [XrpTransactionRecord] {
        let cursor: XrpHistoryCursor?
        if let paginationData {
            guard let parsed = XrpHistoryCursor(rawValue: paginationData) else {
                throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor")
            }
            cursor = parsed
        } else {
            cursor = nil
        }
        return convert(try await kit.history(before: cursor, limit: limit))
    }

    private func loadFiltered(
        paginationData: String?,
        limit: Int,
        type: TransactionTypeFilter,
        address: String?
    ) async throws -> [XrpTransactionRecord] {
        guard limit > 0 else { return [] }

        var cursor: XrpHistoryCursor?
        if let paginationData {
            guard let parsed = XrpHistoryCursor(rawValue: paginationData) else {
                throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor")
            }
            cursor = parsed
        }

        var result = [XrpTransactionRecord]()
        let pageSize = max(50, limit)
        while result.count < limit {
            let page = try await kit.history(before: cursor, limit: pageSize)
            guard !page.isEmpty else { break }

            for rawRecord in page {
                let record = XrpTransactionRecord(
                    record: rawRecord,
                    token: wallet.token,
                    source: wallet.transactionSource,
                    ownAddress: kit.address
                )
                if filter([record], type: type, address: address).isEmpty == false {
                    result.append(record)
                    if result.count == limit { return result }
                }
            }

            cursor = page.last?.cursor
            if page.count < pageSize { break }
        }
        return result
    }

    private func loadTransactionsAfter(paginationData: String?) async throws -> [XrpTransactionRecord] {
        if let paginationData, XrpHistoryCursor(rawValue: paginationData) == nil {
            throw XrpRuntimeError.invalidResponse("Invalid XRP history cursor")
        }

        var cursor: XrpHistoryCursor?
        var newer = [XrpTransactionRecord]()
        let pageSize = 500
        while true {
            let page = try await kit.history(before: cursor, limit: pageSize)
            guard !page.isEmpty else { break }
            for rawRecord in page {
                let record = XrpTransactionRecord(
                    record: rawRecord,
                    token: wallet.token,
                    source: wallet.transactionSource,
                    ownAddress: kit.address
                )
                if record.paginationRaw == paginationData {
                    return Array(newer.reversed())
                }
                newer.append(record)
            }
            guard page.count == pageSize else { break }
            cursor = page.last?.cursor
        }

        if paginationData != nil {
            throw XrpRuntimeError.invalidResponse("XRP history cursor is no longer available")
        }
        return Array(newer.reversed())
    }

    private func filter(_ records: [XrpTransactionRecord], type: TransactionTypeFilter, address: String?) -> [XrpTransactionRecord] {
        records.filter { record in
            let matchesType: Bool
            switch type {
            case .all: matchesType = true
            case .incoming: matchesType = record.direction == .incoming
            case .outgoing: matchesType = record.direction != .incoming
            }
            guard matchesType else { return false }
            guard let address, !address.isEmpty else { return true }
            return record.from == address || record.to == address
        }
    }

    private static func balanceData(_ snapshot: XrpKitSnapshot) -> BalanceData {
        let feeSafetyReserve: UInt64 = 100_000
        let available = snapshot.availableDrops > feeSafetyReserve ? snapshot.availableDrops - feeSafetyReserve : 0
        return BalanceData(total: XrpAmount.xrp(snapshot.balanceDrops), available: XrpAmount.xrp(available))
    }

    private static func adapterState(_ snapshot: XrpKitSnapshot) -> AdapterState {
        switch snapshot.syncState {
        case .syncing: return .syncing(progress: nil, remaining: nil, lastBlockDate: nil)
        case .synced:
            if let message = snapshot.submission?.attentionMessage {
                return .notSynced(error: message)
            }
            return .synced
        case let .notSynced(error): return .notSynced(error: error)
        }
    }
}

extension XrpAdapter: IBaseAdapter {
    var isMainNet: Bool { true }
}

extension XrpAdapter: IAdapter {
    func start() { kit.start() }
    func stop() { kit.stop() }
    func refresh() { kit.refresh() }

    var statusInfo: [(String, Any)] {
        [
            ("Address", kit.address),
            ("Can Sign", kit.canSign),
            ("Sync State", "\(kit.snapshot.syncState)"),
            ("Validated Ledger", kit.snapshot.validatedLedger as Any),
            ("Submission Hash", kit.snapshot.submission?.hash as Any),
            ("Submission State", kit.snapshot.submission.map { "\($0.state)" } as Any),
        ]
    }

    var debugInfo: String { "" }
}

extension XrpAdapter: IBalanceAdapter {
    var balanceStateUpdatedObservable: Observable<AdapterState> { balanceStateSubject.asObservable() }
    var balanceDataUpdatedObservable: Observable<BalanceData> { balanceDataSubject.asObservable() }
}

extension XrpAdapter: IDepositAdapter {
    var receiveAddress: DepositAddress { DepositAddress(kit.address) }
    var receiveAddressPublisher: AnyPublisher<DataStatus<DepositAddress>, Never> { kit.receiveAddressSubject.eraseToAnyPublisher() }
}

extension XrpAdapter: ISendXrpAdapter {
    var canSign: Bool { kit.canSign }

    func sendInfo(
        destination: String,
        destinationTag: UInt32?,
        amount: Decimal,
        memo: String?,
        minimumFeeDrops: UInt64?
    ) async throws -> XrpSendInfo {
        try await kit.sendInfo(
            destination: destination,
            destinationTag: destinationTag,
            amount: amount,
            memo: memo,
            minimumFeeDrops: minimumFeeDrops
        )
    }

    func send(
        destination: String,
        destinationTag: UInt32?,
        amount: Decimal,
        memo: String?,
        minimumFeeDrops: UInt64?,
        maximumFeeDrops: UInt64?,
        validUntilEpochSeconds: Int?
    ) async throws -> String {
        try await kit.send(
            destination: destination,
            destinationTag: destinationTag,
            amount: amount,
            memo: memo,
            minimumFeeDrops: minimumFeeDrops,
            maximumFeeDrops: maximumFeeDrops,
            validUntilEpochSeconds: validUntilEpochSeconds
        )
    }
}

extension XrpAdapter {
    var submission: XrpPendingTransaction? { kit.snapshot.submission }

    func acknowledgeSubmission(hash: String) async throws {
        try await kit.acknowledgeSubmission(hash: hash)
    }
}

extension XrpAdapter: ITransactionsAdapter {
    var syncing: Bool { balanceState.syncing }
    var syncingObservable: Observable<Void> { balanceStateSubject.map { _ in () } }
    var lastBlockInfo: LastBlockInfo? { kit.snapshot.validatedLedger.map { LastBlockInfo(height: Int($0), timestamp: nil) } }
    var lastBlockUpdatedObservable: Observable<Void> { lastBlockSubject.asObservable() }
    var explorerTitle: String { "XRP Ledger Explorer" }
    var additionalTokenQueries: [TokenQuery] { [] }

    func explorerUrl(transactionHash: String) -> String? {
        "https://livenet.xrpl.org/transactions/\(transactionHash)"
    }

    func transactionsObservable(token _: Token?, filter: TransactionTypeFilter, address: String?) -> Observable<[TransactionRecord]> {
        recordsRelay.map { [weak self] records in
            self?.filter(records, type: filter, address: address) ?? []
        }
    }

    func transactionsSingle(paginationData: String?, token _: Token?, filter: TransactionTypeFilter, address: String?, limit: Int) -> Single<[TransactionRecord]> {
        Single.create { [weak self] observer in
            let task = Task { [weak self] in
                do {
                    guard let self else { throw CancellationError() }
                    observer(.success(try await loadFiltered(
                        paginationData: paginationData,
                        limit: limit,
                        type: filter,
                        address: address
                    )))
                } catch {
                    observer(.error(error))
                }
            }
            return Disposables.create { task.cancel() }
        }
    }

    func allTransactionsAfter(paginationData: String?) -> Single<[TransactionRecord]> {
        Single.create { [weak self] observer in
            let task = Task { [weak self] in
                do {
                    guard let self else { throw CancellationError() }
                    observer(.success(try await loadTransactionsAfter(paginationData: paginationData)))
                } catch {
                    observer(.error(error))
                }
            }
            return Disposables.create { task.cancel() }
        }
    }

    func rawTransaction(hash _: String) -> String? { nil }
}
