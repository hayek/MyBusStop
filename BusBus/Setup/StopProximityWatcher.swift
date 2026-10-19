import CoreLocation
import Observation
import SwiftUI

/// A stop the rider is standing at, offered over whatever screen is up.
nonisolated struct StopNearbyAlert: Identifiable, Hashable, Sendable {
    var stop: TransitStop
    /// Whose stop it is: where the rider is standing, not where setup last browsed.
    var providerID: String
    /// The lines the rider watched here before, or every line through the stop when they never have.
    var lines: [TransitLine]
    /// The rider's own board for this stop, when they have set one up here before.
    var saved: SavedSetup?

    var id: String { stop.code }
}

/// When the rider counts as being at a stop, and which of their boards belongs to it.
nonisolated enum StopProximity {
    /// Close enough to be waiting at the stop rather than walking past it.
    static let arrivalRadius: Double = 40
    /// Far enough away that coming back is arriving again.
    static let departureRadius: Double = 150
    /// How far around a fix to ask for stops. The cache answers any fix in the same ~0.001° cell
    /// (up to about 160 m across, corner to corner) with the list fetched for the first one, so this
    /// covers that and the arrival radius beyond it.
    static let searchRadius: Double = 200
    /// A fix this close to the last one looked at says nothing new — unless it is sharper.
    static let minimumMove: Double = 20
    /// A fix this much surer than the last one looked at is looked at again from the same spot: the
    /// first usable fix is often the vaguest, and may have put the rider just out of a stop's reach.
    static let minimumSharpening: Double = 10
    /// A fix vaguer than this cannot say which stop the rider is at — nor can an approximate one.
    static let maximumUncertainty: Double = 50
    /// Faster than a brisk walk: riding past, not waiting at a stop.
    static let maximumSpeed: Double = 3

    /// Whether a fix of `uncertainty` says more than the last one looked at, of `previous`. A fix of
    /// no stated uncertainty never does.
    static func isSharper(_ uncertainty: Double?, than previous: Double?) -> Bool {
        guard let uncertainty else { return false }
        guard let previous else { return true }
        return uncertainty <= previous - minimumSharpening
    }

    /// The closest stop within the arrival radius, measured from the fix rather than taken from the
    /// list's own distances, which may be from where an earlier fix fetched it.
    static func stop(at point: GeoPoint, among stops: [NearbyStop]) -> NearbyStop? {
        stops.map { ($0, point.distance(to: $0.stop.location)) }
            .filter { $0.1 <= arrivalRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// The board the rider set up at this stop most recently. Entries saved before providers
    /// followed location have none, and are taken to be from the stop's.
    static func savedSetup(at stop: TransitStop, providerID: String, in history: [SavedSetup]) -> SavedSetup? {
        history.filter { $0.stop.code == stop.code && ($0.providerID ?? providerID) == providerID }
            .max { $0.lastUsedAt < $1.lastUsedAt }
    }
}

/// Follows the rider while the app is in front, and offers the stop they are standing at.
///
/// Never asks for location: it only runs once the rider has allowed it, from the stop list. Each
/// stop is offered once per arrival — not again until the rider has walked away and come back —
/// and never the stop already on the board.
@MainActor @Observable final class StopProximityWatcher {
    private let settings: SettingsStore
    private let cache: TransitCache

    /// The stop on offer, or nil.
    private(set) var alert: StopNearbyAlert?

    /// The stops offered on this arrival. Each is not offered again until the rider has left it, so
    /// two stops across the street from each other are not offered by turns as the fix wanders.
    @ObservationIgnored private var offered: [TransitStop] = []
    @ObservationIgnored private var lastLooked: GeoPoint?
    @ObservationIgnored private var lastLookedUncertainty: Double?

    init(settings: SettingsStore, cache: TransitCache = .shared) {
        self.settings = settings
        self.cache = cache
    }

    #if !os(tvOS)
    /// Looks at every fix until cancelled. Only called with location already allowed: Core
    /// Location's live updates would otherwise ask for it themselves.
    func watch() async {
        // An offer left from before the app went away may be miles from where the rider is now.
        defer { alert = nil }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                guard !Task.isCancelled else { return }
                guard let location = update.location, Self.isUsable(location) else { continue }
                await look(at: GeoPoint(location.coordinate), uncertainty: location.horizontalAccuracy)
            }
        } catch {
            // Updates ended; the next time the app is in front starts them again.
        }
    }

    /// The rider pulled the board to refresh it: looks again from a fix taken now, even without a
    /// move. Live updates pause while the rider stands still, and the fix they paused on may be one
    /// from before it settled. A stop already offered on this arrival is still not offered again.
    func lookAgain() async {
        guard let location = await Self.freshFix(timeout: .seconds(10)) else { return }
        await look(at: GeoPoint(location.point), uncertainty: location.uncertainty, force: true)
    }

    /// Precise enough to tell which stop the rider is at, and slow enough to be waiting at one.
    private nonisolated static func isUsable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= StopProximity.maximumUncertainty
            && location.speed <= StopProximity.maximumSpeed
    }

    /// The first usable fix from a stream of its own, or nil when none comes within `timeout`.
    private static func freshFix(timeout: Duration) async -> (point: CLLocationCoordinate2D, uncertainty: Double)? {
        await withTaskGroup(of: (point: CLLocationCoordinate2D, uncertainty: Double)?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, isUsable(location) {
                            return (location.coordinate, location.horizontalAccuracy)
                        }
                        if update.authorizationDenied || update.authorizationRestricted { return nil }
                    }
                } catch {}
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
    #endif

    /// Offers the stop at `point`, if there is one the rider has not just been offered.
    /// - Parameters:
    ///   - uncertainty: how far off the fix may be, in metres, when known.
    ///   - force: looks even when the rider has not moved, as a pull to refresh asks to.
    func look(at point: GeoPoint, uncertainty: Double? = nil, force: Bool = false) async {
        if !force, let lastLooked, lastLooked.distance(to: point) < StopProximity.minimumMove,
           !StopProximity.isSharper(uncertainty, than: lastLookedUncertainty) { return }
        lastLooked = point
        lastLookedUncertainty = uncertainty
        offered.removeAll { point.distance(to: $0.location) > StopProximity.departureRadius }
        if let shown = alert?.stop.code, !offered.contains(where: { $0.code == shown }) { alert = nil }
        // Whose stops are where the rider stands — as setup would pick them, without switching it.
        guard let providerID = settings.providerOverride?.id ?? settings.providerID(at: point) else { return }
        let provider = settings.provider(id: providerID)
        guard provider.capabilities.contains(.nearbyStops) else { return }
        let radius = StopProximity.searchRadius
        let stops: [NearbyStop]
        do {
            stops = try await cache.nearby(around: point, radiusMeters: radius, providerID: provider.datasetID) {
                try await provider.stopsNearby(point, radiusMeters: radius)
            }
        } catch {
            // Not looked at after all: the next fix, even from the same spot, tries again.
            lastLooked = nil
            lastLookedUncertainty = nil
            return
        }
        guard let entry = StopProximity.stop(at: point, among: stops),
              !offered.contains(where: { $0.code == entry.stop.code }),
              entry.stop.code != settings.configuration?.stop.code else { return }
        offered.append(entry.stop)
        let saved = StopProximity.savedSetup(at: entry.stop, providerID: providerID, in: settings.savedSetups)
        var lines = saved?.lines ?? entry.lines
        if lines.isEmpty, provider.capabilities.contains(.linesAtStop) {
            lines = (try? await cache.lines(atStop: entry.stop, providerID: provider.datasetID) {
                try await provider.lines(atStop: entry.stop)
            }) ?? []
            lines.sort { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
        }
        alert = StopNearbyAlert(stop: entry.stop, providerID: providerID, lines: lines, saved: saved)
    }

    /// Puts the offer away. The stop is still the one offered, so it does not come straight back.
    func dismiss() {
        alert = nil
    }
}
