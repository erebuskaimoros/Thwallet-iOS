import UIKit

enum PublicAddressModule {
    static func evmViewController(account: Account) -> UIViewController? {
        guard let service = EvmAddressService(account: account) else {
            return nil
        }

        let viewModel = PublicAddressViewModel(service: service)
        return PublicAddressViewController(viewModel: viewModel, accountType: .evm)
    }

    static func tronViewController(account: Account) -> UIViewController? {
        guard let service = TronAddressService(account: account) else {
            return nil
        }

        let viewModel = PublicAddressViewModel(service: service)
        return PublicAddressViewController(viewModel: viewModel, accountType: .tron)
    }

    static func xrpViewController(account: Account) -> UIViewController? {
        guard let service = XrpAddressService(account: account) else {
            return nil
        }

        let viewModel = PublicAddressViewModel(service: service)
        return PublicAddressViewController(viewModel: viewModel, accountType: .xrp)
    }
}

extension PublicAddressModule {
    enum AbstractAccountType {
        case evm, tron, xrp
    }
}
