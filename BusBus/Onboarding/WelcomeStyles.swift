import SwiftUI

// The welcome story's and the first board's tip's own type and colours. Kept out of
// `Typography.swift` and `DesignTokens.swift`, which the widget and the watch compile too.

extension TypeStyles {
    // Welcome story
    /// A page's headline: sentence case, a statement rather than a label.
    static let storyTitle = TypeStyle(.archivoBlack, 32, tracking: -0.019, uppercase: false,
                                      relativeTo: .largeTitle)
    /// The page counter and SKIP.
    static let storyCaption = TypeStyle(.spaceMonoBold, 14, tracking: 0.14, relativeTo: .caption)
    /// "Search by name instead": a way out, quieter than the button above it.
    static let storyLink = TypeStyle(.archivoBold, 16, uppercase: false, relativeTo: .body)
    /// Page 1's countdown, the board's readout in miniature.
    static let storyNumeral = TypeStyle(.archivoBlack, 64, tracking: -0.031, lineHeight: 0.85)
    static let storyUnit = TypeStyle(.archivoBlack, 20)
    static let storyNow = TypeStyle(.archivoBlack, 56, tracking: -0.018, lineHeight: 0.85)
    /// The rails' termini and stop names on page 1. The artboard's 11 pt rises to the readable floor.
    static let storyMapLabel = TypeStyle(.spaceMonoBold, 11)
    static let storyTerminus = TypeStyle(.archivoBlack, 14)
    static let storyYourStop = TypeStyle(.spaceMonoBold, 12, tracking: 0.125)
    /// Page 3's distances. Geometry, like the map's labels, so it does not follow Dynamic Type.
    static let storyChip = TypeStyle(.spaceMonoBold, 13)

    // The first board's tip
    static let tipTitle = TypeStyle(.archivoBlack, 18, tracking: -0.011, uppercase: false, relativeTo: .headline)
    static let tipBody = TypeStyle(.archivoBold, 15, uppercase: false, relativeTo: .body)
}

extension Theme {
    /// The street grid behind page 3's stops: barely there, in either theme.
    var welcomeRoad: Color { isLight ? cardOutline.opacity(0.5) : Color(hex: 0x121218) }

    /// The close button's disc on the tip, which is drawn on the inverted surface
    /// (`primaryButtonFill`): a pale disc on white, a dark one on ink.
    var tipCloseFill: Color { isLight ? primaryButtonText.opacity(0.14) : Color(hex: 0xECEAE4) }

    // Page 2's room is a picture of a dark hallway at night, so it is the same in both themes.
    var welcomeRoom: Color { Color(hex: 0x0D0D12) }
    var welcomeFloor: Color { Color(hex: 0x0A0A0E) }
    /// The skirting line, the door's frame and its panels.
    var welcomeWallLine: Color { Color(hex: 0x1C1C24) }
    var welcomeDoor: Color { Color(hex: 0x101016) }
    /// The door's edge, the light switch and the socket.
    var welcomeFixture: Color { Color(hex: 0x2A2A34) }
    /// The door handle and the phone's camera.
    var welcomeHardware: Color { Color(hex: 0x3A3A46) }
    var welcomeCable: Color { Color(hex: 0x8C8C9A) }
    var welcomePhoneBody: Color { Color(hex: 0x1A1A22) }
    var welcomePhoneScreen: Color { Theme.dark.background }
    var welcomePhoneEdge: Color { Theme.dark.primaryText }
}
