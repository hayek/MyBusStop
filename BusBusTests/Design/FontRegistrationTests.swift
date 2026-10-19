import Testing
import CoreText
import Foundation
@testable import BusBus

@MainActor
struct FontRegistrationTests {

    /// The .ttf files must actually be copied into the app bundle by the synchronized group.
    @Test func fontFilesAreInBundle() {
        for face in BusFace.allCases {
            #expect(FontRegistrar.url(for: face) != nil, "missing \(face.fileName) in the app bundle")
        }
    }

    /// The widget is its own process with its own bundle; the app's copies are out of its reach.
    @Test func fontFilesAreInTheWidgetBundle() throws {
        let appex = try #require(Bundle.main.builtInPlugInsURL?.appending(path: "BusBusWidget.appex"))
        let widget = try #require(Bundle(url: appex), "the widget extension is not embedded in the app")
        for face in BusFace.allCases {
            #expect(FontRegistrar.url(for: face, in: widget) != nil, "missing \(face.fileName) in the widget bundle")
        }
    }

    /// A substituted face is invisible in a screenshot to anyone who does not know the typeface,
    /// so it is asserted rather than eyeballed.
    @Test func allSixFacesResolve() {
        FontRegistrar.registerBundledFonts()
        #expect(FontRegistrar.unresolvedFaces().isEmpty)
    }

    /// Guards the trap this app was designed around: three of the four Archivo weights register as
    /// their own family, so asking for "Archivo" at weight .black silently gives you something else.
    @Test func familyNamePlusWeightDoesNotReachBlack() {
        FontRegistrar.registerBundledFonts()
        let byFamily = CTFontCreateWithName("Archivo" as CFString, 12, nil)
        let familyName = CTFontCopyFamilyName(byFamily) as String
        // Both halves matter: with no fonts registered at all the first expectation holds too.
        #expect(familyName == "Archivo")
        #expect((CTFontCopyPostScriptName(byFamily) as String) != BusFace.archivoBlack.rawValue)
        let byPostScript = CTFontCreateWithName(BusFace.archivoBlack.rawValue as CFString, 12, nil)
        #expect((CTFontCopyPostScriptName(byPostScript) as String) == BusFace.archivoBlack.rawValue)
    }
}
