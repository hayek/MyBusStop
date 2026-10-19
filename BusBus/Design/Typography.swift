import SwiftUI

/// The six bundled faces, addressed by their PostScript name.
///
/// Archivo's Medium, ExtraBold and Black each register as their *own* family — only Bold is a
/// style of "Archivo". So `Font.custom("Archivo", …).weight(.black)` silently resolves to Bold or
/// to the system face, and the board quietly loses its display type. Every weight is therefore
/// named exactly, and `BusFace` is the only place in the app where a font-name string exists.
nonisolated enum BusFace: String, CaseIterable, Sendable {
    case archivoMedium    = "Archivo-Medium"      // 500
    case archivoBold      = "Archivo-Bold"        // 700
    case archivoExtraBold = "Archivo-ExtraBold"   // 800
    case archivoBlack     = "Archivo-Black"       // 900 — the minutes numeral, titles, badge numerals
    case spaceMonoRegular = "SpaceMono-Regular"   // 400
    case spaceMonoBold    = "SpaceMono-Bold"      // 700 — codes, times, stop names, captions

    var fileName: String { rawValue + ".ttf" }
}

nonisolated struct TypeStyle: Hashable, Sendable {
    var face: BusFace
    var size: CGFloat
    /// Tracking in em, as the artboards' CSS letter-spacing. Converted to points at use time.
    var trackingEm: CGFloat
    var uppercase: Bool
    /// Set only where text should grow with Dynamic Type — readout and setup copy in hand mode,
    /// never map labels, which are geometry.
    var relativeTo: Font.TextStyle?
    /// The line box the artboards set, as a multiple of the size. A display numeral's own line box
    /// is far taller than its figures, so without this the readout outgrows the band it sits in.
    var lineHeight: CGFloat?
    /// The size this style will not shrink below, whatever the board's scale.
    ///
    /// The composition scales as one piece, which is right for the numerals — a smaller board still
    /// has a large number on it. It is wrong for the text around them: at two thirds scale a 15 pt
    /// kicker lands under 10 pt and stops being readable at all. Anything that supports the numbers
    /// has a floor; the numerals do not need one. Every style, map labels included, also sits on
    /// `readableMinimum`.
    var minimumSize: CGFloat

    init(_ face: BusFace, _ size: CGFloat, tracking trackingEm: CGFloat = 0,
         uppercase: Bool = true, minimum minimumSize: CGFloat = 0,
         relativeTo: Font.TextStyle? = nil, lineHeight: CGFloat? = nil) {
        self.face = face
        self.size = size
        self.trackingEm = trackingEm
        self.uppercase = uppercase
        self.minimumSize = minimumSize
        self.relativeTo = relativeTo
        self.lineHeight = lineHeight
    }

    /// The size no text in the app goes below: the system's caption, the smallest size it sets
    /// for text meant to be read. The layouts scale as one piece, so without it a 12 pt caption on
    /// a two-thirds board lands at 8 pt — there, but not legible.
    static let readableMinimum: CGFloat = MapMetrics.readableMinimum

    /// The size this style renders at on a board of the given scale.
    func size(at scale: CGFloat) -> CGFloat { max(Self.readableMinimum, minimumSize, size * scale) }

    func scaled(_ scale: CGFloat) -> TypeStyle {
        var copy = self
        copy.size = size(at: scale)
        copy.minimumSize = 0
        return copy
    }
}

extension Font {
    /// The only constructor for app fonts. Nothing else calls `Font.custom`, and nothing ever
    /// applies `.weight()` to a custom face.
    /// No size goes below `TypeStyle.readableMinimum`, whoever computed it.
    static func bus(_ face: BusFace, size: CGFloat, relativeTo: Font.TextStyle? = nil) -> Font {
        let size = max(TypeStyle.readableMinimum, size)
        if let relativeTo { return .custom(face.rawValue, size: size, relativeTo: relativeTo) }
        return .custom(face.rawValue, fixedSize: size)
    }
}

extension View {
    func busText(_ style: TypeStyle, scale: CGFloat = 1) -> some View {
        let size = style.size(at: scale)
        return self
            .busFont(style.face, size: size, relativeTo: style.relativeTo, tracking: size * style.trackingEm)
            .textCase(style.uppercase ? .uppercase : nil)
    }

    /// The board's face and letter-spacing for its own words, adjusted for the language they are
    /// in. See `LocaleAwareBusFont`.
    func busFont(_ face: BusFace, size: CGFloat, relativeTo: Font.TextStyle? = nil, tracking: CGFloat) -> some View {
        // Tracking is proportional to size, so a size raised to the floor takes its tracking along.
        let floored = max(TypeStyle.readableMinimum, size)
        return modifier(LocaleAwareBusFont(face: face, size: floored, relativeTo: relativeTo,
                                           tracking: size > 0 ? tracking * floored / size : tracking))
    }
}

/// Letter-spaced monospace is a Latin idiom. Only alphabets that are customarily tracked keep it;
/// every other script is set solid and in Archivo of the same weight, so the cascade lands on the
/// system's own proportional face for that script. Tracking pulls a joined word (Arabic,
/// Devanagari) apart into letters, spaces Hebrew and CJK out like a ransom note, and the system's
/// fallback for a monospaced face stretches each glyph to a fixed width.
struct LocaleAwareBusFont: ViewModifier {
    @Environment(\.locale) private var locale
    var face: BusFace
    var size: CGFloat
    var relativeTo: Font.TextStyle?
    var tracking: CGFloat

    /// ISO 15924 codes of the scripts the monospace and its tracking were drawn for.
    private static let trackedScripts: Set<String> = ["Latn", "Cyrl", "Grek"]

    func body(content: Content) -> some View {
        let solid = !Self.isTracked(locale)
        content
            .font(.bus(solid ? face.proportional : face, size: size, relativeTo: relativeTo))
            .tracking(solid ? 0 : tracking)
    }

    /// The script is inferred from the language ("he" is Hebr), so a bare code is enough; one
    /// that resolves to none is taken as Latin, as it always was.
    static func isTracked(_ locale: Locale) -> Bool {
        locale.language.script.map { trackedScripts.contains($0.identifier) } ?? true
    }

    /// The same rule for a name from a feed, which is written in its city's script whatever the
    /// app's language: tracked only if every letter is Latin (Vietnamese's included), Greek or
    /// Cyrillic. A Hebrew or Japanese stop name on an English board is set solid.
    static func isTracked(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.isAlphabetic || scalar.value < 0x0530 || (0x1E00...0x1FFF).contains(scalar.value)
        }
    }
}

extension BusFace {
    /// The same weight in Archivo, for a script the monospace was not drawn for.
    var proportional: BusFace {
        switch self {
        case .spaceMonoRegular: .archivoMedium
        case .spaceMonoBold: .archivoBold
        default: self
        }
    }
}

/// Every type style on the board, at its reference size. Views multiply by the layout scale.
nonisolated enum TypeStyles {
    // Header
    static let titleLandscape = TypeStyle(.archivoBlack, 34, tracking: -0.015)
    /// The wall column's header shares its width with the clock, so the name is set a size down.
    static let titleWall = TypeStyle(.archivoBlack, 30, tracking: -0.013)
    /// Set with the live label, as the artboard's "LIVE · 14:31", rather than as a second title.
    static let clockWall = TypeStyle(.spaceMonoBold, 16, tracking: 0.1, minimum: 12)
    static let titlePad = TypeStyle(.archivoBlack, 30, tracking: -0.013)
    static let titlePhone = TypeStyle(.archivoBlack, 22, tracking: -0.013)
    static let headerCaption = TypeStyle(.spaceMonoBold, 13, tracking: 0.14, minimum: 12)
    static let headerCaptionPad = TypeStyle(.spaceMonoBold, 12, tracking: 0.14, minimum: 12)
    static let liveLabel = TypeStyle(.spaceMonoBold, 12, tracking: 0.22, minimum: 11)
    static let liveLabelPad = TypeStyle(.spaceMonoBold, 11, tracking: 0.22, minimum: 11)
    static let clock = TypeStyle(.spaceMonoBold, 26)
    static let clockPad = TypeStyle(.spaceMonoBold, 22)
    static let clockPhone = TypeStyle(.spaceMonoBold, 15)

    // Map
    static let yourStop = TypeStyle(.spaceMonoBold, 13, tracking: 0.16, minimum: 11)
    static let hint = TypeStyle(.spaceMonoBold, 11, tracking: 0.14)

    // Readout
    static let kicker = TypeStyle(.spaceMonoBold, 15, tracking: 0.16, minimum: 13, relativeTo: .caption)
    static let kickerSmall = TypeStyle(.spaceMonoBold, 15, tracking: 0.16, minimum: 13, relativeTo: .caption)
    static let kickerPad = TypeStyle(.spaceMonoBold, 16, tracking: 0.16, minimum: 13, relativeTo: .caption)
    static let minutesPrimary = TypeStyle(.archivoBlack, 124, tracking: -0.04, lineHeight: 0.84)
    static let minutesPrimaryPad = TypeStyle(.archivoBlack, 140, tracking: -0.043, lineHeight: 0.8)
    static let minutesPrimaryPhone = TypeStyle(.archivoBlack, 92, tracking: -0.043, lineHeight: 0.82)
    static let minutesPrimaryBeside = TypeStyle(.archivoBlack, 92, tracking: -0.043, lineHeight: 0.84)
    static let unitPrimary = TypeStyle(.archivoBlack, 34, tracking: 0.02)
    static let unitPrimaryPad = TypeStyle(.archivoBlack, 36, tracking: 0.02)
    static let unitPrimaryPhone = TypeStyle(.archivoBlack, 24, tracking: 0.02)
    static let unitPrimaryBeside = TypeStyle(.archivoBlack, 28, tracking: 0.02)
    static let subStopsAway = TypeStyle(.archivoExtraBold, 17, tracking: 0.02, minimum: 15, relativeTo: .body)
    static let subArrives = TypeStyle(.spaceMonoBold, 17, minimum: 15, relativeTo: .body)
    // Wall display, landscape: the readout runs the full height of a narrow column.
    static let kickerWall = TypeStyle(.spaceMonoBold, 22, tracking: 0.16, minimum: 13)
    static let minutesWall = TypeStyle(.archivoBlack, 340, tracking: -0.035, lineHeight: 0.76)
    static let unitWall = TypeStyle(.archivoBlack, 60, tracking: 0.04)
    static let subStopsAwayWall = TypeStyle(.archivoExtraBold, 30, minimum: 15)
    static let subArrivesWall = TypeStyle(.spaceMonoBold, 24, minimum: 15)
    static let subPhone = TypeStyle(.spaceMonoBold, 15, tracking: 0.02, minimum: 14, relativeTo: .caption)
    static let subBeside = TypeStyle(.spaceMonoBold, 16, tracking: 0.02, minimum: 15)
    static let scheduledTag = TypeStyle(.spaceMonoBold, 13, tracking: 0.10, minimum: 12)

    // THEN card
    static let thenLabel = TypeStyle(.spaceMonoBold, 15, tracking: 0.16, minimum: 13, relativeTo: .caption)
    static let thenLabelPhone = TypeStyle(.spaceMonoBold, 14, tracking: 0.16, minimum: 13, relativeTo: .caption)
    static let minutesSecondary = TypeStyle(.archivoBlack, 56, tracking: -0.036, lineHeight: 0.9)
    static let minutesSecondaryPad = TypeStyle(.archivoBlack, 52, tracking: -0.038, lineHeight: 0.9)
    static let minutesSecondaryPhone = TypeStyle(.archivoBlack, 40, tracking: -0.038, lineHeight: 0.9)
    static let unitSecondary = TypeStyle(.archivoBlack, 20)
    static let unitSecondaryPhone = TypeStyle(.archivoBlack, 16)
    static let thenSub = TypeStyle(.spaceMonoBold, 16, tracking: 0.02, minimum: 14, relativeTo: .caption)
    static let thenSubPhone = TypeStyle(.spaceMonoBold, 14, tracking: 0.02, minimum: 13, relativeTo: .caption)

    // Tapped-bus card
    static let tappedKicker = TypeStyle(.spaceMonoBold, 12, tracking: 0.22, minimum: 12)
    static let tappedMinutes = TypeStyle(.archivoBlack, 62, tracking: -0.032)
    static let tappedUnit = TypeStyle(.archivoBlack, 22)
    static let tappedStops = TypeStyle(.archivoExtraBold, 20, minimum: 16)
    static let tappedDetail = TypeStyle(.spaceMonoBold, 13, tracking: 0.06, minimum: 12)

    // Setup
    static let setupTitle = TypeStyle(.archivoBlack, 40, tracking: -0.02, relativeTo: .largeTitle)
    static let setupTitlePhone = TypeStyle(.archivoBlack, 30, tracking: -0.017, relativeTo: .largeTitle)
    /// The first-run title is a question in sentence case, not a label.
    static let welcomeTitle = TypeStyle(.archivoBlack, 48, tracking: -0.02, uppercase: false, relativeTo: .largeTitle)
    static let welcomeTitlePhone = TypeStyle(.archivoBlack, 36, tracking: -0.017, uppercase: false, relativeTo: .largeTitle)
    static let permissionTitle = TypeStyle(.archivoBlack, 24, tracking: -0.01, uppercase: false, relativeTo: .title3)
    static let permissionTitlePhone = TypeStyle(.archivoBlack, 20, tracking: -0.01, uppercase: false, relativeTo: .title3)
    static let permissionBody = TypeStyle(.archivoBold, 17, uppercase: false, relativeTo: .body)
    static let permissionBodyPhone = TypeStyle(.archivoBold, 15, uppercase: false, relativeTo: .body)
    static let setupTitleLinePhone = TypeStyle(.archivoBlack, 26, tracking: -0.015, relativeTo: .title)
    static let stepCaption = TypeStyle(.spaceMonoBold, 13, tracking: 0.22, relativeTo: .caption)
    static let stepCaptionPhone = TypeStyle(.spaceMonoBold, 11, tracking: 0.22, relativeTo: .caption)
    static let searchInput = TypeStyle(.archivoBold, 22, uppercase: false, relativeTo: .body)
    static let searchInputPhone = TypeStyle(.archivoBold, 18, uppercase: false, relativeTo: .body)
    static let sectionHeader = TypeStyle(.spaceMonoBold, 14, tracking: 0.22, minimum: 13, relativeTo: .caption)
    static let sectionHeaderPhone = TypeStyle(.spaceMonoBold, 13, tracking: 0.22, minimum: 13, relativeTo: .caption)
    static let countCaption = TypeStyle(.spaceMonoBold, 12, tracking: 0.10, relativeTo: .caption)
    static let countCaptionPhone = TypeStyle(.spaceMonoBold, 11, tracking: 0.10, relativeTo: .caption)
    /// A data licence's credit line: set as the licensor wrote it, so never upper-cased.
    static let creditLine = TypeStyle(.spaceMonoRegular, 12, uppercase: false, minimum: 11, relativeTo: .caption2)
    static let creditLinePhone = TypeStyle(.spaceMonoRegular, 11, uppercase: false, minimum: 11, relativeTo: .caption2)
    static let distanceChip = TypeStyle(.spaceMonoBold, 15, relativeTo: .body)
    static let distanceChipPhone = TypeStyle(.spaceMonoBold, 13, relativeTo: .body)
    static let nearbyName = TypeStyle(.archivoBlack, 31, tracking: -0.011, minimum: 20, relativeTo: .title2)
    static let nearbyNamePhone = TypeStyle(.archivoBlack, 23, tracking: -0.01, minimum: 18, relativeTo: .title3)
    static let stopAddress = TypeStyle(.spaceMonoBold, 13, tracking: 0.06, minimum: 12, relativeTo: .caption)
    static let stopAddressPhone = TypeStyle(.spaceMonoBold, 11, tracking: 0.06, minimum: 11, relativeTo: .caption)
    static let overflowCount = TypeStyle(.spaceMonoBold, 14, relativeTo: .caption)
    static let overflowCountPhone = TypeStyle(.spaceMonoBold, 12, relativeTo: .caption)
    static let recentName = TypeStyle(.archivoExtraBold, 26, minimum: 18, relativeTo: .title3)
    static let recentNamePhone = TypeStyle(.archivoExtraBold, 18, minimum: 16, relativeTo: .body)
    /// Where a line goes, beside its badge in the search's confirm panel: a size under the stop's
    /// own name above it, so the list reads as detail rather than as more stops.
    static let confirmLinePhone = TypeStyle(.archivoExtraBold, 15, minimum: 13, relativeTo: .body)
    static let pickerSubtitle = TypeStyle(.spaceMonoBold, 13, tracking: 0.18, relativeTo: .caption)
    static let pickerSubtitlePhone = TypeStyle(.spaceMonoBold, 10, tracking: 0.16, relativeTo: .caption)
    static let chipNumber = TypeStyle(.archivoBlack, 54, tracking: -0.028)
    static let chipNumberPhone = TypeStyle(.archivoBlack, 34, tracking: -0.029)
    static let chipDestination = TypeStyle(.spaceMonoBold, 12, tracking: 0.08, relativeTo: .caption2)
    static let chipDestinationPhone = TypeStyle(.spaceMonoBold, 9, tracking: 0.06, relativeTo: .caption2)
    static let footerCount = TypeStyle(.archivoBlack, 22, tracking: -0.009, relativeTo: .title3)
    static let footerCountPhone = TypeStyle(.archivoBlack, 20, tracking: -0.01, relativeTo: .title3)
    static let footerHint = TypeStyle(.spaceMonoBold, 13, tracking: 0.12, relativeTo: .caption)
    static let footerHintPhone = TypeStyle(.spaceMonoBold, 11, tracking: 0.12, relativeTo: .caption)
    static let clearButton = TypeStyle(.archivoExtraBold, 18, tracking: 0.02, relativeTo: .body)
    static let clearButtonPhone = TypeStyle(.archivoExtraBold, 16, tracking: 0.02, relativeTo: .body)
    static let primaryButton = TypeStyle(.archivoBlack, 22, relativeTo: .body)
    static let primaryButtonPhone = TypeStyle(.archivoBlack, 19, relativeTo: .body)

    /// Badge and puck numerals are Archivo Black sized against the badge, never a weight modifier.
    static func badgeNumeral(_ size: CGFloat) -> TypeStyle { TypeStyle(.archivoBlack, size) }
}
