import Foundation

/// One arrival as the widget keeps it: enough to count down to, nothing it cannot draw.
nonisolated struct WidgetArrival: Codable, Hashable, Sendable {
    var lineID: String
    var expectedAt: Date
    var isRealtime: Bool
    /// Where the board last saw this arrival's bus: this many stops short of the rider's, and this
    /// far (0…1) on towards the next one. Nil when the numbers came without positions, as the
    /// widget's own fetch does.
    var stopsAway: Int?
    var progressToNext: Double?
    /// The board's id for the bus, so the map draws each one once.
    var busID: String?

    /// The board's own arrival, so the widget rounds, flips to NOW and reads hours exactly as the
    /// board does (`BoardArrival.minutes(at:)`, `Countdown`).
    var board: BoardArrival {
        BoardArrival(id: "\(lineID)@\(expectedAt.timeIntervalSinceReferenceDate)", lineID: lineID,
                     expectedAt: expectedAt, isRealtime: isRealtime, delay: nil, bus: nil)
    }
}

/// The last arrivals known for one saved setup: written by the app whenever its board refreshes,
/// and by the widget when it fetches for itself. Lets a widget count down for half an hour from
/// any one fetch, and lets the app's numbers reach the widget without a second request.
nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {
    var setupID: String
    var fetchedAt: Date
    /// Soonest first.
    var arrivals: [WidgetArrival]

    /// Past this the numbers still stand, but the widget stops claiming they are live.
    static let freshFor: TimeInterval = 10 * 60
    /// Past this a countdown is a guess: the widget shows no numbers at all.
    static let usableFor: TimeInterval = 30 * 60
    /// A bus that is due stays up this long, as NOW, before it drops off: buses run a little late
    /// far more often than early.
    static let lingerAfterDue: TimeInterval = 30

    /// The arrivals still to come at `now`, soonest first.
    func upcoming(at now: Date) -> [WidgetArrival] {
        arrivals.filter { $0.expectedAt > now.addingTimeInterval(-Self.lingerAfterDue) }
            .sorted { $0.expectedAt < $1.expectedAt }
    }
}

/// Snapshots on disk in the App Group container, one small JSON file per saved setup.
nonisolated struct WidgetSnapshotStore: Sendable {
    /// Nil where the container is unavailable; every call is then a quiet no-op.
    var directory: URL?

    init(directory: URL? = AppGroup.containerURL?.appending(path: "Library/Caches/WidgetSnapshots", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func load(setupID: String) -> WidgetSnapshot? {
        guard let url = url(for: setupID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save(_ snapshot: WidgetSnapshot) {
        guard let directory, let url = url(for: snapshot.setupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes the snapshots of every setup not in `ids`: stops removed from the history, whose
    /// numbers no widget will show again.
    func prune(keeping ids: Set<String>) {
        let kept = Set(ids.map(Self.fileName(setupID:)))
        for file in files() where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func files() -> [URL] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
    }

    /// A setup id is a stop code and line ids joined by "|", and any of them may hold a "/" or a
    /// ":" — so everything but letters, digits, "-" and "_" is percent-encoded.
    static func fileName(setupID: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return (setupID.addingPercentEncoding(withAllowedCharacters: allowed) ?? setupID) + ".json"
    }

    private func url(for setupID: String) -> URL? {
        directory?.appending(path: Self.fileName(setupID: setupID), directoryHint: .notDirectory)
    }
}
