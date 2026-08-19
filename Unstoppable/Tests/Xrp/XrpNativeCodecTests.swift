import Foundation
import HdWalletKit
import Testing
@testable import WalletCore

struct XrpNativeCodecTests {
    private let fixture = try! XrpGoldenFixture.load()

    @Test
    func bip44DerivationAndClassicAddressMatchSharedFixture() throws {
        let words = fixture.derivation.mnemonic.split(separator: " ").map(String.init)
        let seed = try #require(Mnemonic.seed(mnemonic: words, passphrase: fixture.derivation.bip39Passphrase))
        let privateKey = try XrpKeyDerivation.privateKey(seed: seed)
        let publicKey = try XrpKeyDerivation.compressedPublicKey(privateKey: privateKey)
        let classicAddress = try XrpAddressCodec.classicAddress(publicKey: publicKey)

        #expect(privateKey.hexUppercased == fixture.derivation.rawPrivateKeyHex)
        #expect(publicKey.hexUppercased == fixture.derivation.compressedPublicKeyHex)
        #expect(try XrpAddressCodec.accountId(classicAddress: classicAddress).hexUppercased == fixture.derivation.accountIdHex)
        #expect(classicAddress == fixture.derivation.classicAddress)
    }

    @Test
    func xAddressVectorsRoundTripAcrossBothNetworks() throws {
        let vectors = fixture.xAddressVectors + fixture.xrpl4jPublishedXAddressVectors

        for vector in vectors {
            let mainnet = try XrpAddressCodec.decode(vector.mainnetXAddress, network: .mainnet)
            #expect(mainnet == XrpDestination(classicAddress: vector.classicAddress, destinationTag: vector.tag))
            #expect(
                try XrpAddressCodec.encodeXAddress(
                    classicAddress: vector.classicAddress,
                    destinationTag: vector.tag,
                    network: .mainnet
                ) == vector.mainnetXAddress
            )

            let testnet = try XrpAddressCodec.decode(vector.testnetXAddress, network: .testnet)
            #expect(testnet == XrpDestination(classicAddress: vector.classicAddress, destinationTag: vector.tag))
            #expect(
                try XrpAddressCodec.encodeXAddress(
                    classicAddress: vector.classicAddress,
                    destinationTag: vector.tag,
                    network: .testnet
                ) == vector.testnetXAddress
            )
        }
    }

    @Test
    func destinationResolutionHonorsPresenceAndConflictContract() throws {
        for vector in fixture.destinationResolutionContract {
            if let decimalString = vector.separateTagDecimalString {
                #expect(throws: XrpCodecError.destinationTagOutOfRange) {
                    _ = try XrpAddressCodec.destinationTag(decimalString: decimalString)
                }
                continue
            }

            if vector.expected.outcome == "accept" {
                let resolved = try XrpAddressCodec.resolve(
                    vector.addressInput,
                    separateTag: vector.separateTag,
                    network: .mainnet
                )
                #expect(resolved.classicAddress == vector.expected.classicAddress)
                #expect(resolved.destinationTag == vector.expected.tag)
            } else {
                let expectedError = try #require(XrpCodecError(fixtureName: vector.expected.error))
                #expect(throws: expectedError) {
                    _ = try XrpAddressCodec.resolve(
                        vector.addressInput,
                        separateTag: vector.separateTag,
                        network: .mainnet
                    )
                }
            }
        }
    }

    @Test
    func nativePaymentSigningMatchesEverySharedGoldenVector() throws {
        let privateKey = try Data(strictHex: fixture.derivation.rawPrivateKeyHex)

        for vector in fixture.nativePaymentSigningVectors {
            let transaction = try payment(for: vector)

            let signed = try XrpPaymentCodec.sign(transaction: transaction, privateKey: privateKey)

            #expect(signed.signingPreimage.hexUppercased == vector.signingPreimageHex)
            #expect(signed.signingDigest.hexUppercased == vector.signingDigestSha512HalfHex)
            #expect(signed.signature.hexUppercased == vector.signatureDerHex)
            #expect(signed.blob.hexUppercased == vector.signedBlobHex)
            #expect(signed.transactionHash.hexUppercased == vector.transactionHashHex)
        }
    }

    @Test
    func signedPaymentDecoderCommitsToEveryGoldenTransaction() throws {
        for vector in fixture.nativePaymentSigningVectors {
            let blob = try Data(strictHex: vector.signedBlobHex)
            let expected = try payment(for: vector)

            #expect(try XrpPaymentCodec.decodeSigned(blob) == expected)
            try XrpPaymentCodec.assertCommitment(blob: blob, expected: expected)
        }
    }

    @Test
    func signedPaymentDecoderRejectsMalformedNoncanonicalAndForbiddenFields() throws {
        let vector = try #require(fixture.nativePaymentSigningVectors.first)
        let validBlob = try Data(strictHex: vector.signedBlobHex)

        #expect(throws: XrpCodecError.invalidTransactionEncoding) {
            _ = try XrpPaymentCodec.decodeSigned(Data(validBlob.dropLast()))
        }

        let bytes = [UInt8](validBlob)
        let reordered = Data(bytes[3 ..< 8] + bytes[0 ..< 3] + bytes[8...])
        #expect(throws: XrpCodecError.invalidTransactionEncoding) {
            _ = try XrpPaymentCodec.decodeSigned(reordered)
        }

        var withForbiddenSourceTag = bytes
        withForbiddenSourceTag.insert(contentsOf: [0x23, 0x00, 0x00, 0x00, 0x01], at: 8)
        #expect(throws: XrpCodecError.invalidTransactionEncoding) {
            _ = try XrpPaymentCodec.decodeSigned(Data(withForbiddenSourceTag))
        }
    }

    @Test
    func signedPaymentDecoderRejectsNonminimalAndHighSSignatures() throws {
        let vector = try #require(fixture.nativePaymentSigningVectors.first)
        let validBlob = try Data(strictHex: vector.signedBlobHex)

        let nonminimalDer = Data([0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01])
        let nonminimalBlob = try replacingSignature(in: validBlob, with: nonminimalDer)
        #expect(throws: XrpCodecError.invalidSignature) {
            _ = try XrpPaymentCodec.decodeSigned(nonminimalBlob)
        }

        let zeroScalarDer = Data([0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01])
        let zeroScalarBlob = try replacingSignature(in: validBlob, with: zeroScalarDer)
        #expect(throws: XrpCodecError.invalidSignature) {
            _ = try XrpPaymentCodec.decodeSigned(zeroScalarBlob)
        }

        let highS = Data([
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
            0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA1,
        ])
        let highSDer = Data([0x30, 0x25, 0x02, 0x01, 0x01, 0x02, 0x20]) + highS
        let highSBlob = try replacingSignature(in: validBlob, with: highSDer)
        #expect(throws: XrpCodecError.invalidSignature) {
            _ = try XrpPaymentCodec.decodeSigned(highSBlob)
        }
    }

    @Test
    func signedPaymentDecoderCryptographicallyRejectsAnotherCanonicalSignature() throws {
        let first = try #require(fixture.nativePaymentSigningVectors.first)
        let second = try #require(fixture.nativePaymentSigningVectors.dropFirst().first)
        let firstBlob = try Data(strictHex: first.signedBlobHex)
        let unrelatedLowSignature = try Data(strictHex: second.signatureDerHex)
        let forgedBlob = try replacingSignature(in: firstBlob, with: unrelatedLowSignature)

        #expect(throws: XrpCodecError.invalidSignature) {
            _ = try XrpPaymentCodec.decodeSigned(forgedBlob)
        }
    }

    @Test
    func commitmentCheckRejectsAUiFieldMismatch() throws {
        let vector = try #require(fixture.nativePaymentSigningVectors.first)
        let blob = try Data(strictHex: vector.signedBlobHex)
        let payment = try payment(for: vector)
        let mismatched = XrpNativePayment(
            account: payment.account,
            destination: payment.destination,
            amountDrops: payment.amountDrops + 1,
            feeDrops: payment.feeDrops,
            sequence: payment.sequence,
            lastLedgerSequence: payment.lastLedgerSequence,
            memo: payment.memo
        )

        #expect(throws: XrpCodecError.paymentCommitmentMismatch) {
            try XrpPaymentCodec.assertCommitment(blob: blob, expected: mismatched)
        }
    }

    @Test
    func signerRejectsAccountThatDoesNotBelongToPrivateKey() throws {
        let privateKey = try Data(strictHex: fixture.derivation.rawPrivateKeyHex)
        let vector = try #require(fixture.nativePaymentSigningVectors.first)
        let transaction = XrpNativePayment(
            account: fixture.transactionDestination.classicAddress,
            destination: XrpDestination(
                classicAddress: vector.transaction.destination,
                destinationTag: vector.transaction.destinationTag
            ),
            amountDrops: try #require(UInt64(vector.transaction.amount)),
            feeDrops: try #require(UInt64(vector.transaction.fee)),
            sequence: vector.transaction.sequence,
            lastLedgerSequence: vector.transaction.lastLedgerSequence,
            memo: nil
        )

        #expect(throws: XrpCodecError.accountPrivateKeyMismatch) {
            _ = try XrpPaymentCodec.sign(transaction: transaction, privateKey: privateKey)
        }
    }

    @Test
    func nativePaymentMemoLimitIsExactly256Utf8Bytes() throws {
        let privateKey = try Data(strictHex: fixture.derivation.rawPrivateKeyHex)
        let vector = try #require(fixture.nativePaymentSigningVectors.first)
        let base = try payment(for: vector)
        let acceptedMemo = Data(String(repeating: "é", count: 128).utf8)
        let rejectedMemo = acceptedMemo + Data("a".utf8)

        let accepted = XrpNativePayment(
            account: base.account,
            destination: base.destination,
            amountDrops: base.amountDrops,
            feeDrops: base.feeDrops,
            sequence: base.sequence,
            lastLedgerSequence: base.lastLedgerSequence,
            memo: acceptedMemo
        )
        #expect(try XrpPaymentCodec.decodeSigned(XrpPaymentCodec.sign(transaction: accepted, privateKey: privateKey).blob).memo == acceptedMemo)

        let rejected = XrpNativePayment(
            account: base.account,
            destination: base.destination,
            amountDrops: base.amountDrops,
            feeDrops: base.feeDrops,
            sequence: base.sequence,
            lastLedgerSequence: base.lastLedgerSequence,
            memo: rejectedMemo
        )
        #expect(throws: XrpCodecError.memoTooLarge) {
            _ = try XrpPaymentCodec.sign(transaction: rejected, privateKey: privateKey)
        }
    }

    private func payment(for vector: XrpGoldenFixture.SigningVector) throws -> XrpNativePayment {
        XrpNativePayment(
            account: vector.transaction.account,
            destination: XrpDestination(
                classicAddress: vector.transaction.destination,
                destinationTag: vector.transaction.destinationTag
            ),
            amountDrops: try #require(UInt64(vector.transaction.amount)),
            feeDrops: try #require(UInt64(vector.transaction.fee)),
            sequence: vector.transaction.sequence,
            lastLedgerSequence: vector.transaction.lastLedgerSequence,
            memo: try vector.transaction.memoData
        )
    }

    private func replacingSignature(in blob: Data, with signature: Data) throws -> Data {
        let publicKey = try Data(strictHex: fixture.derivation.compressedPublicKeyHex)
        let marker = [0x73, UInt8(publicKey.count)] + [UInt8](publicKey) + [0x74]
        var bytes = [UInt8](blob)
        guard let markerIndex = bytes.indices.first(where: { index in
            index + marker.count <= bytes.count && Array(bytes[index ..< index + marker.count]) == marker
        }) else {
            throw HexFixtureError.invalid
        }

        let lengthIndex = markerIndex + marker.count
        guard lengthIndex < bytes.count else { throw HexFixtureError.invalid }
        let oldLength = Int(bytes[lengthIndex])
        let signatureEnd = lengthIndex + 1 + oldLength
        guard oldLength <= 192,
              signature.count <= 192,
              signatureEnd <= bytes.count
        else {
            throw HexFixtureError.invalid
        }
        bytes.replaceSubrange(
            lengthIndex ..< signatureEnd,
            with: [UInt8(signature.count)] + [UInt8](signature)
        )
        return Data(bytes)
    }
}

private struct XrpGoldenFixture: Decodable {
    let derivation: Derivation
    let transactionDestination: TransactionDestination
    let xAddressVectors: [XAddressVector]
    let xrpl4jPublishedXAddressVectors: [XAddressVector]
    let destinationResolutionContract: [DestinationResolutionVector]
    let nativePaymentSigningVectors: [SigningVector]

    struct Derivation: Decodable {
        let mnemonic: String
        let bip39Passphrase: String
        let rawPrivateKeyHex: String
        let compressedPublicKeyHex: String
        let accountIdHex: String
        let classicAddress: String
    }

    struct TransactionDestination: Decodable {
        let classicAddress: String
    }

    struct XAddressVector: Decodable {
        let classicAddress: String
        let tag: UInt32?
        let mainnetXAddress: String
        let testnetXAddress: String
    }

    struct DestinationResolutionVector: Decodable {
        let addressInput: String
        let separateTag: UInt32?
        let separateTagDecimalString: String?
        let expected: Expected

        struct Expected: Decodable {
            let outcome: String
            let classicAddress: String?
            let tag: UInt32?
            let error: String?
        }
    }

    struct SigningVector: Decodable {
        let transaction: Transaction
        let signingPreimageHex: String
        let signingDigestSha512HalfHex: String
        let signatureDerHex: String
        let signedBlobHex: String
        let transactionHashHex: String

        struct Transaction: Decodable {
            let account: String
            let destination: String
            let amount: String
            let fee: String
            let sequence: UInt32
            let lastLedgerSequence: UInt32
            let destinationTag: UInt32?
            let memos: [MemoWrapper]?

            var memoData: Data? {
                get throws {
                    guard let hex = memos?.first?.memo.memoData else {
                        return nil
                    }
                    return try Data(strictHex: hex)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case account = "Account"
                case destination = "Destination"
                case amount = "Amount"
                case fee = "Fee"
                case sequence = "Sequence"
                case lastLedgerSequence = "LastLedgerSequence"
                case destinationTag = "DestinationTag"
                case memos = "Memos"
            }
        }

        struct MemoWrapper: Decodable {
            let memo: Memo

            private enum CodingKeys: String, CodingKey {
                case memo = "Memo"
            }
        }

        struct Memo: Decodable {
            let memoData: String

            private enum CodingKeys: String, CodingKey {
                case memoData = "MemoData"
            }
        }
    }

    static func load() throws -> Self {
        let fixtureUrl = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/thwallet-xrpl-native-golden-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(contentsOf: fixtureUrl))
    }
}

private extension XrpCodecError {
    init?(fixtureName: String?) {
        switch fixtureName {
        case "destination_tag_conflict": self = .destinationTagConflict
        case "wrong_network": self = .wrongNetwork
        case "destination_tag_out_of_range": self = .destinationTagOutOfRange
        default: return nil
        }
    }
}

private extension Data {
    init(strictHex: String) throws {
        guard strictHex.count.isMultiple(of: 2) else {
            throw HexFixtureError.invalid
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(strictHex.count / 2)
        var index = strictHex.startIndex
        while index < strictHex.endIndex {
            let next = strictHex.index(index, offsetBy: 2)
            guard let byte = UInt8(strictHex[index ..< next], radix: 16) else {
                throw HexFixtureError.invalid
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

private enum HexFixtureError: Error {
    case invalid
}
