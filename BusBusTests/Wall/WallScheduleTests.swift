import Testing
import Foundation
@testable import BusBus

/// The schedule decides when a wall display shows the board and when it goes black, so every case
/// here is one the rider would notice: a board dark at breakfast, or a panel lit all weekend.
struct WallScheduleTests {

    /// Fixed so a run in another zone, or on another day, measures the same thing.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    /// 2026-09-14 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func weekday(_ date: Date) -> Int { calendar.component(.weekday, from: date) }

    @Test func noWindowsMeansAlwaysOn() {
        let schedule = WallSchedule.alwaysOn
        #expect(schedule.isAlwaysOn)
        #expect(schedule.isOn(at: date(14, 3), calendar: calendar))
        #expect(schedule.isOn(at: date(19, 23, 59), calendar: calendar))
    }

    @Test func aWeekdayWindowIsOffAtTheWeekend() {
        // Monday to Friday, 07:00–19:00.
        let workdays = Set([2, 3, 4, 5, 6])
        let schedule = WallSchedule(windows: [WallWindow(startMinutes: 7 * 60, endMinutes: 19 * 60, days: workdays)])
        #expect(schedule.isAlwaysOn == false)
        #expect(schedule.isOn(at: date(14, 9), calendar: calendar))        // Monday morning
        #expect(schedule.isOn(at: date(18, 18, 59), calendar: calendar))   // Friday, a minute to go
        #expect(schedule.isOn(at: date(14, 6, 59), calendar: calendar) == false)
        #expect(schedule.isOn(at: date(14, 19), calendar: calendar) == false)   // the end is exclusive
        #expect(schedule.isOn(at: date(19, 12), calendar: calendar) == false)   // Saturday noon
    }

    @Test func aWindowPastMidnightBelongsToTheDayItBeganOn() {
        // Friday only, 22:00–06:00.
        let friday = weekday(date(18, 12))
        let schedule = WallSchedule(windows: [WallWindow(startMinutes: 22 * 60, endMinutes: 6 * 60, days: [friday])])
        #expect(schedule.isOn(at: date(18, 23), calendar: calendar))        // Friday night
        #expect(schedule.isOn(at: date(19, 2), calendar: calendar))         // still Friday's window
        #expect(schedule.isOn(at: date(19, 6), calendar: calendar) == false)    // Saturday morning, over
        #expect(schedule.isOn(at: date(18, 21, 59), calendar: calendar) == false)
        // Saturday night is not Friday's, and Saturday was never chosen.
        #expect(schedule.isOn(at: date(19, 23), calendar: calendar) == false)
    }

    @Test func aWindowPastMidnightAtTheStartOfTheWeekLooksBackToSunday() {
        let sunday = weekday(date(13, 12))
        #expect(sunday == 1)
        let schedule = WallSchedule(windows: [WallWindow(startMinutes: 23 * 60, endMinutes: 60, days: [sunday])])
        #expect(schedule.isOn(at: date(13, 23, 30), calendar: calendar))
        #expect(schedule.isOn(at: date(14, 0, 30), calendar: calendar))     // Monday 00:30, Sunday's window
        #expect(schedule.isOn(at: date(14, 1), calendar: calendar) == false)
    }

    @Test func daysWithoutTimesMeanThoseDaysEntire() {
        let monday = weekday(date(14, 12))
        let schedule = WallSchedule(windows: [WallWindow(startMinutes: 9 * 60, endMinutes: 9 * 60, days: [monday])])
        #expect(schedule.isOn(at: date(14, 0, 1), calendar: calendar))
        #expect(schedule.isOn(at: date(14, 23, 59), calendar: calendar))
        #expect(schedule.isOn(at: date(15, 12), calendar: calendar) == false)
    }

    @Test func togglingADayAddsThenRemovesIt() {
        let window = WallWindow(startMinutes: 0, endMinutes: 0, days: [])
        let withMonday = window.togglingDay(2)
        #expect(withMonday.days == [2])
        #expect(withMonday.togglingDay(2).days.isEmpty)
    }

    @Test func aWindowWithNoDaysNeverShowsTheBoard() {
        let schedule = WallSchedule(windows: [WallWindow(startMinutes: 7 * 60, endMinutes: 19 * 60, days: [])])
        #expect(schedule.isAlwaysOn == false)
        #expect(schedule.isOn(at: date(14, 9), calendar: calendar) == false)
    }

    @Test func theBoardShowsInsideAnyOfSeveralWindows() {
        // Weekday mornings and evenings, and Saturday all day.
        let workdays = Set([2, 3, 4, 5, 6])
        let schedule = WallSchedule(windows: [
            WallWindow(startMinutes: 7 * 60, endMinutes: 9 * 60, days: workdays),
            WallWindow(startMinutes: 17 * 60, endMinutes: 20 * 60, days: workdays),
            WallWindow(startMinutes: 0, endMinutes: 0, days: [7]),
        ])
        #expect(schedule.isOn(at: date(14, 8), calendar: calendar))            // Monday morning
        #expect(schedule.isOn(at: date(14, 12), calendar: calendar) == false)  // Monday midday, between them
        #expect(schedule.isOn(at: date(14, 18), calendar: calendar))           // Monday evening
        #expect(schedule.isOn(at: date(19, 12), calendar: calendar))           // Saturday
        #expect(schedule.isOn(at: date(20, 8), calendar: calendar) == false)   // Sunday morning
    }

    @Test func aScheduleSavedAsOneWindowReadsBackAsThatWindow() throws {
        let old = #"{"startMinutes":420,"endMinutes":1140,"days":[2,3]}"#
        let schedule = try JSONDecoder().decode(WallSchedule.self, from: Data(old.utf8))
        #expect(schedule.windows.count == 1)
        #expect(schedule.windows.first?.startMinutes == 420)
        #expect(schedule.windows.first?.endMinutes == 1140)
        #expect(schedule.windows.first?.days == [2, 3])
    }

    @Test func aScheduleSavedWithNoDaysReadsBackAlwaysOn() throws {
        let old = #"{"startMinutes":420,"endMinutes":1380,"days":[]}"#
        let schedule = try JSONDecoder().decode(WallSchedule.self, from: Data(old.utf8))
        #expect(schedule.isAlwaysOn)
    }

    @Test func aNewWindowCoversEveryDay() {
        #expect(WallWindow.new().days == Set(1...7))
    }

    @Test func theWeekStartsWhereTheCalendarSaysItDoes() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        #expect(WallSchedule.orderedWeekdays(calendar: sundayFirst) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WallSchedule.orderedWeekdays(calendar: mondayFirst) == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func minutesSurviveTheRoundTripThroughADate() {
        for minutes in [0, 7 * 60, 13 * 60 + 45, 23 * 60 + 59] {
            let carried = WallSchedule.date(fromMinutes: minutes, calendar: calendar)
            #expect(WallSchedule.minutes(from: carried, calendar: calendar) == minutes)
        }
    }

    @Test(.appLanguage("en")) func theSummaryStatesTheRuleRatherThanImplyingIt() {
        #expect(WallSchedule.alwaysOn.summary().contains("all the time"))
        let window = WallWindow(startMinutes: 7 * 60, endMinutes: 19 * 60, days: [2])
        #expect(WallSchedule(windows: [window]).summary().contains("Tap"))
        #expect(WallWindow(startMinutes: 0, endMinutes: 0, days: [2]).timesSummary(calendar: calendar) == "All day")
        #expect(WallWindow.new().daysSummary(calendar: calendar) == "Every day")
        #expect(WallWindow(startMinutes: 0, endMinutes: 0, days: []).daysSummary(calendar: calendar) == "No days")
    }
}

/// The store is what the board actually asks, and it has to answer for both halves of the rule.
@MainActor struct WallScheduleStoreTests {

    private func store() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "wall.schedule.\(UUID().uuidString)")!
        return SettingsStore(defaults: defaults)
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    @Test func aBoardOutOfWallModeIsNeverShownBySchedule() {
        let settings = store()
        settings.wallMode = false
        #expect(settings.wallDisplayIsAwake(at: date(14, 9), calendar: calendar) == false)
    }

    @Test func wallModeWithoutAScheduleShowsTheBoardAtAnyHour() {
        let settings = store()
        settings.wallMode = true
        #expect(settings.wallDisplayIsAwake(at: date(14, 3), calendar: calendar))
    }

    @Test func aScheduleDarkensTheBoardOutOfHours() {
        let settings = store()
        settings.wallMode = true
        settings.wallSchedule = WallSchedule(windows: [WallWindow(startMinutes: 7 * 60, endMinutes: 19 * 60,
                                                                  days: [2, 3, 4, 5, 6])])
        #expect(settings.wallDisplayIsAwake(at: date(14, 9), calendar: calendar))
        #expect(settings.wallDisplayIsAwake(at: date(14, 22), calendar: calendar) == false)
        #expect(settings.wallDisplayIsAwake(at: date(19, 9), calendar: calendar) == false)
    }

    @Test func theScheduleSurvivesARelaunch() {
        let suite = "wall.schedule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = SettingsStore(defaults: defaults)
        let windows = [WallWindow(startMinutes: 6 * 60 + 30, endMinutes: 9 * 60, days: [2, 4]),
                       WallWindow(startMinutes: 18 * 60, endMinutes: 21 * 60, days: [7])]
        first.wallSchedule = WallSchedule(windows: windows)
        let second = SettingsStore(defaults: defaults)
        #expect(second.wallSchedule.windows == windows)
    }
}
