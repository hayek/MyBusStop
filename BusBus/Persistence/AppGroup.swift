import Foundation

/// The container the app shares with its widget. The widget runs in its own process with its own
/// defaults, so anything it needs from the app — the history it offers, and what it takes to draw
/// that history the way the app does — is written here.
///
/// The same identifier on iOS and macOS: a multiplatform app keeps one group rather than a Mac
/// team-prefixed twin.
nonisolated enum AppGroup {
    static let identifier = "group.com.hayek.BusBus"

    /// The shared container, or nil where it cannot be used — a build signed without the
    /// entitlement. Worked out once per launch.
    static let containerURL: URL? = {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        #if os(macOS)
        // The Mac hands out a URL for any group, authorised or not, and writes there then fail
        // quietly (or wait on the rider allowing access to another app's data). One small write
        // says whether the container is really ours.
        let probe = url.appending(path: "Library/Caches/.busbus-probe", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: probe, options: .atomic)
        } catch {
            return nil
        }
        #endif
        return url
    }()

    /// The shared suite, or the standard one where the container is unavailable. The app then
    /// still keeps its history; only the widget goes without.
    static let defaults: UserDefaults = containerURL != nil ? (UserDefaults(suiteName: identifier) ?? .standard) : .standard
}

/// Keys in the shared suite. Separate from the app's own so a value is never read from the wrong
/// store by accident.
nonisolated enum SharedKeys {
    /// `[SavedSetup]` as JSON.
    static let history = "shared.history"
    /// When `history` was last written, to tell it from an older copy elsewhere.
    static let historySavedAt = "shared.historySavedAt"
    /// `[String: Int]`, line id to palette index, so badges match the app's colours.
    static let palette = "shared.paletteAssignments"
    /// `Appearance.rawValue`.
    static let appearance = "shared.appearance"
    /// A code from `AppLanguage.supported`; absent to follow the device.
    static let language = "shared.language"
    /// `[String]`: provider ids the remote switches (or a missing key) keep the app from using,
    /// so the widget does not call them either. Absent until the app has mirrored them once.
    static let disabledProviders = "shared.disabledProviders"
}

/// The rider's history as the widget reads it and the app writes it.
nonisolated struct SharedHistoryStore: Sendable {
    /// What the shared suite holds under the history's key.
    enum Contents: Hashable, Sendable {
        /// Never written: the app has not moved its older copy here yet.
        case absent
        /// Written, but not in a form this build reads. Left alone rather than replaced.
        case unreadable
        case history([SavedSetup])
    }

    // `UserDefaults` is documented thread-safe, but not marked Sendable.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    func contents() -> Contents {
        guard let data = defaults.data(forKey: SharedKeys.history) else { return .absent }
        guard let setups = try? JSONDecoder().decode([SavedSetup].self, from: data) else { return .unreadable }
        return .history(setups)
    }

    /// The saved setups, or nil when there are none to read — which is not the same as a rider
    /// who removed every entry.
    func stored() -> [SavedSetup]? {
        guard case .history(let setups) = contents() else { return nil }
        return setups
    }

    func load() -> [SavedSetup] { stored() ?? [] }

    /// When the history was last saved; nil for one saved before this was kept.
    func savedAt() -> Date? { defaults.object(forKey: SharedKeys.historySavedAt) as? Date }

    func save(_ setups: [SavedSetup], at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(setups) else { return }
        defaults.set(data, forKey: SharedKeys.history)
        defaults.set(date, forKey: SharedKeys.historySavedAt)
    }

    func paletteAssignments() -> [String: Int] {
        defaults.dictionary(forKey: SharedKeys.palette) as? [String: Int] ?? [:]
    }

    func appearance() -> Appearance {
        defaults.string(forKey: SharedKeys.appearance).flatMap(Appearance.init) ?? .system
    }

    /// Nil until the app has mirrored the remote switches (`WidgetProviderGate.offUntilMirrored`).
    func disabledProviders() -> Set<String>? {
        (defaults.stringArray(forKey: SharedKeys.disabledProviders)).map(Set.init)
    }

    /// The phone's mirror of colours, appearance, language and switches, written together — as the
    /// watch receives them. A nil language (follow the device) or nil switches (not yet mirrored)
    /// remove their keys.
    func writeMirror(palette: [String: Int], appearance: Appearance, language: String?, disabledProviders: [String]?) {
        defaults.set(palette, forKey: SharedKeys.palette)
        defaults.set(appearance.rawValue, forKey: SharedKeys.appearance)
        defaults.set(language, forKey: SharedKeys.language)
        defaults.set(disabledProviders, forKey: SharedKeys.disabledProviders)
    }
}
