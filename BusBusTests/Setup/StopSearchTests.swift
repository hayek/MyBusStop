import Testing
import Foundation
@testable import BusBus

/// Holds each stop's lines back until the test lets them through, so a late answer can be made to
/// land after the rider has moved on.
private actor LineGate {
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<String> = []

    func wait(for code: String) async {
        guard !opened.contains(code) else { return }
        await withCheckedContinuation { waiting[code] = $0 }
    }

    func open(_ code: String) {
        opened.insert(code)
        waiting.removeValue(forKey: code)?.resume()
    }
}

private nonisolated struct GatedLinesProvider: TransitProvider {
    let id = "gated"
    let displayName = "Gated"
    let capabilities: ProviderCapabilities = [.linesAtStop, .stopSearchByName]
    let suggestedRefreshInterval: Duration = .seconds(20)
    let gate: LineGate

    func searchStops(query: String) async throws -> [TransitStop] { [] }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        await gate.wait(for: stop.code)
        return [TransitLine(id: "line-\(stop.code)", shortName: stop.code, destination: "DEPOT")]
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.notFound(line.id) }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

/// A name search that never gets through: the network is gone.
private nonisolated struct OfflineSearchProvider: TransitProvider {
    let id = "offline"
    let displayName = "Offline"
    let capabilities: ProviderCapabilities = [.linesAtStop, .stopSearchByName]
    let suggestedRefreshInterval: Duration = .seconds(20)

    func searchStops(query: String) async throws -> [TransitStop] { throw URLError(.notConnectedToInternet) }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { [] }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.notFound(line.id) }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

/// Lines that never come: the network is gone.
private nonisolated struct OfflineLinesProvider: TransitProvider {
    let id = "offline-lines"
    let displayName = "Offline lines"
    let capabilities: ProviderCapabilities = [.linesAtStop, .stopSearchByName]
    let suggestedRefreshInterval: Duration = .seconds(20)

    func searchStops(query: String) async throws -> [TransitStop] { [] }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { throw URLError(.notConnectedToInternet) }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.notFound(line.id) }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

@Suite(.appLanguage("en"))
@MainActor
struct StopSearchTests {

    private func makeModel() -> SetupViewModel {
        SetupViewModel(settings: SettingsStore(defaults: UserDefaults(suiteName: "search-\(UUID().uuidString)")!))
    }

    private func entry(_ code: String, lines: [TransitLine] = []) -> NearbyStop {
        NearbyStop(stop: TransitStop(code: code, name: "Dizengoff \(code)", city: "Tel Aviv",
                                     location: GeoPoint(lat: 32.08, lon: 34.78)),
                   distanceMeters: 90, lines: lines)
    }

    /// A model whose lines come from `provider`, through a cache and health of its own so no other
    /// test's answers leak in.
    private func makeModel(provider: some TransitProvider) -> SetupViewModel {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "search-\(UUID().uuidString)")!)
        settings.providerOverride = provider
        settings.regionIsAvailable = { _ in true }
        settings.providerHasKey = { _ in true }
        let cache = TransitCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)"))
        return SetupViewModel(settings: settings, cache: cache, health: ServiceHealthMonitor(reporter: .silent))
    }

    private let restore = SearchRestore(drawer: .small, scrolledToStopID: "B",
                                        camera: SavedCamera(center: GeoPoint(lat: 32.08, lon: 34.78), distance: 900))

    @Test func typingRaisesTheDrawerAndClearingLowersIt() {
        var session = StopSearchSession()
        #expect(session.drawer == .medium)
        session.queryChanged(wasEmpty: true, isEmpty: false)
        #expect(session.drawer == .large)
        session.queryChanged(wasEmpty: false, isEmpty: true)
        #expect(session.drawer == .medium)
    }

    /// The drawer pulled down mid-word stays down for the next letters, on the model as typed.
    @Test func onlyTheFirstLetterRaisesTheDrawer() {
        let model = makeModel()
        model.openSearch()
        model.query = "h"
        #expect(model.search.drawer == .large)
        model.search.drawer = .small
        model.query = "ha"
        model.query = "har"
        #expect(model.search.drawer == .small)
        model.query = ""
        #expect(model.search.drawer == .medium)
    }

    @Test func backRestoresWhatWasThere() {
        var session = StopSearchSession()
        session.drawer = .small
        session.beginConfirm(restore)
        #expect(session.isConfirming)
        #expect(session.back() == restore)
        #expect(session.drawer == .small)
        #expect(!session.isConfirming)
        #expect(session.back() == nil)
    }

    @Test func typingWhileConfirmingDoesNotMoveTheDrawer() {
        var session = StopSearchSession()
        session.drawer = .small
        session.beginConfirm(restore)
        session.queryChanged(wasEmpty: true, isEmpty: false)
        #expect(session.drawer == .small)
    }

    @Test func openingStartsFresh() {
        let model = makeModel()
        model.query = "dizen"
        model.search.drawer = .large
        model.openSearch()
        #expect(model.query == "")
        #expect(model.search.drawer == .medium)
        #expect(model.search.isPresented)
        #expect(!model.search.focusesFieldOnOpen)
        #expect(model.confirmingStop == nil)
        model.openSearch(focusingField: true)
        #expect(model.search.focusesFieldOnOpen)
    }

    /// The screen goes at once, and the confirm step with it once it has gone: until then the
    /// panel leaves as it was, rather than turning back into the list on the way down.
    @Test func closeEndsTheConfirmOnceDismissed() async {
        let model = makeModel()
        model.openSearch()
        await model.beginConfirm(entry("A", lines: [TransitLine(id: "7", shortName: "7", destination: "X")]), restore: restore)
        model.closeSearch()
        #expect(!model.search.isPresented)
        #expect(model.confirmingStop?.id == "A")
        #expect(model.search.isConfirming)
        model.searchDismissed()
        #expect(model.confirmingStop == nil)
        #expect(model.focusedStopID == nil)
        #expect(!model.search.isConfirming)
    }

    /// Opened again before the last one finished going, the new screen keeps what it started with.
    @Test func aLateDismissLeavesANewOpeningAlone() async {
        let model = makeModel()
        model.openSearch()
        model.closeSearch()
        model.openSearch()
        await model.beginConfirm(entry("B", lines: [TransitLine(id: "7", shortName: "7", destination: "X")]), restore: restore)
        model.searchDismissed()
        #expect(model.confirmingStop?.id == "B")
        #expect(model.search.isConfirming)
    }

    @Test func confirmSurvivesListRefresh() async {
        let model = makeModel()
        let lines = [TransitLine(id: "7", shortName: "7", destination: "X")]
        let entryA = entry("A", lines: lines)
        await model.beginConfirm(entryA, restore: restore)
        #expect(model.confirmLines == lines)
        #expect(model.focusedStopID == entryA.id)
        model.focusedStopID = nil
        #expect(model.confirmingStop?.id == entryA.id)
        #expect(model.backFromConfirm() == restore)
        #expect(model.confirmingStop == nil)
        #expect(model.confirmLines.isEmpty)
    }

    /// A failed search says why in place of the results; one that was answered says nothing.
    @Test func aFailedSearchSaysWhyRatherThanNoMatch() {
        typealias Model = SetupViewModel
        #expect(Model.searchFailureCaption(status: .healthy, failure: nil) == nil)
        #expect(Model.searchFailureCaption(status: .healthy, failure: .connection) == "NO CONNECTION")
        #expect(Model.searchFailureCaption(status: .healthy, failure: .service) == "TEMPORARILY UNAVAILABLE")
        #expect(Model.searchFailureCaption(status: .offline, failure: .connection) == "NO CONNECTION")
        #expect(Model.searchFailureCaption(status: .down(since: .now), failure: .service) == "SERVICE DOWN")
        #expect(Model.searchFailureCaption(status: .disabled, failure: nil) == "TEMPORARILY UNAVAILABLE")
    }

    @Test func anOfflineSearchIsNotANameWithNoStop() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "search-\(UUID().uuidString)")!)
        settings.providerOverride = OfflineSearchProvider()
        settings.regionIsAvailable = { _ in true }
        settings.providerHasKey = { _ in true }
        let model = SetupViewModel(settings: settings, health: ServiceHealthMonitor(reporter: .silent))
        model.query = "har"
        #expect(model.isSearching)
        while model.isSearching { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(model.results.isEmpty)
        #expect(model.searchFailureCaption == "NO CONNECTION")
        model.query = ""
        #expect(model.searchFailureCaption == nil)
    }

    @Test func walkCaptionIsNilWithoutDistance() {
        #expect(StopSearchSession.walkCaption(meters: -1) == nil)
        let near = StopSearchSession.walkCaption(meters: 90)
        #expect(near?.contains("90 M") == true)
        #expect(near?.contains("2 MIN WALK") == true)
        #expect(StopSearchSession.walkCaption(meters: 40)?.contains("1 MIN WALK") == true)
        let far = StopSearchSession.walkCaption(meters: 1200)
        #expect(far?.contains("1.2 KM") == true)
        #expect(far?.contains("15 MIN WALK") == true)
    }

    @Test func sidePanelRule() {
        #expect(StopSearchSession.usesSidePanel(CGSize(width: 1280, height: 800)))
        #expect(StopSearchSession.usesSidePanel(CGSize(width: 844, height: 390)))
        #expect(!StopSearchSession.usesSidePanel(CGSize(width: 390, height: 844)))
        #expect(!StopSearchSession.usesSidePanel(CGSize(width: 560, height: 500)))
    }

    @Test func drawerHeightsStackAndSnapToTheNearest() {
        // An iPhone's map area under the header, to the bottom edge.
        let heights = DrawerHeights(areaHeight: 760, screenHeight: 852)
        #expect(heights.small == 120)
        #expect(abs(heights.medium - 852 * 0.45) < 0.5)
        #expect(heights.large == 610)
        #expect(heights.nearest(to: 130) == .small)
        #expect(heights.nearest(to: 400) == .medium)
        // A flick up from medium carries past the middle and lands at large.
        #expect(heights.nearest(to: 560) == .large)
        // A window too short for all three never lets small or medium outgrow large.
        let short = DrawerHeights(areaHeight: 200, screenHeight: 300)
        #expect(short.small <= short.medium && short.medium <= short.large)
    }

    @Test func confirmDistanceFallsBackToTheRidersFix() {
        let listed = entry("A")
        let rider = GeoPoint(lat: 32.081, lon: 34.78)
        // A listed row's own figure stands when the rider has a fix…
        #expect(StopSearchSession.distance(to: listed, from: rider) == 90)
        // …but not without one: an area search with location off measured it from the map's middle.
        #expect(StopSearchSession.distance(to: listed, from: nil) == -1)
        var result = listed
        result.distanceMeters = -1
        // A search result carries no distance: measured from the rider when there is a fix…
        let measured = StopSearchSession.distance(to: result, from: rider)
        #expect(abs(measured - 111) < 2)
        // …and unknown without one, which the caption turns into silence rather than "-1 M".
        #expect(StopSearchSession.distance(to: result, from: nil) == -1)
        #expect(StopSearchSession.walkCaption(meters: StopSearchSession.distance(to: result, from: nil)) == nil)
    }

    @Test func onlyASignsCodeIsShown() {
        #expect(StopSearchSession.signCode("41122") == "41122")
        #expect(StopSearchSession.signCode("N12") == "N12")
        #expect(StopSearchSession.signCode("NSR:Quay:7203") == nil)
        #expect(StopSearchSession.signCode("490008660N") == nil)
        #expect(StopSearchSession.signCode("ABCD") == nil)
        #expect(StopSearchSession.signCode("") == nil)
    }

    /// Tap A (lines still loading), BACK, tap B: A's answer arriving late must neither land in B's
    /// panel nor stop B's shimmer.
    @Test func aLateAnswerLeavesTheNextStopLoading() async {
        let gate = LineGate()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "search-\(UUID().uuidString)")!)
        settings.providerOverride = GatedLinesProvider(gate: gate)
        let cache = TransitCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)"))
        let model = SetupViewModel(settings: settings, cache: cache)

        let first = Task { await model.beginConfirm(entry("111"), restore: restore) }
        while !model.isLoadingConfirmLines { await Task.yield() }
        _ = model.backFromConfirm()
        #expect(!model.isLoadingConfirmLines)

        let second = Task { await model.beginConfirm(entry("222"), restore: restore) }
        while model.confirmingStop?.id != "222" { await Task.yield() }
        #expect(model.isLoadingConfirmLines)

        await gate.open("111")
        await first.value
        #expect(model.isLoadingConfirmLines, "the first stop's answer does not end the second's wait")
        #expect(model.confirmLines.isEmpty)

        await gate.open("222")
        await second.value
        #expect(!model.isLoadingConfirmLines)
        #expect(model.confirmLines.map(\.shortName) == ["222"])
    }

    // MARK: The confirm step's lines

    /// A nearby row knows its lines: they are shown at once, and the stop can be chosen.
    @Test func aRowsOwnLinesAreShownAtOnce() async {
        let model = makeModel()
        let lines = [TransitLine(id: "7", shortName: "7", destination: "X")]
        await model.beginConfirm(entry("A", lines: lines), restore: restore)
        #expect(model.confirmLinesState == .lines(lines))
        #expect(model.canSelectConfirmingStop)
        #expect(model.confirmFailureCaption == nil)
    }

    /// While a search result's lines are on their way the panel shimmers, and SELECT STOP stands:
    /// the line picker would only wait on the same lookup.
    @Test func loadingLinesStillLetTheStopBeChosen() async {
        let gate = LineGate()
        let model = makeModel(provider: GatedLinesProvider(gate: gate))
        let task = Task { await model.beginConfirm(entry("333"), restore: restore) }
        while model.confirmingStop == nil { await Task.yield() }
        #expect(model.confirmLinesState == .loading)
        #expect(model.isLoadingConfirmLines)
        #expect(model.canSelectConfirmingStop)
        await gate.open("333")
        await task.value
        #expect(model.confirmLinesState == .lines([TransitLine(id: "line-333", shortName: "333", destination: "DEPOT")]))
    }

    /// The provider answered with no lines (bus.gov.il's stop 41489): there is nothing to choose,
    /// so SELECT STOP is off, and pressing it anyway does nothing.
    @Test func aStopWithNoLinesCannotBeChosen() async {
        let model = makeModel(provider: OfflineSearchProvider())
        model.openSearch()
        await model.beginConfirm(entry("41489"), restore: restore)
        #expect(model.confirmLinesState == .noLines)
        #expect(!model.isLoadingConfirmLines)
        #expect(model.confirmLines.isEmpty)
        #expect(!model.canSelectConfirmingStop)
        #expect(model.confirmFailureCaption == nil)
        await model.selectConfirmingStop()
        #expect(!model.search.isPickingLines)
        #expect(model.chosenStop == nil)
    }

    /// No answer is not "no lines": the panel says why, and the line picker may still try again.
    @Test func linesThatCouldNotBeLookedUpSayWhyAndStillLetTheStopBeChosen() async {
        let model = makeModel(provider: OfflineLinesProvider())
        model.openSearch()
        await model.beginConfirm(entry("555"), restore: restore)
        #expect(model.confirmLinesState == .failed(.connection))
        #expect(model.confirmFailureCaption == "NO CONNECTION")
        #expect(model.canSelectConfirmingStop)
        _ = model.backFromConfirm()
        #expect(model.confirmLinesState == nil)
        #expect(model.confirmFailureCaption == nil)
    }

    // MARK: Lines inside search

    /// SELECT STOP pushes the lines inside search, and the confirm step stays beneath them as it
    /// was, for the back button to come back to. The search that found the stop is remembered.
    @Test func selectingPushesTheLinesOverTheConfirmStep() async {
        let model = makeModel(provider: OfflineSearchProvider())
        model.openSearch()
        model.query = "dizen"
        let lines = [TransitLine(id: "7", shortName: "7", destination: "X")]
        let chosen = entry("A", lines: lines)
        await model.beginConfirm(chosen, restore: restore)
        await model.selectConfirmingStop()
        #expect(model.search.isPickingLines)
        #expect(model.chosenStop == chosen.stop)
        #expect(model.recentSearches.first == "dizen")
        // The line picker's back button: the confirm step, untouched.
        model.backFromLines()
        #expect(!model.search.isPickingLines)
        #expect(model.confirmingStop?.id == "A")
        #expect(model.search.isConfirming)
        #expect(model.confirmLinesState == .lines(lines))
        #expect(model.focusedStopID == "A")
    }

    /// The lines go with the screen, and the next opening starts on the search, not on them.
    @Test func closingOrReopeningLeavesTheLines() async {
        let model = makeModel(provider: OfflineSearchProvider())
        model.openSearch()
        await model.beginConfirm(entry("A", lines: [TransitLine(id: "7", shortName: "7", destination: "X")]),
                                 restore: restore)
        await model.selectConfirmingStop()
        model.closeSearch()
        // Still pushed while the screen goes down, so it leaves as it was.
        #expect(model.search.isPickingLines)
        model.searchDismissed()
        #expect(!model.search.isPickingLines)
        #expect(!model.search.isConfirming)

        var session = StopSearchSession()
        session.isPickingLines = true
        session.open(focusingField: false)
        #expect(!session.isPickingLines)
    }

    /// SELECT STOP on A while its lines are slow, back, back, and SELECT STOP on B: A's lines
    /// arriving late must neither land in B's picker nor end B's shimmer, so SHOW THE MAP can never
    /// save B with A's lines.
    @Test func aLateChoiceLeavesTheNextStopsLinesAlone() async {
        let gate = LineGate()
        let model = makeModel(provider: GatedLinesProvider(gate: gate))
        let first = entry("111"), second = entry("222")

        let choosingFirst = Task { await model.choose(first.stop) }
        while !model.isLoadingLines { await Task.yield() }
        let choosingSecond = Task { await model.choose(second.stop) }
        while model.chosenStop != second.stop { await Task.yield() }

        await gate.open("111")
        let firstIsCurrent = await choosingFirst.value
        #expect(!firstIsCurrent)
        #expect(model.chosenStop == second.stop)
        #expect(model.linesAtStop.isEmpty, "the first stop's lines landed under the second's name")
        #expect(model.isLoadingLines, "the first stop's answer ended the second's wait")

        await gate.open("222")
        let secondIsCurrent = await choosingSecond.value
        #expect(secondIsCurrent)
        #expect(!model.isLoadingLines)
        #expect(model.linesAtStop.map(\.shortName) == ["222"])
    }

    /// The portrait confirm panel may grow past the drawer's resting height for a long list of
    /// lines, but always leaves at least the tallest drawer's band of map above it.
    @Test func theConfirmPanelIsCappedBelowTheMapsBand() {
        let phone = DrawerHeights(areaHeight: 760, screenHeight: 852)
        let cap = StopSearchSession.confirmPanelMaxHeight(phone)
        #expect(cap >= phone.medium)
        #expect(cap <= phone.large)
        #expect(abs(cap - 456) < 0.5)
        let short = DrawerHeights(areaHeight: 300, screenHeight: 380)
        #expect(StopSearchSession.confirmPanelMaxHeight(short) <= short.large)
    }
}
