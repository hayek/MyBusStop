#if os(tvOS)
import SwiftUI

/// The board as the Top Shelf's carousel shows it: full screen, with the Home Screen's row of
/// apps over its lower third and the system clock in its top corner. So the numbers leave the
/// band along the bottom that the board puts them in, and stand in a column on the right above
/// the dock, beside the map; the clock gives way to the time the picture was drawn.
struct TVShelfBoardView: View {
    @Environment(\.colorScheme) private var colorScheme
    var model: BoardViewModel
    var drawnAt: Date

    /// Everything that matters stays above this: the dock covers the rest.
    static let clearHeight: CGFloat = 720
    static let inset: CGFloat = 80
    static let columnWidth: CGFloat = 620

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        let size = TopShelfBoards.size
        let mapWidth = size.width - Self.columnWidth - Self.inset * 3
        // The landscape board at 1.2×, its map given the room left of the column.
        var layout = BoardLayout.resolve(size: CGSize(width: 1536, height: 864), lineCount: model.lines.count,
                                         horizontal: .regular, vertical: .regular)
        let _ = layout.mapSize = CGSize(width: mapWidth, height: Self.clearHeight - 190)
        HStack(alignment: .top, spacing: Self.inset) {
            VStack(alignment: .leading, spacing: 20) {
                if let stop = model.stop {
                    Text(stop.name)
                        .busText(layout.titleStyle, scale: layout.scale)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                MapView(layout: layout, model: model, showsHint: false)
                    .frame(width: layout.mapSize.width, height: layout.mapSize.height)
            }
            .frame(width: mapWidth, alignment: .leading)
            readout(layout: layout, theme: theme)
                .frame(width: Self.columnWidth, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 70)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(theme.background)
        .busTheme()
    }

    @ViewBuilder private func readout(layout: BoardLayout, theme: Theme) -> some View {
        let scale = layout.scale
        VStack(alignment: .leading, spacing: 36) {
            // Where the board's clock stood, under the system's: the picture is only this recent.
            Text("AT \(drawnAt.formatted(date: .omitted, time: .shortened))")
                .busText(TypeStyles.kicker, scale: scale)
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 90)
            if let primary = model.primary {
                VStack(alignment: .leading, spacing: 12 * scale) {
                    Text(primary.kicker.text)
                        .busText(TypeStyles.kicker, scale: scale)
                        .foregroundStyle(theme.captionText)
                    HStack(alignment: .center, spacing: 24 * scale) {
                        LineBadgeView(number: primary.line.shortName, colorIndex: primary.colorIndex,
                                      side: 96 * scale, cornerRadius: 22 * scale, numeralSize: 52 * scale,
                                      ring: nil)
                        MinutesView(arrival: primary.arrival, colorIndex: primary.colorIndex,
                                    numberStyle: TypeStyles.minutesPrimaryBeside, unitStyle: TypeStyles.unitPrimaryBeside,
                                    scale: scale, spacing: 10)
                    }
                    ReadoutSubline(arrival: primary.arrival, scale: scale,
                                   stopsStyle: TypeStyles.subBeside, timeStyle: TypeStyles.subBeside,
                                   spacing: 8, includesStopsWord: true)
                }
            } else {
                Text("NO BUSES DUE")
                    .busText(TypeStyles.titleLandscape, scale: scale * 0.8)
                    .foregroundStyle(theme.primaryText)
            }
            if let secondary = model.secondary {
                ThenCardView(secondary: secondary, scale: scale * 0.85, style: .card)
                    .frame(width: Self.columnWidth, height: 230)
            }
        }
        .frame(maxHeight: Self.clearHeight, alignment: .top)
    }
}
#endif
