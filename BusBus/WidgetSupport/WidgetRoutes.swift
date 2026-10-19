import Foundation

/// The routes a saved setup's lines take to the rider's stop, as the board's map draws them: every
/// stop from the terminus to the rider's own, by code and name. Written by the app when its board
/// has the patterns, so the larger widgets can draw the same map without asking for them.
///
/// Kept apart from the snapshots: a route changes with the timetable, not every refresh.
nonisolated struct WidgetRoutes: Codable, Hashable, Sendable {
    var setupID: String
    /// Per line id: terminus first … the rider's stop last.
    var lines: [String: [MapStopInput]]

    /// The board's trimmed patterns, less everything the map does not draw. Lines without a route
    /// that reaches the stop are left out.
    init(setupID: String, patterns: [String: RoutePattern]) {
        self.setupID = setupID
        lines = patterns.compactMapValues { pattern in
            pattern.stops.count >= 2 ? pattern.stops.map { MapStopInput(code: $0.stop.code, name: $0.stop.name) } : nil
        }
    }

    init(setupID: String, lines: [String: [MapStopInput]]) {
        self.setupID = setupID
        self.lines = lines
    }
}

/// Routes on disk in the App Group container, one small JSON file per saved setup. Not in Caches
/// like the snapshots: without them the widget has no map until the board is opened again.
nonisolated struct WidgetRouteStore: Sendable {
    /// Nil where the container is unavailable; every call is then a quiet no-op.
    var directory: URL?

    init(directory: URL? = AppGroup.containerURL?.appending(path: WidgetRouteStore.folder, directoryHint: .isDirectory)) {
        self.directory = directory
    }

    /// Apple TV keeps no Application Support, so the TV (which has no widget) caches them instead.
    #if os(tvOS)
    static let folder = "Library/Caches/WidgetRoutes"
    #else
    static let folder = "Library/Application Support/WidgetRoutes"
    #endif

    func load(setupID: String) -> WidgetRoutes? {
        guard let url = url(for: setupID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetRoutes.self, from: data)
    }

    /// Writes only what changed, so a board refreshing every twenty seconds does not rewrite the
    /// same routes each time. Returns whether it wrote.
    @discardableResult
    func save(_ routes: WidgetRoutes) -> Bool {
        guard let directory, let url = url(for: routes.setupID), load(setupID: routes.setupID) != routes,
              let data = try? JSONEncoder().encode(routes) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Deletes the routes of every setup not in `ids`, with the snapshots (`WidgetSnapshotStore`).
    func prune(keeping ids: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let kept = Set(ids.map(WidgetSnapshotStore.fileName(setupID:)))
        for file in files where file.pathExtension == "json" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func url(for setupID: String) -> URL? {
        directory?.appending(path: WidgetSnapshotStore.fileName(setupID: setupID), directoryHint: .notDirectory)
    }
}
