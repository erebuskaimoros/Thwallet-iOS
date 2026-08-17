import EvmKit
import Foundation
import MarketKit

class WalletConnectEvmSendHandler {
    private let request: WalletConnectRequest
    private let payload: WCEthereumTransactionPayload
    private let signService: IWalletConnectSignService = Core.shared.walletConnectSessionManager.service

    let baseToken: Token
    private let transactionData: TransactionData
    private let evmKitWrapper: EvmKitWrapper
    private let decorator = EvmDecorator()
    private let evmFeeEstimator = EvmFeeEstimator()

    init(request: WalletConnectRequest, payload: WCEthereumTransactionPayload, baseToken: Token, transactionData: TransactionData, evmKitWrapper: EvmKitWrapper) {
        self.request = request
        self.payload = payload
        self.baseToken = baseToken
        self.transactionData = transactionData
        self.evmKitWrapper = evmKitWrapper
    }
}

extension WalletConnectEvmSendHandler: ISendHandler {
    var syncingText: String? {
        nil
    }

    var expirationDuration: Int? {
        nil
    }

    var initialTransactionSettings: InitialTransactionSettings? {
        let transaction = payload.transaction
        var gasPrice: GasPrice?

        if let maxFeePerGas = transaction.maxFeePerGas,
           let maxPriorityFeePerGas = transaction.maxPriorityFeePerGas
        {
            gasPrice = .eip1559(maxFeePerGas: maxFeePerGas, maxPriorityFeePerGas: maxPriorityFeePerGas)
        } else if let _gasPrice = transaction.gasPrice {
            gasPrice = .legacy(gasPrice: _gasPrice)
        }

        return .evm(gasPrice: gasPrice, nonce: transaction.nonce)
    }

    func sendData(transactionSettings: TransactionSettings?) async throws -> ISendData {
        let gasPriceData = transactionSettings?.gasPriceData
        var evmFeeData: EvmFeeData?
        var transactionError: Error?

        if let gasPriceData {
            do {
                evmFeeData = try await WalletConnectEvmFeePolicy.resolve(predefinedGasLimit: payload.transaction.gasLimit) { gasLimit in
                    try await evmFeeEstimator.estimateFee(
                        evmKitWrapper: evmKitWrapper,
                        transactionData: transactionData,
                        gasPriceData: gasPriceData,
                        predefinedGasLimit: gasLimit
                    )
                }
                if let evmFeeData {
                    try EvmSendBalancePolicy.validate(
                        balance: evmKitWrapper.evmKit.accountState?.balance ?? 0,
                        transactionValue: transactionData.value,
                        fee: evmFeeData.totalFee(gasPrice: gasPriceData.userDefined)
                    )
                }
            } catch {
                transactionError = error
            }
        }

        let transactionDecoration = evmKitWrapper.evmKit.decorate(transactionData: transactionData)
        let decoration = decorator.decorate(baseToken: baseToken, transactionData: transactionData, transactionDecoration: transactionDecoration)

        return EvmSendData(
            decoration: decoration,
            transactionData: transactionData,
            transactionError: transactionError,
            gasPrice: gasPriceData?.userDefined,
            evmFeeData: evmFeeData,
            nonce: transactionSettings?.nonce
        )
    }

    func send(data: ISendData) async throws {
        guard let data = data as? EvmSendData else {
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

        let fullTransaction = try await evmKitWrapper.send(
            transactionData: transactionData,
            gasPrice: gasPrice,
            gasLimit: gasLimit,
            privateSend: false,
            nonce: data.nonce
        )

        signService.approveRequest(id: request.id, result: fullTransaction.transaction.hash)
    }
}

enum WalletConnectEvmFeePolicy {
    static func resolve(
        predefinedGasLimit: Int?,
        estimate: (Int?) async throws -> EvmFeeData
    ) async rethrows -> EvmFeeData {
        try await estimate(predefinedGasLimit)
    }
}

extension WalletConnectEvmSendHandler {
    enum SendError: Error {
        case invalidData
        case noGasPrice
        case noGasLimit
        case noTransactionData
    }
}

extension WalletConnectEvmSendHandler {
    static func instance(request: WalletConnectRequest) -> WalletConnectEvmSendHandler? {
        guard let payload = request.payload as? WCEthereumTransactionPayload,
              let account = Core.shared.accountManager.activeAccount,
              let chainId = Int(request.chain.id),
              let evmKitWrapper = Core.shared.evmBlockchainManager.kitWrapper(chainId: chainId, account: account)
        else {
            return nil
        }

        guard let baseToken = try? Core.shared.coinManager.token(query: .init(blockchainType: evmKitWrapper.blockchainType, tokenType: .native)) else {
            return nil
        }

        let transactionData = TransactionData(
            to: payload.transaction.to,
            value: payload.transaction.value,
            input: payload.transaction.data
        )

        return WalletConnectEvmSendHandler(
            request: request,
            payload: payload,
            baseToken: baseToken,
            transactionData: transactionData,
            evmKitWrapper: evmKitWrapper
        )
    }
}
