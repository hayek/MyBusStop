import Testing
@testable import BusBus

struct SmokeTests {
    @Test func appModuleIsImportable() {
        #expect(TransitProviders.all.count >= 3)
    }
}
