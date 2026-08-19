import Foundation

/// Parses the narrow, address-only portion of XLS-32-style XRP payment URIs.
/// A destination tag is encoded back into a mainnet X-address so it survives
/// the shared deep-link pipeline without being confused with a transaction memo.
final class XrpUriParser: UriParser {
    func canHandle(scheme: String, components _: URLComponents) -> Bool {
        scheme.lowercased() == "xrpl"
    }

    func parse(scheme: String, components: URLComponents) throws -> AddressUri {
        let queryItems = components.queryItems ?? []

        for item in queryItems where item.name.lowercased().hasPrefix("req-") {
            throw AddressUriParser.ParseError.wrongUri
        }

        var queryValues = [String: [String]]()
        for item in queryItems {
            guard let value = item.value else { throw AddressUriParser.ParseError.wrongUri }
            queryValues[item.name.lowercased(), default: []].append(value)
        }
        let criticalKeys = Set(["address", "tag", "dt", "amount", "memo"])
        guard queryValues.allSatisfy({ entry in
            !criticalKeys.contains(entry.key) || entry.value.count == 1
        }) else { throw AddressUriParser.ParseError.wrongUri }
        let query = queryValues.mapValues { $0.last! }

        let rawAddress: String
        if components.path.lowercased() == "account" {
            guard let address = query["address"], !address.isEmpty else {
                throw AddressUriParser.ParseError.wrongUri
            }
            rawAddress = address
        } else {
            guard !components.path.isEmpty else {
                throw AddressUriParser.ParseError.wrongUri
            }
            rawAddress = components.path
        }

        let explicitTag = try query["tag"].map { try XrpAddressCodec.destinationTag(decimalString: $0) }
        let legacyTag = try query["dt"].map { try XrpAddressCodec.destinationTag(decimalString: $0) }
        if let explicitTag, let legacyTag, explicitTag != legacyTag {
            throw AddressUriParser.ParseError.wrongUri
        }
        let tagString = query["tag"] ?? query["dt"]
        let tag = explicitTag ?? legacyTag
        let destination = try XrpAddressCodec.resolve(rawAddress, separateTag: tag, network: .mainnet)
        let address = try XrpAddressCodec.encodeXAddress(
            classicAddress: destination.classicAddress,
            destinationTag: destination.destinationTag,
            network: .mainnet
        )

        var uri = AddressUri(scheme: scheme)
        uri.address = destination.destinationTag == nil ? destination.classicAddress : address
        if let tagString {
            uri.parameters[.destinationTag] = tagString
        }
        if let amount = query["amount"] {
            uri.parameters[.amount] = amount
        }
        if let memo = query["memo"] {
            uri.parameters[.memo] = memo
        }

        let handled = Set(["address", "tag", "dt", "amount", "memo"])
        uri.unhandledParameters = Dictionary(uniqueKeysWithValues: query.filter { !handled.contains($0.key) })
        return uri
    }
}
