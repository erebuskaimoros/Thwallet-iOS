import BigInt
import EvmKit
import Foundation

struct WCEthereumAccessListEntry: Codable {
    let address: String
    let storageKeys: [String]
}

struct WCEthereumTransaction: Codable {
    public let from: String
    public let to: String?
    public let nonce: String?
    public let gasPrice: String?
    public let gas: String?
    public let gasLimit: String? // legacy gas limit
    public let maxPriorityFeePerGas: String?
    public let maxFeePerGas: String?
    public let type: String?
    public let value: String?
    public let accessList: [WCEthereumAccessListEntry]?
    public let data: String
}

struct WalletConnectTransaction {
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

    init(transaction: WCEthereumTransaction) throws {
        guard let to = transaction.to else {
            throw TransactionError.noRecipient
        }

        from = try EvmKit.Address(hex: transaction.from)
        self.to = try EvmKit.Address(hex: to)
        nonce = try Self.intQuantity(transaction.nonce, field: "nonce")
        gasPrice = try Self.intQuantity(transaction.gasPrice, field: "gasPrice")

        let gas = try Self.intQuantity(transaction.gas, field: "gas")
        let legacyGasLimit = try Self.intQuantity(transaction.gasLimit, field: "gasLimit")
        gasLimit = gas ?? legacyGasLimit

        maxPriorityFeePerGas = try Self.intQuantity(transaction.maxPriorityFeePerGas, field: "maxPriorityFeePerGas")
        maxFeePerGas = try Self.intQuantity(transaction.maxFeePerGas, field: "maxFeePerGas")
        guard (maxPriorityFeePerGas == nil) == (maxFeePerGas == nil) else {
            throw TransactionError.incompleteEip1559GasPrice
        }
        guard gasPrice == nil || maxFeePerGas == nil else {
            throw TransactionError.conflictingGasPriceFields
        }

        type = try Self.intQuantity(transaction.type, field: "type")
        switch type {
        case nil:
            break
        case 0:
            guard maxFeePerGas == nil else {
                throw TransactionError.incompatibleTransactionType(0)
            }
        case 2:
            guard gasPrice == nil else {
                throw TransactionError.incompatibleTransactionType(2)
            }
        case let unsupportedType?:
            throw TransactionError.unsupportedTransactionType(unsupportedType)
        }
        guard transaction.accessList?.isEmpty != false else {
            // The signer always serializes an empty EIP-2930 access list. Silently dropping a
            // dApp-supplied list would sign a different transaction than the request.
            throw TransactionError.unsupportedAccessList
        }

        value = try Self.bigUIntQuantity(transaction.value, field: "value") ?? 0
        data = try Self.hexData(transaction.data)
    }

    private static func intQuantity(_ quantity: String?, field: String) throws -> Int? {
        guard let quantity else {
            return nil
        }

        let digits = try hexDigits(quantity, field: field)
        guard let value = Int(digits, radix: 16) else {
            throw TransactionError.invalidQuantity(field)
        }

        return value
    }

    private static func bigUIntQuantity(_ quantity: String?, field: String) throws -> BigUInt? {
        guard let quantity else {
            return nil
        }

        let digits = try hexDigits(quantity, field: field)
        let significantDigits = digits.drop(while: { $0 == "0" })
        guard significantDigits.count <= 64,
              let value = BigUInt(digits, radix: 16)
        else {
            throw TransactionError.invalidQuantity(field)
        }

        return value
    }

    private static func hexDigits(_ quantity: String, field: String) throws -> String {
        guard quantity.hasPrefix("0x") || quantity.hasPrefix("0X") else {
            throw TransactionError.invalidQuantity(field)
        }

        let digits = String(quantity.dropFirst(2))
        guard !digits.isEmpty, digits.utf8.allSatisfy(Self.isAsciiHexDigit) else {
            throw TransactionError.invalidQuantity(field)
        }

        return digits
    }

    private static func hexData(_ value: String) throws -> Data {
        guard value.hasPrefix("0x") || value.hasPrefix("0X") else {
            throw TransactionError.invalidData
        }

        let digits = String(value.dropFirst(2))
        guard digits.count.isMultiple(of: 2), digits.utf8.allSatisfy(Self.isAsciiHexDigit) else {
            throw TransactionError.invalidData
        }

        return Data(hex: "0x" + digits)
    }

    private static func isAsciiHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }
}

extension WalletConnectTransaction {
    enum TransactionError: Error, Equatable {
        case noRecipient
        case invalidQuantity(String)
        case invalidData
        case incompleteEip1559GasPrice
        case conflictingGasPriceFields
        case incompatibleTransactionType(Int)
        case unsupportedTransactionType(Int)
        case unsupportedAccessList
    }
}
