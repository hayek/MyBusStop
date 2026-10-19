import SwiftUI
import Observation

/// Everything the app remembers between launches. One observable object so a change anywhere
/// re-renders the board, and the only place that talks to `UserDefaults`.
@MainActor @Observable final class SettingsStore {
    private enum Key {
        static let configuration = "board.configuration"
        static let savedSetups = "board.savedSetups"
        static let savedSetupsSavedAt = "board.savedSetupsSavedAt"
        static let historyTombstones = "board.historyTombstones"
        static let recentSearches = "board.recentSearches"
        static let paletteAssignments = "palette.assignments"
        static let wallMode = "settings.wallMode"
        static let wallSchedule = "settings.wallSchedule"
        static let appearance = "settings.appearance"
        static let tapBehaviour = "settings.tapBehaviour"
        static let providerID = "settings.providerId"
        static let providerIsAutomatic = "settings.providerIsAutomatic"
        static let mockScenario = "mock.scenario"
        static let onboarding = "onboarding.progress"
        static let welcomeOnNextLaunch = "debug.welcomeOnNextLaunch"
    }

    private let defaults: UserDefaults
    /// The App Group suite the widget reads (`AppGroup`): the history itself, and copies of what
    /// the widget needs to draw it the way the app does.
    private let shared: UserDefaults

    /// `shared` defaults to the App Group for the app's own store and to `defaults` for any other,
    /// so a test's or a screenshot run's volatile store never reaches the rider's widget.
    init(defaults: UserDefaults = .standard, shared: UserDefaults? = nil) {
        self.defaults = defaults
        self.shared = shared ?? (defaults === UserDefaults.standard ? AppGroup.defaults : defaults)
        let configuration = Self.decode(BoardConfiguration.self, from: defaults, key: Key.configuration)
        let history = Self.loadHistory(own: defaults, shared: self.shared)
        self.configuration = configuration
        savedSetups = history
        historyTombstones = Self.decode([String: Date].self, from: defaults, key: Key.historyTombstones) ?? [:]
        onboarding = OnboardingProgress.initial(stored: defaults.string(forKey: Key.onboarding),
                                                hasConfiguration: configuration != nil,
                                                hasHistory: !history.isEmpty)
        welcomeOnNextLaunch = defaults.bool(forKey: Key.welcomeOnNextLaunch)
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        paletteAssignments = defaults.dictionary(forKey: Key.paletteAssignments) as? [String: Int] ?? [:]
        wallMode = defaults.bool(forKey: Key.wallMode)
        wallSchedule = Self.decode(WallSchedule.self, from: defaults, key: Key.wallSchedule) ?? .alwaysOn
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        language = defaults.string(forKey: AppLanguage.defaultsKey).flatMap { AppLanguage.supported.contains($0) ? $0 : nil }
        tapBehaviourOverride = defaults.string(forKey: Key.tapBehaviour).flatMap(TapBehaviour.init)
        providerID = defaults.string(forKey: Key.providerID) ?? "bus.gov.il"
        providerIsAutomatic = defaults.object(forKey: Key.providerIsAutomatic) as? Bool ?? true
        mockScenario = defaults.string(forKey: Key.mockScenario).flatMap(MockScenario.init) ?? .main
        mirrorForWidget()
        // Once at launch, so a watch that missed the last change catches up (and the session knows the store).
        WatchSync.shared.settingsChanged(self)
    }

    var configuration: BoardConfiguration? { didSet { Self.encode(configuration, to: defaults, key: Key.configuration) } }
    /// Stops the rider has watched, with the lines they watched there.
    /// Kept in the shared suite, where the widget offers the same list (`SharedHistoryStore`).
    /// A copy stays in the app's own suite, so a launch that finds the shared one missing or
    /// behind (a build signed without the group, a Mac that refused it) still has every change.
    var savedSetups: [SavedSetup] {
        didSet {
            let now = Date()
            SharedHistoryStore(defaults: shared).save(savedSetups, at: now)
            Self.encode(savedSetups, to: defaults, key: Key.savedSetups)
            defaults.set(now, forKey: Key.savedSetupsSavedAt)
            WidgetBridge.historyChanged(keeping: Set(savedSetups.map(\.id)))
            WatchSync.shared.settingsChanged(self)
            historyDidChange?()
        }
    }
    /// Entries removed here and when, kept until iCloud has carried the removal to the rider's
    /// other devices (`HistorySync`).
    var historyTombstones: [String: Date] {
        didSet { Self.encode(historyTombstones, to: defaults, key: Key.historyTombstones) }
    }
    /// Told after every change to the history, for `CloudHistory` to send it on. Nil in tests
    /// and screenshots, which keep their history to themselves.
    @ObservationIgnored var historyDidChange: (() -> Void)?

    /// The history as it goes to iCloud.
    var syncedHistory: SyncedHistory { SyncedHistory(entries: savedSetups, tombstones: historyTombstones) }

    /// Takes a history merged with another device's. Only what changed is written, so taking back
    /// what was just sent does not send it again.
    func adopt(_ history: SyncedHistory) {
        if historyTombstones != history.tombstones { historyTombstones = history.tombstones }
        if savedSetups != history.entries { savedSetups = history.entries }
    }
    /// What they have searched for, so a stop found once by name is one tap away again.
    var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    var paletteAssignments: [String: Int] {
        didSet {
            defaults.set(paletteAssignments, forKey: Key.paletteAssignments)
            mirrorForWidget()
        }
    }
    var wallMode: Bool { didSet { defaults.set(wallMode, forKey: Key.wallMode) } }
    /// When a wall display shows the board rather than a black screen. No windows means always.
    var wallSchedule: WallSchedule { didSet { Self.encode(wallSchedule, to: defaults, key: Key.wallSchedule) } }
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            mirrorForWidget()
        }
    }
    /// A language code from `AppLanguage.supported`, or nil to follow the device.
    var language: String? {
        didSet {
            AppLanguage.set(language, in: defaults)
            mirrorForWidget()
        }
    }
    var tapBehaviourOverride: TapBehaviour? { didSet { defaults.set(tapBehaviourOverride?.rawValue, forKey: Key.tapBehaviour) } }
    /// The provider setup searches and lists nearby stops with. In automatic mode it follows the
    /// rider's location; the board keeps the provider its stop was chosen from (`boardProvider`).
    var providerID: String { didSet { defaults.set(providerID, forKey: Key.providerID) } }
    /// Pick the provider from where the rider is standing. On by default; choosing a provider in
    /// Settings turns it off.
    var providerIsAutomatic: Bool { didSet { defaults.set(providerIsAutomatic, forKey: Key.providerIsAutomatic) } }
    /// Where the rider is in the first-install welcome (`OnboardingProgress`).
    var onboarding: OnboardingProgress { didSet { defaults.set(onboarding.rawValue, forKey: Key.onboarding) } }
    /// Debug: the next launch opens on the welcome story as a first install does, the tip on the
    /// next board after it, whatever is already set up. Taken once, by that launch.
    var welcomeOnNextLaunch: Bool { didSet { defaults.set(welcomeOnNextLaunch, forKey: Key.welcomeOnNextLaunch) } }
    var mockScenario: MockScenario { didSet { cachedProviders = [:]; defaults.set(mockScenario.rawValue, forKey: Key.mockScenario) } }

    /// A wall display shows the tapped bus beside the next arrival so you never lose sight of the
    /// one you are catching; in the hand the readout simply swaps. Either can be overridden.
    var tapBehaviour: TapBehaviour { tapBehaviourOverride ?? (wallMode ? .beside : .swap) }

    /// Whether a wall display shows the board right now, untouched: wall mode, inside its schedule.
    func wallDisplayIsAwake(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        wallMode && wallSchedule.isOn(at: date, calendar: calendar)
    }

    /// What the board is actually drawn in.
    ///
    /// A wall display is a lit panel in a room, so it stays dark whatever the device is set to. The
    /// rule for a dark room is to dim the board, never to turn it into a cream one.
    var boardColorScheme: ColorScheme? { wallMode ? .dark : appearance.colorScheme }

    /// Substitutes the live feed. Tests set it; the app never does. It is the one place above the
    /// seam that names a specific provider instance, and it is write-only from outside.
    var providerOverride: (any TransitProvider)? { didSet { cachedProviders = [:] } }

    /// Whether the remote switches let a region's provider be used. Tests substitute it; the app
    /// asks `RemoteFlags`.
    @ObservationIgnored var regionIsAvailable: @MainActor (SupportedRegion) -> Bool = {
        RemoteFlags.shared.isEnabled(providerID: $0.providerID, experimental: $0.isExperimental)
    }

    /// Whether the API key a provider needs is at hand (`APIKeys`); keyless providers always have
    /// it. Release builds hold no keys, and a Debug build without a local one neither, so those
    /// regions drop out as if switched off. Tests substitute it.
    @ObservationIgnored var providerHasKey: @MainActor (String) -> Bool = {
        TransitProviders.provider(id: $0).hasRequiredAPIKey
    }

    /// A region the rider can be offered: its provider has its key and is not switched off.
    func regionIsUsable(_ region: SupportedRegion) -> Bool {
        providerHasKey(region.providerID) && regionIsAvailable(region)
    }

    /// Whether a rider outside every region may fall back to Transitous (`transitous_enabled`).
    /// Tests substitute it; the app asks `RemoteFlags`.
    @ObservationIgnored var transitousIsEnabled: @MainActor () -> Bool = { RemoteFlags.shared.transitousEnabled }

    /// Setup is browsing the worldwide fallback rather than a region of ours.
    var isUsingWorldwideFallback: Bool { providerID == TransitousProvider.providerID }

    /// Whether the remote switches, and the build's API keys, let this provider be used at all.
    func providerIsAvailable(_ id: String) -> Bool {
        // Transitous forbids commercial use, so it is off unless its own flag says otherwise.
        if id == TransitousProvider.providerID, !transitousIsEnabled() { return false }
        guard providerHasKey(id) else { return false }
        guard let region = SupportedRegions.region(providerID: id) else {
            return regionIsAvailable(SupportedRegion(id: id, countryCode: "", name: id, providerID: id,
                                                     fit: .full, bounds: GeoBounds(minLat: 0, minLon: 0, maxLat: 0, maxLon: 0)))
        }
        return regionIsAvailable(region)
    }

    /// Built once and kept, so any state an adapter grows later survives between refreshes.
    @ObservationIgnored private var cachedProviders: [String: any TransitProvider] = [:]

    /// What setup browses with.
    var provider: any TransitProvider { provider(id: providerID) }

    /// What the board polls: the provider its stop was chosen from, wherever the rider is now. A
    /// Boston board stays on MBTA even after setup has been opened in Tel Aviv and cancelled.
    var boardProvider: any TransitProvider { provider(id: configuration?.providerID ?? providerID) }

    /// The adapter for `id`, built once and kept (or the test override).
    func provider(id: String) -> any TransitProvider {
        if let providerOverride { return providerOverride }
        if let cached = cachedProviders[id] { return cached }
        var resolved = TransitProviders.provider(id: id)
        if var mock = resolved as? MockTransitProvider {
            mock.scenario = mockScenario
            resolved = mock
        }
        cachedProviders[id] = resolved
        return resolved
    }

    /// In automatic mode, points setup at the region the rider is standing in, and returns it.
    ///
    /// Sticky: a provider that already covers the point is kept, so a rider in Hong Kong who
    /// switched from MTR Bus to KMB is not switched back on the next fix. Nil means no supported
    /// region covers the point (or, in manual mode, that the chosen provider does not).
    ///
    /// A region whose provider has been switched off remotely, or needs an API key this build lacks,
    /// is passed over for the next one that covers the point, as if it were not there.
    ///
    /// Where no region covers the point and `transitous_enabled` is on, setup falls back to
    /// Transitous, which is not a region: the result is still nil. Any region covering the point
    /// wins over it, and a provider chosen in Settings is never replaced.
    @discardableResult
    func adoptLocation(_ point: GeoPoint) -> SupportedRegion? {
        guard let id = providerID(at: point) else { return nil }
        if providerID != id { providerID = id }
        return SupportedRegions.regions(containing: point).first { $0.providerID == id && regionIsUsable($0) }
    }

    /// The provider `adoptLocation` settles on at `point`, without switching setup to it: the one in
    /// use when it covers the point, else (in automatic mode) the first usable region there, else the
    /// worldwide fallback when it is on. In manual mode, only the chosen provider, and only where it
    /// covers the point (or it is the worldwide fallback, which covers everywhere).
    func providerID(at point: GeoPoint) -> String? {
        let candidates = SupportedRegions.regions(containing: point).filter { regionIsUsable($0) }
        if candidates.contains(where: { $0.providerID == providerID }) { return providerID }
        guard providerIsAutomatic else {
            return isUsingWorldwideFallback && providerIsAvailable(providerID) ? providerID : nil
        }
        if let best = candidates.first { return best.providerID }
        return providerIsAvailable(TransitousProvider.providerID) ? TransitousProvider.providerID : nil
    }

    func colorIndex(for lineID: String) -> Int {
        LineColorAssigner.provisionalIndex(for: lineID, persisted: paletteAssignments)
    }

    /// Records the chosen stop and lines, fixing each line's colour for good and saving the pair
    /// to history so it can be returned to in one tap.
    func apply(stop: TransitStop, lines: [TransitLine], providerID: String, at date: Date = Date()) {
        paletteAssignments = LineColorAssigner.resolve(
            persisted: paletteAssignments,
            selected: lines.map(\.id),
            preferred: lines.reduce(into: [:]) { $0[$1.id] = $1.brandColorIndex })
        configuration = BoardConfiguration(providerID: providerID, stop: stop, lines: lines)
        savedSetups = SavedSetups.recording(SavedSetup(stop: stop, lines: lines, lastUsedAt: date,
                                                       providerID: providerID),
                                            in: savedSetups)
    }

    func rememberSearch(_ term: String) {
        recentSearches = RecentSearches.recording(term, in: recentSearches)
    }

    func togglePin(_ id: String, at date: Date = Date()) {
        savedSetups = SavedSetups.togglingPin(id: id, in: savedSetups, at: date)
    }

    func removeSetup(_ id: String, at date: Date = Date()) {
        historyTombstones[id] = date
        savedSetups = SavedSetups.removing(id: id, from: savedSetups)
    }

    /// The history from whichever copy was saved last. History used to live only in the app's
    /// own suite and is still kept there too, so that copy is the fallback: when the shared one
    /// is absent, older, or unreadable. An unreadable shared copy is left as it is.
    private static func loadHistory(own defaults: UserDefaults, shared: UserDefaults) -> [SavedSetup] {
        let history = SharedHistoryStore(defaults: shared)
        let own = decode([SavedSetup].self, from: defaults, key: Key.savedSetups)
        let ownSavedAt = defaults.object(forKey: Key.savedSetupsSavedAt) as? Date
        let ownIsNewer = ownSavedAt.map { own in history.savedAt().map { own > $0 } ?? true } ?? false
        switch history.contents() {
        case .history(let stored) where !ownIsNewer:
            return stored
        case .unreadable:
            return own ?? []
        case .absent, .history:
            // A build of this version signed without the group kept the shared copy in the
            // standard suite; the app's own store looks there too before giving up.
            let standardCopy = defaults === UserDefaults.standard && shared !== UserDefaults.standard
                ? SharedHistoryStore(defaults: .standard).stored() : nil
            guard let source = own ?? standardCopy else { return [] }
            history.save(source, at: ownSavedAt ?? Date())
            return source
        }
    }

    /// Mirrors which providers the remote switches and the build's keys leave usable, so the
    /// widget, which reads no remote config of its own, never calls one the app would not.
    func mirrorProviderSwitches() {
        let disabled = TransitProviders.all.map(\.id).filter { !providerIsAvailable($0) }.sorted()
        guard shared.stringArray(forKey: SharedKeys.disabledProviders) != disabled else { return }
        shared.set(disabled, forKey: SharedKeys.disabledProviders)
        WatchSync.shared.settingsChanged(self)
    }

    /// Copies what the widget draws with into the shared suite: line colours, so a badge there is
    /// the colour it is here, and the appearance and language chosen in Settings. Once at launch,
    /// so a widget added before this existed catches up, and on every change after.
    private func mirrorForWidget() {
        let changed = shared.dictionary(forKey: SharedKeys.palette) as? [String: Int] != paletteAssignments
            || shared.string(forKey: SharedKeys.appearance) != appearance.rawValue
            || shared.string(forKey: SharedKeys.language) != language
        guard changed else { return }
        shared.set(paletteAssignments, forKey: SharedKeys.palette)
        shared.set(appearance.rawValue, forKey: SharedKeys.appearance)
        shared.set(language, forKey: SharedKeys.language)
        WidgetBridge.settingsChanged()
        WatchSync.shared.settingsChanged(self)
    }

    // MARK: JSON helpers

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode(_ value: (some Encodable)?, to defaults: UserDefaults, key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
