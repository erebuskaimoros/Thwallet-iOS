import Foundation
import MarketKit

final class XrpSwapFinalQuote: SwapFinalQuote {
    let destination: String
    let destinationTag: UInt32?
    let memo: String
    let recommendedFeeDrops: UInt64
    let minimumSendAmountDrops: UInt64
    let feeDrops: UInt64?
    let validUntilEpochSeconds: Int
    private let token: Token

    init(
        expectedBuyAmount: Decimal,
        token: Token,
        destination: String,
        destinationTag: UInt32?,
        memo: String,
        recommendedFeeDrops: UInt64,
        minimumSendAmountDrops: UInt64,
        feeDrops: UInt64?,
        validUntilEpochSeconds: Int,
        slippage: Decimal?,
        recipient: String?,
        estimatedTime: TimeInterval?,
        transactionError: Error?,
        toAddress: String
    ) {
        self.token = token
        self.destination = destination
        self.destinationTag = destinationTag
        self.memo = memo
        self.recommendedFeeDrops = recommendedFeeDrops
        self.minimumSendAmountDrops = minimumSendAmountDrops
        self.feeDrops = feeDrops
        self.validUntilEpochSeconds = validUntilEpochSeconds
        super.init(
            expectedBuyAmount: expectedBuyAmount,
            slippage: slippage,
            recipient: recipient,
            estimatedTime: estimatedTime,
            transactionError: transactionError,
            toAddress: toAddress,
            depositAddress: destination
        )
    }

    override func fields(
        tokenIn: Token,
        tokenOut: Token,
        baseToken: Token,
        currency: Currency,
        tokenInRate: Decimal?,
        tokenOutRate: Decimal?,
        baseTokenRate: Decimal?
    ) -> [SendField] {
        var fields = super.fields(
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            baseToken: baseToken,
            currency: currency,
            tokenInRate: tokenInRate,
            tokenOutRate: tokenOutRate,
            baseTokenRate: baseTokenRate
        )
        if let feeDrops {
            let fee = XrpAmount.xrp(feeDrops)
            fields.append(.fee(
                title: "fee_settings.network_fee".localized,
                amountData: .init(
                    appValue: AppValue(token: token, value: fee),
                    currencyValue: tokenInRate.map { CurrencyValue(currency: currency, value: fee * $0) }
                )
            ))
        }
        return fields
    }
}
