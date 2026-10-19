import SwiftUI
import CoreLocation
import Observation
import os

/// One location fix, for the NEARBY list. Permission is asked for once, from the rider's own tap on
/// the NEARBY card, never on open; when it is refused the screen says so and falls back to search
/// rather than nagging.
@MainActor @Observable final class LocationService {
    private nonisolated static let log = Logger(subsystem: "com.hayek.BusBus", category: "location")

    /// The system's side of it: the permission, and one fix. Tests stand in for it.
    struct Source {
        var status: @MainActor () -> CLAuthorizationStatus
        var requestPermission: @MainActor () -> Void
        /// One fix, or nil when none comes within the timeout or location is refused.
        var fix: @MainActor (_ timeout: Duration) async -> GeoPoint?
        /// Hands over what to call whenever the answer changes, including in Settings while the app
        /// is away. A Mac's window can stay active the whole time the rider is in System Settings,
        /// so the return to the app is not a moment either platform can rely on to look again.
        var observeAuthorization: @MainActor (_ onChange: @escaping @MainActor () -> Void) -> Void = { _ in }
    }

    private let source: Source
    private(set) var status: CLAuthorizationStatus
    private(set) var current: GeoPoint?
    /// The fix being looked for. A second caller waits on it rather than starting another, or
    /// giving up because one is already running.
    private var inFlight: Task<Void, Never>?
    var isLocating: Bool { inFlight != nil }

    init(source: Source = .system()) {
        self.source = source
        status = source.status()
        source.observeAuthorization { [weak self] in self?.refreshStatus() }
    }

    var isDenied: Bool { status == .denied || status == .restricted }
    /// Turned off by the device's owner — Screen Time, or a school's or employer's management —
    /// rather than by the rider, so Settings is no way back for them.
    var isRestricted: Bool { status == .restricted }
    /// The rider has not been asked yet.
    var needsPermission: Bool { status == .notDetermined }

    /// Picks up an answer given in Settings while the app was away.
    func refreshStatus() {
        status = source.status()
    }

    func locateOnce(timeout: Duration = .seconds(15)) async {
        if ScreenshotMode.current != nil {
            current = ScreenshotMode.location
            return
        }
        if let inFlight {
            await inFlight.value
            return
        }
        guard !isDenied else { return }
        // Unstructured, so a caller that goes away (the picker leaving the screen) does not take a
        // request the system alert is still showing for with it.
        let task = Task { await locate(timeout: timeout) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// How long the rider may take over the permission alert before the request stops waiting.
    static let answerWait: Duration = .seconds(300)

    private func locate(timeout: Duration) async {
        if source.status() == .notDetermined {
            source.requestPermission()
            // The timeout counts from the rider's answer: time spent reading the system alert is not
            // time spent failing to find them.
            let asked = ContinuousClock.now
            while source.status() == .notDetermined, ContinuousClock.now - asked < Self.answerWait {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        status = source.status()
        guard !isDenied, !needsPermission else { return }
        if let point = await source.fix(timeout) { current = point }
        status = source.status()
    }
}

extension LocationService.Source {
    static func system() -> Self {
        let manager = CLLocationManager()
        // Kept alive by the closures below: a location manager holds its delegate weakly.
        let observer = AuthorizationObserver()
        manager.delegate = observer
        return Self(status: { manager.authorizationStatus },
                    requestPermission: { manager.requestWhenInUseAuthorization() },
                    fix: { timeout in
                        #if os(tvOS)
                        // Apple TV has no stream of updates: one request, answered once.
                        await OneShotLocator().fix(timeout: timeout)
                        #else
                        await LocationService.liveFix(timeout: timeout)
                        #endif
                    },
                    observeAuthorization: { observer.onChange = $0 })
    }
}

/// Core Location's word that the answer changed. It is delivered on the thread the manager was made
/// on, the main one, and passed straight on there.
private final class AuthorizationObserver: NSObject, CLLocationManagerDelegate {
    var onChange: (@MainActor () -> Void)?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange?() }
    }
}

extension LocationService {
    /// Where the rider turns location back on: BusBus's own page in the Settings app, or on a Mac
    /// the Location Services list in System Settings, which has no page per app.
    static var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

extension LocationService {
    /// The first fix Core Location gives, or nil when it refuses or `timeout` passes first.
    fileprivate static func liveFix(timeout: Duration) async -> GeoPoint? {
        await withTaskGroup(of: GeoPoint?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location {
                            return GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
                        }
                        if update.authorizationDenied || update.authorizationRestricted { return nil }
                    }
                } catch {
                    log.warning("location failed: \(error.localizedDescription, privacy: .public)")
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

#if os(tvOS)
/// One fix from `requestLocation()`, the only kind Apple TV gives: a rough position from its
/// network, answered once or failed.
@MainActor private final class OneShotLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<GeoPoint?, Never>?

    func fix(timeout: Duration) async -> GeoPoint? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(nil)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ point: GeoPoint?) {
        continuation?.resume(returning: point)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let point = locations.last.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task { @MainActor in self.finish(point) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
#endif
