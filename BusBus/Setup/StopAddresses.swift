import SwiftUI
import MapKit

/// Street addresses for stops the provider gave none for, looked up from their coordinates.
///
/// A provider's own address always wins (see `TransitStop.address`); this is the fallback. Apple's
/// geocoder throttles an app that asks too fast (`MKError.loadingThrottled`), so lookups run one at
/// a time, spaced out, and pause when Apple says to. Each stop is asked about once per language for
/// as long as the app runs.
@MainActor final class StopAddresses {
    static let shared = StopAddresses()

    private enum Outcome {
        case found(String)
        /// The geocoder answered and had nothing. Remembered, so it is not asked again.
        case none
        /// The network, or the throttle outlasting its retry. Not remembered, so the next showing
        /// tries again.
        case failed
    }

    /// Apple publishes no number, but asks for well under one request a second; this keeps a
    /// screen of rows at a steady trickle rather than a burst.
    private static let spacing: Duration = .milliseconds(1_200)
    /// How long to stand back after Apple says it is being asked too often.
    private static let backoff: Duration = .seconds(60)

    private var cache: [String: String?] = [:]
    private var pending: [String: Task<Outcome, Never>] = [:]
    /// The last lookup queued; each new one waits for it.
    private var tail: Task<Void, Never>?
    private var nextAllowed: ContinuousClock.Instant = .now

    func address(for stop: TransitStop) async -> String? {
        let locale = AppLanguage.locale
        let key = "\(locale.identifier)|\(stop.code)|\(stop.location.lat),\(stop.location.lon)"
        if let cached = cache[key] { return cached }

        let task: Task<Outcome, Never>
        if let existing = pending[key] {
            task = existing
        } else {
            let previous = tail
            task = Task { () -> Outcome in
                await previous?.value
                return await self.throttledLookUp(stop.location, locale: locale)
            }
            tail = Task { _ = await task.value }
            pending[key] = task
        }

        let outcome = await task.value
        pending[key] = nil
        switch outcome {
        case .found(let address):
            cache[key] = .some(address)
            return address
        case .none:
            cache[key] = .some(nil)
            return nil
        case .failed:
            return nil
        }
    }

    /// Waits its turn, asks, and on a throttle stands back once and asks again.
    private func throttledLookUp(_ point: GeoPoint, locale: Locale) async -> Outcome {
        for attempt in 0..<2 {
            let wait = nextAllowed - .now
            if wait > .zero { try? await Task.sleep(for: wait) }
            nextAllowed = .now + Self.spacing
            switch await Self.lookUp(point, locale: locale) {
            case .throttled:
                nextAllowed = .now + Self.backoff
                if attempt == 0 { continue }
                return .failed
            case .answered(let outcome):
                return outcome
            }
        }
        return .failed
    }

    private enum Reply {
        case answered(Outcome)
        case throttled
    }

    private static func lookUp(_ point: GeoPoint, locale: Locale) async -> Reply {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: point.lat, longitude: point.lon)) else {
            return .answered(.none)
        }
        request.preferredLocale = locale
        do {
            guard let item = try await request.mapItems.first else { return .answered(.none) }
            let line = item.address?.shortAddress
                ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            guard let line, !line.isEmpty else { return .answered(.none) }
            return .answered(.found(line))
        } catch let error as MKError where error.code == .loadingThrottled {
            return .throttled
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .answered(.none)
        } catch {
            return .answered(.failed)
        }
    }
}

/// The address line under a stop's name: the provider's address when it has one, otherwise
/// Apple's, with the stop's town standing in until that arrives. It keeps its line even when
/// empty so rows do not jump as addresses arrive.
extension StopAddresses {
    /// The first that says something the name does not: provider, then Apple, then the town.
    nonisolated static func text(for stop: TransitStop, lookedUp: String?) -> String? {
        [stop.address, lookedUp, stop.city].compactMap { $0 }.first { !sameText($0, stop.name) }
    }

    /// Apple is asked only when the provider had nothing, or only the name again.
    nonisolated static func needsLookup(_ stop: TransitStop) -> Bool {
        guard let own = stop.address else { return true }
        return sameText(own, stop.name)
    }

    /// Several feeds put the stop's own name in the address field; that line would say nothing.
    private nonisolated static func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces)
            .compare(b.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

struct StopAddressLine: View {
    @Environment(\.theme) private var theme
    var stop: TransitStop
    var compact: Bool
    var scale: CGFloat
    @State private var looked: String?

    private var text: String? { StopAddresses.text(for: stop, lookedUp: looked) }

    var body: some View {
        Text(text ?? " ")
            .busText(compact ? TypeStyles.stopAddressPhone : TypeStyles.stopAddress, scale: scale)
            .foregroundStyle(theme.dashCaption)
            .lineLimit(1)
            .truncationMode(.tail)
            // Takes whatever width the name leaves and never asks for more, so a long street does
            // not cost the row a line badge.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .task(id: stop.id) {
                guard StopAddresses.needsLookup(stop) else { return }
                looked = await StopAddresses.shared.address(for: stop)
            }
    }
}
