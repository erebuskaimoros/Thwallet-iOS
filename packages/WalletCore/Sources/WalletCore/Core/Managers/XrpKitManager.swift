import Foundation
import GRDB

final class XrpKitManager {
    static let defaultMainnetEndpoint = URL(string: "https://xrplcluster.com")!

    private let dbPool: DatabasePool
    private let endpoint: URL
    private let queue = DispatchQueue(label: "\(AppConfig.label).xrp-kit-manager", qos: .userInitiated)

    private weak var cachedKit: XrpKit?
    private var cachedAccount: Account?

    init(dbPool: DatabasePool, endpoint: URL = XrpKitManager.defaultMainnetEndpoint) {
        self.dbPool = dbPool
        self.endpoint = endpoint
    }

    private func makeKit(account: Account) throws -> XrpKit {
        if let cachedKit, cachedAccount == account {
            return cachedKit
        }

        let credentials = try Self.credentials(accountType: account.type)
        let transport = XrpHttpRpcTransport(endpoint: endpoint)
        let rpc = XrpRpcClient(transport: transport)
        let storage = XrpStorage(dbPool: dbPool, account: credentials.address)
        let kit = XrpKit(address: credentials.address, privateKey: credentials.privateKey, rpc: rpc, storage: storage)

        cachedKit = kit
        cachedAccount = account
        return kit
    }
}

extension XrpKitManager {
    var xrpKit: XrpKit? {
        queue.sync { cachedKit }
    }

    func xrpKit(account: Account) throws -> XrpKit {
        try queue.sync { try makeKit(account: account) }
    }

    static func address(accountType: AccountType) throws -> String {
        try credentials(accountType: accountType).address
    }

    static func privateKey(accountType: AccountType) throws -> Data {
        guard let privateKey = try credentials(accountType: accountType).privateKey else {
            throw XrpRuntimeError.signerUnavailable
        }
        return privateKey
    }

    func clear(except accounts: [Account]) throws {
        var addresses = Set<String>()
        for account in accounts {
            switch account.type {
            case .mnemonic, .xrpAddress:
                // Never turn a derivation or persisted-address failure into a
                // destructive cleanup decision for an account that must be kept.
                addresses.insert(try Self.address(accountType: account.type))
            default:
                continue
            }
        }
        try XrpStorage.clear(dbPool: dbPool, exceptAccounts: addresses)
    }

    private static func credentials(accountType: AccountType) throws -> (address: String, privateKey: Data?) {
        switch accountType {
        case .mnemonic:
            guard let seed = accountType.mnemonicSeed else {
                throw AdapterError.unsupportedAccount
            }
            let privateKey = try XrpKeyDerivation.privateKey(seed: seed)
            let publicKey = try XrpKeyDerivation.compressedPublicKey(privateKey: privateKey)
            return (try XrpAddressCodec.classicAddress(publicKey: publicKey), privateKey)
        case let .xrpAddress(address):
            _ = try XrpAddressCodec.accountId(classicAddress: address)
            return (address, nil)
        default:
            throw AdapterError.unsupportedAccount
        }
    }
}
