import Testing
import Foundation
@testable import BusBus

/// What the outage rules promise: one bad refresh is not an outage, three in a row online are, the
/// alert fires once per episode, an offline device never alerts, and recovery is reported.
@MainActor
struct ServiceHealthTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let broken = TransitError.badResponse("decoding /siri: keyNotFound(\"MonitoredStopVisit\")")

    /// Collects what would have gone to Firebase.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures: [(provider: String, endpoint: String, error: String, reply: ResponseError?)] = []
        private var _outages: [(provider: String, endpoint: String, error: String)] = []
        private var _recoveries: [(provider: String, seconds: TimeInterval)] = []

        var failures: [(provider: String, endpoint: String, error: String, reply: ResponseError?)] { lock.withLock { _failures } }
        var outages: [(provider: String, endpoint: String, error: String)] { lock.withLock { _outages } }
        var recoveries: [(provider: String, seconds: TimeInterval)] { lock.withLock { _recoveries } }

        var reporter: OutageReporter {
            OutageReporter(
                failure: { [self] provider, endpoint, error, reply in lock.withLock { _failures.append((provider, endpoint, error, reply)) } },
                outage: { [self] provider, endpoint, error in lock.withLock { _outages.append((provider, endpoint, error)) } },
                recovered: { [self] provider, seconds in lock.withLock { _recoveries.append((provider, seconds)) } })
        }
    }

    private static func monitor(_ recorder: Recorder) -> ServiceHealthMonitor {
        let monitor = ServiceHealthMonitor(reporter: recorder.reporter)
        #if DEBUG
        monitor.simulatedOutage = nil
        #endif
        var clock = start
        monitor.now = {
            clock = clock.addingTimeInterval(20)
            return clock
        }
        return monitor
    }

    // MARK: The state machine

    @Test func aSingleFailureIsNotAnOutage() {
        var health = ServiceHealth()
        #expect(health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start) == nil)
        #expect(health.status(isOnline: true) == .healthy)
        #expect(health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start) == nil)
        #expect(health.status(isOnline: true) == .healthy)
    }

    @Test func threeFailuresInARowOnlineAreAnOutage() {
        var health = ServiceHealth()
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        let event = health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        #expect(event == .outageBegan(endpoint: "refresh", error: Self.broken.localizedDescription))
        #expect(health.status(isOnline: true) == .down(since: Self.start))
    }

    @Test func aSuccessInBetweenResetsTheCount() {
        var health = ServiceHealth()
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        health.recordSuccess(at: Self.start)
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start)
        #expect(!health.isInOutage)
    }

    @Test func offlineFailuresNeverOpenAnOutage() {
        var health = ServiceHealth()
        for _ in 0..<10 {
            #expect(health.recordFailure(URLError(.notConnectedToInternet), endpoint: "refresh",
                                         isOnline: false, at: Self.start) == nil)
        }
        #expect(!health.isInOutage)
        #expect(health.status(isOnline: false) == .offline)
        // Back online, the streak starts again: one more failure is not the third.
        #expect(health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start) == nil)
        #expect(health.status(isOnline: true) == .healthy)
    }

    @Test func connectivityErrorsDoNotCountEvenWhenThePathLooksUp() {
        var health = ServiceHealth()
        for _ in 0..<5 {
            health.recordFailure(URLError(.networkConnectionLost), endpoint: "refresh", isOnline: true, at: Self.start)
        }
        #expect(!health.isInOutage)
    }

    @Test func cancellationIsNotAFailure() {
        var health = ServiceHealth()
        for _ in 0..<5 { health.recordFailure(CancellationError(), endpoint: "search", isOnline: true, at: Self.start) }
        health.recordFailure(URLError(.cancelled), endpoint: "search", isOnline: true, at: Self.start)
        #expect(health.consecutiveFailures == 0)
    }

    @Test func recoveryReportsHowLongItLasted() {
        var health = ServiceHealth()
        for _ in 0..<3 { health.recordFailure(Self.broken, endpoint: "refresh", isOnline: true, at: Self.start) }
        let event = health.recordSuccess(at: Self.start.addingTimeInterval(600))
        #expect(event == .recovered(outageSeconds: 600))
        #expect(health.status(isOnline: true) == .healthy)
        #expect(health.recordSuccess(at: Self.start) == nil)
    }

    // MARK: The monitor and its alerts

    @Test func oneAlertPerEpisodePerProvider() {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        for _ in 0..<12 { monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: Self.broken) }
        #expect(recorder.outages.count == 1)
        #expect(recorder.outages.first?.provider == "mbta")
        #expect(recorder.outages.first?.error.contains("MonitoredStopVisit") == true)

        // Another provider's outage is its own episode.
        for _ in 0..<3 { monitor.recordFailure(providerID: "tfl", endpoint: "searchStops", error: Self.broken) }
        #expect(recorder.outages.map(\.provider) == ["mbta", "tfl"])

        monitor.recordSuccess(providerID: "mbta")
        #expect(recorder.recoveries.count == 1)
        #expect(recorder.recoveries.first?.provider == "mbta")
        #expect((recorder.recoveries.first?.seconds ?? 0) > 0)
        #expect(monitor.status(providerID: "mbta", isAvailable: true) == .healthy)

        // A second episode is alerted again.
        for _ in 0..<3 { monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: Self.broken) }
        #expect(recorder.outages.filter { $0.provider == "mbta" }.count == 2)
    }

    /// Each distinct failure reaches Crashlytics at once, not three refreshes later, and only once a launch.
    @Test func everyDistinctFailureIsReportedOnce() {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        monitor.recordFailure(providerID: "bus.gov.il", endpoint: "arrivals", error: Self.broken)
        #expect(recorder.failures.count == 1)
        #expect(recorder.outages.isEmpty)
        #expect(recorder.failures.first?.error.contains("MonitoredStopVisit") == true)

        for _ in 0..<10 { monitor.recordFailure(providerID: "bus.gov.il", endpoint: "arrivals", error: Self.broken) }
        #expect(recorder.failures.count == 1)

        monitor.recordFailure(providerID: "bus.gov.il", endpoint: "searchStops", error: Self.broken)
        monitor.recordFailure(providerID: "bus.gov.il", endpoint: "arrivals", error: TransitError.badResponse("HTTP 503 for /x"))
        #expect(recorder.failures.map(\.endpoint) == ["arrivals", "searchStops", "arrivals"])
    }

    /// What the server said travels with the failure, so the non-fatal shows the body.
    @Test func theReplyIsReportedWithTheFailure() throws {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        let reply = ResponseError(reason: "HTTP 503 for /Calendar", url: "https://api.bus.gov.il/x?key=REDACTED",
                                  status: 503, body: "<html>maintenance</html>")
        monitor.reportFailure(providerID: "bus.gov.il", endpoint: "vehicles", error: reply)
        let sent = try #require(recorder.failures.first?.reply)
        #expect(sent.body == "<html>maintenance</html>")
        #expect(sent.status == 503)
        #expect(recorder.failures.first?.error == "Bad response: HTTP 503 for /Calendar")
        // Reported, but never counted towards the rider's service-down screen.
        #expect(monitor.status(providerID: "bus.gov.il", isAvailable: true) == .healthy)
    }

    @Test func aLongBodyIsCutAndSaysSo() {
        let text = ResponseError.text(of: Data(String(repeating: "a", count: ResponseError.bodyLimit + 10).utf8))
        #expect(text.hasSuffix("10 more bytes of \(ResponseError.bodyLimit + 10)"))
        #expect(ResponseError.text(of: Data([0xFF, 0xFE, 0x00])).hasPrefix("<3 bytes, base64>"))
    }

    @Test func cancellationsAndTheNetworkAreNotReported() {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: CancellationError())
        monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: URLError(.notConnectedToInternet))
        monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: TransitError.missingAPIKey("x"))
        monitor.setOnline(false)
        monitor.recordFailure(providerID: "mbta", endpoint: "refresh", error: Self.broken)
        #expect(recorder.failures.isEmpty)
    }

    @Test func anOfflineDeviceNeverAlerts() {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        monitor.setOnline(false)
        for _ in 0..<10 { monitor.recordFailure(providerID: "entur", endpoint: "refresh", error: Self.broken) }
        #expect(recorder.outages.isEmpty)
        #expect(monitor.status(providerID: "entur", isAvailable: true) == .offline)
        monitor.setOnline(true)
        #expect(monitor.status(providerID: "entur", isAvailable: true) == .healthy)
    }

    @Test func aRemoteDisableIsShownButNeverAlerted() {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        #expect(monitor.status(providerID: "foli", isAvailable: false) == .disabled)
        #expect(recorder.outages.isEmpty)
    }

    // MARK: The board

    @Test func theBoardGoesDownAfterThreeFailedRefreshesAndComesBack() async throws {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "health-\(UUID().uuidString)")!)
        let switchable = SwitchableProvider()
        settings.providerOverride = switchable
        let stop = try await switchable.searchStops(query: MapFixtures.user).first!
        let lines = try await switchable.lines(atStop: stop)
        settings.apply(stop: stop, lines: Array(lines.prefix(2)), providerID: switchable.id)
        let model = BoardViewModel(settings: settings, cache: TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")),
                                   health: monitor)
        await model.refresh()
        #expect(model.serviceStatus == .healthy)

        switchable.state.fails = true
        await model.refresh()
        #expect(model.serviceStatus == .healthy, "one failed refresh keeps the board")
        await model.refresh()
        await model.refresh()
        #expect(model.serviceStatus.replacesBoard)
        await model.refresh()
        #expect(recorder.outages.count == 1)
        #expect(recorder.outages.first?.provider == switchable.id)

        switchable.state.fails = false
        await model.refresh()
        #expect(model.serviceStatus == .healthy)
        #expect(recorder.recoveries.count == 1)
    }

    @Test func aRemotelyDisabledBoardProviderShowsTheScreenWithoutAsking() async throws {
        let recorder = Recorder()
        let monitor = Self.monitor(recorder)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "health-\(UUID().uuidString)")!)
        let switchable = SwitchableProvider()
        settings.providerOverride = switchable
        let stop = try await switchable.searchStops(query: MapFixtures.user).first!
        let lines = try await switchable.lines(atStop: stop)
        settings.apply(stop: stop, lines: Array(lines.prefix(1)), providerID: switchable.id)
        settings.regionIsAvailable = { _ in false }
        let model = BoardViewModel(settings: settings, cache: TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")),
                                   health: monitor)
        await model.refresh()
        #expect(model.serviceStatus == .disabled)
        #expect(switchable.state.calls == 0)
        #expect(recorder.outages.isEmpty)
    }
}

/// The mock feed, with a switch that breaks every call.
private nonisolated final class SwitchableState: @unchecked Sendable {
    var fails = false
    var calls = 0
}

private nonisolated struct SwitchableProvider: TransitProvider {
    let id = "switchable"
    let displayName = "Switchable"
    let capabilities: ProviderCapabilities = [.routePattern, .vehiclePositions, .realtimeArrivals]
    let suggestedRefreshInterval: Duration = .seconds(20)
    let state = SwitchableState()
    private let mock = MockTransitProvider()

    private func check() throws {
        state.calls += 1
        if state.fails { throw TransitError.badResponse("HTTP 503 for /vehicles") }
    }

    func searchStops(query: String) async throws -> [TransitStop] { try await mock.searchStops(query: query) }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { try await mock.lines(atStop: stop) }
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try check()
        return try await mock.routePattern(for: line)
    }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        try check()
        return try await mock.vehicles(for: line)
    }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        try check()
        return try await mock.arrivals(for: line, at: stop)
    }
}
