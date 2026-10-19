import SwiftUI
import CoreText
import os

/// Registers the bundled faces with CoreText at launch.
///
/// Runtime registration rather than Info.plist: `GENERATE_INFOPLIST_FILE` has no key for
/// `UIAppFonts`, and macOS wants `ATSApplicationFontsPath` instead — one CoreText call covers both
/// platforms and cannot drift out of sync with the files on disk.
@MainActor enum FontRegistrar {
    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "fonts")
    private static var hasRegistered = false

    static func registerBundledFonts() {
        guard !hasRegistered else { return }
        hasRegistered = true
        for face in BusFace.allCases {
            guard let url = url(for: face) else {
                log.fault("missing font file \(face.fileName, privacy: .public)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = CFErrorGetCode(error?.takeUnretainedValue())
                // Previews and tests can register twice; that is not a failure.
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    log.fault("could not register \(face.rawValue, privacy: .public): \(code)")
                }
            }
        }
    }

    /// The synchronized group may keep the folder or flatten it into the bundle root.
    static func url(for face: BusFace) -> URL? { url(for: face, in: .main) }

    /// The same lookup in another bundle: the widget extension registers its own copies.
    static func url(for face: BusFace, in bundle: Bundle) -> URL? {
        bundle.url(forResource: face.rawValue, withExtension: "ttf", subdirectory: "Fonts")
            ?? bundle.url(forResource: face.rawValue, withExtension: "ttf")
    }

    /// Faces CoreText substituted something else for. A silent substitution is invisible to anyone
    /// who does not know the typeface, so the app reports it rather than shipping the wrong look.
    static func unresolvedFaces() -> [BusFace] {
        BusFace.allCases.filter { face in
            let font = CTFontCreateWithName(face.rawValue as CFString, 12, nil)
            return (CTFontCopyPostScriptName(font) as String) != face.rawValue
        }
    }
}
