#if os(tvOS)
import SwiftUI

/// Adding a stop on the TV itself, for a rider with no other device to save it on: the stops near
/// the TV (its location is rough, but a living room is a fine place to start from), or by name.
struct TVStopFinderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: SetupViewModel
    var onChoose: (TransitStop) -> Void

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        List {
            Section {
                TextField("Stop name or number", text: $model.query)
                    .submitLabel(.search)
                if let region = model.currentRegion {
                    Menu {
                        ForEach(SupportedRegions.all.filter { model.settings.regionIsUsable($0) }) { other in
                            Button(other.name) { Task { await model.switchRegion(to: other) } }
                        }
                    } label: {
                        LabeledContent("Region", value: region.name)
                    }
                }
            }

            if model.isShowingResults {
                Section {
                    if model.results.isEmpty {
                        Text(model.isSearching ? "Searching…" : "No stops found")
                            .foregroundStyle(theme.secondaryText)
                    }
                    ForEach(model.results, id: \.code) { stop in
                        Button { onChoose(stop) } label: { TVStopRow(stop: stop, detail: nil, lines: []) }
                    }
                } header: {
                    Text("Results")
                }
            } else {
                Section {
                    nearbyState(theme: theme)
                    ForEach(model.nearby) { entry in
                        Button { onChoose(entry.stop) } label: {
                            TVStopRow(stop: entry.stop, detail: DistanceFormatter.text(entry.distanceMeters),
                                      lines: entry.lines)
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    if let attribution = model.attribution { Text(attribution) }
                }
            }
        }
        .navigationTitle("Find a stop")
        .task { await model.loadNearby() }
        .analyticsScreen("tv_stop_finder")
    }

    @ViewBuilder private func nearbyState(theme: Theme) -> some View {
        switch model.nearbyState {
        case .needsPermission:
            Button {
                Task { await model.loadNearby(force: true, askingPermission: true) }
            } label: {
                Label("Use this Apple TV's location", systemImage: "location.fill")
            }
        case .locating:
            HStack(spacing: 20) {
                ProgressView()
                Text(verbatim: model.nearbyCaption)
            }
        case .ready:
            EmptyView()
        default:
            Text(verbatim: model.nearbyCaption.isEmpty
                 ? String(appLocalized: "NEARBY NOT AVAILABLE · SEARCH ABOVE") : model.nearbyCaption)
                .foregroundStyle(theme.secondaryText)
        }
    }
}

private struct TVStopRow: View {
    static func numbers(_ lines: [TransitLine]) -> [String] {
        var seen = Set<String>()
        return lines.map(\.shortName).filter { seen.insert($0).inserted }
    }

    @Environment(\.colorScheme) private var colorScheme
    var stop: TransitStop
    var detail: String?
    var lines: [TransitLine]

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stop.name)
                if let city = stop.city, !city.isEmpty {
                    Text(city).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !lines.isEmpty {
                // A line running both ways is two lines to the feed and one number to the rider.
                Text(verbatim: Self.numbers(lines).prefix(6).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
