import Foundation

/// API keys for the transit feeds that need one. No key is ever committed, compiled into or bundled
/// with a Release build.
///
/// - Release: there is no key source at all. Keyed providers go through our server-side proxy,
///   which holds the keys (`TransitProxy`, functions/), and are unavailable while it is switched off
///   (see `KeyedEndpoint`).
/// - Debug: the Info.plist's `BusBusAPIKeys` entry, filled only in the Debug configuration from the
///   gitignored Config/Secrets.xcconfig, or else the environment's `BUSBUS_<NAME>` (the live probe
///   and test runs, exported from the Keychain by scripts/api-keys.sh). Compiled out of Release.
nonisolated enum APIKeys {
    struct Sources: OptionSet, Sendable {
        let rawValue: Int
        /// Info.plist and environment. Debug builds only.
        static let local = Sources(rawValue: 1 << 0)

        /// Where a Release build looks: nowhere.
        static let release: Sources = []
    }

    #if DEBUG
    static let buildSources: Sources = [.local]
    #else
    static let buildSources: Sources = .release
    #endif

    static let infoDictionaryKey = "BusBusAPIKeys"

    /// The key named `name` (`MTA_BUSTIME_KEY`), or nil when absent or empty — always nil in Release.
    static func key(_ name: String) -> String? {
        resolve(name, from: buildSources)
    }

    static func resolve(_ name: String, from sources: Sources) -> String? {
        #if DEBUG
        if sources.contains(.local) { return localKey(name) }
        #endif
        return nil
    }

    #if DEBUG
    private static func localKey(_ name: String) -> String? {
        let bundled = (Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? [String: Any])?[name] as? String
        return usable(bundled) ?? usable(ProcessInfo.processInfo.environment["BUSBUS_\(name)"])
    }

    /// Empty, whitespace, or a build setting that was never expanded ("$(MTA_BUSTIME_KEY)") is no key.
    private static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
    #endif
}

/// Where a keyed provider sends its requests, and how they are authenticated.
///
/// - `.keyed(…)`, what shipping providers use: in Release always our proxy (`TransitProxy`), which
///   adds the key server-side; in Debug the operator's API with the local key when there is one
///   (else the proxy too — or always, with `BUSBUS_USE_PROXY=1`). Resolved per request, so a
///   Remote Config change to the proxy URL applies without a relaunch.
/// - `.direct(…)`: the operator's API with our key, never a proxy.
/// - `.proxy(url)`: a fixed server that authenticates upstream itself; the app sends no key.
nonisolated struct KeyedEndpoint: Sendable {
    /// The operator's API, used when the request carries the key itself.
    var directURL: String?
    /// The query parameter carrying the key, when the request itself must carry one.
    var keyParameter: String?
    /// The `APIKeys` name of that key; nil when the endpoint needs none (a fixed proxy).
    var keyName: String?
    /// The agency's route on `TransitProxy` (`mta`), when it may go through it.
    var proxyAgency: String?
    /// A fixed proxy base, overriding everything else.
    var fixedProxyURL: String?

    /// The operator's API, called with our key.
    static func direct(_ baseURL: String, keyParameter: String, keyName: String) -> KeyedEndpoint {
        KeyedEndpoint(directURL: baseURL, keyParameter: keyParameter, keyName: keyName)
    }

    /// A server that authenticates upstream itself; the app sends no key.
    static func proxy(_ baseURL: String) -> KeyedEndpoint {
        KeyedEndpoint(fixedProxyURL: baseURL)
    }

    /// Our proxy's `agency` route in Release; in Debug the direct API when a local key exists.
    static func keyed(_ baseURL: String, keyParameter: String, keyName: String, proxyAgency: String) -> KeyedEndpoint {
        KeyedEndpoint(directURL: baseURL, keyParameter: keyParameter, keyName: keyName, proxyAgency: proxyAgency)
    }

    /// Where one request goes and the query items that authenticate it.
    struct Resolved: Equatable, Sendable {
        var baseURL: String
        var authQuery: [String: String]
    }

    /// Throws `missingAPIKey` when this build can reach the API neither with a key nor through the proxy.
    func resolve() throws -> Resolved {
        #if DEBUG
        let localKey = keyName.flatMap(APIKeys.key)
        let forceProxy = TransitProxy.isForcedInDebug
        #else
        let localKey: String? = nil
        let forceProxy = true
        #endif
        return try resolve(localKey: localKey, proxyBaseURL: TransitProxy.baseURL, forceProxy: forceProxy)
    }

    /// The decision itself, with every input explicit (tested directly).
    func resolve(localKey: String?, proxyBaseURL: String?, forceProxy: Bool) throws -> Resolved {
        if let fixedProxyURL { return Resolved(baseURL: fixedProxyURL, authQuery: [:]) }
        if let directURL, let keyParameter, let localKey, !forceProxy || proxyAgency == nil {
            return Resolved(baseURL: directURL, authQuery: [keyParameter: localKey])
        }
        if let proxyAgency, let proxyBaseURL {
            return Resolved(baseURL: "\(proxyBaseURL)/\(proxyAgency)", authQuery: [:])
        }
        throw TransitError.missingAPIKey(keyName ?? "unknown")
    }

    /// The key this build lacks to reach the API, or nil when it can (keyless, keyed, or proxied).
    var unmetKey: String? {
        (try? resolve()) == nil ? keyName : nil
    }

    /// The query items that authenticate one request. Throws `missingAPIKey` when a key is needed
    /// and this build has none.
    func authQuery() throws -> [String: String] {
        try resolve().authQuery
    }
}
