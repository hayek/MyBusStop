import Testing
import Foundation
import SwiftUI
@testable import BusBus

/// Which providers a widget may call by itself: the board's rules, as far as the widget can
/// follow them.
struct WidgetProviderGateTests {
    private func setup(provider: String?) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: "1", name: "Stop", location: GeoPoint(lat: 0, lon: 0)),
                   lines: [TransitLine(id: "18", shortName: "18", headsign: nil, agency: nil, origin: nil,
                                       destination: nil, isAccessible: nil, brandColorIndex: nil)],
                   providerID: provider)
    }

    @Test func aKeylessProviderIsCalled() {
        #expect(WidgetProviderGate.provider(for: setup(provider: "mbta"), disabled: [])?.id == "mbta")
    }

    /// Entries saved before providers followed location came from bus.gov.il.
    @Test func anOldEntryUsesTheLegacyProvider() {
        #expect(WidgetProviderGate.provider(for: setup(provider: nil), disabled: [])?.id == "bus.gov.il")
    }

    /// Not the fallback provider, which would be asked about a stop it has never heard of.
    @Test func anUnknownProviderIsNotCalled() {
        #expect(WidgetProviderGate.provider(for: setup(provider: "nowhere"), disabled: []) == nil)
    }

    /// A complication on the watch says where its numbers come from when only the phone can fetch them.
    @Test func aSnapshotOnlyStopIsSentToTheIPhone() {
        #expect(WidgetProviderGate.isSnapshotOnly(setup(provider: "mta-bustime")))
        #expect(!WidgetProviderGate.isSnapshotOnly(setup(provider: "mbta")))
        #expect(!WidgetProviderGate.isSnapshotOnly(setup(provider: nil)))
        #expect(WidgetMessage.expired.watchDetail(snapshotOnly: true) == "OPEN MY BUS STOP ON YOUR IPHONE")
        #expect(WidgetMessage.expired.watchDetail(snapshotOnly: false) == WidgetMessage.expired.detail)
        #expect(WidgetMessage.noBusesDue.watchDetail(snapshotOnly: true) == WidgetMessage.noBusesDue.detail)
    }

    @Test func snapshotOnlyProvidersAreNotCalled() {
        for id in WidgetProviderGate.snapshotOnly {
            #expect(WidgetProviderGate.provider(for: setup(provider: id), disabled: []) == nil, "\(id)")
        }
    }

    /// A provider pulled from the console is pulled from every widget too.
    @Test func aRemotelyDisabledProviderIsNotCalled() {
        #expect(WidgetProviderGate.provider(for: setup(provider: "mbta"), disabled: ["mbta"]) == nil)
        #expect(WidgetProviderGate.provider(for: setup(provider: nil), disabled: ["bus.gov.il"]) == nil)
    }

    /// Transitous forbids commercial use: off until the app has said its flag is on.
    @Test func transitousIsOffUntilTheAppSaysOtherwise() {
        let transitous = setup(provider: TransitousProvider.providerID)
        #expect(WidgetProviderGate.provider(for: transitous, disabled: nil) == nil)
        #expect(WidgetProviderGate.provider(for: transitous, disabled: [TransitousProvider.providerID]) == nil)
        #expect(WidgetProviderGate.provider(for: transitous, disabled: [])?.id == TransitousProvider.providerID)
        // Before any mirror, everything else is allowed.
        #expect(WidgetProviderGate.provider(for: setup(provider: "mbta"), disabled: nil)?.id == "mbta")
    }
}
