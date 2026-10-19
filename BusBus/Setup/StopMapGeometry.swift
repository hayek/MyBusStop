import Foundation
import MapKit
import SwiftUI

nonisolated extension GeoPoint {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// Great-circle distance in metres. Good to well under a metre at the distances a stop list
    /// deals in, which is all it is used for.
    func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = lat * .pi / 180, lat2 = other.lat * .pi / 180
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// How the stop map frames what it shows, and when the rider has moved it far enough to be
/// offered a search of where they are looking.
nonisolated enum MapFraming {
    /// A frame around every point, with room around the edges so a pin is never cut in half, and
    /// never tighter than `minimumMeters` so a single stop is shown with its streets.
    static func rect(around points: [GeoPoint], minimumMeters: Double, padding: Double = 0.2) -> MKMapRect {
        guard !points.isEmpty else { return .null }
        var rect = MKMapRect.null
        for point in points {
            rect = rect.union(MKMapRect(origin: MKMapPoint(point.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let latitude = points.map(\.lat).reduce(0, +) / Double(points.count)
        let minimumSide = minimumMeters * MKMapPointsPerMeterAtLatitude(latitude)
        let width = max(rect.size.width * (1 + 2 * padding), minimumSide)
        let height = max(rect.size.height * (1 + 2 * padding), minimumSide)
        return MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The shorter side of what the map is showing, in metres.
    static func spanMeters(of rect: MKMapRect) -> Double {
        let latitude = rect.origin.coordinate.latitude
        return min(rect.size.width, rect.size.height) / MKMapPointsPerMeterAtLatitude(latitude)
    }

    /// Past this the map shows a city, not a street, and a search of "this area" would mean a
    /// radius no provider answers usefully.
    static let searchableSpanMeters: Double = 6_000

    /// The radius an area search asks for: about what is on screen, within what providers allow.
    static func searchRadius(forSpan span: Double) -> Double { min(max(span / 2, 250), 1_500) }

    /// Whether the map has been moved far enough from where it was framed to be worth a new search.
    /// Relative to the span, so a nudge at street level counts and the same nudge zoomed out does not.
    static func hasMoved(from anchor: GeoPoint, to center: GeoPoint, spanMeters: Double) -> Bool {
        anchor.distance(to: center) > max(150, spanMeters * 0.2)
    }

    // MARK: A map partly covered

    /// The frame for the whole map that shows `target` in the part of it the drawer or panel laid
    /// over it leaves uncovered. Framed against the whole view, a stop under the drawer would be
    /// "on screen" and still out of sight.
    static func rect(showing target: MKMapRect, in size: CGSize, cover: MapCover) -> MKMapRect {
        let visible = cover.visibleSize(in: size)
        guard !target.isNull, visible.width > 0, visible.height > 0 else { return target }
        // Map points per screen point: the tighter of the two sides decides, as an aspect fit.
        let perPoint = max(target.size.width / visible.width, target.size.height / visible.height)
        let width = size.width * perPoint, height = size.height * perPoint
        let midX = target.midX - (cover.left - cover.right) * perPoint / 2
        let midY = target.midY + cover.bottom * perPoint / 2
        return MKMapRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }

    /// The part of `whole` (what the map shows edge to edge) that is not under the drawer or panel.
    static func visibleRect(of whole: MKMapRect, in size: CGSize, cover: MapCover) -> MKMapRect {
        guard size.width > 0, !whole.isNull else { return whole }
        let perPoint = whole.size.width / size.width
        let visible = cover.visibleSize(in: size)
        return MKMapRect(x: whole.minX + cover.left * perPoint, y: whole.minY,
                         width: visible.width * perPoint, height: visible.height * perPoint)
    }

    /// The frame that puts `point` in the middle of what the rider can see, at the zoom the map is
    /// at — closer only when it shows more than `widestSpanMeters`, so a stop picked from a whole
    /// city is shown with its streets, and one picked at street level does not jump.
    static func rect(centering point: GeoPoint, from whole: MKMapRect?, in size: CGSize, cover: MapCover,
                     widestSpanMeters: Double) -> MKMapRect {
        let visible = cover.visibleSize(in: size)
        let center = MKMapPoint(point.coordinate)
        let perMeter = MKMapPointsPerMeterAtLatitude(point.lat)
        var target: MKMapSize
        if let whole, !whole.isNull, visible.width > 0, visible.height > 0 {
            let shown = visibleRect(of: whole, in: size, cover: cover)
            let zoom = min(1, widestSpanMeters / max(spanMeters(of: shown), 1))
            target = MKMapSize(width: shown.size.width * zoom, height: shown.size.height * zoom)
        } else {
            let side = widestSpanMeters * perMeter
            target = MKMapSize(width: side, height: side)
        }
        let rect = MKMapRect(x: center.x - target.width / 2, y: center.y - target.height / 2,
                             width: target.width, height: target.height)
        return self.rect(showing: rect, in: size, cover: cover)
    }
}

/// How much of the map the search screen's drawer (from the bottom) or side panel (from the
/// leading edge) lies over, in points. Left and right as on screen, not leading and trailing: the
/// map's west is on the left whichever way the words run.
nonisolated struct MapCover: Hashable, Sendable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0

    init(left: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0) {
        self.left = left
        self.right = right
        self.bottom = bottom
    }

    /// A panel on the leading edge sits on the right when the layout runs right to left.
    init(leading: CGFloat, bottom: CGFloat, layoutDirection: LayoutDirection) {
        self.init(left: layoutDirection == .rightToLeft ? 0 : leading,
                  right: layoutDirection == .rightToLeft ? leading : 0, bottom: bottom)
    }

    func visibleSize(in size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width - left - right), height: max(0, size.height - bottom))
    }
}
