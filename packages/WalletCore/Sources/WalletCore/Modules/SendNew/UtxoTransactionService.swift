import BitcoinCore
import Combine
import MarketKit
import SwiftUI

class UtxoTransactionService {
    private let blockchainType: BlockchainType
    private let adapter: BitcoinBaseAdapter
    private let feeRateProvider: IFeeRateProvider?
    private let initialTransactionSettings: InitialTransactionSettings?

    private(set) var actualFeeRates: FeeRateProvider.FeeRates?
    private var satoshiPerByte: Int? {
        didSet {
            validate()
        }
    }

    private(set) var cautions: [CautionNew] = []
    private let updateSubject = PassthroughSubject<Void, Never>()

    init(blockchainType: BlockchainType, adapter: BitcoinBaseAdapter, initialTransactionSettings: InitialTransactionSettings? = nil) {
        self.blockchainType = blockchainType
        self.adapter = adapter
        self.initialTransactionSettings = initialTransactionSettings
        feeRateProvider = Core.shared.feeRateProviderFactory.provider(blockchainType: blockchainType)
    }

    private func validate() {
        cautions = Self.validate(actualFeeRates: actualFeeRates, satoshiPerByte: satoshiPerByte)
    }
}

extension UtxoTransactionService: ITransactionService {
    var transactionSettings: TransactionSettings? {
        guard let currentSatoshiPerByte else {
            return nil
        }

        return .bitcoin(satoshiPerByte: currentSatoshiPerByte)
    }

    var modified: Bool {
        satoshiPerByte != nil
    }

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    func sync() async throws {
        guard let providerFeeRates = try await feeRateProvider?.feeRates() else {
            actualFeeRates = nil
            return
        }

        actualFeeRates = resolveUtxoFeeRates(
            providerFeeRates: providerFeeRates,
            initialTransactionSettings: initialTransactionSettings
        )
    }
}

func resolveUtxoFeeRates(
    providerFeeRates: FeeRateProvider.FeeRates,
    initialTransactionSettings: InitialTransactionSettings?
) -> FeeRateProvider.FeeRates {
    guard case let .some(.bitcoin(recommendedFeeRate)) = initialTransactionSettings else {
        return providerFeeRates
    }

    let effectiveRate = max(recommendedFeeRate, providerFeeRates.minimum)
    return .init(recommended: effectiveRate, minimum: effectiveRate)
}

extension UtxoTransactionService {
    var recommendedSatoshiPerByte: Int? {
        actualFeeRates?.recommended
    }

    var currentSatoshiPerByte: Int? {
        satoshiPerByte ?? recommendedSatoshiPerByte
    }

    func resolveFee(params: SendParameters, satoshiPerByte: Int?) throws -> Decimal {
        let params = params.copy()
        params.feeRate = satoshiPerByte
        return try adapter.sendInfo(params: params).fee
    }

    func set(satoshiPerByte: Int?) {
        self.satoshiPerByte = satoshiPerByte
        updateSubject.send()
    }
}

extension UtxoTransactionService {
    static func validate(actualFeeRates: FeeRateProvider.FeeRates?, satoshiPerByte: Int?) -> [CautionNew] {
        guard let actualFeeRates, let satoshiPerByte else {
            return []
        }

        if actualFeeRates.minimum > satoshiPerByte {
            return [.init(title: "send.fee_settings.fee_error.title".localized, text: "send.fee_settings.too_low".localized, type: .error)]
        }

        if actualFeeRates.recommended > satoshiPerByte {
            return [.init(title: "send.fee_settings.stuck_warning.title".localized, text: "send.fee_settings.stuck_warning".localized, type: .warning)]
        }

        return []
    }
}
