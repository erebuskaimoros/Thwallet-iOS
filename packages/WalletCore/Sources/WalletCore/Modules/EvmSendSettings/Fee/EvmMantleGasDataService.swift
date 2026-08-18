import BigInt
import EvmKit
import Foundation
import RxSwift

protocol IMantleFeeProviding: AnyObject {
    func additionalFee(gasLimit: Int, to: EvmKit.Address, value: BigUInt, data: Data) async throws -> BigUInt
}

extension MantleFeeProvider: IMantleFeeProviding {}

/// Adds Mantle's post-Arsia L1-data and operator fee to the selected execution fee.
final class EvmMantleGasDataService: EvmCommonGasDataService {
    private let mantleFeeProvider: IMantleFeeProviding

    override init(evmKit: EvmKit.Kit, predefinedGasLimit: Int?) {
        mantleFeeProvider = MantleFeeProvider(evmKit: evmKit)
        super.init(evmKit: evmKit, predefinedGasLimit: predefinedGasLimit)
    }

    init(
        gasEstimator: IEvmGasEstimating,
        mantleFeeProvider: IMantleFeeProviding,
        predefinedGasLimit: Int?,
        maximumGasLimit: Int = Int.max
    ) {
        self.mantleFeeProvider = mantleFeeProvider
        super.init(gasEstimator: gasEstimator, predefinedGasLimit: predefinedGasLimit, maximumGasLimit: maximumGasLimit)
    }

    override func gasDataSingle(gasPrice: GasPrice, transactionData: TransactionData, stubAmount: BigUInt? = nil) -> Single<EvmFeeModule.GasData> {
        let feeTransactionData = stubAmount.map {
            TransactionData(to: transactionData.to, value: $0, input: transactionData.input)
        } ?? transactionData

        if let predefinedGasLimit {
            let validatedPredefinedGasLimit: Int
            do {
                try EvmGasValidation.validate(gasPrice: gasPrice)
                validatedPredefinedGasLimit = try validated(gasLimit: predefinedGasLimit)
            } catch {
                return .error(error)
            }

            return estimateGas(transactionData: feeTransactionData, gasPrice: gasPrice)
                .flatMap { [weak self] estimatedGasLimit -> Single<EvmFeeModule.GasData> in
                    guard let self else {
                        return .error(AppError.weakReference)
                    }

                    let validatedEstimatedGasLimit: Int
                    do {
                        validatedEstimatedGasLimit = try self.validated(gasLimit: estimatedGasLimit)
                        try EvmGasValidation.validate(
                            signingGasLimit: validatedPredefinedGasLimit,
                            estimatedGasLimit: validatedEstimatedGasLimit
                        )
                    } catch {
                        return .error(error)
                    }

                    return self.additionalFee(transactionData: feeTransactionData, gasLimit: validatedEstimatedGasLimit)
                        .map {
                            EvmFeeModule.RollupGasData(
                                additionalFee: $0,
                                limit: validatedPredefinedGasLimit,
                                estimatedLimit: validatedEstimatedGasLimit,
                                price: gasPrice
                            )
                        }
                }
        }

        return super.gasDataSingle(gasPrice: gasPrice, transactionData: transactionData, stubAmount: stubAmount)
            .flatMap { [weak self] gasData -> Single<EvmFeeModule.GasData> in
                guard let self else {
                    return .error(AppError.weakReference)
                }

                return self.additionalFee(transactionData: feeTransactionData, gasLimit: gasData.estimatedLimit)
                    .map {
                        EvmFeeModule.RollupGasData(
                            additionalFee: $0,
                            limit: gasData.limit,
                            estimatedLimit: gasData.estimatedLimit,
                            price: gasPrice
                        )
                    }
            }
    }

    private func estimateGas(transactionData: TransactionData, gasPrice: GasPrice) -> Single<Int> {
        gasEstimator.estimateGas(transactionData: transactionData, gasPrice: gasPrice)
            .catchError { [gasEstimator] _ in
                gasEstimator.estimateGas(transactionData: transactionData, gasPrice: nil)
            }
    }

    private func additionalFee(transactionData: TransactionData, gasLimit: Int) -> Single<BigUInt> {
        Single.create { [mantleFeeProvider] observer in
            let task = Task {
                do {
                    let fee = try await mantleFeeProvider.additionalFee(
                        gasLimit: gasLimit,
                        to: transactionData.to,
                        value: transactionData.value,
                        data: transactionData.input
                    )
                    observer(.success(fee))
                } catch {
                    observer(.error(error))
                }
            }

            return Disposables.create { task.cancel() }
        }
    }
}
