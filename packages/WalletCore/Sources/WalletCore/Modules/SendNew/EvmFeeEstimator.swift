import BigInt
import EvmKit
import MarketKit

struct EvmFeeEstimator {
    typealias GasEstimator = (GasPrice?) async throws -> Int
    typealias AdditionalFeeEstimator = (EvmGasDataServiceKind, Int) async throws -> BigUInt?

    private static let maximumOpStackAffordabilityAttempts = 4

    func estimateFee(
        evmKitWrapper: EvmKitWrapper,
        transactionData: TransactionData,
        gasPriceData: GasPriceData,
        predefinedGasLimit: Int? = nil,
        stubAmount: BigUInt? = nil
    ) async throws -> EvmFeeData {
        let evmKit = evmKitWrapper.evmKit
        let gasPrice = gasPriceData.userDefined
        let feeServiceKind = EvmGasDataServiceKind.resolve(
            blockchainType: evmKitWrapper.blockchainType,
            predefinedGasLimit: predefinedGasLimit
        )
        let simulationTransactionData = stubAmount.map {
            TransactionData(to: transactionData.to, value: $0, input: transactionData.input)
        } ?? transactionData
        let feeTransactionData = Self.additionalFeeTransactionData(
            transactionData: transactionData,
            stubAmount: stubAmount,
            feeServiceKind: feeServiceKind
        )

        return try await estimateFee(
            transactionData: simulationTransactionData,
            gasPrice: gasPrice,
            predefinedGasLimit: predefinedGasLimit,
            feeServiceKind: feeServiceKind,
            evmBalance: evmKit.accountState?.balance ?? 0,
            maximumGasLimit: evmKit.chain.gasLimit,
            estimateGas: { requestedGasPrice in
                try await evmKit.fetchEstimateGas(transactionData: simulationTransactionData, gasPrice: requestedGasPrice)
            },
            additionalFee: { kind, gasLimit in
                switch kind {
                case .mantle:
                    return try await MantleFeeProvider(evmKit: evmKit).additionalFee(
                        gasLimit: gasLimit,
                        to: feeTransactionData.to,
                        value: feeTransactionData.value,
                        data: feeTransactionData.input
                    )
                case .opStack:
                    guard let contractAddress = evmKitWrapper.blockchainType.rollupFeeContractAddress else {
                        preconditionFailure("Missing OP-stack gas oracle for \(evmKitWrapper.blockchainType.uid)")
                    }
                    return try await L1FeeProvider.instance(evmKit: evmKit, contractAddress: contractAddress).l1Fee(
                        gasPrice: gasPrice,
                        gasLimit: gasLimit,
                        to: feeTransactionData.to,
                        value: feeTransactionData.value,
                        data: feeTransactionData.input
                    )
                case .standard:
                    return nil
                }
            }
        )
    }

    func estimateFee(
        transactionData: TransactionData,
        gasPrice: GasPrice,
        predefinedGasLimit: Int?,
        feeServiceKind: EvmGasDataServiceKind,
        evmBalance: BigUInt,
        maximumGasLimit: Int = Int.max,
        estimateGas: @escaping GasEstimator,
        additionalFee: @escaping AdditionalFeeEstimator
    ) async throws -> EvmFeeData {
        try EvmGasValidation.validate(gasPrice: gasPrice)

        let gasLimit: Int
        if let predefinedGasLimit {
            gasLimit = predefinedGasLimit
        } else {
            gasLimit = try await estimatedGas(gasPrice: gasPrice, estimateGas: estimateGas)
        }

        try EvmGasValidation.validate(gasLimit: gasLimit, maximumGasLimit: maximumGasLimit)

        let fullSurchargedGasLimit: Int
        if predefinedGasLimit == nil, !transactionData.input.isEmpty {
            fullSurchargedGasLimit = try EvmGasValidation.surcharged(
                gasLimit: gasLimit,
                maximumGasLimit: maximumGasLimit
            )
        } else {
            fullSurchargedGasLimit = gasLimit
        }

        // Mantle's total-fee RPC decomposes its result using actual execution gas. A
        // provider-supplied ceiling is retained for signing, but is not treated as consumed gas.
        // OP Stack instead prices the serialized unsigned transaction, so its oracle must see
        // the exact gas limit that will be signed.
        let additionalFeeGasLimit: Int
        if feeServiceKind == .mantle, predefinedGasLimit != nil {
            additionalFeeGasLimit = try await estimatedGas(gasPrice: gasPrice, estimateGas: estimateGas)
            try EvmGasValidation.validate(
                gasLimit: additionalFeeGasLimit,
                maximumGasLimit: maximumGasLimit
            )
            try EvmGasValidation.validate(
                signingGasLimit: gasLimit,
                estimatedGasLimit: additionalFeeGasLimit
            )
        } else {
            additionalFeeGasLimit = gasLimit
        }

        if feeServiceKind == .opStack {
            return try await opStackFeeData(
                estimatedGasLimit: gasLimit,
                requestedGasLimit: fullSurchargedGasLimit,
                transactionData: transactionData,
                gasPrice: gasPrice.max,
                balance: evmBalance,
                additionalFee: additionalFee
            )
        }

        let l1Fee = try await additionalFee(feeServiceKind, additionalFeeGasLimit)
        let surchargedGasLimit = affordableGasLimit(
            estimatedGasLimit: gasLimit,
            requestedGasLimit: fullSurchargedGasLimit,
            transactionValue: transactionData.value,
            additionalFee: l1Fee ?? 0,
            gasPrice: gasPrice.max,
            balance: evmBalance
        )

        return .init(gasLimit: gasLimit, surchargedGasLimit: surchargedGasLimit, l1Fee: l1Fee)
    }

    private func opStackFeeData(
        estimatedGasLimit: Int,
        requestedGasLimit: Int,
        transactionData: TransactionData,
        gasPrice: Int,
        balance: BigUInt,
        additionalFee: @escaping AdditionalFeeEstimator
    ) async throws -> EvmFeeData {
        var candidateGasLimit = requestedGasLimit

        for _ in 0 ..< Self.maximumOpStackAffordabilityAttempts {
            let l1Fee = try await additionalFee(.opStack, candidateGasLimit)
            let affordableCandidate = affordableGasLimit(
                estimatedGasLimit: estimatedGasLimit,
                requestedGasLimit: candidateGasLimit,
                transactionValue: transactionData.value,
                additionalFee: l1Fee ?? 0,
                gasPrice: gasPrice,
                balance: balance
            )

            if affordableCandidate == candidateGasLimit {
                return .init(
                    gasLimit: estimatedGasLimit,
                    surchargedGasLimit: candidateGasLimit,
                    l1Fee: l1Fee
                )
            }

            // Candidate limits only move downward. This prevents a non-monotonic or
            // adversarial oracle from oscillating the value that will be serialized.
            candidateGasLimit = affordableCandidate
        }

        // Fail closed after the bounded retry budget: remove the optional safety margin and
        // price the mandatory estimate exactly. Downstream balance validation still rejects
        // the transaction if even this minimum gas plus its exact L1 fee is unaffordable.
        let l1Fee = try await additionalFee(.opStack, estimatedGasLimit)
        return .init(
            gasLimit: estimatedGasLimit,
            surchargedGasLimit: estimatedGasLimit,
            l1Fee: l1Fee
        )
    }

    private func estimatedGas(gasPrice: GasPrice, estimateGas: GasEstimator) async throws -> Int {
        do {
            return try await estimateGas(gasPrice)
        } catch {
            return try await estimateGas(nil)
        }
    }

    static func additionalFeeTransactionData(
        transactionData: TransactionData,
        stubAmount: BigUInt?,
        feeServiceKind: EvmGasDataServiceKind
    ) -> TransactionData {
        guard let stubAmount else {
            return transactionData
        }

        let value: BigUInt
        switch feeServiceKind {
        case .opStack:
            let hexDigitCount = max(String(transactionData.value, radix: 16).count, 1)
            value = BigUInt(String(repeating: "f", count: hexDigitCount), radix: 16) ?? transactionData.value
        case .mantle, .standard:
            value = stubAmount
        }

        return TransactionData(to: transactionData.to, value: value, input: transactionData.input)
    }

    private func affordableGasLimit(
        estimatedGasLimit: Int,
        requestedGasLimit: Int,
        transactionValue: BigUInt,
        additionalFee: BigUInt,
        gasPrice: Int,
        balance: BigUInt
    ) -> Int {
        guard requestedGasLimit > estimatedGasLimit else {
            return estimatedGasLimit
        }

        let executionFee = BigUInt(estimatedGasLimit) * BigUInt(gasPrice)
        let baseAmount = transactionValue + executionFee + additionalFee
        guard balance > baseAmount else {
            return estimatedGasLimit
        }

        let requestedAdditionalGas = requestedGasLimit - estimatedGasLimit
        let affordableAdditionalGas = (balance - baseAmount) / BigUInt(gasPrice)
        let cappedAdditionalGas = min(BigUInt(requestedAdditionalGas), affordableAdditionalGas)

        return estimatedGasLimit + (Int(cappedAdditionalGas.description) ?? 0)
    }
}

extension EvmFeeEstimator {
    typealias ValidationError = EvmGasValidationError
}
