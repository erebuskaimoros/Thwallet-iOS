import Combine
import MarketKit

class BalanceErrorBottomViewModel: ObservableObject {
    private let adapterManager = Core.shared.adapterManager
    private let btcBlockchainManager = Core.shared.btcBlockchainManager
    private let evmBlockchainManager = Core.shared.evmBlockchainManager
    private let reachabilityManager = Core.shared.reachabilityManager

    let item: Item

    init(wallet: Wallet, error: String) {
        var sourceType: SourceType?
        var xrpSubmission: XrpSubmission?

        if let blockchain = btcBlockchainManager.blockchain(token: wallet.token) {
            sourceType = .btc(blockchain: blockchain)
        } else if let blockchain = evmBlockchainManager.blockchain(token: wallet.token) {
            sourceType = .evm(blockchain: blockchain)
        } else if wallet.token.blockchainType == .tron {
            sourceType = .evm(blockchain: wallet.token.blockchain)
        } else if wallet.token.blockchainType == .monero {
            sourceType = .monero(blockchain: wallet.token.blockchain)
        } else if wallet.token.blockchainType == .zano {
            sourceType = .zano(blockchain: wallet.token.blockchain)
        } else if wallet.token.blockchainType == .zcash {
            sourceType = .zcash(blockchain: wallet.token.blockchain)
        } else if wallet.token.blockchainType == .ripple,
                  let adapter = adapterManager.adapter(for: wallet) as? XrpAdapter,
                  let submission = adapter.submission,
                  let message = submission.attentionMessage
        {
            xrpSubmission = XrpSubmission(
                hash: submission.hash,
                message: message,
                canAcknowledge: submission.canAcknowledge
            )
        }

        item = Item(wallet: wallet, error: error, sourceType: sourceType, xrpSubmission: xrpSubmission)
    }

    func refresh(wallet: Wallet) {
        adapterManager.refresh(wallet: wallet)
    }

    func acknowledgeXrpSubmission() async throws {
        guard let submission = item.xrpSubmission,
              submission.canAcknowledge,
              let adapter = adapterManager.adapter(for: item.wallet) as? XrpAdapter
        else { throw XrpRuntimeError.invalidResponse("XRP submission status is unavailable") }
        try await adapter.acknowledgeSubmission(hash: submission.hash)
    }
}

extension BalanceErrorBottomViewModel {
    struct Item: Identifiable {
        let wallet: Wallet
        let error: String
        let sourceType: SourceType?
        let xrpSubmission: XrpSubmission?

        var id: String {
            wallet.id
        }
    }

    struct XrpSubmission {
        let hash: String
        let message: String
        let canAcknowledge: Bool
    }

    enum SourceType {
        case btc(blockchain: Blockchain)
        case evm(blockchain: Blockchain)
        case monero(blockchain: Blockchain)
        case zano(blockchain: Blockchain)
        case zcash(blockchain: Blockchain)
    }
}
