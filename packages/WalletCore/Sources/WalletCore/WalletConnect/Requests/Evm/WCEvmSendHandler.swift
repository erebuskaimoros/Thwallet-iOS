import EvmKit
import Foundation
import HsExtensions
import MarketKit
import WalletConnectSign

// Mirrors EvmSendHandler on the same primitives, but honors the dApp's gas limit and never adjusts the value
class WCEvmSendHandler {
    private let payload: WCEvmTransactionPayload
    private let request: WCRequest
    private let evmKitWrapper: EvmKitWrapper
    private let responder: WCResponder
    private let accountName: String?
    private let decorator = EvmDecorator()
    private let evmFeeEstimator = EvmFeeEstimator()

    init(payload: WCEvmTransactionPayload, request: WCRequest, evmKitWrapper: EvmKitWrapper, responder: WCResponder, accountName: String?) {
        self.payload = payload
        self.request = request
        self.evmKitWrapper = evmKitWrapper
        self.responder = responder
        self.accountName = accountName
    }
}

extension WCEvmSendHandler: ISendHandler {
    var baseToken: Token { payload.baseToken }

    var initialTransactionSettings: InitialTransactionSettings? {
        .evm(gasPrice: payload.transaction.initialGasPrice, nonce: payload.transaction.nonce)
    }

    func sendData(transactionSettings: TransactionSettings?) async throws -> ISendData {
        // Prefer the service gas price once it arrives, but fall back to the dApp's own gas price so the
        // fee renders without waiting for the service's recommended gas price (Android parity).
        let gasPrice = transactionSettings?.gasPriceData?.userDefined ?? payload.transaction.initialGasPrice
        var evmFeeData: EvmFeeData?
        var transactionError: Error? = accountValidationError()

        if transactionError == nil, let gasPrice {
            do {
                let transactionData = payload.transaction.transactionData
                let gasPriceData = transactionSettings?.gasPriceData ?? GasPriceData(recommended: gasPrice, userDefined: gasPrice)
                // Thwallet: a dApp gas limit still goes through the estimator (kept as the signing limit) so the
                // chain cap, gas price sanity and rollup / Mantle additional fees are all applied.
                let feeData = try await WalletConnectEvmFeePolicy.resolve(predefinedGasLimit: payload.transaction.gasLimit) { gasLimit in
                    try await evmFeeEstimator.estimateFee(
                        evmKitWrapper: evmKitWrapper,
                        transactionData: transactionData,
                        gasPriceData: gasPriceData,
                        predefinedGasLimit: gasLimit
                    )
                }
                evmFeeData = feeData
                try WalletConnectEvmFeePolicy.validate(
                    gasPrice: gasPrice,
                    gasLimit: feeData.surchargedGasLimit,
                    maximumGasLimit: evmKitWrapper.evmKit.chain.gasLimit
                )
                // Fails closed: an unknown balance (account state not synced yet) is treated as 0 here. Only the
                // non-signable preview below tolerates an unknown balance.
                try EvmSendBalancePolicy.validate(
                    balance: evmKitWrapper.evmKit.accountState?.balance ?? 0,
                    transactionValue: transactionData.value,
                    fee: feeData.totalFee(gasPrice: gasPrice)
                )
            } catch {
                transactionError = error
            }
        }

        return makeSendData(gasPrice: gasPrice, evmFeeData: evmFeeData, nonce: transactionSettings?.nonce, transactionError: transactionError)
    }

    private func accountValidationError() -> Error? {
        do {
            try WalletConnectAccountPolicy.validate(requestedFrom: payload.transaction.from, activeAddress: evmKitWrapper.evmKit.address)
            return nil
        } catch {
            return error
        }
    }

    // The rows are decoded synchronously from the fixed dApp transaction; only the fee needs the network.
    // Shared by the async send path (fee estimated) and the sync preview (fee nil) so both render identically.
    private func makeSendData(gasPrice: GasPrice?, evmFeeData: EvmFeeData?, nonce: Int?, transactionError: Error?) -> ISendData {
        let transactionData = payload.transaction.transactionData

        // Same guard as EvmSendHandler: once the fee is known, block signing when the wallet can't cover
        // value + fee. The signable path (sendData) already enforces EvmSendBalancePolicy fail-closed; this
        // check covers the preview's dApp-fixed fee. Set as transactionError so EvmSendData renders the caution.
        var transactionError = transactionError
        // only assert insufficiency when the balance is actually known (accountState loaded); treating an
        // unknown balance as 0 would flash a false alert in the preview that clears after sync (and resizes
        // the fixed-size sheet)
        if transactionError == nil, let gasPrice, let evmFeeData, let evmBalance = evmKitWrapper.evmKit.accountState?.balance {
            if evmBalance < transactionData.value + evmFeeData.totalFee(gasPrice: gasPrice) {
                transactionError = AppError.ethereum(reason: .insufficientBalanceWithFee)
            }
        }

        let transactionDecoration = evmKitWrapper.evmKit.decorate(transactionData: transactionData)
        let decoration = decorator.decorate(baseToken: baseToken, transactionData: transactionData, transactionDecoration: transactionDecoration)

        let inner = EvmSendData(
            decoration: decoration,
            transactionData: transactionData,
            transactionError: transactionError,
            gasPrice: gasPrice,
            evmFeeData: evmFeeData,
            nonce: nonce
        )

        var header: WCSendHeader?
        if case .approveEip20 = decoration.type {
            header = WCSendHeader(title: "wallet_connect.allowance.title".localized, description: "wallet_connect.allowance.description".localized(request.dAppName))
        }
        return WCSendData(inner: WCEvmSendData(evmSendData: inner), request: request, header: header, accountName: accountName)
    }

    func send(data: ISendData) async throws {
        try request.checkExpiration()
        guard !request.isBlocked else { throw SendError.blocked }
        guard let data = ((data as? WCSendData)?.inner as? WCEvmSendData)?.evmSendData else {
            throw SendError.invalidData
        }
        guard let transactionData = data.transactionData else {
            throw SendError.noTransactionData
        }
        guard let gasPrice = data.gasPrice else {
            throw SendError.noGasPrice
        }
        guard let gasLimit = data.evmFeeData?.surchargedGasLimit else {
            throw SendError.noGasLimit
        }
        // Thwallet: re-check immediately before signing so no path reaches the signer with a failed check
        if let transactionError = data.transactionError {
            throw transactionError
        }
        try WalletConnectAccountPolicy.validate(requestedFrom: payload.transaction.from, activeAddress: evmKitWrapper.evmKit.address)
        try WalletConnectEvmFeePolicy.validate(gasPrice: gasPrice, gasLimit: gasLimit, maximumGasLimit: evmKitWrapper.evmKit.chain.gasLimit)

        if payload.isSignOnly {
            guard let signer = evmKitWrapper.signer else {
                throw SendError.noSigner
            }
            guard let nonce = data.nonce ?? payload.transaction.nonce else {
                throw SendError.noNonce
            }

            let signedTransaction = try signer.signedTransaction(
                address: transactionData.to,
                value: transactionData.value,
                transactionInput: transactionData.input,
                gasPrice: gasPrice,
                gasLimit: gasLimit,
                nonce: nonce
            )
            try await responder.respond(request: payload, result: AnyCodable(signedTransaction.hs.hexString))
        } else {
            let fullTransaction = try await evmKitWrapper.send(
                transactionData: transactionData,
                gasPrice: gasPrice,
                gasLimit: gasLimit,
                privateSend: false,
                nonce: data.nonce
            )
            try await responder.respond(request: payload, result: AnyCodable(fullTransaction.transaction.hash.hs.hexString))
        }
    }
}

extension WCEvmSendHandler: IWCPreviewSendHandler {
    func previewSendData() -> ISendData? {
        makeSendData(gasPrice: payload.transaction.initialGasPrice, evmFeeData: dAppFixedFeeData(), nonce: payload.transaction.nonce, transactionError: accountValidationError())
    }

    // The fee needs no network call only when the dApp fixed both gas price and gas limit; otherwise nil,
    // so the fee row stays pending (spinner) until sendData() estimates it.
    private func dAppFixedFeeData() -> EvmFeeData? {
        guard payload.transaction.initialGasPrice != nil, let gasLimit = payload.transaction.gasLimit else { return nil }
        return EvmFeeData(gasLimit: gasLimit, surchargedGasLimit: gasLimit)
    }
}

extension WCEvmSendHandler {
    enum SendError: Error {
        case blocked
        case invalidData
        case noTransactionData
        case noGasPrice
        case noGasLimit
        case noSigner
        case noNonce
    }
}
