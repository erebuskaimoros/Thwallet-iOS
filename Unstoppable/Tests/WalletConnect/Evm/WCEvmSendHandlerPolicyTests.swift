import BigInt
import EvmKit
import Foundation
import MarketKit
import Testing
import WalletConnectSign
@testable import WalletCore

// Thwallet protections carried over from the legacy WalletConnect EVM path: the request `from` is bound to the
// signing kit, the signed gas price / limit are validated against the chain cap, a dApp gas limit is still
// priced through EvmFeeEstimator, and value + full fee must be covered by a known balance.
struct WCEvmSendHandlerPolicyTests {
    private static let foreignAddress = "0x1111111111111111111111111111111111111111"

    private let baseToken = Token(
        coin: Coin(uid: "ethereum", name: "Ethereum", code: "ETH"),
        blockchain: Blockchain(type: .ethereum, name: "Ethereum", explorerUrl: nil),
        type: .native, decimals: 18
    )

    private struct Marker: Error, Equatable {}

    private func ours() throws -> EvmKit.Address {
        try EvmKit.Address(hex: WCTestFixtures.address)
    }

    private func makeKit() throws -> EvmKit.Kit {
        try EvmKit.Kit.instance(
            address: ours(), chain: .ethereum, rpcSource: .http(urls: [], auth: nil),
            transactionSource: .ethereumEtherscan(apiKeys: []), walletId: "wc-policy-test-\(UUID().uuidString)"
        )
    }

    private func makeHandler(from: String = WCTestFixtures.address, kit: EvmKit.Kit) throws -> (handler: WCEvmSendHandler, request: WCRequest, payload: WCEvmTransactionPayload) {
        let params: [[String: String]] = [[
            "from": from,
            "to": WCTestFixtures.address,
            "gas": "0x5208",
            "gasPrice": "0x3b9aca00",
            "nonce": "0x1",
            "value": "0x0",
            "data": "0x",
        ]]
        let request = try WCTestFixtures.request(method: WCEvmTransactionPayload.sendMethod, params: AnyCodable(any: params))
        let transaction = try WCEvmTransaction.parse(params: request.params)
        let payload = WCEvmTransactionPayload(request: request, transaction: transaction, blockchainType: .ethereum, baseToken: baseToken, swapInfo: nil)
        let wcRequest = WCRequest(payload: payload, verdict: .pass, dAppName: "dApp")
        let wrapper = EvmKitWrapper(blockchainType: .ethereum, evmKit: kit, merkleTransactionAdapter: nil, signer: nil)
        let handler = WCEvmSendHandler(
            payload: payload, request: wcRequest, evmKitWrapper: wrapper,
            responder: WCResponder(signClient: WCSpySignClient()), accountName: nil
        )
        return (handler, wcRequest, payload)
    }

    private func signable(request: WCRequest, payload: WCEvmTransactionPayload, gasLimit: Int, transactionError: Error? = nil) throws -> WCSendData {
        let evmSendData = try EvmSendData(
            decoration: EvmDecoration(type: .outgoingEvm(to: ours(), value: 0), customSendButtonTitle: nil),
            transactionData: payload.transaction.transactionData,
            transactionError: transactionError,
            gasPrice: .legacy(gasPrice: 1_000_000_000),
            evmFeeData: EvmFeeData(gasLimit: gasLimit, surchargedGasLimit: gasLimit),
            nonce: 1
        )
        return WCSendData(inner: WCEvmSendData(evmSendData: evmSendData), request: request)
    }

    private func evmSendData(_ data: ISendData?) -> EvmSendData? {
        ((data as? WCSendData)?.inner as? WCEvmSendData)?.evmSendData
    }

    @Test func sendRejectsFromThatIsNotTheSigningAccount() async throws {
        let (handler, request, payload) = try makeHandler(from: Self.foreignAddress, kit: makeKit())
        let data = try signable(request: request, payload: payload, gasLimit: 21000)

        await #expect(throws: WalletConnectAccountPolicy.ValidationError.invalidFromAddress) {
            try await handler.send(data: data)
        }
    }

    @Test func previewAndSyncFlagForeignFromAndCannotSend() async throws {
        let (handler, _, _) = try makeHandler(from: Self.foreignAddress, kit: makeKit())

        let preview = try #require(evmSendData(handler.previewSendData()))
        #expect(preview.transactionError as? WalletConnectAccountPolicy.ValidationError == .invalidFromAddress)
        #expect(!preview.canSend)

        let synced = try #require(evmSendData(try await handler.sendData(transactionSettings: nil)))
        #expect(synced.transactionError as? WalletConnectAccountPolicy.ValidationError == .invalidFromAddress)
        #expect(!synced.canSend)
    }

    @Test func sendRejectsGasLimitAboveChainCap() async throws {
        let kit = try makeKit()
        let (handler, request, payload) = try makeHandler(kit: kit)
        let cap = kit.chain.gasLimit
        let data = try signable(request: request, payload: payload, gasLimit: cap + 1)

        await #expect(throws: EvmGasValidationError.invalidGasLimit(cap + 1, maximum: cap)) {
            try await handler.send(data: data)
        }
    }

    @Test func sendRethrowsTransactionErrorInsteadOfSigning() async throws {
        let (handler, request, payload) = try makeHandler(kit: makeKit())
        let data = try signable(request: request, payload: payload, gasLimit: 21000, transactionError: Marker())

        await #expect(throws: Marker()) {
            try await handler.send(data: data)
        }
    }

    // The dApp gas limit is kept as the signing limit, but now goes through EvmFeeEstimator and the balance
    // policy; an unsynced kit (unknown balance) fails closed instead of being treated as affordable.
    @Test func dAppGasLimitIsEstimatedAndUnknownBalanceFailsClosed() async throws {
        let (handler, _, _) = try makeHandler(kit: makeKit())

        let synced = try #require(evmSendData(try await handler.sendData(transactionSettings: nil)))
        #expect(synced.evmFeeData?.gasLimit == 21000)
        #expect(synced.evmFeeData?.surchargedGasLimit == 21000)
        #expect(synced.transactionError != nil)
        #expect(!synced.canSend)
    }
}
