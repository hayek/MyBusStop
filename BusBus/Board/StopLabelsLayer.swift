import SwiftUI

/// Gives a name a width to wrap inside. The box is fixed rather than a maximum because it is
/// measured inside a zero-sized anchor, which would otherwise propose no width at all and collapse
/// every name to one character per line. A short name simply does not reach the far edge.
private struct WrappedLabelWidth: ViewModifier {
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        if maxWidth > 0 {
            content
                .frame(width: maxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}

/// A stop's name as a button for its card, with a little more than the glyphs to aim at. Without
/// an action the name is only drawn, and lets every touch through.
private struct StopNameTap: ViewModifier {
    var code: String
    var action: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle().inset(by: -8))
                .onTapGesture { action(code) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Shows the stop’s lines, address and map"))
        } else {
            content.allowsHitTesting(false)
        }
    }
}

/// A "+N STOPS" caption as the way into the full route, where nothing is folded.
private struct DashTap: ViewModifier {
    var action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle().inset(by: -10))
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Shows every stop of the lines"))
        } else {
            content.allowsHitTesting(false)
        }
    }
}

/// Places a piece of text so that a chosen corner or edge sits exactly on an anchor point, then
/// rotates about that same point. A zero-sized frame carries the anchor, so nothing has to be
/// measured first.
struct AnchoredText<Content: View>: View {
    var anchor: CGPoint
    var alignment: Alignment
    var rotationDegrees: Double
    var rotationAnchor: UnitPoint
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: alignment) { content().fixedSize() }
            .rotationEffect(.degrees(rotationDegrees), anchor: rotationAnchor)
            .position(anchor)
    }
}

/// "YOUR STOP", beside the node in portrait and under it in landscape.
struct YourStopCaption: View {
    @Environment(\.theme) private var theme
    var convergence: ConvergenceMark

    var body: some View {
        AnchoredText(anchor: convergence.captionAnchor,
                     alignment: convergence.captionIsBelow ? .top : .leading,
                     rotationDegrees: 0, rotationAnchor: .center) {
            Text("YOUR STOP")
                .busFont(.spaceMonoBold, size: convergence.captionFontSize,
                         tracking: convergence.captionFontSize * convergence.captionTrackingEm)
                .foregroundStyle(theme.primaryText)
        }
    }
}

/// One stop's name, set where the scene put it.
struct StopName: View {
    var label: StopLabel
    var color: Color
    /// Opens the stop's card. Nil where there is nothing to press.
    var onTap: ((String) -> Void)?

    var body: some View {
        AnchoredText(anchor: label.anchor,
                     alignment: label.rotationDegrees != 0 ? .bottomLeading : Alignment(label.alignment),
                     rotationDegrees: label.rotationDegrees,
                     rotationAnchor: label.rotationDegrees == 0 ? .center : .bottomLeading) {
            let tracked = LocaleAwareBusFont.isTracked(label.text)
            Text(label.text)
                .font(.bus(tracked ? .spaceMonoBold : BusFace.spaceMonoBold.proportional, size: label.fontSize))
                .tracking(tracked ? label.fontSize * label.trackingEm : 0)
                .foregroundStyle(color)
                .lineLimit(label.lineLimit)
                .multilineTextAlignment(.leading)
                .modifier(WrappedLabelWidth(maxWidth: label.maxWidth))
                .modifier(StopNameTap(code: label.stopCode, action: onTap))
        }
    }
}

private extension Alignment {
    init(_ alignment: LabelAlignment) {
        switch alignment {
        case .leading: self = .leading
        case .trailing: self = .trailing
        case .center: self = .center
        }
    }
}

/// Stop names, terminus names and the dashed runs' captions.
///
/// In landscape the names are set at −35°, anchored at the dot and rising to the right. That is the
/// whole reason a stop can have a long name here: parallel lines of text can never collide, so the
/// only cost of a long name is vertical rise, which the row pitch absorbs.
struct StopLabelsLayer: View {
    @Environment(\.theme) private var theme
    var scene: MapScene
    /// The stop a tapped bus last went through, drawn in primary text like a junction.
    var passedStopCode: String?
    /// Opens a stop's card from its name. Nil where there is nothing to press (the widget).
    var onTapStop: ((String) -> Void)? = nil
    /// Opens the full route from a "+N STOPS" caption: the stops it folds away are all there.
    var onTapDash: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            names
            dashCaptions
            termini
                .allowsHitTesting(false)
        }
    }

    private var names: some View {
        ForEach(scene.labels) { label in
            StopName(label: label, color: color(for: label), onTap: onTapStop)
                .opacity(label.dimmed ? 0.45 : 1)
        }
    }

    private var dashCaptions: some View {
        ForEach(scene.dashes.filter(\.showLabel)) { dash in
            AnchoredText(anchor: dash.labelCenter, alignment: Alignment(dash.labelAlignment),
                         rotationDegrees: 0, rotationAnchor: .center) {
                Text("+\(dash.swallowedCount) STOPS", comment: "Stops folded out of the map")
                    .busFont(.spaceMonoBold, size: dash.fontSize,
                             tracking: dash.fontSize * dash.trackingEm)
                    .foregroundStyle(theme.dashCaption)
                    .opacity(dash.dimmed ? 0.45 : 1)
                    .modifier(DashTap(action: onTapDash))
            }
            .accessibilityLabel("\(dash.swallowedCount) stops not shown")
        }
    }

    private var termini: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scene.termini) { terminus in
                if case .badge(let number) = terminus.style {
                    LineBadgeView(number: number, colorIndex: terminus.colorIndex,
                                  side: min(terminus.rect.width, terminus.rect.height),
                                  cornerRadius: terminus.cornerRadius,
                                  numeralSize: terminus.fontSize, ring: nil, dimmed: terminus.dimmed)
                        .frame(width: terminus.rect.width, height: terminus.rect.height)
                        .position(x: terminus.rect.midX, y: terminus.rect.midY)
                }
            }
        }
    }

    private func color(for label: StopLabel) -> Color {
        label.stopCode == passedStopCode ? theme.primaryText : theme.nameInk(label.role, preset: scene.preset)
    }
}

extension Theme {
    /// The ink of a stop's name: a terminus in its line's colour, a junction in primary text.
    func nameInk(_ role: StopLabelRole, preset: MapSizePreset) -> Color {
        switch role {
        case .terminus(let colorIndex): lineText(colorIndex)
        case .junction, .passed: primaryText
        case .stop: preset == .landscapeSingle ? secondaryText : stopName
        }
    }
}
