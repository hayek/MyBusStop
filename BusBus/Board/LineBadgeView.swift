import SwiftUI

/// The square that carries a line number. The white ring is the only thing tying the map to the
/// numbers below it, so it is a first-class option rather than a decoration.
struct LineBadgeView: View {
    struct Ring: Equatable {
        var halo: Color
        var haloWidth: CGFloat
        var ringWidth: CGFloat
    }

    @Environment(\.theme) private var theme

    var number: String
    var colorIndex: Int
    var side: CGFloat
    var cornerRadius: CGFloat
    var numeralSize: CGFloat
    var ring: Ring?
    var dimmed: Bool = false

    var body: some View {
        Text(number)
            .busText(TypeStyles.badgeNumeral(numeralSize))
            .foregroundStyle(theme.numeral(on: colorIndex))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // A three-digit line would otherwise run to the corners it sits in; the padding gives
            // it somewhere to shrink into instead.
            .padding(.horizontal, side * 0.14)
            .frame(width: side, height: side)
            .background { LineMarkFill(cornerRadius: cornerRadius, colorIndex: colorIndex) }
            .overlay {
                if let ring {
                    RoundedRectangle(cornerRadius: cornerRadius + ring.haloWidth, style: .continuous)
                        .stroke(ring.halo, lineWidth: ring.haloWidth)
                        .padding(-ring.haloWidth / 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius + ring.haloWidth + ring.ringWidth, style: .continuous)
                                .stroke(theme.primaryText, lineWidth: ring.ringWidth)
                                .padding(-(ring.haloWidth + ring.ringWidth / 2))
                        }
                }
            }
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}

/// The ground of a badge or puck: the line's colour, or in one ink (`Theme.isMonochrome`) an
/// outline round a hole, since a filled mark would leave its number nothing to be read against.
struct LineMarkFill: View {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat
    var colorIndex: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if theme.isMonochrome {
            ZStack {
                shape.fill(.black).blendMode(.destinationOut)
                shape.strokeBorder(theme.primaryText, lineWidth: Stroke.cardOutline)
            }
        } else {
            shape.fill(theme.rail(colorIndex))
        }
    }
}
