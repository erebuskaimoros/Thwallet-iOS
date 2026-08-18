import MarketKit

enum EvmGasDataServiceKind: Equatable {
    case standard
    case opStack
    case mantle

    static func resolve(blockchainType: BlockchainType, predefinedGasLimit _: Int?) -> EvmGasDataServiceKind {
        if let feeModel = EvmNetworkCatalog.network(blockchainType: blockchainType)?.feeModel {
            switch feeModel {
            case .standard: return .standard
            case .opStack: return .opStack
            case .mantle: return .mantle
            }
        }

        return blockchainType.rollupFeeContractAddress == nil ? .standard : .opStack
    }
}
