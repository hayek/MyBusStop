import Testing
import CoreGraphics
import SwiftUI
@testable import BusBus

private func resolve(_ w: CGFloat, _ h: CGFloat, lines: Int = 3,
                     vertical: UserInterfaceSizeClass? = nil) -> BoardLayout {
    BoardLayout.resolve(size: CGSize(width: w, height: h), lineCount: lines, vertical: vertical)
}

struct BoardLayoutModeTests {

    @Test func iPhone8Landscape_isLandscape() {
        #expect(resolve(667, 375, vertical: .compact).mode == .landscape)
    }

    @Test func modernPhoneLandscape_isLandscape() {
        #expect(resolve(844, 390, vertical: .compact).mode == .landscape)
    }

    @Test func iPhonePortrait_isPhone() {
        let layout = resolve(393, 852)
        #expect(layout.mode == .phone)
        #expect(layout.axis == .vertical)
    }

    @Test func iPadPortrait_isPad() {
        #expect(resolve(834, 1194).mode == .pad)
    }

    @Test func iPadLandscape_isLandscape() {
        #expect(resolve(1194, 834).mode == .landscape)
    }

    @Test func macSmallWindow_usesPortraitRules() {
        // The brief's rule: below about 900 pt wide the Mac switches to the portrait composition,
        // even in a window that is wider than it is tall.
        #expect(resolve(880, 700).mode == .pad)
        #expect(resolve(700, 880).mode == .pad)
        #expect(resolve(960, 700).mode == .landscape)
    }

    @Test func mac1280x720_scaleOne() {
        let layout = resolve(1280, 720)
        #expect(abs(layout.scale - 1) < 0.001)
        #expect(abs(layout.headerHeight - 72) < 0.001)
        #expect(abs(layout.readoutHeight - 268) < 0.001)
        #expect(abs(layout.mapSize.height - 380) < 0.001)
        #expect(abs(layout.sideInset - 40) < 0.001)
    }

    @Test func splitViewThird_isPhone() {
        #expect(resolve(375, 1024).mode == .phone)
    }

    @Test func foldedCover_isPhone() {
        #expect(resolve(380, 800).mode == .phone)
    }

    @Test func unfoldedSquarish_isPad() {
        #expect(resolve(900, 1000).mode == .pad)
    }

    @Test func unfoldedWide_isLandscape() {
        #expect(resolve(1200, 1000).mode == .landscape)
    }

    @Test func oneLine_usesTheSingleLinePreset() {
        let layout = resolve(1280, 720, lines: 1)
        #expect(layout.mode == .landscapeSingle)
        #expect(layout.preset == .landscapeSingle)
    }

    @Test func phoneThreeLines_namesOnlyTrunk() {
        #expect(resolve(390, 844, lines: 3).namesAllLines == false)
        #expect(resolve(390, 844, lines: 2).namesAllLines)
        #expect(resolve(834, 1194, lines: 3).namesAllLines)
    }

    @Test func scaleIsClamped() {
        // Sizes chosen so both clamps actually run: 3840×2160 wants 3.0, 100×200 wants 0.24.
        #expect(resolve(3840, 2160).scale == BoardLayout.maximumScale)
        #expect(resolve(100, 200).scale == BoardLayout.minimumScale)
    }

    @Test func aWindowTooSmallForTheReadoutIsCompact() {
        #expect(resolve(100, 200).isCompact)
        #expect(resolve(390, 844).isCompact == false)
        #expect(resolve(1280, 720).isCompact == false)
    }

    @Test func mapTakesTheRemainingHeight() {
        let layout = resolve(1280, 900)
        #expect(abs(layout.headerHeight + layout.mapSize.height + layout.readoutHeight - 900) < 0.001)
    }
}

/// The design's inset and the system's are two answers to "keep this off the edge", so the board
/// takes the larger of the two rather than adding one to the other.
struct BoardLayoutSafeAreaTests {

    private func landscapePhone(safeArea: BoardLayout.SafeArea) -> BoardLayout {
        BoardLayout.resolve(size: CGSize(width: 932, height: 409), lineCount: 3,
                            vertical: .compact, safeArea: safeArea)
    }

    @Test func theSystemsMarginIsNotAddedToTheDesigns() {
        let layout = landscapePhone(safeArea: BoardLayout.SafeArea(leading: 59, trailing: 59))
        #expect(layout.sideInset < 59)
        #expect(layout.contentInsetLeading == 59)
        #expect(layout.contentInsetTrailing == 59)
        // Stacking them is what pushed the readout 82 pt in from a 59 pt reservation.
        #expect(layout.contentInsetLeading < 59 + layout.sideInset)
    }

    @Test func theDesignsMarginStillAppliesWhereThereIsNoSystemOne() {
        let layout = landscapePhone(safeArea: BoardLayout.SafeArea())
        #expect(layout.contentInsetLeading == layout.sideInset)
        #expect(layout.contentInsetTrailing == layout.sideInset)
    }

    @Test func eachEdgeIsMeasuredOnItsOwn() {
        let layout = landscapePhone(safeArea: BoardLayout.SafeArea(leading: 59, trailing: 0))
        #expect(layout.contentInsetLeading == 59)
        #expect(layout.contentInsetTrailing == layout.sideInset)
    }
}

/// Only one side of a phone in landscape is actually obstructed, but the system reserves both.
struct SensorHousingLayoutTests {

    private func landscape(housing: HorizontalEdge?) -> BoardLayout {
        BoardLayout.resolve(size: CGSize(width: 874, height: 382), lineCount: 3, vertical: .compact,
                            safeArea: BoardLayout.SafeArea(leading: 62, trailing: 62),
                            housingEdge: housing)
    }

    @Test func theObstructedSideKeepsTheReservation() {
        let layout = landscape(housing: .leading)
        #expect(layout.contentInsetLeading == 62)
        #expect(layout.mapInsetLeading == 62)
    }

    @Test func theClearSideKeepsOnlyTheDesignsMargin() {
        let layout = landscape(housing: .leading)
        #expect(layout.contentInsetTrailing == layout.sideInset)
        #expect(layout.contentInsetTrailing < 62)
    }

    @Test func theSidesSwapWithThePhone() {
        let layout = landscape(housing: .trailing)
        #expect(layout.mapInsetTrailing == 62)
        #expect(layout.mapInsetLeading == layout.sideInset)
    }

    /// The map stands off the edge by the same amount as the readout below it.
    @Test func theMapKeepsTheSameMarginAsEverythingElse() {
        let layout = landscape(housing: .leading)
        #expect(layout.mapInsetLeading == layout.contentInsetLeading)
        #expect(layout.mapInsetTrailing == layout.contentInsetTrailing)
    }

    /// The artboards run their bands to the top and bottom edges, so the board adds nothing there.
    @Test func verticallyItTakesOnlyWhatTheSystemReserved() {
        let layout = BoardLayout.resolve(size: CGSize(width: 1280, height: 720), lineCount: 3,
                                         safeArea: BoardLayout.SafeArea(top: 0, bottom: 34))
        #expect(layout.contentInsetTop == 0)
        #expect(layout.contentInsetBottom == 34)
    }

    /// Leading is the right-hand side in a right-to-left language, so the same notch is a
    /// different edge there.
    @Test func theHousingSideIsTranslatedIntoTheLayoutsOwnEdges() {
        #expect(SensorHousing.edge(of: .right, in: .leftToRight) == .trailing)
        #expect(SensorHousing.edge(of: .left, in: .leftToRight) == .leading)
        #expect(SensorHousing.edge(of: .right, in: .rightToLeft) == .leading)
        #expect(SensorHousing.edge(of: .left, in: .rightToLeft) == .trailing)
        #expect(SensorHousing.edge(of: nil, in: .rightToLeft) == nil)
    }

    @Test func withNoHousingBothSidesKeepTheReservation() {
        let layout = landscape(housing: nil)
        #expect(layout.contentInsetLeading == 62)
        #expect(layout.contentInsetTrailing == 62)
    }

    /// The map's frame has to match the slot it is padded into, or it overhangs and is clipped.
    @Test func theMapsWidthMatchesItsPadding() {
        for housing in [HorizontalEdge.leading, .trailing, nil] {
            let layout = landscape(housing: housing)
            #expect(layout.mapSize.width == 874 - layout.mapInsetLeading - layout.mapInsetTrailing)
        }
    }

    @Test func aSquareWindowIsLandscape() {
        let square = BoardLayout.resolve(size: CGSize(width: 1000, height: 1000), lineCount: 3)
        #expect(square.mode == .landscape)
    }

    @Test func aWallInLandscapeGivesTheReadoutAThirdAndTheFullHeight() {
        let wall = BoardLayout.resolve(size: CGSize(width: 1280, height: 720), lineCount: 2, wall: true)
        #expect(wall.wallReadoutWidth == 427)
        #expect(wall.readoutHeight == 720)
        // The map takes the column beside it, under the header.
        #expect(wall.mapSize == CGSize(width: 1280 - 427 - 24 - 40, height: 720 - 72))
        // The readout grows until its column's width runs out.
        #expect(abs(wall.wallReadoutScale - (427 - 80) / 360) < 0.001)
    }

    @Test func anIPadWallReadoutIsBoundByItsWidth() {
        let wall = BoardLayout.resolve(size: CGSize(width: 1376, height: 1032), lineCount: 2, wall: true)
        #expect(wall.wallReadoutWidth == 459)
        #expect(wall.wallReadoutScale * BoardLayout.wallReadoutContent.height < 1032)
    }

    @Test func aWallInPortraitKeepsTheUsualBoard() {
        #expect(!BoardLayout.resolve(size: CGSize(width: 390, height: 844), lineCount: 2, wall: true).isWall)
        #expect(!BoardLayout.resolve(size: CGSize(width: 1280, height: 720), lineCount: 2).isWall)
    }
}
