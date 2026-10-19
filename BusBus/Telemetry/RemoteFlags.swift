import Foundation
import Observation
import FirebaseRemoteConfig

/// Switches we can flip from the Firebase console without shipping a build: pull a provider whose
/// feed has gone bad, hide the experimental ones, or put a line of news in front of riders.
/// Until a fetch lands, or forever without Firebase, the in-app defaults hold and nothing is disabled.
@MainActor @Observable final class RemoteFlags {
    static let shared = RemoteFlags()

    private enum Key {
        static let disabledProviders = "disabled_providers"
        static let experimentalProvidersEnabled = "experimental_providers_enabled"
        static let serviceStatusMessage = "service_status_message"
        static let transitousEnabled = "transitous_enabled"
        static let transitProxyURL = "transit_proxy_url"
    }

    private(set) var disabledProviders: Set<String> = []
    private(set) var experimentalProvidersEnabled = true
    private(set) var serviceStatusMessage = ""
    /// Whether a rider outside every supported region falls back to Transitous. Off unless switched
    /// on remotely: its policy forbids commercial use, so a paid build must never turn it on.
    private(set) var transitousEnabled = false
    /// Base URL of the key-holding transit proxy (`TransitProxy`); empty switches it off, which makes
    /// the keyed providers unavailable in Release. Not a secret.
    private(set) var transitProxyURL = TransitProxy.defaultBaseURL
    /// Goes up each time fetched values are applied, for whatever copies them elsewhere (the
    /// widget's mirror, `SettingsStore.mirrorProviderSwitches`).
    private(set) var revision = 0

    func activate() async {
        guard Telemetry.isConfigured else { return }
        let config = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        config.configSettings = settings
        config.setDefaults([
            Key.disabledProviders: "" as NSString,
            Key.experimentalProvidersEnabled: true as NSNumber,
            Key.serviceStatusMessage: "" as NSString,
            Key.transitousEnabled: false as NSNumber,
            Key.transitProxyURL: TransitProxy.defaultBaseURL as NSString,
        ])
        do {
            _ = try await config.fetchAndActivate()
        } catch {
            // Offline or throttled: whatever was activated last time (or the defaults) still applies.
            Telemetry.record(error, context: ["where": "RemoteFlags.activate"])
        }
        apply(config)
    }

    func isEnabled(providerID: String, experimental: Bool) -> Bool {
        if disabledProviders.contains(providerID) { return false }
        return !experimental || experimentalProvidersEnabled
    }

    private func apply(_ config: RemoteConfig) {
        disabledProviders = Set(
            config.configValue(forKey: Key.disabledProviders).stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        experimentalProvidersEnabled = config.configValue(forKey: Key.experimentalProvidersEnabled).boolValue
        serviceStatusMessage = config.configValue(forKey: Key.serviceStatusMessage).stringValue
        transitousEnabled = config.configValue(forKey: Key.transitousEnabled).boolValue
        transitProxyURL = config.configValue(forKey: Key.transitProxyURL).stringValue
        TransitProxy.configure(baseURL: transitProxyURL)
        revision += 1
    }
}
