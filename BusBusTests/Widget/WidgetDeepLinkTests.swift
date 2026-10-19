import Testing
import Foundation
@testable import BusBus

struct WidgetDeepLinkTests {
    private func setup(code: String, lines: [String]) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: code, name: "Stop", location: GeoPoint(lat: 0, lon: 0)),
                   lines: lines.map {
                       TransitLine(id: $0, shortName: $0, headsign: nil, agency: nil, origin: nil, destination: nil,
                                   isAccessible: nil, brandColorIndex: nil)
                   })
    }

    /// Ids join their parts with "|", and line ids may carry "/", "&" or spaces of their own.
    @Test func roundTripsASetupID() throws {
        let saved = setup(code: "41122", lines: ["18", "N 5/A&B"])
        let url = WidgetDeepLink.url(for: saved)
        #expect(url.scheme == "busbus")
        #expect(WidgetDeepLink.setupID(from: url) == saved.id)
    }

    @Test func otherLinksNameNoSetup() throws {
        #expect(WidgetDeepLink.url(for: nil).absoluteString == "busbus://open")
        #expect(WidgetDeepLink.setupID(from: WidgetDeepLink.url(for: nil)) == nil)
        #expect(WidgetDeepLink.setupID(from: try #require(URL(string: "https://example.com/setup?id=1"))) == nil)
        #expect(WidgetDeepLink.setupID(from: try #require(URL(string: "busbus://setup?id="))) == nil)
    }
}
