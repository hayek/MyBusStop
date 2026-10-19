import Testing
import Foundation
@testable import BusBus

struct APIKeysTests {
    /// A shipped build has no key source at all: whatever the bundle or environment holds, nothing
    /// is found, and a keyed provider stays unavailable until it goes through the proxy.
    @Test func releaseHasNoKeySource() {
        setenv("BUSBUS_RELEASE_PROBE_KEY", "local-key", 1)
        defer { unsetenv("BUSBUS_RELEASE_PROBE_KEY") }
        #expect(APIKeys.Sources.release.isEmpty)
        #expect(APIKeys.resolve("RELEASE_PROBE_KEY", from: .release) == nil)
        // The unit tests themselves are a Debug build, which reads the local key.
        #expect(APIKeys.resolve("RELEASE_PROBE_KEY", from: [.local]) == "local-key")
    }

    @Test func anUnknownKeyIsNil() {
        #expect(APIKeys.key("NO_SUCH_KEY") == nil)
    }

    @Test func keylessProvidersNeedNothing() {
        #expect(MBTAProvider().requiredAPIKey == nil)
        #expect(MBTAProvider().hasRequiredAPIKey)
    }

    /// A keyed endpoint: the local key when this build has one, else the proxy's agency route with no
    /// key; Release (`forceProxy`) always the proxy; neither available → `missingAPIKey`.
    @Test func aKeyedEndpointPrefersTheLocalKeyThenTheProxy() throws {
        let endpoint = KeyedEndpoint.keyed("https://bustime.mta.info/api", keyParameter: "key",
                                           keyName: "MTA_BUSTIME_KEY", proxyAgency: "mta")
        let proxy = "https://proxy.example/transitProxy"
        #expect(try endpoint.resolve(localKey: "k", proxyBaseURL: proxy, forceProxy: false)
                == .init(baseURL: "https://bustime.mta.info/api", authQuery: ["key": "k"]))
        #expect(try endpoint.resolve(localKey: nil, proxyBaseURL: proxy, forceProxy: false)
                == .init(baseURL: "\(proxy)/mta", authQuery: [:]))
        #expect(try endpoint.resolve(localKey: "k", proxyBaseURL: proxy, forceProxy: true)
                == .init(baseURL: "\(proxy)/mta", authQuery: [:]))
        #expect { try endpoint.resolve(localKey: nil, proxyBaseURL: nil, forceProxy: true) } throws: { error in
            if case TransitError.missingAPIKey("MTA_BUSTIME_KEY") = error { return true }
            return false
        }
    }

    /// Only the proxy's own host is handed an App Check token.
    @Test func onlyTheProxyHostGetsAToken() {
        #expect(TransitProxy.isProxyHost(URL(string: "\(TransitProxy.defaultBaseURL)/mta/siri/x.json")))
        #expect(!TransitProxy.isProxyHost(URL(string: "https://bustime.mta.info/api/siri/x.json")))
        #expect(!TransitProxy.isProxyHost(URL(string: "https://evil.cloudfunctions.net/transitProxy")))
        #expect(!TransitProxy.isProxyHost(nil))
    }

    /// Pointing a provider at the proxy drops the key requirement and sends no key.
    @Test func aProxyEndpointNeedsNoKey() throws {
        var mta = MTABusTimeProvider()
        mta.endpoint = .proxy("https://proxy.example/mta")
        #expect(mta.requiredAPIKey == nil)
        #expect(mta.hasRequiredAPIKey)
        #expect(try mta.endpoint.authQuery().isEmpty)
    }

    @Test func aDirectEndpointWithoutItsKeyThrows() {
        let endpoint = KeyedEndpoint.direct("https://example.org", keyParameter: "key", keyName: "NO_SUCH_KEY")
        #expect { try endpoint.authQuery() } throws: { error in
            if case TransitError.missingAPIKey("NO_SUCH_KEY") = error { return true }
            return false
        }
    }

    /// A missing key never counts towards an outage.
    @Test func aMissingKeyIsNoOutage() {
        var health = ServiceHealth()
        for _ in 0..<5 {
            #expect(health.recordFailure(TransitError.missingAPIKey("x"), endpoint: "e", isOnline: true, at: Date()) == nil)
        }
        #expect(!health.isInOutage)
    }
}

struct MTABusTimeFormatTests {
    /// SIRI bearings count counter-clockwise from east.
    @Test func bearingsBecomeCompassHeadings() {
        #expect(MTABusTimeProvider.compassBearing(90) == 0)
        #expect(MTABusTimeProvider.compassBearing(0) == 90)
        #expect(MTABusTimeProvider.compassBearing(180) == 270)
        #expect(abs(MTABusTimeProvider.compassBearing(234.4) - 215.6) < 0.01)
    }

    @Test func signAbbreviationsAreSpelledOutForTheGeocoder() {
        #expect(MTABusTimeProvider.spelledOut("1 AV/E 86 ST") == "1st Avenue & East 86th Street")
        #expect(MTABusTimeProvider.spelledOut("ST NICHOLAS AV/W 112 ST") == "Saint NICHOLAS Avenue & West 112th Street")
        #expect(MTABusTimeProvider.spelledOut("Times Square") == "Times Square")
    }
}
