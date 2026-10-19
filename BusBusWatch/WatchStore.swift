import Foundation
import Observation

/// What the watch knows from the phone, read from the App Group on demand and re-read whenever a
/// sync lands. Views read this; nothing on the watch writes the history.
@MainActor @Observable final class WatchStore {
    private(set) var history: [SavedSetup] = []
    private(set) var savedAt: Date?
    private(set) var palette: [String: Int] = [:]
    private(set) var appearance: Appearance = .system
    private(set) var language: String?

    init(history store: SharedHistoryStore = SharedHistoryStore()) { reload(from: store) }

    /// Reads the mirror again: after a sync, and whenever the app comes back to the front.
    func reload(from store: SharedHistoryStore = SharedHistoryStore()) {
        history = store.load()
        savedAt = store.savedAt()
        palette = store.paletteAssignments()
        appearance = store.appearance()
        language = store.defaults.string(forKey: SharedKeys.language)
    }

    func setup(id: String) -> SavedSetup? { history.first { $0.id == id } }
}
