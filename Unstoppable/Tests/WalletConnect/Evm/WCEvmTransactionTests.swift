import BigInt
import EvmKit
import Foundation
import Testing
import WalletConnectSign
@testable import WalletCore

struct WCEvmTransactionTests {
    // params[0] exactly as react-app.walletconnect.com sent it during the 2026-09-02 spike
    private let spikeParams: [[String: String]] = [[
        "from": "0x3f4E9c3Ac73a4cff7540293c24a3D055E03fd78d",
        "to": "0x3f4E9c3Ac73a4cff7540293c24a3D055E03fd78d",
        "data": "0x",
        "gasLimit": "0x5208",
        "gasPrice": "0x06bb7166",
        "nonce": "0x0146",
        "value": "0x00",
    ]]

    @Test func parsesSpikeParams() throws {
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: spikeParams))

        #expect(transaction.from.eip55 == WCTestFixtures.address)
        #expect(transaction.to.eip55 == WCTestFixtures.address)
        #expect(transaction.gasLimit == 21000)
        #expect(transaction.gasPrice == 0x06BB_7166)
        #expect(transaction.nonce == 326)
        #expect(transaction.value == 0)
        #expect(transaction.data.isEmpty)
        #expect(transaction.initialGasPrice == .legacy(gasPrice: 0x06BB_7166))
    }

    @Test func gasTakesPrecedenceOverLegacyGasLimit() throws {
        var params = spikeParams
        params[0]["gas"] = "0x7530"
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.gasLimit == 30000)
    }

    @Test func eip1559FieldsProduceEip1559GasPrice() throws {
        var params = spikeParams
        params[0]["gasPrice"] = nil
        params[0]["maxFeePerGas"] = "0x3b9aca00"
        params[0]["maxPriorityFeePerGas"] = "0x3b9aca0"
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.initialGasPrice == .eip1559(maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 62_500_000))
    }

    @Test func missingFeeFieldsLeaveGasPriceNil() throws {
        var params = spikeParams
        params[0]["gasPrice"] = nil
        params[0]["nonce"] = nil
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.initialGasPrice == nil)
        #expect(transaction.nonce == nil)
    }

    @Test func valueAndDataDecode() throws {
        var params = spikeParams
        params[0]["value"] = "0xde0b6b3a7640000"
        params[0]["data"] = "0xa9059cbb"
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.value == BigUInt(1_000_000_000_000_000_000))
        #expect(transaction.data == Data([0xA9, 0x05, 0x9C, 0xBB]))
        #expect(transaction.transactionData.input == transaction.data)
        #expect(transaction.transactionData.value == transaction.value)
    }

    @Test func missingRecipientIsRejected() {
        var params = spikeParams
        params[0]["to"] = nil
        #expect(throws: WCEvmTransaction.ParsingError.noRecipient) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func malformedParamsAreRejected() {
        #expect(throws: WCEvmTransaction.ParsingError.malformedParams) {
            try WCEvmTransaction.parse(params: AnyCodable(any: ["not", "a", "transaction"]))
        }
        #expect(throws: WCEvmTransaction.ParsingError.malformedParams) {
            try WCEvmTransaction.parse(params: AnyCodable(any: [[String: String]]()))
        }
    }

    // Thwallet: a malformed quantity rejects the request instead of being dropped to nil (which would let
    // the wallet substitute its own nonce / gas for the one the dApp sent)
    @Test func negativeQuantityIsRejectedNotDropped() {
        var params = spikeParams
        params[0]["nonce"] = "-1"
        #expect(throws: WCEvmTransaction.ParsingError.invalidQuantity("nonce")) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func overflowingIntQuantityIsRejectedNotDropped() {
        var params = spikeParams
        params[0]["gasPrice"] = "0x" + String(repeating: "f", count: 40) // far beyond Int.max
        #expect(throws: WCEvmTransaction.ParsingError.invalidQuantity("gasPrice")) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func overflowingValueStaysUnboundedBigUInt() throws {
        var params = spikeParams
        params[0]["value"] = "0x" + String(repeating: "f", count: 40)
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.value > BigUInt(UInt64.max))
    }

    @Test func oddLengthCalldataIsRejected() {
        var params = spikeParams
        params[0]["data"] = "0xabc"
        #expect(throws: WCEvmTransaction.ParsingError.malformedParams) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func nonHexCalldataIsRejected() {
        var params = spikeParams
        params[0]["data"] = "0xzzzz"
        #expect(throws: WCEvmTransaction.ParsingError.malformedParams) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test(arguments: ["0x", "5208", "0x-1", "0x+1", "0x52 08", "0x\u{FF15}"])
    func malformedGasQuantityIsRejected(gas: String) {
        var params = spikeParams
        params[0]["gas"] = gas
        #expect(throws: WCEvmTransaction.ParsingError.invalidQuantity("gas")) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func malformedLegacyGasLimitIsRejectedEvenWhenGasIsPresent() {
        var params = spikeParams
        params[0]["gas"] = "0x7530"
        params[0]["gasLimit"] = "0xzz"
        #expect(throws: WCEvmTransaction.ParsingError.invalidQuantity("gasLimit")) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func valueIsBoundedTo256Bits() throws {
        var params = spikeParams
        params[0]["value"] = "0x" + String(repeating: "f", count: 64)
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.value == BigUInt(2).power(256) - 1)

        params[0]["value"] = "0x1" + String(repeating: "0", count: 64)
        #expect(throws: WCEvmTransaction.ParsingError.invalidQuantity("value")) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func calldataWithoutPrefixOrWithNonAsciiDigitsIsRejected() {
        for data in ["a9059cbb", "0x\u{FF21}\u{FF22}"] {
            var params = spikeParams
            params[0]["data"] = data
            #expect(throws: WCEvmTransaction.ParsingError.malformedParams) {
                try WCEvmTransaction.parse(params: AnyCodable(any: params))
            }
        }
    }

    @Test func absentCalldataIsEmpty() throws {
        var params = spikeParams
        params[0]["data"] = nil
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.data.isEmpty)
    }

    @Test func halfSpecifiedEip1559PriceIsRejected() {
        var params = spikeParams
        params[0]["gasPrice"] = nil
        params[0]["maxPriorityFeePerGas"] = "0x3b9aca0"
        #expect(throws: WCEvmTransaction.ParsingError.incompleteEip1559GasPrice) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func legacyAndEip1559PricesTogetherAreRejected() {
        var params = spikeParams
        params[0]["maxFeePerGas"] = "0x3b9aca00"
        params[0]["maxPriorityFeePerGas"] = "0x3b9aca0"
        #expect(throws: WCEvmTransaction.ParsingError.conflictingGasPriceFields) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func typeMustMatchTheGasPriceFields() throws {
        var legacy = spikeParams
        legacy[0]["type"] = "0x2"
        #expect(throws: WCEvmTransaction.ParsingError.incompatibleTransactionType(2)) {
            try WCEvmTransaction.parse(params: AnyCodable(any: legacy))
        }

        var eip1559 = spikeParams
        eip1559[0]["gasPrice"] = nil
        eip1559[0]["maxFeePerGas"] = "0x3b9aca00"
        eip1559[0]["maxPriorityFeePerGas"] = "0x3b9aca0"
        eip1559[0]["type"] = "0x0"
        #expect(throws: WCEvmTransaction.ParsingError.incompatibleTransactionType(0)) {
            try WCEvmTransaction.parse(params: AnyCodable(any: eip1559))
        }

        eip1559[0]["type"] = "0x2"
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: eip1559))
        #expect(transaction.type == 2)
        #expect(transaction.initialGasPrice == .eip1559(maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 62_500_000))
    }

    @Test(arguments: ["0x1", "0x3", "0x4", "0x7e"])
    func unsupportedTransactionTypeIsRejected(type: String) throws {
        var params = spikeParams
        params[0]["type"] = type
        let expected = try #require(Int(type.dropFirst(2), radix: 16))
        #expect(throws: WCEvmTransaction.ParsingError.unsupportedTransactionType(expected)) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }
    }

    @Test func nonEmptyAccessListIsRejectedAndEmptyOneAccepted() throws {
        var params: [[String: Any]] = spikeParams.map { $0 as [String: Any] }
        let entry: [String: Any] = ["address": WCTestFixtures.address, "storageKeys": ["0x" + String(repeating: "0", count: 64)]]
        params[0]["accessList"] = [entry]
        #expect(throws: WCEvmTransaction.ParsingError.unsupportedAccessList) {
            try WCEvmTransaction.parse(params: AnyCodable(any: params))
        }

        params[0]["accessList"] = [[String: Any]]()
        let transaction = try WCEvmTransaction.parse(params: AnyCodable(any: params))
        #expect(transaction.to.eip55 == WCTestFixtures.address)
    }
}
