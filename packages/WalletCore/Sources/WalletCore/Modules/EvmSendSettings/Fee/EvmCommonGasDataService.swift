import BigInt
import EvmKit
import MarketKit
import RxCocoa
import RxRelay
import RxSwift

protocol IEvmGasEstimating: AnyObject {
    func estimateGas(transactionData: TransactionData, gasPrice: GasPrice?) -> Single<Int>
}

final class EvmKitGasEstimator: IEvmGasEstimating {
    private let evmKit: EvmKit.Kit

    init(evmKit: EvmKit.Kit) {
        self.evmKit = evmKit
    }

    func estimateGas(transactionData: TransactionData, gasPrice: GasPrice?) -> Single<Int> {
        Single.create { [evmKit] observer in
            let task = Task {
                do {
                    let gasLimit = try await evmKit.fetchEstimateGas(transactionData: transactionData, gasPrice: gasPrice)
                    observer(.success(gasLimit))
                } catch {
                    observer(.error(error))
                }
            }

            return Disposables.create { task.cancel() }
        }
    }
}

class EvmCommonGasDataService {
    let gasEstimator: IEvmGasEstimating
    let maximumGasLimit: Int
    private(set) var predefinedGasLimit: Int?

    init(evmKit: EvmKit.Kit, predefinedGasLimit: Int?) {
        gasEstimator = EvmKitGasEstimator(evmKit: evmKit)
        maximumGasLimit = evmKit.chain.gasLimit
        self.predefinedGasLimit = predefinedGasLimit
    }

    init(gasEstimator: IEvmGasEstimating, predefinedGasLimit: Int?, maximumGasLimit: Int = Int.max) {
        self.gasEstimator = gasEstimator
        self.maximumGasLimit = maximumGasLimit
        self.predefinedGasLimit = predefinedGasLimit
    }

    func gasDataSingle(gasPrice: GasPrice, transactionData: TransactionData, stubAmount: BigUInt? = nil) -> Single<EvmFeeModule.GasData> {
        do {
            try EvmGasValidation.validate(gasPrice: gasPrice)
        } catch {
            return .error(error)
        }

        if let predefinedGasLimit {
            do {
                let validatedGasLimit = try validated(gasLimit: predefinedGasLimit)
                return .just(EvmFeeModule.GasData(limit: validatedGasLimit, price: gasPrice))
            } catch {
                return .error(error)
            }
        }

        let surchargeRequired = !transactionData.input.isEmpty

        let adjustedTransactionData = stubAmount.map { TransactionData(to: transactionData.to, value: $0, input: transactionData.input) } ?? transactionData

        return gasEstimator.estimateGas(transactionData: adjustedTransactionData, gasPrice: gasPrice)
            .map { [maximumGasLimit] estimatedGasLimit in
                let estimatedGasLimit = try EvmGasValidation.validate(
                    gasLimit: estimatedGasLimit,
                    maximumGasLimit: maximumGasLimit
                )
                let limit = surchargeRequired
                    ? try EvmFeeModule.surcharged(gasLimit: estimatedGasLimit, maximumGasLimit: maximumGasLimit)
                    : estimatedGasLimit

                return EvmFeeModule.GasData(
                    limit: limit,
                    estimatedLimit: estimatedGasLimit,
                    price: gasPrice
                )
            }
    }

    func validated(gasLimit: Int) throws -> Int {
        try EvmGasValidation.validate(gasLimit: gasLimit, maximumGasLimit: maximumGasLimit)
    }
}

extension EvmCommonGasDataService {
    static func instance(evmKit: EvmKit.Kit, blockchainType: BlockchainType, predefinedGasLimit: Int?) -> EvmCommonGasDataService {
        switch EvmGasDataServiceKind.resolve(blockchainType: blockchainType, predefinedGasLimit: predefinedGasLimit) {
        case .mantle:
            return EvmMantleGasDataService(evmKit: evmKit, predefinedGasLimit: predefinedGasLimit)
        case .opStack:
            guard let rollupFeeContractAddress = blockchainType.rollupFeeContractAddress else {
                preconditionFailure("Missing OP-stack gas oracle for \(blockchainType.uid)")
            }
            return EvmRollupGasDataService(evmKit: evmKit, l1GasFeeContractAddress: rollupFeeContractAddress, predefinedGasLimit: predefinedGasLimit)
        case .standard:
            return EvmCommonGasDataService(evmKit: evmKit, predefinedGasLimit: predefinedGasLimit)
        }
    }
}
