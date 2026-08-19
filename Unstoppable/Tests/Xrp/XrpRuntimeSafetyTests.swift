import Foundation
import GRDB
import Testing
@testable import WalletCore

struct XrpRuntimeSafetyTests {
    @Test
    func sendInfoRunsPinnedLivePreflightWithoutSigningOrSubmitting() async throws {
        let rpc = FakeXrpRpc()
        await rpc.configure(accountState: XrpAccountState(
            address: "rDestination",
            balanceDrops: 2_000_000,
            sequence: 7,
            ownerCount: 0,
            flags: XrpAccountState.requireDestinationTagFlag
        ))
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-preflight-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        let engine = XrpEngine(
            address: "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3",
            privateKey: nil,
            rpc: rpc,
            storage: XrpStorage(dbPool: pool, account: "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3")
        )

        await #expect(throws: XrpRuntimeError.destinationTagRequired) {
            try await engine.sendInfo(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100_000,
                memo: nil,
                minimumFeeDrops: 300
            )
        }

        let info = try await engine.sendInfo(
            destination: xrpDestination,
            separateTag: 0,
            amountDrops: 100_000,
            memo: nil,
            minimumFeeDrops: 300
        )
        #expect(info.destination.destinationTag == 0)
        #expect(info.feeDrops == 300)
        #expect(info.sequence == 7)
        #expect(info.validatedLedger == 100)
        #expect(await rpc.submittedBlobs.isEmpty)
    }

    @Test
    func incomingPaymentUsesDeliveredAmountInsteadOfAdvertisedAmount() throws {
        let entry = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            amount: .string("999999999"),
            deliveredAmount: .string("7")
        )

        let record = try #require(try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn"))
        #expect(record.amountDrops == 7)
        #expect(record.direction == .incoming)
    }

    @Test
    func legacyDirectPaymentWithUnavailableDeliveredAmountFallsBackToRequestedAmount() throws {
        let entry = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            amount: .string("91"),
            deliveredAmount: .string("unavailable")
        )

        let record = try #require(try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn"))
        #expect(record.amountDrops == 91)
    }

    @Test
    func simultaneousApiV1AmountAndApiV2DeliverMaxFailsClosed() {
        let entry = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            amount: .string("91"),
            legacyAmount: .string("91")
        )

        #expect(throws: XrpRuntimeError.invalidResponse("Malformed native XRP Payment")) {
            try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn")
        }
    }

    @Test
    func historyNormalizesHashAndRejectsWrapperTransactionMismatch() throws {
        let lowerHash = String(repeating: "a", count: 64)
        var lowerWrapper = try #require(paymentEntry(
            hash: lowerHash,
            source: "rSource",
            destination: "rOwn"
        ).object)
        lowerWrapper["hash"] = .string(lowerHash)
        let normalized = try #require(try XrpHistorySyncer.record(
            entry: .object(lowerWrapper),
            ownAddress: "rOwn"
        ))
        #expect(normalized.hash == lowerHash.uppercased())

        let mismatch = paymentEntry(
            hash: "A",
            transactionHash: "B",
            source: "rSource",
            destination: "rOwn"
        )
        #expect(throws: XrpRuntimeError.invalidResponse("XRPL transaction hash commitment mismatch")) {
            try XrpHistorySyncer.record(entry: mismatch, ownAddress: "rOwn")
        }
    }

    @Test
    func apiV2OutgoingPaymentUsesDeliverMax() throws {
        let entry = paymentEntry(
            source: "rOwn",
            destination: "rDestination",
            amount: .string("91"),
            deliveredAmount: .string("91")
        )

        let record = try #require(try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn"))
        #expect(record.amountDrops == 91)
        #expect(record.direction == .outgoing)
    }

    @Test
    func failedPaymentRecordsZeroInsteadOfAdvertisedAmount() throws {
        let entry = paymentEntry(
            source: "rOwn",
            destination: "rDestination",
            amount: .string("999999999"),
            deliveredAmount: .string("unavailable"),
            result: "tecUNFUNDED_PAYMENT"
        )

        let record = try #require(try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn"))
        #expect(record.amountDrops == 0)
        #expect(record.succeeded == false)
    }

    @Test
    func partialAndPathPaymentsAreExcludedFromNarrowNativeHistory() throws {
        let partial = paymentEntry(
            source: "rOwn",
            destination: "rDestination",
            amount: .string("999"),
            deliveredAmount: .string("7"),
            flags: 0x0002_0000
        )
        let path = paymentEntry(
            source: "rOwn",
            destination: "rDestination",
            amount: .string("7"),
            deliveredAmount: .string("7"),
            sendMax: .object([
                "currency": .string("USD"),
                "issuer": .string("rIssuer"),
                "value": .string("1"),
            ]),
            paths: .array([])
        )
        let deliverMin = paymentEntry(
            source: "rOwn",
            destination: "rDestination",
            amount: .string("7"),
            deliveredAmount: .string("7"),
            deliverMin: .string("1")
        )

        #expect(try XrpHistorySyncer.record(entry: partial, ownAddress: "rOwn") == nil)
        #expect(try XrpHistorySyncer.record(entry: path, ownAddress: "rOwn") == nil)
        #expect(try XrpHistorySyncer.record(entry: deliverMin, ownAddress: "rOwn") == nil)
    }

    @Test
    func malformedNativePaymentFailsHistoryPageInsteadOfAdvancingCheckpoint() async {
        let rpc = FakeXrpRpc()
        let store = TestHistoryStore()
        let malformed = paymentEntry(source: "rSource", destination: "rOwn", amount: nil)
        await rpc.setHistoryPages([
            XrpHistoryPage(entries: [malformed], marker: nil, ledgerIndexMin: 1, ledgerIndexMax: 200),
        ])

        await #expect(throws: XrpRuntimeError.invalidResponse("Malformed native XRP Payment")) {
            try await XrpHistorySyncer(rpc: rpc, store: store).sync(address: "rOwn", fromLedger: 1, toLedger: 200)
        }
        #expect(await store.records.isEmpty)
        #expect(await store.checkpoints.isEmpty)
    }

    @Test
    func conflictingWrapperAndTransactionLedgersFailWithoutPublishingHistory() async {
        let rpc = FakeXrpRpc()
        let store = TestHistoryStore()
        let malformed = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            ledgerIndex: 100,
            transactionLedgerIndex: 201
        )
        await rpc.setHistoryPages([
            XrpHistoryPage(entries: [malformed], marker: nil, ledgerIndexMin: 1, ledgerIndexMax: 200),
        ])

        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL transaction ledger commitment mismatch")) {
            try await XrpHistorySyncer(rpc: rpc, store: store).sync(
                address: "rOwn",
                fromLedger: 1,
                toLedger: 200
            )
        }
        #expect(await store.records.isEmpty)
        #expect(await store.checkpoints.isEmpty)
    }

    @Test
    func issuedCurrencyDeliveredAmountIsNeverRenderedAsNativeXrp() throws {
        let entry = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            amount: .string("999999999"),
            deliveredAmount: .object(["currency": .string("USD"), "value": .string("1000000"), "issuer": .string("rIssuer")])
        )

        #expect(try XrpHistorySyncer.record(entry: entry, ownAddress: "rOwn") == nil)
    }

    @Test
    func historyPaginatesOpaqueMarkersAndCommitsCheckpointOnlyAfterLastPage() async throws {
        let rpc = FakeXrpRpc()
        let store = TestHistoryStore()
        let marker: XrpJsonValue = .object(["ledger": .uint(100), "seq": .uint(7)])
        await rpc.setHistoryPages([
            XrpHistoryPage(entries: [paymentEntry(source: "rSource", destination: "rOwn")], marker: marker, ledgerIndexMin: 1, ledgerIndexMax: 200),
            XrpHistoryPage(entries: [paymentEntry(hash: "B", source: "rOwn", destination: "rDestination")], marker: nil, ledgerIndexMin: 1, ledgerIndexMax: 200),
        ])

        try await XrpHistorySyncer(rpc: rpc, store: store).sync(address: "rOwn", fromLedger: 1, toLedger: 200)

        #expect(await rpc.receivedMarkers == [nil, marker])
        #expect(await store.records.map(\.hash) == [historyHash("A"), historyHash("B")])
        #expect(await store.checkpoints == [200])
        #expect(await store.stageBatchSizes == [1, 1])
    }

    @Test
    func inactiveDeletedAccountStillSynchronizesHistoricalTransactions() async throws {
        let rpc = FakeXrpRpc()
        await rpc.configure(
            server: XrpServerState(
                networkId: 0,
                validatedLedger: 32_570,
                completeLedgers: try XrpLedgerRanges("1-32570")
            ),
            accountAvailable: false
        )
        await rpc.setHistoryPages([
            XrpHistoryPage(
                entries: [paymentEntry(source: "rSource", destination: xrpAccount, ledgerIndex: 32_570)],
                marker: nil,
                ledgerIndexMin: 32_570,
                ledgerIndexMax: 32_570
            ),
        ])
        let engine = try makeEngine(rpc: rpc, privateKey: nil)

        let snapshot = try await engine.refresh()

        #expect(snapshot.balanceDrops == 0)
        #expect(try await engine.history(before: nil, limit: 10).map(\.hash) == [historyHash("A")])
    }

    @Test
    func failedLaterHistoryPageCannotAdvanceCheckpoint() async {
        let rpc = FakeXrpRpc()
        let store = TestHistoryStore()
        await rpc.setHistoryPages([
            XrpHistoryPage(entries: [paymentEntry(source: "rSource", destination: "rOwn")], marker: .string("next"), ledgerIndexMin: 1, ledgerIndexMax: 200),
        ], failAfter: 1)

        await #expect(throws: TestError.forced) {
            try await XrpHistorySyncer(rpc: rpc, store: store).sync(address: "rOwn", fromLedger: 1, toLedger: 200)
        }
        #expect(await store.checkpoints.isEmpty)
        #expect(await store.records.isEmpty)
    }

    @Test
    func repeatedOpaqueMarkerFailsInsteadOfLoopingForever() async {
        let rpc = FakeXrpRpc()
        let store = TestHistoryStore()
        let marker: XrpJsonValue = .object(["ledger": .uint(100), "seq": .uint(7)])
        await rpc.setHistoryPages([
            XrpHistoryPage(entries: [], marker: marker, ledgerIndexMin: 1, ledgerIndexMax: 200),
            XrpHistoryPage(entries: [], marker: marker, ledgerIndexMin: 1, ledgerIndexMax: 200),
        ])

        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL account_tx marker cycle")) {
            try await XrpHistorySyncer(rpc: rpc, store: store).sync(address: "rOwn", fromLedger: 1, toLedger: 200)
        }
        #expect(await store.checkpoints.isEmpty)
    }

    @Test
    func mismatchedHistoryRangeOrOutOfRangeEntryCannotAdvanceCheckpoint() async {
        let rangeRpc = FakeXrpRpc()
        let rangeStore = TestHistoryStore()
        await rangeRpc.setHistoryPages([
            XrpHistoryPage(entries: [], marker: nil, ledgerIndexMin: 2, ledgerIndexMax: 200),
        ])
        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL account_tx returned a different ledger range")) {
            try await XrpHistorySyncer(rpc: rangeRpc, store: rangeStore).sync(address: "rOwn", fromLedger: 1, toLedger: 200)
        }
        #expect(await rangeStore.checkpoints.isEmpty)

        let entryRpc = FakeXrpRpc()
        let entryStore = TestHistoryStore()
        await entryRpc.setHistoryPages([
            XrpHistoryPage(
                entries: [paymentEntry(hash: "OUTSIDE", source: "rSource", destination: "rOwn", ledgerIndex: 201)],
                marker: nil,
                ledgerIndexMin: 1,
                ledgerIndexMax: 200
            ),
        ])
        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL account_tx entry is outside the requested ledger range")) {
            try await XrpHistorySyncer(rpc: entryRpc, store: entryStore).sync(address: "rOwn", fromLedger: 1, toLedger: 200)
        }
        #expect(await entryStore.checkpoints.isEmpty)
    }

    @Test
    func signedBlobIsPersistedBeforeSubmitAndRetryUsesIdenticalBlob() async throws {
        let log = EventLog()
        let rpc = FakeXrpRpc(log: log)
        let store = TestPendingStore(log: log)
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let pending = try signedPendingTransaction()

        _ = try await service.persistAndSubmit(pending)
        _ = try await service.resubmitSameBlob(hash: pending.hash, account: pending.account)

        #expect(await log.events == ["save:\(pending.hash)", "submit:\(pending.blobHex)", "submit:\(pending.blobHex)"])
        #expect(await rpc.submittedBlobs == [pending.blobHex, pending.blobHex])
    }

    @Test
    func preliminarySubmitSuccessNeverFinalizesTransaction() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let pending = try signedPendingTransaction()

        _ = try await service.persistAndSubmit(pending)

        #expect(await store.value(hash: pending.hash)?.state == .pending)
    }

    @Test
    func submitTransportFailureReturnsDurableHashForReconciliation() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let pending = try signedPendingTransaction(destinationTag: 1)
        await rpc.failSubmissions()

        #expect(try await service.persistAndSubmit(pending) == pending.hash)
        #expect(await store.value(hash: pending.hash)?.state == .pending)
    }

    @Test
    func onlyValidatedLookupCanFinalizeSuccessOrFailure() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let success = try signedPendingTransaction(sequence: 1, lastLedgerSequence: 104)
        let failure = try signedPendingTransaction(sequence: 2, lastLedgerSequence: 104)
        try await store.save(success); try await store.save(failure)
        await rpc.configure(
            server: XrpServerState(networkId: 0, validatedLedger: 120, completeLedgers: try XrpLedgerRanges("1-120")),
            lookups: [
                success.hash: XrpTransactionLookup(hash: success.hash, validated: true, resultCode: "tesSUCCESS", ledgerIndex: 101),
                failure.hash: XrpTransactionLookup(hash: failure.hash, validated: true, resultCode: "tecUNFUNDED_PAYMENT", ledgerIndex: 102),
            ]
        )

        try await service.reconcile(account: success.account)

        #expect(await store.value(hash: success.hash)?.state == .validatedSuccess(ledger: 101))
        #expect(await store.value(hash: failure.hash)?.state == .validatedFailure(code: "tecUNFUNDED_PAYMENT", ledger: 102))
    }

    @Test
    func expiryRequiresContinuousLedgerCoverageAndSequenceIsConflictChecked() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let gap = try signedPendingTransaction(sequence: 1, lastLedgerSequence: 104)
        try await store.save(gap)
        await rpc.configure(
            server: XrpServerState(networkId: 0, validatedLedger: 120, completeLedgers: try XrpLedgerRanges("1-101,103-120")),
            accountState: XrpAccountState(address: gap.account, balanceDrops: 2_000_000, sequence: 2, ownerCount: 0, flags: 0)
        )
        try await service.reconcile(account: gap.account)
        #expect(await store.value(hash: gap.hash)?.state == .unknownLedgerGap)

        var retried = try #require(await store.value(hash: gap.hash)); retried.state = .pending
        try await store.save(retried)
        await rpc.configure(server: XrpServerState(networkId: 0, validatedLedger: 120, completeLedgers: try XrpLedgerRanges("1-120")))
        try await service.reconcile(account: gap.account)
        #expect(await store.value(hash: gap.hash)?.state == .sequenceConflict)
    }

    @Test
    func deletedAccountAfterSignedWindowBecomesDurableSequenceConflict() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let pending = try signedPendingTransaction(sequence: 1, lastLedgerSequence: 104)
        try await store.save(pending)
        await rpc.configure(
            server: XrpServerState(
                networkId: 0,
                validatedLedger: 120,
                completeLedgers: try XrpLedgerRanges("1-120")
            ),
            accountAvailable: false
        )

        try await XrpReliableSubmission(rpc: rpc, store: store).reconcile(account: pending.account)

        #expect(await store.value(hash: pending.hash)?.state == .sequenceConflict)
    }

    @Test
    func validatedLookupOutsideSignedLedgerWindowCannotFinalize() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let service = XrpReliableSubmission(rpc: rpc, store: store)
        let pending = try signedPendingTransaction(lastLedgerSequence: 104)
        try await store.save(pending)
        await rpc.configure(
            server: XrpServerState(networkId: 0, validatedLedger: 120, completeLedgers: try XrpLedgerRanges("1-120")),
            lookups: [pending.hash: XrpTransactionLookup(hash: pending.hash, validated: true, resultCode: "tesSUCCESS", ledgerIndex: 105)]
        )

        await #expect(throws: XrpRuntimeError.invalidResponse("Validated XRP transaction is outside its signed ledger window")) {
            try await service.reconcile(account: pending.account)
        }
        #expect(await store.value(hash: pending.hash)?.state == .pending)
    }

    @Test
    func lingeringUnvalidatedLookupCannotPreventExpiryAfterSignedWindow() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let pending = try signedPendingTransaction(sequence: 1, lastLedgerSequence: 104)
        try await store.save(pending)
        await rpc.configure(
            server: XrpServerState(
                networkId: 0,
                validatedLedger: 120,
                completeLedgers: try XrpLedgerRanges("1-120")
            ),
            lookups: [
                pending.hash: XrpTransactionLookup(
                    hash: pending.hash,
                    validated: false,
                    resultCode: nil,
                    ledgerIndex: nil
                ),
            ],
            accountState: XrpAccountState(
                address: pending.account,
                balanceDrops: 2_000_000,
                sequence: pending.sequence,
                ownerCount: 0,
                flags: 0
            )
        )

        try await XrpReliableSubmission(rpc: rpc, store: store).reconcile(account: pending.account)

        #expect(await store.value(hash: pending.hash)?.state == .expired)
    }

    @Test
    func reserveFeeAndDestinationSafetyRulesFailClosed() throws {
        let feeSettings = XrpFeeSettings(baseFeeDrops: 1_000_000, reserveBaseDrops: 1_000_000, reserveIncrementDrops: 200_000)
        let account = XrpAccountState(address: "r", balanceDrops: 2_000_000, sequence: 1, ownerCount: 2, flags: XrpAccountState.requireDestinationTagFlag)
        #expect(try account.availableDrops(feeSettings: feeSettings, pendingFeeDrops: 100) == 599_900)

        let preflight = XrpPaymentPreflight(maxFeeDrops: 1_000)
        #expect(throws: XrpRuntimeError.feeExceedsCap(actual: 1_001, cap: 1_000)) { try preflight.fee(1_001) }
        #expect(throws: XrpRuntimeError.destinationTagRequired) {
            try preflight.validateDestination(state: account, tag: nil, feeSettings: feeSettings, amountDrops: 1)
        }
        #expect(throws: XrpRuntimeError.destinationInactive(minimumDrops: 1_000_000)) {
            try preflight.validateDestination(state: nil, tag: nil, feeSettings: feeSettings, amountDrops: 999_999)
        }
    }

    @Test
    func untrustedReserveArithmeticFailsClosedAtIntegerBounds() throws {
        let multiplicationOverflow = XrpFeeSettings(
            baseFeeDrops: 1,
            reserveBaseDrops: 1,
            reserveIncrementDrops: UInt64.max
        )
        #expect(throws: XrpRuntimeError.arithmeticOverflow) {
            try multiplicationOverflow.requiredReserve(ownerCount: 2)
        }

        let additionOverflow = XrpFeeSettings(
            baseFeeDrops: 1,
            reserveBaseDrops: UInt64.max,
            reserveIncrementDrops: 1
        )
        #expect(throws: XrpRuntimeError.arithmeticOverflow) {
            try additionOverflow.requiredReserve(ownerCount: 1)
        }

        let account = XrpAccountState(
            address: "rAccount",
            balanceDrops: UInt64.max,
            sequence: 1,
            ownerCount: 1,
            flags: 0
        )
        #expect(throws: XrpRuntimeError.arithmeticOverflow) {
            try account.availableDrops(feeSettings: additionOverflow)
        }
    }

    @Test
    func untrustedRpcDropsBeyondNativeProtocolMaximumFailClosed() async throws {
        let oversized = String(XrpAmount.maximumDrops + 1)
        let history = paymentEntry(
            source: "rSource",
            destination: "rOwn",
            amount: .string(oversized),
            deliveredAmount: .string(oversized)
        )
        #expect(throws: XrpRuntimeError.invalidResponse("Malformed native XRP Payment")) {
            try XrpHistorySyncer.record(entry: history, ownAddress: "rOwn")
        }

        let transport = RecordingXrpTransport(responses: [
            "account_info": .object([
                "validated": .bool(true),
                "ledger_hash": .string("LEDGER"),
                "ledger_index": .uint(100),
                "account_data": .object([
                    "Account": .string("rRequested"),
                    "Balance": .string(oversized),
                    "Sequence": .uint(1),
                    "OwnerCount": .uint(0),
                    "Flags": .uint(0),
                ]),
            ]),
        ])
        await #expect(throws: XrpRuntimeError.invalidResponse("Uncommitted account_info response")) {
            try await XrpRpcClient(transport: transport).accountState(
                address: "rRequested",
                ledger: XrpLedgerReference(index: 100, hash: "LEDGER")
            )
        }
    }

    @Test
    func amountConversionEnforcesTheNativeXrpProtocolMaximum() throws {
        #expect(try XrpAmount.drops(Decimal(100_000_000_000)) == XrpAmount.maximumDrops)
        #expect(throws: XrpRuntimeError.arithmeticOverflow) {
            try XrpAmount.drops(Decimal(100_000_000_000) + Decimal(string: "0.000001")!)
        }
    }

    @Test
    func fakeWrongNetworkAndIncompleteValidatedLedgerAreRejectedBeforeSend() async throws {
        let rpc = FakeXrpRpc()
        let engine = try makeEngine(rpc: rpc, privateKey: nil)
        await rpc.configure(server: XrpServerState(
            networkId: 1,
            validatedLedger: 100,
            completeLedgers: try XrpLedgerRanges("1-100")
        ))

        await #expect(throws: XrpRuntimeError.wrongNetwork(1)) {
            try await engine.sendInfo(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil
            )
        }

        await rpc.configure(server: XrpServerState(
            networkId: 0,
            validatedLedger: 100,
            completeLedgers: try XrpLedgerRanges("1-99")
        ))
        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL endpoint does not retain the pinned validated ledger")) {
            try await engine.sendInfo(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil
            )
        }
        #expect(await rpc.submittedBlobs.isEmpty)
    }

    @Test
    func ledgerCloseBetweenPinAndServerProofDoesNotFailPreflight() async throws {
        let rpc = LedgerCloseRaceRpc()
        let engine = try makeEngine(rpc: rpc, privateKey: nil)

        let info = try await engine.sendInfo(
            destination: xrpDestination,
            separateTag: nil,
            amountDrops: 100,
            memo: nil
        )

        #expect(info.validatedLedger == 100)
        #expect(await rpc.callOrder == ["ledger", "server"])
    }

    @Test
    func pollingUsesFastPendingAndSlowIdleIntervals() {
        var submission = XrpPendingTransaction(
            account: "rAccount",
            hash: String(repeating: "A", count: 64),
            blobHex: "00",
            sequence: 1,
            lastLedgerSequence: 2,
            preparedLedger: 1,
            state: .pending
        )
        #expect(XrpKit.pollIntervalSeconds(submission: nil) == 30)
        #expect(XrpKit.pollIntervalSeconds(submission: submission) == 4)
        submission.state = .unknownLedgerGap
        #expect(XrpKit.pollIntervalSeconds(submission: submission) == 4)
        submission.state = .sequenceConflict
        #expect(XrpKit.pollIntervalSeconds(submission: submission) == 30)
    }

    @Test
    func explicitRefreshWakesAnIdlePollImmediately() async throws {
        let rpc = FakeXrpRpc()
        let sleeper = RecordingPollSleeper()
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-poll-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        let kit = XrpKit(
            address: xrpAccount,
            privateKey: nil,
            rpc: rpc,
            storage: XrpStorage(dbPool: pool, account: xrpAccount),
            pollSleep: { seconds in try await sleeper.sleep(seconds: seconds) }
        )
        kit.start()
        defer { kit.stop() }

        try await eventually { await sleeper.intervals == [30] }
        let callsBeforeWake = await rpc.validatedLedgerCallCount

        kit.refresh()

        try await eventually { await rpc.validatedLedgerCallCount >= callsBeforeWake + 2 }
        #expect(await sleeper.intervals.last == 30)
    }

    @Test
    func failedPostSubmitRefreshStillSchedulesPendingCadence() async throws {
        let rpc = FakeXrpRpc()
        let sleeper = RecordingPollSleeper()
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-post-send-poll-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        let kit = XrpKit(
            address: xrpAccount,
            privateKey: try Data(xrpStrictHex: xrpPrivateKeyHex),
            rpc: rpc,
            storage: XrpStorage(dbPool: pool, account: xrpAccount),
            pollSleep: { seconds in try await sleeper.sleep(seconds: seconds) }
        )
        kit.start()
        defer { kit.stop() }
        try await eventually { await sleeper.intervals == [30] }
        #expect(await rpc.validatedLedgerCallCount == 2)
        await rpc.failValidatedLedger(afterCallCount: 3)

        let hash = try await kit.send(
            destination: xrpDestination,
            destinationTag: nil,
            amount: Decimal(string: "0.0001")!,
            memo: nil
        )

        #expect(hash.utf8.count == 64)
        try await eventually { await sleeper.intervals.last == 4 }
    }

    @Test
    func terminalConflictRemainsVisibleWhenSubsequentHistorySyncFails() async throws {
        let rpc = FakeXrpRpc()
        await rpc.configure(
            server: XrpServerState(
                networkId: 0,
                validatedLedger: 32_570,
                completeLedgers: try XrpLedgerRanges("1-32570")
            ),
            accountAvailable: false
        )
        let sleeper = RecordingPollSleeper()
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-terminal-presentation-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        let storage = XrpStorage(dbPool: pool, account: xrpAccount)
        try await storage.save(try signedPendingTransaction())
        let kit = XrpKit(
            address: xrpAccount,
            privateKey: nil,
            rpc: rpc,
            storage: storage,
            pollSleep: { seconds in try await sleeper.sleep(seconds: seconds) }
        )
        kit.start()
        defer { kit.stop() }

        try await eventually {
            kit.snapshot.submission?.state == .sequenceConflict
        }

        #expect(kit.snapshot.submission?.attentionMessage != nil)
        guard case .notSynced = kit.snapshot.syncState else {
            Issue.record("Expected failed history refresh to remain not-synced")
            return
        }
    }

    @Test
    func terminalConflictIsPresentedImmediatelyAfterOfflineRestart() async throws {
        let rpc = FakeXrpRpc()
        await rpc.failValidatedLedger(afterCallCount: 0)
        let sleeper = RecordingPollSleeper()
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-offline-terminal-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        var migrator = DatabaseMigrator()
        XrpStorage.registerMigration(in: &migrator)
        try migrator.migrate(pool)
        let storage = XrpStorage(dbPool: pool, account: xrpAccount)
        var conflict = try signedPendingTransaction()
        conflict.state = .sequenceConflict
        try await storage.save(conflict)
        let expectedConflict = conflict
        let kit = XrpKit(
            address: xrpAccount,
            privateKey: nil,
            rpc: rpc,
            storage: storage,
            pollSleep: { seconds in try await sleeper.sleep(seconds: seconds) }
        )
        kit.start()
        defer { kit.stop() }

        try await eventually { kit.snapshot.submission == expectedConflict }

        #expect(kit.snapshot.submission?.attentionMessage != nil)
        guard case .notSynced = kit.snapshot.syncState else {
            Issue.record("Expected offline XRP kit to remain not-synced")
            return
        }
    }

    @Test
    func concurrentSendsCannotSignTheSameAccountSequenceTwice() async throws {
        let rpc = FakeXrpRpc()
        let engine = try makeEngine(rpc: rpc, privateKey: try Data(xrpStrictHex: xrpPrivateKeyHex))

        async let first: Result<String, Error> = asyncResult {
            try await engine.prepareAndSubmit(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil
            )
        }
        async let second: Result<String, Error> = asyncResult {
            try await engine.prepareAndSubmit(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 101,
                memo: nil
            )
        }
        let results = await [first, second]

        #expect(results.filter(\.isSuccess).count == 1)
        #expect(results.filter { result in
            if case .failure(XrpRuntimeError.pendingTransactionExists) = result { return true }
            return false
        }.count == 1)
        #expect(await rpc.submittedBlobs.count == 1)
    }

    @Test
    func sendRejectsFeeIncreaseAboveTheDisplayedPreflightCommitment() async throws {
        let rpc = FakeXrpRpc()
        await rpc.setOpenLedgerFees([10, 11])
        let engine = try makeEngine(rpc: rpc, privateKey: try Data(xrpStrictHex: xrpPrivateKeyHex))
        let displayed = try await engine.sendInfo(
            destination: xrpDestination,
            separateTag: nil,
            amountDrops: 100,
            memo: nil
        )
        #expect(displayed.feeDrops == 10)

        await #expect(throws: XrpRuntimeError.feeExceedsApproved(actual: 11, approved: 10)) {
            try await engine.prepareAndSubmit(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil,
                maximumFeeDrops: displayed.feeDrops
            )
        }
        #expect(await rpc.submittedBlobs.isEmpty)
    }

    @Test
    func expiredSwapQuoteIsRejectedAfterLivePreflightBeforeSigning() async throws {
        let rpc = FakeXrpRpc()
        let clock = LockedEpochClock(values: [1_000])
        let engine = try makeEngine(
            rpc: rpc,
            privateKey: try Data(xrpStrictHex: xrpPrivateKeyHex),
            nowEpochSeconds: { clock.next() }
        )

        await #expect(throws: XrpRuntimeError.quoteExpired) {
            try await engine.prepareAndSubmit(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil,
                validUntilEpochSeconds: 1_000
            )
        }

        #expect(await rpc.openLedgerFeeCallCount == 1)
        #expect(await rpc.submittedBlobs.isEmpty)
        #expect(try await engine.latestSubmission() == nil)
    }

    @Test
    func swapQuoteExpiringDuringSigningIsRejectedBeforePersistence() async throws {
        let rpc = FakeXrpRpc()
        let clock = LockedEpochClock(values: [999, 1_000])
        let engine = try makeEngine(
            rpc: rpc,
            privateKey: try Data(xrpStrictHex: xrpPrivateKeyHex),
            nowEpochSeconds: { clock.next() }
        )

        await #expect(throws: XrpRuntimeError.quoteExpired) {
            try await engine.prepareAndSubmit(
                destination: xrpDestination,
                separateTag: nil,
                amountDrops: 100,
                memo: nil,
                validUntilEpochSeconds: 1_000
            )
        }

        #expect(clock.callCount == 2)
        #expect(await rpc.submittedBlobs.isEmpty)
        #expect(try await engine.latestSubmission() == nil)
    }

    @Test
    func reconciliationCannotFinalizeAHashMismatchedLookup() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let pending = try signedPendingTransaction()
        try await store.save(pending)
        await rpc.configure(
            server: XrpServerState(networkId: 0, validatedLedger: 120, completeLedgers: try XrpLedgerRanges("1-120")),
            lookups: [
                pending.hash: XrpTransactionLookup(
                    hash: String(repeating: "A", count: 64),
                    validated: true,
                    resultCode: "tesSUCCESS",
                    ledgerIndex: 101
                ),
            ]
        )

        await #expect(throws: XrpRuntimeError.invalidResponse("XRPL transaction lookup hash mismatch")) {
            try await XrpReliableSubmission(rpc: rpc, store: store).reconcile(account: pending.account)
        }
        #expect(await store.value(hash: pending.hash)?.state == .pending)
    }

    @Test
    func pendingRetrySubmitsOnlyTheIdenticalDurableBlob() async throws {
        let rpc = FakeXrpRpc()
        let store = TestPendingStore()
        let pending = try signedPendingTransaction()
        try await store.save(pending)
        await rpc.configure(server: XrpServerState(
            networkId: 0,
            validatedLedger: 100,
            completeLedgers: try XrpLedgerRanges("1-100")
        ))

        try await XrpReliableSubmission(rpc: rpc, store: store).reconcile(account: pending.account)

        #expect(await rpc.submittedBlobs == [pending.blobHex])
        #expect(await store.value(hash: pending.hash)?.state == .pending)
    }

    @Test
    func rpcPinsApiVersionAccountAndHistoryRange() async throws {
        let transport = RecordingXrpTransport(responses: [
            "account_info": .object([
                "validated": .bool(true),
                "ledger_hash": .string("LEDGER"),
                "ledger_index": .uint(100),
                "account_data": .object([
                    "Account": .string("rRequested"),
                    "Balance": .string("1000000"),
                    "Sequence": .uint(7),
                    "OwnerCount": .uint(0),
                    "Flags": .uint(0),
                ]),
            ]),
            "account_tx": .object([
                "account": .string("rRequested"),
                "validated": .bool(true),
                "ledger_index_min": .uint(90),
                "ledger_index_max": .uint(100),
                "transactions": .array([]),
            ]),
            "submit": .object([
                "engine_result": .string("tesSUCCESS"),
            ]),
        ])
        let client = XrpRpcClient(transport: transport)
        let ledger = XrpLedgerReference(index: 100, hash: "LEDGER")

        _ = try await client.accountState(address: "rRequested", ledger: ledger)
        _ = try await client.accountTransactions(
            address: "rRequested",
            fromLedger: 90,
            toLedger: 100,
            marker: nil
        )
        _ = try await client.submit(blobHex: "BLOB")
        let calls = await transport.calls

        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.params["api_version"] == .uint(2) })
        #expect(calls[0].params["queue"] == .bool(false))
        #expect(calls[0].params["ledger_hash"] == .string("LEDGER"))
        #expect(calls[1].params["ledger_index_min"] == .uint(90))
        #expect(calls[1].params["ledger_index_max"] == .uint(100))
        #expect(calls[2].params["fail_hard"] == .bool(false))
    }

    @Test
    func apiV2TransactionNotFoundShapeReturnsNilForReconciliation() async throws {
        let client = XrpRpcClient(transport: FailingXrpTransport(
            error: XrpRuntimeError.rpc(code: 29, message: "Transaction not found.")
        ))

        #expect(try await client.transaction(hash: String(repeating: "A", count: 64)) == nil)
    }
}

private enum TestError: Error { case forced }

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0 ..< 200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestError.forced
}

private func asyncResult<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

private actor EventLog {
    private(set) var events = [String]()
    func append(_ event: String) { events.append(event) }
}

private actor RecordingPollSleeper {
    private(set) var intervals = [UInt64]()

    func sleep(seconds: UInt64) async throws {
        intervals.append(seconds)
        try await Task.sleep(for: .seconds(3_600))
    }
}

private final class LockedEpochClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]
    private(set) var callCount = 0

    init(values: [Int]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if values.count > 1 {
            return values.removeFirst()
        }
        return values[0]
    }
}

private actor FakeXrpRpc: IXrpRpcClient {
    private let log: EventLog?
    private var pages = [XrpHistoryPage]()
    private var failAfter: Int?
    private(set) var receivedMarkers = [XrpJsonValue?]()
    private(set) var submittedBlobs = [String]()
    private(set) var validatedLedgerCallCount = 0
    private(set) var openLedgerFeeCallCount = 0
    private var server = try! XrpServerState(networkId: 0, validatedLedger: 100, completeLedgers: XrpLedgerRanges("1-100"))
    private var lookups = [String: XrpTransactionLookup]()
    private var configuredAccount = XrpAccountState(address: xrpAccount, balanceDrops: 2_000_000, sequence: 1, ownerCount: 0, flags: 0)
    private var submissionFailure = false
    private var failValidatedLedgerAfterCallCount: Int?
    private var openLedgerFees: [UInt64] = [12]

    init(log: EventLog? = nil) { self.log = log }

    func setHistoryPages(_ pages: [XrpHistoryPage], failAfter: Int? = nil) {
        self.pages = pages; self.failAfter = failAfter
    }

    private var accountAvailable = true

    func configure(
        server: XrpServerState? = nil,
        lookups: [String: XrpTransactionLookup]? = nil,
        accountState: XrpAccountState? = nil,
        accountAvailable: Bool? = nil
    ) {
        if let server { self.server = server }; if let lookups { self.lookups = lookups }; if let accountState { configuredAccount = accountState }
        if let accountAvailable { self.accountAvailable = accountAvailable }
    }
    func failSubmissions() { submissionFailure = true }
    func failValidatedLedger(afterCallCount: Int) { failValidatedLedgerAfterCallCount = afterCallCount }
    func setOpenLedgerFees(_ fees: [UInt64]) { openLedgerFees = fees }

    func serverState() async throws -> XrpServerState { server }
    func validatedLedger() async throws -> XrpLedgerReference {
        validatedLedgerCallCount += 1
        if let failValidatedLedgerAfterCallCount,
           validatedLedgerCallCount > failValidatedLedgerAfterCallCount
        {
            throw TestError.forced
        }
        return XrpLedgerReference(index: server.validatedLedger, hash: "ledger")
    }
    func feeSettings(ledger: XrpLedgerReference) async throws -> XrpFeeSettings { XrpFeeSettings(baseFeeDrops: 10, reserveBaseDrops: 1_000_000, reserveIncrementDrops: 200_000) }
    func accountState(address: String, ledger: XrpLedgerReference) async throws -> XrpAccountState {
        guard accountAvailable else { throw XrpRuntimeError.accountNotFound }
        return configuredAccount
    }
    func openLedgerFeeDrops() async throws -> UInt64 {
        openLedgerFeeCallCount += 1
        guard let fee = openLedgerFees.first else { throw TestError.forced }
        if openLedgerFees.count > 1 { openLedgerFees.removeFirst() }
        return fee
    }

    func accountTransactions(address: String, fromLedger: UInt32, toLedger: UInt32, marker: XrpJsonValue?) async throws -> XrpHistoryPage {
        receivedMarkers.append(marker)
        if let failAfter, receivedMarkers.count > failAfter { throw TestError.forced }
        guard !pages.isEmpty else { throw TestError.forced }
        return pages.removeFirst()
    }

    func transaction(hash: String) async throws -> XrpTransactionLookup? { lookups[hash] }
    func submit(blobHex: String) async throws -> XrpSubmitResult {
        submittedBlobs.append(blobHex); await log?.append("submit:\(blobHex)")
        if submissionFailure { throw URLError(.timedOut) }
        return XrpSubmitResult(engineResult: "tesSUCCESS", engineResultMessage: nil)
    }
}

private actor LedgerCloseRaceRpc: IXrpRpcClient {
    private var serverWasCalled = false
    private var ledgerWasCalled = false
    private(set) var callOrder = [String]()

    func validatedLedger() async throws -> XrpLedgerReference {
        callOrder.append("ledger")
        ledgerWasCalled = true
        return XrpLedgerReference(index: serverWasCalled ? 101 : 100, hash: "PINNED")
    }

    func serverState() async throws -> XrpServerState {
        callOrder.append("server")
        serverWasCalled = true
        return XrpServerState(
            networkId: 0,
            validatedLedger: ledgerWasCalled ? 101 : 100,
            completeLedgers: try XrpLedgerRanges("1-101")
        )
    }

    func feeSettings(ledger _: XrpLedgerReference) async throws -> XrpFeeSettings {
        XrpFeeSettings(baseFeeDrops: 10, reserveBaseDrops: 1_000_000, reserveIncrementDrops: 200_000)
    }

    func accountState(address: String, ledger _: XrpLedgerReference) async throws -> XrpAccountState {
        XrpAccountState(address: address, balanceDrops: 2_000_000, sequence: 1, ownerCount: 0, flags: 0)
    }

    func openLedgerFeeDrops() async throws -> UInt64 { 10 }
    func accountTransactions(address _: String, fromLedger _: UInt32, toLedger _: UInt32, marker _: XrpJsonValue?) async throws -> XrpHistoryPage {
        throw TestError.forced
    }
    func transaction(hash _: String) async throws -> XrpTransactionLookup? { nil }
    func submit(blobHex _: String) async throws -> XrpSubmitResult { throw TestError.forced }
}

private actor TestHistoryStore: IXrpHistoryStore {
    private(set) var records = [XrpHistoryRecord]()
    private(set) var checkpoints = [UInt32]()
    private(set) var stageBatchSizes = [Int]()
    private var staged = [String: [XrpHistoryRecord]]()

    func beginStaging(session: String) async throws {
        staged[session] = []
    }

    func stage(records: [XrpHistoryRecord], session: String) async throws {
        guard staged[session] != nil else { throw TestError.forced }
        stageBatchSizes.append(records.count)
        staged[session, default: []].append(contentsOf: records)
    }

    func commitStaged(session: String, checkpoint: UInt32) async throws {
        guard let stagedRecords = staged.removeValue(forKey: session) else { throw TestError.forced }
        records.append(contentsOf: stagedRecords)
        checkpoints.append(checkpoint)
    }

    func discardStaged(session: String) async {
        staged.removeValue(forKey: session)
    }
}

private actor TestPendingStore: IXrpPendingTransactionStore {
    private let log: EventLog?
    private var values = [String: XrpPendingTransaction]()
    init(log: EventLog? = nil) { self.log = log }
    func save(_ transaction: XrpPendingTransaction) async throws {
        values[transaction.hash] = transaction; await log?.append("save:\(transaction.hash)")
    }
    func unresolved(account: String) async throws -> [XrpPendingTransaction] {
        values.values.filter {
            guard $0.account == account else { return false }
            return $0.state == .pending || $0.state == .unknownLedgerGap
        }
    }
    func value(hash: String) -> XrpPendingTransaction? { values[hash] }
}

private func paymentEntry(
    hash: String = "A",
    transactionHash: String? = nil,
    source: String,
    destination: String,
    amount: XrpJsonValue? = .string("10"),
    legacyAmount: XrpJsonValue? = nil,
    deliveredAmount: XrpJsonValue? = .string("10"),
    result: String = "tesSUCCESS",
    flags: UInt32 = 0,
    sendMax: XrpJsonValue? = nil,
    deliverMin: XrpJsonValue? = nil,
    paths: XrpJsonValue? = nil,
    ledgerIndex: UInt32 = 100,
    transactionLedgerIndex: UInt32? = nil
) -> XrpJsonValue {
    var transaction: [String: XrpJsonValue] = [
        "TransactionType": .string("Payment"), "Account": .string(source), "Destination": .string(destination),
        "Fee": .string("12"), "Flags": .uint(UInt64(flags)),
    ]
    transaction["DeliverMax"] = amount
    transaction["Amount"] = legacyAmount
    if let transactionHash {
        transaction["hash"] = .string(historyHash(transactionHash))
    }
    if let transactionLedgerIndex {
        transaction["ledger_index"] = .uint(UInt64(transactionLedgerIndex))
    }
    transaction["SendMax"] = sendMax
    transaction["DeliverMin"] = deliverMin
    transaction["Paths"] = paths
    var meta: [String: XrpJsonValue] = ["TransactionResult": .string(result)]
    meta["delivered_amount"] = deliveredAmount
    return .object([
        "validated": .bool(true),
        "tx_json": .object(transaction),
        "hash": .string(historyHash(hash)),
        "ledger_index": .uint(UInt64(ledgerIndex)),
        "close_time_iso": .string("2025-05-08T18:40:00Z"),
        "meta": .object(meta),
    ])
}

private func historyHash(_ label: String) -> String {
    if label.utf8.count == 64,
       label.utf8.allSatisfy({
           (0x30 ... 0x39).contains($0)
               || (0x41 ... 0x46).contains($0)
               || (0x61 ... 0x66).contains($0)
       })
    {
        return label.uppercased()
    }
    let encoded = Data(label.utf8).map { String(format: "%02X", $0) }.joined()
    precondition(encoded.count <= 64)
    return String(repeating: "0", count: 64 - encoded.count) + encoded
}

private actor RecordingXrpTransport: IXrpRpcTransport {
    struct Call: Sendable {
        let method: String
        let params: [String: XrpJsonValue]
    }

    private let responses: [String: XrpJsonValue]
    private(set) var calls = [Call]()

    init(responses: [String: XrpJsonValue]) {
        self.responses = responses
    }

    func request(method: String, params: [String: XrpJsonValue]) async throws -> XrpJsonValue {
        calls.append(Call(method: method, params: params))
        guard let response = responses[method] else { throw TestError.forced }
        return response
    }
}

private struct FailingXrpTransport: IXrpRpcTransport {
    let error: Error
    func request(method _: String, params _: [String: XrpJsonValue]) async throws -> XrpJsonValue {
        throw error
    }
}

private let xrpAccount = "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"
private let xrpDestination = "r3AgF9mMBFtaLhKcg96weMhbbEFLZ3mx17"
private let xrpPrivateKeyHex = "90802A50AA84EFB6CDB225F17C27616EA94048C179142FECF03F4712A07EA7A4"

private func makeEngine(
    rpc: IXrpRpcClient,
    privateKey: Data?,
    nowEpochSeconds: @escaping @Sendable () -> Int = {
        Int(Date().timeIntervalSince1970)
    }
) throws -> XrpEngine {
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("xrp-engine-\(UUID().uuidString).sqlite")
    let pool = try DatabasePool(path: dbURL.path)
    var migrator = DatabaseMigrator()
    XrpStorage.registerMigration(in: &migrator)
    try migrator.migrate(pool)
    return XrpEngine(
        address: xrpAccount,
        privateKey: privateKey,
        rpc: rpc,
        storage: XrpStorage(dbPool: pool, account: xrpAccount),
        nowEpochSeconds: nowEpochSeconds
    )
}

private func signedPendingTransaction(
    sequence: UInt32 = 1,
    lastLedgerSequence: UInt32 = 104,
    destinationTag: UInt32? = nil
) throws -> XrpPendingTransaction {
    let payment = XrpNativePayment(
        account: xrpAccount,
        destination: XrpDestination(classicAddress: xrpDestination, destinationTag: destinationTag),
        amountDrops: 100,
        feeDrops: 12,
        sequence: sequence,
        lastLedgerSequence: lastLedgerSequence,
        memo: nil
    )
    let signed = try XrpPaymentCodec.sign(
        transaction: payment,
        privateKey: Data(xrpStrictHex: xrpPrivateKeyHex)
    )
    return XrpPendingTransaction(
        account: payment.account,
        hash: signed.transactionHash.xrpHexUppercased,
        blobHex: signed.blob.xrpHexUppercased,
        sequence: payment.sequence,
        lastLedgerSequence: payment.lastLedgerSequence,
        preparedLedger: payment.lastLedgerSequence - 4,
        state: .pending
    )
}

private extension Data {
    init(xrpStrictHex string: String) throws {
        guard string.count.isMultiple(of: 2) else { throw TestError.forced }
        var bytes = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else { throw TestError.forced }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var xrpHexUppercased: String { map { String(format: "%02X", $0) }.joined() }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
