import Foundation
import MarketKit
import ObjectMapper
import Testing
@testable import WalletCore

// Restored by Thwallet: upstream removed these with its native provider (798917fa2); Thwallet keeps
// the native THORNode-quoted provider, so its quote decoding and memo checks stay covered.
struct ThorChainSwapQuoteTests {
    @Test func nativeQuoteDecodesWithoutAnInboundAddress() throws {
        // A THORChain-native swap has no vault to pay into, so THORNode omits the field.
        // Decoding it strictly would reject exactly the quote the deposit path needs.
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: Self.json(inboundAddress: nil))

        #expect(quote.inboundAddress == nil)
        #expect(quote.memo == "=:BTC.BTC:bc1qexample")
        #expect(quote.expectedAmountOut == Decimal(string: "0.12345678"))
    }

    @Test func quoteFromAnotherChainKeepsItsInboundAddress() throws {
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: Self.json(inboundAddress: "bc1qvault"))

        #expect(quote.inboundAddress == "bc1qvault")
    }

    @Test func utxoGasFieldsDecodeForTheSendPolicy() throws {
        let json = Self.json(inboundAddress: "bc1qvault").replacingOccurrences(
            of: "\"fees\"",
            with: "\"recommended_gas_rate\":\"750000\",\"gas_rate_units\":\"satsperbyte\",\"dust_threshold\":\"100000000\",\"fees\""
        )
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: json)

        #expect(quote.recommendedGasRate == 750_000)
        #expect(quote.gasRateUnits == "satsperbyte")
        #expect(quote.dustThreshold == 100_000_000)
    }

    @Test func confirmationMemoChecksDestinationWithoutRequiringInboundAddress() throws {
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: Self.json(inboundAddress: nil))
        let memo = try quote.requiredMemo(expectedDestination: "bc1qexample", blockchainType: .bitcoin)
        #expect(memo == quote.memo)
        #expect(quote.inboundAddress == nil)
    }

    @Test func confirmationMemoRejectsWrongRecipientBeforeTransactionConstruction() throws {
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: Self.json(inboundAddress: "bc1qvault"))
        #expect(throws: ThorChainSwapMemo.ValidationError.destinationMismatch) {
            _ = try quote.requiredMemo(expectedDestination: "bc1qdifferent", blockchainType: .bitcoin)
        }
    }

    @Test func dryQuoteCanStillDecodeWithoutMemo() throws {
        let json = Self.json(inboundAddress: nil).replacingOccurrences(of: ",\"memo\":\"=:BTC.BTC:bc1qexample\"", with: "")
        let quote = try BaseThorChainMultiSwapProvider.SwapQuote(JSONString: json)
        #expect(quote.memo == nil)
        do {
            _ = try quote.requiredMemo(expectedDestination: "bc1qexample", blockchainType: .bitcoin)
            Issue.record("Confirmation must reject a missing memo")
        } catch BaseThorChainMultiSwapProvider.SwapError.noMemo {
            // Existing no-memo error is preserved.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func zcashOutputRequiresTransparentDestination() throws {
        try BaseThorChainMultiSwapProvider.validateDestination("t1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU", tokenOut: Self.zec)
        // A non-ZEC output is not restricted here.
        try BaseThorChainMultiSwapProvider.validateDestination("bc1qexample", tokenOut: Self.btc)

        for destination in ["u1example", "zs1example", ""] {
            do {
                try BaseThorChainMultiSwapProvider.validateDestination(destination, tokenOut: Self.zec)
                Issue.record("A non-transparent ZEC destination must be refused: \(destination)")
            } catch BaseThorChainMultiSwapProvider.SwapError.transparentZcashRequired {
                // expected
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private static let zec = Token(
        coin: Coin(uid: "zcash", name: "Zcash", code: "ZEC"),
        blockchain: Blockchain(type: .zcash, name: "Zcash", explorerUrl: nil),
        type: .native,
        decimals: 8
    )

    private static let btc = Token(
        coin: Coin(uid: "bitcoin", name: "Bitcoin", code: "BTC"),
        blockchain: Blockchain(type: .bitcoin, name: "Bitcoin", explorerUrl: nil),
        type: .derived(derivation: .bip84),
        decimals: 8
    )

    private static func json(inboundAddress: String?) -> String {
        let inbound = inboundAddress.map { "\"inbound_address\":\"\($0)\"," } ?? ""
        return """
        {\(inbound)"expected_amount_out":"12345678","memo":"=:BTC.BTC:bc1qexample",
         "fees":{"affiliate":"1","outbound":"2","liquidity":"3","total":"6"}}
        """
    }
}
