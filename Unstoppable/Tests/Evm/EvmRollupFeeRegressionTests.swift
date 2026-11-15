import BigInt
import EvmKit
import Foundation
import XCTest
@testable import WalletCore

final class EvmRollupFeeRegressionTests: XCTestCase {
    private let recipient = try! EvmKit.Address(hex: "0x2222222222222222222222222222222222222222")
    private let gasPrice = GasPrice.eip1559(maxFeePerGas: 100, maxPriorityFeePerGas: 2)

    func testWalletConnectExplicitGasStillInvokesFeeEstimator() async throws {
        var additionalFeeRequests = [(kind: EvmGasDataServiceKind, gasLimit: Int)]()
        let transaction = TransactionData(to: recipient, value: 42, input: Data([1]))

        let result = try await WalletConnectEvmFeePolicy.resolve(predefinedGasLimit: 250_000) { gasLimit in
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: gasPrice,
                predefinedGasLimit: gasLimit,
                feeServiceKind: .opStack,
                evmBalance: 100_000_000,
                estimateGas: { _ in
                    XCTFail("Blast must not replace WalletConnect's explicit gas ceiling")
                    return 100_000
                },
                additionalFee: { kind, gasLimit in
                    additionalFeeRequests.append((kind, gasLimit))
                    return 777
                }
            )
        }

        XCTAssertEqual(result.gasLimit, 250_000)
        XCTAssertEqual(result.surchargedGasLimit, 250_000)
        XCTAssertEqual(result.l1Fee, 777)
        XCTAssertEqual(additionalFeeRequests.map(\.kind), [.opStack])
        XCTAssertEqual(additionalFeeRequests.map(\.gasLimit), [250_000])
    }

    func testAsyncMantleEstimatorKeepsExplicitGasAndDecomposesWithEstimatedUsage() async throws {
        var gasPriceRequests = [GasPrice?]()
        var additionalFeeRequests = [(kind: EvmGasDataServiceKind, gasLimit: Int)]()
        let transaction = TransactionData(to: recipient, value: 42, input: Data([1]))

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: gasPrice,
            predefinedGasLimit: 250_000,
            feeServiceKind: .mantle,
            evmBalance: 100_000_000,
            estimateGas: { requestedGasPrice in
                gasPriceRequests.append(requestedGasPrice)
                return 100_000
            },
            additionalFee: { kind, gasLimit in
                additionalFeeRequests.append((kind, gasLimit))
                return 777
            }
        )

        XCTAssertEqual(result.gasLimit, 250_000)
        XCTAssertEqual(result.surchargedGasLimit, 250_000)
        XCTAssertEqual(result.l1Fee, 777)
        XCTAssertEqual(gasPriceRequests, [gasPrice])
        XCTAssertEqual(additionalFeeRequests.map(\.kind), [.mantle])
        XCTAssertEqual(additionalFeeRequests.map(\.gasLimit), [100_000])
    }

    func testAsyncMantleRejectsInvalidOrInsufficientEstimatedGasBeforeFeeRpc() async {
        let transaction = TransactionData(to: recipient, value: 42, input: Data([1]))

        for (estimated, expectedError) in [
            (3_000_001, EvmGasValidationError.invalidGasLimit(3_000_001, maximum: 3_000_000)),
            (300_000, EvmGasValidationError.insufficientGasLimit(250_000, estimated: 300_000)),
        ] {
            var calledAdditionalFee = false
            await XCTAssertThrowsErrorAsync(
                try await EvmFeeEstimator().estimateFee(
                    transactionData: transaction,
                    gasPrice: gasPrice,
                    predefinedGasLimit: 250_000,
                    feeServiceKind: .mantle,
                    evmBalance: 100_000_000,
                    maximumGasLimit: 3_000_000,
                    estimateGas: { _ in estimated },
                    additionalFee: { _, _ in
                        calledAdditionalFee = true
                        return 1
                    }
                )
            ) { error in
                XCTAssertEqual(error as? EvmGasValidationError, expectedError)
            }
            XCTAssertFalse(calledAdditionalFee)
        }
    }

    func testAsyncOpStackOracleSerializesTheSurchargedSigningLimit() async throws {
        var additionalFeeRequests = [(kind: EvmGasDataServiceKind, gasLimit: Int)]()
        let transaction = TransactionData(to: recipient, value: 42, input: Data([1]))

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: gasPrice,
            predefinedGasLimit: nil,
            feeServiceKind: .opStack,
            evmBalance: 100_000_000,
            estimateGas: { _ in 100_000 },
            additionalFee: { kind, gasLimit in
                additionalFeeRequests.append((kind, gasLimit))
                return 777
            }
        )

        XCTAssertEqual(result.gasLimit, 100_000)
        XCTAssertEqual(result.surchargedGasLimit, 110_000)
        XCTAssertEqual(additionalFeeRequests.map(\.kind), [.opStack])
        XCTAssertEqual(
            additionalFeeRequests.map(\.gasLimit),
            [result.surchargedGasLimit],
            "The OP oracle must serialize the same gas limit that will be signed"
        )
    }

    func testAsyncOpStackAffordabilityConvergesOrFallsBackToExactlyPricedEstimatedGas() async throws {
        let transaction = TransactionData(to: recipient, value: 0, input: Data([1]))
        let balance = BigUInt(10_500)
        var requestedGasLimits = [Int]()

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: .legacy(gasPrice: 100),
            predefinedGasLimit: nil,
            feeServiceKind: .opStack,
            evmBalance: balance,
            maximumGasLimit: 1_000_000,
            estimateGas: { _ in 100 },
            additionalFee: { _, gasLimit in
                requestedGasLimits.append(gasLimit)
                switch gasLimit {
                case 110: return 0
                case 105: return 400
                case 101: return 1_000
                case 100: return 200
                default: return 10_000
                }
            }
        )

        XCTAssertEqual(requestedGasLimits, [110, 105, 101, 100])
        XCTAssertEqual(result.surchargedGasLimit, 100)
        XCTAssertEqual(result.l1Fee, 200)
        XCTAssertLessThanOrEqual(
            BigUInt(result.surchargedGasLimit) * 100 + (result.l1Fee ?? 0),
            balance
        )
    }

    func testFeeTotalPromotesOperandsBeforeMultiplication() {
        let feeData = EvmFeeData(gasLimit: 10_000_000, surchargedGasLimit: 10_000_000, l1Fee: 123)
        let highGasPrice = GasPrice.legacy(gasPrice: 1_000_000_000_000)

        XCTAssertEqual(
            feeData.totalFee(gasPrice: highGasPrice),
            BigUInt(10_000_000) * BigUInt(1_000_000_000_000) + 123
        )
    }

    func testNormalEvmSendRequiresBalanceForValueAndFullFee() {
        XCTAssertThrowsError(
            try EvmSendBalancePolicy.validate(
                balance: 1_000_000,
                transactionValue: 900_000,
                fee: 200_000
            )
        )

        XCTAssertNoThrow(
            try EvmSendBalancePolicy.validate(
                balance: 1_100_000,
                transactionValue: 900_000,
                fee: 200_000
            )
        )
    }

    func testSendAllUsesAConservativeOpStackValueButMantleSimulatesTheStub() {
        let transaction = TransactionData(to: recipient, value: 0x1000, input: Data())

        let opStackTransaction = EvmFeeEstimator.additionalFeeTransactionData(
            transactionData: transaction,
            stubAmount: 1,
            feeServiceKind: .opStack
        )
        let mantleTransaction = EvmFeeEstimator.additionalFeeTransactionData(
            transactionData: transaction,
            stubAmount: 1,
            feeServiceKind: .mantle
        )

        XCTAssertEqual(opStackTransaction.value, 0xFFFF)
        XCTAssertEqual(mantleTransaction.value, 1)
        XCTAssertEqual(opStackTransaction.to, transaction.to)
        XCTAssertEqual(opStackTransaction.input, transaction.input)
    }

    func testGasLimitValidationRejectsUntrustedValuesInsteadOfClampingRequiredGas() async throws {
        let transaction = TransactionData(to: recipient, value: 0, input: Data([1]))

        await XCTAssertThrowsErrorAsync(
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: gasPrice,
                predefinedGasLimit: 3_000_001,
                feeServiceKind: .standard,
                evmBalance: 1_000_000_000,
                maximumGasLimit: 3_000_000,
                estimateGas: { _ in XCTFail("Explicit gas must not be replaced"); return 21_000 },
                additionalFee: { _, _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? EvmFeeEstimator.ValidationError, .invalidGasLimit(3_000_001, maximum: 3_000_000))
        }

        await XCTAssertThrowsErrorAsync(
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: gasPrice,
                predefinedGasLimit: nil,
                feeServiceKind: .standard,
                evmBalance: 1_000_000_000,
                maximumGasLimit: 3_000_000,
                estimateGas: { _ in Int.max },
                additionalFee: { _, _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? EvmFeeEstimator.ValidationError, .invalidGasLimit(Int.max, maximum: 3_000_000))
        }
    }

    func testGasSafetyMarginStopsAtChainCapWithoutReducingEstimatedRequirement() async throws {
        let transaction = TransactionData(to: recipient, value: 0, input: Data([1]))

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: gasPrice,
            predefinedGasLimit: nil,
            feeServiceKind: .standard,
            evmBalance: 1_000_000_000,
            maximumGasLimit: 3_000_000,
            estimateGas: { _ in 2_900_000 },
            additionalFee: { _, _ in nil }
        )

        XCTAssertEqual(result.gasLimit, 2_900_000)
        XCTAssertEqual(result.surchargedGasLimit, 3_000_000)
    }

    func testGasPriceValidationRejectsInvalidEip1559OrderingBeforeRpc() async {
        let invalidGasPrice = GasPrice.eip1559(maxFeePerGas: 99, maxPriorityFeePerGas: 100)
        let transaction = TransactionData(to: recipient, value: 0, input: Data())
        var calledEstimator = false

        await XCTAssertThrowsErrorAsync(
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: invalidGasPrice,
                predefinedGasLimit: nil,
                feeServiceKind: .standard,
                evmBalance: 1_000_000_000,
                estimateGas: { _ in
                    calledEstimator = true
                    return 21_000
                },
                additionalFee: { _, _ in nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? EvmGasValidationError,
                .invalidEip1559GasPrice(maxFeePerGas: 99, maxPriorityFeePerGas: 100)
            )
        }
        XCTAssertFalse(calledEstimator)
    }

    func testSendAllSimulatesGasWithStubValueButKeepsRecipientAndCalldata() {
        let transaction = TransactionData(to: recipient, value: 1_000_000, input: Data([1, 2]))

        let simulation = EvmFeeEstimator.simulationTransactionData(transactionData: transaction, stubAmount: 1)
        let unchanged = EvmFeeEstimator.simulationTransactionData(transactionData: transaction, stubAmount: nil)

        XCTAssertEqual(simulation.value, 1)
        XCTAssertEqual(simulation.to, transaction.to)
        XCTAssertEqual(simulation.input, transaction.input)
        XCTAssertEqual(unchanged.value, 1_000_000)
    }

    func testMantleSendAllPricesAdditionalFeeWithUnsurchargedEstimatedGas() async throws {
        var additionalFeeRequests = [(kind: EvmGasDataServiceKind, gasLimit: Int)]()
        let transaction = TransactionData(to: recipient, value: 1, input: Data())

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: gasPrice,
            predefinedGasLimit: nil,
            feeServiceKind: .mantle,
            evmBalance: 100_000_000,
            estimateGas: { _ in 21_000 },
            additionalFee: { kind, gasLimit in
                additionalFeeRequests.append((kind, gasLimit))
                return 888
            }
        )

        XCTAssertEqual(result.gasLimit, 21_000)
        XCTAssertEqual(result.surchargedGasLimit, 21_000)
        XCTAssertEqual(result.l1Fee, 888)
        XCTAssertEqual(additionalFeeRequests.map(\.kind), [.mantle])
        XCTAssertEqual(additionalFeeRequests.map(\.gasLimit), [21_000])
    }

    func testOpStackExplicitGasStillCallsL1OracleWithoutReEstimating() async throws {
        var additionalFeeRequests = [(kind: EvmGasDataServiceKind, gasLimit: Int)]()
        let transaction = TransactionData(to: recipient, value: 42, input: Data([1]))

        let result = try await EvmFeeEstimator().estimateFee(
            transactionData: transaction,
            gasPrice: gasPrice,
            predefinedGasLimit: 250_000,
            feeServiceKind: .opStack,
            evmBalance: 100_000_000,
            estimateGas: { _ in
                XCTFail("A provider-supplied OP-stack gas limit must not be re-estimated")
                return 100_000
            },
            additionalFee: { kind, gasLimit in
                additionalFeeRequests.append((kind, gasLimit))
                return 999
            }
        )

        XCTAssertEqual(result.gasLimit, 250_000)
        XCTAssertEqual(result.surchargedGasLimit, 250_000)
        XCTAssertEqual(result.l1Fee, 999)
        XCTAssertEqual(additionalFeeRequests.map(\.kind), [.opStack])
        XCTAssertEqual(additionalFeeRequests.map(\.gasLimit), [250_000])
    }

    func testOpStackRejectsExplicitGasAboveChainLimitBeforeCallingOracle() async {
        let transaction = TransactionData(to: recipient, value: 0, input: Data([1]))
        var calledOracle = false

        await XCTAssertThrowsErrorAsync(
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: gasPrice,
                predefinedGasLimit: 3_000_001,
                feeServiceKind: .opStack,
                evmBalance: 1_000_000_000,
                maximumGasLimit: 3_000_000,
                estimateGas: { _ in 21_000 },
                additionalFee: { _, _ in
                    calledOracle = true
                    return 1
                }
            )
        ) { error in
            XCTAssertEqual(error as? EvmGasValidationError, .invalidGasLimit(3_000_001, maximum: 3_000_000))
        }
        XCTAssertFalse(calledOracle)
    }

    func testMantleRejectsUnboundedEstimatedGasBeforeCallingFeeRpc() async {
        let transaction = TransactionData(to: recipient, value: 0, input: Data([1]))
        var calledAdditionalFee = false

        await XCTAssertThrowsErrorAsync(
            try await EvmFeeEstimator().estimateFee(
                transactionData: transaction,
                gasPrice: gasPrice,
                predefinedGasLimit: 2_000_000,
                feeServiceKind: .mantle,
                evmBalance: 1_000_000_000,
                maximumGasLimit: 3_000_000,
                estimateGas: { _ in Int.max },
                additionalFee: { _, _ in
                    calledAdditionalFee = true
                    return 1
                }
            )
        ) { error in
            XCTAssertEqual(error as? EvmGasValidationError, .invalidGasLimit(Int.max, maximum: 3_000_000))
        }
        XCTAssertFalse(calledAdditionalFee)
    }

    func testGasPriceValidationRejectsNonPositiveLegacyPriceBeforeRpc() async {
        let transaction = TransactionData(to: recipient, value: 0, input: Data())

        for invalidPrice in [0, -1] {
            var calledEstimator = false
            await XCTAssertThrowsErrorAsync(
                try await EvmFeeEstimator().estimateFee(
                    transactionData: transaction,
                    gasPrice: .legacy(gasPrice: invalidPrice),
                    predefinedGasLimit: nil,
                    feeServiceKind: .standard,
                    evmBalance: 1_000_000_000,
                    estimateGas: { _ in
                        calledEstimator = true
                        return 21_000
                    },
                    additionalFee: { _, _ in nil }
                )
            ) { error in
                XCTAssertEqual(error as? EvmGasValidationError, .invalidGasPrice(invalidPrice))
            }
            XCTAssertFalse(calledEstimator)
        }
    }

    func testWalletConnectSignValidationRejectsGasAboveChainLimit() {
        XCTAssertThrowsError(
            try WalletConnectEvmFeePolicy.validate(
                gasPrice: gasPrice,
                gasLimit: 3_000_001,
                maximumGasLimit: 3_000_000
            )
        ) { error in
            XCTAssertEqual(error as? EvmGasValidationError, .invalidGasLimit(3_000_001, maximum: 3_000_000))
        }
    }

    func testWalletConnectRejectsMalformedOrNegativeQuantitiesInsteadOfDroppingThem() throws {
        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(gas: "-0x1"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .invalidQuantity("gas"))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(gas: "0x10x2"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .invalidQuantity("gas"))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(gas: "0xffffffffffffffffffff"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .invalidQuantity("gas"))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(value: "0xnot-a-number"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .invalidQuantity("value"))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(value: "0x1" + String(repeating: "0", count: 64)))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .invalidQuantity("value"))
        }
    }

    func testWalletConnectRejectsMalformedCalldataAndIncompleteEip1559Price() {
        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(data: "0x0g"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .malformedParams)
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(maxFeePerGas: "0x64"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .incompleteEip1559GasPrice)
        }
    }

    func testWalletConnectRejectsUnsupportedOrContradictoryTransactionTypes() {
        XCTAssertThrowsError(
            try WCEvmTransaction(
                raw: wcTransaction(
                    type: "0x2",
                    accessList: [
                        WCEvmAccessListEntry(
                            address: recipient.hex,
                            storageKeys: ["0x" + String(repeating: "0", count: 64)]
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .unsupportedAccessList)
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(
                raw: wcTransaction(
                    gasPrice: "0x64",
                    maxPriorityFeePerGas: "0x2",
                    maxFeePerGas: "0x64"
                )
            )
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .conflictingGasPriceFields)
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(gasPrice: "0x64", type: "0x2"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .incompatibleTransactionType(2))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(
                raw: wcTransaction(
                    maxPriorityFeePerGas: "0x2",
                    maxFeePerGas: "0x64",
                    type: "0x0"
                )
            )
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .incompatibleTransactionType(0))
        }

        XCTAssertThrowsError(
            try WCEvmTransaction(raw: wcTransaction(type: "0x1"))
        ) { error in
            XCTAssertEqual(error as? WCEvmTransaction.ParsingError, .unsupportedTransactionType(1))
        }
    }

    func testWalletConnectTransactionFromMustMatchTheActiveSessionAccount() throws {
        let requested = try EvmKit.Address(hex: "0x1111111111111111111111111111111111111111")
        let active = try EvmKit.Address(hex: "0x2222222222222222222222222222222222222222")

        XCTAssertThrowsError(
            try WalletConnectAccountPolicy.validate(requestedFrom: requested, activeAddress: active)
        ) { error in
            XCTAssertEqual(error as? WalletConnectAccountPolicy.ValidationError, .invalidFromAddress)
        }
        XCTAssertNoThrow(try WalletConnectAccountPolicy.validate(requestedFrom: requested, activeAddress: requested))
    }

    func testWalletConnectParsesValidJsonRpcQuantitiesWithoutGlobalPrefixReplacement() throws {
        let transaction = try WCEvmTransaction(
            raw: wcTransaction(
                nonce: "0x2a",
                gasPrice: "0x64",
                gas: "0x5208",
                type: "0x0",
                value: "0x1234"
            )
        )

        XCTAssertEqual(transaction.nonce, 42)
        XCTAssertEqual(transaction.gasPrice, 100)
        XCTAssertEqual(transaction.gasLimit, 21_000)
        XCTAssertEqual(transaction.type, 0)
        XCTAssertEqual(transaction.value, 0x1234)
    }

    func testUSwapEvmSignableParsingFailsClosedForValueGasAndCalldata() throws {
        let valid = try USwapEvmSignableParser.parse([
            "to": recipient.hex,
            "value": "0x1234",
            "gas": "0x5208",
            "data": "0x0102",
        ])
        XCTAssertEqual(valid.transactionData.to, recipient)
        XCTAssertEqual(valid.transactionData.value, 0x1234)
        XCTAssertEqual(valid.transactionData.input, Data([1, 2]))
        XCTAssertEqual(valid.gasLimit, 21_000)

        let invalidPayloads: [[String: Any]] = [
            ["to": recipient.hex, "value": "0xnot-a-number", "gas": "0x5208", "data": "0x"],
            ["to": recipient.hex, "value": "0x1", "gas": "-0x1", "data": "0x"],
            ["to": recipient.hex, "value": "0x1", "gas": "0x10x2", "data": "0x"],
            ["to": recipient.hex, "value": "0x1", "gas": "0x5208", "data": "0x0"],
            ["to": recipient.hex, "value": "0x1", "gas": "0x5208", "data": "0x0g"],
        ]
        for invalid in invalidPayloads {
            XCTAssertThrowsError(try USwapEvmSignableParser.parse(invalid))
        }
    }

    private func wcTransaction(
        nonce: String? = nil,
        gasPrice: String? = nil,
        gas: String? = nil,
        gasLimit: String? = nil,
        maxPriorityFeePerGas: String? = nil,
        maxFeePerGas: String? = nil,
        type: String? = nil,
        value: String? = nil,
        accessList: [WCEvmAccessListEntry]? = nil,
        data: String? = "0x"
    ) -> WCEvmRawTransaction {
        WCEvmRawTransaction(
            from: "0x1111111111111111111111111111111111111111",
            to: recipient.hex,
            nonce: nonce,
            gasPrice: gasPrice,
            gas: gas,
            gasLimit: gasLimit,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            type: type,
            value: value,
            accessList: accessList,
            data: data
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
