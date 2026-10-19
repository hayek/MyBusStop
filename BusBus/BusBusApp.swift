import SwiftUI

@main struct BusBusApp: App {
    init() {
        FontRegistrar.registerBundledFonts()
        ServiceHealthMonitor.shared.startMonitoringConnectivity()
        // Earlier builds kept nearby lists on disk, named after where the rider stood.
        Task { await TransitCache.shared.purgeStoredNearby() }
        HTTPClient.purgeCachedLocationRepliesOnce()
        // Staged screenshots are not riders: they send nothing and follow no remote switch.
        guard ScreenshotMode.current == nil else {
            if AppClock.rate > 0 { ScreenshotMode.listenForClockStart() }
            return
        }
        Telemetry.start()
        Task { await RemoteFlags.shared.activate() }
        WatchSync.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if !os(tvOS)
        .commands {
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1280, height: ScreenshotMode.current == nil ? 720 : ScreenshotMode.macWindowSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// Opens settings from whatever the focused window is showing.
struct OpenSettingsAction {
    private let open: () -> Void
    init(_ open: @escaping () -> Void) { self.open = open }
    func callAsFunction() { open() }
}

extension FocusedValues {
    @Entry var openSettings: OpenSettingsAction?
}

#if !os(tvOS)
/// Settings… in the app menu, on ⌘, as every Mac app has it. Greyed out while nothing can show it.
private struct SettingsCommand: View {
    @FocusedValue(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") { openSettings?() }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(openSettings == nil)
    }
}
#endif
