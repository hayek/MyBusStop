import Foundation
import FirebaseAnalytics
import FirebaseAppCheck
import FirebaseCore
import FirebaseCrashlytics
import DeviceCheck
import os

/// The one door to Firebase. Everything here is a quiet no-op until `start()` has configured an app,
/// so a checkout without `GoogleService-Info.plist`, and every test run, never talks to Google.
nonisolated enum Telemetry {
    static var isConfigured: Bool { FirebaseApp.app() != nil }

    /// Configures Firebase once at launch. Skipped under XCTest so tests hosted in the app stay offline.
    @MainActor static func start() {
        guard !isConfigured,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
        else { return }
        // Before `configure()`: App Check reads its factory once, when the app is created.
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AttestedAppCheckFactory())
        #endif
        FirebaseApp.configure()
        // Debug builds are the developer's own devices and simulators, and would swamp the real
        // riders in every report; Crashlytics still hears from them. The choice is persisted, so
        // Release says it again: a store build installed over a debug one keeps its container.
        #if DEBUG
        Analytics.setAnalyticsCollectionEnabled(false)
        #else
        Analytics.setAnalyticsCollectionEnabled(true)
        #endif
        // The transit layer asks for tokens through this hook rather than importing App Check, so
        // the widget can share it without linking Firebase.
        TransitProxy.attestation.withLock { $0 = { _ in await appCheckToken() } }
        #if DEBUG
        logDebugToken()
        #endif
    }

    #if DEBUG
    /// The simulator cannot attest, so Debug builds use App Check's debug provider. Its token is
    /// only accepted once registered: Firebase console → App Check → Apps → BusBus iOS → ⋮ →
    /// Manage debug tokens → Add. It is stable per install (or fixed with the scheme's
    /// `FIRAAppCheckDebugToken` environment variable).
    @MainActor private static func logDebugToken() {
        guard let app = FirebaseApp.app(), let provider = AppCheckDebugProvider(app: app) else { return }
        let token = provider.currentDebugToken()
        Logger(subsystem: "com.hayek.BusBus", category: "proxy").notice(
            "App Check debug token: \(token, privacy: .public) — register it in the Firebase console (App Check → Apps → BusBus iOS → Manage debug tokens) to use the transit proxy from this device.")
        print("[BusBus] App Check debug token: \(token) — register it in Firebase console → App Check → Apps → BusBus iOS → Manage debug tokens")
    }
    #endif

    /// A token for our transit proxy, or nil when attestation fails. The SDK caches it until it
    /// nears expiry, so asking per request is cheap.
    private static func appCheckToken() async -> String? {
        do {
            return try await AppCheck.appCheck().token(forcingRefresh: false).token
        } catch {
            Logger(subsystem: "com.hayek.BusBus", category: "proxy").error(
                "App Check token unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A non-fatal: something went wrong that the rider survived, but we want to see it.
    static func record(_ error: Error, context: [String: Any] = [:]) {
        guard isConfigured else { return }
        Crashlytics.crashlytics().record(error: error, userInfo: context)
    }

    static func log(_ event: String, _ params: [String: Any] = [:]) {
        guard isConfigured else { return }
        Analytics.logEvent(event, parameters: params.isEmpty ? nil : params)
    }

    /// The screen in front of the rider, for GA's screens report and its path explorations. Firebase
    /// reports view controllers by itself, not SwiftUI views, so each screen names itself.
    static func screen(_ name: String) {
        log(AnalyticsEventScreenView, [AnalyticsParameterScreenName: name, AnalyticsParameterScreenClass: name])
    }

    /// Sticks to every later event from this rider, so any report can be split by it.
    static func setUserProperty(_ value: String?, for name: String) {
        guard isConfigured else { return }
        Analytics.setUserProperty(value, forName: name)
    }

    /// A transit feed that failed us. Crashlytics groups non-fatals by domain and code, so the code
    /// is derived from the provider id alone: each provider gets its own issue, whatever the endpoint.
    static func serviceOutage(providerID: String, endpoint: String, error: Error) {
        guard isConfigured else { return }
        let outage = NSError(domain: "BusBus.ServiceOutage", code: outageCode(for: providerID), userInfo: [
            NSLocalizedDescriptionKey: "\(providerID) unavailable",
            "provider": providerID,
            "endpoint": endpoint,
            "error": String(describing: error),
        ])
        Crashlytics.crashlytics().record(error: outage)
        // Analytics caps parameter values at 100 characters.
        log("service_outage", ["provider_id": providerID, "endpoint": String(endpoint.prefix(100))])
    }

    /// One failed request from a transit feed, as soon as it happens rather than three refreshes
    /// later. Grouped per provider and endpoint, so a broken timetable and a broken search are
    /// separate issues; the outage above still marks when riders were actually shown it.
    ///
    /// Custom keys stop at 1 KB, so the reply's full body goes to the Crashlytics log, which is sent
    /// with this report (Logs tab); the key keeps its first kilobyte for the issue list.
    static func providerFailure(providerID: String, endpoint: String, description: String, reply: ResponseError?) {
        guard isConfigured else { return }
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: "\(providerID) \(endpoint) failed",
            "provider": providerID,
            "endpoint": endpoint,
            "error": description,
        ]
        let crashlytics = Crashlytics.crashlytics()
        if let reply {
            info["url"] = reply.url
            info["status"] = reply.status
            info["response"] = String(reply.body.prefix(1000))
            crashlytics.log("\(providerID) \(endpoint) → HTTP \(reply.status) \(reply.url)")
            // One log line per chunk: a single enormous line is harder to read and to search.
            var rest = Substring(reply.body)
            while !rest.isEmpty {
                crashlytics.log(String(rest.prefix(4000)))
                rest = rest.dropFirst(4000)
            }
        }
        let failure = NSError(domain: "BusBus.ProviderFailure", code: outageCode(for: "\(providerID)/\(endpoint)"),
                              userInfo: info)
        crashlytics.record(error: failure)
    }

    /// FNV-1a, because `hashValue` is reseeded every launch and would scatter one provider across issues.
    static func outageCode(for providerID: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in providerID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash & 0x7FFF_FFFF)
    }
}

#if !DEBUG
/// App Attest where the device supports it, DeviceCheck otherwise. Release only: App Attest cannot
/// attest a simulator, which is why Debug uses the debug provider instead.
private final class AttestedAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if DCAppAttestService.shared.isSupported, let provider = AppAttestProvider(app: app) {
            return provider
        }
        return DeviceCheckProvider(app: app)
    }
}
#endif
