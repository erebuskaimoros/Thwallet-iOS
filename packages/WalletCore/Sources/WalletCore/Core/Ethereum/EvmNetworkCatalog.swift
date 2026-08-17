import EvmKit
import Foundation
import MarketKit

extension BlockchainType {
    static let cronos = BlockchainType.unsupported(uid: "cronos")
    static let blast = BlockchainType.unsupported(uid: "blast")
    static let mantle = BlockchainType.unsupported(uid: "mantle")
    static let seiEvm = BlockchainType.unsupported(uid: "sei-network")
    static let hyperEvm = BlockchainType.unsupported(uid: "hyperevm")
    static let robinhood = BlockchainType.unsupported(uid: "robinhood")
}

enum EvmNetworkFeeModel: Equatable {
    case standard
    case opStack
    case mantle
}

enum EvmNetworkHistorySource: Equatable {
    case rpcOnly
    case etherscanV2
    case blockscout
}

enum EvmNetworkCatalog {
    struct Network {
        let blockchainType: BlockchainType
        let name: String
        let chainId: Int
        let nativeCoinUid: String
        let nativeName: String
        let nativeCode: String
        let rpcName: String
        let rpcUrls: [URL]
        let explorerBaseUrl: String
        let historySource: EvmNetworkHistorySource
        let gasLimit: Int
        let blockTime: TimeInterval
        let order: Int
        let feeModel: EvmNetworkFeeModel

        let nativeDecimals = 18

        var chain: EvmKit.Chain {
            EvmKit.Chain(
                id: chainId,
                coinType: 60,
                syncInterval: 15,
                gasLimit: gasLimit,
                isEIP1559Supported: true
            )
        }
    }

    static let networks: [Network] = [
        Network(
            blockchainType: .cronos,
            name: "Cronos",
            chainId: 25,
            nativeCoinUid: "crypto-com-chain",
            nativeName: "Cronos",
            nativeCode: "CRO",
            rpcName: "Cronos",
            rpcUrls: [URL(string: "https://evm.cronos.com")!],
            explorerBaseUrl: "https://explorer.cronos.com",
            historySource: .rpcOnly,
            gasLimit: 10_000_000,
            blockTime: 1,
            order: 24,
            feeModel: .standard
        ),
        Network(
            blockchainType: .blast,
            name: "Blast",
            chainId: 81_457,
            nativeCoinUid: "ethereum",
            nativeName: "Ethereum",
            nativeCode: "ETH",
            rpcName: "Blast",
            rpcUrls: [URL(string: "https://rpc.blast.io")!],
            explorerBaseUrl: "https://blastscan.io",
            historySource: .etherscanV2,
            gasLimit: 10_000_000,
            blockTime: 2,
            order: 25,
            feeModel: .opStack
        ),
        Network(
            blockchainType: .mantle,
            name: "Mantle",
            chainId: 5_000,
            nativeCoinUid: "mantle",
            nativeName: "Mantle",
            nativeCode: "MNT",
            rpcName: "Mantle",
            rpcUrls: [URL(string: "https://rpc.mantle.xyz")!],
            explorerBaseUrl: "https://mantlescan.xyz",
            historySource: .etherscanV2,
            gasLimit: 10_000_000,
            blockTime: 2,
            order: 26,
            feeModel: .mantle
        ),
        Network(
            blockchainType: .seiEvm,
            name: "Sei EVM",
            chainId: 1_329,
            nativeCoinUid: "sei-network",
            nativeName: "Sei",
            nativeCode: "SEI",
            rpcName: "Sei",
            rpcUrls: [URL(string: "https://evm-rpc.sei-apis.com")!],
            explorerBaseUrl: "https://seiscan.io",
            historySource: .etherscanV2,
            gasLimit: 10_000_000,
            blockTime: 1,
            order: 27,
            feeModel: .standard
        ),
        Network(
            blockchainType: .hyperEvm,
            name: "HyperEVM",
            chainId: 999,
            nativeCoinUid: "hyperliquid",
            nativeName: "Hyperliquid",
            nativeCode: "HYPE",
            rpcName: "HyperEVM",
            rpcUrls: [URL(string: "https://rpc.hyperliquid.xyz/evm")!],
            explorerBaseUrl: "https://hyperevmscan.io",
            historySource: .etherscanV2,
            gasLimit: 3_000_000,
            blockTime: 1,
            order: 28,
            feeModel: .standard
        ),
        Network(
            blockchainType: .robinhood,
            name: "Robinhood Chain",
            chainId: 4_663,
            nativeCoinUid: "ethereum",
            nativeName: "Ethereum",
            nativeCode: "ETH",
            rpcName: "Robinhood Chain",
            rpcUrls: [URL(string: "https://rpc.mainnet.chain.robinhood.com")!],
            explorerBaseUrl: "https://robinhoodchain.blockscout.com",
            historySource: .blockscout,
            gasLimit: 10_000_000,
            blockTime: 1,
            order: 29,
            feeModel: .standard
        ),
    ]

    private static let networkByType = Dictionary(uniqueKeysWithValues: networks.map { ($0.blockchainType, $0) })

    static let blockchainTypes = networks.map(\.blockchainType)

    static func network(blockchainType: BlockchainType) -> Network? {
        networkByType[blockchainType]
    }

    static func contains(_ blockchainType: BlockchainType) -> Bool {
        networkByType[blockchainType] != nil
    }

    static func transactionSource(blockchainType: BlockchainType, etherscanKeys: [String]) -> TransactionSource {
        guard let network = network(blockchainType: blockchainType) else {
            preconditionFailure("Missing EVM catalog network: \(blockchainType.uid)")
        }

        switch network.historySource {
        case .rpcOnly:
            return .rpcOnly(name: URL(string: network.explorerBaseUrl)?.host ?? network.name, explorerUrl: network.explorerBaseUrl)
        case .etherscanV2:
            return TransactionSource(
                name: URL(string: network.explorerBaseUrl)?.host ?? network.name,
                type: .etherscan(
                    apiBaseUrl: "https://api.etherscan.io/v2",
                    txBaseUrl: network.explorerBaseUrl,
                    apiKeys: etherscanKeys
                )
            )
        case .blockscout:
            return TransactionSource(
                name: URL(string: network.explorerBaseUrl)?.host ?? network.name,
                type: .etherscan(
                    apiBaseUrl: network.explorerBaseUrl,
                    txBaseUrl: network.explorerBaseUrl,
                    apiKeys: [""]
                )
            )
        }
    }
}
