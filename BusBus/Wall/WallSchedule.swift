import Foundation

/// When a wall display shows the board.
///
/// A board on a wall has no reason to go dark, so the default is no schedule at all: with no
/// windows the board shows around the clock. Add windows and the board shows inside any of them,
/// and outside them it goes black — the app stays open and awake, and a tap brings the board back
/// for a moment. That is what a board in an office or a shop wants, rather than a panel lit all
/// weekend for nobody.
nonisolated struct WallSchedule: Codable, Sendable, Hashable {
    var windows: [WallWindow]

    static let alwaysOn = WallSchedule(windows: [])

    var isAlwaysOn: Bool { windows.isEmpty }

    func isOn(at date: Date, calendar: Calendar = .current) -> Bool {
        isAlwaysOn || windows.contains { $0.isOn(at: date, calendar: calendar) }
    }

    /// What the settings screen says under the list, so the rule is stated rather than implied.
    func summary() -> String {
        guard !isAlwaysOn else { return String(appLocalized: "The board shows all the time.") }
        return String(appLocalized: "Outside these times the screen goes black. Tap it to show the board for 20 seconds.")
    }

    /// The weekdays of the user's own week, in their own order: a Monday-first calendar lists
    /// Monday first.
    static func orderedWeekdays(calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// A date carrying only this time of day, for a `DatePicker` to edit.
    static func date(fromMinutes minutes: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    init(windows: [WallWindow]) {
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case windows, startMinutes, endMinutes, days }

    /// Reads the single window the schedule used to be, so a board set up before windows keeps its
    /// hours: its days became that one window, and no days was the same always-on as no windows.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let windows = try container.decodeIfPresent([WallWindow].self, forKey: .windows) {
            self.windows = windows
            return
        }
        let days = try container.decode(Set<Int>.self, forKey: .days)
        windows = days.isEmpty ? [] : [WallWindow(startMinutes: try container.decode(Int.self, forKey: .startMinutes),
                                                  endMinutes: try container.decode(Int.self, forKey: .endMinutes),
                                                  days: days)]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
    }
}

/// One stretch of the week the board shows: the chosen days, between two times.
nonisolated struct WallWindow: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    /// Minutes from midnight, so the pair survives a time-zone change intact: a board set to wake
    /// at seven wakes at seven wherever it is hung.
    var startMinutes: Int
    var endMinutes: Int
    /// `Calendar` weekday numbers — 1 is Sunday. Empty means the window never applies.
    var days: Set<Int>

    /// What the plus button adds: every day, the waking hours.
    static func new() -> WallWindow {
        WallWindow(startMinutes: 7 * 60, endMinutes: 23 * 60, days: Set(1...7))
    }

    /// Two equal times are not an empty window but a whole day: it is the state the pickers start
    /// in, and a rider who has chosen days and left the times alone means those days entire.
    var coversWholeDay: Bool { startMinutes == endMinutes }

    func isOn(at date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        if coversWholeDay { return days.contains(weekday) }

        let minutes = WallSchedule.minutes(from: date, calendar: calendar)
        if startMinutes < endMinutes {
            return days.contains(weekday) && minutes >= startMinutes && minutes < endMinutes
        }
        // The window runs past midnight, so the small hours belong to the day it began on: a board
        // set to 22:00–06:00 on Friday is still on at two on Saturday morning.
        if minutes >= startMinutes { return days.contains(weekday) }
        if minutes < endMinutes { return days.contains(weekday == 1 ? 7 : weekday - 1) }
        return false
    }

    func togglingDay(_ weekday: Int) -> WallWindow {
        var copy = self
        if copy.days.contains(weekday) { copy.days.remove(weekday) } else { copy.days.insert(weekday) }
        return copy
    }

    /// The days as the list row shows them: "Every day", or the chosen ones in the week's order.
    func daysSummary(calendar: Calendar = .current) -> String {
        if days.isEmpty { return String(appLocalized: "No days") }
        if days.count == 7 { return String(appLocalized: "Every day") }
        var named = calendar
        named.locale = AppLanguage.locale
        let symbols = named.shortWeekdaySymbols
        return WallSchedule.orderedWeekdays(calendar: calendar)
            .filter { days.contains($0) }
            .map { symbols[$0 - 1] }
            .formatted(.list(type: .and, width: .narrow).locale(AppLanguage.locale))
    }

    /// The hours as the list row shows them: "All day", or the two times.
    func timesSummary(calendar: Calendar = .current) -> String {
        if coversWholeDay { return String(appLocalized: "All day") }
        let format = Date.FormatStyle.dateTime.hour().minute().locale(AppLanguage.locale)
        let from = WallSchedule.date(fromMinutes: startMinutes, calendar: calendar).formatted(format)
        let until = WallSchedule.date(fromMinutes: endMinutes, calendar: calendar).formatted(format)
        return "\(from) – \(until)"
    }
}
