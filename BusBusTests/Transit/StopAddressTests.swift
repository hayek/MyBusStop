import Testing
import Foundation
@testable import BusBus

struct StopAddressTests {
    @Test func joinsWhatTheProviderGaveAndDropsBlanks() {
        #expect(TransitStop.address(["דרך אלנבי", "166"]) == "דרך אלנבי 166")
        #expect(TransitStop.address(["השיטה", ""]) == "השיטה")
        #expect(TransitStop.address(["", "  ", nil]) == nil)
        #expect(TransitStop.address(["Mount Auburn Street", "DeWolfe Street"], separator: " & ")
                == "Mount Auburn Street & DeWolfe Street")
    }

    /// History and caches were written before stops had an address; they still have to load.
    @Test func stopsSavedWithoutAnAddressStillDecode() throws {
        let saved = #"{"code":"41122","name":"אלנבי ג","city":"חיפה","location":{"lat":32.827,"lon":34.975}}"#
        let stop = try JSONDecoder().decode(TransitStop.self, from: Data(saved.utf8))
        #expect(stop.code == "41122")
        #expect(stop.address == nil)
    }

    @Test func addressSurvivesARoundTrip() throws {
        let stop = TransitStop(code: "1", name: "A", city: nil, location: GeoPoint(lat: 1, lon: 2), address: "Antakalnio g.")
        let back = try JSONDecoder().decode(TransitStop.self, from: JSONEncoder().encode(stop))
        #expect(back.address == "Antakalnio g.")
    }
}
