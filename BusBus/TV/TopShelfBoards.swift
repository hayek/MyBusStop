import Foundation

/// Pictures of each stop's board, drawn by the Apple TV app whenever its board refreshes, for the
/// Top Shelf's full-screen carousel. The extension cannot draw the board itself (it has no live
/// model, and no time to fetch routes and positions), so it shows the app's picture while it is
/// recent and its own summary once it is not.
nonisolated enum TopShelfBoards {
    /// 1920 × 1080: a carousel slide fills the screen.
    static let size = CGSize(width: 1920, height: 1080)
    /// Older than this, a board's buses have moved on too far to show.
    static let freshFor: TimeInterval = 10 * 60

    static var directory: URL? {
        AppGroup.containerURL?.appending(path: "Library/Caches/TopShelfBoards", directoryHint: .isDirectory)
    }

    static func url(for setupID: String) -> URL? {
        let name = WidgetSnapshotStore.fileName(setupID: setupID).dropLast(".json".count)
        return directory?.appending(path: "\(name).png", directoryHint: .notDirectory)
    }

    /// The picture of this stop's board, when one was drawn in the last `freshFor`.
    static func freshPicture(for setupID: String, now: Date) -> URL? {
        guard let url = url(for: setupID),
              let drawnAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(drawnAt) < freshFor else { return nil }
        return url
    }

    /// Deletes the pictures of stops no longer saved.
    static func prune(keeping ids: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let kept = Set(ids.compactMap { url(for: $0)?.lastPathComponent })
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
