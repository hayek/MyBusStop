import SwiftUI
import MapKit

#if !os(tvOS)
/// The full route on a real map, the other face of the full route's strip: each watched line that
/// has a road shape drawn on its streets, its stops, the rider's stop, and the buses placed on the
/// line between the two stops they are between. Shapes come from the cache, so a line's is fetched
/// once (the line card shares it) and the map asks nothing on later openings.
struct FullRouteMapView: View {
    @Environment(\.theme) private var theme
    var model: BoardViewModel
    /// A tap on a stop: its card, as on the strip.
    var onStop: (String) -> Void
    var cache: TransitCache = .shared

    @State private var drawn: [String: DrawnLine] = [:]
    @State private var position: MapCameraPosition = .automatic

    /// One line's road and where its stops meet it, so buses can be put on the road.
    struct DrawnLine: Equatable {
        var pattern: RoutePattern
        var shape: RouteShape
        /// Metres along the first branch at which each stop meets it, when they meet it in order.
        var stopsAlong: [Double]?
    }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(model.lines) { line in
                if let line = drawn[line.id] {
                    ForEach(Array(line.shape.branches.enumerated()), id: \.offset) { _, branch in
                        MapPolyline(coordinates: branch.map(\.coordinate))
                            .stroke(theme.background, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            ForEach(model.lines) { line in
                if let drawnLine = drawn[line.id] {
                    ForEach(Array(drawnLine.shape.branches.enumerated()), id: \.offset) { _, branch in
                        MapPolyline(coordinates: branch.map(\.coordinate))
                            .stroke(theme.rail(model.colorIndex(line.id)),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            ForEach(stops, id: \.code) { stop in
                Annotation(stop.name, coordinate: stop.location.coordinate, anchor: .center) {
                    Button { onStop(stop.code) } label: {
                        stopDot(isRiders: stop.code == model.stop?.code, colorIndex: stop.colorIndex)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: stop.name))
                }
                .annotationTitles(.hidden)
            }
            ForEach(buses, id: \.id) { bus in
                Annotation("", coordinate: bus.location.coordinate, anchor: .center) {
                    Circle()
                        .fill(theme.rail(bus.colorIndex))
                        .overlay(Circle().strokeBorder(theme.primaryText, lineWidth: bus.isSelected ? 3 : 2))
                        .frame(width: bus.isSelected ? 18 : 14, height: bus.isSelected ? 18 : 14)
                        .accessibilityLabel("Bus \(bus.lineNumber)")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Route map")
        .task(id: model.lines.map(\.id)) { await load() }
    }

    // MARK: What is drawn

    private struct MapStop {
        var code: String
        var name: String
        var location: GeoPoint
        var colorIndex: Int
    }

    /// Every drawn line's stops once, the rider's stop included; a stop two lines share is drawn once.
    private var stops: [MapStop] {
        var seen = Set<String>()
        var out: [MapStop] = []
        for line in model.lines {
            guard let drawnLine = drawn[line.id] else { continue }
            for patternStop in drawnLine.pattern.stops where seen.insert(patternStop.stop.code).inserted {
                let stop = patternStop.stop
                out.append(MapStop(code: stop.code, name: stop.name,
                                   location: drawnLine.shape.stopPositions?[stop.code] ?? stop.location,
                                   colorIndex: model.colorIndex(line.id)))
            }
        }
        return out
    }

    private struct MapBus {
        var id: String
        var lineNumber: String
        var location: GeoPoint
        var colorIndex: Int
        var isSelected: Bool
    }

    /// The board's buses, each between the stop it last passed and the next, on the road where the
    /// line has a road; between the two stops' points where it has not been matched.
    private var buses: [MapBus] {
        let ringed = model.ringedBusID
        return model.snapshot.buses.compactMap { bus in
            guard let line = model.line(bus.lineID), let drawnLine = drawn[bus.lineID] else { return nil }
            // The board counts stops on its own pattern; find the bus's last stop on the drawn one by code.
            guard let code = bus.lastStopCode ?? model.snapshot.patterns[bus.lineID]?.stops[safe: bus.lastStopIndex]?.stop.code,
                  let index = drawnLine.pattern.stops.firstIndex(where: { $0.stop.code == code }) else { return nil }
            let progress = min(1, max(0, bus.progressToNext))
            let location: GeoPoint
            if let along = drawnLine.stopsAlong, index + 1 < along.count, let branch = drawnLine.shape.branches.first {
                let distance = along[index] + progress * (along[index + 1] - along[index])
                location = ShapeCheck.Projection(branch).point(at: distance)
            } else {
                let stops = drawnLine.pattern.stops
                let from = stops[index].stop.location
                let to = stops[min(index + 1, stops.count - 1)].stop.location
                location = GeoPoint(lat: from.lat + progress * (to.lat - from.lat), lon: from.lon + progress * (to.lon - from.lon))
            }
            return MapBus(id: bus.id, lineNumber: line.shortName, location: location,
                          colorIndex: model.colorIndex(bus.lineID), isSelected: bus.id == ringed)
        }
    }

    private func stopDot(isRiders: Bool, colorIndex: Int) -> some View {
        let side: CGFloat = isRiders ? 18 : 8
        return Circle()
            .fill(isRiders ? theme.rail(colorIndex) : theme.background)
            .overlay(Circle().strokeBorder(isRiders ? theme.primaryText : theme.rail(colorIndex), lineWidth: isRiders ? 3.5 : 2))
            .frame(width: side, height: side)
    }

    // MARK: Loading

    /// Each line's road from the cache: stored ones at once, the rest asked for once. A line whose
    /// feed has no shapes is left off the map (the toggle is only offered when some line has one).
    private func load() async {
        let provider = model.settings.provider(id: model.configuration?.providerID ?? model.settings.providerID)
        for line in model.lines where provider.hasRouteShape(for: line) {
            let stored = await cache.cachedPattern(for: line.id, providerID: provider.datasetID)
            guard let pattern = stored ?? model.snapshot.fullPatterns[line.id] ?? model.snapshot.patterns[line.id] else { continue }
            var shape = await cache.cachedShape(for: pattern, provider: provider)?.drawable
            if shape == nil { shape = try? await cache.shape(for: pattern, provider: provider).drawable }
            guard let shape else { continue }
            let along = shape.branches.first.flatMap { branch in
                ShapeCheck.orderedMatches(branch, stops: pattern.stops.map { shape.stopPositions?[$0.stop.code] ?? $0.stop.location })?
                    .map(\.along)
            }
            drawn[line.id] = DrawnLine(pattern: pattern, shape: shape, stopsAlong: along)
            reframe()
        }
    }

    private func reframe() {
        let points = drawn.values.flatMap { $0.shape.branches.flatMap { $0 } }
        let rect = MapFraming.rect(around: points, minimumMeters: 600, padding: 0.12)
        guard !rect.isNull else { return }
        position = .rect(rect)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
