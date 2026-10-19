import Foundation
import os

/// Our key-holding proxy for the transit feeds that need a key (functions/src, `transitProxy`).
///
/// The app never holds those keys in Release: it calls `<baseURL>/<agency>/<path>` instead, and the
/// proxy adds the key, caches, and rate-limits. Every request carries a fresh App Check token, which
/// is how the proxy knows the caller is a genuine build of this app — and the host check below is
/// what keeps that token from going anywhere else.
///
/// The base URL is not a secret. It defaults to the deployed function and can be moved (or, set to
/// an empty string, switched off) with the Remote Config parameter `transit_proxy_url`.
nonisolated enum TransitProxy {
    static let defaultBaseURL = "https://us-central1-busbus-ios.cloudfunctions.net/transitProxy"

    private static let state = OSAllocatedUnfairLock<String>(initialState: defaultBaseURL)

    /// The configured base, or nil when the proxy is switched off.
    static var baseURL: String? {
        let value = state.withLock { $0 }
        return value.isEmpty ? nil : value
    }

    /// Applies a Remote Config value. Empty switches the proxy off; anything that is not an https
    /// URL is ignored in favour of the default, so a typo in the console cannot strand riders.
    static func configure(baseURL value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.isEmpty {
            resolved = ""
        } else if let url = URL(string: trimmed), url.scheme == "https", url.host != nil {
            resolved = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        } else {
            resolved = defaultBaseURL
        }
        state.withLock { $0 = resolved }
    }

    /// `<base>/<agency>`, the base URL a provider appends its upstream paths to.
    static func url(forAgency agency: String) -> String? {
        baseURL.map { "\($0)/\(agency)" }
    }

    #if DEBUG
    /// Debug only: `BUSBUS_USE_PROXY=1` sends keyed providers through the proxy even when a local
    /// key is present, to exercise the Release path (and App Check's debug provider) locally.
    static var isForcedInDebug: Bool {
        ProcessInfo.processInfo.environment["BUSBUS_USE_PROXY"] == "1"
    }
    #endif

    /// Hosts that receive an App Check token: the configured proxy's and the default's. Nothing else.
    static func isProxyHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        let hosts = [baseURL, defaultBaseURL].compactMap { $0.flatMap(URL.init(string:))?.host?.lowercased() }
        return hosts.contains(host)
    }

    /// Mints an App Check token. Set by `Telemetry.start()` once Firebase is configured; until then,
    /// and always in the widget, which links no Firebase at all, requests go without one.
    static let attestation = OSAllocatedUnfairLock<(@Sendable (URL) async -> String?)?>(initialState: nil)

    /// A fresh App Check token for a request to the proxy, or nil for any other host or when
    /// attestation is unavailable (the proxy then answers 401, surfaced as the provider failing).
    ///
    /// The SDK caches the token until it nears expiry, so asking per request is cheap.
    static func appCheckToken(for url: URL?) async -> String? {
        guard let url, isProxyHost(url), let attest = attestation.withLock({ $0 }) else { return nil }
        return await attest(url)
    }
}
