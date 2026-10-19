import Testing
import Foundation
import CoreLocation
#if os(iOS)
import UIKit
#endif
@testable import BusBus

private extension CLAuthorizationStatus {
    /// Location allowed, as each platform says it: a Mac has no "while in use".
    static var allowed: Self {
        #if os(macOS)
        .authorizedAlways
        #else
        .authorizedWhenInUse
        #endif
    }
}

/// The list waits for the rider's own tap before location is asked for — and never flips back to
/// waiting while a request is already on the system's alert.
struct NearbyPermissionTests {

    @Test func anUnaskedRiderWithNoFixWaits() {
        #expect(SetupViewModel.waitsForPermission(hasFix: false, needsPermission: true, askingPermission: false,
                                                  isLocating: false, staging: false))
    }

    @Test func aRequestAlreadyWaitingOnTheAlertIsNotUndone() {
        #expect(!SetupViewModel.waitsForPermission(hasFix: false, needsPermission: true, askingPermission: false,
                                                   isLocating: true, staging: false))
    }

    @Test func theRidersOwnTapAsks() {
        #expect(!SetupViewModel.waitsForPermission(hasFix: false, needsPermission: true, askingPermission: true,
                                                   isLocating: false, staging: false))
    }

    /// OPEN SETTINGS goes to BusBus's own page on iPhone and iPad, and to Location Services on a
    /// Mac, which has no page per app.
    @Test func settingsOpensWhereLocationIsTurnedOn() {
        #if os(macOS)
        #expect(LocationService.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        #else
        #expect(LocationService.settingsURL?.absoluteString == UIApplication.openSettingsURLString)
        #endif
    }

    @Test func aFixOrAnAnswerOrAScreenshotDoesNotWait() {
        #expect(!SetupViewModel.waitsForPermission(hasFix: true, needsPermission: true, askingPermission: false,
                                                   isLocating: false, staging: false))
        #expect(!SetupViewModel.waitsForPermission(hasFix: false, needsPermission: false, askingPermission: false,
                                                   isLocating: false, staging: false))
        #expect(!SetupViewModel.waitsForPermission(hasFix: false, needsPermission: true, askingPermission: false,
                                                   isLocating: false, staging: true))
    }
}

/// Stands in for Core Location: the rider answers the alert, and a fix arrives, when the test says.
@MainActor private final class ScriptedLocation {
    var status: CLAuthorizationStatus = .notDetermined
    private(set) var permissionRequests = 0
    private(set) var fixRequests = 0
    /// Whether a fix was asked for before the rider had answered the alert.
    private(set) var askedBeforeAnswer = false
    private var pending: CheckedContinuation<GeoPoint?, Never>?
    private var onChange: (@MainActor () -> Void)?

    var source: LocationService.Source {
        LocationService.Source(
            status: { self.status },
            requestPermission: { self.permissionRequests += 1 },
            fix: { _ in
                self.fixRequests += 1
                if self.status == .notDetermined { self.askedBeforeAnswer = true }
                return await withCheckedContinuation { self.pending = $0 }
            },
            observeAuthorization: { self.onChange = $0 })
    }

    /// The answer changes the way Core Location reports it: the new status, then word of it.
    func change(to status: CLAuthorizationStatus) {
        self.status = status
        onChange?()
    }

    var isWaitingForFix: Bool { pending != nil }

    func deliver(_ point: GeoPoint?) {
        pending?.resume(returning: point)
        pending = nil
    }
}

/// `loadNearby` itself, around a request that is waiting on the permission alert.
@Suite(.appLanguage("en"))
@MainActor
struct NearbyLoadWhileLocatingTests {

    private func makeModel(_ scripted: ScriptedLocation) -> SetupViewModel {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "nearby-\(UUID().uuidString)")!)
        settings.providerID = "mock"
        return SetupViewModel(settings: settings, location: LocationService(source: scripted.source))
    }

    /// Lets the tasks the test started run until `condition` holds.
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func thePickersOwnLoadLeavesARequestOnTheAlertAlone() async throws {
        let scripted = ScriptedLocation()
        let model = makeModel(scripted)
        let asking = Task { await model.loadNearby(force: true, askingPermission: true) }
        try await until { model.location.isLocating }
        #expect(model.nearbyState == .locating)

        // The picker appearing under the story: still unasked, but it must not put the card up.
        await model.loadNearby()
        #expect(model.nearbyState == .locating)
        #expect(scripted.permissionRequests == 1)

        scripted.status = .denied
        await asking.value
        #expect(model.nearbyState == .denied)
    }

    @Test func aSecondForcedLoadWaitsForTheFixInsteadOfGivingUp() async throws {
        let scripted = ScriptedLocation()
        let model = makeModel(scripted)
        let first = Task { await model.loadNearby(force: true, askingPermission: true) }
        try await until { model.location.isLocating }

        let second = Task { await model.loadNearby(force: true, askingPermission: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.nearbyState == .locating)

        scripted.status = .allowed
        try await until { scripted.isWaitingForFix }
        scripted.deliver(nil)
        await first.value
        await second.value
        // One request answered both.
        #expect(scripted.fixRequests == 1)
        #expect(model.nearbyState == .unavailable)
    }

    @Test func theTimeoutStartsOnlyOnceTheRiderHasAnswered() async throws {
        let scripted = ScriptedLocation()
        let model = makeModel(scripted)
        let asking = Task { await model.loadNearby(force: true, askingPermission: true) }
        try await until { model.location.isLocating }
        // Reading the alert for a while: nothing is being timed yet.
        try await Task.sleep(for: .milliseconds(500))
        #expect(scripted.fixRequests == 0)

        scripted.status = .allowed
        try await until { scripted.isWaitingForFix }
        #expect(!scripted.askedBeforeAnswer)
        scripted.deliver(nil)
        await asking.value
    }

    @Test func comingBackRetriesAListThatCouldNotFindTheRider() async throws {
        let scripted = ScriptedLocation()
        scripted.status = .allowed
        let model = makeModel(scripted)
        let first = Task { await model.loadNearby() }
        try await until { scripted.isWaitingForFix }
        scripted.deliver(nil)
        await first.value
        #expect(model.nearbyState == .unavailable)

        let again = Task { await model.reloadNearbyIfLocationChanged() }
        try await until { scripted.isWaitingForFix }
        #expect(scripted.fixRequests == 2)
        scripted.deliver(nil)
        await again.value
    }

    @Test func refusedAndRestrictedAreToldApart() async {
        let scripted = ScriptedLocation()
        scripted.status = .denied
        let refused = makeModel(scripted)
        await refused.loadNearby()
        #expect(refused.nearbyState == .denied)

        scripted.status = .restricted
        let restricted = makeModel(scripted)
        await restricted.loadNearby()
        #expect(restricted.nearbyState == .restricted)
        // Neither is ever asked, nor looked for.
        #expect(scripted.permissionRequests == 0)
        #expect(scripted.fixRequests == 0)
    }

    @Test func aRestrictionLiftedLooksForTheRider() async throws {
        let scripted = ScriptedLocation()
        scripted.status = .restricted
        let model = makeModel(scripted)
        await model.loadNearby()
        #expect(model.nearbyState == .restricted)

        scripted.status = .allowed
        let again = Task { await model.reloadNearbyIfLocationChanged() }
        try await until { scripted.isWaitingForFix }
        scripted.deliver(nil)
        await again.value
        #expect(model.nearbyState == .unavailable)
    }

    /// Core Location's word of the change can arrive before the app hears it is back (a Mac window
    /// never left): the answer is already new by the time the list looks, and it must still look.
    @Test func anAnswerHeardBeforeComingBackStillLooksForTheRider() async throws {
        let scripted = ScriptedLocation()
        scripted.status = .denied
        let model = makeModel(scripted)
        await model.loadNearby()
        #expect(model.nearbyState == .denied)

        scripted.change(to: .allowed)
        #expect(model.location.status == .allowed)
        let again = Task { await model.reloadNearbyIfLocationChanged() }
        try await until { scripted.isWaitingForFix }
        scripted.deliver(nil)
        await again.value
        #expect(scripted.fixRequests == 1)
        #expect(model.nearbyState == .unavailable)
    }

    @Test func comingBackAfterAllowingInSettingsLooksForTheRider() async throws {
        let scripted = ScriptedLocation()
        scripted.status = .denied
        let model = makeModel(scripted)
        await model.loadNearby()
        #expect(model.nearbyState == .denied)

        // Unchanged: nothing is asked.
        await model.reloadNearbyIfLocationChanged()
        #expect(scripted.fixRequests == 0)

        scripted.status = .allowed
        let again = Task { await model.reloadNearbyIfLocationChanged() }
        try await until { scripted.isWaitingForFix }
        scripted.deliver(nil)
        await again.value
        #expect(model.nearbyState == .unavailable)
    }
}
