import SwiftUI

/// The landscape readout: the number you read from across the room, and the bus after it.
struct ReadoutView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var model: BoardViewModel

    var body: some View {
        let beside = model.tappedDetail
        HStack(alignment: .center,
               spacing: (beside == nil ? Spacing.readoutGap : Spacing.readoutGapBeside) * layout.scale) {
            if let primary = model.primary {
                primaryBlock(primary, shrunk: beside != nil)
            } else if model.isAwaitingFirstBoard {
                ReadoutSkeleton(badgeSide: 104 * layout.scale, badgeRadius: 24 * layout.scale,
                                kickerAbove: false, scale: layout.scale)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
            if let beside {
                TappedBusCardView(detail: beside, scale: layout.scale, onDismiss: { model.dismissTapped() },
                                  onAboutLine: model.canInspectLine(beside.line) ? { model.inspectLine(beside.line) } : nil)
                    .frame(width: Spacing.tappedCardWidth * layout.scale)
            } else if let secondary = model.secondary {
                ThenCardView(secondary: secondary, scale: layout.scale, style: .card)
                    .frame(width: Spacing.thenCardWidth * layout.scale)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.top, Spacing.readoutTop * layout.scale)
        .padding(.bottom, Spacing.readoutBottom * layout.scale)
        .padding(.leading, layout.contentInsetLeading)
        .padding(.trailing, layout.contentInsetTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.readoutBand)
    }

    private func primaryBlock(_ primary: ReadoutPrimary, shrunk: Bool) -> some View {
        HStack(alignment: .center,
               spacing: (shrunk ? Spacing.primaryBadgeGapBeside : Spacing.primaryBadgeGap) * layout.scale) {
            LineBadgeView(number: primary.line.shortName, colorIndex: primary.colorIndex,
                          side: (shrunk ? 84 : 104) * layout.scale,
                          cornerRadius: (shrunk ? 20 : 24) * layout.scale,
                          numeralSize: (shrunk ? 46 : 58) * layout.scale,
                          // The ring moves to the tapped puck in beside mode, so the badge drops it.
                          ring: shrunk ? nil : LineBadgeView.Ring(halo: theme.readoutBand,
                                                                 haloWidth: 6 * layout.scale,
                                                                 ringWidth: 5 * layout.scale))
            VStack(alignment: .leading, spacing: (shrunk ? 6 : 8) * layout.scale) {
                Text(primary.kicker.text)
                    .busText(shrunk ? TypeStyles.kickerSmall : TypeStyles.kicker, scale: layout.scale)
                    .foregroundStyle(theme.captionText)
                MinutesView(arrival: primary.arrival, colorIndex: primary.colorIndex,
                            numberStyle: shrunk ? TypeStyles.minutesPrimaryBeside : TypeStyles.minutesPrimary,
                            unitStyle: shrunk ? TypeStyles.unitPrimaryBeside : TypeStyles.unitPrimary,
                            scale: layout.scale, spacing: shrunk ? 10 : 14)
                if shrunk {
                    ReadoutSubline(arrival: primary.arrival, scale: layout.scale,
                                   stopsStyle: TypeStyles.subBeside, timeStyle: TypeStyles.subBeside,
                                   spacing: 8, includesStopsWord: false)
                } else {
                    ReadoutSubline(arrival: primary.arrival, scale: layout.scale)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8 * layout.scale) {
            Text(model.lastError == nil ? "NO BUSES DUE" : "NO LIVE DATA" as LocalizedStringKey)
                .busText(TypeStyles.titleLandscape, scale: layout.scale * 0.7)
                .foregroundStyle(theme.primaryText)
            Text(model.lastError == nil ? "NOTHING SCHEDULED RIGHT NOW" : "SHOWING THE LAST KNOWN BOARD" as LocalizedStringKey)
                .busText(TypeStyles.kicker, scale: layout.scale)
                .foregroundStyle(theme.secondaryText)
        }
    }
}
