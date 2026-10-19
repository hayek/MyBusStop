#if os(tvOS)
import SwiftUI

/// Where Apple TV's stack goes from its root, the saved stops.
private enum TVRoute: Hashable {
    case board
    case find
    case lines
}

/// Apple TV's app: glanced at, not left on. It opens on the saved stops — the rider's own, synced
/// from their other devices — and one click shows a stop's board. Menu goes back, as everywhere on
/// the TV; left and right on a board flip to the neighbouring stop.
struct TVRootView: View {
    @Bindable var settings: SettingsStore
    /// Made once, up front: the stack's destinations are built from the state they were declared
    /// with, and a model created on the way to the board is not yet there when the board is.
    /// Nothing polls until a board is on screen.
    @State private var model: BoardViewModel
    @State private var setup: SetupViewModel
    @State private var path: [TVRoute] = []
    @State private var showsSettings = false
    /// The stops a board flips through, as the home row showed them when the board was opened.
    /// Opening a stop moves it to the front of the history, so the live order would bounce the
    /// remote between the same two.
    @State private var flipOrder: [SavedSetup] = []

    init(settings: SettingsStore) {
        self.settings = settings
        _setup = State(initialValue: SetupViewModel(settings: settings))
        _model = State(initialValue: BoardViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack(path: $path) {
            TVHomeView(settings: settings,
                       onOpen: open,
                       onFind: {
                           // A fresh search each time, not the last one's leftovers.
                           setup.query = ""
                           path = [.find]
                       },
                       onSettings: { showsSettings = true })
                .navigationDestination(for: TVRoute.self) { route in
                    switch route {
                    case .board:
                        TVBoardScreen(model: model, onMove: flip, onBack: { path.removeAll() })
                    case .find:
                        TVStopFinderView(model: setup) { stop in
                            setup.rememberSearchIfAny()
                            path.append(.lines)
                            Task { await setup.choose(stop) }
                        }
                    case .lines:
                        TVLinePickerView(model: setup) {
                            setup.confirm()
                            flipOrder = TVStopOrder.ordered(settings.savedSetups)
                            showBoard()
                        }
                    }
                }
        }
        .id(settings.language)
        // Full screen, as Settings is everywhere on the TV: a sheet there is a small floating card.
        .fullScreenCover(isPresented: $showsSettings) {
            TVSettingsScreen(settings: settings)
        }
        .onOpenURL { url in
            guard let id = WidgetDeepLink.setupID(from: url),
                  let saved = settings.savedSetups.first(where: { $0.id == id }) else { return }
            showsSettings = false
            open(saved)
        }
        .onChange(of: RemoteFlags.shared.revision) { settings.mirrorProviderSwitches() }
        .task {
            // The TV has no welcome story; a rider arriving here has nothing left to be shown.
            if settings.onboarding != .done { settings.onboarding = .done }
            await stageScreenshot()
        }
        .preferredColorScheme(settings.boardColorScheme)
        .modifier(LanguageOverride(language: settings.language))
    }

    private func isAvailable(_ saved: SavedSetup) -> Bool {
        settings.providerIsAvailable(saved.providerID ?? WidgetProviderGate.legacyProviderID)
    }

    /// A card, or a Top Shelf link. A stop whose provider is switched off is not opened, however
    /// it was asked for.
    private func open(_ saved: SavedSetup) {
        guard isAvailable(saved) else { return }
        flipOrder = TVStopOrder.ordered(settings.savedSetups)
        setup.use(saved)
        showBoard()
    }

    /// The neighbouring stop, from the order the board was opened with.
    private func flip(_ step: Int) {
        guard let current = settings.configuration else { return }
        let id = SavedSetup.identifier(stop: current.stop, lineIDs: current.lines.map(\.id))
        let order = flipOrder.isEmpty ? TVStopOrder.ordered(settings.savedSetups) : flipOrder
        // Stops removed on another device since, or whose provider is off, are passed over; the
        // current one stays in so the step is counted from it.
        let live = order.compactMap { entry in settings.savedSetups.first { $0.id == entry.id } }
            .filter { $0.id == id || isAvailable($0) }
        guard let next = TVStopOrder.neighbour(of: id, step: step, in: live) else { return }
        setup.use(next, source: "tv_flip")
        model.configurationChanged()
    }

    /// Screenshot mode: the screen it was asked for, reached the way a rider would. `stops` is the
    /// home row itself, and so is `search`: the TV finds stops on a screen of its own, not that one.
    private func stageScreenshot() async {
        guard let shot = ScreenshotMode.current else { return }
        switch shot.screen {
        case .stops, .search:
            break
        case .board:
            showBoard()
        case .tapped:
            showBoard()
            while model.snapshot.arrivals.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
            if let bus = model.snapshot.arrivals[1].bus { model.tap(busID: bus.id) }
        case .lines:
            guard let staged = shot.boardStop else { return }
            path = [.find, .lines]
            await setup.choose(staged.stop)
            for line in staged.lines { setup.toggle(line) }
        case .settings:
            showsSettings = true
        }
    }

    /// The board in place of whatever is above the home, keeping the one view model so its
    /// polling loop survives.
    private func showBoard() {
        guard settings.configuration != nil else { return }
        model.configurationChanged()
        path = [.board]
    }
}
/// Settings over the whole screen. A full-screen cover is see-through on the TV, so it brings the
/// board's own background: the stops behind would otherwise show through the form.
private struct TVSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    var settings: SettingsStore

    var body: some View {
        SettingsView(settings: settings)
            .background(Theme.resolve(colorScheme).background.ignoresSafeArea())
    }
}
#endif
