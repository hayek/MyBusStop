import Foundation

/// What set a refresh off. Carried in every build; only a debug build writes it anywhere.
nonisolated enum RefreshTrigger: String, Codable, Sendable {
    case poll
    case pull
    case foreground
    case stopChanged
    case networkBack
    /// A tap brought a wall display's black screen back to the board.
    case wake

    var label: String {
        switch self {
        case .poll: "POLL"
        case .pull: "PULL"
        case .foreground: "FOREGROUND"
        case .stopChanged: "STOP CHANGED"
        case .networkBack: "NETWORK BACK"
        case .wake: "WAKE"
        }
    }
}

#if DEBUG

/// One refresh of the board, as the debug screen lists it: what asked for it, and what each line's
/// feed said against what the board went on to show.
nonisolated struct RefreshLogEntry: Codable, Identifiable, Hashable, Sendable {
    enum Outcome: Codable, Hashable, Sendable {
        case updated
        /// Every line failed; the board kept what it had.
        case failed
        /// Nothing was asked: the provider is switched off.
        case skipped(String)
        /// A refresh was already under way, and this one waited for its answer instead.
        case joined
    }

    struct Line: Codable, Hashable, Sendable {
        var name: String
        /// Upcoming times the feed returned, before the board matched them to buses.
        var fromFeed: Int?
        /// Times the board shows for the line once the refresh was applied.
        var shown: Int?
        var buses: Int?
        var next: Date?
        var error: String?
    }

    var id = UUID()
    var at: Date
    var trigger: RefreshTrigger
    var stop: String
    var provider: String
    var outcome: Outcome
    var seconds: Double?
    var lines: [Line] = []
}

/// The board's refreshes, newest first, for the debug screen under Settings. A debug build only:
/// in any other the type does not exist, so nothing can be written.
///
/// Kept on disk, so a board that went wrong this morning can still be read after the app was
/// closed; capped, so it never grows past a few hundred entries.
@MainActor @Observable final class RefreshLog {
    /// The unit tests run inside the app: theirs is kept in memory, out of the rider's log.
    static let shared = RefreshLog(file: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                                   ? RefreshLog.defaultFile : nil)
    static let limit = 500

    private(set) var entries: [RefreshLogEntry] = []
    @ObservationIgnored private let file: URL?

    /// - Parameter file: where the log is kept. Nil keeps it in memory, as the tests do.
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([RefreshLogEntry].self, from: data) {
            entries = stored
        }
    }

    func record(_ entry: RefreshLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// The log as plain text, to share from the debug screen.
    var text: String {
        entries.map(Self.describe).joined(separator: "\n\n")
    }

    static func describe(_ entry: RefreshLogEntry) -> String {
        var lines = ["\(entry.at.formatted(Self.stamp)) \(entry.trigger.label) · \(summary(entry)) · \(entry.stop) · \(entry.provider)"]
        lines += entry.lines.map { "  " + describe($0) }
        return lines.joined(separator: "\n")
    }

    static func summary(_ entry: RefreshLogEntry) -> String {
        let outcome = switch entry.outcome {
        case .updated: "updated"
        case .failed: "failed"
        case .skipped(let why): "skipped: \(why)"
        case .joined: "joined the refresh already running"
        }
        guard let seconds = entry.seconds else { return outcome }
        return outcome + String(format: " in %.1fs", seconds)
    }

    static func describe(_ line: RefreshLogEntry.Line) -> String {
        var parts = [line.name]
        if let fromFeed = line.fromFeed { parts.append("feed \(fromFeed)") }
        if let shown = line.shown { parts.append("shown \(shown)") }
        if let buses = line.buses { parts.append("buses \(buses)") }
        if let next = line.next { parts.append("next \(next.formatted(Self.clock))") }
        if let error = line.error { parts.append("error: \(error)") }
        return parts.joined(separator: " · ")
    }

    static let stamp = Date.FormatStyle().month(.twoDigits).day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
    static let clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    private static var defaultFile: URL? {
        // Caches rather than Application Support: Apple TV keeps nothing else.
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BusBus/refresh-log.json")
    }

    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

#endif
