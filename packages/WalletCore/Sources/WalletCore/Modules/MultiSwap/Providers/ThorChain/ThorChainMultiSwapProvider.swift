// Thwallet product policy: a direct THORChain swap charges no wallet affiliate fee. Both values
// stay nil, so BaseThorChainMultiSwapProvider.quoteParameters omits `affiliate` and `affiliate_bps`
// and THORNode builds a memo without an affiliate. Guarded by ThorChainAffiliatePolicyTests.
enum ThorChainAffiliatePolicy {
    static let affiliate: String? = nil
    static let affiliateBps: Int? = nil
}

class ThorChainMultiSwapProvider: BaseThorChainMultiSwapProvider {
    // Shared with USwapProviderInfo.thorChain: history, suspensions and the /v3/providers list all
    // key THORChain by this id, and SwapProviderResolver maps it to this native provider.
    static let id = "THORCHAIN"
    static let name = "THORChain"

    override var baseUrl: String {
        "https://gateway.liquify.com/chain/thorchain_api/thorchain"
    }

    override var securedAssetsSupported: Bool { true }

    override var id: String { Self.id }
    override var name: String { Self.name }
    // The backend's AML rating for this id when it publishes one; the native provider's
    // long-standing rating otherwise.
    override var type: SwapProviderType? { Core.shared.swapProviderManager.amlPolicy(providerId: Self.id) ?? .excellent }
    override var icon: String { "swap_provider_thorchain" }

    override var affiliate: String? {
        ThorChainAffiliatePolicy.affiliate
    }

    override var affiliateBps: Int? {
        ThorChainAffiliatePolicy.affiliateBps
    }

    override var streamingInterval: Int { 0 }
}
