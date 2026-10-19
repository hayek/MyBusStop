import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
#if os(tvOS)
import TVServices
#endif
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's side of the widget: hands it the board's numbers and tells WidgetKit when what the
/// widget shows has changed. On Apple TV the same numbers feed the Top Shelf, which is told
/// instead.
///
/// App only. The widget reads the shared suite and snapshot store directly and never needs this.
@MainActor enum WidgetBridge {
    /// How often a board refresh may also redraw the widgets. The board polls every 20–30 seconds;
    /// WidgetKit rations reloads, and a widget counts down on its own between them anyway.
    static let reloadInterval: TimeInterval = 3 * 60

    private static var lastReload: [String: Date] = [:]

    /// A history entry was added, pinned or removed: the widget's list and its choices change at
    /// once, and the numbers kept for stops no longer in it go.
    static func historyChanged(keeping ids: Set<String>) {
        guard isActive else { return }
        WidgetSnapshotStore().prune(keeping: ids)
        WidgetRouteStore().prune(keeping: ids)
        #if os(tvOS)
        TopShelfBoards.prune(keeping: ids)
        #endif
        reloadAll()
    }

    /// Colours, appearance or language changed: the widget should draw in them too.
    static func settingsChanged() {
        guard isActive else { return }
        reloadAll()
    }

    /// The board fetched fresh numbers. They are saved for the widget showing this stop, so it has
    /// them without a request of its own, with where each bus is for the large sizes' map, and the
    /// routes that map is drawn from when they are new. The widgets are redrawn when they last were a while
    /// ago — only while the app is in front, where WidgetKit does not count the reload against the
    /// widget's daily ration. A Mac window left open behind others keeps polling, and would spend it.
    static func boardDidRefresh(configuration: BoardConfiguration, snapshot: BoardSnapshot, settings: SettingsStore,
                                at now: Date) {
        guard isActive else { return }
        let setupID = SavedSetup.identifier(stop: configuration.stop, lineIDs: configuration.lines.map(\.id))
        let arrivals = snapshot.arrivals.map {
            WidgetArrival(lineID: $0.lineID, expectedAt: $0.expectedAt, isRealtime: $0.isRealtime,
                          stopsAway: $0.bus?.stopsAway, progressToNext: $0.bus?.progressToNext, busID: $0.bus?.id)
        }
        WidgetSnapshotStore().save(WidgetSnapshot(setupID: setupID, fetchedAt: now, arrivals: arrivals))
        // Written only when they differ from the last saved, which is next to never.
        let routes = WidgetRoutes(setupID: setupID, patterns: snapshot.patterns)
        let routesChanged = !routes.lines.isEmpty && WidgetRouteStore().save(routes)
        // The watch gets the same numbers, so a board just looked at shows on the wrist too.
        WatchSync.shared.boardDidRefresh(setupID: setupID, settings: settings, at: now)
        guard isInFront else { return }
        guard routesChanged || lastReload[setupID].map({ now.timeIntervalSince($0) >= reloadInterval }) ?? true else { return }
        lastReload[setupID] = now
        reloadAll()
    }

    /// Staged screenshots and tests are not a rider: they leave the widget, and the watch, alone.
    static var isActive: Bool {
        ScreenshotMode.current == nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    private static var isInFront: Bool {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

    /// Every widget of the app's, or on Apple TV the Top Shelf, which draws from the same numbers.
    private static func reloadAll() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #else
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus)
        #endif
    }
}
