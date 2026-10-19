import Testing
import Foundation
@testable import BusBus

struct SupportedRegionsTests {
    private let haifa = GeoPoint(lat: 32.8166, lon: 34.9895)
    private let boston = GeoPoint(lat: 42.3298, lon: -71.0839)
    private let bergen = GeoPoint(lat: 60.3917, lon: 5.3246)
    private let cairo = GeoPoint(lat: 30.0444, lon: 31.2357)
    private let princeEdward = GeoPoint(lat: 22.3241, lon: 114.1699)
    private let taiPoMarket = GeoPoint(lat: 22.4444, lon: 114.1695)

    @Test func aPointFindsTheRegionItIsIn() {
        #expect(SupportedRegions.region(containing: haifa)?.providerID == "bus.gov.il")
        #expect(SupportedRegions.region(containing: boston)?.providerID == "mbta")
        #expect(SupportedRegions.region(containing: bergen)?.providerID == "entur")
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 35.6812, lon: 139.7671))?.providerID == "odpt-toei")
    }

    @Test func nowhereCoveredIsNil() {
        #expect(SupportedRegions.region(containing: cairo) == nil)
        #expect(SupportedRegions.regions(containing: cairo).isEmpty)
    }

    /// Where operators overlap, every one of them is offered, the most local first.
    @Test func overlappingRegionsAreAllOfferedSmallestFirst() {
        let here = SupportedRegions.regions(containing: taiPoMarket).map(\.providerID)
        #expect(here.first == "hk-mtrbus")
        #expect(Set(here) == ["hk-mtrbus", "hk-kmb", "hk-citybus", "hk-gmb"])
        #expect(SupportedRegions.region(containing: princeEdward)?.providerID == "hk-kmb")
    }

    @Test func regionIDsAreUnique() {
        let ids = SupportedRegions.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func countryCodesAreISOAlpha2() {
        for code in SupportedRegions.countryCodes {
            #expect(code.count == 2 && code == code.uppercased(), "\(code)")
        }
    }

    @Test func boundsAreWellFormed() {
        for region in SupportedRegions.all {
            let b = region.bounds
            #expect(b.minLat < b.maxLat && b.minLon < b.maxLon, "\(region.id)")
        }
    }

    /// A licence that asks for a credit line gets one, whatever region the provider serves.
    @Test func everyShippingProviderCarriesItsCreditLine() {
        for region in SupportedRegions.all {
            let attribution = TransitProviders.provider(id: region.providerID).attribution
            #expect(attribution?.isEmpty == false, "\(region.providerID) has no attribution")
        }
    }
}

@MainActor
struct AutomaticProviderTests {
    private let haifa = GeoPoint(lat: 32.8166, lon: 34.9895)
    private let boston = GeoPoint(lat: 42.3298, lon: -71.0839)
    private let cairo = GeoPoint(lat: 30.0444, lon: 31.2357)
    private let taiPoMarket = GeoPoint(lat: 22.4444, lon: 114.1695)

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "auto-\(UUID().uuidString)")!)
    }

    private func stop(_ code: String) -> TransitStop {
        TransitStop(code: code, name: code, city: nil, location: GeoPoint(lat: 42.33, lon: -71.08))
    }

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    @Test func automaticIsTheDefault() {
        #expect(makeStore().providerIsAutomatic)
    }

    @Test func setupFollowsTheRider() {
        let store = makeStore()
        #expect(store.adoptLocation(boston)?.providerID == "mbta")
        #expect(store.providerID == "mbta")
        #expect(store.adoptLocation(haifa)?.providerID == "bus.gov.il")
        #expect(store.providerID == "bus.gov.il")
    }

    @Test func outsideEveryRegionTheProviderIsLeftAlone() {
        let store = makeStore()
        store.adoptLocation(boston)
        #expect(store.adoptLocation(cairo) == nil)
        #expect(store.providerID == "mbta")
    }

    /// A rider who chose KMB over MTR Bus is not switched back by the next location fix.
    @Test func aProviderThatCoversThePointIsKept() {
        let store = makeStore()
        #expect(store.adoptLocation(taiPoMarket)?.providerID == "hk-mtrbus")
        store.providerID = "hk-kmb"
        #expect(store.adoptLocation(taiPoMarket)?.providerID == "hk-kmb")
        #expect(store.providerID == "hk-kmb")
    }

    @Test func aChosenProviderIsNeverReplaced() {
        let store = makeStore()
        store.providerIsAutomatic = false
        store.providerID = "stride"
        #expect(store.adoptLocation(boston) == nil)
        #expect(store.providerID == "stride")
    }

    @Test func theChoiceSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "auto-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.providerIsAutomatic = false
        #expect(SettingsStore(defaults: defaults).providerIsAutomatic == false)
    }

    /// Opening setup somewhere else must not repoint a board that is already running.
    @Test func theBoardKeepsTheProviderItsStopCameFrom() {
        let store = makeStore()
        store.adoptLocation(boston)
        store.apply(stop: stop("64"), lines: [line("1")], providerID: store.providerID)
        store.adoptLocation(haifa)
        #expect(store.provider.id == "bus.gov.il")
        #expect(store.boardProvider.id == "mbta")
    }

    @Test func historyRemembersEachEntrysProvider() {
        let store = makeStore()
        store.apply(stop: stop("64"), lines: [line("1")], providerID: "mbta")
        #expect(store.savedSetups.first?.providerID == "mbta")
    }

    @Test func historySavedBeforeProvidersFollowedLocationStillDecodes() throws {
        let legacy = """
        {"stop":{"code":"41122","name":"A","location":{"lat":32.8,"lon":34.9}},"lines":[],"lastUsedAt":0,"pinned":false}
        """
        let setup = try JSONDecoder().decode(SavedSetup.self, from: Data(legacy.utf8))
        #expect(setup.providerID == nil)
    }
}
