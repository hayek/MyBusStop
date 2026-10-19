import Foundation
import WatchConnectivity
import WidgetKit
import os

/// Receives the phone's payload and writes it into the watch's App Group (`WatchSyncApply`), then
/// tells the store and WidgetKit.
@MainActor final class WatchSyncReceiver: NSObject {
    nonisolated private static let log = Logger(subsystem: "com.hayek.BusBus", category: "watch")
    private let store: WatchStore
    private let applier: WatchSyncApply

    init(store: WatchStore, apply: WatchSyncApply = WatchSyncApply()) {
        self.store = store
        self.applier = apply
    }

    /// False under XCTest, where the host app must not talk to a real session, and while staging
    /// screenshots, whose history a synced one must not replace (the phone's `WidgetBridge.isActive` rule).
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && !AppClock.isStaging
    }

    /// Once, at launch (the app's `init`, so a background launch gets it too); whatever context is
    /// already there is applied once it is up.
    func activate() {
        guard Self.isActive, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// The system woke the app to deliver what the phone sent (`.backgroundTask(.watchConnectivity)`):
    /// waits for the session to be up and to have handed over everything pending, then applies the
    /// latest context, so the store and the complications are current before the app is suspended.
    /// A context the delegate already applied comes back as no newer than stored and is skipped.
    func receivePendingContent() async {
        guard Self.isActive, WCSession.isSupported() else { return }
        activate()
        let session = WCSession.default
        // The task's time is short; ten seconds is far more than a delivery takes.
        let deadline = ContinuousClock.now + .seconds(10)
        while session.activationState != .activated || session.hasContentPending, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let data = session.receivedApplicationContext[WatchSyncPayload.contextKey] as? Data,
              let payload = WatchSyncPayload.decode(data),
              store.savedAt.map({ payload.sentAt > $0 }) ?? true else { return }
        apply(data: data)
    }

    /// Decode + apply + notify. Exposed for tests (a dictionary shaped like a context).
    @discardableResult func apply(context: [String: Any]) -> WatchSyncApply.Outcome {
        apply(data: context[WatchSyncPayload.contextKey] as? Data)
    }

    @discardableResult private func apply(data: Data?) -> WatchSyncApply.Outcome {
        guard let data else {
            Self.log.error("An application context without a payload")
            return .unreadable
        }
        let outcome = applier.apply(contextData: data)
        switch outcome {
        case .applied:
            store.reload(from: SharedHistoryStore(defaults: applier.defaults))
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus)
            // The faces' complication gallery lists the history (`recommendations()`).
            WidgetCenter.shared.invalidateConfigurationRecommendations()
        case .olderThanStored:
            Self.log.info("Ignored a payload older than the history already stored")
        case .unreadable:
            Self.log.error("Could not read the phone's payload")
        }
        return outcome
    }
}

extension WatchSyncReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: (any Error)?) {
        if let error { Self.log.error("Watch session did not activate: \(error.localizedDescription)") }
        // The last context the phone sent before this launch, kept by the system.
        guard let data = session.receivedApplicationContext[WatchSyncPayload.contextKey] as? Data else { return }
        Task { @MainActor in self.apply(data: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let data = context[WatchSyncPayload.contextKey] as? Data
        Task { @MainActor in self.apply(data: data) }
    }
}
