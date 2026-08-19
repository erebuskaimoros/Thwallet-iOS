import Foundation
import MarketKit
import Testing
@testable import WalletCore

struct XrpThorChainSwapTests {
    @Test
    func finalQuoteExpiryIsRecheckedAfterLivePreflightBeforeSigning() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ relativePath: String) throws -> String {
            try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
        }

        let quoteSource = try source("packages/WalletCore/Sources/WalletCore/Modules/MultiSwap/Providers/XrpSwapFinalQuote.swift")
        let providerSource = try source("packages/WalletCore/Sources/WalletCore/Modules/MultiSwap/Providers/ThorChain/BaseThorChainMultiSwapProvider.swift")
        let sendHandlerSource = try source("packages/WalletCore/Sources/WalletCore/Modules/MultiSwap/MultiSwapSendHandler.swift")
        let adapterSource = try source("packages/WalletCore/Sources/WalletCore/Core/Adapters/XrpAdapter.swift")
        let runtimeSource = try source("packages/WalletCore/Sources/WalletCore/Core/Xrp/Runtime/XrpKit.swift")

        #expect(quoteSource.contains("let validUntilEpochSeconds"))
        #expect(providerSource.contains("validUntilEpochSeconds: swapQuote.expiry"))
        #expect(sendHandlerSource.contains("validUntilEpochSeconds: quote.validUntilEpochSeconds"))
        #expect(adapterSource.contains("validUntilEpochSeconds: Int"))

        let livePreflight = try #require(runtimeSource.range(of: "let info = try await sendInfo("))
        let signing = try #require(
            runtimeSource.range(
                of: "let signed = try XrpPaymentCodec.sign",
                range: livePreflight.upperBound ..< runtimeSource.endIndex
            )
        )
        let expiryRecheck = runtimeSource.range(
            of: "validUntilEpochSeconds",
            range: livePreflight.upperBound ..< signing.lowerBound
        )
        #expect(expiryRecheck != nil)
    }

    @Test
    func swapMemoBindsEveryQuotedXrpPaymentCommitment() throws {
        let expected = "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"
        #expect(
            try validatedThorXrpSwapCommitment(
                memo: "=:b:\(expected):6109",
                expectedAsset: "BTC.BTC",
                availablePoolAssets: ["BTC.BTC"],
                expectedDestination: expected,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 6171,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 0,
                feeAsset: "BTC.BTC"
            ) == expected
        )

        #expect(
            try validatedThorXrpSwapCommitment(
                memo: "=:b:\(expected):6109/0/5",
                expectedAsset: "BTC.BTC",
                availablePoolAssets: ["BTC.BTC"],
                expectedDestination: expected,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 6171,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 5,
                affiliateFeeBaseUnits: 0,
                feeAsset: "BTC.BTC"
            ) == expected
        )

        #expect(
            try validatedThorXrpSwapCommitment(
                memo: "=:b:\(expected):6109/1/0",
                expectedAsset: "BTC.BTC",
                availablePoolAssets: ["BTC.BTC"],
                expectedDestination: expected,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 6171,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 1,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 0,
                feeAsset: "BTC.BTC"
            ) == expected
        )

        let invalidMemos = [
            "SWAP:b:\(expected):6109",
            "=:ETH.ETH:\(expected):6109",
            "=:b:\(expected.lowercased()):6109",
            "=:b:\(expected)/rRefundAddress:6109",
            "=:b:\(expected):0",
            "=:b:\(expected):6110",
            "=:b:\(expected):6109/1/5",
            "=:b:\(expected):6109/0/4",
            "=:b:\(expected):6109:dx:30",
            "=:b:\(expected):6109::",
        ]
        for memo in invalidMemos {
            #expect(throws: ThorChainSwapMemoError.self) {
                try validatedThorXrpSwapCommitment(
                    memo: memo,
                    expectedAsset: "BTC.BTC",
                    availablePoolAssets: ["BTC.BTC"],
                    expectedDestination: expected,
                    expectedRefundAddress: nil,
                    expectedAmountOutBaseUnits: 6171,
                    approvedSlippageBps: 100,
                    requestedStreamingInterval: 0,
                    maxStreamingQuantity: 5,
                    affiliateFeeBaseUnits: 0,
                    feeAsset: "BTC.BTC"
                )
            }
        }

        #expect(throws: ThorChainSwapMemoError.self) {
            try validatedThorXrpSwapCommitment(
                memo: "=:b:\(expected):6109",
                expectedAsset: "BTC.BTC",
                availablePoolAssets: ["BTC.BTC"],
                expectedDestination: expected,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 6171,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 1,
                feeAsset: "BTC.BTC"
            )
        }
        #expect(throws: ThorChainSwapMemoError.self) {
            try validatedThorXrpSwapCommitment(
                memo: "=:b:\(expected):6109",
                expectedAsset: "BTC.BTC",
                availablePoolAssets: ["BTC.BTC"],
                expectedDestination: expected,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 6171,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 0,
                feeAsset: "ETH.ETH"
            )
        }
    }

    @Test
    func contractAssetMemoRequiresUniqueThornodeFuzzySuffix() throws {
        let destination = "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"
        let expectedAsset = "ETH.USDC-0X1234ABCD"
        let pools = [expectedAsset, "ETH.USDC-0X9999ABCD"]

        #expect(
            try validatedThorXrpSwapCommitment(
                memo: "=:ETH.USDC-4ABCD:\(destination):990",
                expectedAsset: expectedAsset,
                availablePoolAssets: pools,
                expectedDestination: destination,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 1000,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 0,
                feeAsset: expectedAsset
            ) == destination
        )
        #expect(throws: ThorChainSwapMemoError.self) {
            try validatedThorXrpSwapCommitment(
                memo: "=:ETH.USDC:\(destination):990",
                expectedAsset: expectedAsset,
                availablePoolAssets: pools,
                expectedDestination: destination,
                expectedRefundAddress: nil,
                expectedAmountOutBaseUnits: 1000,
                approvedSlippageBps: 100,
                requestedStreamingInterval: 0,
                maxStreamingQuantity: 1,
                affiliateFeeBaseUnits: 0,
                feeAsset: expectedAsset
            )
        }
    }

    @Test
    func quoteIsBoundToCurrentUnhaltedXrpInbound() throws {
        let inbound = ThorChainInboundAddress(
            chain: "XRP",
            address: "rg24swjNUoMbFenctAcieM1VXKaa3EP8d",
            router: nil,
            halted: false,
            gasRate: "600",
            dustThreshold: 100_000_000
        )

        #expect(
            try validatedThorXrpInbound(
                quoteAddress: inbound.address,
                quoteRouter: nil,
                quoteExpiry: 1_800_000_000,
                quoteRecommendedFee: 600,
                quoteDustThreshold: 100_000_000,
                inboundAddresses: [inbound],
                nowEpochSeconds: 1_799_999_900
            ) == inbound.address
        )

        for invalid in [
            inbound.with(halted: true),
            inbound.with(address: "rDifferent"),
            inbound.with(router: "0xRouter"),
            inbound.with(gasRate: "1"),
            inbound.with(dustThreshold: 1),
        ] {
            #expect(throws: ThorChainXrpInboundError.self) {
                try validatedThorXrpInbound(
                    quoteAddress: inbound.address,
                    quoteRouter: nil,
                    quoteExpiry: 1_800_000_000,
                    quoteRecommendedFee: 600,
                    quoteDustThreshold: 100_000_000,
                    inboundAddresses: [invalid],
                    nowEpochSeconds: 1_799_999_900
                )
            }
        }
    }

    @Test
    func quoteUsesBoundedDropFeeAndDustPolicy() throws {
        #expect(thorChainBlockchainType(assetBlockchainId: "XRP") == .ripple)
        let live = try thorChainXrpSendPolicy(
            recommendedFeeDrops: 600,
            gasRateUnits: "DrOp",
            dustThreshold: 100_000_000
        )
        #expect(live.recommendedFeeDrops == 600)
        #expect(live.minimumSendAmountDrops == 100_000_001)

        for unit in [nil, "", " drop ", "drops", "satsperbyte"] as [String?] {
            #expect(throws: ThorChainXrpPolicyError.self) {
                try thorChainXrpSendPolicy(recommendedFeeDrops: 600, gasRateUnits: unit, dustThreshold: 100_000_000)
            }
        }
        for fee in [nil, 0, -1, 100_001, Int.max] as [Int?] {
            #expect(throws: ThorChainXrpPolicyError.self) {
                try thorChainXrpSendPolicy(recommendedFeeDrops: fee, gasRateUnits: "drop", dustThreshold: 100_000_000)
            }
        }
        for dust in [nil, 0, -1, 1_000_000_001, Int.max] as [Int?] {
            #expect(throws: ThorChainXrpPolicyError.self) {
                try thorChainXrpSendPolicy(recommendedFeeDrops: 600, gasRateUnits: "drop", dustThreshold: dust)
            }
        }
    }

    @Test
    func confirmationUsesLiveXrpPreflightFeeInsteadOfQuotedMinimum() async throws {
        let adapter = XrpSwapAdapterSpy(liveFeeDrops: 900)
        let policy = ThorChainXrpSendPolicy(
            recommendedFeeDrops: 300,
            minimumSendAmountDrops: 100_000_001
        )

        let info = try await thorChainXrpSendInfo(
            adapter: adapter,
            destination: "r3AgF9mMBFtaLhKcg96weMhbbEFLZ3mx17",
            destinationTag: 0,
            amount: Decimal(101),
            memo: "=:THOR.RUNE:rDestination",
            policy: policy
        )

        #expect(info.feeDrops == 900)
        let request = await adapter.request
        #expect(request?.destinationTag == 0)
        #expect(request?.minimumFeeDrops == 300)
        #expect(request?.memo == "=:THOR.RUNE:rDestination")
    }

    @Test
    func uSwapCannotExposeXrpWithoutTypedDestinationTagAttachments() {
        #expect(USwapMultiSwapProvider.blockchainTypeMap["ripple"] == nil)
        #expect(USwapMultiSwapProvider.blockchainTypeMap["xrp"] == nil)
        #expect(USwapMultiSwapProvider.blockchainTypeMap.values.contains(.ripple) == false)
    }
}

private actor XrpSwapAdapterSpy: ISendXrpAdapter {
    struct Request {
        let destination: String
        let destinationTag: UInt32?
        let amount: Decimal
        let memo: String?
        let minimumFeeDrops: UInt64?
    }

    nonisolated let canSign = true
    private let liveFeeDrops: UInt64
    private(set) var request: Request?

    init(liveFeeDrops: UInt64) {
        self.liveFeeDrops = liveFeeDrops
    }

    func sendInfo(
        destination: String,
        destinationTag: UInt32?,
        amount: Decimal,
        memo: String?,
        minimumFeeDrops: UInt64?
    ) async throws -> XrpSendInfo {
        request = Request(
            destination: destination,
            destinationTag: destinationTag,
            amount: amount,
            memo: memo,
            minimumFeeDrops: minimumFeeDrops
        )
        return XrpSendInfo(
            destination: XrpDestination(classicAddress: destination, destinationTag: destinationTag),
            amountDrops: try XrpAmount.drops(amount),
            feeDrops: liveFeeDrops,
            availableBalanceDrops: 1_000_000_000,
            sequence: 1,
            validatedLedger: 100,
            lastLedgerSequence: 104
        )
    }

    func send(
        destination _: String,
        destinationTag _: UInt32?,
        amount _: Decimal,
        memo _: String?,
        minimumFeeDrops _: UInt64?,
        maximumFeeDrops _: UInt64?,
        validUntilEpochSeconds _: Int?
    ) async throws -> String {
        "HASH"
    }
}

private extension ThorChainInboundAddress {
    func with(
        address: String? = nil,
        router: String?? = nil,
        halted: Bool? = nil,
        gasRate: String? = nil,
        dustThreshold: Int? = nil
    ) -> Self {
        .init(
            chain: chain,
            address: address ?? self.address,
            router: router ?? self.router,
            halted: halted ?? self.halted,
            gasRate: gasRate ?? self.gasRate,
            dustThreshold: dustThreshold ?? self.dustThreshold
        )
    }
}
