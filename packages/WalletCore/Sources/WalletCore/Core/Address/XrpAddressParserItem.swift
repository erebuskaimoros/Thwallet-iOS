import MarketKit
import RxSwift

final class XrpAddressParserItem: IAddressParserItem {
    let blockchainType: BlockchainType = .ripple

    func handle(address: String) -> Single<Address> {
        do {
            _ = try XrpAddressCodec.resolve(address, separateTag: nil, network: .mainnet)
            return .just(Address(raw: address, blockchainType: blockchainType))
        } catch {
            return .error(error)
        }
    }

    func isValid(address: String) -> Single<Bool> {
        .just((try? XrpAddressCodec.resolve(address, separateTag: nil, network: .mainnet)) != nil)
    }
}
