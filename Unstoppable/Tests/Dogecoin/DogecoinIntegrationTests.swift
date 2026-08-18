import BitcoinCore
import Foundation
import HdWalletKit
import MarketKit
import Testing
@testable import WalletCore

struct DogecoinIntegrationTests {
    private let p2pkhAddress = "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC"
    private let p2shAddress = "AETZJzedcmLM2rxCM6VqCGF3YEMUjA3jMw"

    @Test
    func chainMetadataIsNativeOnlyBip44() {
        #expect(BlockchainType.supported.contains(.dogecoin))
        #expect(BtcBlockchainManager.blockchainTypes.contains(.dogecoin))
        #expect(BlockchainType.dogecoin.defaultTokenQuery == TokenQuery(blockchainType: .dogecoin, tokenType: .native))
        #expect(BlockchainType.dogecoin.nativeTokenQueries == [TokenQuery(blockchainType: .dogecoin, tokenType: .native)])
        #expect(BlockchainType.dogecoin.description == "DOGE")
        #expect(BlockchainType.dogecoin.blockTime == 60)
        #expect(BlockchainType.dogecoin.uriScheme == "dogecoin")
        #expect(BlockchainType.dogecoin.removeScheme)
        #expect(BlockchainType.dogecoin.order > BlockchainType.dash.order)
        #expect(BlockchainType.dogecoin.order < BlockchainType.litecoin.order)
        #expect(ExtendedKeyService.Blockchain.dogecoin.coinType == 3)
        #expect(ExtendedKeyService.Blockchain.dogecoin.extendedKeyCoinType == .bitcoin)
        #expect(DogecoinAdapter.confirmationsThreshold == 1)
    }

    @Test
    func mnemonicAndNativeWatchAccountSupportDogecoin() throws {
        let native = token(type: .native)
        let derived = token(type: .derived(derivation: .bip44))
        let words = try Mnemonic.generate()
        let mnemonic = AccountType.mnemonic(
            words: words,
            salt: "",
            bip39Compliant: true
        )
        let watch = AccountType.btcAddress(
            address: p2pkhAddress,
            blockchainType: .dogecoin,
            tokenType: .native
        )

        #expect(mnemonic.supports(token: native))
        #expect(mnemonic.supports(token: derived) == false)
        #expect(watch.supports(token: native))
        #expect(watch.supports(token: derived) == false)

        let firstAddress = try DogecoinAdapter.firstAddress(accountType: mnemonic)
        #expect(firstAddress.hasPrefix("D"))
        #expect(try dogecoinAddressConverter().convert(address: firstAddress).scriptType == .p2pkh)

        let decoded = AccountType.decode(
            uniqueId: watch.uniqueId(hashed: false),
            type: AccountType.Abstract(watch)
        )
        let restored = try #require(decoded)
        #expect(restored == watch)
        #expect(restored.watchAddress == p2pkhAddress)
    }

    @Test
    func extendedKeyRequiresBitcoinVersionFamilyAndBip44() throws {
        let words = try Mnemonic.generate()
        let seed = try #require(Mnemonic.seed(mnemonic: words))
        let bitcoinKey = HDExtendedKey.private(
            key: HDPrivateKey(seed: seed, xPrivKey: HDExtendedKeyVersion.xprv.rawValue)
        )
        let litecoinKey = HDExtendedKey.private(
            key: HDPrivateKey(seed: seed, xPrivKey: HDExtendedKeyVersion.Ltpv.rawValue)
        )
        let native = token(type: .native)

        #expect(AccountType.hdExtendedKey(key: bitcoinKey).supports(token: native))
        #expect(AccountType.hdExtendedKey(key: litecoinKey).supports(token: native) == false)
    }

    @Test
    func addressPolicyAcceptsP2pkhAndP2shButWatchesOnlyP2pkh() throws {
        let converter = dogecoinAddressConverter()
        let p2pkh = try converter.convert(address: p2pkhAddress)
        let p2sh = try converter.convert(address: p2shAddress)

        #expect(p2pkh.scriptType == .p2pkh)
        #expect(p2sh.scriptType == .p2sh)

        let p2pkhParsed = BitcoinAddress(
            raw: p2pkhAddress,
            blockchainType: .dogecoin,
            tokenType: .native,
            scriptType: p2pkh.scriptType
        )
        let p2shParsed = BitcoinAddress(
            raw: p2shAddress,
            blockchainType: .dogecoin,
            tokenType: .native,
            scriptType: p2sh.scriptType
        )

        #expect(bitcoinWatchAccountType(address: p2pkhParsed) != nil)
        #expect(bitcoinWatchAccountType(address: p2shParsed) == nil)
    }

    @Test
    func bip21DeepLinkKeepsDogecoinAmountAndStripsScheme() throws {
        let parser = AddressUriParser(blockchainType: .dogecoin, tokenType: .native)
        let uri = try parser.parse(url: "dogecoin:\(p2pkhAddress)?amount=12.5&label=Tip")

        #expect(uri.scheme == "dogecoin")
        #expect(uri.address == p2pkhAddress)
        #expect(uri.amount == .decimals(Decimal(string: "12.5")!))
        #expect(uri.parameters[.label] == "Tip")
    }

    @Test
    func syncModeRespectsDogecoinSelectionAndAccountOrigin() {
        #expect(
            resolveBtcSyncMode(
                blockchainType: .dogecoin,
                accountOrigin: .created,
                restoreMode: .blockchain
            ) == .full
        )
        #expect(
            resolveBtcSyncMode(
                blockchainType: .dogecoin,
                accountOrigin: .created,
                restoreMode: .blockchair
            ) == .blockchair
        )
        #expect(
            resolveBtcSyncMode(
                blockchainType: .dogecoin,
                accountOrigin: .created,
                restoreMode: .hybrid
            ) == .api
        )
        #expect(
            resolveBtcSyncMode(
                blockchainType: .bitcoin,
                accountOrigin: .created,
                restoreMode: .blockchain
            ) == .blockchair
        )
        #expect(
            resolveBtcSyncMode(
                blockchainType: .dash,
                accountOrigin: .created,
                restoreMode: .blockchain
            ) == .api
        )
        #expect(
            resolveBtcSyncMode(
                blockchainType: .ecash,
                accountOrigin: .created,
                restoreMode: .blockchain
            ) == .api
        )
        #expect(dogecoinUsesRecentPinnedFullSync(accountOrigin: .created, watchAccount: false))
        #expect(dogecoinUsesRecentPinnedFullSync(accountOrigin: .restored, watchAccount: false) == false)
        #expect(dogecoinUsesRecentPinnedFullSync(accountOrigin: .created, watchAccount: true) == false)
    }

    @Test
    func feePolicyHasHardAndRecommendedFloors() async throws {
        let rates = try await DogecoinFeeRateProvider().feeRates()

        #expect(rates.minimum == 100)
        #expect(rates.recommended == 1_000)

        let thorRates = resolveUtxoFeeRates(
            providerFeeRates: rates,
            initialTransactionSettings: .bitcoin(recommendedFeeRate: 2_500)
        )
        #expect(thorRates.recommended == 2_500)
        #expect(thorRates.minimum == 2_500)
    }

    @Test
    func dogecoinDisablesBitcoinOnlySendFeatures() {
        #expect(BtcBlockchainManager.allowedRbfBlockchainTypes.contains(.dogecoin) == false)
        #expect(BlockchainType.dogecoin.resendable)
    }

    @Test
    func swapMappingsAndThorchainUtxoPolicyAreSafe() throws {
        #expect(USwapMultiSwapProvider.blockchainTypeMap["dogecoin"] == .dogecoin)
        #expect(thorChainBlockchainType(assetBlockchainId: "DOGE") == .dogecoin)

        let filters = thorChainUtxoFilters(blockchainType: .dogecoin)
        #expect(filters.scriptTypes == [.p2pkh])
        #expect(filters.maxOutputsCountForInputs == 10)
        #expect(
            try effectiveThorChainFeeRate(
                blockchainType: .dogecoin,
                selectedFeeRate: 50,
                recommendedGasRate: 75
            ) == 100
        )
        #expect(
            try effectiveThorChainFeeRate(
                blockchainType: .dogecoin,
                selectedFeeRate: 2_000,
                recommendedGasRate: 1_000
            ) == 2_000
        )
        #expect(
            try effectiveThorChainFeeRate(
                blockchainType: .dogecoin,
                selectedFeeRate: nil,
                recommendedGasRate: nil
            ) == nil
        )
    }

    @Test
    func thorchainConfirmationUsesSafeDogecoinUtxoPolicy() throws {
        let dogecoin = token(type: .native)

        let minimumPolicy = try thorChainUtxoSendPolicy(
            tokenIn: dogecoin,
            transactionSettings: .bitcoin(satoshiPerByte: 50),
            recommendedGasRate: 75,
            gasRateUnits: "satsperbyte",
            dustThreshold: 100_000_000
        )
        #expect(minimumPolicy.feeRate == 100)
        #expect(minimumPolicy.minimumSendValue == 100_000_001)
        #expect(minimumPolicy.utxoFilters.scriptTypes == [.p2pkh])
        #expect(minimumPolicy.utxoFilters.maxOutputsCountForInputs == 10)

        let selectedPolicy = try thorChainUtxoSendPolicy(
            tokenIn: dogecoin,
            transactionSettings: .bitcoin(satoshiPerByte: 2_000),
            recommendedGasRate: 1_000,
            gasRateUnits: "SatsPerByte",
            dustThreshold: 100_000_000
        )
        #expect(selectedPolicy.feeRate == 2_000)
        #expect(selectedPolicy.utxoFilters.scriptTypes == [.p2pkh])
        #expect(selectedPolicy.utxoFilters.maxOutputsCountForInputs == 10)

        let liveQuotePolicy = try thorChainUtxoSendPolicy(
            tokenIn: dogecoin,
            transactionSettings: .bitcoin(satoshiPerByte: 1_000),
            recommendedGasRate: 750_000,
            gasRateUnits: "satsperbyte",
            dustThreshold: 100_000_000
        )
        #expect(liveQuotePolicy.feeRate == 750_000)
    }

    @Test
    func thorchainConfirmationRejectsUnsafeGasRateUnits() {
        let dogecoin = token(type: .native)

        #expect(throws: ThorChainUtxoPolicyError.invalidGasRateUnits(nil)) {
            try thorChainUtxoSendPolicy(
                tokenIn: dogecoin,
                transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                recommendedGasRate: 1_000,
                gasRateUnits: nil,
                dustThreshold: 100_000_000
            )
        }
        #expect(throws: ThorChainUtxoPolicyError.invalidGasRateUnits("")) {
            try thorChainUtxoSendPolicy(
                tokenIn: dogecoin,
                transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                recommendedGasRate: 1_000,
                gasRateUnits: "",
                dustThreshold: 100_000_000
            )
        }
        #expect(throws: ThorChainUtxoPolicyError.invalidGasRateUnits(" satsperbyte ")) {
            try thorChainUtxoSendPolicy(
                tokenIn: dogecoin,
                transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                recommendedGasRate: 1_000,
                gasRateUnits: " satsperbyte ",
                dustThreshold: 100_000_000
            )
        }
        #expect(throws: ThorChainUtxoPolicyError.invalidGasRateUnits("coinsperbyte")) {
            try thorChainUtxoSendPolicy(
                tokenIn: dogecoin,
                transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                recommendedGasRate: 1_000,
                gasRateUnits: "coinsperbyte",
                dustThreshold: 100_000_000
            )
        }
    }

    @Test
    func thorchainConfirmationRejectsUnsafeGasRates() {
        let dogecoin = token(type: .native)

        for gasRate in [nil, 0, -1, 1_000_001, Int.max] as [Int?] {
            #expect(throws: ThorChainUtxoPolicyError.invalidRecommendedGasRate(gasRate)) {
                try thorChainUtxoSendPolicy(
                    tokenIn: dogecoin,
                    transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                    recommendedGasRate: gasRate,
                    gasRateUnits: "satsperbyte",
                    dustThreshold: 100_000_000
                )
            }
        }

        for selectedFeeRate in [0, -1, 1_000_001, Int.max] {
            #expect(throws: ThorChainUtxoPolicyError.invalidSelectedFeeRate(selectedFeeRate)) {
                try thorChainUtxoSendPolicy(
                    tokenIn: dogecoin,
                    transactionSettings: .bitcoin(satoshiPerByte: selectedFeeRate),
                    recommendedGasRate: 750_000,
                    gasRateUnits: "satsperbyte",
                    dustThreshold: 100_000_000
                )
            }
        }
    }

    @Test
    func thorchainConfirmationRejectsUnsafeDustThresholds() {
        let dogecoin = token(type: .native)

        for dustThreshold in [nil, 0, -1, 1_000_000_001, Int.max] as [Int?] {
            #expect(throws: ThorChainUtxoPolicyError.invalidDustThreshold(dustThreshold)) {
                try thorChainUtxoSendPolicy(
                    tokenIn: dogecoin,
                    transactionSettings: .bitcoin(satoshiPerByte: 1_000),
                    recommendedGasRate: 750_000,
                    gasRateUnits: "satsperbyte",
                    dustThreshold: dustThreshold
                )
            }
        }
    }

    @Test
    func thorchainConfirmationDisplaysCommittedRecipient() async throws {
        let walletAddress = "0x1111111111111111111111111111111111111111"
        let customRecipient = "0x2222222222222222222222222222222222222222"

        let customDestination = try await thorChainConfirmationDestination(recipient: customRecipient) {
            walletAddress
        }
        #expect(customDestination == customRecipient)

        let walletDestination = try await thorChainConfirmationDestination(recipient: nil) {
            walletAddress
        }
        #expect(walletDestination == walletAddress)
    }

    @Test
    func openCryptoPayDoesNotAdvertiseDogecoin() {
        #expect(OpenCryptoPayBroadcasterFactory.unstoppable.supportedChains.values.contains(.dogecoin) == false)
    }

    private func token(type: TokenType) -> Token {
        Token(
            coin: Coin(uid: "dogecoin", name: "Dogecoin", code: "DOGE"),
            blockchain: Blockchain(type: .dogecoin, name: "Dogecoin", explorerUrl: nil),
            type: type,
            decimals: 8
        )
    }
}
