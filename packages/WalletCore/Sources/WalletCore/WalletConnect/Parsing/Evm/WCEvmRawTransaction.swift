// JSON shape of eth_sendTransaction / eth_signTransaction params[0]; `gasLimit` is the legacy alias of `gas`.
// `type` and `accessList` are decoded only so WCEvmTransaction can reject requests the signer cannot
// reproduce faithfully (unsupported envelope types, non-empty EIP-2930 access lists) instead of ignoring them.
struct WCEvmRawTransaction: Codable {
    let from: String
    let to: String?
    let nonce: String?
    let gasPrice: String?
    let gas: String?
    let gasLimit: String?
    let maxPriorityFeePerGas: String?
    let maxFeePerGas: String?
    let type: String?
    let value: String?
    let accessList: [WCEvmAccessListEntry]?
    let data: String?
}

struct WCEvmAccessListEntry: Codable {
    let address: String
    let storageKeys: [String]
}
