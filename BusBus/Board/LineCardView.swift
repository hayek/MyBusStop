import SwiftUI
import MapKit

/// Which line a card is about, the feed that knows its route, and the stop it was opened from,
/// which the card picks out on the map and in the list.
nonisolated struct LineCardRequest: Identifiable, Hashable, Sendable {
    var line: TransitLine
    var providerID: String
    var stopCode: String?

    var id: String { "\(providerID)|\(line.id)|\(stopCode ?? "")" }
}

/// What the line card's map has to go on. The stops come first, from the stored pattern; the line
/// along the roads joins them when its shape arrives, or never, and the card says so quietly.
nonisolated enum LineCardRoute: Hashable, Sendable {
    /// The shape is on its way.
    case loading
    case drawn(RouteShape)
    /// The feed has no shapes, or no path for this line.
    case unsupported
    /// The feed sent one that does not run past the stops (`ShapeCheck`).
    case rejected
    /// No answer: offline, or the feed failed.
    case failed
    /// Not even the stops could be had, so there is nothing to draw.
    case noStops

    var shape: RouteShape? {
        if case .drawn(let shape) = self { shape } else { nil }
    }

    /// What the card makes of a stored shape. A line the feed had no path for is stored as an
    /// empty shape (`TransitCache.shape`), and is said to have none like a feed without shapes;
    /// only a path that misses the stops counts as rejected.
    init(_ stored: StoredShape) {
        if let shape = stored.drawable {
            self = .drawn(shape)
        } else {
            self = stored.shape.isEmpty ? .unsupported : .rejected
        }
    }

    /// Whether the card says the route is missing. Never while it may still come.
    var isUnavailable: Bool {
        switch self {
        case .loading, .drawn: false
        case .unsupported, .rejected, .failed, .noStops: true
        }
    }
}

/// The pieces of the line card that are not drawing: framing, credits and how a stop is marked.
nonisolated enum LineCard {
    /// The credit lines under the map: the feed's own, which also covers its shapes (Hong Kong's
    /// names the CSDI Portal its route lines come from). Set as the licensors wrote them, so never
    /// translated.
    static func credits(attribution: String?) -> [String] {
        [attribution].compactMap { $0 }
    }

    /// The map's frame: the whole of the drawn line when there is one, the stops when there is
    /// not, with room round the edges so the termini are never cut in half.
    static func frame(shape: RouteShape?, stops: [GeoPoint]) -> MKMapRect {
        let points = shape.map { $0.branches.flatMap { $0 } } ?? []
        return MapFraming.rect(around: points.isEmpty ? stops : points, minimumMeters: 600, padding: 0.12)
    }

    /// Where a stop is drawn: where the shape's source says it stands when the line is drawn, so
    /// a stop-area centre does not float off the road beside it.
    static func position(of stop: TransitStop, shape: RouteShape?) -> GeoPoint {
        shape?.stopPositions?[stop.code] ?? stop.location
    }

    enum Mark: Hashable, Sendable {
        case stop, terminus, highlighted
    }

    /// The stop the card was opened from stands out most, then the two ends of the line.
    static func mark(index: Int, count: Int, code: String, highlighted: String?) -> Mark {
        if code == highlighted { return .highlighted }
        return index == 0 || index == count - 1 ? .terminus : .stop
    }

    /// The line under the title, which never says the title again: where the line sets out from,
    /// or, when the title is a headsign rather than the last stop, the whole way from end to end.
    enum Subtitle: Hashable, Sendable {
        case from(String)
        case journey(origin: String, terminus: String)
    }

    /// Nothing for a loop that ends where it is named, or a feed that names no origin.
    static func subtitle(title: String, origin: String?, terminus: String?) -> Subtitle? {
        guard let origin, origin != title else { return nil }
        if let terminus, terminus != title, terminus != origin {
            return .journey(origin: origin, terminus: terminus)
        }
        return .from(origin)
    }

    /// "Origin → Destination", the arrow pointing the way the words run. Each name is isolated
    /// (U+2068…U+2069), so a Hebrew or Arabic name in an English line keeps its place either side
    /// of the arrow rather than being reordered with it. With only isolates and an arrow there is
    /// no strong letter to set the paragraph's direction, so a mark (RLM, LRM) sets it to the
    /// layout's: otherwise a Hebrew card would lay it out left to right and read backwards.
    static func journey(from origin: String, to destination: String, layoutDirection: LayoutDirection) -> String {
        let (mark, arrow) = layoutDirection == .rightToLeft ? ("\u{200F}", "←") : ("\u{200E}", "→")
        return "\(mark)\u{2068}\(origin)\u{2069} \(arrow) \u{2068}\(destination)\u{2069}"
    }

    /// A shape judged for other stops is dropped when the pattern is refreshed, so the old path is
    /// never drawn over the new stops while the new one is fetched (or if it cannot be).
    static func route(_ route: LineCardRoute, from old: RoutePattern?, to new: RoutePattern) -> LineCardRoute {
        old?.stopsFingerprint == new.stopsFingerprint ? route : .loading
    }

    /// Nil while the route is still coming: what the card settled on is what is worth counting.
    /// A card closed before then is counted as dismissed, so a slow or failing feed is not missed.
    static func analyticsName(for route: LineCardRoute, isClosing: Bool = false) -> String? {
        switch route {
        case .loading: isClosing ? "dismissed" : nil
        case .drawn: "drawn"
        case .unsupported: "unsupported"
        case .rejected: "rejected"
        case .failed: "failed"
        case .noStops: "no_stops"
        }
    }
}

#if !os(tvOS)
/// A line on its own: where it goes, its path along the roads and every stop it calls at. Opened
/// by the ⓘ beside a line wherever lines are listed — the stop card, search's confirm step, the
/// tapped bus.
struct LineCardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    var request: LineCardRequest
    var settings: SettingsStore
    var cache: TransitCache = .shared

    @State private var pattern: RoutePattern?
    @State private var route: LineCardRoute = .loading
    @State private var position: MapCameraPosition = .automatic
    @State private var inspectedStop: StopCardRequest?
    /// Whether this opening has been logged: once, when the route settles or the card closes.
    @State private var isCounted = false
    /// The stop last tapped on the map, scrolled to and marked in the list below.
    @State private var focusedStop: Int?
    /// Counts taps on the map's stops, so tapping the same one again scrolls back to it.
    @State private var focusTaps = 0

    private var line: TransitLine { request.line }
    private var colorIndex: Int { settings.colorIndex(for: line.id) }
    private var stops: [TransitStop] { pattern?.stops.map(\.stop) ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    map
                    stopsSection
                    credits
                }
                .padding(20)
            }
            .onChange(of: focusTaps) {
                guard let index = focusedStop else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(StopRow(index: index), anchor: .center) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.background)
        .task(id: request.id) { await load() }
        .onDisappear { count(route, isClosing: true) }
        .sheet(item: $inspectedStop) { request in
            StopCardView(request: request, settings: settings)
                .busTheme()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .analyticsScreen("line_card")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            LineBadgeView(number: line.shortName, colorIndex: colorIndex,
                          side: 44, cornerRadius: 11, numeralSize: 20, ring: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .busText(TypeStyles.titlePhone)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = LineCard.subtitle(title: title, origin: origin, terminus: terminus) {
                    subtitleText(subtitle)
                        .busText(TypeStyles.stopAddressPhone)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let agency = line.agency ?? pattern?.line.agency {
                    Text(agency)
                        .busText(TypeStyles.headerCaption)
                        .foregroundStyle(theme.headerCaption)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                CloseGlyph(scale: 1)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.closeButton))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    /// Where the line goes, named as in the row the card was opened from, or its number when the
    /// feed says nothing.
    private var title: String {
        line.destinationLabel ?? stops.last?.name ?? String(appLocalized: "Line \(line.shortName)")
    }

    private var origin: String? { line.origin ?? stops.first?.name }
    private var terminus: String? { line.destination ?? stops.last?.name }

    private func subtitleText(_ subtitle: LineCard.Subtitle) -> Text {
        switch subtitle {
        case .from(let origin):
            Text("From \(origin)")
        case .journey(let origin, let terminus):
            Text(verbatim: LineCard.journey(from: origin, to: terminus, layoutDirection: layoutDirection))
        }
    }

    // MARK: Map

    /// The line in its colour over a quiet map, cased so it reads over any road, and its stops on
    /// it: the ends larger, the stop the card came from larger still.
    private var map: some View {
        let shape = route.shape
        return Map(position: $position, interactionModes: [.pan, .zoom]) {
            if let shape {
                ForEach(Array(shape.branches.enumerated()), id: \.offset) { _, branch in
                    MapPolyline(coordinates: branch.map(\.coordinate))
                        .stroke(theme.background, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: branch.map(\.coordinate))
                        .stroke(theme.rail(colorIndex), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                Annotation(stop.name, coordinate: LineCard.position(of: stop, shape: shape).coordinate,
                           anchor: .center) {
                    // A tap finds the stop in the list below; the dot's target is bigger than the dot.
                    Button { focusedStop = index; focusTaps += 1 } label: {
                        StopDot(mark: LineCard.mark(index: index, count: stops.count, code: stop.code,
                                                    highlighted: request.stopCode),
                                colorIndex: colorIndex, isOnMap: true, isFocused: focusedStop == index)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: stop.name))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay {
            if pattern == nil && !route.isUnavailable {
                ProgressView()
                    .accessibilityLabel("Loading stops")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if route.isUnavailable {
                Text("Route not available for this line")
                    .busText(TypeStyles.hint)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(theme.background.opacity(0.9)))
                    .padding(10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map")
    }

    // MARK: Stops

    @ViewBuilder private var stopsSection: some View {
        if !stops.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("STOPS ON THIS LINE")
                    .busText(TypeStyles.kicker)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                        stopRow(stop, index: index)
                            .id(StopRow(index: index))
                    }
                }
            }
        }
    }

    /// One stop on a strip of the line's colour, as on a route diagram. Tapping it opens the
    /// stop's own card.
    private func stopRow(_ stop: TransitStop, index: Int) -> some View {
        let mark = LineCard.mark(index: index, count: stops.count, code: stop.code, highlighted: request.stopCode)
        return Button {
            inspectedStop = StopCardRequest(stop: stop, providerID: request.providerID, watched: [line])
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    VStack(spacing: 0) {
                        theme.rail(colorIndex).opacity(index == 0 ? 0 : 1)
                        theme.rail(colorIndex).opacity(index == stops.count - 1 ? 0 : 1)
                    }
                    .frame(width: 5)
                    StopDot(mark: mark, colorIndex: colorIndex)
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name)
                        .busText(TypeStyles.confirmLinePhone)
                        .foregroundStyle(mark == .stop ? theme.secondaryText : theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let city = stop.city {
                        Text(city)
                            .busText(TypeStyles.stopAddressPhone)
                            .foregroundStyle(theme.dashCaption)
                    }
                }
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background {
                // The stop just tapped on the map, found in the list.
                if focusedStop == index {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.rail(colorIndex).opacity(0.16))
                        .padding(.horizontal, -8)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focusedStop)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(mark == .highlighted ? .isSelected : [])
        .accessibilityHint("Shows the stop’s lines, address and map")
    }

    @ViewBuilder private var credits: some View {
        let lines = LineCard.credits(attribution: settings.provider(id: request.providerID).attribution)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text(AttributedString(creditLine: $0)) }
            }
            .busText(TypeStyles.creditLinePhone)
            .foregroundStyle(theme.dashCaption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Loading

    /// The stored stops and shape first, so the card is drawn at once, then the network's: the
    /// pattern refreshed, and the shape fetched only if none is stored for these stops.
    private func load() async {
        pattern = nil
        route = .loading
        isCounted = false
        let provider = settings.provider(id: request.providerID)
        let hasShapes = provider.capabilities.contains(.routeShape)

        if let stored = await cache.cachedPattern(for: line.id, providerID: provider.datasetID) {
            pattern = stored
            if hasShapes, let shape = await cache.cachedShape(for: stored, provider: provider) {
                route = LineCardRoute(shape)
            }
            reframe()
        }
        do {
            let fresh = try await cache.pattern(for: line, provider: provider)
            if fresh != pattern {
                if fresh.stopsFingerprint != pattern?.stopsFingerprint { focusedStop = nil }
                route = LineCard.route(route, from: pattern, to: fresh)
                pattern = fresh
                reframe()
            }
        } catch {
            guard pattern != nil else { return settle(.noStops) }
        }
        guard let pattern, !Task.isCancelled else { return }
        guard hasShapes else { return settle(.unsupported) }
        do {
            settle(LineCardRoute(try await cache.shape(for: pattern, provider: provider)))
        } catch TransitError.unsupported {
            settle(.unsupported)
        } catch {
            // What the store had for these stops, drawn or not, stays through a failed refresh.
            settle(route == .loading ? .failed : route)
        }
    }

    private func settle(_ settled: LineCardRoute) {
        guard !Task.isCancelled else { return }
        let hadShape = route.shape != nil
        route = settled
        if settled.shape != nil && !hadShape {
            withAnimation(.easeInOut(duration: 0.35)) { reframe() }
        }
        count(settled)
    }

    /// One `line_card_opened` per opening, with what its route came to, or `dismissed` when the
    /// card was closed while it was still coming.
    private func count(_ route: LineCardRoute, isClosing: Bool = false) {
        guard !isCounted, let name = LineCard.analyticsName(for: route, isClosing: isClosing) else { return }
        isCounted = true
        Telemetry.log("line_card_opened", ["route": name, "provider_id": request.providerID])
    }

    private func reframe() {
        let rect = LineCard.frame(shape: route.shape, stops: stops.map { LineCard.position(of: $0, shape: route.shape) })
        guard !rect.isNull else { return }
        position = .rect(rect)
    }
}

/// Names a stop's row in the list, for scrolling to it from the map.
private struct StopRow: Hashable { var index: Int }

/// A stop on the line: a ring in the line's colour, the ends a size up, and the stop the card was
/// opened from filled in. Smaller on the map, where a city's worth of stops would hide the line.
/// The stop last tapped on the map wears a halo there.
private struct StopDot: View {
    @Environment(\.theme) private var theme
    var mark: LineCard.Mark
    var colorIndex: Int
    var isOnMap = false
    var isFocused = false

    var body: some View {
        let side: CGFloat = switch mark {
        case .stop: isOnMap ? 8 : 11
        case .terminus: isOnMap ? 13 : 15
        case .highlighted: isOnMap ? 18 : 20
        }
        Circle()
            .fill(mark == .highlighted ? theme.rail(colorIndex) : theme.background)
            .overlay(Circle().strokeBorder(mark == .highlighted ? theme.primaryText : theme.rail(colorIndex),
                                           lineWidth: mark == .stop ? (isOnMap ? 2 : 2.5) : 3.5))
            .frame(width: side, height: side)
            .background {
                if isFocused {
                    Circle().strokeBorder(theme.primaryText, lineWidth: 2.5).frame(width: side + 10, height: side + 10)
                }
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Line card") {
    let suite = "LineCardView.preview"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let settings = SettingsStore(defaults: defaults)
    settings.providerOverride = MockTransitProvider()
    let line = TransitLine(id: "41", shortName: "41", headsign: "HARBOR GATE", agency: "Mock Transit")
    return Color.clear.sheet(isPresented: .constant(true)) {
        LineCardView(request: LineCardRequest(line: line, providerID: "mock", stopCode: "HARBOR-GATE"),
                     settings: settings)
            .busTheme()
    }
}
#endif
#endif
