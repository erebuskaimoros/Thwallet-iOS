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
    private var assetStorageId: String { "\(id)-assets-v4" }

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
        case .ripple:
            let policy = try thorChainXrpSendPolicy(
                recommendedFeeDrops: swapQuote.recommendedGasRate,
                gasRateUnits: swapQuote.gasRateUnits,
                dustThreshold: swapQuote.dustThreshold
            )
            return ThorChainXrpMultiSwapQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                estimatedTime: swapQuote.totalSwapSeconds,
                policy: policy
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
        if tokenIn.blockchainType == .ripple {
            async let inboundsRequest: [ThorChainInboundAddress] = networkManager.fetch(url: "\(baseUrl)/inbound_addresses")
            async let poolsRequest: [Pool] = networkManager.fetch(url: "\(baseUrl)/pools")
            let (inbounds, pools) = try await (inboundsRequest, poolsRequest)
            _ = try validatedThorXrpInbound(
                quoteAddress: swapQuote.inboundAddress,
                quoteRouter: swapQuote.router,
                quoteExpiry: swapQuote.expiry,
                quoteRecommendedFee: swapQuote.recommendedGasRate,
                quoteDustThreshold: swapQuote.dustThreshold,
                inboundAddresses: inbounds,
                nowEpochSeconds: Int(Date().timeIntervalSince1970)
            )
            guard let expectedAsset = assetMap[tokenOut.tokenQuery.id.lowercased()],
                  let approvedSlippageBps = Int((slippage * 100).roundedDown(decimal: 0).description)
            else {
                throw SwapError.unsupportedTokenOut
            }
            _ = try validatedThorXrpSwapCommitment(
                memo: swapQuote.memo,
                expectedAsset: expectedAsset,
                availablePoolAssets: pools
                    .filter { $0.status.caseInsensitiveCompare("available") == .orderedSame }
                    .map(\.asset),
                expectedDestination: toAddress,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: swapQuote.expectedAmountOutBaseUnits,
                approvedSlippageBps: approvedSlippageBps,
                requestedStreamingInterval: streamingInterval,
                maxStreamingQuantity: swapQuote.maxStreamingQuantity,
                affiliateFeeBaseUnits: swapQuote.affiliateFeeBaseUnits,
                feeAsset: swapQuote.feeAsset
            )
        } else {
            _ = try validatedThorSwapMemoDestination(memo: swapQuote.memo, expectedDestination: toAddress)
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
        case .ripple:
            let policy = try thorChainXrpSendPolicy(
                recommendedFeeDrops: swapQuote.recommendedGasRate,
                gasRateUnits: swapQuote.gasRateUnits,
                dustThreshold: swapQuote.dustThreshold
            )
            let inbound = try XrpAddressCodec.resolve(
                swapQuote.inboundAddress,
                separateTag: nil,
                network: .mainnet
            )
            guard swapQuote.memo.utf8.count <= 256 else { throw XrpRuntimeError.memoTooLarge }

            var transactionError: Error?
            var sendInfo: XrpSendInfo?
            do {
                guard let adapter = adapterManager.adapter(for: tokenIn) as? ISendXrpAdapter,
                      adapter.canSign
                else { throw SwapError.noXrpAdapter }
                sendInfo = try await thorChainXrpSendInfo(
                    adapter: adapter,
                    destination: inbound.classicAddress,
                    destinationTag: inbound.destinationTag,
                    amount: amountIn,
                    memo: swapQuote.memo,
                    policy: policy
                )
            } catch {
                transactionError = error
            }

            return XrpSwapFinalQuote(
                expectedBuyAmount: swapQuote.expectedAmountOut,
                token: tokenIn,
                destination: inbound.classicAddress,
                destinationTag: inbound.destinationTag,
                memo: swapQuote.memo,
                recommendedFeeDrops: policy.recommendedFeeDrops,
                minimumSendAmountDrops: policy.minimumSendAmountDrops,
                feeDrops: sendInfo?.feeDrops,
                validUntilEpochSeconds: swapQuote.expiry,
                slippage: slippage,
                recipient: recipient,
                estimatedTime: swapQuote.totalSwapSeconds,
                transactionError: transactionError,
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

            case .bitcoinCash, .bitcoin, .dash, .dogecoin, .zcash, .ripple:
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
    case "XRP": return .ripple
    case "ZEC": return .zcash
    default: return nil
    }
}

enum ThorChainSwapMemoError: Error, Equatable {
    case malformed
    case invalidFunction
    case assetMismatch
    case destinationMismatch
    case refundAddressMismatch
    case invalidLiquidityTolerance
    case invalidExpectedOutput
    case invalidStreamingPolicy
    case tradeTargetMismatch
    case affiliateNotAllowed
    case feeAssetMismatch
}

struct ThorChainInboundAddress: ImmutableMappable, Equatable {
    let chain: String
    let address: String
    let router: String?
    let halted: Bool
    let gasRate: String
    let dustThreshold: Int?

    init(chain: String, address: String, router: String?, halted: Bool, gasRate: String, dustThreshold: Int?) {
        self.chain = chain
        self.address = address
        self.router = router
        self.halted = halted
        self.gasRate = gasRate
        self.dustThreshold = dustThreshold
    }

    init(map: Map) throws {
        chain = try map.value("chain")
        address = try map.value("address")
        router = try? map.value("router")
        halted = try map.value("halted")
        gasRate = try map.value("gas_rate")
        dustThreshold = try? map.value("dust_threshold", using: Transform.stringToIntTransform)
    }
}

enum ThorChainXrpInboundError: Error, Equatable {
    case missingUniqueInbound
    case halted
    case unexpectedRouter
    case expired
    case addressMismatch
    case feeMismatch
    case dustThresholdMismatch
}

enum ThorChainXrpPolicyError: Error, Equatable {
    case invalidGasRateUnits(String?)
    case invalidRecommendedFee(Int?)
    case invalidDustThreshold(Int?)
    case arithmeticOverflow
}

struct ThorChainXrpSendPolicy: Equatable {
    let recommendedFeeDrops: UInt64
    let minimumSendAmountDrops: UInt64
}

func thorChainXrpSendPolicy(
    recommendedFeeDrops: Int?,
    gasRateUnits: String?,
    dustThreshold: Int?
) throws -> ThorChainXrpSendPolicy {
    guard gasRateUnits?.caseInsensitiveCompare("drop") == .orderedSame else {
        throw ThorChainXrpPolicyError.invalidGasRateUnits(gasRateUnits)
    }
    guard let recommendedFeeDrops, (1 ... 100_000).contains(recommendedFeeDrops) else {
        throw ThorChainXrpPolicyError.invalidRecommendedFee(recommendedFeeDrops)
    }
    guard let dustThreshold, (1 ... 1_000_000_000).contains(dustThreshold) else {
        throw ThorChainXrpPolicyError.invalidDustThreshold(dustThreshold)
    }
    let (minimum, overflow) = dustThreshold.addingReportingOverflow(1)
    guard !overflow else { throw ThorChainXrpPolicyError.arithmeticOverflow }
    return ThorChainXrpSendPolicy(
        recommendedFeeDrops: UInt64(recommendedFeeDrops),
        minimumSendAmountDrops: UInt64(minimum)
    )
}

func thorChainXrpSendInfo(
    adapter: ISendXrpAdapter,
    destination: String,
    destinationTag: UInt32?,
    amount: Decimal,
    memo: String,
    policy: ThorChainXrpSendPolicy
) async throws -> XrpSendInfo {
    let amountDrops = try XrpAmount.drops(amount)
    guard amountDrops >= policy.minimumSendAmountDrops else {
        throw XrpSendHandler.TransactionError.belowMinimum(
            minimumDrops: policy.minimumSendAmountDrops
        )
    }
    return try await adapter.sendInfo(
        destination: destination,
        destinationTag: destinationTag,
        amount: amount,
        memo: memo,
        minimumFeeDrops: policy.recommendedFeeDrops
    )
}

func validatedThorXrpInbound(
    quoteAddress: String,
    quoteRouter: String?,
    quoteExpiry: Int,
    quoteRecommendedFee: Int?,
    quoteDustThreshold: Int?,
    inboundAddresses: [ThorChainInboundAddress],
    nowEpochSeconds: Int
) throws -> String {
    let matches = inboundAddresses.filter { $0.chain.caseInsensitiveCompare("XRP") == .orderedSame }
    guard matches.count == 1, let inbound = matches.first else {
        throw ThorChainXrpInboundError.missingUniqueInbound
    }
    guard !inbound.halted else { throw ThorChainXrpInboundError.halted }
    guard quoteRouter == nil, inbound.router == nil else { throw ThorChainXrpInboundError.unexpectedRouter }
    let (minimumExpiry, overflow) = nowEpochSeconds.addingReportingOverflow(30)
    guard !overflow, quoteExpiry > minimumExpiry else { throw ThorChainXrpInboundError.expired }
    guard quoteAddress == inbound.address else { throw ThorChainXrpInboundError.addressMismatch }
    guard quoteRecommendedFee == Int(inbound.gasRate) else { throw ThorChainXrpInboundError.feeMismatch }
    guard quoteDustThreshold == inbound.dustThreshold else { throw ThorChainXrpInboundError.dustThresholdMismatch }
    return inbound.address
}

func validatedThorSwapMemoDestination(memo: String, expectedDestination: String) throws -> String {
    let components = memo.components(separatedBy: ":")
    guard components.count >= 3 else {
        throw ThorChainSwapMemoError.malformed
    }

    let function = components[0].lowercased()
    guard function == "swap" || function == "s" || function == "=" else {
        throw ThorChainSwapMemoError.invalidFunction
    }

    // A custom refund address may follow the output address as DESTADDR/REFUNDADDR.
    // Base58 formats are case-sensitive, so the commitment boundary is deliberately exact.
    guard let destination = components[2].split(separator: "/", omittingEmptySubsequences: false).first,
          !destination.isEmpty,
          String(destination) == expectedDestination
    else {
        throw ThorChainSwapMemoError.destinationMismatch
    }

    return String(destination)
}

private let thorChainAssetShortCodes: [String: String] = [
    "THOR.RUNE": "r",
    "BTC.BTC": "b",
    "ETH.ETH": "e",
    "GAIA.ATOM": "g",
    "DOGE.DOGE": "d",
    "LTC.LTC": "l",
    "BCH.BCH": "c",
    "AVAX.AVAX": "a",
    "BSC.BNB": "s",
    "BASE.ETH": "f",
    "TRON.TRX": "tr",
    "XRP.XRP": "x",
    "SOL.SOL": "o",
    "TAO.TAO": "ta",
    "ZEC.ZEC": "z",
    "XMR.XMR": "m",
    "POL.POL": "p",
    "SUI.SUI": "u",
    "DOT.DOT": "do",
    "ADA.ADA": "ad",
]

private struct ThorChainFuzzyPoolAsset {
    let full: String
    let chain: String
    let ticker: String
    let address: String
}

private func thorChainFuzzyPoolAsset(_ asset: String) -> ThorChainFuzzyPoolAsset? {
    guard let chainSeparator = asset.firstIndex(of: "."),
          let addressSeparator = asset[asset.index(after: chainSeparator)...].firstIndex(of: "-"),
          chainSeparator != asset.startIndex,
          asset.index(after: chainSeparator) != addressSeparator,
          asset.index(after: addressSeparator) != asset.endIndex
    else {
        return nil
    }
    return ThorChainFuzzyPoolAsset(
        full: asset,
        chain: String(asset[..<chainSeparator]),
        ticker: String(asset[asset.index(after: chainSeparator) ..< addressSeparator]),
        address: String(asset[asset.index(after: addressSeparator)...])
    )
}

private func expectedThorChainMemoAsset(
    expectedAsset: String,
    availablePoolAssets: [String]
) throws -> String {
    if let shortCode = thorChainAssetShortCodes[expectedAsset.uppercased()] {
        return shortCode
    }
    guard let expected = thorChainFuzzyPoolAsset(expectedAsset) else {
        return expectedAsset
    }
    guard availablePoolAssets.contains(where: {
        $0.caseInsensitiveCompare(expectedAsset) == .orderedSame
    }) else {
        throw ThorChainSwapMemoError.assetMismatch
    }

    let otherAddresses = availablePoolAssets.compactMap(thorChainFuzzyPoolAsset).filter {
        $0.full.caseInsensitiveCompare(expected.full) != .orderedSame &&
            $0.chain.caseInsensitiveCompare(expected.chain) == .orderedSame &&
            $0.ticker.caseInsensitiveCompare(expected.ticker) == .orderedSame
    }.map(\.address)

    let prefix = "\(expected.chain).\(expected.ticker)"
    guard !otherAddresses.isEmpty else { return prefix }

    let address = expected.address
    guard address.count > 1 else { return expectedAsset }
    for offset in stride(from: address.count - 1, through: 1, by: -1) {
        let suffix = String(address.suffix(address.count - offset))
        if otherAddresses.allSatisfy({ !$0.lowercased().hasSuffix(suffix.lowercased()) }) {
            return "\(prefix)-\(suffix)"
        }
    }
    return expectedAsset
}

func validatedThorXrpSwapCommitment(
    memo: String,
    expectedAsset: String,
    availablePoolAssets: [String],
    expectedDestination: String,
    expectedRefundAddress: String?,
    expectedAmountOutBaseUnits: Decimal,
    approvedSlippageBps: Int,
    requestedStreamingInterval: Int,
    maxStreamingQuantity: Int?,
    affiliateFeeBaseUnits: Decimal,
    feeAsset: String
) throws -> String {
    guard (1 ... 9_999).contains(approvedSlippageBps) else {
        throw ThorChainSwapMemoError.invalidLiquidityTolerance
    }
    guard (0 ... 43_200).contains(requestedStreamingInterval),
          let maxStreamingQuantity,
          (1 ... 1_000_000).contains(maxStreamingQuantity)
    else {
        throw ThorChainSwapMemoError.invalidStreamingPolicy
    }
    guard affiliateFeeBaseUnits == 0 else { throw ThorChainSwapMemoError.affiliateNotAllowed }
    guard feeAsset.caseInsensitiveCompare(expectedAsset) == .orderedSame else {
        throw ThorChainSwapMemoError.feeAssetMismatch
    }

    let components = memo.components(separatedBy: ":")
    guard components.count == 4 else { throw ThorChainSwapMemoError.malformed }
    guard components[0] == "=" else { throw ThorChainSwapMemoError.invalidFunction }

    let expectedMemoAsset = try expectedThorChainMemoAsset(
        expectedAsset: expectedAsset,
        availablePoolAssets: availablePoolAssets
    )
    guard components[1].caseInsensitiveCompare(expectedAsset) == .orderedSame ||
        components[1].caseInsensitiveCompare(expectedMemoAsset) == .orderedSame
    else {
        throw ThorChainSwapMemoError.assetMismatch
    }

    let destinations = components[2].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard destinations.first == expectedDestination else {
        throw ThorChainSwapMemoError.destinationMismatch
    }
    if let expectedRefundAddress {
        guard destinations.count == 2, destinations[1] == expectedRefundAddress else {
            throw ThorChainSwapMemoError.refundAddressMismatch
        }
    } else if destinations.count != 1 {
        throw ThorChainSwapMemoError.refundAddressMismatch
    }

    let integralExpectedAmount = expectedAmountOutBaseUnits.roundedDown(decimal: 0)
    guard expectedAmountOutBaseUnits > 0, integralExpectedAmount == expectedAmountOutBaseUnits else {
        throw ThorChainSwapMemoError.invalidExpectedOutput
    }
    let limit = (
        integralExpectedAmount * Decimal(10_000 - approvedSlippageBps) / Decimal(10_000)
    ).roundedDown(decimal: 0)
    guard limit > 0 else { throw ThorChainSwapMemoError.invalidExpectedOutput }
    let limitString = NSDecimalNumber(decimal: limit).stringValue
    let expectedTradeTarget: String
    if requestedStreamingInterval > 0 {
        // Thornode preserves an explicitly requested interval and auto quantity as /I/0.
        expectedTradeTarget = "\(limitString)/\(requestedStreamingInterval)/0"
    } else if maxStreamingQuantity > 1 {
        // Rapid auto-streaming rewrites quantity only when more than one sub-swap is useful.
        expectedTradeTarget = "\(limitString)/0/\(maxStreamingQuantity)"
    } else {
        expectedTradeTarget = limitString
    }
    guard components[3] == expectedTradeTarget else {
        throw ThorChainSwapMemoError.tradeTargetMismatch
    }

    return expectedDestination
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

final class ThorChainXrpMultiSwapQuote: MultiSwapQuote {
    let policy: ThorChainXrpSendPolicy

    init(expectedBuyAmount: Decimal, estimatedTime: TimeInterval?, policy: ThorChainXrpSendPolicy) {
        self.policy = policy
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
        let expectedAmountOutBaseUnits: Decimal
        let memo: String
        let router: String?
        let expiry: Int

        let affiliateFee: Decimal
        let affiliateFeeBaseUnits: Decimal
        let feeAsset: String
        let outboundFee: Decimal
        let liquidityFee: Decimal
        let totalFee: Decimal

        let dustThreshold: Int?
        let inboundConfirmationSeconds: TimeInterval?
        let outboundDelaySeconds: TimeInterval?
        let streamingSwapSeconds: TimeInterval?
        let totalSwapSeconds: TimeInterval?
        let maxStreamingQuantity: Int?
        let recommendedGasRate: Int?
        let gasRateUnits: String?

        init(map: Map) throws {
            inboundAddress = try map.value("inbound_address")
            expectedAmountOutBaseUnits = try map.value("expected_amount_out", using: Transform.stringToDecimalTransform)
            expectedAmountOut = expectedAmountOutBaseUnits / pow(10, 8)
            memo = try map.value("memo")
            router = try? map.value("router")
            expiry = try map.value("expiry")

            affiliateFeeBaseUnits = try map.value("fees.affiliate", using: Transform.stringToDecimalTransform)
            affiliateFee = affiliateFeeBaseUnits / pow(10, 8)
            feeAsset = try map.value("fees.asset")
            outboundFee = try map.value("fees.outbound", using: Transform.stringToDecimalTransform) / pow(10, 8)
            liquidityFee = try map.value("fees.liquidity", using: Transform.stringToDecimalTransform) / pow(10, 8)
            totalFee = try map.value("fees.total", using: Transform.stringToDecimalTransform) / pow(10, 8)

            dustThreshold = try? map.value("dust_threshold", using: Transform.stringToIntTransform)

            inboundConfirmationSeconds = try? map.value("inbound_confirmation_seconds")
            outboundDelaySeconds = try? map.value("outbound_delay_seconds")
            streamingSwapSeconds = try? map.value("streaming_swap_seconds")
            totalSwapSeconds = try? map.value("total_swap_seconds")
            maxStreamingQuantity = try? map.value("max_streaming_quantity")
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
        case noXrpAdapter
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
