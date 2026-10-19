import SwiftUI

/// The way into settings: in the board's header beside the clock, and at the top of the picker.
///
/// A bare glyph rather than a chip: the board carries no other chrome, and a filled button in the
/// corner of a wall display reads as something to press rather than something to ignore. It stays
/// visible in wall mode too — a board nobody can get out of is worse than one small icon.
struct SettingsGearButton: View {
    @Environment(\.theme) private var theme
    var size: CGFloat
    /// The picker sets its gear in the weight of the title beside it; the board's header wants the
    /// quieter bold that the clock and the live dot are drawn in.
    var weight: Font.Weight = .bold
    var color: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color ?? theme.secondaryText)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}
