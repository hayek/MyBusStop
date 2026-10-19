import SwiftUI

/// One saved stop: its lines, and the next two buses on each when the board has seen them lately.
struct TVStopCard: View {
    @Environment(\.theme) private var theme
    var glance: StopGlance
    var isAvailable: Bool
    var colorIndex: (String) -> Int
    /// Set on the Top Shelf's still picture of the card, which cannot count down: the time it was
    /// drawn, so its numbers are read as of then.
    var drawnAt: Date? = nil

    /// 16:9, the Top Shelf's own card shape.
    static let size = CGSize(width: 560, height: 315)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if glance.setup.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.stopName)
                        .accessibilityHidden(true)
                }
                Text(glance.setup.stop.name)
                    .busText(TypeStyles.titleLandscape)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if let city = glance.setup.stop.city, !city.isEmpty {
                Text(city)
                    .busText(TypeStyles.kicker)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if isAvailable {
                ForEach(glance.lines, id: \.line.id) { line in
                    HStack(spacing: 16) {
                        LineBadgeView(number: line.line.shortName, colorIndex: colorIndex(line.line.id),
                                      side: 48, cornerRadius: 12, numeralSize: 24, ring: nil)
                        Text(verbatim: TVStopCard.times(line.next))
                            .busText(TypeStyles.subArrives, scale: 1.3)
                            .foregroundStyle(line.next.isEmpty ? theme.secondaryText : theme.primaryText)
                    }
                }
            } else {
                Text("Not available here")
                    .busText(TypeStyles.kicker)
                    .foregroundStyle(theme.stale)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let drawnAt {
                Text("AT \(drawnAt.formatted(date: .omitted, time: .shortened))")
                    .busText(TypeStyles.kicker)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(32)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(theme.card)
        .accessibilityElement(children: .combine)
    }

    /// "4 · 12 MIN", or a dash when the board has not seen this line lately.
    static func times(_ next: [Countdown]) -> String {
        guard !next.isEmpty else { return "—" }
        func unit(_ countdown: Countdown) -> String { countdown.isHours ? String(appLocalized: "HR") : String(appLocalized: "MIN") }
        // One unit after the last figure when they share it; "12 MIN · 1:05 HR" when they do not.
        let sharesUnit = Set(next.map(\.isHours)).count == 1
        let figures = next.enumerated().map { index, countdown in
            if countdown.minutes == 0 { return String(appLocalized: "NOW") }
            let isLast = index == next.count - 1
            return sharesUnit && !isLast ? countdown.figure : "\(countdown.figure) \(unit(countdown))"
        }
        return figures.joined(separator: " · ")
    }
}

/// A stop filling the screen, for the Top Shelf's carousel when the app has no recent picture of
/// its board (`TopShelfBoards`): the lines and their next buses, large, on the board's own
/// background. The carousel lays the stop's name and a summary over the lower left, so the
/// numbers keep to the right.
struct TVGlanceSlide: View {
    @Environment(\.theme) private var theme
    var glance: StopGlance
    var colorIndex: (String) -> Int
    var drawnAt: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.background
            VStack(alignment: .leading, spacing: 40) {
                ForEach(glance.lines, id: \.line.id) { line in
                    HStack(spacing: 36) {
                        LineBadgeView(number: line.line.shortName, colorIndex: colorIndex(line.line.id),
                                      side: 120, cornerRadius: 28, numeralSize: 58, ring: nil)
                        Text(verbatim: TVStopCard.times(line.next))
                            .busText(TypeStyles.minutesSecondary, scale: 1.4)
                            .foregroundStyle(line.next.isEmpty ? theme.secondaryText : theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
            }
            .frame(width: 900, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 140)
            .padding(.bottom, 200)
            Text("AT \(drawnAt.formatted(date: .omitted, time: .shortened))")
                .busText(TypeStyles.kicker, scale: 1.6)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 90)
                .padding(.trailing, 140)
        }
        .frame(width: TopShelfBoards.size.width, height: TopShelfBoards.size.height)
    }
}
