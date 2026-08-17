import Alamofire
import BigInt
import BitcoinCore
import Combine
import EvmKit
import Foundation
import HsToolKit
import MarketKit
import ObjectMapper
import SwiftUI

class BaseThorChainMultiSwapProvider: IMultiSwapProvider {
    private let assetMapExpiration: TimeInterval = 60 * 60

    let networkManager = Core.shared.networkManager
//    let networkManager = NetworkManager(logger: Logger(minLogLevel: .debug))
    let adapterManager = Core.shared.adapterManager
    private let evmBlockchainManager = Core.shared.evmBlockchainManager
    private let swapAssetStorage = Core.shared.swapAssetStorage
    private let allowanceHelper = MultiSwapAllowanceHelper()
    private let evmFeeEstimator = EvmFeeEstimator()
    private var assetMap = [String: String]()
    private let syncSubject = PassthroughSubject<Void, Never>()
    private var assetStorageId: String { "\(id)-assets-v2" }

    init() {
        assetMap = (try? swapAssetStorage.swapAssetMap(provider: assetStorageId, as: String.self)) ?? [:]
        syncAssets()
    }

    var baseUrl: String { fatalError("Must be overridden by subclass") }
    var id: String { fatalError("Must be overridden by subclass") }
    var name: String { fatalError("Must be overridden by subclass") }
    var type: SwapProviderType { fatalError("Must be overridden by subclass") }
    var icon: String { fatalError("Must be overridden by subclass") }

    var syncPublisher: AnyPublisher<Void, Never>? {
        syncSubject.eraseToAnyPublisher()
    }

    var affiliate: String? {
        nil
    }

    var affiliateBps: Int? {
        nil
    }

    var streamingInterval: Int { 1 }

    func supports(tokenIn: Token, tokenOut: Token) -> Bool {
        assetMap[tokenIn.tokenQuery.id.lowercased()] != nil && assetMap[tokenOut.tokenQuery.id.lowercased()] != nil
    }

    func quote(tokenIn: Token, tokenOut: Token, amountIn: Decimal) async throws -> MultiSwapQuote {
        let swapQuote = try await swapQuote(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn)

        let blockchainType = tokenIn.blockchainType

        switch blockchainType {
        case .arbitrumOne, .avalanche, .base, .binanceSmartChain, .ethereum:
            guard let router = swapQuote.router else {
                throw SwapError.noRouterAddress
            }

            return await EvmMultiSwapQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                allowanceState: allowanceHelper.allowanceState(spenderAddress: .init(raw: router), token: tokenIn, amount: amountIn),
                estimatedTime: estimatedTime(swapQuote, tokenOut: tokenOut)
            )
        case .bitcoin, .bitcoinCash, .dash, .dogecoin, .litecoin, .zcash:
            return ThorChainUtxoMultiSwapQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                estimatedTime: swapQuote.totalSwapSeconds,
                recommendedGasRate: swapQuote.recommendedGasRate,
                gasRateUnits: swapQuote.gasRateUnits,
                dustThreshold: swapQuote.dustThreshold
            )
        default:
            throw SwapError.unsupportedTokenIn
        }
    }

    func confirmationQuote(multiSwapQuote _: MultiSwapQuote, tokenIn: Token, tokenOut: Token, amountIn: Decimal, slippage: Decimal, recipient: String?, transactionSettings: TransactionSettings?) async throws -> SwapFinalQuote {
        let swapQuote = try await swapQuote(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippage: slippage, recipient: recipient)
        let toAddress = try await thorChainConfirmationDestination(recipient: recipient) {
            try await resolveDestination(recipient: nil, token: tokenOut)
        }

        switch tokenIn.blockchainType {
        case .arbitrumOne, .avalanche, .base, .binanceSmartChain, .ethereum:
            guard let router = swapQuote.router else {
                throw SwapError.noRouterAddress
            }

            let transactionData: TransactionData

            switch tokenIn.type {
            case .native:
                transactionData = try TransactionData(
                    to: EvmKit.Address(hex: swapQuote.inboundAddress),
                    value: tokenIn.fractionalMonetaryValue(value: amountIn),
                    input: Data(swapQuote.memo.utf8)
                )
            case let .eip20(address):
                let method = try DepositWithExpiryMethod(
                    inboundAddress: EvmKit.Address(hex: swapQuote.inboundAddress),
                    asset: EvmKit.Address(hex: address),
                    amount: tokenIn.fractionalMonetaryValue(value: amountIn),
                    memo: swapQuote.memo,
                    expiry: BigUInt(UInt64(Date().timeIntervalSince1970) + 1 * 60 * 60)
                )

                transactionData = try TransactionData(
                    to: EvmKit.Address(hex: router),
                    value: 0,
                    input: method.encodedABI()
                )
            default:
                throw SwapError.invalidTokenInType
            }

            let blockchainType = tokenIn.blockchainType
            let gasPriceData = transactionSettings?.gasPriceData
            var evmFeeData: EvmFeeData?
            var transactionError: Error?

            guard let evmKitWrapper = try evmBlockchainManager.evmKitManager(blockchainType: blockchainType).evmKitWrapper else {
                throw SwapError.noEvmKit
            }

            if let gasPriceData {
                do {
                    let _evmFeeData = try await evmFeeEstimator.estimateFee(evmKitWrapper: evmKitWrapper, transactionData: transactionData, gasPriceData: gasPriceData)
                    evmFeeData = _evmFeeData

                    try BaseEvmMultiSwapProvider.validateBalance(evmKitWrapper: evmKitWrapper, transactionData: transactionData, evmFeeData: _evmFeeData, gasPriceData: gasPriceData)
                } catch {
                    transactionError = error
                }
            }

            return EvmSwapFinalQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                transactionData: transactionData,
                transactionError: transactionError,
                slippage: slippage,
                recipient: recipient,
                estimatedTime: estimatedTime(swapQuote, tokenOut: tokenOut),
                gasPrice: gasPriceData?.userDefined,
                evmFeeData: evmFeeData,
                nonce: transactionSettings?.nonce,
                toAddress: toAddress
            )
        case .bitcoin, .bitcoinCash, .dash, .dogecoin, .litecoin:
            var transactionError: Error?
            var sendInfo: SendInfo?
            var params: SendParameters?

            guard let adapter = adapterManager.adapter(for: tokenIn) as? BitcoinBaseAdapter else {
                throw SwapError.noAdapter
            }

            do {
                let policy = try thorChainUtxoSendPolicy(
                    tokenIn: tokenIn,
                    transactionSettings: transactionSettings,
                    recommendedGasRate: swapQuote.recommendedGasRate,
                    gasRateUnits: swapQuote.gasRateUnits,
                    dustThreshold: swapQuote.dustThreshold
                )

                let value = adapter.convertToSatoshi(value: amountIn)
                if value < policy.minimumSendValue {
                    throw BitcoinCoreErrors.SendValueErrors.dust(policy.minimumSendValue)
                }

                let _params = SendParameters(
                    address: swapQuote.inboundAddress,
                    value: value,
                    feeRate: policy.feeRate,
                    memo: swapQuote.memo,
                    utxoFilters: policy.utxoFilters,
                    changeToFirstInput: true
                )

                sendInfo = try adapter.sendInfo(params: _params)
                params = _params
            } catch {
                transactionError = error
            }

            return UtxoSwapFinalQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                sendParameters: params,
                slippage: slippage,
                recipient: recipient,
                estimatedTime: swapQuote.totalSwapSeconds,
                transactionError: transactionError,
                fee: sendInfo?.fee,
                toAddress: toAddress
            )
        default:
            throw SwapError.unsupportedTokenIn
        }
    }

    private func estimatedTime(_ swapQuote: SwapQuote, tokenOut: Token) -> TimeInterval {
        let inbound = swapQuote.inboundConfirmationSeconds ?? 0
        let swap = swapQuote.streamingSwapSeconds ?? 6
        let outbound = (swapQuote.outboundDelaySeconds ?? 6) + (tokenOut.blockchainType.blockTime ?? 6)
        return inbound + swap + outbound
    }

    func preSwapView(step: MultiSwapPreSwapStep, tokenIn: Token, tokenOut _: Token, amount: Decimal, isPresented: Binding<Bool>, onSuccess: @escaping () -> Void) -> AnyView {
        allowanceHelper.preSwapView(step: step, tokenIn: tokenIn, amount: amount, isPresented: isPresented, onSuccess: onSuccess)
    }

    func track(swap: Swap) async throws -> Swap {
        var parameters: Parameters = [
            "provider": swap.providerId,
            "toAddress": swap.toAddress,
        ]

        func set(_ dict: inout Parameters, _ key: String, _ value: Any?) {
            guard let value else { return }
            dict[key] = value
        }

        set(&parameters, "inboundTxHash", swap.txHash)
        set(&parameters, "fromAsset", assetMap[swap.tokenIn.tokenQuery.id.lowercased()])
        set(&parameters, "toAsset", assetMap[swap.tokenOut.tokenQuery.id.lowercased()])

        // Native THORChain/Maya swaps aren't recorded by us → the stateless reader.
        return try await USwapMultiSwapProvider.track(swap: swap, parameters: parameters, networkManager: networkManager, endpoint: "track/thorchain")
    }

    func swapQuote(tokenIn: Token, tokenOut: Token, amountIn: Decimal, slippage: Decimal? = nil, recipient: String? = nil, params: Parameters? = nil) async throws -> SwapQuote {
        guard let assetIn = assetMap[tokenIn.tokenQuery.id.lowercased()] else {
            throw SwapError.unsupportedTokenIn
        }

        guard let assetOut = assetMap[tokenOut.tokenQuery.id.lowercased()] else {
            throw SwapError.unsupportedTokenOut
        }

        let amount = (amountIn * pow(10, 8)).roundedDown(decimal: 0)
        let destination = try await resolveDestination(recipient: recipient, token: tokenOut)

        var parameters: Parameters = [
            "from_asset": assetIn,
            "to_asset": assetOut,
            "amount": amount.description,
            "destination": destination,
            "streaming_interval": streamingInterval,
            "streaming_quantity": 0,
        ]

        if let slippage {
            parameters["liquidity_tolerance_bps"] = Int((slippage * 100).roundedDown(decimal: 0).description)
        }

        if let affiliate, let affiliateBps {
            parameters["affiliate"] = affiliate
            parameters["affiliate_bps"] = affiliateBps
        }

        if let params {
            parameters.merge(params) { _, custom in
                custom
            }
        }

        return try await networkManager.fetch(url: "\(baseUrl)/quote/swap", parameters: parameters)
    }

    func resolveDestination(recipient: String?, token: Token) async throws -> String {
        if let recipient {
            return recipient
        }

        return try await DestinationHelper.resolveDestination(token: token).address
    }

    private func syncAssets() {
        let lastSyncTimetamp = try? swapAssetStorage.lastSyncTimetamp(provider: assetStorageId)

        if let lastSyncTimetamp, Date().timeIntervalSince1970 - lastSyncTimetamp < assetMapExpiration {
            return
        }

        Task { [weak self, networkManager, baseUrl] in
            let pools: [Pool] = try await networkManager.fetch(url: "\(baseUrl)/pools")
            self?.sync(pools: pools)
        }
    }

    private func sync(pools: [Pool]) {
        var assetMap = [String: String]()

        let availablePools = pools.filter { $0.status.caseInsensitiveCompare("available") == .orderedSame }

        for pool in availablePools {
            let components = pool.asset.components(separatedBy: ".")

            guard let assetBlockchainId = components.first, let assetId = components.last else {
                continue
            }

            guard let blockchainType = blockchainType(assetBlockchainId: assetBlockchainId) else {
                continue
            }

            var tokenQueries: [TokenQuery] = []

            switch blockchainType {
            case .arbitrumOne, .avalanche, .base, .binanceSmartChain, .ethereum, .stellar:
                let components = assetId.components(separatedBy: "-")

                let tokenType: TokenType

                if components.count == 2 {
                    tokenType = .eip20(address: components[1])
                } else {
                    tokenType = .native
                }

                tokenQueries = [TokenQuery(blockchainType: blockchainType, tokenType: tokenType)]

            case .bitcoinCash, .bitcoin, .dash, .dogecoin, .zcash:
                tokenQueries = blockchainType.nativeTokenQueries

            case .litecoin:
                let supportedDerivations: [TokenType.Derivation] = [.bip44, .bip49, .bip84]
                tokenQueries = supportedDerivations.map {
                    TokenQuery(blockchainType: .litecoin, tokenType: .derived(derivation: $0))
                }

            default: ()
            }

            for tokenQuery in tokenQueries {
                assetMap[tokenQuery.id.lowercased()] = pool.asset
            }
        }

        try? swapAssetStorage.save(swapAssetMap: assetMap, provider: assetStorageId)
        try? swapAssetStorage.save(lastSyncTimestamp: Date().timeIntervalSince1970, provider: assetStorageId)

        DispatchQueue.main.async {
            self.assetMap = assetMap
            self.syncSubject.send()
        }
    }

    private func blockchainType(assetBlockchainId: String) -> BlockchainType? {
        thorChainBlockchainType(assetBlockchainId: assetBlockchainId)
    }
}

func thorChainBlockchainType(assetBlockchainId: String) -> BlockchainType? {
    switch assetBlockchainId {
    case "ARB": return .arbitrumOne
    case "AVAX": return .avalanche
    case "BASE": return .base
    case "BCH": return .bitcoinCash
    case "BSC": return .binanceSmartChain
    case "BTC": return .bitcoin
    case "DASH": return .dash
    case "DOGE": return .dogecoin
    case "ETH": return .ethereum
    case "LTC": return .litecoin
    case "ZEC": return .zcash
    default: return nil
    }
}

func thorChainUtxoFilters(blockchainType: BlockchainType) -> UtxoFilters {
    if blockchainType == .dogecoin {
        return UtxoFilters(scriptTypes: [.p2pkh], maxOutputsCountForInputs: 10)
    }

    return UtxoFilters(scriptTypes: [.p2pkh, .p2wpkhSh, .p2wpkh])
}

func thorChainConfirmationDestination(
    recipient: String?,
    walletDestination: () async throws -> String
) async rethrows -> String {
    if let recipient {
        return recipient
    }

    return try await walletDestination()
}

enum ThorChainUtxoPolicyError: Error, Equatable {
    case invalidGasRateUnits(String?)
    case invalidRecommendedGasRate(Int?)
    case invalidSelectedFeeRate(Int)
    case invalidDustThreshold(Int?)
}

// Preserves THORChain's live DOGE rate (750k) while bounding downstream size × rate arithmetic.
private let thorChainMaximumUtxoGasRate = 1_000_000
// Ten times the live DOGE threshold (1 DOGE), with ample room for other UTXO chains.
private let thorChainMaximumUtxoDustThreshold = 1_000_000_000

func effectiveThorChainFeeRate(
    blockchainType: BlockchainType,
    selectedFeeRate: Int?,
    recommendedGasRate: Int?
) throws -> Int? {
    if let selectedFeeRate, !(1 ... thorChainMaximumUtxoGasRate).contains(selectedFeeRate) {
        throw ThorChainUtxoPolicyError.invalidSelectedFeeRate(selectedFeeRate)
    }
    if let recommendedGasRate, !(1 ... thorChainMaximumUtxoGasRate).contains(recommendedGasRate) {
        throw ThorChainUtxoPolicyError.invalidRecommendedGasRate(recommendedGasRate)
    }

    guard selectedFeeRate != nil || recommendedGasRate != nil else {
        return nil
    }

    var candidates = [selectedFeeRate, recommendedGasRate].compactMap { $0 }
    if blockchainType == .dogecoin {
        candidates.append(DogecoinFeeRateProvider.minimumFeeRate)
    }
    return candidates.max()
}

struct ThorChainUtxoSendPolicy {
    let feeRate: Int
    let minimumSendValue: Int
    let utxoFilters: UtxoFilters
}

func thorChainUtxoSendPolicy(
    tokenIn: Token,
    transactionSettings: TransactionSettings?,
    recommendedGasRate: Int?,
    gasRateUnits: String?,
    dustThreshold: Int?
) throws -> ThorChainUtxoSendPolicy {
    guard gasRateUnits?.caseInsensitiveCompare("satsperbyte") == .orderedSame else {
        throw ThorChainUtxoPolicyError.invalidGasRateUnits(gasRateUnits)
    }

    guard let recommendedGasRate else {
        throw ThorChainUtxoPolicyError.invalidRecommendedGasRate(recommendedGasRate)
    }

    guard let dustThreshold, (1 ... thorChainMaximumUtxoDustThreshold).contains(dustThreshold) else {
        throw ThorChainUtxoPolicyError.invalidDustThreshold(dustThreshold)
    }

    guard let feeRate = try effectiveThorChainFeeRate(
        blockchainType: tokenIn.blockchainType,
        selectedFeeRate: transactionSettings?.satoshiPerByte,
        recommendedGasRate: recommendedGasRate
    ) else {
        throw ThorChainUtxoPolicyError.invalidRecommendedGasRate(recommendedGasRate)
    }

    return ThorChainUtxoSendPolicy(
        feeRate: feeRate,
        minimumSendValue: dustThreshold + 1,
        utxoFilters: thorChainUtxoFilters(blockchainType: tokenIn.blockchainType)
    )
}

class ThorChainUtxoMultiSwapQuote: MultiSwapQuote {
    let recommendedGasRate: Int?
    let gasRateUnits: String?
    let dustThreshold: Int?

    init(expectedBuyAmount: Decimal, estimatedTime: TimeInterval?, recommendedGasRate: Int?, gasRateUnits: String?, dustThreshold: Int?) {
        self.recommendedGasRate = recommendedGasRate
        self.gasRateUnits = gasRateUnits
        self.dustThreshold = dustThreshold
        super.init(expectedBuyAmount: expectedBuyAmount, estimatedTime: estimatedTime)
    }
}

extension BaseThorChainMultiSwapProvider {
    struct Asset {
        let id: String
        let token: Token
    }

    struct Pool: ImmutableMappable {
        let asset: String
        let status: String

        init(map: Map) throws {
            asset = try map.value("asset")
            status = try map.value("status")
        }
    }

    struct SwapQuote: ImmutableMappable {
        let inboundAddress: String
        let expectedAmountOut: Decimal
        let memo: String
        let router: String?

        let affiliateFee: Decimal
        let outboundFee: Decimal
        let liquidityFee: Decimal
        let totalFee: Decimal

        let dustThreshold: Int?
        let inboundConfirmationSeconds: TimeInterval?
        let outboundDelaySeconds: TimeInterval?
        let streamingSwapSeconds: TimeInterval?
        let totalSwapSeconds: TimeInterval?
        let recommendedGasRate: Int?
        let gasRateUnits: String?

        init(map: Map) throws {
            inboundAddress = try map.value("inbound_address")
            expectedAmountOut = try map.value("expected_amount_out", using: Transform.stringToDecimalTransform) / pow(10, 8)
            memo = try map.value("memo")
            router = try? map.value("router")

            affiliateFee = try map.value("fees.affiliate", using: Transform.stringToDecimalTransform) / pow(10, 8)
            outboundFee = try map.value("fees.outbound", using: Transform.stringToDecimalTransform) / pow(10, 8)
            liquidityFee = try map.value("fees.liquidity", using: Transform.stringToDecimalTransform) / pow(10, 8)
            totalFee = try map.value("fees.total", using: Transform.stringToDecimalTransform) / pow(10, 8)

            dustThreshold = try? map.value("dust_threshold", using: Transform.stringToIntTransform)

            inboundConfirmationSeconds = try? map.value("inbound_confirmation_seconds")
            outboundDelaySeconds = try? map.value("outbound_delay_seconds")
            streamingSwapSeconds = try? map.value("streaming_swap_seconds")
            totalSwapSeconds = try? map.value("total_swap_seconds")
            recommendedGasRate = try? map.value("recommended_gas_rate", using: Transform.stringToIntTransform)
            gasRateUnits = try? map.value("gas_rate_units")
        }
    }

    enum SwapError: Error {
        case unsupportedTokenIn
        case unsupportedTokenOut
        case noRouterAddress
        case invalidTokenInType
        case noAdapter
        case noEvmKit
    }
}

extension BaseThorChainMultiSwapProvider {
    class DepositWithExpiryMethod: ContractMethod {
        static let methodSignature = "depositWithExpiry(address,address,uint256,string,uint256)"

        let inboundAddress: EvmKit.Address
        let asset: EvmKit.Address
        let amount: BigUInt
        let memo: String
        let expiry: BigUInt

        init(inboundAddress: EvmKit.Address, asset: EvmKit.Address, amount: BigUInt, memo: String, expiry: BigUInt) {
            self.inboundAddress = inboundAddress
            self.asset = asset
            self.amount = amount
            self.memo = memo
            self.expiry = expiry

            super.init()
        }

        override var methodSignature: String { Self.methodSignature }
        override var arguments: [Any] { [inboundAddress, asset, amount, memo, expiry] }
    }
}
