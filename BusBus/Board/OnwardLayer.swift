import SwiftUI

/// The trunk past the rider's stop: its next stop, that stop's name and the dashed run, drawn
/// whole and then faded out as one from the node, so the line plainly goes on while the ride
/// ends at the node. Sits under the rails, so the node covers where it starts.
struct OnwardLayer: View {
    @Environment(\.theme) private var theme
    var scene: MapScene
    /// Opens the stop's card from its name. Nil where there is nothing to press.
    var onTapStop: ((String) -> Void)? = nil

    /// Strong at the node, still legible at the next stop, gone by the far end.
    private static let fade = Gradient(stops: [
        .init(color: .black.opacity(0.85), location: 0),
        .init(color: .black.opacity(0.5), location: 0.5),
        .init(color: .clear, location: 1),
    ])

    var body: some View {
        if let onward = scene.onward {
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, _ in
                    draw(onward, in: &context)
                }
                .flipsForRightToLeftLayoutDirection(true)
                .accessibilityHidden(true)

                StopName(label: onward.label, color: theme.nameInk(onward.label.role, preset: scene.preset),
                         onTap: onTapStop)

                if let terminus = onward.terminus, case .badge(let number) = terminus.style {
                    LineBadgeView(number: number, colorIndex: terminus.colorIndex,
                                  side: min(terminus.rect.width, terminus.rect.height),
                                  cornerRadius: terminus.cornerRadius,
                                  numeralSize: terminus.fontSize, ring: nil)
                        .frame(width: terminus.rect.width, height: terminus.rect.height)
                        .position(x: terminus.rect.midX, y: terminus.rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .mask { fade(onward) }
        }
    }

    private func draw(_ onward: OnwardMark, in context: inout GraphicsContext) {
        let color = theme.rail(onward.colorIndex)
        context.strokeRail(onward.segments, color: color, width: onward.width)
        if let mark = onward.stop {
            let circle = Path(ellipseIn: CGRect(x: mark.center.x - mark.ringRadius, y: mark.center.y - mark.ringRadius,
                                                width: mark.ringRadius * 2, height: mark.ringRadius * 2))
            context.fillWithGround(circle, theme: theme)
            context.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: mark.strokeWidth))
        }
        if let terminus = onward.terminus, case .bar = terminus.style {   // a badge is a real view
            context.fill(Path(roundedRect: terminus.rect, cornerRadius: terminus.cornerRadius, style: .continuous),
                         with: .color(color))
        }
    }

    /// One gradient over everything in the layer, along the direction of travel.
    private func fade(_ onward: OnwardMark) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Self.fade, startPoint: onward.fadeFrom, endPoint: onward.fadeTo))
        }
        .flipsForRightToLeftLayoutDirection(true)
    }
}
