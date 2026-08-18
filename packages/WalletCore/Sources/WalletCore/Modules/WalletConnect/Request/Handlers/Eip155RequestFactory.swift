import EvmKit
import Foundation
import WalletConnectSign

enum WalletConnectAccountPolicy {
    static func validate(requestedFrom: EvmKit.Address, activeAddress: EvmKit.Address) throws {
        guard requestedFrom == activeAddress else {
            throw WalletConnectRequest.CreationError.invalidFromAddress
        }
    }
}

class Eip155RequestFactory {
    let evmBlockchainManager: EvmBlockchainManager
    let accountManager: AccountManager

    init(evmBlockchainManager: EvmBlockchainManager, accountManager: AccountManager) {
        self.evmBlockchainManager = evmBlockchainManager
        self.accountManager = accountManager
    }
}

extension Eip155RequestFactory {
    func request(request: Request, payload: WCRequestPayload) throws -> WalletConnectRequest {
        guard let account = accountManager.activeAccount else {
            throw WalletConnectRequest.CreationError.noActiveAccount
        }

        guard let chainId = Int(request.chainId.reference),
              let blockchain = evmBlockchainManager.blockchain(chainId: chainId)
        else {
            throw WalletConnectRequest.CreationError.invalidChain
        }

        guard let address = try? AccountAddress.evmAddress(
            account: account,
            blockchainType: blockchain.type
        )
        else {
            throw WalletConnectRequest.CreationError.cantCreateAddress
        }

        if let transactionPayload = payload as? WCEthereumTransactionPayload {
            try WalletConnectAccountPolicy.validate(
                requestedFrom: transactionPayload.transaction.from,
                activeAddress: address
            )
        }

        let chain = WalletConnectRequest.Chain(id: request.chainId.reference, chainName: blockchain.name, address: address.eip55)

        return WalletConnectRequest(
            id: request.id.intValue,
            chain: chain,
            payload: payload
        )
    }
}
