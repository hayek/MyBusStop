import Foundation
import Network
import Observation

/// What the rider should be told about a provider right now.
nonisolated enum ServiceStatus: Hashable, Sendable {
    /// Answering, or failing too briefly to mean anything: the stale indicator covers it.
    case healthy
    /// Failing for several refreshes in a row while the device is online. The feed is broken.
    case down(since: Date)
    /// The device has no network. Nothing is wrong with the feed, and nobody is alerted.
    case offline
    /// Switched off from the Firebase console. Deliberate, so nobody is alerted either.
    case disabled

    /// Whether the board gives way to the service-down screen.
    var replacesBoard: Bool { self != .healthy }
}

/// One provider's run of failures, and whether they add up to an outage.
///
/// A single failed refresh is weather: the board keeps its last numbers and the LIVE dot goes grey.
/// `outageThreshold` of them in a row, with the device online, is an outage — reported once when
/// it begins and once when it ends, never per retry. Failures while offline are counted towards
/// the "no connection" state but never towards an outage.
nonisolated struct ServiceHealth: Hashable, Sendable {
    static let outageThreshold = 3

    /// Something the owner of the state machine has to tell the outside world about.
    enum Event: Hashable, Sendable {
        case outageBegan(endpoint: String, error: String)
        case recovered(outageSeconds: TimeInterval)
    }

    /// Every failure in a row, online or not.
    private(set) var consecutiveFailures = 0
    /// Failures in a row that happened while online and were not the network itself giving out.
    private(set) var onlineFailures = 0
    /// When the current outage was declared. Set once per episode; only a success clears it.
    private(set) var outageStartedAt: Date?

    var isInOutage: Bool { outageStartedAt != nil }

    @discardableResult
    mutating func recordSuccess(at now: Date) -> Event? {
        consecutiveFailures = 0
        onlineFailures = 0
        guard let started = outageStartedAt else { return nil }
        outageStartedAt = nil
        return .recovered(outageSeconds: max(0, now.timeIntervalSince(started)))
    }

    @discardableResult
    mutating func recordFailure(_ error: any Error, endpoint: String, isOnline: Bool, at now: Date) -> Event? {
        if Self.isCancellation(error) || Self.isMissingAPIKey(error) { return nil }
        consecutiveFailures += 1
        guard isOnline, !Self.isConnectivityError(error) else {
            // The streak is broken by the network, not by the feed: start counting again.
            onlineFailures = 0
            return nil
        }
        onlineFailures += 1
        guard onlineFailures >= Self.outageThreshold, outageStartedAt == nil else { return nil }
        outageStartedAt = now
        return .outageBegan(endpoint: endpoint, error: Self.describe(error))
    }

    func status(isOnline: Bool) -> ServiceStatus {
        if !isOnline {
            // Offline for one blip is still weather; offline and failing is the "no connection" state.
            return consecutiveFailures >= Self.outageThreshold || isInOutage ? .offline : .healthy
        }
        if let outageStartedAt { return .down(since: outageStartedAt) }
        return .healthy
    }

    /// The network, not the feed: these never count towards an outage.
    static func isConnectivityError(_ error: any Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                .internationalRoamingOff, .callIsActive].contains(url.code)
    }

    /// A request abandoned because the board moved on is not a failure of anything.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// A key that has not arrived yet (Remote Config) is not an outage of the feed; the provider
    /// shows as unavailable instead, and nobody is alerted.
    static func isMissingAPIKey(_ error: any Error) -> Bool {
        if case TransitError.missingAPIKey = error { return true }
        return false
    }

    /// Whether a failure says something about the feed, and so belongs in Crashlytics. Cancelled
    /// requests, missing keys and the network giving out say nothing about it.
    static func isReportable(_ error: any Error, isOnline: Bool) -> Bool {
        isOnline && !isCancellation(error) && !isMissingAPIKey(error) && !isConnectivityError(error)
    }

    /// Decoding errors are the ones that say an API changed shape, so the full description is kept,
    /// with any URL in it redacted: a URLError's description quotes the request whole, and a nearby
    /// request's says where the rider is standing.
    static func describe(_ error: any Error) -> String {
        let localized = (error as? LocalizedError)?.errorDescription
        return HTTPClient.redacted(text: localized ?? String(describing: error))
    }
}

/// Where outages and recoveries are sent. Firebase in the app; a recorder in tests.
nonisolated struct OutageReporter: Sendable {
    /// Every failure worth seeing, as it happens; the monitor sends each distinct one once per launch.
    var failure: @Sendable (_ providerID: String, _ endpoint: String, _ error: String, _ reply: ResponseError?) -> Void
    var outage: @Sendable (_ providerID: String, _ endpoint: String, _ error: String) -> Void
    var recovered: @Sendable (_ providerID: String, _ outageSeconds: TimeInterval) -> Void

    static let firebase = OutageReporter(
        failure: { providerID, endpoint, error, reply in
            Telemetry.providerFailure(providerID: providerID, endpoint: endpoint, description: error, reply: reply)
        },
        outage: { providerID, endpoint, error in
            Telemetry.serviceOutage(providerID: providerID, endpoint: endpoint, error: ServiceFailure(description: error))
        },
        recovered: { providerID, seconds in
            Telemetry.log("service_recovered", ["provider_id": providerID, "outage_seconds": Int(seconds.rounded())])
        })

    static let silent = OutageReporter(failure: { _, _, _, _ in }, outage: { _, _, _ in }, recovered: { _, _ in })
}

/// Carries an already-described error into Crashlytics without losing its words.
nonisolated struct ServiceFailure: LocalizedError, CustomStringConvertible, Sendable {
    var description: String
    var errorDescription: String? { description }
}

/// Every provider's health, and whether the device is online at all. Shared by the board and
/// setup, so failures on either side count towards the same outage and it is reported once.
@MainActor @Observable final class ServiceHealthMonitor {
    static let shared = ServiceHealthMonitor(reporter: .firebase)

    private(set) var isOnline = true
    private var records: [String: ServiceHealth] = [:]
    @ObservationIgnored var reporter: OutageReporter
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Failures already sent this launch, so a feed failing on every 20-second refresh is one
    /// non-fatal rather than hundreds.
    @ObservationIgnored private var reportedFailures: Set<String> = []

    #if DEBUG
    /// `-BusBusSimulateOutage <providerID>` shows the service-down screen for that provider,
    /// `-BusBusSimulateOutage offline` the no-connection one. Nothing is reported to Firebase.
    @ObservationIgnored var simulatedOutage: String? = UserDefaults.standard.string(forKey: "BusBusSimulateOutage")
    #endif

    init(reporter: OutageReporter) {
        self.reporter = reporter
    }

    func startMonitoringConnectivity() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.hayek.BusBus.health"))
        pathMonitor = monitor
    }

    func setOnline(_ online: Bool) {
        if isOnline != online { isOnline = online }
    }

    func health(of providerID: String) -> ServiceHealth { records[providerID] ?? ServiceHealth() }

    func recordSuccess(providerID: String) {
        var health = health(of: providerID)
        let event = health.recordSuccess(at: now())
        if health != records[providerID] { records[providerID] = health }
        if case .recovered(let seconds) = event { reporter.recovered(providerID, seconds) }
    }

    func recordFailure(providerID: String, endpoint: String, error: any Error) {
        var health = health(of: providerID)
        let event = health.recordFailure(error, endpoint: endpoint, isOnline: isOnline, at: now())
        if health != records[providerID] { records[providerID] = health }
        reportFailure(providerID: providerID, endpoint: endpoint, error: error)
        if case .outageBegan(let endpoint, let description) = event {
            reporter.outage(providerID, endpoint, description)
        }
    }

    /// Sends a failure to Crashlytics, with the reply when there was one, without counting it towards
    /// an outage: for the parts a board survives without, like positions or one line's timetable.
    func reportFailure(providerID: String, endpoint: String, error: any Error) {
        guard ServiceHealth.isReportable(error, isOnline: isOnline) else { return }
        let description = ServiceHealth.describe(error)
        guard reportedFailures.insert("\(providerID)|\(endpoint)|\(description)").inserted else { return }
        reporter.failure(providerID, endpoint, description, error as? ResponseError)
    }

    /// `isAvailable` is the remote switch for this provider; a provider switched off is disabled
    /// whatever its own record says.
    func status(providerID: String, isAvailable: Bool) -> ServiceStatus {
        guard isAvailable else { return .disabled }
        #if DEBUG
        if let simulatedOutage {
            if simulatedOutage == "offline" { return .offline }
            if simulatedOutage == "disabled" { return .disabled }
            if simulatedOutage == providerID { return .down(since: now().addingTimeInterval(-240)) }
        }
        #endif
        return health(of: providerID).status(isOnline: isOnline)
    }
}
