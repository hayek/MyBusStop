import Testing
import Foundation
@testable import BusBus

/// A stop served by more lines than the picker will take, so the cap has something to refuse.
private nonisolated struct CrowdedStopProvider: TransitProvider {
    let id = "crowded"
    let displayName = "Crowded"
    let capabilities: ProviderCapabilities = [.linesAtStop, .stopSearchByName]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var mock = MockTransitProvider()

    func searchStops(query: String) async throws -> [TransitStop] { try await mock.searchStops(query: query) }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        ["7", "18", "41", "63", "104"].map {
            TransitLine(id: $0, shortName: $0, destination: "DEPOT \($0)")
        }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern { try await mock.routePattern(for: line) }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

@Suite(.appLanguage("en"))
@MainActor
struct LineSelectionTests {

    private func crowdedModel() async -> SetupViewModel {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "setup-\(UUID().uuidString)")!)
        settings.providerOverride = CrowdedStopProvider()
        let model = SetupViewModel(settings: settings)
        let stop = try! await settings.provider.searchStops(query: MapFixtures.user).first!
        await model.choose(stop)
        return model
    }

    private func makeModel() async -> SetupViewModel {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "setup-\(UUID().uuidString)")!)
        settings.providerID = "mock"
        let model = SetupViewModel(settings: settings)
        let stop = try! await settings.provider.searchStops(query: MapFixtures.user).first!
        await model.choose(stop)
        return model
    }

    @Test func capsAtThree() async {
        let model = await crowdedModel()
        #expect(model.linesAtStop.count == 5)
        for line in model.linesAtStop { model.toggle(line) }
        #expect(model.selected.count == 3)
        #expect(model.isFull)
        // The three that got in are the first three tapped; the fourth tap did nothing at all.
        #expect(model.selected.map(\.id) == model.linesAtStop.prefix(3).map(\.id))
        #expect(model.isSelected(model.linesAtStop[3]) == false)
    }

    @Test func aSelectedLineCanBeSwappedForOneOutsideTheCap() async {
        let model = await crowdedModel()
        let lines = model.linesAtStop
        for line in lines.prefix(3) { model.toggle(line) }
        model.toggle(lines[0])
        model.toggle(lines[4])
        #expect(model.selected.map(\.id) == [lines[1].id, lines[2].id, lines[4].id])
        #expect(model.isFull)
    }

    @Test func linesOutsideTheCapAreMutedRatherThanErrored() async {
        let model = await crowdedModel()
        for line in model.linesAtStop.prefix(3) { model.toggle(line) }
        // The rule the chip's muted state is drawn from: full, and this line is not one of them.
        #expect(model.isFull && !model.isSelected(model.linesAtStop[3]))
        #expect(model.isSelected(model.linesAtStop[0]))
        #expect(model.footerHint == "TAP A SELECTED LINE TO SWAP IT OUT")
    }

    @Test func deselectingReopensASlot() async {
        let model = await makeModel()
        let lines = model.linesAtStop
        for line in lines.prefix(3) { model.toggle(line) }
        #expect(model.isFull)
        model.toggle(lines[0])
        #expect(model.selected.count == 2)
        #expect(model.isFull == false)
    }

    @Test func selectionOrderIsPreserved() async {
        let model = await makeModel()
        let lines = model.linesAtStop
        model.toggle(lines[2])
        model.toggle(lines[0])
        #expect(model.selected.map(\.id) == [lines[2].id, lines[0].id])
    }

    @Test func theHintNeverBecomesAnError() async {
        let model = await makeModel()
        #expect(model.footerHint == "ADD UP TO 3 MORE")
        for line in model.linesAtStop.prefix(3) { model.toggle(line) }
        #expect(model.footerHint == "TAP A SELECTED LINE TO SWAP IT OUT")
        #expect(model.footerCount == "3 OF 3 SELECTED")
    }

    @Test func showMapNeedsAtLeastOneLine() async {
        let model = await makeModel()
        #expect(model.canConfirm == false)
        model.toggle(model.linesAtStop[0])
        #expect(model.canConfirm)
    }

    @Test func clearEmptiesTheSelection() async {
        let model = await makeModel()
        for line in model.linesAtStop.prefix(2) { model.toggle(line) }
        model.clearSelection()
        #expect(model.selected.isEmpty)
    }

    @Test func confirmingWritesTheConfiguration() async {
        let model = await makeModel()
        model.toggle(model.linesAtStop[0])
        model.confirm()
        #expect(model.settings.configuration?.stop.code == MapFixtures.userCode)
        #expect(model.settings.configuration?.lines.count == 1)
        #expect(model.settings.savedSetups.first?.stop.code == MapFixtures.userCode)
    }

    /// The lines are already chosen, so there is nothing for step 2 to ask.
    @Test func resumingAnEntrySkipsStepTwo() async throws {
        let model = await makeModel()
        model.toggle(model.linesAtStop[0])
        model.toggle(model.linesAtStop[1])
        model.confirm()
        let saved = try #require(model.history.first)

        let fresh = SetupViewModel(settings: model.settings)
        fresh.use(saved)
        #expect(fresh.chosenStop == nil)
        #expect(fresh.settings.configuration?.stop.code == saved.stop.code)
        #expect(fresh.settings.configuration?.lines.map(\.id) == saved.lineIDs)
    }

    @Test func resumingAnEntryMovesItToTheTop() async throws {
        let model = await makeModel()
        model.toggle(model.linesAtStop[0])
        model.confirm()
        model.clearSelection()
        model.toggle(model.linesAtStop[1])
        model.confirm()
        #expect(model.history.count == 2)

        let older = try #require(model.history.last)
        model.use(older)
        #expect(model.history.first?.id == older.id)
        #expect(model.history.count == 2)
    }

    @Test func pinningKeepsAnEntryAtTheTopAndRemovingDropsIt() async throws {
        let model = await makeModel()
        model.toggle(model.linesAtStop[0])
        model.confirm()
        let first = try #require(model.history.first)
        model.clearSelection()
        model.toggle(model.linesAtStop[1])
        model.confirm()

        model.togglePin(first)
        #expect(model.history.first?.id == first.id)
        #expect(model.history.first?.pinned == true)

        model.remove(first)
        #expect(model.history.contains { $0.id == first.id } == false)
    }

    @Test func nearbyCaptionSaysWhyTheListIsEmpty() {
        #expect(SetupViewModel.caption(for: .locating) == "FINDING STOPS NEAR YOU…")
        // Location off is said by the card in the list, not repeated beside the header.
        #expect(SetupViewModel.caption(for: .denied) == "")
        #expect(SetupViewModel.caption(for: .restricted) == "")
        #expect(SetupViewModel.caption(for: .unavailable) == "NEARBY NOT AVAILABLE · SEARCH ABOVE")
        #expect(SetupViewModel.caption(for: .ready(count: 4, radiusMeters: 500)) == "4 STOPS WITHIN 500 M")
        #expect(SetupViewModel.caption(for: .ready(count: 6, radiusMeters: 1000)) == "6 STOPS WITHIN 1 KM")
    }

    /// EDIT belongs to one visit to the stop list: choosing a stop leaves the list, and coming back
    /// to it later shows the history ready to tap, not still being pruned.
    @Test func choosingAStopEndsEditingTheHistory() async {
        let model = await makeModel()
        model.isEditingHistory = true
        await model.choose(model.chosenStop!)
        #expect(model.isEditingHistory == false)
    }

    // MARK: Changing lines from the board

    @Test func editingTicksTheWatchedLinesAndKeepsTheCap() async throws {
        let setup = await crowdedModel()
        for line in setup.linesAtStop.prefix(2) { setup.toggle(line) }
        setup.confirm()
        let configuration = try #require(setup.settings.configuration)

        let editor = SetupViewModel(settings: setup.settings)
        await editor.edit(configuration.stop, watching: configuration.lines)
        #expect(editor.linesAtStop.count == 5)
        #expect(editor.selected.map(\.id) == configuration.lines.map(\.id))
        // One more fits; past three the grid stops answering, as in setup.
        editor.toggle(editor.linesAtStop[2])
        #expect(editor.isFull)
        editor.toggle(editor.linesAtStop[3])
        #expect(editor.selected.map(\.id) == editor.linesAtStop.prefix(3).map(\.id))
    }

    @Test func aWatchedLineTheStopNoLongerListsCanStillBeLetGo() async throws {
        let setup = await crowdedModel()
        let stop = try #require(setup.chosenStop)
        let gone = TransitLine(id: "999", shortName: "999", destination: "NOWHERE")

        let editor = SetupViewModel(settings: setup.settings)
        await editor.edit(stop, watching: [gone])
        #expect(editor.linesAtStop.map(\.id).contains("999"))
        #expect(editor.isSelected(gone))
        editor.toggle(gone)
        #expect(editor.selected.isEmpty)
    }

    /// The board's stop stays with the provider it was chosen from, wherever setup has browsed since.
    @Test func editedLinesAreSavedUnderTheBoardsProvider() async throws {
        let setup = await crowdedModel()
        let stop = try #require(setup.chosenStop)
        setup.settings.apply(stop: stop, lines: [setup.linesAtStop[0]], providerID: "board-provider")
        setup.settings.providerID = "elsewhere"

        let editor = SetupViewModel(settings: setup.settings)
        await editor.edit(stop, watching: setup.settings.configuration!.lines)
        editor.toggle(editor.linesAtStop[1])
        editor.confirm()
        #expect(editor.settings.configuration?.providerID == "board-provider")
        #expect(editor.settings.configuration?.lines.count == 2)
    }

    @Test func resumingAnEntryEndsEditingTheHistory() async {
        let model = await makeModel()
        model.toggle(model.linesAtStop[0])
        model.confirm()
        model.isEditingHistory = true
        model.use(model.history[0])
        #expect(model.isEditingHistory == false)
    }
}

@Suite(.appLanguage("en"))
struct DistanceFormatterTests {
    @Test func metresRoundToTheNearestTen() {
        #expect(DistanceFormatter.text(83) == "80 M")
        #expect(DistanceFormatter.text(0) == "0 M")
        #expect(DistanceFormatter.text(615) == "620 M")
    }

    @Test func aboveAKilometreItSwitchesUnits() {
        #expect(DistanceFormatter.text(1200) == "1.2 KM")
    }
}

struct WallModeTests {
    @Test func driftCyclesThroughEveryPosition() {
        let start = Date(timeIntervalSince1970: 0)
        let seen = (0..<8).map {
            WallModeController.driftOffset(at: start.addingTimeInterval(Double($0) * WallModeController.driftInterval))
        }
        #expect(Set(seen.map { "\($0.width),\($0.height)" }).count == 8)
        // It comes back round rather than wandering off the screen.
        #expect(WallModeController.driftOffset(at: start.addingTimeInterval(8 * WallModeController.driftInterval)) == seen[0])
        #expect(seen.allSatisfy { abs($0.width) <= 2 && abs($0.height) <= 2 })
    }

    @Test func nightHoursDimTheBoard() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_800_000_000)
        let night = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: midnight)!
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: midnight)!
        #expect(WallModeController.dimming(at: night, brightness: 1, calendar: calendar) == 0.3)
        #expect(WallModeController.dimming(at: noon, brightness: 1, calendar: calendar) == 0)
        // A dark room dims further, and by the same amount whatever the hour.
        #expect(WallModeController.dimming(at: noon, brightness: 0.1, calendar: calendar) == 0.45)
        #expect(WallModeController.dimming(at: night, brightness: 0.1, calendar: calendar) == 0.45)
        #expect(WallModeController.dimming(at: noon, brightness: nil, calendar: calendar) == 0)
    }
}
