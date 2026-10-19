import SwiftUI

/// Portrait readout. The node of the map lands on the centre line of this block, which is what
/// holds the composition together at any width.
struct ReadoutPortraitView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var model: BoardViewModel

    private var isPad: Bool { layout.mode == .pad }

    var body: some View {
        let beside = model.tappedDetail
        VStack(alignment: .leading, spacing: 0) {
            if let primary = model.primary {
                if beside != nil {
                    shrunkPrimaryBlock(primary)
                } else {
                    primaryBlock(primary)
                }
            } else if model.isAwaitingFirstBoard {
                ReadoutSkeleton(badgeSide: (isPad ? 110 : 76) * layout.scale,
                                badgeRadius: (isPad ? 26 : 18) * layout.scale,
                                kickerAbove: true, scale: layout.scale)
            } else {
                emptyState
            }
            Spacer(minLength: 12 * layout.scale)
            // As in landscape, the tapped bus takes the "then" card's place in the readout, so the
            // map above stays live: another puck can be tapped, and a tap elsewhere lets go.
            if let beside {
                TappedBusCardView(detail: beside, scale: layout.scale * (isPad ? 1 : 0.85), onDismiss: { model.dismissTapped() },
                                  onAboutLine: model.canInspectLine(beside.line) ? { model.inspectLine(beside.line) } : nil)
            } else if let secondary = model.secondary {
                ThenCardView(secondary: secondary, scale: layout.scale, style: isPad ? .padBar : .phoneRow)
            }
        }
        .padding(.top, (isPad ? 28 : 24) * layout.scale)
        .padding(.bottom, (isPad ? 32 : 26) * layout.scale)
        .padding(.leading, layout.contentInsetLeading)
        .padding(.trailing, layout.contentInsetTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.readoutBand)
    }

    private func primaryBlock(_ primary: ReadoutPrimary) -> some View {
        VStack(alignment: .leading, spacing: (isPad ? 14 : 12) * layout.scale) {
            Text(primary.kicker.text)
                .busText(isPad ? TypeStyles.kickerPad : TypeStyles.kickerSmall, scale: layout.scale)
                .foregroundStyle(theme.captionText)
            HStack(alignment: .center,
                   spacing: (isPad ? Spacing.primaryBadgeGapPad : Spacing.primaryBadgeGapPhone) * layout.scale) {
                LineBadgeView(number: primary.line.shortName, colorIndex: primary.colorIndex,
                              side: (isPad ? 110 : 76) * layout.scale,
                              cornerRadius: (isPad ? 26 : 18) * layout.scale,
                              numeralSize: (isPad ? 60 : 40) * layout.scale,
                              ring: LineBadgeView.Ring(halo: theme.readoutBand,
                                                       haloWidth: (isPad ? 6 : 5) * layout.scale,
                                                       ringWidth: (isPad ? 5 : 4) * layout.scale))
                MinutesView(arrival: primary.arrival, colorIndex: primary.colorIndex,
                            numberStyle: isPad ? TypeStyles.minutesPrimaryPad : TypeStyles.minutesPrimaryPhone,
                            unitStyle: isPad ? TypeStyles.unitPrimaryPad : TypeStyles.unitPrimaryPhone,
                            scale: layout.scale, spacing: isPad ? 14 : 10)
            }
            if isPad {
                ReadoutSubline(arrival: primary.arrival, scale: layout.scale,
                               timeColor: theme.captionText)
            } else {
                ReadoutSubline(arrival: primary.arrival, scale: layout.scale,
                               stopsStyle: TypeStyles.subPhone, timeStyle: TypeStyles.subPhone,
                               spacing: 8,
                               timeColor: theme.captionText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The next arrival, pulled down to one row so the tapped card beneath it has room.
    private func shrunkPrimaryBlock(_ primary: ReadoutPrimary) -> some View {
        HStack(alignment: .center, spacing: (isPad ? 20 : 16) * layout.scale) {
            // The ring moves to the tapped puck, so the badge drops it.
            LineBadgeView(number: primary.line.shortName, colorIndex: primary.colorIndex,
                          side: (isPad ? 64 : 48) * layout.scale,
                          cornerRadius: (isPad ? 16 : 12) * layout.scale,
                          numeralSize: (isPad ? 32 : 24) * layout.scale, ring: nil)
            VStack(alignment: .leading, spacing: 6 * layout.scale) {
                Text(primary.kicker.text)
                    .busText(TypeStyles.kickerSmall, scale: layout.scale)
                    .foregroundStyle(theme.captionText)
                MinutesView(arrival: primary.arrival, colorIndex: primary.colorIndex,
                            numberStyle: TypeStyles.minutesSecondaryPhone,
                            unitStyle: TypeStyles.unitSecondaryPhone,
                            scale: layout.scale, spacing: 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8 * layout.scale) {
            Text(model.lastError == nil ? "NO BUSES DUE" : "NO LIVE DATA" as LocalizedStringKey)
                .busText(isPad ? TypeStyles.titlePad : TypeStyles.titlePhone, scale: layout.scale)
                .foregroundStyle(theme.primaryText)
            Text(model.lastError == nil ? "NOTHING SCHEDULED RIGHT NOW" : "SHOWING THE LAST KNOWN BOARD" as LocalizedStringKey)
                .busText(TypeStyles.kickerSmall, scale: layout.scale)
                .foregroundStyle(theme.secondaryText)
        }
    }
}
