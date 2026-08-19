import Testing
import WalletCore

struct XrpPublicApiTests {
    @Test
    func xrpKitManagerIsVisibleAcrossTheModuleBoundary() {
        let exposedType: Any.Type = XrpKitManager.self
        #expect(String(describing: exposedType) == "XrpKitManager")
    }
}
