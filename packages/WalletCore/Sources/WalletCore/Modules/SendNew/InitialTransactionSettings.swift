import BigInt
import EvmKit
import ZcashLightClientKit

public enum InitialTransactionSettings {
    case evm(gasPrice: GasPrice?, nonce: Int?)
    case aa(maxFeePerGas: BigUInt?, maxPriorityFeePerGas: BigUInt?, nonce: BigUInt?)
    case bitcoin(recommendedFeeRate: Int)
    case zcash(zip317MarginalFee: Zatoshi?)
}
