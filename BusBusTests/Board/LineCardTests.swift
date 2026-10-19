import Testing
import CoreText
import MapKit
import SwiftUI
@testable import BusBus

struct LineCardTests {
    /// Line 112's way out of Haifa: down from the Carmel to the shore, a bend the stops alone miss.
    private let shape = RouteShape([GeoPoint(lat: 32.8191, lon: 34.9983), GeoPoint(lat: 32.8100, lon: 34.9400),
                                    GeoPoint(lat: 32.7940, lon: 34.9560)])
    private let stops = [GeoPoint(lat: 32.8191, lon: 34.9983), GeoPoint(lat: 32.7940, lon: 34.9560)]

    @Test func cameraHoldsTheWholeDrawnLine() {
        let rect = LineCard.frame(shape: shape, stops: stops)
        for point in shape.branches.flatMap({ $0 }) {
            #expect(rect.contains(MKMapPoint(point.coordinate)))
        }
        // The bend west of the stops' own box is inside too, which a frame round the stops would cut.
        let stopsOnly = LineCard.frame(shape: nil, stops: stops)
        #expect(rect.size.width > stopsOnly.size.width)
    }

    @Test func withoutAShapeTheCameraFramesTheStops() {
        let rect = LineCard.frame(shape: nil, stops: stops)
        for point in stops { #expect(rect.contains(MKMapPoint(point.coordinate))) }
        #expect(LineCard.frame(shape: nil, stops: []).isNull)
        // A single stop is still shown with its streets.
        #expect(MapFraming.spanMeters(of: LineCard.frame(shape: nil, stops: [stops[0]])) >= 599)
    }

    @Test func stopsAreDrawnWhereTheShapePutsThem() {
        let stop = TransitStop(code: "41122", name: "Hof HaCarmel", location: stops[0])
        let onRoad = GeoPoint(lat: 32.8192, lon: 34.9985)
        #expect(LineCard.position(of: stop, shape: RouteShape(shape.branches[0], stopPositions: ["41122": onRoad])) == onRoad)
        #expect(LineCard.position(of: stop, shape: shape) == stops[0])
        #expect(LineCard.position(of: stop, shape: nil) == stops[0])
    }

    @Test func theStopTheCardCameFromOutranksTheEnds() {
        #expect(LineCard.mark(index: 0, count: 5, code: "A", highlighted: "C") == .terminus)
        #expect(LineCard.mark(index: 4, count: 5, code: "E", highlighted: "C") == .terminus)
        #expect(LineCard.mark(index: 2, count: 5, code: "C", highlighted: "C") == .highlighted)
        #expect(LineCard.mark(index: 0, count: 5, code: "A", highlighted: "A") == .highlighted)
        #expect(LineCard.mark(index: 1, count: 5, code: "B", highlighted: nil) == .stop)
    }

    /// The feed's credit, which also covers its shapes: Hong Kong's names the CSDI Portal.
    @Test func theFeedsCreditIsShown() {
        let kmb = "Data: Kowloon Motor Bus / DATA.GOV.HK; route lines: Transport Department / CSDI Portal"
        #expect(LineCard.credits(attribution: kmb) == [kmb])
        #expect(LineCard.credits(attribution: nil).isEmpty)
    }

    @Test func theTitleIsTheNameTheRowShowed() {
        // TfL: the row says the stop the line ends at, not the bus's blind.
        let line = TransitLine(id: "5", shortName: "5", headsign: "Victoria", destination: "Victoria Station")
        #expect(line.destinationLabel == "Victoria Station")
        #expect(TransitLine(id: "5", shortName: "5", headsign: "Victoria").destinationLabel == "Victoria")
        #expect(TransitLine(id: "5", shortName: "5").destinationLabel == nil)
    }

    @Test func theSubtitleNeverSaysTheTitleAgain() {
        // Titled by its last stop: only where it sets out from.
        #expect(LineCard.subtitle(title: "Akko", origin: "Haifa", terminus: "Akko") == .from("Haifa"))
        #expect(LineCard.subtitle(title: "Akko", origin: "Haifa", terminus: nil) == .from("Haifa"))
        // Titled by a headsign that is not the last stop: the whole way.
        #expect(LineCard.subtitle(title: "Merkaz", origin: "Haifa", terminus: "Akko")
                == .journey(origin: "Haifa", terminus: "Akko"))
        // A loop named after the stop it leaves from, or no origin at all: nothing.
        #expect(LineCard.subtitle(title: "Haifa", origin: "Haifa", terminus: "Haifa") == nil)
        #expect(LineCard.subtitle(title: "Akko", origin: nil, terminus: "Akko") == nil)
        // A headsign on a loop: "Haifa → Haifa" would say nothing.
        #expect(LineCard.subtitle(title: "Circle", origin: "Haifa", terminus: "Haifa") == .from("Haifa"))
    }

    @Test func theArrowPointsTheWayTheWordsRun() {
        #expect(LineCard.journey(from: "Haifa", to: "Akko", layoutDirection: .leftToRight)
                == "\u{200E}\u{2068}Haifa\u{2069} → \u{2068}Akko\u{2069}")
        // The right-to-left mark makes the paragraph RTL, so the origin stands at the right and the
        // arrow points left, on to the destination.
        #expect(LineCard.journey(from: "חיפה", to: "עכו", layoutDirection: .rightToLeft)
                == "\u{200F}\u{2068}חיפה\u{2069} ← \u{2068}עכו\u{2069}")
        // A Latin name in a Hebrew card too: the isolates alone would leave the paragraph LTR.
        let mixed = LineCard.journey(from: "Haifa", to: "Akko", layoutDirection: .rightToLeft)
        #expect(mixed.unicodeScalars.first == "\u{200F}")
    }

    /// Where the text system lays each name out, left to right in points.
    private func offsets(_ text: String, of names: String...) -> [CGFloat] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text))
        return names.map { name in
            let index = (text as NSString).range(of: name).location
            return CTLineGetOffsetForStringIndex(line, index, nil)
        }
    }

    @Test func theJourneyReadsFromOriginToDestinationInEitherDirection() {
        // Hebrew reads from the right: the origin stands right of the destination.
        let hebrew = offsets(LineCard.journey(from: "חיפה", to: "עכו", layoutDirection: .rightToLeft), of: "חיפה", "עכו")
        #expect(hebrew[0] > hebrew[1])
        // Latin names in a Hebrew card as well, which the isolates alone would lay out left to right.
        let latin = offsets(LineCard.journey(from: "Haifa", to: "Akko", layoutDirection: .rightToLeft), of: "Haifa", "Akko")
        #expect(latin[0] > latin[1])
        // And Hebrew names in an English card read from the left.
        let english = offsets(LineCard.journey(from: "חיפה", to: "עכו", layoutDirection: .leftToRight), of: "חיפה", "עכו")
        #expect(english[0] < english[1])
    }

    private func pattern(_ codes: [String]) -> RoutePattern {
        RoutePattern(line: TransitLine(id: "112", shortName: "112"), stops: codes.enumerated().map {
            PatternStop(stop: TransitStop(code: $1, name: $1, location: stops[$0 % stops.count]), sequence: $0)
        })
    }

    @Test func aRouteJudgedForOtherStopsIsDropped() {
        let old = pattern(["41122", "41300"])
        let rerouted = pattern(["41122", "41250", "41300"])
        #expect(LineCard.route(.drawn(shape), from: old, to: rerouted) == .loading)
        #expect(LineCard.route(.rejected, from: old, to: rerouted) == .loading)
        #expect(LineCard.route(.drawn(shape), from: nil, to: rerouted) == .loading)
        // Same stops, other details (a renamed agency): the drawn route stays.
        var renamed = old
        renamed.line.agency = "Egged"
        #expect(LineCard.route(.drawn(shape), from: old, to: renamed) == .drawn(shape))
    }

    @Test func aStoredShapeSaysWhatTheCardShows() {
        let judged = pattern(["41122", "41300"])
        // The feed had no path for the line: stored empty, shown like a feed without shapes.
        let none = StoredShape(judging: RouteShape(branches: []), for: judged, tolerance: .platforms)
        #expect(LineCardRoute(none) == .unsupported)
        #expect(LineCardRoute(none).isUnavailable)
        // A path that misses the stops.
        let astray = RouteShape([GeoPoint(lat: 31.0, lon: 35.0), GeoPoint(lat: 31.1, lon: 35.1)])
        let rejected = StoredShape(judging: astray, for: judged, tolerance: .platforms)
        #expect(!rejected.verdict.passes)
        #expect(LineCardRoute(rejected) == .rejected)
        var passed = rejected
        passed.verdict = ShapeVerdict(passes: true, reason: nil, worstOffset: 12)
        #expect(LineCardRoute(passed) == .drawn(passed.shape))
    }

    @Test func onlyTheMissingRouteIsSaidToBeMissing() {
        #expect(!LineCardRoute.loading.isUnavailable)
        #expect(!LineCardRoute.drawn(shape).isUnavailable)
        for route in [LineCardRoute.unsupported, .rejected, .failed, .noStops] {
            #expect(route.isUnavailable)
            #expect(route.shape == nil)
        }
    }
}
