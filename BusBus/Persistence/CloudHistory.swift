import Foundation
import os

/// Where `CloudHistory` keeps its copy. iCloud's key-value store in the app; a dictionary in tests.
@MainActor protocol CloudDataStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudDataStore {
    func set(_ data: Data?, forKey key: String) { set(data as Any?, forKey: key) }
}

/// Keeps the saved stops the same on the rider's iPhone, iPad, Mac and Apple TV, through iCloud's
/// key-value store — a few kilobytes, well under its limits, and no account screens.
///
/// Every change goes through `SettingsStore.savedSetups`, so a stop that arrives from another
/// device reaches this device's widget, watch and Top Shelf the way a local one does. With iCloud
/// off the store simply stays local, and so does the history.
@MainActor final class CloudHistory {
    static let shared = CloudHistory(store: NSUbiquitousKeyValueStore.default)
    static let key = "history.v1"

    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "cloud")

    private let store: any CloudDataStore
    /// Every window's store: a Mac or an iPad window each keeps its own `SettingsStore`, and a
    /// change in one has to reach iCloud and the others alike. Held weakly, so a closed window's
    /// store simply drops out.
    private var stores: [WeakStore] = []
    private var observer: (any NSObjectProtocol)?

    private struct WeakStore { weak var settings: SettingsStore? }

    init(store: any CloudDataStore) {
        self.store = store
    }

    /// Once per window, for the rider's own store: takes in what the other devices saved, and from
    /// then on sends every change here and takes every change there.
    func attach(_ settings: SettingsStore) {
        stores.removeAll { $0.settings == nil }
        guard !stores.contains(where: { $0.settings === settings }) else { return }
        stores.append(WeakStore(settings: settings))
        settings.historyDidChange = { [weak self, weak settings] in
            guard let settings else { return }
            self?.push(from: settings)
        }
        if observer == nil, let store = store as? NSUbiquitousKeyValueStore {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
            ) { [weak self] note in
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                MainActor.assumeIsolated {
                    Self.log.info("iCloud history changed elsewhere (reason \(reason ?? -1))")
                    self?.pull()
                }
            }
        }
        store.synchronize()
        sync(from: settings, now: Date())
    }

    /// Merges the cloud's copy in, and sends the result back when this device had something the
    /// cloud did not.
    func pull(now: Date = Date()) {
        guard let first = stores.lazy.compactMap(\.settings).first else { return }
        sync(from: first, now: now)
    }

    /// A change made in `settings`: merged with the cloud's copy first, so a change another device
    /// made in the meantime is not overwritten, then handed to every window. Adopting the merge
    /// calls back into here; by then it changes nothing, and nothing is written.
    func push(from settings: SettingsStore, now: Date = Date()) { sync(from: settings, now: now) }

    private func sync(from source: SettingsStore, now: Date) {
        let remote: SyncedHistory?
        switch remoteContents() {
        case .unreadable:
            // A newer build's format: left alone rather than replaced with what this one knows.
            return
        case .absent: remote = nil
        case .history(let history): remote = history
        }
        let merged = HistorySync.merge(local: source.syncedHistory, remote: remote ?? SyncedHistory(), now: now)
        // Nothing here and nothing there yet — a new device before iCloud's first download — is
        // not worth a write that could race the download.
        let isEmpty = merged.entries.isEmpty && merged.tombstones.isEmpty
        if merged != remote, !(remote == nil && isEmpty) { write(merged) }
        for settings in stores.compactMap(\.settings) { settings.adopt(merged) }
    }

    private enum Contents { case absent, unreadable, history(SyncedHistory) }

    private func remoteContents() -> Contents {
        guard let data = store.data(forKey: Self.key) else { return .absent }
        do {
            return .history(try JSONDecoder().decode(SyncedHistory.self, from: data))
        } catch {
            Self.log.error("iCloud history unreadable: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
    }

    private func write(_ history: SyncedHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        store.set(data, forKey: Self.key)
    }
}
