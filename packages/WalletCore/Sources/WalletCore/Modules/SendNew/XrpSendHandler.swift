import Foundation
import MarketKit

final class XrpSendHandler {
    private static let maximumFeeDrops: UInt64 = 100_000

    let baseToken: Token
    private let adapter: ISendXrpAdapter & IBalanceAdapter
    private let amount: Decimal
    private let destination: String
    private let destinationTag: UInt32?
    private let memo: String?
    private let recommendedFeeDrops: UInt64?
    private let minimumSendAmountDrops: UInt64?

    init(
        token: Token,
        adapter: ISendXrpAdapter & IBalanceAdapter,
        amount: Decimal,
        destination: String,
        destinationTag: UInt32?,
        memo: String?,
        recommendedFeeDrops: UInt64?,
        minimumSendAmountDrops: UInt64?
    ) {
        baseToken = token
        self.adapter = adapter
        self.amount = amount
        self.destination = destination
        self.destinationTag = destinationTag
        self.memo = memo
        self.recommendedFeeDrops = recommendedFeeDrops
        self.minimumSendAmountDrops = minimumSendAmountDrops
    }
}

extension XrpSendHandler: ISendHandler {
    var autoRefreshEnabled: Bool { false }

    func sendData(transactionSettings _: TransactionSettings?) async throws -> ISendData {
        var transactionError: Error?
        var amountDrops: UInt64?
        var sendInfo: XrpSendInfo?

        do {
            amountDrops = try XrpAmount.drops(amount)
            _ = try XrpAddressCodec.resolve(destination, separateTag: destinationTag, network: .mainnet)

            if let memo, memo.utf8.count > 256 {
                throw XrpRuntimeError.memoTooLarge
            }
            if let recommendedFeeDrops,
               recommendedFeeDrops == 0 || recommendedFeeDrops > Self.maximumFeeDrops
            {
                throw XrpRuntimeError.feeExceedsCap(actual: recommendedFeeDrops, cap: Self.maximumFeeDrops)
            }
            if let minimumSendAmountDrops, let amountDrops, amountDrops < minimumSendAmountDrops {
                throw TransactionError.belowMinimum(minimumDrops: minimumSendAmountDrops)
            }
            sendInfo = try await adapter.sendInfo(
                destination: destination,
                destinationTag: destinationTag,
                amount: amount,
                memo: memo,
                minimumFeeDrops: recommendedFeeDrops
            )
        } catch {
            transactionError = error
        }

        return PreparedData(
            token: baseToken,
            amount: amount,
            destination: destination,
            destinationTag: destinationTag,
            memo: memo,
            recommendedFeeDrops: recommendedFeeDrops,
            feeDrops: sendInfo?.feeDrops,
            transactionError: transactionError
        )
    }

    func send(data: ISendData) async throws {
        guard let data = data as? PreparedData,
              data.transactionError == nil,
              let approvedFeeDrops = data.feeDrops
        else {
            throw SendError.invalidData
        }

        _ = try await adapter.send(
            destination: data.destination,
            destinationTag: data.destinationTag,
            amount: data.amount,
            memo: data.memo,
            minimumFeeDrops: data.recommendedFeeDrops,
            maximumFeeDrops: approvedFeeDrops
        )
    }
}

extension XrpSendHandler {
    final class PreparedData: ISendData {
        let token: Token
        let amount: Decimal
        let destination: String
        let destinationTag: UInt32?
        let memo: String?
        let recommendedFeeDrops: UInt64?
        let feeDrops: UInt64?
        fileprivate let transactionError: Error?

        init(
            token: Token,
            amount: Decimal,
            destination: String,
            destinationTag: UInt32?,
            memo: String?,
            recommendedFeeDrops: UInt64?,
            feeDrops: UInt64?,
            transactionError: Error?
        ) {
            self.token = token
            self.amount = amount
            self.destination = destination
            self.destinationTag = destinationTag
            self.memo = memo
            self.recommendedFeeDrops = recommendedFeeDrops
            self.feeDrops = feeDrops
            self.transactionError = transactionError
        }

        var feeData: FeeData? { nil }
        var canSend: Bool { transactionError == nil }
        var rateCoins: [Coin] { [token.coin] }

        func cautions(baseToken _: Token, currency _: Currency, rates _: [String: Decimal]) -> [CautionNew] {
            guard let transactionError else { return [] }
            return [CautionNew(title: "XRP payment unavailable", text: Self.message(transactionError), type: .error)]
        }

        func sections(baseToken _: Token, currency: Currency, rates: [String: Decimal]) -> [SendDataSection] {
            var details = [SendField]()
            if let destinationTag {
                details.append(.simpleValue(title: "Destination tag", value: String(destinationTag)))
            }
            if let memo {
                details.append(.simpleValue(title: "send.confirmation.memo".localized, value: memo))
            }
            if let feeDrops {
                let fee = XrpAmount.xrp(feeDrops)
                let appValue = AppValue(token: token, value: fee)
                let currencyValue = rates[token.coin.uid].map { CurrencyValue(currency: currency, value: fee * $0) }
                details.append(.fee(
                    title: "fee_settings.network_fee".localized,
                    amountData: .init(appValue: appValue, currencyValue: currencyValue)
                ))
            }

            return [
                .init([
                    .amount(
                        token: token,
                        appValueType: .regular(appValue: AppValue(token: token, value: amount)),
                        currencyValue: rates[token.coin.uid].map { CurrencyValue(currency: currency, value: amount * $0) }
                    ),
                    .address(value: destination, blockchainType: .ripple),
                ], isFlow: true),
                .init(details, isMain: false),
            ]
        }

        private static func message(_ error: Error) -> String {
            switch error {
            case let XrpRuntimeError.feeExceedsCap(actual, cap):
                return "The requested XRP fee (\(actual) drops) exceeds the wallet safety cap (\(cap) drops)."
            case XrpRuntimeError.memoTooLarge:
                return "XRP memo data must be 256 bytes or less."
            case XrpRuntimeError.insufficientBalance:
                return "The spendable XRP balance cannot cover this payment and its network fee."
            case XrpRuntimeError.destinationTagRequired:
                return "The destination account requires a destination tag."
            case let XrpRuntimeError.destinationInactive(minimumDrops):
                return "This inactive destination requires at least \(XrpAmount.xrp(minimumDrops)) XRP to activate."
            case XrpRuntimeError.pendingTransactionExists:
                return "Wait for the previous XRP payment to validate before sending another one."
            case let TransactionError.belowMinimum(minimumDrops):
                return "This payment requires at least \(XrpAmount.xrp(minimumDrops)) XRP."
            case XrpCodecError.destinationTagConflict:
                return "The separate destination tag conflicts with the tag in the X-address."
            case XrpCodecError.wrongNetwork:
                return "This XRP address belongs to a different network."
            default:
                return "The native XRP payment parameters are invalid."
            }
        }
    }

    enum SendError: Error { case invalidData }
    enum TransactionError: Error { case belowMinimum(minimumDrops: UInt64) }
}

extension XrpSendHandler {
    static func instance(
        token: Token,
        amount: Decimal,
        destination: String,
        destinationTag: UInt32?,
        memo: String?,
        recommendedFeeDrops: UInt64?,
        minimumSendAmountDrops: UInt64?
    ) -> XrpSendHandler? {
        guard token.blockchainType == .ripple, token.type == .native,
              let adapter = Core.shared.adapterManager.adapter(for: token) as? ISendXrpAdapter & IBalanceAdapter,
              adapter.canSign
        else { return nil }

        return XrpSendHandler(
            token: token,
            adapter: adapter,
            amount: amount,
            destination: destination,
            destinationTag: destinationTag,
            memo: memo,
            recommendedFeeDrops: recommendedFeeDrops,
            minimumSendAmountDrops: minimumSendAmountDrops
        )
    }
}
