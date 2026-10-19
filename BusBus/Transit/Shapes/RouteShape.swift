import Foundation
import CryptoKit

/// A line's real path along the roads, for the line card's map — never straight lines between
/// stops. docs/research/route-shapes.md has where each provider's comes from.
nonisolated struct RouteShape: Hashable, Sendable {
    /// One polyline per branch. Usually one; several when a pattern's stop list merges variants
    /// (a direction with two starts or two ends), so every stop lies on some branch.
    var branches: [[GeoPoint]]
    /// Where each stop really stands, by stop code, when the shape's source knows better than the
    /// provider's own stop list (stop-area centres can be 100–250 m off the road).
    var stopPositions: [String: GeoPoint]? = nil
    /// The source's own version marker (`shape_id`, a timetable date…), when it has one.
    var version: String? = nil

    init(branches: [[GeoPoint]], stopPositions: [String: GeoPoint]? = nil, version: String? = nil) {
        self.branches = branches.filter { $0.count >= 2 }
        self.stopPositions = stopPositions
        self.version = version
    }

    init(_ points: [GeoPoint], stopPositions: [String: GeoPoint]? = nil, version: String? = nil) {
        self.init(branches: [points], stopPositions: stopPositions, version: version)
    }

    var isEmpty: Bool { branches.isEmpty }
    var pointCount: Int { branches.reduce(0) { $0 + $1.count } }
}

/// Stored as precision-6 encoded polylines: lossless at road scale and about a quarter the size of
/// JSON coordinates.
nonisolated extension RouteShape: Codable {
    private enum CodingKeys: String, CodingKey { case branches, stopPositions, version }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode([String].self, forKey: .branches)
        self.init(branches: try encoded.map { try Polyline.decode($0, precision: 6) },
                  stopPositions: try container.decodeIfPresent([String: GeoPoint].self, forKey: .stopPositions),
                  version: try container.decodeIfPresent(String.self, forKey: .version))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branches.map { Polyline.encode($0, precision: 6) }, forKey: .branches)
        try container.encodeIfPresent(stopPositions, forKey: .stopPositions)
        try container.encodeIfPresent(version, forKey: .version)
    }
}

nonisolated extension RoutePattern {
    /// The stop codes in order with immediate repeats dropped (some feeds list a stop twice in a
    /// row), as a short hash. A shape is kept until this changes.
    var stopsFingerprint: String {
        var codes: [String] = []
        for stop in stops where codes.last != stop.stop.code { codes.append(stop.stop.code) }
        let digest = Insecure.SHA1.hash(data: Data(codes.joined(separator: ",").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// How far from the drawn line a stop may stand before the shape is judged not to be this line's.
nonisolated struct ShapeTolerance: Hashable, Sendable {
    /// For stops along the way.
    var stops: Double
    /// For the first and last stop, which often stand in a terminal or bus station off the road.
    var ends: Double

    /// Stop coordinates are the pole on the kerb.
    static let platforms = ShapeTolerance(stops: 50, ends: 150)
    /// Stop coordinates are the centre of a stop area serving both directions (Luxembourg, a
    /// station's centre in HAFAS feeds).
    static let stopAreas = ShapeTolerance(stops: 200, ends: 200)
}
