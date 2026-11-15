import Foundation
import Testing
@testable import WalletCore

struct ThorChainAffiliatePolicyTests {
    @Test func directQuotesOmitWalletAffiliateParameters() {
        #expect(ThorChainAffiliatePolicy.affiliate == nil)
        #expect(ThorChainAffiliatePolicy.affiliateBps == nil)
    }

    // The THORNode quote query built with the policy values carries neither affiliate key.
    @Test func quoteRequestCarriesNoAffiliateKeys() {
        let parameters = BaseThorChainMultiSwapProvider.quoteParameters(
            assetIn: "BTC.BTC",
            assetOut: "ETH.ETH",
            amount: 100_000,
            destination: "0x1111111111111111111111111111111111111111",
            streamingInterval: 0,
            slippage: 1,
            affiliate: ThorChainAffiliatePolicy.affiliate,
            affiliateBps: ThorChainAffiliatePolicy.affiliateBps
        )

        #expect(parameters["affiliate"] == nil)
        #expect(parameters["affiliate_bps"] == nil)
        #expect(parameters["from_asset"] as? String == "BTC.BTC")
        #expect(parameters["destination"] as? String == "0x1111111111111111111111111111111111111111")
    }

    // Guards the builder itself: a half-configured pair never produces affiliate keys either.
    @Test func quoteRequestNeedsBothAffiliateValues() {
        for (affiliate, affiliateBps) in [("t", nil), (nil, 50)] as [(String?, Int?)] {
            let parameters = BaseThorChainMultiSwapProvider.quoteParameters(
                assetIn: "BTC.BTC",
                assetOut: "ETH.ETH",
                amount: 100_000,
                destination: nil,
                streamingInterval: 0,
                slippage: nil,
                affiliate: affiliate,
                affiliateBps: affiliateBps
            )

            #expect(parameters["affiliate"] == nil)
            #expect(parameters["affiliate_bps"] == nil)
            #expect(parameters["destination"] == nil)
        }
    }
}
