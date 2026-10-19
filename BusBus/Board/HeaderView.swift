import SwiftUI

/// Stop name, its code, whether the data is live, and the time. No rules below it: the sections of
/// the board separate by space and, in dark mode, by the readout band sitting a shade lighter.
struct HeaderView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var model: BoardViewModel
    /// The back chevron before the stop's name goes back, to change the stop; the name itself
    /// changes which of its lines are watched.
    var onChangeStop: () -> Void
    var onSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(alignment: layout.mode == .landscapeSingle ? .center : .lastTextBaseline,
                   spacing: Spacing.headerGap * layout.scale) {
                if layout.mode == .landscapeSingle, let line = model.lines.first {
                    LineBadgeView(number: line.shortName, colorIndex: model.colorIndex(line.id),
                                  side: 44 * layout.scale, cornerRadius: 12 * layout.scale,
                                  numeralSize: 24 * layout.scale, ring: nil)
                }
                title
                    // Where the first board's tip points: its arrow lands on the chevron.
                    .anchorPreference(key: StopTitleAnchorKey.self, value: .bounds) { $0 }
                // Apple TV changes lines from its own picker; the board there is one button.
                #if !os(tvOS)
                fullRouteButton
                #endif
                Spacer(minLength: 0)
                // The artboards baseline the title and its code together and centre everything to
                // the right of them, so the clock and the gear sit on the header's own centre line.
                HStack(alignment: .center, spacing: trailingGap * layout.scale) {
                    LiveIndicatorView(state: model.liveState(at: context.now),
                                      secondsSinceUpdate: model.secondsSinceUpdate(at: context.now),
                                      style: layout.liveLabelStyle, scale: layout.scale,
                                      showsLabel: layout.showsLiveLabel)
                    ClockView(style: layout.clockStyle, scale: layout.scale)
                    #if !os(tvOS)
                    SettingsGearButton(size: 20 * layout.scale, action: onSettings)
                    #endif
                }
                // The wall column is narrow: the stop's name shrinks before the live label wraps.
                .fixedSize(horizontal: layout.isWall, vertical: false)
            }
            .padding(.leading, layout.contentInsetLeading)
            .padding(.trailing, layout.contentInsetTrailing)
            .frame(height: layout.headerHeight)
        }
    }

    /// Every stop of the watched lines, end to end, without the map's folds (`FullRouteView`).
    private var fullRouteButton: some View {
        Button { model.showsFullRoute = true } label: {
            // In a rounded rect of its own, so it reads as the button it is and not a glyph.
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 16 * layout.scale, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .frame(width: iconWidth, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.closeButton))
                .frame(width: iconWidth, height: 44)
                .contentShape(Rectangle().inset(by: (iconWidth - 44) / 2))
        }
        .buttonStyle(.plain)
        .disabled(!model.hasFullRoute)
        .accessibilityLabel(Text("Full lines view"))
    }

    /// A phone's header is short of room for the stop's name, so the icon sits narrower than its
    /// target, which reaches the full 44 points into the gap beside it.
    private var iconWidth: CGFloat { layout.mode == .phone ? 36 : 44 }

    private var trailingGap: CGFloat {
        layout.mode == .phone ? Spacing.headerTrailingGapPhone : Spacing.headerTrailingGap
    }

    /// The chevron is the way back, to the stop list; the stop's name keeps the stop and changes
    /// which of its lines are watched (`BoardLinesSheet`). Apple TV keeps settings on its home and
    /// its board is one button, which changes the stop.
    @ViewBuilder private var title: some View {
        #if os(tvOS)
        Button(action: onChangeStop) {
            HStack(alignment: .lastTextBaseline, spacing: Spacing.headerGap * layout.scale) {
                BackChevron(scale: layout.scale)
                name
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(changeStopLabel)
        #else
        HStack(alignment: .lastTextBaseline, spacing: Spacing.headerGap * layout.scale) {
            Button(action: onChangeStop) {
                // A small mark with a target the size of a finger, reaching into the gap around it.
                BackChevron(scale: layout.scale)
                    .contentShape(Rectangle().inset(by: -15))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(changeStopLabel)
            Button { model.showsLinePicker = true } label: {
                name.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.stop == nil)
            // Plain strings: a Text here would take the title's capitals ("CHANGE LINES").
            .accessibilityLabel(String(appLocalized: "Change lines"))
            .accessibilityValue(model.stop?.name ?? "")
        }
        #endif
    }

    private var changeStopLabel: Text {
        if let stop = model.stop { Text("\(stop.name). Change stop and lines") } else { Text("Stop. Change stop and lines") }
    }

    private var name: some View {
        HStack(alignment: .lastTextBaseline, spacing: Spacing.headerGap * layout.scale) {
            Text(model.stop?.name ?? "")
                .busText(layout.titleStyle, scale: layout.scale)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .busText(layout.captionStyle, scale: layout.scale)
                    .foregroundStyle(theme.headerCaption)
                    .lineLimit(1)
            }
        }
    }

    private var caption: String? {
        guard layout.mode != .phone, !layout.isWall, let stop = model.stop else { return nil }
        guard let city = stop.city else { return String(appLocalized: "STOP \(stop.code)") }
        return String(appLocalized: "STOP \(stop.code) · \(city)")
    }
}


/// The way back to the stop list, before the stop's name — where and how a back button points.
private struct BackChevron: View {
    @Environment(\.theme) private var theme
    var scale: CGFloat

    /// Floored like the caption beside it: a small window must not shrink it into a speck.
    private var height: CGFloat { max(13, 15 * scale) }

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: height / 2, y: 0))
            path.addLine(to: CGPoint(x: 0, y: height / 2))
            path.addLine(to: CGPoint(x: height / 2, y: height))
        }
        .stroke(theme.stopName, style: StrokeStyle(lineWidth: max(2, 2.4 * scale),
                                                   lineCap: .round, lineJoin: .round))
        .frame(width: height / 2, height: height)
        .accessibilityHidden(true)
    }
}
