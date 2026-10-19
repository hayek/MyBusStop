import SwiftUI
import Observation

/// Step 1 and step 2 of setup: which stop, then up to three lines.
@MainActor @Observable final class SetupViewModel {
    /// A name search that failed: the network, or the provider.
    nonisolated enum SearchFailure: Hashable, Sendable { case connection, service }

    /// What the confirm step knows of the lines at its stop. "None call here" and "could not ask"
    /// are told apart: the first is an answer, and leaves nothing to choose, while the second may
    /// well have lines that the line picker's own lookup will find.
    nonisolated enum ConfirmLines: Hashable, Sendable {
        case loading
        case lines([TransitLine])
        /// The provider answered, and no line calls here (bus.gov.il has stops like this).
        case noLines
        case failed(SearchFailure)
    }

    nonisolated enum NearbyState: Hashable, Sendable {
        case locating
        /// Location has not been asked for yet: the list waits for the rider to allow it.
        case needsPermission
        case ready(count: Int, radiusMeters: Double)
        /// The rider said no, and can say yes in Settings.
        case denied
        /// Location is off on this device by someone else's say — Screen Time, or management — so
        /// Settings would only show the rider a switch they cannot turn.
        case restricted
        case unavailable
        /// The rider is somewhere no supported region covers yet.
        case outsideCoverage
    }

    /// The cap is the whole point of the picker; a fourth line has nowhere to go on the map.
    static let maximumLines = 3
    static let nearRadius: Double = 500
    private static let widerRadius: Double = 1000

    let settings: SettingsStore
    let location: LocationService
    private let cache: TransitCache
    let health: ServiceHealthMonitor

    var query = "" {
        didSet {
            // The confirmed stop keeps its pin raised while typing goes on behind it.
            if !search.isConfirming { focusedStopID = nil }
            search.queryChanged(wasEmpty: oldValue.trimmingCharacters(in: .whitespaces).isEmpty,
                                isEmpty: query.trimmingCharacters(in: .whitespaces).isEmpty)
            scheduleSearch()
        }
    }
    private(set) var results: [TransitStop] = []
    private(set) var nearby: [NearbyStop] = []
    private(set) var nearbyState: NearbyState = .locating { didSet { logNearbyState() } }
    private(set) var isSearching = false
    /// Why the last name search came back with nothing, when it failed rather than found nothing.
    private(set) var searchFailure: SearchFailure?
    /// Every supported region at the rider's location, the one in use among them. More than one
    /// means the rider can switch (Hong Kong's operators overlap).
    private(set) var regionsHere: [SupportedRegion] = []

    /// Where the listed stops were looked up around: the rider, or a spot they moved the map to.
    private(set) var stopsCenter: GeoPoint?
    /// The listed stops are around a spot on the map rather than around the rider.
    private(set) var isAreaSearch = false
    private(set) var isLoadingStops = false
    private var areaRadius: Double = 500
    /// Bumped by every stop lookup, so a slow answer never lands on top of a newer one.
    private var stopsGeneration = 0

    /// The stop the confirm step is about: its pin is raised and ringed on the map, with every
    /// other pin faded round it.
    var focusedStopID: String?

    /// The full-screen map search: its drawer, and the confirm step.
    var search = StopSearchSession()
    /// The stop the confirm panel is about, held apart from the list so a refresh cannot swap it out.
    private(set) var confirmingStop: NearbyStop?
    /// The confirm step's lines, or nil when there is no confirm step.
    private(set) var confirmLinesState: ConfirmLines?
    /// Bumped by every stop chosen, so the lines of one chosen before — SELECT STOP, back, and
    /// another stop selected while the first one's lines were still on their way — never land on the
    /// line picker under the new stop's name, nor stop its shimmer.
    private var chooseGeneration = 0
    /// Bumped by every confirm step begun or ended, so lines that arrive for one already left — or
    /// for the same stop tapped again since — neither land in the panel nor stop its shimmer.
    private var confirmGeneration = 0

    var confirmLines: [TransitLine] {
        if case .lines(let lines) = confirmLinesState { lines } else { [] }
    }

    var isLoadingConfirmLines: Bool { confirmLinesState == .loading }

    /// SELECT STOP is offered unless the stop is known to have no lines: a lookup still on its way,
    /// or one that failed, leaves the line picker to try again.
    var canSelectConfirmingStop: Bool {
        confirmingStop != nil && confirmLinesState != .noLines
    }

    /// Said where the lines go when they could not be looked up, in the words a failed search uses.
    var confirmFailureCaption: String? {
        guard case .failed(let failure) = confirmLinesState else { return nil }
        return Self.searchFailureCaption(status: serviceStatus, failure: failure)
    }

    var chosenStop: TransitStop?
    private(set) var linesAtStop: [TransitLine] = []
    private(set) var isLoadingLines = false
    private(set) var selected: [TransitLine] = []
    private(set) var loadError: String?

    private var searchTask: Task<Void, Never>?
    /// What the last name search came to, kept until the search ends and is logged.
    private var searchOutcome: (outcome: String, results: Int)?
    /// The NEARBY state last logged, so a refresh that lands on the same state is not logged again.
    private var loggedNearbyState: String?
    /// Editing the board's lines rather than setting up: they come from, and are saved under, the
    /// provider the board's stop was chosen from, wherever setup has browsed since.
    private var editsBoard = false

    init(settings: SettingsStore, cache: TransitCache = .shared, health: ServiceHealthMonitor = .shared,
         location: LocationService? = nil) {
        self.settings = settings
        self.cache = cache
        self.health = health
        self.location = location ?? LocationService()
    }

    // MARK: Service health

    /// Whether the provider setup browses with is answering. Its searches, nearby lists and line
    /// lists count towards the same outage as the board's refreshes.
    var serviceStatus: ServiceStatus {
        let id = settings.provider.id
        return health.status(providerID: id, isAvailable: settings.providerIsAvailable(id))
    }

    /// Said under the list when the provider is down or switched off, so an empty list is never
    /// mistaken for there being no stops.
    var serviceNotice: String? {
        let name = currentRegion?.name ?? settings.provider.displayName
        switch serviceStatus {
        case .healthy, .offline: return nil
        case .down: return String(appLocalized: "LIVE DATA FOR \(name) IS DOWN · WE'RE WORKING ON A FIX")
        case .disabled: return String(appLocalized: "LIVE DATA FOR \(name) IS PAUSED FOR NOW")
        }
    }

    private func record<T>(_ endpoint: String, providerID: String, _ work: () async throws -> T) async throws -> T {
        do {
            let value = try await work()
            health.recordSuccess(providerID: providerID)
            return value
        } catch {
            health.recordFailure(providerID: providerID, endpoint: endpoint, error: error)
            throw error
        }
    }

    /// Pinned first, then most recently used.
    var history: [SavedSetup] { SavedSetups.sorted(settings.savedSetups) }
    var recentSearches: [String] { settings.recentSearches }
    var isEditingHistory = false
    var isShowingResults: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var canConfirm: Bool { !selected.isEmpty }

    func colorIndex(for line: TransitLine) -> Int {
        LineColorAssigner.provisionalIndex(for: line.id, persisted: settings.paletteAssignments)
    }

    // MARK: Step 1

    /// The region setup is browsing, when the rider's location or the chosen provider names one.
    var currentRegion: SupportedRegion? {
        regionsHere.first { $0.providerID == settings.providerID }
            ?? SupportedRegions.region(providerID: settings.providerID)
    }

    /// Says whose stops the screen lists. Outside every region nothing nearby is listed, but search
    /// still runs against the last region, so the caption says that instead.
    var regionCaption: String? {
        guard let region = currentRegion else {
            // Outside every region, the worldwide fallback's stops are listed instead.
            return settings.isUsingWorldwideFallback ? String(appLocalized: "STOPS FROM TRANSITOUS") : nil
        }
        return nearbyState == .outsideCoverage
            ? String(appLocalized: "SEARCH COVERS \(region.name)")
            : String(appLocalized: "STOPS IN \(region.name)")
    }

    /// The credit line the current provider's licence asks for, shown under the stop list.
    var attribution: String? { settings.provider.attribution }

    // MARK: Map

    /// A name search can match a whole country; the map pins the best of it, not all of it.
    static let mapResultLimit = 40

    /// What the map pins: the search results while searching, the nearby stops otherwise — the same
    /// stops the list names, in the same row type.
    var mapStops: [NearbyStop] {
        if isShowingResults {
            return results.prefix(Self.mapResultLimit).map { NearbyStop(stop: $0, distanceMeters: -1, lines: []) }
        }
        return nearby
    }

    /// Switches setup to another provider covering the same spot, and reloads what it lists.
    func switchRegion(to region: SupportedRegion) async {
        guard region.providerID != settings.providerID else { return }
        settings.providerID = region.providerID
        Telemetry.log("region_switched", ["provider_id": region.providerID])
        nearby = []
        if isShowingResults { scheduleSearch() }
        if isAreaSearch, let center = stopsCenter {
            await loadStops(around: center, radii: [areaRadius], isArea: true)
        } else {
            await loadNearby(force: true)
        }
    }

    /// The stops around the rider. An area the rider searched on the map is kept when the screen
    /// comes back, unless `force` asks for the rider's own surroundings again. The permission
    /// prompt only ever follows `askingPermission`, the rider's tap on CONTINUE. `relocate`
    /// looks for the rider again rather than trusting the fix from when the screen opened: they may
    /// have walked, or ridden, since.
    func loadNearby(force: Bool = false, askingPermission: Bool = false, relocate: Bool = false) async {
        if isAreaSearch, !force, !nearby.isEmpty { return }
        // A fix already under way answers for this call too. Without this, the search screen's load on
        // appear, arriving while the welcome story's request waits on the system alert, would find
        // the rider still unasked and put the permission card up behind the alert. A forced call
        // goes on, and waits for that same fix in `locateOnce` rather than giving up on it.
        if location.isLocating, !force { return }
        location.refreshStatus()
        if Self.waitsForPermission(hasFix: location.current != nil, needsPermission: location.needsPermission,
                                   askingPermission: askingPermission, isLocating: location.isLocating,
                                   staging: ScreenshotMode.current != nil) {
            nearbyState = .needsPermission
            return
        }
        if location.current == nil {
            nearbyState = .locating
            await location.locateOnce()
        } else if relocate {
            // The old fix stands if no new one comes, and the list stays up while it is looked for.
            await location.locateOnce()
        }
        guard let point = location.current else {
            nearbyState = location.isRestricted ? .restricted : location.isDenied ? .denied : .unavailable
            return
        }
        await loadStops(around: point, radii: [Self.nearRadius, Self.widerRadius], isArea: false)
    }

    /// Back in the foreground, or told the answer changed. A list left without the rider's
    /// location — not asked yet, refused, or given up on — tries again once the answer no longer
    /// matches what the list says (turned on in Settings, say), and one that could not find them
    /// tries again anyway. Nothing is asked of the rider from here.
    ///
    /// Measured against the list rather than against the answer before this call: Core Location's
    /// own word of the change can land first and update the answer, and the list would then never
    /// hear that anything had changed.
    func reloadNearbyIfLocationChanged() async {
        location.refreshStatus()
        guard !isAreaSearch, location.current == nil, !location.isLocating else { return }
        switch nearbyState {
        case .unavailable: await loadNearby()
        case .needsPermission, .denied, .restricted:
            if Self.stateWithoutLocation(location) != nearbyState { await loadNearby() }
        default: break
        }
    }

    /// The state the answer alone holds the list in, or nil when it lets the list look for the rider.
    private static func stateWithoutLocation(_ location: LocationService) -> NearbyState? {
        if location.isRestricted { return .restricted }
        if location.isDenied { return .denied }
        if location.needsPermission { return .needsPermission }
        return nil
    }

    /// Whether the list should stand waiting for the rider to allow location rather than look for
    /// them: never asked, no fix to go on, and this is not the rider's own tap asking — nor a
    /// request already waiting on the system's answer, nor a staged screenshot.
    nonisolated static func waitsForPermission(hasFix: Bool, needsPermission: Bool, askingPermission: Bool,
                                               isLocating: Bool, staging: Bool) -> Bool {
        !hasFix && needsPermission && !askingPermission && !isLocating && !staging
    }

    /// The stops around a spot on the map, for a rider looking somewhere other than where they are
    /// standing, or who has not shared where that is.
    func searchArea(around center: GeoPoint, spanMeters: Double) async {
        areaRadius = MapFraming.searchRadius(forSpan: spanMeters)
        await loadStops(around: center, radii: [areaRadius], isArea: true)
    }

    /// Radii are tried in turn while too few stops come back: widen the net rather than show a
    /// nearly empty list.
    private func loadStops(around point: GeoPoint, radii: [Double], isArea: Bool) async {
        stopsGeneration += 1
        let generation = stopsGeneration
        isLoadingStops = false
        stopsCenter = point
        isAreaSearch = isArea
        // The confirm panel's stop keeps its pin raised while a refresh lands behind it.
        if !search.isConfirming { focusedStopID = nil }
        // Where the stops are decides whose they are, unless the rider picked a provider.
        let before = settings.providerID
        let region = settings.adoptLocation(point)
        // A provider without its API key is not offered at all; one switched off remotely still is,
        // and says it is paused.
        regionsHere = SupportedRegions.regions(containing: point).filter { settings.providerHasKey($0.providerID) }
        if settings.providerID != before, isShowingResults { scheduleSearch() }
        if region == nil, settings.providerIsAutomatic, !settings.isUsingWorldwideFallback {
            nearby = []
            nearbyState = .outsideCoverage
            return
        }
        let provider = settings.provider
        guard settings.providerIsAvailable(provider.id) else {
            nearby = []
            nearbyState = .unavailable
            return
        }
        guard provider.capabilities.contains(.nearbyStops) else {
            nearby = []
            nearbyState = .unavailable
            return
        }
        isLoadingStops = true
        defer { if generation == stopsGeneration { isLoadingStops = false } }
        do {
            func stops(within radius: Double) async throws -> [NearbyStop] {
                try await record("stopsNearby", providerID: provider.id) {
                    try await cache.nearby(around: point, radiusMeters: radius,
                                           providerID: provider.datasetID) {
                        try await provider.stopsNearby(point, radiusMeters: radius)
                    }
                }
            }
            var radius = radii[0]
            var found = try await stops(within: radius)
            for wider in radii.dropFirst() where found.count < 4 {
                radius = wider
                found = try await stops(within: radius)
            }
            guard generation == stopsGeneration else { return }
            // An area's stops are measured from the rider, not from the middle of the map: the
            // distance on a row is always how far the rider would walk.
            if isArea {
                let origin = location.current ?? point
                found = found.map { entry in
                    var entry = entry
                    entry.distanceMeters = origin.distance(to: entry.stop.location)
                    return entry
                }
            }
            nearby = found
            nearbyState = .ready(count: found.count, radiusMeters: radius)
        } catch {
            guard generation == stopsGeneration else { return }
            nearbyState = .unavailable
            loadError = error.localizedDescription
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            results = []
            isSearching = false
            searchFailure = nil
            searchOutcome = nil
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            do {
                let provider = self.settings.provider
                let found = try await self.record("searchStops", providerID: provider.id) {
                    try await provider.searchStops(query: needle)
                }
                guard !Task.isCancelled else { return }
                self.results = found
                self.loadError = nil
                self.searchFailure = nil
                self.searchOutcome = (found.isEmpty ? "empty" : "found", found.count)
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.loadError = error.localizedDescription
                self.searchFailure = ServiceHealth.isConnectivityError(error) ? .connection : .service
                self.searchOutcome = (self.searchFailure == .connection ? "no_connection" : "failed", 0)
            }
            self.isSearching = false
        }
    }

    // MARK: Search

    /// Every opening starts fresh: whatever was typed, picked or half-confirmed last time is gone.
    /// A map the rider had moved to look elsewhere is put back on their own surroundings.
    func openSearch(focusingField: Bool = false) {
        logSearch(picked: false)
        query = ""
        endConfirm()
        search.open(focusingField: focusingField)
        if isAreaSearch { Task { await loadNearby(force: true) } }
    }

    /// Takes the screen away at once; the confirm step it may be showing is let go of once the
    /// screen has gone (`searchDismissed`), so the panel is not swapped for the list on its way out.
    func closeSearch() {
        search.close()
    }

    /// The search screen has finished going. Nothing to do if it has been opened again since:
    /// that opening started its own fresh confirm state.
    func searchDismissed() {
        guard !search.isPresented else { return }
        logSearch(picked: false)
        search.dismissed()
        endConfirm()
    }

    /// One event per name search the rider made: what it found, and whether they went on with a stop
    /// from it. Logged when it ends rather than per keystroke, so a name typed out is one search.
    private func logSearch(picked: Bool) {
        guard let searchOutcome else { return }
        self.searchOutcome = nil
        Telemetry.log("stop_search", ["outcome": searchOutcome.outcome, "results": searchOutcome.results,
                                      "picked": picked ? "yes" : "no", "provider_id": settings.providerID])
    }

    /// What the NEARBY list came to, once per change: how many riders get stops, turn location
    /// down, or open the app where no provider covers them. A map moved to look elsewhere is not
    /// the rider's surroundings, and is left out.
    private func logNearbyState() {
        guard !isAreaSearch, let name = Self.analyticsName(for: nearbyState), name != loggedNearbyState else { return }
        loggedNearbyState = name
        var params: [String: Any] = ["state": name, "provider_id": settings.providerID]
        if case .ready(let count, _) = nearbyState { params["stops"] = count }
        Telemetry.log("nearby_result", params)
    }

    /// Nil while still looking: only where the list ends up is worth counting.
    nonisolated static func analyticsName(for state: NearbyState) -> String? {
        switch state {
        case .locating: nil
        case .needsPermission: "needs_permission"
        case .ready(let count, _): count == 0 ? "no_stops" : "stops"
        case .denied: "denied"
        case .restricted: "restricted"
        case .unavailable: "unavailable"
        case .outsideCoverage: "outside_coverage"
        }
    }

    /// The rider tapped a stop to see it before choosing it. Its lines come from the row when the
    /// list knows them, and from the same lookup `choose` makes when it does not (a search result).
    func beginConfirm(_ entry: NearbyStop, restore: SearchRestore) async {
        confirmGeneration += 1
        let generation = confirmGeneration
        focusedStopID = entry.id
        confirmingStop = entry
        search.beginConfirm(restore)
        guard entry.lines.isEmpty else {
            confirmLinesState = .lines(entry.lines)
            logPreview("lines")
            return
        }
        confirmLinesState = .loading
        // Only this confirm step's own lookup may say what came of it: an earlier one finishing
        // late would otherwise stop the shimmer while this stop's lines are still on their way.
        do {
            let provider = settings.provider
            let found = try await record("lines", providerID: provider.id) {
                try await cache.lines(atStop: entry.stop, providerID: provider.datasetID) {
                    try await provider.lines(atStop: entry.stop)
                }
            }
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            // BACK, or another stop, may have come in while the lines were on their way.
            guard confirmGeneration == generation else { return }
            confirmLinesState = found.isEmpty ? .noLines : .lines(found)
            logPreview(found.isEmpty ? "no_lines" : "lines")
        } catch {
            guard confirmGeneration == generation else { return }
            // Kept in the state alone: `loadError` is the line picker's, and a late answer here
            // must not write over what its own lookup said.
            let connection = ServiceHealth.isConnectivityError(error)
            confirmLinesState = .failed(connection ? .connection : .service)
            logPreview(connection ? "no_connection" : "failed")
        }
    }

    /// A stop tapped to look at before choosing it, and whether its lines came: a stop that says
    /// no line stops there is a dead end worth counting.
    private func logPreview(_ outcome: String) {
        Telemetry.log("stop_previewed", ["outcome": outcome, "provider_id": settings.providerID])
    }

    /// SELECT STOP: the stop's lines, pushed inside the search screen over the confirm step, which
    /// stays as it is beneath them — the line picker's back button returns to it unchanged.
    func selectConfirmingStop() async {
        guard canSelectConfirmingStop, let stop = confirmingStop?.stop else { return }
        Telemetry.log("stop_selected", ["source": isShowingResults ? "search" : isAreaSearch ? "map" : "nearby",
                                        "provider_id": settings.providerID])
        if isShowingResults { logSearch(picked: true) }
        rememberSearchIfAny()
        search.isPickingLines = true
        await choose(stop)
    }

    /// The line picker's way back inside search: the confirm step beneath, as it was left.
    func backFromLines() {
        search.isPickingLines = false
    }

    func backFromConfirm() -> SearchRestore? {
        endConfirm()
        return search.back()
    }

    /// Lets go of the confirmed stop, and of any lookup still on its way for it.
    private func endConfirm() {
        confirmGeneration += 1
        confirmingStop = nil
        focusedStopID = nil
        confirmLinesState = nil
    }

    // MARK: Step 2

    /// Returns whether this stop is still the chosen one once its lines are in: another may have
    /// been chosen while they were on their way, and the lines that came are then let go of.
    @discardableResult
    func choose(_ stop: TransitStop) async -> Bool {
        // Leaving the home ends editing its stops: back there later, they are for tapping.
        isEditingHistory = false
        chooseGeneration += 1
        let generation = chooseGeneration
        chosenStop = stop
        selected = []
        linesAtStop = []
        isLoadingLines = true
        // Only this choice's own lookup may end the shimmer: a later stop's lines are still coming.
        defer { if chooseGeneration == generation { isLoadingLines = false } }
        let provider = editsBoard ? settings.boardProvider : settings.provider
        do {
            let found = try await record("lines", providerID: provider.id) {
                try await cache.lines(atStop: stop, providerID: provider.datasetID) {
                    try await provider.lines(atStop: stop)
                }
            }
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            guard chooseGeneration == generation else { return false }
            linesAtStop = found
            loadError = nil
            Telemetry.log("stop_lines", ["outcome": found.isEmpty ? "empty" : "found", "lines": found.count,
                                         "provider_id": provider.id])
        } catch {
            guard chooseGeneration == generation else { return false }
            loadError = error.localizedDescription
            Telemetry.log("stop_lines", ["outcome": ServiceHealth.isConnectivityError(error) ? "no_connection" : "failed",
                                         "lines": 0, "provider_id": provider.id])
        }
        return true
    }

    /// Step 2 again from the board: the stop's lines with the ones already watched ticked. A
    /// watched line the stop no longer lists is kept in the grid, so it can still be let go of.
    func edit(_ stop: TransitStop, watching lines: [TransitLine]) async {
        editsBoard = true
        guard await choose(stop) else { return }
        let listed = Set(linesAtStop.map(\.id))
        linesAtStop += lines.filter { !listed.contains($0.id) }
        selected = Array(lines.prefix(Self.maximumLines))
    }

    func isSelected(_ line: TransitLine) -> Bool { selected.contains { $0.id == line.id } }

    var isFull: Bool { selected.count >= Self.maximumLines }

    /// Tapping a selected line frees its slot; a fourth tap does nothing at all, which is why the
    /// rest of the grid is disabled rather than showing an error.
    func toggle(_ line: TransitLine) {
        if let index = selected.firstIndex(where: { $0.id == line.id }) {
            selected.remove(at: index)
        } else if !isFull {
            selected.append(line)
        }
    }

    func clearSelection() { selected = [] }

    var footerHint: String {
        if isFull { return String(appLocalized: "TAP A SELECTED LINE TO SWAP IT OUT") }
        let remaining = Self.maximumLines - selected.count
        return String(appLocalized: "ADD UP TO \(remaining) MORE")
    }

    var footerCount: String { String(appLocalized: "\(selected.count) OF \(Self.maximumLines) SELECTED") }

    func confirm() {
        guard let chosenStop, !selected.isEmpty else { return }
        let providerID = editsBoard ? settings.configuration?.providerID ?? settings.providerID : settings.providerID
        settings.apply(stop: chosenStop, lines: selected, providerID: providerID)
        Self.logBoardSetUp(source: editsBoard ? "edit" : "new", lines: selected.count, providerID: providerID)
    }

    /// Resuming an entry restores the stop and its lines at once. There is nothing left to
    /// choose, so it goes straight to the map rather than back through step 2. `source` says what
    /// resumed it, for analytics: My Stops, a widget, the nearby-stop banner, the TV's stop flip.
    func use(_ setup: SavedSetup, source: String = "history") {
        isEditingHistory = false
        let providerID = setup.providerID ?? settings.providerID
        settings.apply(stop: setup.stop, lines: setup.lines, providerID: providerID)
        Self.logBoardSetUp(source: source, lines: setup.lines.count, providerID: providerID)
    }

    /// A board put up, and how the rider got to it. The provider also becomes a user property, so
    /// every later event can be split by where the rider rides.
    private static func logBoardSetUp(source: String, lines: Int, providerID: String) {
        Telemetry.log("board_set_up", ["source": source, "lines": lines, "provider_id": providerID])
        Telemetry.setUserProperty(providerID, for: "provider")
    }

    func togglePin(_ setup: SavedSetup) { settings.togglePin(setup.id) }
    func remove(_ setup: SavedSetup) { settings.removeSetup(setup.id) }

    /// A stop reached by searching means that search was worth keeping.
    func rememberSearchIfAny() {
        guard isShowingResults else { return }
        settings.rememberSearch(query)
    }

    func search(for term: String) { query = term }

    /// The caption beside the NEARBY header carries the state; there is no button to press.
    var nearbyCaption: String {
        switch serviceStatus {
        case .healthy:
            if isAreaSearch, case .ready(let count, _) = nearbyState {
                String(appLocalized: "\(count) STOPS IN THIS AREA")
            } else {
                Self.caption(for: nearbyState)
            }
        case .down: String(appLocalized: "SERVICE DOWN")
        case .offline: String(appLocalized: "NO CONNECTION")
        case .disabled: String(appLocalized: "TEMPORARILY UNAVAILABLE")
        }
    }

    /// Said in place of the results when there are none because the search could not be made,
    /// so a failed search never reads as a name with no stop: nil when it was answered.
    var searchFailureCaption: String? {
        Self.searchFailureCaption(status: serviceStatus, failure: searchFailure)
    }

    /// The same words the NEARBY caption uses for an outage, a lost connection or a provider
    /// switched off. A single failure is not an outage yet, so it says what it was: the network
    /// gone, or the search not to be had just now.
    nonisolated static func searchFailureCaption(status: ServiceStatus, failure: SearchFailure?) -> String? {
        switch status {
        case .down: String(appLocalized: "SERVICE DOWN")
        case .offline: String(appLocalized: "NO CONNECTION")
        case .disabled: String(appLocalized: "TEMPORARILY UNAVAILABLE")
        case .healthy:
            switch failure {
            case .connection: String(appLocalized: "NO CONNECTION")
            case .service: String(appLocalized: "TEMPORARILY UNAVAILABLE")
            case nil: nil
            }
        }
    }

    /// The list never just sits there empty: every state says which one it is.
    nonisolated static func caption(for state: NearbyState) -> String {
        switch state {
        case .locating: String(appLocalized: "FINDING STOPS NEAR YOU…")
        // The NEARBY card says it all.
        case .needsPermission, .denied, .restricted: ""
        case .ready(let count, let radius):
            radius >= 1000 ? String(appLocalized: "\(count) STOPS WITHIN 1 KM")
                           : String(appLocalized: "\(count) STOPS WITHIN \(Int(radius)) M")
        case .unavailable: String(appLocalized: "NEARBY NOT AVAILABLE · SEARCH ABOVE")
        case .outsideCoverage: String(appLocalized: "NO LIVE BUSES HERE YET")
        }
    }
}

nonisolated enum DistanceFormatter {
    /// "80 M" up to a kilometre, then "1.2 KM".
    static func text(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(appLocalized: "\(meters / 1000, format: .number.precision(.fractionLength(1))) KM")
        }
        return String(appLocalized: "\(Int((meters / 10).rounded()) * 10) M")
    }

    static func accessibleText(_ meters: Double) -> String {
        meters >= 1000
            ? Measurement(value: meters / 1000, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .wide, numberFormatStyle: .number.precision(.fractionLength(1))).locale(AppLanguage.locale))
            : Measurement(value: meters.rounded(), unit: UnitLength.meters)
                .formatted(.measurement(width: .wide, usage: .asProvided).locale(AppLanguage.locale))
    }
}
