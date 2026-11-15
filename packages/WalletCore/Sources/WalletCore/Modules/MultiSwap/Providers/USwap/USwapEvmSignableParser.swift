import BigInt
import EvmKit
import Foundation

/// Fail-closed decoding of the `to` / `value` / `data` / `gas` fields of a server-built EVM
/// transaction. Encodings follow the USwap v3 contract: `value` and `gas` are decimal or `0x`-hex
/// strings (a bare JSON number is tolerated), `data` is `0x`-prefixed hex. An absent `value` is 0
/// (ERC-20 calldata transactions legitimately omit it) and an absent or zero `gas` leaves the limit
/// to estimation, but a field that is present and malformed is rejected rather than defaulted.
enum USwapEvmSignableParser {
    struct ParsedTransaction {
        let transactionData: TransactionData
        let gasLimit: Int?
    }

    static func parse(_ jsonObject: [String: Any]) throws -> ParsedTransaction {
        guard let to = jsonObject["to"] as? String,
              let dataString = jsonObject["data"] as? String
        else {
            throw USwapMultiSwapProvider.SwapError.invalidTransactionData
        }

        let dataDigits = try hexDigits(dataString, allowEmpty: true)
        guard dataDigits.count.isMultiple(of: 2),
              let input = ("0x" + dataDigits).hs.hexData
        else {
            throw USwapMultiSwapProvider.SwapError.invalidTransactionData
        }

        let value: BigUInt
        if let rawValue = present(jsonObject["value"]) {
            guard let parsed = bigUInt(rawValue), parsed.bitWidth <= 256 else {
                throw USwapMultiSwapProvider.SwapError.invalidTransactionData
            }
            value = parsed
        } else {
            value = 0
        }

        let gasLimit: Int?
        if let rawGas = present(jsonObject["gas"]) {
            guard let parsed = int(rawGas), parsed >= 0 else {
                throw USwapMultiSwapProvider.SwapError.invalidTransactionData
            }
            // A zero limit is treated as absent so the estimate applies.
            gasLimit = parsed > 0 ? parsed : nil
        } else {
            gasLimit = nil
        }

        return try ParsedTransaction(
            transactionData: TransactionData(to: .init(hex: to), value: value, input: input),
            gasLimit: gasLimit
        )
    }

    private static func present(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        return value
    }

    private static func int(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            return Int(number.stringValue)
        }
        guard let string = value as? String else {
            return nil
        }
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            guard let digits = try? hexDigits(string) else {
                return nil
            }
            return Int(digits, radix: 16)
        }
        guard isAsciiDecimal(string) else {
            return nil
        }
        return Int(string)
    }

    private static func bigUInt(_ value: Any) -> BigUInt? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let text = number.stringValue
            return isAsciiDecimal(text) ? BigUInt(text) : nil
        }
        guard let string = value as? String else {
            return nil
        }
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            guard let digits = try? hexDigits(string) else {
                return nil
            }
            return BigUInt(digits, radix: 16)
        }
        guard isAsciiDecimal(string) else {
            return nil
        }
        return BigUInt(string)
    }

    private static func hexDigits(_ value: String, allowEmpty: Bool = false) throws -> String {
        guard value.hasPrefix("0x") || value.hasPrefix("0X") else {
            throw USwapMultiSwapProvider.SwapError.invalidTransactionData
        }

        let digits = String(value.dropFirst(2))
        guard allowEmpty || !digits.isEmpty,
              digits.utf8.allSatisfy(Self.isAsciiHexDigit)
        else {
            throw USwapMultiSwapProvider.SwapError.invalidTransactionData
        }

        return digits
    }

    private static func isAsciiDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func isAsciiHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }
}
