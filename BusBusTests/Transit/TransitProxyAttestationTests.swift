import Testing
import Foundation
import os
@testable import BusBus

/// The transit layer takes App Check tokens through a hook rather than from Firebase directly, so
/// the widget can share it without linking Firebase. Serialized: the hook is process-wide.
@Suite(.serialized)
struct TransitProxyAttestationTests {
    /// Whatever the host app's `Telemetry.start()` installed goes back afterwards, so the rest of
    /// the run sees the process as it was.
    private func withHook(_ hook: (@Sendable (URL) async -> String?)?, _ body: () async -> Void) async {
        let saved = TransitProxy.attestation.withLock { current in
            defer { current = hook }
            return current
        }
        await body()
        TransitProxy.attestation.withLock { $0 = saved }
    }

    @Test func noHookMeansNoToken() async {
        await withHook(nil) {
            #expect(await TransitProxy.appCheckToken(for: URL(string: "\(TransitProxy.defaultBaseURL)/mta/x")) == nil)
        }
    }

    @Test func theHookIsAskedForTheProxyHostOnly() async {
        await withHook({ _ in "token" }) {
            #expect(await TransitProxy.appCheckToken(for: URL(string: "\(TransitProxy.defaultBaseURL)/mta/x")) == "token")
            #expect(await TransitProxy.appCheckToken(for: URL(string: "https://bustime.mta.info/api/x")) == nil)
            #expect(await TransitProxy.appCheckToken(for: nil) == nil)
        }
    }

    @Test func theHookIsRestored() async {
        let url = URL(string: "\(TransitProxy.defaultBaseURL)/mta/x")
        await withHook({ _ in "outer" }) {
            await withHook(nil) {}
            #expect(await TransitProxy.appCheckToken(for: url) == "outer")
        }
    }
}
