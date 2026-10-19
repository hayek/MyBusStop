#if !os(tvOS)
import LoveLetterUI
#endif
import SwiftUI

struct ContentView: View {
    @State private var settings = ScreenshotMode.current?.makeSettings() ?? SettingsStore()

    var body: some View {
        Group {
            #if os(tvOS)
            TVRootView(settings: settings)
            #else
            RootView(settings: settings)
            #endif
        }
        // The rider's own history only: staged screenshots and tests keep theirs to themselves.
        .task { if WidgetBridge.isActive { CloudHistory.shared.attach(settings) } }
    }
}

#if !os(tvOS)

/// Where the stack can go from its root, My Stops.
private enum Route: Hashable {
    /// The lines of the stop the rider is standing at, from the nearby banner (and the staged
    /// screenshot of the picker). A stop found in search has its lines chosen inside search.
    case lines
    case board
}

/// The app's one navigation stack: My Stops, then a board.
///
/// My Stops is always the root, so going back from anywhere is the system's own — the back
/// button, and a swipe from the leading edge. A new stop is found on the search screen, presented
/// over the root rather than pushed: it is a detour, stop then lines, that ends either back on My
/// Stops or, with the lines chosen, on the board. The board replaces whatever was above My Stops,
/// so its way back is straight to the saved stops.
///
/// It launches straight into the board whenever a stop has already been chosen — a wall display
/// that reboots must come back to the map, never to setup.
struct RootView: View {
    @Bindable var settings: SettingsStore
    @State private var model: BoardViewModel?
    @State private var setup: SetupViewModel
    @State private var path: [Route]
    @State private var showsSettings = false
    @State private var showsFeedback = false
    /// The first-install welcome story, over My Stops.
    @State private var showsWelcome: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// Whether the app has been in the background since it was last in front, for debug's replay.
    @State private var wasInBackground = false
    /// The stop the rider is standing at, offered over whatever screen is up.
    @State private var proximity: StopProximityWatcher

    init(settings: SettingsStore) {
        self.settings = settings
        _setup = State(initialValue: SetupViewModel(settings: settings))
        _proximity = State(initialValue: StopProximityWatcher(settings: settings))
        // Built here rather than on appear: a board that exists must be on the very first frame.
        // Deciding later means My Stops is drawn once and then covered, which on a wall display is
        // a flash of the one screen it is never supposed to show.
        let configured = settings.configuration != nil
        // Debug's "show onboarding on next launch": this launch plays a first install's welcome,
        // over My Stops rather than the board. (Coming back from the background counts too;
        // see `replayWelcomeIfAsked`.)
        let replaysWelcome = settings.welcomeOnNextLaunch && ScreenshotMode.current == nil
        if replaysWelcome {
            settings.welcomeOnNextLaunch = false
            settings.onboarding = .welcome
        }
        _model = State(initialValue: configured ? BoardViewModel(settings: settings) : nil)
        _path = State(initialValue: configured && !replaysWelcome ? [.board] : [])
        // Decided here for the same reason: the story is the first frame of a first launch, not
        // something laid over a home the rider has already glimpsed.
        _showsWelcome = State(initialValue: (replaysWelcome || !configured && settings.onboarding == .welcome)
                                            && ScreenshotMode.current == nil)
    }

    var body: some View {
        NavigationStack(path: $path) {
            MyStopsView(model: setup,
                        onOpenSettings: { showsSettings = true },
                        onOpenFeedback: Feedback.client == nil ? nil : {
                            Telemetry.log("feedback_opened")
                            showsFeedback = true
                        },
                        onResume: { saved in
                            setup.use(saved)
                            showBoard()
                        })
            // Captions built in code are only read again when rebuilt.
            .id(settings.language)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .lines:
                    LinePickerView(model: setup, onConfirm: showChosenLines)
                        .id(settings.language)
                case .board:
                    if let model {
                        BoardView(model: model, onChangeStop: {
                            model.showsSetupTip = false
                            path.removeAll()
                        }, onPull: {
                            // Not awaited: the stop list can take far longer than the board's
                            // refresh, and the spinner is the board's.
                            guard watchesNearbyStops else { return }
                            Task { await proximity.lookAgain() }
                        })
                            #if os(iOS)
                            // The board is edge to edge and names its stop itself; the bar would
                            // only cover it. Hiding it would also take the back swipe, so that is
                            // put back.
                            .toolbar(.hidden, for: .navigationBar)
                            .background(SwipeBackEnabler())
                            #endif
                    }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: searchIsPresented, onDismiss: { setup.searchDismissed() }) {
            StopSearchFlow(model: setup, onConfirmLines: showChosenLines)
        }
        #else
        // macOS has no full-screen cover: a large sheet, the map given room beside its panel.
        .sheet(isPresented: searchIsPresented, onDismiss: { setup.searchDismissed() }) {
            StopSearchFlow(model: setup, onConfirmLines: showChosenLines)
                .frame(minWidth: 900, minHeight: 640)
        }
        #endif
        // An overlay rather than a cover: a cover presented from the first frame still animates in
        // after it, showing My Stops first.
        .accessibilityHidden(showsWelcome)
        .overlay {
            ZStack {
                if showsWelcome {
                    WelcomeStoryView(onFinish: finishWelcome)
                        .transition(.opacity)
                }
            }
            // Out of the way the moment it is done: a second tap while it fades reaches nothing.
            .allowsHitTesting(showsWelcome)
        }
        .overlay(alignment: .top) {
            ZStack {
                if let alert = nearbyAlert {
                    NearbyStopBanner(alert: alert, colorIndex: { setup.colorIndex(for: $0) },
                                     onOpen: { openNearbyStop(alert) },
                                     onDismiss: { proximity.dismiss() })
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4), value: nearbyAlert)
            .busTheme()
        }
        // Only while someone is holding the app: not on a wall, not behind the welcome story, and
        // only once location is allowed — this never asks for it.
        .task(id: watchesNearbyStops) {
            guard watchesNearbyStops else { return }
            await proximity.watch()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(settings: settings)
        }
        // ⌘, from the app menu (or a keyboard's): settings over whichever screen is showing, but
        // not over the welcome story, which has not let the rider in yet.
        // Nor over search, whose sheet on a Mac would have to give way first.
        .focusedSceneValue(\.openSettings, showsWelcome || setup.search.isPresented
                                            ? nil : OpenSettingsAction(openSettings))
        .sheet(isPresented: $showsFeedback) {
            if let client = Feedback.client {
                FeedbackSheet(client: client)
                    .analyticsScreen("feedback")
            }
        }
        .task {
            if showsWelcome { Telemetry.log("welcome_shown") }
            await stageScreenshot()
        }
        .onOpenURL { openWidgetLink($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasInBackground = true }
            if phase == .active, wasInBackground {
                wasInBackground = false
                replayWelcomeIfAsked()
            }
        }
        // Only once fetched values apply: the in-app defaults would switch a pulled provider back
        // on for the widget until then.
        .onChange(of: RemoteFlags.shared.revision) { settings.mirrorProviderSwitches() }
        .preferredColorScheme(settings.boardColorScheme)
        .modifier(LanguageOverride(language: settings.language))
        #if os(macOS)
        // A floor for the window, not for the app: on a phone this is wider than the screen, and
        // the whole board would hang off both edges.
        .frame(minWidth: 480, minHeight: 600)
        // A widget tapped on the desktop brings this window forward rather than opening another.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #endif
    }

    /// A widget was tapped: its stop's board, straight away, as if resumed from the history. Any
    /// other link — a widget with no stop yet — just opens the app where it was.
    private func openWidgetLink(_ url: URL) {
        guard let id = WidgetDeepLink.setupID(from: url),
              let saved = settings.savedSetups.first(where: { $0.id == id }) else { return }
        setup.closeSearch()
        showsSettings = false
        model?.showsSettings = false
        model?.showsLinePicker = false
        setup.use(saved, source: "widget")
        showBoard()
    }

    /// Whether to follow the rider for the stop they are standing at.
    private var watchesNearbyStops: Bool {
        scenePhase == .active && !settings.wallMode && !showsWelcome && ScreenshotMode.current == nil
            && !setup.location.needsPermission && !setup.location.isDenied
    }

    /// The offer, unless the screen already shows its stop — the line picker open on it — or a sheet
    /// covers the banner, where it would time out unseen and not be offered again on this arrival.
    private var nearbyAlert: StopNearbyAlert? {
        guard watchesNearbyStops, let alert = proximity.alert else { return nil }
        if showsSettings || showsFeedback || setup.search.isPresented
            || model?.showsSettings == true || model?.showsLinePicker == true {
            return nil
        }
        if path.last == .lines, setup.chosenStop?.code == alert.stop.code { return nil }
        return alert
    }

    /// The offered stop, tapped: the board the rider keeps there, as if resumed from the history,
    /// or at a stop they have never set up, its lines to choose from first.
    private func openNearbyStop(_ alert: StopNearbyAlert) {
        proximity.dismiss()
        setup.closeSearch()
        showsSettings = false
        model?.showsSettings = false
        model?.showsLinePicker = false
        Telemetry.log("nearby_stop_opened", ["saved": alert.saved == nil ? "no" : "yes"])
        if var saved = alert.saved {
            // An entry from before providers were recorded is the stop's own provider's, not
            // whichever setup last browsed; saving it again records that.
            saved.providerID = saved.providerID ?? alert.providerID
            setup.use(saved, source: "nearby_banner")
            showBoard()
        } else {
            // Its lines come from the provider the stop is from.
            if settings.providerID != alert.providerID { settings.providerID = alert.providerID }
            path = [.lines]
            Task { await setup.choose(alert.stop) }
        }
    }

    /// The story is over, and both of its answers are ways to find a first stop, so both go on
    /// to the search screen. Allowing location asks for it now, while the story fades, and search
    /// opens on the map already looking; choosing to search by name opens it with the keyboard up.
    /// A story left to time out stays on My Stops, where the rider can still choose.
    ///
    /// Refusing in the system's prompt keeps the keyboard down: the drawer then says location is
    /// off and offers both ways on — Settings, or search — and on a phone a keyboard sprung up
    /// unasked would cover that card. Search by name is one tap away on it.
    private func finishWelcome(_ choice: WelcomeChoice) {
        // Once: a tap that lands during the fade is not a second answer.
        guard showsWelcome else { return }
        settings.onboarding = .tipPending
        let answer = switch choice {
        case .allowLocation: "location"
        case .searchByName: "search"
        case .timedOut: "timeout"
        }
        Telemetry.log("welcome_finished", ["choice": answer])
        withAnimation(.easeOut(duration: 0.3)) {
            showsWelcome = false
        } completion: {
            // A new screen: VoiceOver starts reading it from the top.
            AccessibilityNotification.ScreenChanged(nil).post()
            switch choice {
            case .allowLocation: setup.openSearch()
            case .searchByName: setup.openSearch(focusingField: true)
            case .timedOut: break
            }
        }
        guard choice == .allowLocation else { return }
        // Started now rather than once search is up: the system's prompt comes over the fade, and
        // the search screen's own load on appear waits on this one's fix instead of asking again.
        Task { await setup.loadNearby(force: true, askingPermission: true) }
    }

    /// Bound to the search screen's presentation. Dismissed by the system — Escape on a Mac, say —
    /// it is closed the way CANCEL closes it.
    private var searchIsPresented: Binding<Bool> {
        Binding(get: { setup.search.isPresented }, set: { if !$0 { setup.closeSearch() } })
    }

    /// SHOW THE MAP on the line picker, in search or from the nearby banner: the board replaces
    /// everything above My Stops, the search screen going down over it as it does.
    private func showChosenLines() {
        setup.confirm()
        setup.closeSearch()
        showBoard()
        // Marked done as it is shown, not as it is dismissed: a wall display that reboots must
        // never bring it back.
        if settings.onboarding == .tipPending, let model {
            model.showsSetupTip = true
            settings.onboarding = .done
        }
    }

    /// Replaces whatever is above My Stops with the board. The same view model is kept so its
    /// polling loop survives, but it is told to let go of a board that belongs to another stop.
    private func showBoard() {
        guard settings.configuration != nil else { return }
        if let model { model.configurationChanged() } else { model = BoardViewModel(settings: settings) }
        path = [.board]
    }

    /// Debug's "show onboarding on next launch", when the app comes back from the background
    /// rather than being launched afresh: a phone rarely quits an app, so leaving it and opening it
    /// again is the launch a tester means. The story opens over My Stops, as on a first install,
    /// with any settings sheet or search put away.
    private func replayWelcomeIfAsked() {
        guard settings.welcomeOnNextLaunch, !showsWelcome, ScreenshotMode.current == nil else { return }
        settings.welcomeOnNextLaunch = false
        settings.onboarding = .welcome
        setup.closeSearch()
        showsSettings = false
        model?.showsSettings = false
        model?.showsLinePicker = false
        model?.showsSetupTip = false
        path = []
        showsWelcome = true
        Telemetry.log("welcome_shown")
    }

    /// The board has its own settings sheet; My Stops and the line picker share the root's.
    private func openSettings() {
        if path.last == .board, let model {
            model.showsSettings = true
        } else {
            showsSettings = true
        }
    }

    /// Screenshot mode: goes on to the screen it was asked for, the way a rider would get there.
    private func stageScreenshot() async {
        guard let shot = ScreenshotMode.current else { return }
        #if os(macOS)
        // Set here rather than trusted to the default size, which a saved window frame overrides.
        if let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first {
            window.setContentSize(ScreenshotMode.macWindowSize)
            window.center()
        }
        #endif
        #if os(iOS)
        // Asked for either way: an iPad keeps the last launch's orientation otherwise. The iPad
        // only lets an app turn itself when it runs full screen, which the script's build sets.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:
                shot.orientation == .landscape ? .landscapeRight : .portrait))
        }
        #endif
        switch shot.screen {
        case .stops, .board:
            break
        case .search:
            setup.openSearch()
        case .lines:
            guard let staged = shot.boardStop else { return }
            path = [.lines]
            await setup.choose(staged.stop)
            for line in staged.lines { setup.toggle(line) }
        case .settings:
            showsSettings = true
        case .tapped:
            // The bus after the next one, so the readout visibly changes to it.
            guard let model else { return }
            while model.snapshot.arrivals.count < 2 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let bus = model.snapshot.arrivals[1].bus { model.tap(busID: bus.id) }
        }
    }
}

#if os(iOS)
/// A navigation bar hidden in SwiftUI takes the edge swipe back with it. This finds the hosting
/// navigation controller and answers for its swipe, allowing it whenever there is a screen to
/// go back to.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
#endif

#endif

/// Puts a language chosen in Settings into the environment, so `Text` resolves in it and every
/// screen, the board included, mirrors for a right-to-left one. Following the device, it leaves
/// both alone.
struct LanguageOverride: ViewModifier {
    @Environment(\.locale) private var inheritedLocale
    @Environment(\.layoutDirection) private var inheritedDirection
    var language: String?

    // Always applied, never branched on: swapping the modifier's content would rebuild the tree
    // beneath it and close the very Settings sheet the language was chosen in.
    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.map(Locale.init(identifier:)) ?? inheritedLocale)
            .environment(\.layoutDirection, language.map(AppLanguage.layoutDirection(for:)) ?? inheritedDirection)
            #if os(iOS)
            .onAppear { Self.mirrorWindows(for: language) }
            .onChange(of: language) { _, language in Self.mirrorWindows(for: language) }
            #endif
    }

    #if os(iOS)
    /// The environment only reaches SwiftUI. A sheet already on screen, its navigation bar and its
    /// form are UIKit, and take their direction from the window's traits — so without this the
    /// words change language and the layout stays facing the old way until a relaunch.
    private static func mirrorWindows(for language: String?) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let language {
                window.traitOverrides.layoutDirection = AppLanguage.layoutDirection(for: language) == .rightToLeft
                    ? .rightToLeft : .leftToRight
            } else {
                window.traitOverrides.remove(UITraitLayoutDirection.self)
            }
        }
    }
    #endif
}

#Preview {
    ContentView()
}
