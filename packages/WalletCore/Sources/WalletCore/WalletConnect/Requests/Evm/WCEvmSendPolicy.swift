import EvmKit

// Thwallet: the request's `from` must be the address of the EVM kit that will sign it. WCSignerBindingVerifier
// checks `from` against the session's approved accounts; this binds it to the actual signing key as well.
enum WalletConnectAccountPolicy {
    static func validate(requestedFrom: EvmKit.Address, activeAddress: EvmKit.Address) throws {
        guard requestedFrom == activeAddress else {
            throw ValidationError.invalidFromAddress
        }
    }

    enum ValidationError: Error, Equatable {
        case invalidFromAddress
    }
}

// Thwallet: a dApp-supplied gas limit is a signing ceiling, not a fee quote. It is still routed through
// EvmFeeEstimator (as `predefinedGasLimit`, kept for signing) so rollup L1 and Mantle additional fees are
// priced instead of short-circuiting to gasLimit * gasPrice.
enum WalletConnectEvmFeePolicy {
    static func resolve(
        predefinedGasLimit: Int?,
        estimate: (Int?) async throws -> EvmFeeData
    ) async rethrows -> EvmFeeData {
        try await estimate(predefinedGasLimit)
    }

    // Final gate on the exact gas price and limit that will be signed, against the chain's gas cap
    static func validate(gasPrice: GasPrice, gasLimit: Int, maximumGasLimit: Int) throws {
        try EvmGasValidation.validate(gasPrice: gasPrice)
        try EvmGasValidation.validate(gasLimit: gasLimit, maximumGasLimit: maximumGasLimit)
    }
}
