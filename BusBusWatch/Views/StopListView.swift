import SwiftUI

/// The root: the phone's history, pinned first, each stop with its lines and — when the stored
/// numbers are still good — its next bus, so the list is itself a glance. Reads stores only.
struct StopListView: View {
    @Environment(\.theme) private var theme
    var store: WatchStore

    var body: some View {
        ScrollView {
            if store.history.isEmpty {
                empty
            } else {
                // Once a minute is enough: the board is where the seconds are.
                TimelineView(.everyMinute) { context in
                    list(at: context.now)
                }
            }
        }
        .background(theme.background)
    }

    private func list(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STOPS")
                .busText(TypeStyles.sectionHeaderPhone)
                .foregroundStyle(theme.headerCaption)
                .padding(.horizontal, 4)
            ForEach(SavedSetups.sorted(store.history)) { setup in
                NavigationLink(value: setup.id) {
                    StopRow(setup: setup, entry: entry(for: setup, at: date))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let savedAt = store.savedAt {
                    Text(String(appLocalized: "FROM YOUR IPHONE · SYNCED \(WidgetFormat.time(savedAt))"))
                        .busText(TypeStyles.creditLinePhone)
                }
                Text("Language and colours follow your iPhone")
                    .busText(TypeStyles.creditLinePhone)
            }
            .foregroundStyle(theme.dashCaption)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    /// The picture a complication on this stop would show now, from the stored numbers alone.
    private func entry(for setup: SavedSetup, at date: Date) -> NextBusEntry {
        NextBusTimeline.entry(history: [setup], chosenID: setup.id, snapshot: WidgetSnapshotStore().load(setupID: setup.id),
                              layout: WidgetLayout(arrivalsShown: 1), palette: store.palette,
                              appearance: store.appearance, now: date)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHOOSE YOUR STOP")
                .busText(TypeStyle(.archivoBlack, 17, tracking: -0.01))
                .foregroundStyle(theme.primaryText)
                .minimumScaleFactor(0.7)
            Text("PICK A STOP ON YOUR IPHONE FIRST")
                .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.06))
                .foregroundStyle(theme.dashCaption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// One saved stop: its name over its lines' badges, the next bus's minutes trailing when there
/// are numbers to trust, and a pin when it is pinned.
private struct StopRow: View {
    @Environment(\.theme) private var theme
    var setup: SavedSetup
    var entry: NextBusEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: setup.stop.name)
                    .busText(TypeStyle(.archivoBlack, 17, tracking: -0.013))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    ForEach(setup.lines.prefix(3), id: \.id) { line in
                        WidgetBadge(number: line.shortName, colorIndex: entry.colorIndex(for: line.id),
                                    side: 20, numeralSize: 10)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if setup.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityHidden(true)
                }
                if let arrival = entry.arrivals.first {
                    WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                                  numberStyle: TypeStyle(.archivoBlack, 22, tracking: -0.03, lineHeight: 1),
                                  unitStyle: TypeStyle(.archivoBlack, 12), spacing: 3)
                        .fixedSize()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetCardBackground(radius: 14))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
