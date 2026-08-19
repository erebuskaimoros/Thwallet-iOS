import Foundation
import Testing
import WalletCore

struct XrpPublicApiTests {
    @Test
    func xrpKitManagerIsVisibleAcrossTheModuleBoundary() {
        let exposedType: Any.Type = XrpKitManager.self
        #expect(String(describing: exposedType) == "XrpKitManager")
    }

    @Test
    func xrpHistorySinglesUseRxSwiftErrorEvents() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterSource = try String(
            contentsOf: repository.appendingPathComponent(
                "packages/WalletCore/Sources/WalletCore/Core/Adapters/XrpAdapter.swift"
            ),
            encoding: .utf8
        )

        #expect(!adapterSource.contains("observer(.failure("))
        #expect(adapterSource.components(separatedBy: "observer(.error(error))").count >= 3)
    }
}
