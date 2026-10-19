import SwiftUI

extension View {
    /// Sweeps a band of light across the view while something is on its way. Applied to a whole
    /// group of placeholders rather than to each one, so a single sweep crosses them all together.
    ///
    /// The band follows the reading direction, and with Reduce Motion on it is not drawn at all:
    /// the placeholders alone already say "not yet".
    func shimmering(_ isActive: Bool = true, tint: Color? = nil) -> some View {
        modifier(ShimmerModifier(isActive: isActive, tint: tint))
    }
}

private struct ShimmerModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool
    var tint: Color?

    /// Seconds for one pass, pause included.
    private static let period: Double = 1.5
    /// The part of the period the band spends crossing; the rest is a rest.
    private static let sweep: Double = 0.8

    func body(content: Content) -> some View {
        content.overlay {
            if isActive && !reduceMotion {
                TimelineView(.animation) { context in
                    GeometryReader { proxy in
                        let band = max(proxy.size.width * 0.45, 80)
                        let progress = Self.progress(at: context.date)
                        LinearGradient(colors: [.clear, (tint ?? theme.primaryText).opacity(0.16), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band, height: proxy.size.height)
                            // Offsets mirror in a right-to-left layout, so this runs with the reading.
                            .offset(x: -band + (proxy.size.width + band) * progress)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
    }

    private static func progress(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return CGFloat(min(1, phase / sweep))
    }
}

/// A placeholder for something not loaded yet: the shape of the thing, in the faintest ink.
struct SkeletonBlock: View {
    @Environment(\.theme) private var theme
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.primaryText.opacity(theme.isLight ? 0.07 : 0.10))
            .frame(width: width, height: height)
    }
}

/// A row of the stop list before its stop has arrived, sized like the real one so nothing jumps
/// when it does. Search results have no distance or badges, and neither does their placeholder.
struct StopRowSkeleton: View {
    var compact: Bool
    var scale: CGFloat
    var showsDistance = true
    /// Varies the name's length from row to row, so a column of them reads as a list.
    var nameFraction: CGFloat = 0.7

    var body: some View {
        let radius = (compact ? Radius.phoneRow : Radius.row) * scale
        HStack(spacing: (compact ? 12 : 22) * scale) {
            if showsDistance {
                SkeletonBlock(width: (compact ? 40 : 56) * scale, height: (compact ? 14 : 18) * scale,
                              radius: 4 * scale)
                    .frame(width: (compact ? 52 : 76) * scale, alignment: .leading)
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: (compact ? 6 : 8) * scale) {
                    SkeletonBlock(width: proxy.size.width * nameFraction, height: (compact ? 16 : 20) * scale,
                                  radius: 4 * scale)
                    SkeletonBlock(width: proxy.size.width * nameFraction * 0.6, height: (compact ? 11 : 13) * scale,
                                  radius: 3 * scale)
                }
                .frame(maxHeight: .infinity, alignment: .leading)
            }
            if showsDistance {
                SkeletonBlock(width: (compact ? 30 : 38) * scale, height: (compact ? 30 : 38) * scale,
                              radius: (compact ? 8 : 10) * scale)
            }
        }
        .padding(.horizontal, (compact ? 16 : 24) * scale)
        .frame(height: (showsDistance ? (compact ? Spacing.nearbyRowHeightPhone : Spacing.nearbyRowHeight)
                                      : (compact ? 56 : Spacing.nearbyRowHeight)) * scale)
        .frame(maxWidth: .infinity)
        .background(RowBackground(radius: radius, scale: scale))
    }
}

/// Stand-ins for a list of stops, faded row by row so the list trails off rather than ending.
struct StopListSkeleton: View {
    var count: Int
    var compact: Bool
    var scale: CGFloat
    var showsDistance = true
    var spacing: CGFloat
    /// Still, when the rows stand for stops that are not on their way yet.
    var shimmers = true

    private static let nameFractions: [CGFloat] = [0.72, 0.55, 0.8, 0.62, 0.68, 0.5]

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                StopRowSkeleton(compact: compact, scale: scale, showsDistance: showsDistance,
                                nameFraction: Self.nameFractions[index % Self.nameFractions.count])
                    .opacity(1 - Double(index) / Double(max(count, 1)) * 0.6)
            }
        }
        .shimmering(shimmers)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading stops"))
        .accessibilityHidden(!shimmers)
    }
}

/// A chip of the line grid before the stop's lines have arrived.
struct LineChipSkeleton: View {
    var compact: Bool
    var scale: CGFloat
    var destinationFraction: CGFloat = 0.8

    var body: some View {
        let radius = (compact ? Radius.chip : Radius.row) * scale
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(width: (compact ? 36 : 56) * scale, height: (compact ? 24 : 38) * scale,
                          radius: 6 * scale)
            Spacer(minLength: 0)
            GeometryReader { proxy in
                SkeletonBlock(width: proxy.size.width * destinationFraction, height: (compact ? 11 : 14) * scale,
                              radius: 3 * scale)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: (compact ? 11 : 14) * scale)
        }
        .padding((compact ? 12 : 18) * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: (compact ? Spacing.chipHeightPhone : Spacing.chipHeight) * scale)
        .background(RowBackground(radius: radius, scale: scale))
    }
}

/// The readout's leading block before the first answer: badge, kicker, the big number and the
/// line under it, in the places they will land.
struct ReadoutSkeleton: View {
    var badgeSide: CGFloat
    var badgeRadius: CGFloat
    /// The kicker sits above the badge in portrait and beside it in landscape.
    var kickerAbove: Bool
    var scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            if kickerAbove { kicker }
            HStack(alignment: .center, spacing: badgeSide * 0.3) {
                SkeletonBlock(width: badgeSide, height: badgeSide, radius: badgeRadius)
                VStack(alignment: .leading, spacing: 10 * scale) {
                    if !kickerAbove { kicker }
                    SkeletonBlock(width: badgeSide * 1.9, height: badgeSide * 0.62, radius: 8 * scale)
                    if !kickerAbove { subline }
                }
            }
            if kickerAbove { subline }
        }
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading arrivals"))
    }

    private var kicker: some View {
        SkeletonBlock(width: 120 * scale, height: 12 * scale, radius: 3 * scale)
    }

    private var subline: some View {
        SkeletonBlock(width: 200 * scale, height: 14 * scale, radius: 3 * scale)
    }
}
