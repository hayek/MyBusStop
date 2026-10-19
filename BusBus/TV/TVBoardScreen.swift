#if os(tvOS)
import SwiftUI
import TVServices

/// The board, driven by the Siri Remote. The whole board is one focusable button, so none of its
/// own buttons (the header's, the pucks) take focus from it:
/// - select (or play/pause) steps through the upcoming buses, as tapping each puck would, then lets go;
/// - left and right flip to the neighbouring saved stop;
/// - Menu lets go of a bus first, then goes back to the stops.
struct TVBoardScreen: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Bindable var model: BoardViewModel
    /// +1 for the next stop in the home row's order, −1 for the one before.
    var onMove: (Int) -> Void
    var onBack: () -> Void

    var body: some View {
        Button(action: selectNextBus) {
            BoardView(model: model, onChangeStop: onBack)
                // A button sizes to its label, and the board's reader has no size of its own.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TVBareButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onMoveCommand { direction in
            // The row runs the reading direction's way, so right is "next" only left to right.
            let forward = layoutDirection == .rightToLeft ? MoveCommandDirection.left : .right
            switch direction {
            case forward: onMove(1)
            case .left, .right: onMove(-1)
            default: break
            }
        }
        // The remote's play/pause does what select does: the one other button a hand finds.
        .onPlayPauseCommand(perform: selectNextBus)
        .onExitCommand {
            if model.selectedBusID != nil { model.dismissTapped() } else { onBack() }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Every refresh, a picture of this board for the Top Shelf.
        .onChange(of: model.lastSuccessAt) {
            TVBoardPicture.draw(model: model, colorScheme: colorScheme, locale: locale,
                                layoutDirection: layoutDirection)
        }
        .analyticsScreen("tv_board")
    }

    private func selectNextBus() {
        let buses = model.snapshot.arrivals.compactMap { $0.bus?.id }
        if let next = TVStopOrder.nextBus(after: model.selectedBusID, in: buses) {
            model.tap(busID: next)
        } else {
            model.dismissTapped()
        }
    }
}

/// Draws the board as it is now into the App Group, where the Top Shelf finds it
/// (`TopShelfBoards`), and tells the Top Shelf. At most once a minute per stop: the picture only
/// has to be recent, and each one costs a full-screen render.
@MainActor enum TVBoardPicture {
    static let interval: TimeInterval = 60
    private static var lastDrawn: [String: Date] = [:]

    static func draw(model: BoardViewModel, colorScheme: ColorScheme, locale: Locale,
                     layoutDirection: LayoutDirection, now: Date = .now) {
        guard WidgetBridge.isActive || ScreenshotMode.current != nil, let configuration = model.configuration,
              !model.snapshot.arrivals.isEmpty else { return }
        let setupID = SavedSetup.identifier(stop: configuration.stop, lineIDs: configuration.lines.map(\.id))
        if let last = lastDrawn[setupID], now.timeIntervalSince(last) < interval { return }
        guard let url = TopShelfBoards.url(for: setupID) else { return }
        let size = TopShelfBoards.size
        let renderer = ImageRenderer(content: TVShelfBoardView(model: model, drawnAt: now)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        guard let data = renderer.uiImage?.pngData() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        lastDrawn[setupID] = now
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}

/// A button with no look of its own: the board is the whole screen, and a lift or a glow would
/// only move it.
struct TVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif
