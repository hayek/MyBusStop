import Testing
import Foundation
@testable import BusBus

struct OneBusAwayProviderTests {
    /// King County Metro's stops keep the number on their sign; every other agency keeps its full id,
    /// so a Sound Transit stop cannot be mistaken for a Metro one with the same number.
    @Test func stopCodesRoundTrip() {
        #expect(OneBusAwayProvider.stopCode("1_7160", signAgency: "1") == "7160")
        #expect(OneBusAwayProvider.stopCode("40_99603", signAgency: "1") == "40_99603")
        for id in ["1_7160", "40_99603", "29_2150", "1_431"] {
            #expect(OneBusAwayProvider.stopID(OneBusAwayProvider.stopCode(id, signAgency: "1"), signAgency: "1") == id)
        }
    }

    /// OneBusAway measures orientation counter-clockwise from east.
    @Test func orientationBecomesACompassHeading() {
        #expect(OneBusAwayProvider.compassBearing(0) == 90)
        #expect(OneBusAwayProvider.compassBearing(90) == 0)
        #expect(OneBusAwayProvider.compassBearing(180) == 270)
        #expect(OneBusAwayProvider.compassBearing(270) == 180)
    }

    @Test func seattleIsServedByOneBusAway() {
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 47.6097, lon: -122.3331))?.providerID == "oba-pugetsound")
        #expect(TransitProviders.provider(id: "oba-pugetsound").displayName.contains("Puget Sound"))
    }

    @Test func tampaIsServedByOneBusAway() {
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 27.9506, lon: -82.4572))?.providerID == "oba-tampa")
        #expect(TransitProviders.provider(id: "oba-tampa").displayName.contains("Tampa"))
        #expect(OneBusAwayProvider(.tampa).attribution?.contains("HART") == true)
    }

    /// Sound Transit's terms have to reach riders: the credit line links them.
    @Test func theCreditLineLinksTheTerms() throws {
        let attribution = try #require(OneBusAwayProvider(.pugetSound).attribution)
        #expect(attribution.contains("AS IS"))
        #expect(attribution.contains("https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/transit-data-terms-use"))
    }
}
