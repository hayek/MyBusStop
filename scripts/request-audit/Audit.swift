import Foundation

/// Counts the requests each phase of a rider's journey costs, per provider:
/// setup (search + lines at the stop), the board's pattern for up to four lines, and — with SHAPES —
/// opening each line's card, re-opening it, a day-later pattern refresh, plus one board poll.
enum Audit {
    static let linesPerStop = 4

    static func run(_ f: LiveFixture) async -> [String: Any] {
        let p = f.provider
        var result: [String: Any] = ["provider": p.id]
        func phase(_ name: String) { _ = RequestCounter.take(); RequestCounter.phase = name }
        func count() -> Int { RequestCounter.take().count }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            phase("setup")
            let results = try await p.searchStops(query: f.stopQuery)
            let stop = f.stopCode.flatMap { c in results.first { $0.code == c } } ?? results[0]
            var lines = try await p.lines(atStop: stop)
            if let preferred = f.lineShortName, let i = lines.firstIndex(where: { $0.shortName == preferred }) {
                lines.insert(lines.remove(at: i), at: 0)
            }
            result["setup"] = count()
            let chosen = Array(lines.prefix(linesPerStop))
            result["lines"] = chosen.map(\.shortName)

            let cache = TransitCache(directory: dir)
            var board: [Int] = [], card: [Int] = [], reopen: [Int] = [], verdicts: [String] = []
            for line in chosen {
                phase("board")
                #if SHAPES
                let pattern = try await cache.pattern(for: line, provider: p)
                #else
                let pattern = try await cache.pattern(for: line, providerID: p.datasetID) { try await p.routePattern(for: line) }
                #endif
                board.append(count())
                #if SHAPES
                phase("card")
                _ = try? await cache.pattern(for: line, provider: p)
                do {
                    let s = try await cache.shape(for: pattern, provider: p)
                    verdicts.append(s.verdict.passes ? "pass" : "rejected: \(s.verdict.reason ?? "?")")
                } catch {
                    verdicts.append("error: \(error)")
                }
                card.append(count())
                phase("reopen")
                _ = try? await cache.pattern(for: line, provider: p)
                _ = try? await cache.shape(for: pattern, provider: p)
                reopen.append(count())
                #endif
            }
            result["board"] = board
            #if SHAPES
            result["card"] = card
            result["reopen"] = reopen
            result["verdicts"] = verdicts

            // A day later: the pattern has expired, the shape has not.
            if let line = chosen.first {
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("pattern_") { try? FileManager.default.removeItem(at: file) }
                let later = TransitCache(directory: dir)
                phase("refresh")
                let pattern = try await later.pattern(for: line, provider: p)
                result["refreshPattern"] = count()
                phase("refreshShape")
                _ = try? await later.shape(for: pattern, provider: p)
                result["refreshShape"] = count()
            }
            #endif

            if let line = chosen.first {
                phase("poll")
                if p.capabilities.contains(.vehiclePositions) { _ = try? await p.vehicles(for: line) }
                if !p.capabilities.isDisjoint(with: [.realtimeArrivals, .scheduledArrivals]) { _ = try? await p.arrivals(for: line, at: stop) }
                result["poll"] = count()
            }
        } catch {
            result["error"] = "\(error)".prefix(160).description
            _ = RequestCounter.take()
        }
        return result
    }
}
