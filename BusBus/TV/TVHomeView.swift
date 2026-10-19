#if os(tvOS)
import SwiftUI

/// The saved stops as a row of cards, pinned first. The last stop used is first in the row, so
/// it already has focus: one click is its board.
struct TVHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    var settings: SettingsStore
    var onOpen: (SavedSetup) -> Void
    var onFind: () -> Void
    var onSettings: () -> Void
    /// Staged screenshots: the numbers the staged feed gives, since no board has saved any.
    @State private var stagedSnapshots: [String: WidgetSnapshot] = [:]

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        // A minute is the smallest step the cards count in, and the snapshots are re-read with it.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let store = WidgetSnapshotStore()
            let glances = StopGlances.build(history: settings.savedSetups,
                                            snapshot: { stagedSnapshots[$0] ?? store.load(setupID: $0) },
                                            now: context.now)
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .firstTextBaseline) {
                    Text("My stops")
                        .busText(TypeStyles.titleLandscape, scale: 1.6)
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Button(action: onSettings) {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }
                // Its own section, so up from any card reaches Settings: the focus engine only
                // looks straight up, and the button sits far to the side of the row.
                .focusSection()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 48) {
                        ForEach(glances) { glance in
                            let available = settings.providerIsAvailable(
                                glance.setup.providerID ?? WidgetProviderGate.legacyProviderID)
                            Button { onOpen(glance.setup) } label: {
                                TVStopCard(glance: glance, isAvailable: available, colorIndex: settings.colorIndex(for:))
                            }
                            .buttonStyle(.card)
                            .disabled(!available)
                        }
                        Button(action: onFind) {
                            TVFindCard(isOnlyCard: glances.isEmpty)
                        }
                        .buttonStyle(.card)
                    }
                    // Room for a focused card to lift without its shadow being clipped.
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
                .focusSection()
                if glances.isEmpty {
                    Text("Stops you save on your iPhone, iPad or Mac appear here through iCloud.")
                        .busText(TypeStyles.kicker, scale: 1.6)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        .task { await stageSnapshots() }
        .analyticsScreen("tv_home")
    }

    private func stageSnapshots() async {
        guard ScreenshotMode.current != nil else { return }
        let provider = settings.provider
        var staged: [String: WidgetSnapshot] = [:]
        for setup in settings.savedSetups {
            var arrivals: [WidgetArrival] = []
            for line in setup.lines {
                let upcoming = (try? await provider.arrivals(for: line, at: setup.stop)) ?? []
                arrivals += upcoming.map {
                    WidgetArrival(lineID: line.id, expectedAt: $0.expectedAt, isRealtime: $0.isRealtime, stopsAway: nil)
                }
            }
            staged[setup.id] = WidgetSnapshot(setupID: setup.id, fetchedAt: AppClock.now,
                                              arrivals: arrivals.sorted { $0.expectedAt < $1.expectedAt })
        }
        stagedSnapshots = staged
    }
}

/// The way to add a stop on the TV itself: nearby, or by name.
private struct TVFindCard: View {
    @Environment(\.theme) private var theme
    var isOnlyCard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text("Find a stop")
                .busText(TypeStyles.titleLandscape)
                .foregroundStyle(theme.primaryText)
            Text(isOnlyCard ? "Nearby or by name" : "Add another stop")
                .busText(TypeStyles.kicker)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(32)
        .frame(width: TVStopCard.size.width * (isOnlyCard ? 1 : 0.6), height: TVStopCard.size.height,
               alignment: .topLeading)
        .background(theme.card)
    }
}
#endif
