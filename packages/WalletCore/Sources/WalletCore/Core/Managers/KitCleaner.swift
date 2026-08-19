import Foundation

public class KitCleaner {
    private let accountManager: AccountManager
    private let xrpKitManager: XrpKitManager

    public init(accountManager: AccountManager, xrpKitManager: XrpKitManager) {
        self.accountManager = accountManager
        self.xrpKitManager = xrpKitManager
    }
}

public extension KitCleaner {
    func clear() {
        let accounts = accountManager.allAccounts
        let accountIds = accounts.map(\.id)

        DispatchQueue.global(qos: .background).async {
            try? BitcoinAdapter.clear(except: accountIds)
            try? LitecoinAdapter.clear(except: accountIds)
            try? BitcoinCashAdapter.clear(except: accountIds)
            try? DashAdapter.clear(except: accountIds)
            try? DogecoinAdapter.clear(except: accountIds)
            try? EvmAdapter.clear(except: accountIds)
            try? EvmNftAdapter.clear(except: accountIds)
            try? ZcashAdapter.clear(except: accountIds)
            try? TronAdapter.clear(except: accountIds)
            try? MoneroAdapter.clear(except: accountIds)
            try? ZanoAdapter.clear(except: accountIds)
            try? self.xrpKitManager.clear(except: accounts)
        }
    }
}
