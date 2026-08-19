import Crypto
import Foundation
import HdWalletKit
import HsCryptoKit

public enum XrpNetwork: Equatable, Sendable {
    case mainnet
    case testnet

    fileprivate var xAddressPrefix: [UInt8] {
        switch self {
        case .mainnet: return [0x05, 0x44]
        case .testnet: return [0x04, 0x93]
        }
    }
}

public struct XrpDestination: Equatable, Sendable {
    public let classicAddress: String
    public let destinationTag: UInt32?

    public init(classicAddress: String, destinationTag: UInt32?) {
        self.classicAddress = classicAddress
        self.destinationTag = destinationTag
    }
}

public enum XrpCodecError: Error, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidAddress
    case invalidChecksum
    case invalidXAddress
    case wrongNetwork
    case invalidDestinationTag
    case destinationTagOutOfRange
    case destinationTagConflict
    case invalidPayment
    case memoTooLarge
    case invalidVariableLength
    case invalidSignature
    case accountPrivateKeyMismatch
    case invalidTransactionEncoding
    case paymentCommitmentMismatch
}

public enum XrpKeyDerivation {
    public static let coinType: UInt32 = 144
    public static let derivationPath = "m/44'/144'/0'/0/0"

    public static func privateKey(seed: Data) throws -> Data {
        guard !seed.isEmpty else {
            throw XrpCodecError.invalidPrivateKey
        }

        let wallet = HDWallet(
            seed: seed,
            coinType: coinType,
            xPrivKey: HDExtendedKeyVersion.xprv.rawValue,
            purpose: .bip44,
            curve: .secp256k1
        )
        let privateKey = try wallet.privateKey(account: 0, index: 0, chain: .external).raw
        guard XrpSecp256k1.isValid(privateKey: privateKey) else {
            throw XrpCodecError.invalidPrivateKey
        }
        return privateKey
    }

    public static func compressedPublicKey(privateKey: Data) throws -> Data {
        guard XrpSecp256k1.isValid(privateKey: privateKey) else {
            throw XrpCodecError.invalidPrivateKey
        }

        let publicKey = HsCryptoKit.Crypto.publicKey(
            privateKey: privateKey,
            curve: .secp256k1,
            compressed: true
        )
        guard publicKey.count == 33, publicKey.first == 0x02 || publicKey.first == 0x03 else {
            throw XrpCodecError.invalidPublicKey
        }
        return publicKey
    }
}

public enum XrpAddressCodec {
    public static func classicAddress(publicKey: Data) throws -> String {
        guard publicKey.count == 33, publicKey.first == 0x02 || publicKey.first == 0x03 else {
            throw XrpCodecError.invalidPublicKey
        }
        return classicAddress(accountId: HsCryptoKit.Crypto.ripeMd160Sha256(publicKey))
    }

    public static func accountId(classicAddress: String) throws -> Data {
        let payload = try XrpBase58Check.decode(classicAddress)
        guard payload.count == 21, payload.first == 0x00 else {
            throw XrpCodecError.invalidAddress
        }
        return Data(payload.dropFirst())
    }

    public static func encodeXAddress(
        classicAddress: String,
        destinationTag: UInt32?,
        network: XrpNetwork
    ) throws -> String {
        let accountId = try accountId(classicAddress: classicAddress)
        var payload = Data(network.xAddressPrefix)
        payload.append(accountId)

        if let destinationTag {
            payload.append(0x01)
            payload.appendLittleEndian(destinationTag)
        } else {
            payload.append(0x00)
            payload.append(contentsOf: repeatElement(0x00, count: 4))
        }

        payload.append(contentsOf: repeatElement(0x00, count: 4))
        return XrpBase58Check.encode(payload)
    }

    public static func decode(_ xAddress: String, network: XrpNetwork) throws -> XrpDestination {
        let payload = try XrpBase58Check.decode(xAddress)
        guard payload.count == 31 else {
            throw XrpCodecError.invalidXAddress
        }

        let actualNetwork: XrpNetwork
        let networkPrefix = Array(payload.prefix(2))
        if networkPrefix == XrpNetwork.mainnet.xAddressPrefix {
            actualNetwork = .mainnet
        } else if networkPrefix == XrpNetwork.testnet.xAddressPrefix {
            actualNetwork = .testnet
        } else {
            throw XrpCodecError.invalidXAddress
        }
        guard actualNetwork == network else {
            throw XrpCodecError.wrongNetwork
        }

        let accountId = Data(payload[2 ..< 22])
        let tagFlag = payload[22]
        let tagBytes = Data(payload[23 ..< 27])
        guard payload[27 ..< 31].allSatisfy({ $0 == 0 }) else {
            throw XrpCodecError.invalidXAddress
        }

        let destinationTag: UInt32?
        switch tagFlag {
        case 0:
            guard tagBytes.allSatisfy({ $0 == 0 }) else {
                throw XrpCodecError.invalidXAddress
            }
            destinationTag = nil
        case 1:
            destinationTag = tagBytes.littleEndianUInt32
        default:
            throw XrpCodecError.invalidXAddress
        }

        return XrpDestination(
            classicAddress: classicAddress(accountId: accountId),
            destinationTag: destinationTag
        )
    }

    public static func resolve(
        _ address: String,
        separateTag: UInt32?,
        network: XrpNetwork
    ) throws -> XrpDestination {
        if (try? accountId(classicAddress: address)) != nil {
            return XrpDestination(classicAddress: address, destinationTag: separateTag)
        }

        let decoded = try decode(address, network: network)
        if let embeddedTag = decoded.destinationTag,
           let separateTag,
           embeddedTag != separateTag
        {
            throw XrpCodecError.destinationTagConflict
        }

        return XrpDestination(
            classicAddress: decoded.classicAddress,
            destinationTag: decoded.destinationTag ?? separateTag
        )
    }

    public static func destinationTag(decimalString: String) throws -> UInt32 {
        guard !decimalString.isEmpty,
              decimalString.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) })
        else {
            throw XrpCodecError.invalidDestinationTag
        }
        guard let tag = UInt32(decimalString) else {
            throw XrpCodecError.destinationTagOutOfRange
        }
        return tag
    }

    fileprivate static func classicAddress(accountId: Data) -> String {
        precondition(accountId.count == 20)
        return XrpBase58Check.encode(Data([0x00]) + accountId)
    }
}

public struct XrpNativePayment: Equatable, Sendable {
    public let account: String
    public let destination: XrpDestination
    public let amountDrops: UInt64
    public let feeDrops: UInt64
    public let sequence: UInt32
    public let lastLedgerSequence: UInt32
    public let memo: Data?

    public init(
        account: String,
        destination: XrpDestination,
        amountDrops: UInt64,
        feeDrops: UInt64,
        sequence: UInt32,
        lastLedgerSequence: UInt32,
        memo: Data?
    ) {
        self.account = account
        self.destination = destination
        self.amountDrops = amountDrops
        self.feeDrops = feeDrops
        self.sequence = sequence
        self.lastLedgerSequence = lastLedgerSequence
        self.memo = memo
    }
}

public struct XrpSignedPayment: Equatable, Sendable {
    public let signingPreimage: Data
    public let signingDigest: Data
    public let signature: Data
    public let blob: Data
    public let transactionHash: Data
}

public enum XrpPaymentCodec {
    // 100 billion XRP, expressed in drops.
    private static let maximumDrops: UInt64 = 100_000_000_000_000_000
    private static let maximumMemoBytes = 256
    private static let signingPrefix = Data([0x53, 0x54, 0x58, 0x00])
    private static let transactionIdPrefix = Data([0x54, 0x58, 0x4E, 0x00])

    public static func sign(transaction: XrpNativePayment, privateKey: Data) throws -> XrpSignedPayment {
        guard XrpSecp256k1.isValid(privateKey: privateKey) else {
            throw XrpCodecError.invalidPrivateKey
        }
        try validate(transaction: transaction)

        let publicKey = try XrpKeyDerivation.compressedPublicKey(privateKey: privateKey)
        let signingAccount = try XrpAddressCodec.classicAddress(publicKey: publicKey)
        guard signingAccount == transaction.account else {
            throw XrpCodecError.accountPrivateKeyMismatch
        }

        let unsignedTransaction = try serialize(
            transaction: transaction,
            signingPublicKey: publicKey,
            signature: nil
        )
        let signingPreimage = signingPrefix + unsignedTransaction
        let signingDigest = sha512Half(signingPreimage)
        let signature = try HsCryptoKit.Crypto.sign(data: signingDigest, privateKey: privateKey)
        guard XrpSecp256k1.isStrictLowDer(signature: signature) else {
            throw XrpCodecError.invalidSignature
        }

        let blob = try serialize(
            transaction: transaction,
            signingPublicKey: publicKey,
            signature: signature
        )
        let transactionHash = sha512Half(transactionIdPrefix + blob)

        return XrpSignedPayment(
            signingPreimage: signingPreimage,
            signingDigest: signingDigest,
            signature: signature,
            blob: blob,
            transactionHash: transactionHash
        )
    }

    /// Strictly parses the narrow, single-signature native XRP Payment shape emitted by this codec.
    /// This is a commitment decoder for locally signed blobs, not a general XRPL transaction decoder.
    public static func decodeSigned(_ blob: Data) throws -> XrpNativePayment {
        var reader = XrpByteReader(data: blob)

        try reader.consume([0x12, 0x00, 0x00]) // TransactionType: Payment
        try reader.consume([0x22, 0x80, 0x00, 0x00, 0x00]) // tfFullyCanonicalSig only
        try reader.consume([0x24])
        let sequence = try reader.readBigEndianUInt32()

        let destinationTag: UInt32?
        if reader.peek() == 0x2E {
            try reader.consume([0x2E])
            destinationTag = try reader.readBigEndianUInt32()
        } else {
            destinationTag = nil
        }

        try reader.consume([0x20, 0x1B])
        let lastLedgerSequence = try reader.readBigEndianUInt32()
        try reader.consume([0x61])
        let amountDrops = try drops(fromNativeAmount: reader.readBigEndianUInt64())
        try reader.consume([0x68])
        let feeDrops = try drops(fromNativeAmount: reader.readBigEndianUInt64())

        try reader.consume([0x73])
        let signingPublicKey = try reader.readVariableLength()
        guard signingPublicKey.count == 33,
              signingPublicKey.first == 0x02 || signingPublicKey.first == 0x03
        else {
            throw XrpCodecError.invalidPublicKey
        }

        try reader.consume([0x74])
        let signature = try reader.readVariableLength()
        guard XrpSecp256k1.isStrictLowDer(signature: signature) else {
            throw XrpCodecError.invalidSignature
        }

        try reader.consume([0x81])
        let accountId = try reader.readVariableLength()
        guard accountId.count == 20 else {
            throw XrpCodecError.invalidTransactionEncoding
        }
        try reader.consume([0x83])
        let destinationAccountId = try reader.readVariableLength()
        guard destinationAccountId.count == 20 else {
            throw XrpCodecError.invalidTransactionEncoding
        }

        let memo: Data?
        if reader.isAtEnd {
            memo = nil
        } else {
            try reader.consume([0xF9, 0xEA, 0x7D])
            memo = try reader.readVariableLength()
            try reader.consume([0xE1, 0xF1])
        }
        guard reader.isAtEnd else {
            throw XrpCodecError.invalidTransactionEncoding
        }

        let account = XrpAddressCodec.classicAddress(accountId: accountId)
        let signingAccount = try XrpAddressCodec.classicAddress(publicKey: signingPublicKey)
        guard account == signingAccount else {
            throw XrpCodecError.accountPrivateKeyMismatch
        }

        let transaction = XrpNativePayment(
            account: account,
            destination: XrpDestination(
                classicAddress: XrpAddressCodec.classicAddress(accountId: destinationAccountId),
                destinationTag: destinationTag
            ),
            amountDrops: amountDrops,
            feeDrops: feeDrops,
            sequence: sequence,
            lastLedgerSequence: lastLedgerSequence,
            memo: memo
        )
        try validate(transaction: transaction)

        // Re-encoding catches alternate VL forms, reordered fields, extra fields, and any
        // transaction shape outside the deliberately narrow Payment contract.
        let canonicalBlob = try serialize(
            transaction: transaction,
            signingPublicKey: signingPublicKey,
            signature: signature
        )
        guard canonicalBlob == blob else {
            throw XrpCodecError.invalidTransactionEncoding
        }
        let unsignedTransaction = try serialize(
            transaction: transaction,
            signingPublicKey: signingPublicKey,
            signature: nil
        )
        let digest = sha512Half(signingPrefix + unsignedTransaction)
        guard XrpSecp256k1.verify(
            signature: signature,
            digest: digest,
            publicKey: signingPublicKey
        ) else {
            throw XrpCodecError.invalidSignature
        }
        return transaction
    }

    public static func transactionHash(blob: Data) -> Data {
        sha512Half(transactionIdPrefix + blob)
    }

    public static func assertCommitment(blob: Data, expected: XrpNativePayment) throws {
        guard try decodeSigned(blob) == expected else {
            throw XrpCodecError.paymentCommitmentMismatch
        }
    }

    private static func validate(transaction: XrpNativePayment) throws {
        _ = try XrpAddressCodec.accountId(classicAddress: transaction.account)
        _ = try XrpAddressCodec.accountId(classicAddress: transaction.destination.classicAddress)

        guard transaction.amountDrops > 0,
              transaction.amountDrops <= maximumDrops,
              transaction.feeDrops > 0,
              transaction.feeDrops <= maximumDrops,
              transaction.sequence > 0,
              transaction.lastLedgerSequence > 0
        else {
            throw XrpCodecError.invalidPayment
        }

        if let memo = transaction.memo {
            guard !memo.isEmpty else {
                throw XrpCodecError.invalidPayment
            }
            guard memo.count <= maximumMemoBytes else {
                throw XrpCodecError.memoTooLarge
            }
        }
    }

    private static func serialize(
        transaction: XrpNativePayment,
        signingPublicKey: Data,
        signature: Data?
    ) throws -> Data {
        var bytes = Data()

        // TransactionType: Payment
        bytes.append(contentsOf: [0x12, 0x00, 0x00])
        // Flags: tfFullyCanonicalSig
        bytes.append(contentsOf: [0x22, 0x80, 0x00, 0x00, 0x00])
        // Sequence
        bytes.append(0x24)
        bytes.appendBigEndian(transaction.sequence)
        // DestinationTag. Presence is distinct from a value of zero.
        if let destinationTag = transaction.destination.destinationTag {
            bytes.append(0x2E)
            bytes.appendBigEndian(destinationTag)
        }
        // LastLedgerSequence (extended field header: UInt32 field 27)
        bytes.append(contentsOf: [0x20, 0x1B])
        bytes.appendBigEndian(transaction.lastLedgerSequence)
        // Amount and Fee: native positive XRP amounts.
        bytes.append(0x61)
        bytes.appendBigEndian(nativeAmount(transaction.amountDrops))
        bytes.append(0x68)
        bytes.appendBigEndian(nativeAmount(transaction.feeDrops))
        // SigningPubKey
        bytes.append(0x73)
        try bytes.appendVariableLength(signingPublicKey)
        // TxnSignature is omitted from the signing serialization.
        if let signature {
            bytes.append(0x74)
            try bytes.appendVariableLength(signature)
        }
        // Account and Destination are variable-length AccountID fields.
        bytes.append(0x81)
        try bytes.appendVariableLength(XrpAddressCodec.accountId(classicAddress: transaction.account))
        bytes.append(0x83)
        try bytes.appendVariableLength(
            XrpAddressCodec.accountId(classicAddress: transaction.destination.classicAddress)
        )

        if let memo = transaction.memo {
            // Memos array -> Memo object -> MemoData -> object end -> array end.
            bytes.append(contentsOf: [0xF9, 0xEA, 0x7D])
            try bytes.appendVariableLength(memo)
            bytes.append(contentsOf: [0xE1, 0xF1])
        }

        return bytes
    }

    private static func nativeAmount(_ drops: UInt64) -> UInt64 {
        0x4000_0000_0000_0000 | drops
    }

    private static func drops(fromNativeAmount amount: UInt64) throws -> UInt64 {
        guard amount & 0xC000_0000_0000_0000 == 0x4000_0000_0000_0000 else {
            throw XrpCodecError.invalidTransactionEncoding
        }
        let drops = amount & 0x3FFF_FFFF_FFFF_FFFF
        guard drops > 0, drops <= maximumDrops else {
            throw XrpCodecError.invalidPayment
        }
        return drops
    }

    private static func sha512Half(_ data: Data) -> Data {
        Data(SHA512.hash(data: data).prefix(32))
    }
}

private struct XrpByteReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    func peek() -> UInt8? {
        guard offset < data.count else { return nil }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }

    mutating func consume(_ expected: [UInt8]) throws {
        guard try read(expected.count) == Data(expected) else {
            throw XrpCodecError.invalidTransactionEncoding
        }
    }

    mutating func readBigEndianUInt32() throws -> UInt32 {
        let bytes = [UInt8](try read(4))
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    mutating func readBigEndianUInt64() throws -> UInt64 {
        let bytes = [UInt8](try read(8))
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func readVariableLength() throws -> Data {
        let first = Int(try readByte())
        let length: Int
        switch first {
        case 0 ... 192:
            length = first
        case 193 ... 240:
            let second = Int(try readByte())
            length = 193 + (first - 193) * 256 + second
        case 241 ... 254:
            let second = Int(try readByte())
            let third = Int(try readByte())
            length = 12_481 + (first - 241) * 65_536 + second * 256 + third
            guard length <= 918_744 else {
                throw XrpCodecError.invalidVariableLength
            }
        default:
            throw XrpCodecError.invalidVariableLength
        }
        return try read(length)
    }

    private mutating func readByte() throws -> UInt8 {
        guard let byte = peek() else {
            throw XrpCodecError.invalidTransactionEncoding
        }
        offset += 1
        return byte
    }

    private mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw XrpCodecError.invalidTransactionEncoding
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start ..< end])
    }
}

private enum XrpBase58Check {
    private static let alphabet = Array("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz")
    private static let alphabetIndex = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })

    static func encode(_ payload: Data) -> String {
        let checksum = HsCryptoKit.Crypto.doubleSha256(payload).prefix(4)
        return encodeBase58(payload + Data(checksum))
    }

    static func decode(_ string: String) throws -> Data {
        guard let decoded = decodeBase58(string), decoded.count >= 5 else {
            throw XrpCodecError.invalidAddress
        }

        let payload = Data(decoded.dropLast(4))
        let checksum = Data(decoded.suffix(4))
        let expectedChecksum = Data(HsCryptoKit.Crypto.doubleSha256(payload).prefix(4))
        guard checksum == expectedChecksum else {
            throw XrpCodecError.invalidChecksum
        }
        return payload
    }

    private static func encodeBase58(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        let leadingZeroCount = data.prefix(while: { $0 == 0 }).count
        let input = data.dropFirst(leadingZeroCount)
        var encoded = [UInt8](repeating: 0, count: input.count * 138 / 100 + 1)
        var length = 0

        for byte in input {
            var carry = Int(byte)
            var digitCount = 0
            for index in encoded.indices.reversed() where carry != 0 || digitCount < length {
                carry += 256 * Int(encoded[index])
                encoded[index] = UInt8(carry % 58)
                carry /= 58
                digitCount += 1
            }
            length = digitCount
        }

        let firstNonZero = encoded.firstIndex(where: { $0 != 0 }) ?? encoded.endIndex
        let prefix = String(repeating: String(alphabet[0]), count: leadingZeroCount)
        let body = firstNonZero == encoded.endIndex
            ? ""
            : encoded[firstNonZero...].map { String(alphabet[Int($0)]) }.joined()
        return prefix + body
    }

    private static func decodeBase58(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }

        let characters = Array(string)
        let leadingZeroCount = characters.prefix(while: { $0 == alphabet[0] }).count
        let input = characters.dropFirst(leadingZeroCount)
        var decoded = [UInt8](repeating: 0, count: input.count * 733 / 1_000 + 1)
        var length = 0

        for character in input {
            guard let alphabetValue = alphabetIndex[character] else { return nil }
            var carry = alphabetValue
            var byteCount = 0
            for index in decoded.indices.reversed() where carry != 0 || byteCount < length {
                carry += 58 * Int(decoded[index])
                decoded[index] = UInt8(carry % 256)
                carry /= 256
                byteCount += 1
            }
            guard carry == 0 else { return nil }
            length = byteCount
        }

        let firstNonZero = decoded.firstIndex(where: { $0 != 0 }) ?? decoded.endIndex
        let body = firstNonZero == decoded.endIndex ? Data() : Data(decoded[firstNonZero...])
        return Data(repeating: 0, count: leadingZeroCount) + body
    }
}

private enum XrpSecp256k1 {
    private static let order = Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ])
    private static let halfOrder = Data([
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    ])

    static func isValid(privateKey: Data) -> Bool {
        guard privateKey.count == 32,
              privateKey.contains(where: { $0 != 0 })
        else {
            return false
        }
        return privateKey.lexicographicallyPrecedes(order)
    }

    static func isStrictLowDer(signature: Data) -> Bool {
        let bytes = [UInt8](signature)
        guard (8 ... 72).contains(bytes.count),
              bytes[0] == 0x30,
              Int(bytes[1]) == bytes.count - 2,
              bytes[2] == 0x02
        else {
            return false
        }

        let rLength = Int(bytes[3])
        let rStart = 4
        let rEnd = rStart + rLength
        guard rLength > 0,
              rEnd + 2 <= bytes.count,
              isMinimalPositiveInteger(Array(bytes[rStart ..< rEnd])),
              bytes[rEnd] == 0x02
        else {
            return false
        }

        let sLength = Int(bytes[rEnd + 1])
        let sStart = rEnd + 2
        let sEnd = sStart + sLength
        guard sLength > 0,
              sEnd == bytes.count,
              isMinimalPositiveInteger(Array(bytes[sStart ..< sEnd]))
        else {
            return false
        }

        guard let paddedR = normalizedScalar(Array(bytes[rStart ..< rEnd])),
              paddedR.lexicographicallyPrecedes(order),
              let paddedS = normalizedScalar(Array(bytes[sStart ..< sEnd]))
        else {
            return false
        }
        return paddedS == halfOrder || paddedS.lexicographicallyPrecedes(halfOrder)
    }

    static func verify(signature: Data, digest: Data, publicKey: Data) -> Bool {
        guard digest.count == 32,
              publicKey.count == 33,
              let (r, s) = compactScalars(signature: signature)
        else { return false }

        let compact = r + s
        for recoveryId in UInt8(0) ... UInt8(3) {
            let recoverable = compact + Data([recoveryId])
            if HsCryptoKit.Crypto.ellipticPublicKey(
                signature: recoverable,
                of: digest,
                compressed: true
            ) == publicKey {
                return true
            }
        }
        return false
    }

    private static func compactScalars(signature: Data) -> (Data, Data)? {
        let bytes = [UInt8](signature)
        guard bytes.count >= 8,
              bytes[0] == 0x30,
              Int(bytes[1]) == bytes.count - 2,
              bytes[2] == 0x02
        else { return nil }
        let rLength = Int(bytes[3])
        let rStart = 4
        let rEnd = rStart + rLength
        guard rEnd + 2 <= bytes.count, bytes[rEnd] == 0x02 else { return nil }
        let sLength = Int(bytes[rEnd + 1])
        let sStart = rEnd + 2
        let sEnd = sStart + sLength
        guard sEnd == bytes.count,
              let r = normalizedScalar(Array(bytes[rStart ..< rEnd])),
              let s = normalizedScalar(Array(bytes[sStart ..< sEnd]))
        else { return nil }
        return (r, s)
    }

    private static func isMinimalPositiveInteger(_ integer: [UInt8]) -> Bool {
        guard let first = integer.first,
              first & 0x80 == 0,
              integer.contains(where: { $0 != 0 })
        else {
            return false
        }
        if integer.count > 1, first == 0, integer[1] & 0x80 == 0 {
            return false
        }
        return true
    }

    private static func normalizedScalar(_ integer: [UInt8]) -> Data? {
        var scalar = integer
        if scalar.first == 0 { scalar.removeFirst() }
        guard !scalar.isEmpty, scalar.count <= 32 else { return nil }
        return Data(repeating: 0, count: 32 - scalar.count) + Data(scalar)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendVariableLength(_ value: Data) throws {
        let count = value.count
        switch count {
        case 0 ... 192:
            append(UInt8(count))
        case 193 ... 12_480:
            let adjusted = count - 193
            append(UInt8(193 + adjusted / 256))
            append(UInt8(adjusted % 256))
        case 12_481 ... 918_744:
            let adjusted = count - 12_481
            append(UInt8(241 + adjusted / 65_536))
            append(UInt8((adjusted / 256) % 256))
            append(UInt8(adjusted % 256))
        default:
            throw XrpCodecError.invalidVariableLength
        }
        append(value)
    }

    var littleEndianUInt32: UInt32 {
        precondition(count == 4)
        return UInt32(self[startIndex])
            | UInt32(self[index(startIndex, offsetBy: 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: 3)]) << 24
    }
}
