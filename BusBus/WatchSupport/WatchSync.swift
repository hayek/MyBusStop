import Foundation
#if os(iOS)
import WatchConnectivity
import os

/// The iPhone's side of the watch: sends the history and what draws it whenever they change.
/// Application context only — latest state wins, delivered when the watch wakes.
///
/// iPhone only. The Mac build of the same target gets the stub below, so the call sites in
/// `SettingsStore` and `WidgetBridge` need no guard of their own.
@MainActor final class WatchSync: NSObject {
    static let shared = WatchSync()

    nonisolated private static let log = Logger(subsystem: "com.hayek.BusBus", category: "watch")

    /// Nil on the iPad, which has no watch.
    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    /// The app's store, from its first change on: what a push is built from when the session,
    /// rather than the store, is what changed.
    private weak var settings: SettingsStore?
    private var ledger = WatchPushLedger()
    private var loggedInstall = false

    /// Once at launch, after `Telemetry.start()`. A no-op on the iPad and everywhere WCSession is unsupported.
    static func activate() { shared.activateSession() }

    private func activateSession() {
        guard WidgetBridge.isActive, let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// The history, colours, appearance, language or switches changed (SettingsStore's didSets).
    func settingsChanged(_ settings: SettingsStore) {
        guard WidgetBridge.isActive else { return }
        self.settings = settings
        push(from: settings)
    }

    /// The board fetched numbers for `setupID` (WidgetBridge.boardDidRefresh); throttled per setup.
    func boardDidRefresh(setupID: String, settings: SettingsStore, at now: Date) {
        guard WidgetBridge.isActive else { return }
        self.settings = settings
        guard ledger.allowsSnapshotPush(setupID: setupID, now: now) else { return }
        push(from: settings, now: now, snapshotFor: setupID)
    }

    /// Builds and sends unless: not active (screenshots/tests, as WidgetBridge.isActive), no
    /// session, not activated, no watch app installed, or identical to the last payload sent.
    /// `setupID`: the board whose refresh asked, throttled from the moment the push goes out.
    private func push(from settings: SettingsStore, now: Date = .now, snapshotFor setupID: String? = nil) {
        guard WidgetBridge.isActive, let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        if !loggedInstall {
            loggedInstall = true
            Telemetry.log("watch_app_installed")
        }
        let snapshots = WidgetSnapshotStore()
        let payload = WatchSyncPayload.make(history: settings.savedSetups, palette: settings.paletteAssignments,
                                            appearance: settings.appearance, language: settings.language,
                                            disabledProviders: SharedHistoryStore().disabledProviders(),
                                            snapshot: { snapshots.load(setupID: $0) }, now: now)
        guard ledger.isNew(payload) else { return }
        do {
            try session.updateApplicationContext([WatchSyncPayload.contextKey: payload.encoded()])
            ledger.didPush(payload, snapshotFor: setupID, at: now)
            Telemetry.log("watch_sync_pushed", ["setups": payload.history.count])
            Self.log.info("Pushed \(payload.history.count) setups and \(payload.snapshots.count) snapshots to the watch")
        } catch {
            Self.log.error("Could not update the watch's application context: \(error.localizedDescription)")
        }
    }

    /// The session came up, or the watch app was installed or removed: send what there is now.
    private func sessionChanged() {
        guard let settings else { return }
        ledger.sessionChanged()
        push(from: settings)
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        if let error { Self.log.error("Watch session did not activate: \(error.localizedDescription)") }
        Task { @MainActor in self.sessionChanged() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The rider switched watches: the session must be activated again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sessionChanged() }
    }
}
#else
/// No watch off the iPhone: every call is a no-op, so the call sites stay unconditional.
@MainActor enum WatchSync {
    static func activate() {}
    static var shared: WatchSync.Type { self }
    static func settingsChanged(_ settings: SettingsStore) {}
    static func boardDidRefresh(setupID: String, settings: SettingsStore, at now: Date) {}
}
#endif
