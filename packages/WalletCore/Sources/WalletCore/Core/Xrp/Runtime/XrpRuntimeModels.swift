import Foundation

enum XrpJsonValue: Codable, Equatable, Sendable {
    case object([String: XrpJsonValue])
    case array([XrpJsonValue])
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: XrpJsonValue].self) { self = .object(value) }
        else if let value = try? container.decode([XrpJsonValue].self) { self = .array(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(UInt64.self) { self = .uint(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .uint(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension XrpJsonValue {
    var object: [String: XrpJsonValue]? { if case let .object(value) = self { value } else { nil } }
    var array: [XrpJsonValue]? { if case let .array(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }

    var uint64: UInt64? {
        switch self {
        case let .uint(value): return value
        case let .int(value) where value >= 0: return UInt64(value)
        case let .string(value): return UInt64(value)
        default: return nil
        }
    }

    var uint32: UInt32? { uint64.flatMap(UInt32.init(exactly:)) }
}

struct XrpLedgerReference: Equatable, Sendable {
    let index: UInt32
    let hash: String
}

struct XrpFeeSettings: Equatable, Sendable {
    let baseFeeDrops: UInt64
    let reserveBaseDrops: UInt64
    let reserveIncrementDrops: UInt64

    func requiredReserve(ownerCount: UInt32) throws -> UInt64 {
        let (increment, multipliedOverflow) = reserveIncrementDrops.multipliedReportingOverflow(by: UInt64(ownerCount))
        let (total, addedOverflow) = reserveBaseDrops.addingReportingOverflow(increment)
        guard !multipliedOverflow, !addedOverflow else { throw XrpRuntimeError.arithmeticOverflow }
        return total
    }
}

struct XrpAccountState: Equatable, Sendable {
    static let requireDestinationTagFlag: UInt32 = 0x0002_0000

    let address: String
    let balanceDrops: UInt64
    let sequence: UInt32
    let ownerCount: UInt32
    let flags: UInt32

    var requiresDestinationTag: Bool { flags & Self.requireDestinationTagFlag != 0 }

    func availableDrops(feeSettings: XrpFeeSettings, pendingFeeDrops: UInt64 = 0) throws -> UInt64 {
        let reserve = try feeSettings.requiredReserve(ownerCount: ownerCount)
        let (locked, overflow) = reserve.addingReportingOverflow(pendingFeeDrops)
        guard !overflow else { throw XrpRuntimeError.arithmeticOverflow }
        return balanceDrops > locked ? balanceDrops - locked : 0
    }
}

struct XrpServerState: Equatable, Sendable {
    let networkId: UInt32
    let validatedLedger: UInt32
    let completeLedgers: XrpLedgerRanges
}

struct XrpLedgerRanges: Equatable, Sendable {
    let ranges: [ClosedRange<UInt32>]

    init(_ value: String) throws {
        ranges = try value.split(separator: ",").map { component in
            let bounds = component.split(separator: "-")
            if bounds.count == 1, let value = UInt32(bounds[0]) { return value ... value }
            if bounds.count == 2, let lower = UInt32(bounds[0]), let upper = UInt32(bounds[1]), lower <= upper {
                return lower ... upper
            }
            throw XrpRuntimeError.invalidResponse("Invalid complete_ledgers")
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    func contains(_ range: ClosedRange<UInt32>) -> Bool {
        guard range.lowerBound <= range.upperBound else { return false }
        var next = range.lowerBound
        for available in ranges where available.upperBound >= next {
            guard available.lowerBound <= next else { return false }
            if available.upperBound >= range.upperBound { return true }
            guard available.upperBound < UInt32.max else { return true }
            next = available.upperBound + 1
        }
        return false
    }

    func lowerBound(ofRangeContaining ledger: UInt32) -> UInt32? {
        ranges.first(where: { $0.contains(ledger) })?.lowerBound
    }
}

enum XrpRuntimeError: Error, Equatable {
    case rpc(code: Int?, message: String)
    case accountNotFound
    case wrongNetwork(UInt32)
    case invalidResponse(String)
    case feeExceedsCap(actual: UInt64, cap: UInt64)
    case feeExceedsApproved(actual: UInt64, approved: UInt64)
    case quoteExpired
    case destinationTagRequired
    case destinationInactive(minimumDrops: UInt64)
    case insufficientBalance
    case signerUnavailable
    case pendingTransactionExists
    case submissionRequiresAttention(String)
    case memoTooLarge
    case arithmeticOverflow
}

extension XrpRuntimeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .rpc(_, message), let .invalidResponse(message): return message
        case .accountNotFound: return "The XRP account is not active on the ledger."
        case let .wrongNetwork(network): return "The XRP endpoint reported unsupported network ID \(network)."
        case let .feeExceedsCap(actual, cap): return "The XRP network fee of \(actual) drops exceeds the \(cap)-drop safety cap."
        case let .feeExceedsApproved(actual, approved): return "The XRP network fee changed from the approved \(approved) drops to \(actual) drops. Review it before sending."
        case .quoteExpired: return "The XRP swap quote expired. Request a new quote before sending."
        case .destinationTagRequired: return "The destination XRP account requires a destination tag."
        case let .destinationInactive(minimumDrops): return "The inactive XRP destination requires at least \(XrpAmount.xrp(minimumDrops)) XRP."
        case .insufficientBalance: return "The spendable XRP balance cannot cover the payment and network fee."
        case .signerUnavailable: return "This XRP account is watch-only and cannot sign payments."
        case .pendingTransactionExists: return "Wait for the previous XRP payment to validate before sending another one."
        case let .submissionRequiresAttention(message): return message
        case .memoTooLarge: return "XRP memo data must be 256 bytes or less."
        case .arithmeticOverflow: return "The XRP amount is outside the supported range."
        }
    }
}

enum XrpAmount {
    static let scale = Decimal(1_000_000)
    static let maximumDrops: UInt64 = 100_000_000_000_000_000

    static func drops(_ amount: Decimal) throws -> UInt64 {
        guard amount > 0 else { throw XrpRuntimeError.invalidResponse("XRP amount must be positive") }
        let scaled = amount * scale
        var source = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded == scaled else { throw XrpRuntimeError.invalidResponse("XRP supports at most 6 decimals") }
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: maximumDrops)) != .orderedDescending
        else {
            throw XrpRuntimeError.arithmeticOverflow
        }
        let drops = number.uint64Value
        guard Decimal(drops) == rounded else { throw XrpRuntimeError.arithmeticOverflow }
        return drops
    }

    static func xrp(_ drops: UInt64) -> Decimal { Decimal(drops) / scale }
}

struct XrpHistoryRecord: Equatable, Sendable {
    enum Direction: String, Sendable { case incoming, outgoing, selfTransfer }

    let hash: String
    let ledgerIndex: UInt32
    let timestamp: TimeInterval
    let direction: Direction
    let amountDrops: UInt64
    let feeDrops: UInt64
    let counterparty: String
    let destinationTag: UInt32?
    let resultCode: String
    let memo: Data?

    var succeeded: Bool { resultCode == "tesSUCCESS" }
}

struct XrpHistoryPage: Equatable, Sendable {
    let entries: [XrpJsonValue]
    let marker: XrpJsonValue?
    let ledgerIndexMin: UInt32
    let ledgerIndexMax: UInt32
}

struct XrpTransactionLookup: Equatable, Sendable {
    let hash: String
    let validated: Bool
    let resultCode: String?
    let ledgerIndex: UInt32?
}

struct XrpSubmitResult: Equatable, Sendable {
    let engineResult: String
    let engineResultMessage: String?
}

struct XrpSendInfo: Equatable, Sendable {
    let destination: XrpDestination
    let amountDrops: UInt64
    let feeDrops: UInt64
    let availableBalanceDrops: UInt64
    let sequence: UInt32
    let validatedLedger: UInt32
    let lastLedgerSequence: UInt32
}
