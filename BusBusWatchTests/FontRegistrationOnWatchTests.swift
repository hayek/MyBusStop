import Testing
import Foundation
@testable import BusBusWatch

/// The watch app and its complications are two more bundles, each with its own copies of the six
/// faces (`BusBusTests/Design/FontRegistrationTests` checks the phone's).
@MainActor
struct FontRegistrationOnWatchTests {
    @Test func fontFilesAreInTheWatchApp() {
        for face in BusFace.allCases {
            #expect(FontRegistrar.url(for: face) != nil, "missing \(face.fileName) in the watch app")
        }
    }

    @Test func fontFilesAreInTheComplicationsBundle() throws {
        let appex = try #require(Bundle.main.builtInPlugInsURL?.appending(path: "BusBusWatchWidget.appex"))
        let widget = try #require(Bundle(url: appex), "the complications are not embedded in the watch app")
        for face in BusFace.allCases {
            #expect(FontRegistrar.url(for: face, in: widget) != nil, "missing \(face.fileName) in the complications")
        }
    }

    @Test func allSixFacesResolve() {
        FontRegistrar.registerBundledFonts()
        #expect(FontRegistrar.unresolvedFaces().isEmpty)
    }
}
