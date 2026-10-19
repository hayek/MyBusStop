import SwiftUI

/// The landscape wall display's readout: the next arrival at the board's full height, in a column
/// a third of its width, beside the map. On a wall the number is the job, so it is read from across
/// the room or not at all.
struct WallReadoutView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var model: BoardViewModel

    private var scale: CGFloat { layout.wallReadoutScale }
    private var margin: CGFloat { BoardLayout.wallReadoutMargin * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let primary = model.primary {
                Spacer(minLength: 0)
                badgeRow(primary)
                MinutesView(arrival: primary.arrival, colorIndex: primary.colorIndex,
                            numberStyle: TypeStyles.minutesWall, unitStyle: TypeStyles.unitWall,
                            scale: scale, spacing: 14)
                    .padding(.top, 20 * scale)
                ReadoutSubline(arrival: primary.arrival, scale: scale,
                               stopsStyle: TypeStyles.subStopsAwayWall, timeStyle: TypeStyles.subArrivesWall,
                               timeColor: theme.captionText, isStacked: true, stackAlignment: .leading)
                    .padding(.top, 16 * scale)
                Spacer(minLength: 24 * scale)
                // The bus after it, read with it rather than with the map; a tapped bus takes its
                // place, as on the board beside the hand.
                if let detail = model.tappedDetail {
                    TappedBusCardView(detail: detail, scale: scale) { model.dismissTapped() }
                        .transition(.opacity)
                } else if let secondary = model.secondary {
                    ThenCardView(secondary: secondary, scale: scale, style: .wallBar)
                }
            } else if model.isAwaitingFirstBoard {
                Spacer(minLength: 0)
                ReadoutSkeleton(badgeSide: 100 * scale, badgeRadius: 24 * scale,
                                kickerAbove: true, scale: scale * 1.6)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, margin)
        .padding(.leading, max(margin, layout.contentInsetLeading))
        .padding(.trailing, margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.readoutBand)
    }

    /// The line's badge, carrying the same ring as its bus on the map unless another bus is
    /// tapped, with what the number below it is.
    private func badgeRow(_ primary: ReadoutPrimary) -> some View {
        HStack(alignment: .center, spacing: 22 * scale) {
            LineBadgeView(number: primary.line.shortName, colorIndex: primary.colorIndex,
                          side: 100 * scale, cornerRadius: 24 * scale, numeralSize: 54 * scale,
                          ring: model.tappedDetail == nil
                              ? LineBadgeView.Ring(halo: theme.readoutBand, haloWidth: 6 * scale, ringWidth: 6 * scale)
                              : nil)
            Text(primary.kicker.text)
                .busText(TypeStyles.kickerWall, scale: scale)
                .foregroundStyle(theme.captionText)
                .lineLimit(2)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            Text(model.lastError == nil ? "NO BUSES DUE" : "NO LIVE DATA" as LocalizedStringKey)
                .busText(TypeStyles.titleLandscape, scale: scale * 1.2)
                .foregroundStyle(theme.primaryText)
            Text(model.lastError == nil ? "NOTHING SCHEDULED RIGHT NOW" : "SHOWING THE LAST KNOWN BOARD" as LocalizedStringKey)
                .busText(TypeStyles.kickerWall, scale: scale)
                .foregroundStyle(theme.secondaryText)
        }
    }
}

/// The column beside the wall readout: the stop and the time over the map.
struct WallColumnView: View {
    var layout: BoardLayout
    var model: BoardViewModel
    var onChangeStop: () -> Void
    var onSettings: () -> Void

    private var scale: CGFloat { layout.scale }

    var body: some View {
        // The header and the map keep the column's narrower inset on the readout's side.
        var column = layout
        column.insets.leading = BoardLayout.wallColumnInset * scale
        return VStack(spacing: 0) {
            HeaderView(layout: column, model: model, onChangeStop: onChangeStop, onSettings: onSettings)
                .frame(height: layout.headerHeight)
            MapView(layout: column, model: model, showsHint: false)
                .frame(height: layout.mapSize.height)
                .padding(.leading, column.insets.leading)
                .padding(.trailing, column.insets.trailing)
        }
        .frame(height: layout.readoutHeight, alignment: .top)
    }
}
