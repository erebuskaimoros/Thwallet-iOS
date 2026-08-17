import Testing
@testable import WalletCore

struct ThorChainAffiliatePolicyTests {
    @Test func directQuotesOmitWalletAffiliateParameters() {
        #expect(ThorChainAffiliatePolicy.affiliate == nil)
        #expect(ThorChainAffiliatePolicy.affiliateBps == nil)
    }
}
