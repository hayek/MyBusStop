import SwiftUI

@main struct BusBusWatchApp: App {
    @State private var store: WatchStore
    @State private var receiver: WatchSyncReceiver

    init() {
        // Its own process and bundle: the phone's registration does not reach it.
        FontRegistrar.registerBundledFonts()
        // App Store screenshots: the staged history, in the App Group, before the store reads it.
        WatchScreenshotStage.current?.apply()
        let store = WatchStore()
        let receiver = WatchSyncReceiver(store: store)
        _store = State(initialValue: store)
        _receiver = State(initialValue: receiver)
        // At launch, not from a view: a launch in the background to deliver the phone's context
        // draws no view. The session's delegate is the receiver for the app's life.
        receiver.activate()
    }

    var body: some Scene {
        WindowGroup {
            // `WatchEnvironment` is applied inside, per screen (see `WatchRootView`).
            WatchRootView(store: store)
        }
        // The phone's context arriving while the app is not running: applied (and the complications
        // redrawn) now, not when the rider next opens the app.
        .backgroundTask(.watchConnectivity) { [receiver] in
            await receiver.receivePendingContent()
        }
    }
}
