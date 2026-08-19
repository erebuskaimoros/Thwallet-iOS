import Foundation

protocol IXrpRpcClient: Sendable {
    func serverState() async throws -> XrpServerState
    func validatedLedger() async throws -> XrpLedgerReference
    func feeSettings(ledger: XrpLedgerReference) async throws -> XrpFeeSettings
    func accountState(address: String, ledger: XrpLedgerReference) async throws -> XrpAccountState
    func openLedgerFeeDrops() async throws -> UInt64
    func accountTransactions(address: String, fromLedger: UInt32, toLedger: UInt32, marker: XrpJsonValue?) async throws -> XrpHistoryPage
    func transaction(hash: String) async throws -> XrpTransactionLookup?
    func submit(blobHex: String) async throws -> XrpSubmitResult
}

protocol IXrpRpcTransport: Sendable {
    func request(method: String, params: [String: XrpJsonValue]) async throws -> XrpJsonValue
}

final class XrpHttpRpcTransport: IXrpRpcTransport, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func request(method: String, params: [String: XrpJsonValue]) async throws -> XrpJsonValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            XrpJsonValue.object([
                "jsonrpc": .string("2.0"),
                "id": .uint(1),
                "method": .string(method),
                "params": .array([.object(params)]),
            ])
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw XrpRuntimeError.invalidResponse("XRPL endpoint returned a non-success HTTP status")
        }
        let envelope = try JSONDecoder().decode(XrpJsonValue.self, from: data)
        guard let root = envelope.object, let result = root["result"], let object = result.object else {
            throw XrpRuntimeError.invalidResponse("XRPL response has no result")
        }
        if object["status"]?.string == "error" || object["error"] != nil {
            let name = object["error"]?.string ?? "rpcError"
            let message = object["error_message"]?.string ?? object["error_exception"]?.string ?? name
            let code = object["error_code"]?.uint64.flatMap(Int.init(exactly:))
            throw name == "actNotFound" ? XrpRuntimeError.accountNotFound : XrpRuntimeError.rpc(code: code, message: message)
        }
        return result
    }
}

final class XrpRpcClient: IXrpRpcClient, @unchecked Sendable {
    static let feeSettingsIndex = "4BC50C9B0D8515D3EAAE1E74B29A95804346C491EE1A95BF25E4AAB854A6A651"
    private let transport: IXrpRpcTransport

    init(transport: IXrpRpcTransport) { self.transport = transport }

    func serverState() async throws -> XrpServerState {
        let result = try await object("server_info")
        guard let info = result["info"]?.object,
              let networkId = info["network_id"]?.uint32,
              let validated = info["validated_ledger"]?.object,
              let sequence = validated["seq"]?.uint32,
              let complete = info["complete_ledgers"]?.string
        else { throw XrpRuntimeError.invalidResponse("Incomplete server_info") }
        guard networkId == 0 else { throw XrpRuntimeError.wrongNetwork(networkId) }
        return XrpServerState(networkId: networkId, validatedLedger: sequence, completeLedgers: try XrpLedgerRanges(complete))
    }

    func validatedLedger() async throws -> XrpLedgerReference {
        let result = try await object("ledger", params: ["ledger_index": .string("validated"), "transactions": .bool(false)])
        guard let ledger = result["ledger"]?.object,
              let index = (ledger["ledger_index"] ?? result["ledger_index"])?.uint32,
              let hash = ledger["hash"]?.string ?? result["ledger_hash"]?.string,
              result["validated"]?.bool == true,
              index > 0,
              Self.isHash(hash)
        else { throw XrpRuntimeError.invalidResponse("Incomplete validated ledger") }
        return XrpLedgerReference(index: index, hash: hash)
    }

    func feeSettings(ledger: XrpLedgerReference) async throws -> XrpFeeSettings {
        let result = try await object("ledger_entry", params: [
            "index": .string(Self.feeSettingsIndex), "ledger_hash": .string(ledger.hash), "binary": .bool(false),
        ])
        guard result["validated"]?.bool == true,
              result["ledger_hash"]?.string == ledger.hash,
              result["ledger_index"]?.uint32 == ledger.index,
              let node = result["node"]?.object,
              let base = (node["BaseFeeDrops"] ?? node["BaseFee"])?.uint64,
              let reserveBase = (node["ReserveBaseDrops"] ?? node["ReserveBase"])?.uint64,
              let reserveIncrement = (node["ReserveIncrementDrops"] ?? node["ReserveIncrement"])?.uint64,
              base <= XrpAmount.maximumDrops,
              reserveBase <= XrpAmount.maximumDrops,
              reserveIncrement <= XrpAmount.maximumDrops
        else { throw XrpRuntimeError.invalidResponse("Uncommitted FeeSettings response") }
        return XrpFeeSettings(baseFeeDrops: base, reserveBaseDrops: reserveBase, reserveIncrementDrops: reserveIncrement)
    }

    func accountState(address: String, ledger: XrpLedgerReference) async throws -> XrpAccountState {
        let result = try await object("account_info", params: [
            "account": .string(address), "ledger_hash": .string(ledger.hash), "strict": .bool(true), "queue": .bool(false),
        ])
        guard result["validated"]?.bool == true,
              result["ledger_hash"]?.string == ledger.hash,
              result["ledger_index"]?.uint32 == ledger.index,
              let data = result["account_data"]?.object,
              data["Account"]?.string == address,
              let balance = data["Balance"]?.uint64,
              let sequence = data["Sequence"]?.uint32,
              let ownerCount = data["OwnerCount"]?.uint32,
              let flags = data["Flags"]?.uint32,
              balance <= XrpAmount.maximumDrops
        else { throw XrpRuntimeError.invalidResponse("Uncommitted account_info response") }
        return XrpAccountState(address: address, balanceDrops: balance, sequence: sequence, ownerCount: ownerCount, flags: flags)
    }

    func openLedgerFeeDrops() async throws -> UInt64 {
        let result = try await object("fee")
        guard let fee = result["drops"]?.object?["open_ledger_fee"]?.uint64 else {
            throw XrpRuntimeError.invalidResponse("Incomplete fee response")
        }
        return fee
    }

    func accountTransactions(address: String, fromLedger: UInt32, toLedger: UInt32, marker: XrpJsonValue?) async throws -> XrpHistoryPage {
        var params: [String: XrpJsonValue] = [
            "account": .string(address), "ledger_index_min": .uint(UInt64(fromLedger)),
            "ledger_index_max": .uint(UInt64(toLedger)), "binary": .bool(false),
            "forward": .bool(true), "limit": .uint(200),
        ]
        params["marker"] = marker
        let result = try await object("account_tx", params: params)
        guard result["validated"]?.bool == true,
              result["account"]?.string == address,
              let returnedMin = result["ledger_index_min"]?.uint32,
              let returnedMax = result["ledger_index_max"]?.uint32,
              returnedMin == fromLedger,
              returnedMax == toLedger,
              let entries = result["transactions"]?.array
        else {
            throw XrpRuntimeError.invalidResponse("XRPL account_tx returned a different ledger range")
        }
        return XrpHistoryPage(
            entries: entries,
            marker: result["marker"],
            ledgerIndexMin: returnedMin,
            ledgerIndexMax: returnedMax
        )
    }

    func transaction(hash: String) async throws -> XrpTransactionLookup? {
        do {
            let result = try await object("tx", params: ["transaction": .string(hash), "binary": .bool(false)])
            guard let returnedHash = (result["hash"] ?? result["tx_json"]?.object?["hash"])?.string,
                  returnedHash == hash
            else { throw XrpRuntimeError.invalidResponse("XRPL transaction lookup hash mismatch") }
            return XrpTransactionLookup(
                hash: returnedHash,
                validated: result["validated"]?.bool == true,
                resultCode: result["meta"]?.object?["TransactionResult"]?.string,
                ledgerIndex: result["ledger_index"]?.uint32
            )
        } catch XrpRuntimeError.rpc(let code, let message)
            where code == 29
                || message.caseInsensitiveCompare("Transaction not found.") == .orderedSame
                || message.lowercased().contains("txnnotfound")
        {
            return nil
        }
    }

    func submit(blobHex: String) async throws -> XrpSubmitResult {
        let result = try await object("submit", params: ["tx_blob": .string(blobHex), "fail_hard": .bool(false)])
        guard let engineResult = result["engine_result"]?.string else {
            throw XrpRuntimeError.invalidResponse("Incomplete submit response")
        }
        return XrpSubmitResult(engineResult: engineResult, engineResultMessage: result["engine_result_message"]?.string)
    }

    private func object(_ method: String, params: [String: XrpJsonValue] = [:]) async throws -> [String: XrpJsonValue] {
        var versionedParams = params
        versionedParams["api_version"] = .uint(2)
        let result = try await transport.request(method: method, params: versionedParams)
        guard let object = result.object else { throw XrpRuntimeError.invalidResponse("XRPL result is not an object") }
        return object
    }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x41 ... 0x46).contains($0)
        }
    }
}
