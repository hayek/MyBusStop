import SwiftUI
import MapKit

/// Which stop a card is about, and the feed that knows its lines. A saved stop from another city
/// is asked of its own provider, not of whichever one setup is browsing.
nonisolated struct StopCardRequest: Identifiable, Hashable, Sendable {
    var stop: TransitStop
    var providerID: String
    /// The lines the rider watches here, which lead the card's list.
    var watched: [TransitLine] = []

    var id: String { "\(providerID)|\(stop.code)" }
}

#if !os(tvOS)
/// A stop on its own: its name, every line that calls there, where it stands and a map of it.
/// Opened by tapping a stop wherever one is drawn — the board's map, the full route, the stop lists.
struct StopCardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var request: StopCardRequest
    var settings: SettingsStore
    var cache: TransitCache = .shared

    private enum LinesState: Equatable {
        case loading
        case loaded([TransitLine])
        case failed
    }

    @State private var lines: LinesState = .loading
    @State private var lookedUpAddress: String?
    @State private var inspectedLine: LineCardRequest?

    private var stop: TransitStop { request.stop }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                map
                if let address { addressRow(address) }
                linesSection
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.background)
        .task(id: request.id) { await load() }
        .sheet(item: $inspectedLine) { request in
            LineCardView(request: request, settings: settings)
                .busTheme()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .analyticsScreen("stop_card")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stop.name)
                    .busText(TypeStyles.titlePhone)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .busText(TypeStyles.headerCaption)
                    .foregroundStyle(theme.headerCaption)
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

    private var caption: String {
        guard let city = stop.city else { return String(appLocalized: "STOP \(stop.code)") }
        return String(appLocalized: "STOP \(stop.code) · \(city)")
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: stop.location.lat, longitude: stop.location.lon)
    }

    /// Placed, not explored: it pans and zooms, and the pin is where the pole stands.
    private var map: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 500,
                                                        longitudinalMeters: 500))) {
            Marker(stop.name, systemImage: "bus.fill", coordinate: coordinate)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let mapsURL {
                Link(destination: mapsURL) {
                    Text("OPEN IN MAPS")
                        .busText(TypeStyles.hint)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(theme.background.opacity(0.9)))
                }
                .padding(10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of \(stop.name)")
    }

    private var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "ll", value: "\(stop.location.lat),\(stop.location.lon)"),
                                  URLQueryItem(name: "q", value: stop.name)]
        return components?.url
    }

    /// The same line the stop lists show: the provider's address, Apple's, or the town.
    private var address: String? { StopAddresses.text(for: stop, lookedUp: lookedUpAddress) }

    private func addressRow(_ text: String) -> some View {
        Label {
            Text(text)
                .busText(TypeStyles.subArrives)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Address, \(text)")
    }

    @ViewBuilder private var linesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LINES AT THIS STOP")
                .busText(TypeStyles.kicker)
                .foregroundStyle(theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            switch lines {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Loading lines")
            case .failed:
                Text("Couldn’t load the lines at this stop.")
                    .busText(TypeStyles.subArrives)
                    .foregroundStyle(theme.secondaryText)
            case .loaded(let found) where found.isEmpty:
                Text("No lines listed for this stop.")
                    .busText(TypeStyles.subArrives)
                    .foregroundStyle(theme.secondaryText)
            case .loaded(let found):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(found) { line in
                        let badge = LineBadgeView(number: line.shortName, colorIndex: colorIndex(line),
                                                  side: 44, cornerRadius: 11, numeralSize: 20, ring: nil)
                            .frame(width: 48, height: 48)
                        // The badge is the line's ⓘ here: a grid of badges has no row to set one beside.
                        // Only where its route can be drawn; otherwise it is just the badge.
                        if settings.provider(id: request.providerID).hasRouteShape(for: line) {
                            Button {
                                inspectedLine = LineCardRequest(line: line, providerID: request.providerID,
                                                                stopCode: stop.code)
                            } label: {
                                badge.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(lineLabel(line))
                            .accessibilityHint("Shows the line’s route and stops")
                        } else {
                            badge.accessibilityLabel(lineLabel(line))
                        }
                    }
                }
            }
        }
    }

    private func lineLabel(_ line: TransitLine) -> String {
        guard let destination = line.destinationLabel else { return String(appLocalized: "Line \(line.shortName)") }
        return String(appLocalized: "Line \(line.shortName) to \(destination)")
    }

    /// A watched line keeps the colour the board gives it; any other gets setup's provisional one.
    private func colorIndex(_ line: TransitLine) -> Int { settings.colorIndex(for: line.id) }

    private func load() async {
        // Nothing of the last stop's may show under this one's name while its own is fetched.
        lines = .loading
        lookedUpAddress = nil
        async let address: Void = lookUpAddress()
        let provider = settings.provider(id: request.providerID)
        do {
            let found = try await cache.lines(atStop: stop, providerID: provider.datasetID) {
                try await provider.lines(atStop: stop)
            }
            lines = .loaded(ordered(found))
        } catch {
            lines = .failed
        }
        await address
    }

    private func lookUpAddress() async {
        guard StopAddresses.needsLookup(stop) else { return }
        lookedUpAddress = await StopAddresses.shared.address(for: stop)
    }

    /// Watched lines first, in the order they were picked, then the rest by number. One line in
    /// two directions is listed once, as a badge says nothing about direction.
    private func ordered(_ found: [TransitLine]) -> [TransitLine] {
        let watchedIDs = request.watched.map(\.id)
        let watched = request.watched.filter { line in found.contains { $0.id == line.id } }
        var seen = Set(watched.map(\.shortName))
        let others = found
            .filter { !watchedIDs.contains($0.id) }
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            .filter { seen.insert($0.shortName).inserted }
        return watched + others
    }
}
#endif
