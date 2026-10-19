import Foundation

/// Which provider a widget may ask for a saved setup's arrivals, if any. The board's rules, as far
/// as a widget can follow them without Firebase: no provider switched off remotely, none without
/// its key, and none a widget cannot afford to call.
nonisolated enum WidgetProviderGate {
    /// Providers the widget never calls itself. MTA Bus Time goes through our proxy, which wants an
    /// App Check token the widget cannot mint without Firebase; Metro Transit inflates a GTFS
    /// archive in memory, more than a widget is allowed. Both still show what the app last saw.
    static let snapshotOnly: Set<String> = ["mta-bustime", "metrotransit"]

    /// What an entry saved before providers followed location was taken from.
    static let legacyProviderID = "bus.gov.il"

    /// Switched off until the app says otherwise (`SharedHistoryStore.disabledProviders()`):
    /// Transitous forbids commercial use unless its own remote flag is on.
    static let offUntilMirrored: Set<String> = [TransitousProvider.providerID]

    /// Whether only the app ever has numbers for this setup: a complication can only say to open it.
    static func isSnapshotOnly(_ setup: SavedSetup) -> Bool {
        snapshotOnly.contains(setup.providerID ?? legacyProviderID)
    }

    /// `disabled` is what the app mirrored of the remote switches, or nil before it ever has.
    static func provider(for setup: SavedSetup, disabled: Set<String>?,
                         among providers: [any TransitProvider] = TransitProviders.all) -> (any TransitProvider)? {
        let id = setup.providerID ?? legacyProviderID
        guard !(disabled ?? offUntilMirrored).contains(id), !snapshotOnly.contains(id),
              // An unknown id names no provider: never the fallback one, which would be asked
              // about a stop it has never heard of.
              let provider = providers.first(where: { $0.id == id }),
              provider.hasRequiredAPIKey else { return nil }
        return provider
    }
}
