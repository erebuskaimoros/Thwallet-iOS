import BigInt
import EvmKit
import Foundation
import RxCocoa
import RxRelay
import RxSwift

class EvmRollupGasDataService: EvmCommonGasDataService {
    typealias L1Fee = (GasPrice, Int, EvmKit.Address, BigUInt, Data) -> Single<BigUInt>

    private let l1Fee: L1Fee

    init(evmKit: EvmKit.Kit, l1GasFeeContractAddress: EvmKit.Address, predefinedGasLimit: Int?) {
        let provider = L1FeeProvider.instance(evmKit: evmKit, contractAddress: l1GasFeeContractAddress, minLogLevel: .error)
        l1Fee = { gasPrice, gasLimit, to, value, data in
            provider.getL1Fee(gasPrice: gasPrice, gasLimit: gasLimit, to: to, value: value, data: data)
        }

        super.init(evmKit: evmKit, predefinedGasLimit: predefinedGasLimit)
    }

    init(gasEstimator: IEvmGasEstimating, predefinedGasLimit: Int?, maximumGasLimit: Int = Int.max, l1Fee: @escaping L1Fee) {
        self.l1Fee = l1Fee
        super.init(gasEstimator: gasEstimator, predefinedGasLimit: predefinedGasLimit, maximumGasLimit: maximumGasLimit)
    }

    private func l1GasFeeSingle(transactionData: TransactionData, gasPrice: GasPrice, gasLimit: Int) -> Single<BigUInt> {
        l1Fee(gasPrice, gasLimit, transactionData.to, transactionData.value, transactionData.input)
    }

    private func stubMaxHex(value: BigUInt) -> BigUInt {
        let hexString = String(value, radix: 16)
        let maximumHexValue = [String](repeating: "F", count: hexString.count).joined()
        let newValue = BigUInt(maximumHexValue, radix: 16) ?? (value * 10)
        return newValue
    }

    override func gasDataSingle(gasPrice: GasPrice, transactionData: TransactionData, stubAmount: BigUInt?) -> Single<EvmFeeModule.GasData> {
        if let predefinedGasLimit {
            let validatedGasLimit: Int
            do {
                try EvmGasValidation.validate(gasPrice: gasPrice)
                validatedGasLimit = try validated(gasLimit: predefinedGasLimit)
            } catch {
                return .error(error)
            }

            return l1GasFeeSingle(transactionData: transactionData, gasPrice: gasPrice, gasLimit: validatedGasLimit).map { l1GasFee in
                EvmFeeModule.RollupGasData(additionalFee: l1GasFee, limit: validatedGasLimit, price: gasPrice)
            }
        }

        return super.gasDataSingle(gasPrice: gasPrice, transactionData: transactionData, stubAmount: stubAmount)
            .flatMap { [weak self] commonGasData in
                var l1TransactionData = transactionData
                // if we calculate stub fee for l2 layer. we need calculate l1BaseFee using maximum value converted to FFF..FFF view
                if stubAmount != nil {
                    let maxAmount = self?.stubMaxHex(value: transactionData.value) ?? transactionData.value
                    l1TransactionData = TransactionData(to: transactionData.to, value: maxAmount, input: transactionData.input)
                }

                return self?.l1GasFeeSingle(transactionData: l1TransactionData, gasPrice: gasPrice, gasLimit: commonGasData.limit)
                    .map { l1GasFee in
                        EvmFeeModule.RollupGasData(additionalFee: l1GasFee, limit: commonGasData.limit, price: gasPrice)
                    } ?? .just(EvmFeeModule.RollupGasData(additionalFee: 0, limit: commonGasData.limit, price: gasPrice))
            }
    }
}
