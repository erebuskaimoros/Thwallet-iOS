import EvmKit

enum EvmGasValidationError: Error, Equatable {
    case invalidGasLimit(Int, maximum: Int)
    case insufficientGasLimit(Int, estimated: Int)
    case invalidGasPrice(Int)
    case invalidEip1559GasPrice(maxFeePerGas: Int, maxPriorityFeePerGas: Int)
}

enum EvmGasValidation {
    private static let surchargeDivisor = 10

    static func validate(gasPrice: GasPrice) throws {
        switch gasPrice {
        case let .legacy(gasPrice):
            guard gasPrice > 0 else {
                throw EvmGasValidationError.invalidGasPrice(gasPrice)
            }
        case let .eip1559(maxFeePerGas, maxPriorityFeePerGas):
            guard maxFeePerGas > 0,
                  maxPriorityFeePerGas >= 0,
                  maxPriorityFeePerGas <= maxFeePerGas
            else {
                throw EvmGasValidationError.invalidEip1559GasPrice(
                    maxFeePerGas: maxFeePerGas,
                    maxPriorityFeePerGas: maxPriorityFeePerGas
                )
            }
        }
    }

    @discardableResult
    static func validate(gasLimit: Int, maximumGasLimit: Int) throws -> Int {
        guard maximumGasLimit > 0,
              gasLimit > 0,
              gasLimit <= maximumGasLimit
        else {
            throw EvmGasValidationError.invalidGasLimit(gasLimit, maximum: maximumGasLimit)
        }

        return gasLimit
    }

    static func surcharged(gasLimit: Int, maximumGasLimit: Int) throws -> Int {
        let gasLimit = try validate(gasLimit: gasLimit, maximumGasLimit: maximumGasLimit)
        let requestedSafetyMargin = gasLimit / surchargeDivisor
        let availableHeadroom = maximumGasLimit - gasLimit

        // Both operands are bounded by maximumGasLimit before addition, so even an
        // adversarial Int.max estimate cannot overflow this arithmetic.
        return gasLimit + min(requestedSafetyMargin, availableHeadroom)
    }

    static func validate(signingGasLimit: Int, estimatedGasLimit: Int) throws {
        guard signingGasLimit >= estimatedGasLimit else {
            throw EvmGasValidationError.insufficientGasLimit(signingGasLimit, estimated: estimatedGasLimit)
        }
    }
}
