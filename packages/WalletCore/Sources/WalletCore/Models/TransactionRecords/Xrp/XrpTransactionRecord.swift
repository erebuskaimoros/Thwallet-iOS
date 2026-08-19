import Foundation
import MarketKit

class XrpTransactionRecord: TransactionRecord {
    let value: AppValue
    let fee: AppValue?
    let from: String?
    let to: String?
    let sentToSelf: Bool
    let memo: String?
    let destinationTag: UInt32?
    let direction: XrpHistoryRecord.Direction

    init(record: XrpHistoryRecord, token: Token, source: TransactionSource, ownAddress: String) {
        let amount = XrpAmount.xrp(record.amountDrops)
        let signedAmount: Decimal
        switch record.direction {
        case .incoming:
            signedAmount = amount
        case .outgoing:
            signedAmount = -amount
        case .selfTransfer:
            // A payment back to the same account has no principal balance change;
            // only the network fee is spent.
            signedAmount = 0
        }

        value = AppValue(token: token, value: signedAmount)
        fee = record.direction == .incoming ? nil : AppValue(token: token, value: XrpAmount.xrp(record.feeDrops))
        from = record.direction == .incoming ? record.counterparty : ownAddress
        to = record.direction == .incoming ? ownAddress : record.counterparty
        sentToSelf = record.direction == .selfTransfer
        memo = record.memo.map { data in
            String(data: data, encoding: .utf8) ?? "0x" + data.map { String(format: "%02X", $0) }.joined()
        }
        destinationTag = record.destinationTag
        direction = record.direction

        super.init(
            source: source,
            uid: record.hash,
            transactionHash: record.hash,
            transactionIndex: 0,
            blockHeight: Int(record.ledgerIndex),
            confirmationsThreshold: 1,
            date: Date(timeIntervalSince1970: record.timestamp),
            failed: !record.succeeded,
            paginationRaw: record.cursor.rawValue
        )
    }

    override var mainValue: AppValue? {
        value
    }
}
