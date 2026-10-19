import Foundation
@testable import BusBus

/// Every provider the app ships, with its real-world smoke route. Adding a region means adding a
/// provider to `TransitProviders.all`, a region to `SupportedRegions.all`, and a fixture here.
nonisolated enum LiveFixtures {
    static let all: [LiveFixture] = [
        .busGovIL,
        .mbta,
        .metroTransit,
        .mtaBusTime,
        .pugetSound,
        .tampa,
        .carris,
        .starRennes,
        .stib,
        .entur,
        .foli,
        .tampere,
        .poznan,
        .mtrBus,
        .kmb,
        .citybus,
        .gmb,
        .nlb,
        .tfl,
        .wienerLinien,
        .toei,
        .adelaide,
        .efaLinz,
        .gdansk,
        .krakow,
        .iett,
        .ttc,
        .tallinn,
        .vilnius,
        .kaunas,
        .swiss,
        .vag,
        .lpp,
        .luxembourg,
        .vbb,
        .bizkaibus,
        // No region: the worldwide fallback, behind the `transitous_enabled` flag.
        .transitous,
    ]

    /// The fixtures whose provider can run here: a keyed provider without its key (no
    /// Config/Secrets.xcconfig, nothing in the Keychain) is skipped rather than failed.
    static var runnable: [LiveFixture] { all.filter(\.provider.hasRequiredAPIKey) }

    /// Providers skipped for want of a key, by the key they need.
    static var missingKeys: [String] {
        all.filter { !$0.provider.hasRequiredAPIKey }.map { "\($0.provider.id) (\($0.provider.requiredAPIKey ?? ""))" }
    }
}
