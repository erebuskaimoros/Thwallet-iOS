import BitcoinCashKit
import BitcoinCore
import BitcoinKit
import DashKit
import ECashKit
import LitecoinKit
import MarketKit
import ZODLSwiftWalletSDK

enum AddressParserFactory {
    static func parser(blockchainType: BlockchainType?, tokenType: TokenType?) -> AddressUriParser {
        AddressUriParser(blockchainType: blockchainType, tokenType: tokenType)
    }

    static func parserChainHandlers(blockchainType: BlockchainType, filter: ParserFilter? = nil, withEns: Bool = true) -> [IAddressParserItem] {
        if EvmNetworkCatalog.contains(blockchainType) {
            let evmAddressParserItem = EvmAddressParser(blockchainType: blockchainType)
            var handlers: [IAddressParserItem] = [evmAddressParserItem]

            if withEns,
               let httpSyncSource = Core.shared.evmSyncSourceManager.httpSyncSource(blockchainType: .ethereum),
               let ensAddressParserItem = EnsAddressParserItem(rpcSource: httpSyncSource.rpcSource, rawAddressParserItem: evmAddressParserItem)
            {
                handlers.append(ensAddressParserItem)
            }

            return handlers
        }

        switch blockchainType {
        case .bitcoin, .dash, .dogecoin, .litecoin, .bitcoinCash, .ecash:
            let scriptConverter = ScriptConverter()

            let specificAddressConverter: IAddressConverter?
            let base58AddressConverter: IAddressConverter
            switch blockchainType {
            case .dash:
                let network = DashKit.MainNet()
                specificAddressConverter = nil
                base58AddressConverter = Base58AddressConverter(addressVersion: network.pubKeyHash, addressScriptVersion: network.scriptHash)
            case .dogecoin:
                specificAddressConverter = nil
                base58AddressConverter = dogecoinAddressConverter()
            case .litecoin:
                let network = LitecoinKit.MainNet()
                specificAddressConverter = SegWitBech32AddressConverter(prefix: network.bech32PrefixPattern, scriptConverter: scriptConverter)
                base58AddressConverter = Base58AddressConverter(addressVersion: network.pubKeyHash, addressScriptVersion: network.scriptHash)
            case .bitcoinCash:
                let network = BitcoinCashKit.MainNet()
                specificAddressConverter = CashBech32AddressConverter(prefix: network.bech32PrefixPattern)
                base58AddressConverter = Base58AddressConverter(addressVersion: network.pubKeyHash, addressScriptVersion: network.scriptHash)
            case .ecash:
                let network = ECashKit.MainNet()
                specificAddressConverter = CashBech32AddressConverter(prefix: network.bech32PrefixPattern)
                base58AddressConverter = Base58AddressConverter(addressVersion: network.pubKeyHash, addressScriptVersion: network.scriptHash)
            default:
                let network = BitcoinKit.MainNet()
                specificAddressConverter = SegWitBech32AddressConverter(prefix: network.bech32PrefixPattern, scriptConverter: scriptConverter)
                base58AddressConverter = Base58AddressConverter(addressVersion: network.pubKeyHash, addressScriptVersion: network.scriptHash)
            }

            let addressConverterChain = AddressConverterChain()
            addressConverterChain.prepend(addressConverter: base58AddressConverter)
            if let specificAddressConverter {
                addressConverterChain.prepend(addressConverter: specificAddressConverter)
            }

            let bitcoinTypeParserItem = BitcoinAddressParserItem(blockchainType: blockchainType, parserType: .converter(addressConverterChain))

            var handlers = [IAddressParserItem]()
            handlers.append(bitcoinTypeParserItem)
            if withEns {
                if let httpSyncSource = Core.shared.evmSyncSourceManager.httpSyncSource(blockchainType: .ethereum),
                   let ensAddressParserItem = EnsAddressParserItem(rpcSource: httpSyncSource.rpcSource, rawAddressParserItem: bitcoinTypeParserItem)
                {
                    handlers.append(ensAddressParserItem)
                }
            }

            return handlers
        case .ethereum, .gnosis, .fantom, .polygon, .arbitrumOne, .avalanche, .optimism, .binanceSmartChain, .base, .zkSync, .robinhood, .arc:
            let evmAddressParserItem = EvmAddressParser(blockchainType: blockchainType)

            var handlers = [IAddressParserItem]()
            handlers.append(evmAddressParserItem)
            if withEns {
                if let httpSyncSource = Core.shared.evmSyncSourceManager.httpSyncSource(blockchainType: .ethereum),
                   let ensAddressParserItem = EnsAddressParserItem(rpcSource: httpSyncSource.rpcSource, rawAddressParserItem: evmAddressParserItem)
                {
                    handlers.append(ensAddressParserItem)
                }
            }

            return handlers
        case .tron:
            return [TronAddressParser()]
        case .thorChain:
            return [ThorChainAddressParserItem()]
        case .mayaChain:
            return [ThorChainAddressParserItem(blockchainType: .mayaChain, network: .mayaMainnet)]
        case .zcash:
            let network = ZcashNetworkBuilder.network(for: ZcashAdapter.networkType)
            let validator = ZcashAddressValidator(network: network)

            let addressType = filter.flatMap {
                switch $0 {
                case let .zCashTypes(type): return type
//                default: return nil
                }
            }
            let zcashParserItem = ZcashAddressParserItem(parserType: .validator(validator), addressType: addressType)

            var handlers: [IAddressParserItem] = [zcashParserItem]
            // name services only where ENS runs (send, contacts), as on Android; the ZNS indexer is mainnet only
            if withEns, ZcashAdapter.networkType == .mainnet {
                let resolver = ZnsResolver(networkManager: Core.shared.networkManager)
                handlers.append(ZnsAddressParserItem(resolver: resolver, rawAddressParserItem: zcashParserItem))
            }

            return handlers
        case .solana:
            return [SolanaAddressParserItem()]
        case .ton:
            return [TonAddressParserItem()]
        case .stellar:
            return [StellarAddressParserItem()]
        case .monero:
            return [MoneroAddressParserItem()]
        case .zano:
            var handlers: [IAddressParserItem] = [ZanoAddressParserItem()]
            // aliases are a name service: only where ENS runs, as on Android (ZanoChainPlugin.domainAddressHandlers)
            if withEns {
                let aliasResolver = ZanoAliasResolver(zanoNodeManager: Core.shared.zanoNodeManager, networkManager: Core.shared.networkManager)
                handlers.append(ZanoAliasAddressParserItem(resolver: aliasResolver))
            }

            return handlers
        case .xrp:
            return [XrpAddressParserItem()]
        case .near:
            return [NearAddressParserItem(rpcUrls: Core.shared.nearNodeManager.rpcUrls(network: Core.shared.nearKitManager.network))]
        case .unsupported: return []
        }
    }

    static func parserChain(blockchainType: BlockchainType?, filter: ParserFilter? = nil, withEns: Bool = true) -> AddressParserChain {
        if let blockchainType {
            return AddressParserChain().append(handlers: parserChainHandlers(blockchainType: blockchainType, filter: filter, withEns: withEns))
        }

        var handlers = [IAddressParserItem]()
        for blockchainType in BlockchainType.supported {
            handlers.append(contentsOf: parserChainHandlers(blockchainType: blockchainType, filter: filter, withEns: withEns))
        }

        return AddressParserChain().append(handlers: handlers)
    }
}

// Dogecoin mainnet deliberately supports both legacy P2PKH (`D...`) and P2SH
// (`A...`/`9...`) destinations. Single-address watch wallets further restrict
// this converter's output to P2PKH in WatchViewModel.
func dogecoinAddressConverter() -> IAddressConverter {
    Base58AddressConverter(addressVersion: 30, addressScriptVersion: 22)
}

extension AddressParserFactory {
    enum ParserFilter {
        static let zCashTransparentOnly: Self = .zCashTypes(.transparent)

        case zCashTypes(ZcashAdapter.AddressType)
        // can be updated with btc addresses (like Only Legacy or SegWit)
    }
}
