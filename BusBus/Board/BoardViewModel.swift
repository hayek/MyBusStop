import Foundation
import Observation
import Network
import CoreGraphics
import os

/// Owns the board's data: polls the provider, turns what comes back into arrivals and buses the
/// views can draw, picks the trunk, and remembers the last good answer so the board never blanks.
///
/// It knows the `TransitProvider` protocol and the domain model, never which feed is behind it.
@MainActor @Observable final class BoardViewModel {
    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "board")
    /// Without a successful fetch for this long the LIVE indicator admits it is stale.
    static let staleAfter: TimeInterval = 90
    /// How soon to ask again when a line came back with its bus but without its minutes.
    static let quickRetrySeconds: Double = 5
    /// Quick retries in a row before an empty timetable is believed and the normal pace resumes.
    private static let maxQuickRetries = 3

    let settings: SettingsStore
    private let cache: TransitCache
    /// Shared with setup, so a feed that fails on both sides is one outage, reported once.
    let health: ServiceHealthMonitor

    private(set) var snapshot = BoardSnapshot.empty
    private(set) var lastSuccessAt: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var trunkLineID: String?

    var selectedBusID: String?
    private(set) var hasTappedOnce = false
    /// The board's Settings sheet. Kept here rather than in the view so a widget link that opens
    /// another stop's board can put it away (`RootView.openWidgetLink`).
    var showsSettings = false
    /// The sheet of every line at the stop, from the button beside its name (`BoardLinesSheet`).
    var showsLinePicker = false
    /// The full route view, every stop of every watched line (`FullRouteView`).
    var showsFullRoute = false
    /// The stop whose card is open, from a tap on its name or mark on the map (`StopCardView`).
    var inspectedStop: StopCardRequest?
    /// The line whose card is open, from the ⓘ on a tapped bus or a badge in the full route
    /// (`LineCardView`).
    var inspectedLine: LineCardRequest?
    /// The one tip on the first board after the welcome story (`SetupTipView`). For this session
    /// only: that it has been shown is kept in `SettingsStore.onboarding`.
    var showsSetupTip = false

    private var trunk = TrunkSelector()
    private var pollTask: Task<Void, Never>?
    /// A refresh already under way. A second caller joins it rather than starting a race whose
    /// loser can land last and overwrite newer numbers.
    private var inFlight: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var wasOffline = false
    private var consecutiveFailures = 0
    /// Refreshes in a row that drew a bus but not its minutes.
    private var incompleteRefreshes = 0
    /// Board and outcome pairs already logged this launch: each board says once that it came up,
    /// and once that it failed, not on every poll.
    private var loggedBoards: Set<String> = []
    /// Bus id → the stop index we last saw it at, and when we watched it move there. The time is
    /// nil until we have actually seen the move: no feed tells us when a bus passed a stop, so
    /// "LEFT OLD MILL 1 MIN AGO" may only ever come from our own observation.
    private var stopChangeTimes: [String: (index: Int, changedAt: Date?)] = [:]
    #if DEBUG
    /// Where every refresh is written down for the debug screen. Tests hand in one of their own.
    @ObservationIgnored var refreshLog = RefreshLog.shared
    #endif

    init(settings: SettingsStore, cache: TransitCache = .shared, health: ServiceHealthMonitor = .shared) {
        self.settings = settings
        self.cache = cache
        self.health = health
        resolvePalette()
    }

    /// Fixes a distinct colour for every watched line and remembers it. Setup normally does this,
    /// but a configuration can also arrive from disk (or from an older build) without assignments,
    /// and two lines sharing a colour would make the map unreadable.
    func resolvePalette() {
        let selected = lines.map(\.id)
        guard !selected.isEmpty else { return }
        let resolved = LineColorAssigner.resolve(
            persisted: settings.paletteAssignments, selected: selected,
            preferred: lines.reduce(into: [:]) { $0[$1.id] = $1.brandColorIndex })
        if resolved != settings.paletteAssignments { settings.paletteAssignments = resolved }
    }

    // MARK: Configuration

    var configuration: BoardConfiguration? { settings.configuration }
    var stop: TransitStop? { configuration?.stop }
    var lines: [TransitLine] { configuration?.lines ?? [] }

    func line(_ id: String) -> TransitLine? { lines.first { $0.id == id } }
    func colorIndex(_ lineID: String) -> Int { settings.colorIndex(for: lineID) }

    // MARK: Live state

    func liveState(at now: Date) -> LiveState {
        guard let lastSuccessAt else { return .connecting }
        return now.timeIntervalSince(lastSuccessAt) > Self.staleAfter ? .stale : .live
    }

    /// Whether the board's own provider is answering. Anything but `.healthy` swaps the board for
    /// the service-down screen, which gives way again by itself once the feed comes back.
    var serviceStatus: ServiceStatus {
        let id = settings.boardProvider.id
        return health.status(providerID: id, isAvailable: settings.providerIsAvailable(id))
    }

    /// Who the board is waiting on, as the service-down screen names it: "Israel · bus.gov.il".
    var serviceName: String {
        let provider = settings.boardProvider
        guard let region = SupportedRegions.region(providerID: provider.id) else { return provider.displayName }
        return "\(region.name) · \(provider.displayName)"
    }

    func secondsSinceUpdate(at now: Date) -> TimeInterval? {
        lastSuccessAt.map { now.timeIntervalSince($0) }
    }

    // MARK: Readout

    var primary: ReadoutPrimary? {
        let arrivals = snapshot.arrivals
        if settings.tapBehaviour == .swap, let selectedBusID,
           let selected = arrivals.first(where: { $0.bus?.id == selectedBusID }),
           let line = line(selected.lineID) {
            return ReadoutPrimary(arrival: selected, line: line,
                                  colorIndex: colorIndex(line.id), kicker: .selectedBus)
        }
        guard let next = arrivals.first, let line = line(next.lineID) else { return nil }
        return ReadoutPrimary(arrival: next, line: line, colorIndex: colorIndex(line.id), kicker: .nextArrival)
    }

    /// Nothing has come back yet for this board, good or bad: the readout is waiting, not empty.
    var isAwaitingFirstBoard: Bool { primary == nil && lastSuccessAt == nil && lastError == nil }

    var secondary: ReadoutSecondary? {
        guard let primary else { return nil }
        guard let next = snapshot.arrivals.first(where: { $0.id != primary.arrival.id && $0.expectedAt >= primary.arrival.expectedAt }),
              let line = line(next.lineID) else { return nil }
        return ReadoutSecondary(arrival: next, line: line, colorIndex: colorIndex(line.id))
    }

    /// The bus whose card is open beside the readout.
    var tappedDetail: TappedBusDetail? {
        guard settings.tapBehaviour == .beside, let selectedBusID,
              let bus = snapshot.buses.first(where: { $0.id == selectedBusID }),
              let line = line(bus.lineID) else { return nil }
        return TappedBusDetail(bus: bus,
                               arrival: snapshot.arrivals.first { $0.bus?.id == bus.id },
                               line: line, colorIndex: colorIndex(line.id))
    }

    /// The puck that carries the white ring — the only thing tying the map to the numbers.
    var ringedBusID: String? {
        settings.tapBehaviour == .beside && selectedBusID != nil ? selectedBusID : primary?.arrival.bus?.id
    }

    var showsHint: Bool { !hasTappedOnce && !snapshot.buses.isEmpty }

    // MARK: Map input

    /// Adapts the transit model into the engine's plain value types. The engine never sees a
    /// `RoutePattern`, which is what keeps it testable with string fixtures.
    func mapInputs() -> (lines: [MapLineInput], vehicles: [MapVehicleInput]) {
        let ringed = ringedBusID
        let mapLines: [MapLineInput] = lines.compactMap { line in
            guard let pattern = snapshot.patterns[line.id], pattern.stops.count >= 2 else { return nil }
            // The trimmed route ends at the rider's stop, so the full one carries on from that index.
            let onward = snapshot.fullPatterns[line.id].map { $0.stops.dropFirst(pattern.stops.count) } ?? []
            return MapLineInput(id: line.id, number: line.shortName, colorIndex: colorIndex(line.id),
                                stops: pattern.stops.map { MapStopInput(code: $0.stop.code, name: $0.stop.name) },
                                onward: onward.map { MapStopInput(code: $0.stop.code, name: $0.stop.name) })
        }
        let vehicles = snapshot.buses.map {
            MapVehicleInput(id: $0.id, lineID: $0.lineID, lastStopIndex: $0.lastStopIndex,
                            progressToNext: $0.progressToNext, isSelected: $0.id == ringed)
        }
        return (mapLines, vehicles)
    }

    /// The full route view's input: each watched line terminus to terminus. The rider's stop is
    /// where the board's trimmed route ends, so a route that calls twice is placed at the same
    /// visit the board draws.
    func fullRouteInputs() -> (lines: [FullRouteLineInput], vehicles: [MapVehicleInput]) {
        let ringed = ringedBusID
        let routeLines: [FullRouteLineInput] = lines.compactMap { line in
            guard let full = snapshot.fullPatterns[line.id] ?? snapshot.patterns[line.id],
                  full.stops.count >= 2 else { return nil }
            let userIndex = (snapshot.patterns[line.id]?.stops.count).map { $0 - 1 }
                ?? full.stops.lastIndex { $0.stop.code == stop?.code }
                ?? full.stops.count - 1
            return FullRouteLineInput(id: line.id, number: line.shortName, colorIndex: colorIndex(line.id),
                                      stops: full.stops.map { MapStopInput(code: $0.stop.code, name: $0.stop.name) },
                                      userStopIndex: userIndex)
        }
        let vehicles = snapshot.buses.map {
            MapVehicleInput(id: $0.id, lineID: $0.lineID, lastStopIndex: $0.lastStopIndex,
                            progressToNext: $0.progressToNext, isSelected: $0.id == ringed)
        }
        return (routeLines, vehicles)
    }

    /// Some watched line has a route the full view can draw — the same test `fullRouteInputs` makes.
    var hasFullRoute: Bool {
        lines.contains { ((snapshot.fullPatterns[$0.id] ?? snapshot.patterns[$0.id])?.stops.count ?? 0) >= 2 }
    }

    /// A stop of the watched lines by its code, as the routes carry it.
    func routeStop(code: String) -> TransitStop? {
        if let stop, stop.code == code { return stop }
        for line in lines {
            for pattern in [snapshot.fullPatterns[line.id], snapshot.patterns[line.id]].compactMap({ $0 }) {
                if let match = pattern.stops.first(where: { $0.stop.code == code }) { return match.stop }
            }
        }
        return nil
    }

    /// What a stop's card needs: the stop, the feed to ask for its lines, and which lines are
    /// watched here so they lead.
    func stopCard(code: String) -> StopCardRequest? {
        guard let stop = routeStop(code: code) else { return nil }
        return StopCardRequest(stop: stop, providerID: configuration?.providerID ?? settings.providerID,
                               watched: lines)
    }

    // MARK: Interaction

    func inspectStop(code: String) {
        inspectedStop = stopCard(code: code)
    }

    /// Whether the line has a card to open: one only where its route can be drawn.
    func canInspectLine(_ line: TransitLine) -> Bool {
        settings.provider(id: configuration?.providerID ?? settings.providerID).hasRouteShape(for: line)
    }

    /// A watched line's card, with the board's stop picked out on it.
    func inspectLine(_ line: TransitLine) {
        inspectedLine = LineCardRequest(line: line, providerID: configuration?.providerID ?? settings.providerID,
                                        stopCode: stop?.code)
    }

    /// A selected bus or the setup tip is let go of by the next tap on the board, as a tap on its
    /// background does, before a tap on a stop opens anything.
    var dismissesBeforeOpening: Bool { selectedBusID != nil || showsSetupTip }

    func tap(busID: String) {
        hasTappedOnce = true
        showsSetupTip = false
        selectedBusID = (selectedBusID == busID && settings.tapBehaviour == .swap) ? nil : busID
    }

    /// A tap on the board away from any bus. It also puts the setup tip away: any tap on the
    /// board is the rider having read it.
    func dismissTapped() {
        selectedBusID = nil
        showsSetupTip = false
    }

    /// The rider picked a different stop, or different lines. Nothing already on screen belongs to
    /// the new board — the routes, the buses and the ETAs are all for somewhere else — so it is
    /// cleared and refetched rather than left for the next poll to correct. Keeping it would show
    /// the previous stop's arrivals under the new stop's name for up to a full polling interval.
    func configurationChanged() {
        snapshot = .empty
        lastSuccessAt = nil
        lastError = nil
        selectedBusID = nil
        hasTappedOnce = false
        trunk = TrunkSelector()
        trunkLineID = nil
        stopChangeTimes = [:]
        consecutiveFailures = 0
        incompleteRefreshes = 0
        resolvePalette()
        Task { [weak self] in
            await self?.showCachedRoutes()
            await self?.refresh(.stopChanged)
        }
    }

    func promoteTrunk(_ lineID: String) {
        trunk.manualTrunkID = lineID
        trunkLineID = trunk.select(candidateID: snapshot.arrivals.first?.lineID, now: AppClock.now)
    }

    // MARK: Polling

    /// Puts the routes on screen before the first request goes out. Everything but the buses
    /// themselves is already known, so the map has no reason to wait for the network to draw.
    func showCachedRoutes() async {
        guard let configuration, snapshot.patterns.isEmpty else { return }
        let datasetID = settings.boardProvider.datasetID
        var routes: [String: RoutePattern] = [:]
        var fullRoutes: [String: RoutePattern] = [:]
        for line in configuration.lines {
            guard let pattern = await cache.cachedPattern(for: line.id, providerID: datasetID) else { continue }
            routes[line.id] = trim(pattern, to: configuration.stop)
            fullRoutes[line.id] = pattern
        }
        guard !routes.isEmpty, snapshot.patterns.isEmpty else { return }
        snapshot = BoardSnapshot(fetchedAt: .distantPast, arrivals: [], buses: [], patterns: routes,
                                 fullPatterns: fullRoutes)
        trunkLineID = trunk.select(candidateID: configuration.lines.first?.id, now: AppClock.now)
    }

    func start() {
        guard pollTask == nil else { return }
        startMonitoringNetwork()
        pollTask = Task { [weak self] in
            await self?.showCachedRoutes()
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = self.nextInterval()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        monitor?.cancel()
        monitor = nil
    }

    func nextInterval() -> Double {
        if consecutiveFailures > 0 { return min(60, 5 * pow(2, Double(consecutiveFailures - 1))) }
        if (1...Self.maxQuickRetries).contains(incompleteRefreshes) { return Self.quickRetrySeconds }
        return Double(settings.boardProvider.refreshInterval.components.seconds)
    }

    private func startMonitoringNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied, self.wasOffline {
                    self.wasOffline = false
                    await self.refresh(.networkBack)
                } else if path.status != .satisfied {
                    self.wasOffline = true
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.hayek.BusBus.network"))
        self.monitor = monitor
    }

    // MARK: Refresh

    private struct LineResult: Sendable {
        var lineID: String
        var pattern: RoutePattern
        var progress: BusProgress
    }

    func refresh(_ trigger: RefreshTrigger = .poll) async {
        if let inFlight {
            #if DEBUG
            if let configuration {
                refreshLog.record(RefreshLogEntry(at: AppClock.now, trigger: trigger, stop: Self.logName(configuration.stop),
                                                  provider: settings.boardProvider.id, outcome: .joined))
            }
            #endif
            await inFlight.value
            return
        }
        let task = Task<Void, Never> { [weak self] in await self?.load(trigger) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load(_ trigger: RefreshTrigger) async {
        guard let configuration, !configuration.lines.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let provider = settings.boardProvider
        let started = ContinuousClock.now
        #if DEBUG
        var entry = RefreshLogEntry(at: AppClock.now, trigger: trigger, stop: Self.logName(configuration.stop),
                                    provider: provider.id, outcome: .updated)
        defer {
            let elapsed = ContinuousClock.now - started
            entry.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            refreshLog.record(entry)
        }
        #endif
        // Switched off from the console: nothing is asked of it until it is switched back on. The
        // polling loop carries on, so the board returns by itself on the first tick after.
        guard settings.providerIsAvailable(provider.id) else {
            #if DEBUG
            entry.outcome = .skipped("provider switched off")
            #endif
            return
        }
        let stop = configuration.stop
        let service = BusProgressService()
        let cache = self.cache

        var results: [LineResult] = []
        var failures: [any Error] = []
        #if DEBUG
        /// Line id → why it failed, for the debug log.
        var failedLines: [String: String] = [:]
        #endif

        await withTaskGroup(of: (lineID: String, outcome: Result<LineResult, any Error>).self) { group in
            for line in configuration.lines {
                group.addTask {
                    do {
                        let pattern = try await cache.pattern(for: line, provider: provider)
                        let geometry = RouteGeometry(pattern: pattern)
                        let progress = try await service.progress(provider: provider, geometry: geometry,
                                                                  line: line, stop: stop)
                        return (line.id, .success(LineResult(lineID: line.id, pattern: pattern, progress: progress)))
                    } catch {
                        return (line.id, .failure(error))
                    }
                }
            }
            for await (lineID, outcome) in group {
                switch outcome {
                case .success(let result): results.append(result)
                case .failure(let error):
                    failures.append(error)
                    #if DEBUG
                    failedLines[lineID] = ServiceHealth.describe(error)
                    #else
                    _ = lineID
                    #endif
                }
            }
        }

        #if DEBUG
        // Filled in after the board is updated, so each line can say what it went on to show.
        defer {
            entry.lines = configuration.lines.map { line in
                let result = results.first { $0.lineID == line.id }
                let shown = snapshot.arrivals.filter { $0.lineID == line.id }
                return RefreshLogEntry.Line(
                    name: line.shortName,
                    fromFeed: result?.progress.arrivals.count,
                    shown: result == nil ? nil : shown.count,
                    buses: result?.progress.buses.count,
                    next: result == nil ? nil : shown.first?.expectedAt,
                    error: failedLines[line.id] ?? result?.progress.arrivalsError
                        ?? result?.progress.vehiclesError.map { "vehicles: \($0)" })
            }
        }
        #endif

        if results.isEmpty {
            #if DEBUG
            entry.outcome = .failed
            #endif
            // Keep the last good board rather than blanking it; the LIVE dot tells the truth.
            consecutiveFailures += 1
            let description = failures.first.map(ServiceHealth.describe) ?? "unknown"
            lastError = description
            Self.log.warning("refresh failed: \(description, privacy: .public)")
            health.recordFailure(providerID: provider.id, endpoint: "refresh",
                                 error: failures.first ?? TransitError.badResponse("no lines"))
            let connection = failures.first.map(ServiceHealth.isConnectivityError) ?? false
            logBoard(configuration, outcome: connection ? "no_connection" : "failed", since: started)
            return
        }

        consecutiveFailures = 0
        let arrivalFailures = results.compactMap(\.progress.arrivalsError)
        lastError = failures.first.map(ServiceHealth.describe) ?? arrivalFailures.first
        let progresses = results.map(\.progress)
        // Positions without a single timetable is still a broken feed: every line's minutes are gone.
        if arrivalFailures.count == results.count {
            health.recordFailure(providerID: provider.id, endpoint: "arrivals",
                                 error: progresses[0].arrivalsReply ?? ServiceFailure(description: arrivalFailures[0]))
        } else {
            health.recordSuccess(providerID: provider.id)
            // The board survives these, but each one is a feed that failed us and is worth seeing.
            for failure in failures { health.reportFailure(providerID: provider.id, endpoint: "line", error: failure) }
            for progress in progresses {
                guard let description = progress.arrivalsError else { continue }
                health.reportFailure(providerID: provider.id, endpoint: "arrivals",
                                     error: progress.arrivalsReply ?? ServiceFailure(description: description))
            }
        }
        for progress in progresses {
            guard let description = progress.vehiclesError else { continue }
            health.reportFailure(providerID: provider.id, endpoint: "vehicles",
                                 error: progress.vehiclesReply ?? ServiceFailure(description: description))
        }
        let complete = apply(results: results, stop: stop, now: AppClock.now)
        incompleteRefreshes = complete ? 0 : incompleteRefreshes + 1
        lastSuccessAt = AppClock.now
        logBoard(configuration, outcome: Self.analyticsOutcome(snapshot.arrivals), since: started)
        WidgetBridge.boardDidRefresh(configuration: configuration, snapshot: snapshot, settings: settings,
                                     at: AppClock.now)
    }

    #if DEBUG
    private static func logName(_ stop: TransitStop) -> String { "\(stop.name) (\(stop.code))" }
    #endif

    /// Whether the rider got what they came for: the first time a board comes up, or fails to, in
    /// this launch. Later polls of the same board are left out.
    private func logBoard(_ configuration: BoardConfiguration, outcome: String, since started: ContinuousClock.Instant) {
        let key = "\(configuration.providerID)|\(configuration.stop.id)|\(configuration.lines.map(\.id))|\(outcome)"
        guard loggedBoards.insert(key).inserted else { return }
        let elapsed = ContinuousClock.now - started
        Telemetry.log("board_loaded", [
            "outcome": outcome,
            "provider_id": configuration.providerID,
            "lines": configuration.lines.count,
            "buses": snapshot.buses.count,
            "load_ms": Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
        ])
    }

    /// "live" when a minute on the board comes from a bus, "scheduled" when every one is the
    /// timetable's, and "no_buses" when nothing is due.
    nonisolated static func analyticsOutcome(_ arrivals: [BoardArrival]) -> String {
        if arrivals.isEmpty { return "no_buses" }
        return arrivals.contains(where: \.isRealtime) ? "live" : "scheduled"
    }

    /// Returns false when some line drew its buses but not their minutes, so the caller asks again
    /// soon instead of leaving "NO BUSES DUE" under a bus for a whole polling interval.
    @discardableResult
    private func apply(results: [LineResult], stop: TransitStop, now: Date) -> Bool {
        var complete = true
        let previousArrivals = snapshot.arrivals
        var routes = snapshot.patterns
        var fullRoutes = snapshot.fullPatterns
        /// Ids the ranking moved to a different vehicle between polls.
        var retargeted: Set<String> = []
        var buses: [BoardBus] = snapshot.buses.filter { lineID in
            !results.contains { $0.lineID == lineID.lineID }
        }
        var arrivals: [BoardArrival] = snapshot.arrivals.filter { arrival in
            !results.contains { $0.lineID == arrival.lineID }
        }

        for result in results {
            let trimmed = trim(result.pattern, to: stop)
            routes[result.lineID] = trimmed
            fullRoutes[result.lineID] = result.pattern
            let targetIndex = trimmed.stops.count - 1
            let geometry = RouteGeometry(pattern: trimmed)

            // Closest to the stop first — that is the order arrivals come in too, which is the only
            // link we have between a prediction and a position on a feed with no trip ids.
            let tracked = result.progress.buses
                .filter { $0.distanceAlongRoute <= result.progress.targetDistance + BusProgressService.atStopToleranceMeters }
                .sorted { $0.distanceAlongRoute > $1.distanceAlongRoute }

            var lineBuses: [BoardBus] = []
            for (rank, bus) in tracked.enumerated() {
                let index = min(geometry.lastStopIndex(atDistance: bus.distanceAlongRoute), max(0, targetIndex - 1))
                let from = geometry.stopDistances[index]
                let to = geometry.stopDistances[min(index + 1, targetIndex)]
                let fraction = to > from ? (bus.distanceAlongRoute - from) / (to - from) : 0
                let id = bus.vehicle.plateNumber ?? bus.vehicle.tripId ?? "\(result.lineID)-rank\(rank)"

                if let previous = stopChangeTimes[id] {
                    if previous.index > index {
                        // A vehicle never runs backwards along its route, so an id that does has
                        // been handed to a different bus by the ranking. Start it over.
                        stopChangeTimes[id] = (index, nil)
                        retargeted.insert(id)
                    } else if previous.index < index {
                        stopChangeTimes[id] = (index, now)
                    }
                } else {
                    stopChangeTimes[id] = (index, nil)
                }
                let passedAt = stopChangeTimes[id].flatMap { $0.index == index ? $0.changedAt : nil }

                lineBuses.append(BoardBus(
                    id: id, lineID: result.lineID, lastStopIndex: index,
                    progressToNext: min(max(fraction, 0), 1),
                    stopsAway: max(0, targetIndex - index),
                    lastStopCode: trimmed.stops[index].stop.code,
                    lastStopName: trimmed.stops[index].stop.name,
                    lastStopPassedAt: passedAt,
                    positionAge: bus.vehicle.recordedAt.map { now.timeIntervalSince($0) }))
            }
            buses.append(contentsOf: lineBuses)

            // A bus on its way with no minutes for it is a missing answer, not an empty timetable:
            // the calendar call failed or came back blank. Keep this line's last minutes that are
            // still ahead rather than wiping the readout under a bus the map is still showing.
            let upcoming = result.progress.arrivals.sorted { $0.expectedAt < $1.expectedAt }
            if result.progress.arrivalsError != nil || (upcoming.isEmpty && !lineBuses.isEmpty) {
                complete = false
                let kept = previousArrivals.filter {
                    $0.lineID == result.lineID && $0.expectedAt > now.addingTimeInterval(-60)
                }
                for (index, var arrival) in kept.enumerated() {
                    arrival.bus = index < lineBuses.count ? lineBuses[index] : nil
                    arrivals.append(arrival)
                }
                continue
            }
            // The buses were measured on the whole pattern, not the trimmed one; the predictions'
            // positions have to be too, or a line that passes the stop twice snaps them to another pass.
            for pair in Self.pair(upcoming, with: tracked, geometry: RouteGeometry(pattern: result.pattern),
                                  targetDistance: result.progress.targetDistance, now: now) {
                let matched = pair.busIndex.map { lineBuses[$0] }
                let arrival = pair.arrival
                // An estimate has no trip of its own; naming it after its bus keeps it the same row between polls.
                let key = pair.isEstimate ? "bus-\(matched?.id ?? "")"
                    : arrival.tripId ?? String(Int(arrival.expectedAt.timeIntervalSince1970))
                arrivals.append(BoardArrival(
                    id: "\(result.lineID)#\(key)",
                    lineID: result.lineID, expectedAt: arrival.expectedAt,
                    isRealtime: arrival.isRealtime,
                    delay: arrival.isRealtime ? arrival.delay : nil, bus: matched,
                    isEstimate: pair.isEstimate))
            }
        }

        snapshot = BoardSnapshot(fetchedAt: now,
                                 arrivals: arrivals.sorted { $0.expectedAt < $1.expectedAt },
                                 buses: buses, patterns: routes, fullPatterns: fullRoutes)

        if let selectedBusID, !buses.contains(where: { $0.id == selectedBusID }) || retargeted.contains(selectedBusID) {
            self.selectedBusID = nil
        }
        trunkLineID = trunk.select(candidateID: snapshot.arrivals.first?.lineID, now: now)
        // Forget buses that have finished their run so the dictionary cannot grow forever.
        let live = Set(buses.map(\.id))
        stopChangeTimes = stopChangeTimes.filter { live.contains($0.key) }
        return complete
    }

    /// A prediction's bus and a drawn bus are the same one when they sit this close along the route.
    /// bus.gov.il samples the two a little apart; 240 m was the widest gap seen on line 148 in Haifa.
    static let predictionMatchMeters = 500.0
    /// How far ahead of a prediction's position its bus may already be. That position is a sample
    /// older than the vehicle feed's, so it trails the bus: line 112 at Allenby G, Haifa, on
    /// 2 Oct 2026 put it 536 m back on a clear stretch. About a minute at the fastest plausible pace.
    static let predictionLagMeters = 1_000.0
    /// City traffic, stops included (about 14 km/h). Used when no realtime prediction on the line
    /// gives a pace to borrow.
    static let fallbackBusSpeed = 4.0
    /// A pace borrowed from a prediction is kept between a crawl in a jam and a clear main road, so
    /// one odd prediction cannot put a bus at the stop in seconds or leave it an hour away.
    static let plausibleBusSpeeds = 2.0...15.0
    /// A timetable slot due this long after a drawn bus's estimate is still that bus, running early
    /// or quicker than city pace; any slot before it is the same bus running late.
    static let earlyRunningAllowance: TimeInterval = 5 * 60

    /// Which drawn bus each prediction is about, plus a time for a bus the timetable left out.
    /// `buses` run closest to the stop first and were measured on `geometry`, the whole pattern.
    /// A shared trip id settles it; failing that, a prediction that says where its bus is goes to
    /// the bus there; one that says neither falls back to order, the only link a bare feed leaves us.
    static func pair(_ arrivals: [Arrival], with buses: [TrackedBus], geometry: RouteGeometry,
                     targetDistance: Double, now: Date, limits: BusProgressService = BusProgressService())
        -> [(arrival: Arrival, busIndex: Int?, isEstimate: Bool)] {
        var busFor = [Int?](repeating: nil, count: arrivals.count)
        var free = Set(buses.indices)

        for (index, arrival) in arrivals.enumerated() {
            guard let trip = arrival.tripId,
                  let bus = free.sorted().first(where: { buses[$0].vehicle.tripId == trip }) else { continue }
            busFor[index] = bus
            free.remove(bus)
        }

        // Filtered the way the buses themselves are, so the next trip's bus waiting at the origin,
        // which the map does not draw, cannot claim the bus that has just left it.
        let along: [Double?] = arrivals.map { arrival in
            guard let location = arrival.vehicleLocation, let snapped = geometry.project(location),
                  snapped.offRoute <= limits.maxOffRouteMeters,
                  snapped.distanceAlong > limits.terminalToleranceMeters else { return nil }
            return snapped.distanceAlong
        }
        // Closest pairs first: taking predictions in time order lets an early one grab the bus a
        // later one sits right on, and the two end up swapped.
        let candidates = arrivals.indices.filter { busFor[$0] == nil }.flatMap { index in
            along[index].map { position in
                free.map { bus in (arrival: index, bus: bus, ahead: buses[bus].distanceAlongRoute - position) }
            } ?? []
        }
        // The position trails the bus, so a bus ahead of it may be further off than one behind.
        // Gaps are ranked against the reach on their own side: otherwise a bus a little behind the
        // position, the next trip's, outranks the lagged bus ahead that the position is really about.
        .filter { -predictionMatchMeters...predictionLagMeters ~= $0.ahead }
        .map { candidate -> (arrival: Int, bus: Int, gap: Double) in
            let reach = candidate.ahead > 0 ? predictionLagMeters : predictionMatchMeters
            return (candidate.arrival, candidate.bus, abs(candidate.ahead) / reach)
        }
        .sorted { ($0.gap, $0.arrival, $0.bus) < ($1.gap, $1.arrival, $1.bus) }
        for candidate in candidates where busFor[candidate.arrival] == nil && free.contains(candidate.bus) {
            busFor[candidate.arrival] = candidate.bus
            free.remove(candidate.bus)
        }

        // With nothing tying a prediction to a bus there is no telling which bus the timetable
        // skipped, and a guessed time would only sit beside the real one for the same bus.
        // A timetable slot, though, is no bus at all: with only slots, each bus coming gets a time
        // of its own at city pace, and takes the slot it is running so it is not counted twice.
        guard busFor.contains(where: { $0 != nil }) else {
            guard !arrivals.contains(where: \.isRealtime) else {
                return arrivals.enumerated().map { ($1, $0 < buses.count ? $0 : nil, false) }
            }
            var slots = arrivals.map { (arrival: $0, busIndex: Int?.none, isEstimate: false) }
            for index in buses.indices where buses[index].distanceAlongRoute < targetDistance {
                let expected = now.addingTimeInterval((targetDistance - buses[index].distanceAlongRoute) / fallbackBusSpeed)
                if let running = slots.indices.filter({ !slots[$0].isEstimate })
                    .min(by: { slots[$0].arrival.expectedAt < slots[$1].arrival.expectedAt }),
                   slots[running].arrival.expectedAt <= expected.addingTimeInterval(earlyRunningAllowance) {
                    slots.remove(at: running)
                }
                slots.append((Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: true, tripId: nil,
                                      vehicleLocation: buses[index].vehicle.location), index, true))
            }
            return slots.sorted { $0.arrival.expectedAt < $1.arrival.expectedAt }
        }

        // A prediction that says nothing of its bus takes the closest free bus that keeps the order
        // the matched ones set: behind every bus due before it, ahead of every bus due after.
        for index in arrivals.indices where busFor[index] == nil && arrivals[index].vehicleLocation == nil {
            let placed = arrivals.indices.compactMap { other in
                busFor[other].map { (at: arrivals[other].expectedAt, along: buses[$0].distanceAlongRoute) }
            }
            let due = arrivals[index].expectedAt
            let ahead = placed.filter { $0.at <= due }.map(\.along).min() ?? .infinity
            let behind = placed.filter { $0.at > due }.map(\.along).max() ?? -.infinity
            guard let bus = free.sorted().first(where: {
                buses[$0].distanceAlongRoute < ahead && buses[$0].distanceAlongRoute > behind
            }) else { continue }
            busFor[index] = bus
            free.remove(bus)
        }

        var pairs = arrivals.enumerated().map { (arrival: $1, busIndex: busFor[$0], isEstimate: false) }

        // A bus nearer the stop than every predicted one reaches it first, whatever the timetable
        // says; the rider can see it coming. Give it a time at the pace the nearest predicted bus
        // is keeping, so the two numbers agree with the order on the map. A timetable-only time
        // says nothing about how the bus is moving, so that lead lends neither pace nor bound.
        let matched = pairs.compactMap { pair in pair.busIndex.map { (bus: buses[$0], arrival: pair.arrival) } }
        guard let lead = matched.max(by: { $0.bus.distanceAlongRoute < $1.bus.distanceAlongRoute }) else { return pairs }
        let leadMeters = targetDistance - lead.bus.distanceAlongRoute
        let leadSeconds = lead.arrival.expectedAt.timeIntervalSince(now)
        let pace = lead.arrival.isRealtime && leadMeters > 0 && leadSeconds > 30
            ? min(max(leadMeters / leadSeconds, plausibleBusSpeeds.lowerBound), plausibleBusSpeeds.upperBound)
            : fallbackBusSpeed
        // A bus at the stop or just past it is one whose trip the feed has already dropped, not
        // one it forgot; it would read "now" until it drove out of range.
        for index in free.sorted() where buses[index].distanceAlongRoute > lead.bus.distanceAlongRoute
            && buses[index].distanceAlongRoute < targetDistance {
            var expected = now.addingTimeInterval((targetDistance - buses[index].distanceAlongRoute) / pace)
            if lead.arrival.isRealtime { expected = min(expected, lead.arrival.expectedAt) }
            pairs.append((Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: true, tripId: nil,
                                  vehicleLocation: buses[index].vehicle.location), index, true))
        }
        return pairs.sorted { $0.arrival.expectedAt < $1.arrival.expectedAt }
    }

    /// The map draws a route only as far as the rider's stop; anything past it is another trip.
    private func trim(_ pattern: RoutePattern, to stop: TransitStop) -> RoutePattern {
        guard let index = pattern.stops.lastIndex(where: { $0.stop.code == stop.code }) else { return pattern }
        var trimmed = pattern
        trimmed.stops = Array(pattern.stops.prefix(index + 1))
        return trimmed
    }
}
