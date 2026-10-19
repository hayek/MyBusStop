import Testing
import MapKit
import SwiftUI
@testable import BusBus

struct StopMapGeometryTests {
    private let haifaCenter = GeoPoint(lat: 32.8191, lon: 34.9983)
    private let bahaiGardens = GeoPoint(lat: 32.8144, lon: 34.9870)

    @Test func distanceMatchesCoreLocation() {
        let expected = CLLocation(latitude: haifaCenter.lat, longitude: haifaCenter.lon)
            .distance(from: CLLocation(latitude: bahaiGardens.lat, longitude: bahaiGardens.lon))
        #expect(abs(haifaCenter.distance(to: bahaiGardens) - expected) < expected * 0.005)
        #expect(haifaCenter.distance(to: haifaCenter) == 0)
    }

    @Test func frameHoldsEveryPointWithRoomToSpare() {
        let rect = MapFraming.rect(around: [haifaCenter, bahaiGardens], minimumMeters: 0)
        for point in [haifaCenter, bahaiGardens] {
            let mapPoint = MKMapPoint(point.coordinate)
            #expect(rect.insetBy(dx: rect.size.width * 0.1, dy: rect.size.height * 0.1).contains(mapPoint))
        }
    }

    @Test func singleStopIsFramedWithItsStreets() {
        let rect = MapFraming.rect(around: [haifaCenter], minimumMeters: 700)
        #expect(abs(MapFraming.spanMeters(of: rect) - 700) < 5)
        #expect(MapFraming.rect(around: [], minimumMeters: 700).isNull)
    }

    @Test func areaRadiusFollowsTheSpanWithinLimits() {
        #expect(MapFraming.searchRadius(forSpan: 100) == 250)
        #expect(MapFraming.searchRadius(forSpan: 1_200) == 600)
        #expect(MapFraming.searchRadius(forSpan: 20_000) == 1_500)
    }

    @Test func movingIsJudgedAgainstWhatIsOnScreen() {
        let nudged = GeoPoint(lat: haifaCenter.lat + 0.002, lon: haifaCenter.lon) // ≈ 220 m north
        #expect(MapFraming.hasMoved(from: haifaCenter, to: nudged, spanMeters: 800))
        #expect(!MapFraming.hasMoved(from: haifaCenter, to: nudged, spanMeters: 5_000))
        #expect(!MapFraming.hasMoved(from: haifaCenter, to: haifaCenter, spanMeters: 800))
    }

    @Test func framingAllowsForTheDrawerOverTheMap() {
        let size = CGSize(width: 400, height: 800)
        let cover = MapCover(bottom: 400)
        let target = MapFraming.rect(around: [haifaCenter, bahaiGardens], minimumMeters: 0)
        let whole = MapFraming.rect(showing: target, in: size, cover: cover)
        // The whole map keeps the view's shape, and the part above the drawer holds the target,
        // centred in it.
        #expect(abs(whole.size.width / whole.size.height - 0.5) < 0.001)
        let visible = MapFraming.visibleRect(of: whole, in: size, cover: cover)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(target.origin))
        #expect(abs(visible.midX - target.midX) < 1 && abs(visible.midY - target.midY) < 1)
    }

    @Test func centringPutsTheStopMidUncoveredAndZoomsInOnlyFromAfar() {
        let size = CGSize(width: 800, height: 600)
        let cover = MapCover(leading: 300, bottom: 0, layoutDirection: .leftToRight)
        let city = MapFraming.rect(showing: MapFraming.rect(around: [haifaCenter], minimumMeters: 10_000),
                                   in: size, cover: cover)
        let rect = MapFraming.rect(centering: bahaiGardens, from: city, in: size, cover: cover,
                                   widestSpanMeters: 1_500)
        let visible = MapFraming.visibleRect(of: rect, in: size, cover: cover)
        let stop = MKMapPoint(bahaiGardens.coordinate)
        #expect(abs(visible.midX - stop.x) < 1 && abs(visible.midY - stop.y) < 1)
        #expect(abs(MapFraming.spanMeters(of: visible) - 1_500) < 15)
        // Already at street level: the zoom stays as it is.
        let street = MapFraming.rect(centering: bahaiGardens, from: rect, in: size, cover: cover,
                                     widestSpanMeters: 5_000)
        #expect(abs(street.size.width - rect.size.width) < 1)
        // Right to left, the panel is on the right, and the stop moves left of the middle.
        let mirrored = MapCover(leading: 300, bottom: 0, layoutDirection: .rightToLeft)
        let rtl = MapFraming.rect(centering: bahaiGardens, from: city, in: size, cover: mirrored,
                                  widestSpanMeters: 1_500)
        #expect(rtl.midX > stop.x && rect.midX < stop.x)
    }
}
