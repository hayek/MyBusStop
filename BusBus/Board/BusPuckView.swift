import SwiftUI

/// A live bus on its rail. A real button: tapping it is how you inspect a bus, and VoiceOver reads
/// the same three facts the sighted rider gets.
struct BusPuckView: View {
    @Environment(\.theme) private var theme

    var puck: PuckMark
    var minutes: Int?
    var stopsAway: Int?
    /// How old the fix behind this puck is, where the feed timestamps it.
    var positionAge: TimeInterval?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            BusPuckMark(puck: puck)
                // The mark is 44×36, but the target is never smaller than 44 in either direction.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(puck.dimmed || isStale ? 0.55 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(puck.isSelected ? [.isSelected] : [])
    }

    /// A position older than the board's own idea of current is drawn back and says so, so it is
    /// never mistaken for where the bus is now.
    private var isStale: Bool { (positionAge ?? 0) > BoardBus.positionStaleAfter }

    private var accessibilityLabel: String {
        var parts = [String(appLocalized: "Bus \(puck.lineNumber)")]
        if let minutes {
            parts.append(minutes == 0 ? String(appLocalized: "arriving now")
                         : String(appLocalized: "\(minutes) minutes away"))
        }
        if let stopsAway { parts.append(String(appLocalized: "\(stopsAway) stops")) }
        if isStale, let positionAge {
            let minutesOld = max(1, Int((positionAge / 60).rounded()))
            parts.append(String(appLocalized: "position \(minutesOld) minutes old"))
        }
        if puck.isSelected { parts.append(String(appLocalized: "selected")) }
        return parts.formatted(.list(type: .and, width: .narrow).locale(AppLanguage.locale))
    }
}

/// What a puck looks like: a badge carrying the line number, punched through the rail it sits on,
/// ringed when it is the bus the readout is about. The board's button wears it, and so does the
/// widget's map, which has nothing to tap.
struct BusPuckMark: View {
    @Environment(\.theme) private var theme
    var puck: PuckMark
    /// Drawn back, for a position no longer current. The halo stays whole, so the rail still stops
    /// at the puck's edge rather than showing through it.
    var faded = false

    var body: some View {
        Text(puck.lineNumber)
            .busText(TypeStyles.badgeNumeral(puck.fontSize))
            .foregroundStyle(theme.numeral(on: puck.colorIndex))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, puck.size.width * 0.12)
            .frame(width: puck.size.width, height: puck.size.height)
            .background { LineMarkFill(cornerRadius: puck.cornerRadius, colorIndex: puck.colorIndex) }
            .opacity(faded ? 0.55 : 1)
            // The halo punches the puck through the rail it sits on.
            .background {
                let halo = RoundedRectangle(cornerRadius: puck.cornerRadius + puck.haloWidth, style: .continuous)
                    .padding(-puck.haloWidth)
                if theme.isMonochrome {
                    halo.foregroundStyle(.black).blendMode(.destinationOut)
                } else {
                    halo.foregroundStyle(theme.background)
                }
            }
            .overlay {
                if puck.isSelected {
                    RoundedRectangle(cornerRadius: puck.cornerRadius + puck.haloWidth + puck.ringWidth, style: .continuous)
                        .stroke(theme.primaryText, lineWidth: puck.ringWidth)
                        .padding(-(puck.haloWidth + puck.ringWidth / 2))
                }
            }
            .scaleEffect(puck.isSelected ? 1.14 : 1)
    }
}
