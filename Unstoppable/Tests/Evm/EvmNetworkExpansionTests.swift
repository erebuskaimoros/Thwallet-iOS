import EvmKit
import Foundation
import MarketKit
import Testing
@testable import WalletCore

struct EvmNetworkExpansionTests {
    private let expected: [(uid: String, chainId: Int, coinUid: String, code: String)] = [
        ("cronos", 25, "crypto-com-chain", "CRO"),
        ("blast", 81_457, "ethereum", "ETH"),
        ("mantle", 5_000, "mantle", "MNT"),
        ("sei-network", 1_329, "sei-network", "SEI"),
        ("hyperevm", 999, "hyperliquid", "HYPE"),
        ("robinhood", 4_663, "ethereum", "ETH"),
    ]

    @Test
    func catalogKeepsStableIdentifiersAndNativeAssets() throws {
        #expect(EvmNetworkCatalog.networks.map(\.blockchainType.uid) == expected.map(\.uid))
        #expect(EvmNetworkCatalog.networks.map(\.chainId) == expected.map(\.chainId))
        #expect(EvmNetworkCatalog.networks.map(\.nativeCoinUid) == expected.map(\.coinUid))
        #expect(EvmNetworkCatalog.networks.map(\.nativeCode) == expected.map(\.code))
        #expect(Set(EvmNetworkCatalog.networks.map(\.blockchainType)).count == expected.count)

        for network in EvmNetworkCatalog.networks {
            #expect(network.chain.coinType == 60)
            #expect(network.chain.isEIP1559Supported)
            #expect(network.nativeDecimals == 18)
            #expect(network.blockchainType.isEvm)
            #expect(BlockchainType.supported.contains(network.blockchainType))
            #expect(EvmBlockchainManager.blockchainTypes.contains(network.blockchainType))
        }
    }

    @Test
    func tokenQueryIdsRoundTripWithoutChangingPersistedUids() throws {
        for network in EvmNetworkCatalog.networks {
            let nativeQuery = TokenQuery(blockchainType: network.blockchainType, tokenType: .native)
            #expect(nativeQuery.id == "\(network.blockchainType.uid)|native")
            #expect(TokenQuery(id: nativeQuery.id) == nativeQuery)

            let contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
            let eip20Query = TokenQuery(blockchainType: network.blockchainType, tokenType: .eip20(address: contract))
            #expect(TokenQuery(id: eip20Query.id) == eip20Query)
        }
    }

    @Test
    func mnemonicAndEvmAccountsAcceptNativeAndContractTokens() throws {
        let mnemonic = AccountType.mnemonic(words: [], salt: "", bip39Compliant: true)
        let privateKey = AccountType.evmPrivateKey(data: Data(repeating: 1, count: 32))
        let address = AccountType.evmAddress(address: try EvmKit.Address(hex: "0x1111111111111111111111111111111111111111"))

        for network in EvmNetworkCatalog.networks {
            let blockchain = Blockchain(type: network.blockchainType, name: network.name, explorerUrl: nil)
            let coin = Coin(uid: network.nativeCoinUid, name: network.nativeName, code: network.nativeCode)
            let native = Token(coin: coin, blockchain: blockchain, type: .native, decimals: network.nativeDecimals)
            let contract = Token(
                coin: coin,
                blockchain: blockchain,
                type: .eip20(address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
                decimals: 6
            )

            #expect(native.protocolName == network.name)
            #expect(contract.protocolName == (network.blockchainType == .cronos ? "CRC20" : "ERC20"))

            for accountType in [mnemonic, privateKey, address] {
                #expect(accountType.supports(token: native))
                #expect(accountType.supports(token: contract))
            }
        }
    }

    @Test
    func rpcAndHistoryMappingsAreExplicitForEveryNetwork() throws {
        for network in EvmNetworkCatalog.networks {
            #expect(!network.rpcUrls.isEmpty)
            #expect(network.rpcUrls.allSatisfy { $0.scheme == "https" })

            let source = EvmNetworkCatalog.transactionSource(
                blockchainType: network.blockchainType,
                etherscanKeys: ["test-key"]
            )

            switch (network.historySource, source.type) {
            case (.rpcOnly, .rpcOnly):
                #expect(network.blockchainType == .cronos)
            case let (.etherscanV2, .etherscan(apiBaseUrl, _, apiKeys)):
                #expect(apiBaseUrl == "https://api.etherscan.io/v2")
                #expect(apiKeys == ["test-key"])
            case let (.blockscout, .etherscan(apiBaseUrl, _, _)):
                #expect(network.blockchainType == .robinhood)
                #expect(apiBaseUrl == "https://robinhoodchain.blockscout.com")
            default:
                Issue.record("History source mismatch for \(network.blockchainType.uid)")
            }

            #expect(source.transactionUrl(hash: "0x1234") == "\(network.explorerBaseUrl)/tx/0x1234")
        }
    }

    @Test
    func feeRoutingNeverDropsRollupFeesForExplicitGasLimits() throws {
        #expect(EvmNetworkCatalog.network(blockchainType: .blast)?.feeModel == .opStack)
        #expect(EvmNetworkCatalog.network(blockchainType: .mantle)?.feeModel == .mantle)

        for gasLimit in [nil, 21_000] as [Int?] {
            #expect(EvmGasDataServiceKind.resolve(blockchainType: .blast, predefinedGasLimit: gasLimit) == .opStack)
            #expect(EvmGasDataServiceKind.resolve(blockchainType: .mantle, predefinedGasLimit: gasLimit) == .mantle)
        }

        for network in EvmNetworkCatalog.networks where network.blockchainType != .blast && network.blockchainType != .mantle {
            #expect(EvmGasDataServiceKind.resolve(blockchainType: network.blockchainType, predefinedGasLimit: 21_000) == .standard)
        }
    }

    @Test
    func genericEvmCleanupAndSwapRoutingIncludeAllNetworks() throws {
        let expectedChainIds = Dictionary(uniqueKeysWithValues: expected.map { ($0.chainId.description, $0.uid) })

        for network in EvmNetworkCatalog.networks {
            // EvmAdapter clears the shared EvmKit database family by wallet id. Membership in
            // this manager is therefore the lifecycle/cleanup gate for every EVM network.
            #expect(EvmBlockchainManager.blockchainTypes.contains(network.blockchainType))
            #expect(USwapMultiSwapProvider.blockchainTypeMap[network.chainId.description] == network.blockchainType)
            #expect(expectedChainIds[network.chainId.description] == network.blockchainType.uid)
        }
    }
}
