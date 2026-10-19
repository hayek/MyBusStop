import Testing
import Foundation
@testable import BusBus

/// A provider switched off from the Firebase console is passed over as if its region were not there.
@MainActor
struct RemoteSwitchTests {
    private static func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "remote-\(UUID().uuidString)")!)
    }

    /// Covered by MTR Bus, KMB and Citybus, MTR Bus's box being the smallest.
    private static let tuenMun = GeoPoint(lat: 22.40, lon: 114.10)
    private static let telAviv = GeoPoint(lat: 32.08, lon: 34.78)

    @Test func theMostSpecificRegionWinsWhenNothingIsDisabled() {
        let settings = Self.store()
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-mtrbus")
    }

    @Test func aDisabledRegionIsSkippedForTheNextCandidate() {
        let settings = Self.store()
        settings.regionIsAvailable = { $0.providerID != "hk-mtrbus" }
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-kmb")
        #expect(settings.providerID == "hk-kmb")
    }

    @Test func aStickyProviderIsDroppedOnceItIsDisabled() {
        let settings = Self.store()
        settings.providerID = "hk-mtrbus"
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-mtrbus")
        settings.regionIsAvailable = { $0.providerID != "hk-mtrbus" }
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-kmb")
    }

    @Test func theOnlyRegionDisabledLeavesNoCoverage() {
        let settings = Self.store()
        settings.regionIsAvailable = { $0.providerID != "bus.gov.il" }
        #expect(settings.adoptLocation(Self.telAviv) == nil)
        #expect(!settings.providerIsAvailable("bus.gov.il"))
        #expect(settings.providerIsAvailable("hk-kmb"))
    }

    // MARK: Keyed providers

    private static let midtown = GeoPoint(lat: 40.7549, lon: -73.9840)

    @Test func aProviderWithoutItsAPIKeyIsPassedOver() {
        let settings = Self.store()
        settings.providerHasKey = { $0 != "mta-bustime" }
        #expect(settings.adoptLocation(Self.midtown) == nil)
        #expect(settings.providerID != "mta-bustime")
        #expect(!settings.providerIsAvailable("mta-bustime"))
    }

    @Test func aProviderWithItsAPIKeyIsOffered() {
        let settings = Self.store()
        settings.providerHasKey = { _ in true }
        #expect(settings.adoptLocation(Self.midtown)?.providerID == "mta-bustime")
        #expect(settings.providerIsAvailable("mta-bustime"))
    }

    // MARK: Transitous, the worldwide fallback

    /// Paris: covered by Transitous, by none of our regions.
    private static let paris = GeoPoint(lat: 48.8566, lon: 2.3522)

    @Test func outsideEveryRegionTransitousIsUsedOnlyWhenItsFlagIsOn() {
        let off = Self.store()
        off.transitousIsEnabled = { false }
        #expect(off.adoptLocation(Self.paris) == nil)
        #expect(off.providerID != TransitousProvider.providerID)
        #expect(!off.providerIsAvailable(TransitousProvider.providerID))

        let on = Self.store()
        on.transitousIsEnabled = { true }
        #expect(on.adoptLocation(Self.paris) == nil)
        #expect(on.providerID == TransitousProvider.providerID)
        #expect(on.isUsingWorldwideFallback)
        #expect(on.providerIsAvailable(TransitousProvider.providerID))
    }

    @Test func transitousNeverOverridesARealRegion() {
        let settings = Self.store()
        settings.transitousIsEnabled = { true }
        #expect(settings.adoptLocation(Self.telAviv)?.providerID == "bus.gov.il")
        #expect(settings.providerID == "bus.gov.il")
        // Once on the fallback, walking back into a region hands setup back to that region.
        #expect(settings.adoptLocation(Self.paris) == nil)
        #expect(settings.providerID == TransitousProvider.providerID)
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-mtrbus")
    }

    @Test func aProviderChosenInSettingsIsNeverReplacedByTransitous() {
        let settings = Self.store()
        settings.transitousIsEnabled = { true }
        settings.providerIsAutomatic = false
        settings.providerID = "mbta"
        #expect(settings.adoptLocation(Self.paris) == nil)
        #expect(settings.providerID == "mbta")
    }

    @Test func aRegionSwitchedOffDoesNotHandTheRiderToTransitousWhereAnotherRegionCovers() {
        let settings = Self.store()
        settings.transitousIsEnabled = { true }
        settings.regionIsAvailable = { $0.providerID != "hk-mtrbus" }
        #expect(settings.adoptLocation(Self.tuenMun)?.providerID == "hk-kmb")
    }
}
