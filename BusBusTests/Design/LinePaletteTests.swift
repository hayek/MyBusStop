import Testing
import Foundation
@testable import BusBus

struct LinePaletteTests {

    @Test func paletteHasTwelveOfEachVariant() {
        #expect(LinePalette.darkRail.count == 12)
        #expect(LinePalette.lightRail.count == 12)
        #expect(LinePalette.lightText.count == 12)
    }

    /// Hand-derived from FNV-1a, not from the implementation: these are the colours already on
    /// every installed device, and the hash is not free to move.
    @Test func hashIsStable() {
        #expect(LineColorAssigner.hashedIndex(for: "41") == 2)
        #expect(LineColorAssigner.hashedIndex(for: "18") == 8)
        #expect(LineColorAssigner.hashedIndex(for: "7") == 2)
        #expect(LineColorAssigner.hashedIndex(for: "112") == 7)
        #expect(LineColorAssigner.hashedIndex(for: "") == 5)
    }

    @Test func hashInRange() {
        for id in ["41", "18", "7", "112", "mock-112", "", "‏קו 5"] {
            let index = LineColorAssigner.hashedIndex(for: id)
            #expect(index >= 0 && index < 12)
        }
    }

    @Test func resolveKeepsPersisted() {
        let resolved = LineColorAssigner.resolve(persisted: ["41": 9], selected: ["41", "18"])
        #expect(resolved["41"] == 9)
    }

    @Test func resolveAvoidsCollisionAmongSelected() {
        // Every line asks for the same colour, so only the fallback rule can separate them.
        let ids = ["a", "b", "c"]
        let wanted = LineColorAssigner.hashedIndex(for: ids[0])
        let resolved = LineColorAssigner.resolve(persisted: [:], selected: ids,
                                                 preferred: ids.reduce(into: [:]) { $0[$1] = wanted })
        let indices = ids.compactMap { resolved[$0] }
        #expect(Set(indices).count == 3)
        // Distinct is not enough: two rails read across a room have to differ in hue as well.
        let pairs = indices.indices.flatMap { left in
            indices.indices.filter { $0 > left }.map { (indices[left], indices[$0]) }
        }
        #expect(pairs.allSatisfy { LineColorAssigner.hueDistance($0, $1) >= 40 })
    }

    /// The palette's own promises, against the real ground it is drawn on. The amber rail is the
    /// brief's own value and is the one entry that cannot reach 3:1, which the palette records.
    @Test func lightPaletteHoldsItsContrast() {
        let cream: UInt32 = 0xF4F2EC
        for index in 0..<LinePalette.count {
            #expect(contrast(LinePalette.lightText[index], cream) >= 4.5,
                    "lightText \(index) is unreadable on cream")
            if index != 1 {
                #expect(contrast(LinePalette.lightRail[index], cream) >= 3,
                        "lightRail \(index) does not separate from cream")
            }
        }
        #expect(contrast(LinePalette.lightRail[1], cream) < 3)
    }

    @Test func darkPaletteHoldsItsContrast() {
        let ink: UInt32 = 0x08080B
        for index in 0..<LinePalette.count {
            #expect(contrast(LinePalette.darkRail[index], ink) >= 4.5,
                    "darkRail \(index) is unreadable on the dark ground")
        }
    }

    @Test func resolveNeverChangesAnAlreadyPersistedSelectedLine() {
        let persisted = ["41": 0, "18": 0]   // a clash inherited from an older build
        let resolved = LineColorAssigner.resolve(persisted: persisted, selected: ["41", "18"])
        #expect(resolved["41"] == 0)
        #expect(resolved["18"] == 0)
    }

    /// A numeral has to be readable on its own badge. The dark palette is bright enough that ink
    /// always wins; the light one is darkened to work as a rail and mostly cannot carry ink at all.
    ///
    /// The bar is WCAG's large-text 3:1, which is the one that applies: every badge numeral is
    /// Archivo Black at 15 pt or more, well past the 14 pt bold the standard asks for. Two of the
    /// light rails land between 4.3 and 4.5, so the small-text bar is recorded separately rather
    /// than asserted — tightening it would mean recolouring the artboards' own rails.
    @Test func everyNumeralIsReadableOnItsOwnFill() {
        var clearingSmallText = 0
        for index in 0..<LinePalette.count {
            for isLight in [false, true] {
                let fill = (isLight ? LinePalette.lightRail : LinePalette.darkRail)[index]
                let ink: UInt32 = isLight ? 0x14140F : 0x08080B
                let best = max(LinePalette.contrast(fill, ink), LinePalette.contrast(fill, 0xFFFFFF))
                #expect(best >= 3, "line \(index) \(isLight ? "light" : "dark") reaches only \(best):1")
                if best >= 4.5 { clearingSmallText += 1 }
            }
        }
        #expect(clearingSmallText >= 22)
    }

    @Test func theDarkPaletteKeepsItsInkNumerals() {
        for index in 0..<LinePalette.count {
            let fill = LinePalette.darkRail[index]
            #expect(LinePalette.contrast(fill, 0x08080B) > LinePalette.contrast(fill, 0xFFFFFF))
        }
    }

    /// Most of the light palette is too dark for ink, which is what made the numbers unreadable.
    @Test func theLightPaletteNeedsWhiteOnItsDarkerEntries() {
        let needingWhite = (0..<LinePalette.count).filter { index in
            let fill = LinePalette.lightRail[index]
            return LinePalette.contrast(fill, 0xFFFFFF) > LinePalette.contrast(fill, 0x14140F)
        }
        #expect(needingWhite.count >= 6)
        // Amber is the exception the artboards draw with ink.
        #expect(needingWhite.contains(1) == false)
    }

    @Test func luminanceMatchesTheKnownEnds() {
        #expect(abs(LinePalette.relativeLuminance(0xFFFFFF) - 1) < 0.001)
        #expect(abs(LinePalette.relativeLuminance(0x000000)) < 0.001)
        #expect(abs(LinePalette.contrast(0xFFFFFF, 0x000000) - 21) < 0.01)
    }

    @Test func provisionalIndexFallsBackToTheHash() {
        #expect(LineColorAssigner.provisionalIndex(for: "41", persisted: [:]) == LineColorAssigner.hashedIndex(for: "41"))
        #expect(LineColorAssigner.provisionalIndex(for: "41", persisted: ["41": 4]) == 4)
    }
}

/// WCAG relative luminance and contrast, computed here rather than taken from the app, so the
/// palette is measured against the standard and not against itself.
private func luminance(_ hex: UInt32) -> Double {
    let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { value -> Double in
        let part = Double(value) / 255
        return part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
}

private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (high + 0.05) / (low + 0.05)
}

/// The board scales as one piece, which is right for the numerals and wrong for the text that
/// supports them: a small window drove the kicker under 10 pt.
struct TypeScaleTests {

    /// A Mac window at about two thirds of the reference board.
    private let small: CGFloat = 0.64

    @Test func supportingTextStopsShrinking() {
        for style in [TypeStyles.kicker, TypeStyles.kickerSmall, TypeStyles.kickerPad,
                      TypeStyles.subStopsAway, TypeStyles.subArrives,
                      TypeStyles.subPhone, TypeStyles.thenLabel, TypeStyles.thenSub] {
            #expect(style.size(at: small) >= 13, "\(style.face.rawValue) at \(style.size) fell to \(style.size(at: small))")
            #expect(style.size(at: small) > style.size * small)
        }
    }

    @Test func theNumeralsScaleFreely() {
        for style in [TypeStyles.minutesPrimary, TypeStyles.minutesSecondary, TypeStyles.tappedMinutes] {
            #expect(style.size(at: small) == style.size * small)
        }
        // Still large at a third of the board, so a floor would only distort the composition.
        #expect(TypeStyles.minutesPrimary.size(at: 0.32) > 35)
    }

    /// The setup screen's captions ("EDIT", "10 STOPS WITHIN 500 M") shrank to 8 pt on an iPad.
    /// Nothing reads below the system's caption size, whatever the scale.
    @Test func noStyleFallsBelowACaption() {
        for style in [TypeStyles.countCaption, TypeStyles.countCaptionPhone, TypeStyles.stepCaptionPhone,
                      TypeStyles.pickerSubtitlePhone, TypeStyles.chipDestinationPhone, TypeStyles.hint,
                      TypeStyles.creditLinePhone, TypeStyles.stopAddressPhone, TypeStyles.footerHintPhone] {
            #expect(style.size(at: small) >= TypeStyle.readableMinimum)
            #expect(style.size(at: 0.3) >= TypeStyle.readableMinimum)
        }
    }

    /// The layout engine still scales map labels as geometry; the floor is applied where they are
    /// drawn, so the map composition is unchanged and only the text is held legible.
    @Test func mapLabelsScaleAsGeometry() {
        let full = MapMetrics(preset: .landscape, scale: 1, lineCount: 3)
        let half = MapMetrics(preset: .landscape, scale: 0.5, lineCount: 3)
        #expect(half.stopNameFontSize == full.stopNameFontSize / 2)
        #expect(half.dashFontSize == full.dashFontSize / 2)
    }

    /// A name held at the readable floor on a small board still wraps between words: its box grows
    /// to the longest word as drawn, and no further.
    @Test func mapLabelsNeverBreakAWord() {
        let small = MapMetrics(preset: .landscape, scale: 0.58, lineCount: 2)
        let drawn = TypeStyle.readableMinimum
        let perGlyph = drawn * MapMetrics.monoAdvanceEm + small.stopNameFontSize * small.stopNameTrackingEm
        #expect(small.labelMaxWidth(for: "NORTHGATE") >= 9 * perGlyph)
        #expect(small.labelMaxWidth(for: "AIRPORT LOOP") < 12 * perGlyph)
        #expect(small.labelMaxWidth(for: "V 1") == small.labelMaxWidth)

        let full = MapMetrics(preset: .landscape, scale: 1, lineCount: 2)
        #expect(full.labelMaxWidth(for: "NORTHGATE") == full.labelMaxWidth)
    }

    /// Two lines of a name held at the floor fit between neighbouring stops, and between the
    /// terminus and the first stop; a full-size board keeps the design's spacing.
    @Test func floorHeldNamesGetRoomBetweenStops() {
        let depth = 2 * TypeStyle.readableMinimum * MapMetrics.lineHeightEm
        let gapNeeded = depth / sin(35 * CGFloat.pi / 180)
        let small = MapMetrics(preset: .landscape, scale: 0.58, lineCount: 3)
        #expect(small.stopPitch >= gapNeeded)
        #expect(small.firstStopAlong - small.terminusCenterAlong >= gapNeeded)

        let full = MapMetrics(preset: .landscape, scale: 1, lineCount: 3)
        #expect(full.stopPitch == 100)
        #expect(full.firstStopAlong == 110)
    }

    @Test func aBoardLargerThanTheReferenceIsUnaffected() {
        for style in [TypeStyles.kicker, TypeStyles.subArrives, TypeStyles.thenSub] {
            #expect(style.size(at: 1.4) == style.size * 1.4)
        }
    }
}
