import Foundation

/// How current a widget's numbers are.
nonisolated enum WidgetLiveness: Hashable, Sendable {
    /// Fetched less than `WidgetSnapshot.freshFor` ago: the green dot.
    case live
    /// Older, still worth counting down from: a grey dot, and the time they were fetched.
    case stale(asOf: Date)
    /// Too old to show a number at all.
    case expired
}

/// The arithmetic behind a widget's timeline, kept apart from WidgetKit so it can be tested.
///
/// A widget is a series of pictures drawn ahead of time, not a live view: the countdown stays
/// honest by having a picture ready for every moment a number on it changes.
nonisolated enum WidgetTimelineMath {
    /// How long before it is due a bus reads NOW. A millisecond inside `BoardArrival.isImminent`'s
    /// strict 45 seconds, so the picture drawn at this moment already says NOW, and the one before
    /// it never has to.
    static let imminentLead: TimeInterval = 44.999

    /// The moments the widget must be redrawn at, from `now` on. The last one is where the
    /// timeline runs out, and is drawn as numbers no longer to be trusted.
    ///
    /// A figure rounded up (`BoardArrival.minutes(at:)`) changes each time a whole minute is left,
    /// so every arrival on screen contributes `expectedAt - k minutes` for each k, its NOW flip,
    /// and the moment it drops off. Only `arrivalsShown` are on screen at once: a later arrival's
    /// moments count from when the one that many places ahead of it drops off. Given when the
    /// numbers were fetched, so does the moment the dot stops being live.
    ///
    /// The series ends at the first of: the numbers becoming unusable, `horizon`, and the first
    /// moment `maxEntries` leaves out. WidgetKit keeps showing the last picture until it reloads,
    /// which it may put off for hours, so that last picture is never a number.
    static func entryDates(for arrivals: [WidgetArrival], fetchedAt: Date? = nil, now: Date,
                           horizon: TimeInterval = 30 * 60, maxEntries: Int = 120,
                           arrivalsShown: Int = 2) -> [Date] {
        var stop = now.addingTimeInterval(horizon)
        if let fetchedAt { stop = min(stop, fetchedAt.addingTimeInterval(WidgetSnapshot.usableFor)) }
        guard stop.timeIntervalSince(now) > 1 else { return [now] }

        var dates: [Date] = [now]
        if let fetchedAt { dates.append(fetchedAt.addingTimeInterval(WidgetSnapshot.freshFor)) }
        let sorted = arrivals.sorted { $0.expectedAt < $1.expectedAt }
        let shown = max(1, arrivalsShown)
        for (index, arrival) in sorted.enumerated() {
            let onScreenFrom = index < shown
                ? now : sorted[index - shown].expectedAt.addingTimeInterval(WidgetSnapshot.lingerAfterDue)
            guard onScreenFrom < stop else { break }
            let due = arrival.expectedAt
            var boundary = due
            while boundary > onScreenFrom {
                if boundary < stop { dates.append(boundary) }
                boundary = boundary.addingTimeInterval(-60)
            }
            dates.append(due.addingTimeInterval(-imminentLead))
            dates.append(due.addingTimeInterval(WidgetSnapshot.lingerAfterDue))
        }

        // Two redraws within a second of each other draw the same picture; so does one a second
        // short of the end.
        var result: [Date] = []
        for date in dates.filter({ $0 >= now && $0 < stop.addingTimeInterval(-1) }).sorted()
        where result.last.map({ date.timeIntervalSince($0) >= 1 }) ?? true {
            result.append(date)
        }
        // One place is kept for the end, so the cap can never cut it off.
        let room = max(1, maxEntries - 1)
        if result.count > room {
            stop = result[room]
            result = Array(result.prefix(room))
        }
        return result + [stop]
    }

    /// When WidgetKit should ask for a new timeline: shortly before the next bus, but never sooner
    /// than five minutes (the system rations reloads) nor later than fifteen.
    static func reloadDate(for arrivals: [WidgetArrival], now: Date) -> Date {
        let earliest = now.addingTimeInterval(5 * 60), latest = now.addingTimeInterval(15 * 60)
        guard let next = arrivals.map(\.expectedAt).filter({ $0 > now }).min() else { return latest }
        return min(max(next.addingTimeInterval(-2 * 60), earliest), latest)
    }

    static func liveness(fetchedAt: Date, now: Date) -> WidgetLiveness {
        let age = now.timeIntervalSince(fetchedAt)
        if age < WidgetSnapshot.freshFor { return .live }
        if age < WidgetSnapshot.usableFor { return .stale(asOf: fetchedAt) }
        return .expired
    }

    /// How much the Smart Stack should care right now: 100 when the next bus is within 15 minutes,
    /// climbing as it nears; 20 when there are numbers but the bus is further out; nil with none.
    /// `secondsToNext` is the next upcoming arrival's `expectedAt - now`, or nil.
    static func relevanceScore(secondsToNext: TimeInterval?) -> Float? {
        guard let secondsToNext else { return nil }
        let near: TimeInterval = 15 * 60
        guard secondsToNext < near else { return 20 }
        // 100 at the door, 60 fifteen minutes out.
        return Float(60 + 40 * (1 - max(0, secondsToNext) / near))
    }
}
