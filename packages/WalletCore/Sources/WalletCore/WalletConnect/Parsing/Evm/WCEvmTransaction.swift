import BigInt
import EvmKit
import Foundation
import WalletConnectSign

struct WCEvmTransaction: Equatable {
    let from: EvmKit.Address
    let to: EvmKit.Address
    let nonce: Int?
    let gasPrice: Int?
    let gasLimit: Int?
    let maxPriorityFeePerGas: Int?
    let maxFeePerGas: Int?
    let type: Int?
    let value: BigUInt
    let data: Data

    // Upper bound on significant hex digits of a 256-bit EVM QUANTITY (value)
    private static let maximumQuantityHexDigits = 64

    static func parse(params: AnyCodable) throws -> WCEvmTransaction {
        guard let raw = try? params.get([WCEvmRawTransaction].self).first else {
            throw ParsingError.malformedParams
        }
        return try WCEvmTransaction(raw: raw)
    }

    // Thwallet: every present field is parsed strictly and a malformed one rejects the whole request.
    // Dropping a malformed field to nil would let the wallet substitute its own estimate (or 0) for a
    // value the dApp did send, i.e. sign something other than what was requested.
    init(raw: WCEvmRawTransaction) throws {
        guard let to = raw.to else {
            throw ParsingError.noRecipient
        }

        from = try EvmKit.Address(hex: raw.from)
        self.to = try EvmKit.Address(hex: to)
        nonce = try Self.int(quantity: raw.nonce, field: "nonce")
        gasPrice = try Self.int(quantity: raw.gasPrice, field: "gasPrice")

        let gas = try Self.int(quantity: raw.gas, field: "gas")
        let legacyGasLimit = try Self.int(quantity: raw.gasLimit, field: "gasLimit")
        gasLimit = gas ?? legacyGasLimit

        maxPriorityFeePerGas = try Self.int(quantity: raw.maxPriorityFeePerGas, field: "maxPriorityFeePerGas")
        maxFeePerGas = try Self.int(quantity: raw.maxFeePerGas, field: "maxFeePerGas")
        guard (maxPriorityFeePerGas == nil) == (maxFeePerGas == nil) else {
            throw ParsingError.incompleteEip1559GasPrice
        }
        guard gasPrice == nil || maxFeePerGas == nil else {
            throw ParsingError.conflictingGasPriceFields
        }

        type = try Self.int(quantity: raw.type, field: "type")
        switch type {
        case nil:
            break
        case 0:
            guard maxFeePerGas == nil else {
                throw ParsingError.incompatibleTransactionType(0)
            }
        case 2:
            guard gasPrice == nil else {
                throw ParsingError.incompatibleTransactionType(2)
            }
        case let unsupportedType?:
            throw ParsingError.unsupportedTransactionType(unsupportedType)
        }

        guard raw.accessList?.isEmpty != false else {
            // The signer always serializes an empty EIP-2930 access list. Silently dropping a
            // dApp-supplied list would sign a different transaction than the request.
            throw ParsingError.unsupportedAccessList
        }

        value = try Self.bigUInt(quantity: raw.value, field: "value") ?? 0
        data = try Self.data(hex: raw.data)
    }

    var transactionData: TransactionData {
        TransactionData(to: to, value: value, input: data)
    }

    var initialGasPrice: GasPrice? {
        if let maxFeePerGas, let maxPriorityFeePerGas {
            return .eip1559(maxFeePerGas: maxFeePerGas, maxPriorityFeePerGas: maxPriorityFeePerGas)
        }
        return gasPrice.map { .legacy(gasPrice: $0) }
    }

    // EVM QUANTITY: "0x"-prefixed, non-empty, ASCII hex only. No sign, so there is no RLP BigUInt(-1) trap,
    // and a value that does not fit Int is rejected instead of being dropped (Int(_:radix:) returns nil).
    private static func int(quantity: String?, field: String) throws -> Int? {
        guard let quantity else {
            return nil
        }

        let digits = try hexDigits(quantity, field: field)
        guard let value = Int(digits, radix: 16) else {
            throw ParsingError.invalidQuantity(field)
        }

        return value
    }

    private static func bigUInt(quantity: String?, field: String) throws -> BigUInt? {
        guard let quantity else {
            return nil
        }

        let digits = try hexDigits(quantity, field: field)
        let significantDigits = digits.drop(while: { $0 == "0" })
        guard significantDigits.count <= maximumQuantityHexDigits,
              let value = BigUInt(digits, radix: 16)
        else {
            throw ParsingError.invalidQuantity(field)
        }

        return value
    }

    private static func hexDigits(_ quantity: String, field: String) throws -> String {
        guard quantity.hasPrefix("0x") || quantity.hasPrefix("0X") else {
            throw ParsingError.invalidQuantity(field)
        }

        let digits = String(quantity.dropFirst(2))
        guard !digits.isEmpty, digits.utf8.allSatisfy(Self.isAsciiHexDigit) else {
            throw ParsingError.invalidQuantity(field)
        }

        return digits
    }

    // EVM DATA must be "0x"-prefixed, even-length ASCII hex; a non-failing decode would silently corrupt
    // calldata (odd length, non-hex or non-ASCII "hex digit" characters), so reject it instead.
    // An absent field is empty calldata.
    private static func data(hex: String?) throws -> Data {
        guard let hex else { return Data() }
        guard hex.hasPrefix("0x") || hex.hasPrefix("0X") else {
            throw ParsingError.malformedParams
        }

        let digits = String(hex.dropFirst(2))
        guard digits.utf8.count.isMultiple(of: 2), digits.utf8.allSatisfy(Self.isAsciiHexDigit) else {
            throw ParsingError.malformedParams
        }
        return Data(hex: digits)
    }

    private static func isAsciiHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }
}

extension WCEvmTransaction {
    enum ParsingError: Error, Equatable {
        case malformedParams
        case noRecipient
        case invalidQuantity(String)
        case incompleteEip1559GasPrice
        case conflictingGasPriceFields
        case incompatibleTransactionType(Int)
        case unsupportedTransactionType(Int)
        case unsupportedAccessList
    }
}
