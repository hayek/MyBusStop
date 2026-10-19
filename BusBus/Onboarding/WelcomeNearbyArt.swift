import SwiftUI

/// Page 3: the rider on a street grid, the 500 m circle round them, and the stops inside it
/// appearing closest first, each with how far it is.
///
/// The artboard's 350 × 400 plan, times `scale`. It is geography, so it never mirrors — the stop
/// map it stands for (`SearchMapView`) does not either. The distances still read in the rider's
/// language.
///
/// It builds in street by street: the grid, then the circle drawn round from its 500 m chip, then
/// the rider, before the stops pop in. Going back from it, the stops shrink away farthest first and
/// the rest fades.
struct WelcomeNearbyArt: View {
    @Environment(\.theme) private var theme
    var frame: WelcomeTimeline.NearbyFrame
    var scale: CGFloat

    static let size = CGSize(width: 350, height: 400)
    private static let rider = CGPoint(x: 175, y: 200)
    private static let radius: CGFloat = 150

    /// A stop's dot, how far it is, and which side of the dot its chip sits on. Closest first,
    /// the order they appear in.
    private struct Stop {
        var dot: CGPoint
        var meters: Double
        var chipTrailing: Bool
    }

    private static let stops = [
        Stop(dot: CGPoint(x: 220, y: 158), meters: 200, chipTrailing: true),
        Stop(dot: CGPoint(x: 100, y: 245), meters: 290, chipTrailing: false),
        Stop(dot: CGPoint(x: 235, y: 300), meters: 390, chipTrailing: true),
        Stop(dot: CGPoint(x: 100, y: 105), meters: 400, chipTrailing: false),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { context, _ in
                context.scaleBy(x: scale, y: scale)
                drawStreets(in: &context)
                drawRider(in: &context)
            }
            chip(DistanceFormatter.text(SetupViewModel.nearRadius), fill: theme.background, text: theme.stopName,
                 minWidth: 56)
                .opacity(frame.ringLabel)
                .position(x: Self.rider.x * scale, y: (Self.rider.y - Self.radius) * scale)
            ForEach(Self.stops.indices, id: \.self) { index in
                stop(Self.stops[index], isClosest: index == 0,
                     pop: frame.pops.indices.contains(index) ? frame.pops[index] : .init(scale: 1, opacity: 1))
            }
        }
        .frame(width: Self.size.width * scale, height: Self.size.height * scale, alignment: .topLeading)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your location with a 500 m circle around it and four stops inside, the closest 200 m away."))
        .accessibilityAddTraits(.isImage)
    }

    private func drawStreets(in context: inout GraphicsContext) {
        var streets = Path()
        for y in [158.0, 300.0] {
            streets.move(to: CGPoint(x: 0, y: y))
            streets.addLine(to: CGPoint(x: Self.size.width, y: y))
        }
        for x in [100.0, 260.0] {
            streets.move(to: CGPoint(x: x, y: 0))
            streets.addLine(to: CGPoint(x: x, y: Self.size.height))
        }
        var roads = context
        roads.opacity = frame.roads
        roads.stroke(streets, with: .color(theme.welcomeRoad), style: StrokeStyle(lineWidth: 16, lineCap: .round))
        guard frame.ring > 0 else { return }
        // Round from the top, where its chip sits, clockwise.
        var ring = Path()
        ring.addArc(center: Self.rider, radius: Self.radius, startAngle: .degrees(-90), endAngle: .degrees(270),
                    clockwise: false)
        var circle = context
        circle.opacity = frame.ringOpacity
        circle.stroke(frame.ring < 1 ? ring.trimmedPath(from: 0, to: frame.ring) : ring,
                      with: .color(theme.clearButtonBorder), style: StrokeStyle(lineWidth: 2, dash: [6, 8]))
    }

    private func drawRider(in context: inout GraphicsContext) {
        for ping in frame.pings where ping.opacity > 0 {
            context.stroke(circle(ping.radius), with: .color(theme.primaryText.opacity(ping.opacity)), lineWidth: 1.5)
        }
        guard frame.rider.opacity > 0 else { return }
        var rider = context
        rider.opacity = frame.rider.opacity
        rider.fill(circle(18 * frame.rider.scale), with: .color(theme.primaryText.opacity(0.14)))
        let dot = circle(10 * frame.rider.scale)
        rider.fill(dot, with: .color(theme.primaryText))
        rider.stroke(dot, with: .color(theme.background), lineWidth: 3 * frame.rider.scale)
    }

    private func circle(_ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: Self.rider.x - radius, y: Self.rider.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A dot and its chip, popping in about their shared middle. The chip is pinned by the edge
    /// nearest its dot, so a longer distance in another language grows away from it.
    private func stop(_ stop: Stop, isClosest: Bool, pop: WelcomeTimeline.Pop) -> some View {
        // The artboard's group: a dot of radius 10 in a 5 wide ring, and a 62 wide chip 18 from its
        // centre.
        let minX = stop.chipTrailing ? stop.dot.x - 12.5 : stop.dot.x - 80
        let maxX = stop.chipTrailing ? stop.dot.x + 80 : stop.dot.x + 12.5
        let dotColor = isClosest ? theme.rail(1) : theme.primaryText
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(theme.background)
                .overlay(Circle().stroke(dotColor, lineWidth: 5 * scale))
                .frame(width: 20 * scale, height: 20 * scale)
                .position(x: (stop.dot.x - minX) * scale, y: 12 * scale)
            AnchoredText(anchor: CGPoint(x: (stop.dot.x + (stop.chipTrailing ? 18 : -18) - minX) * scale, y: 12 * scale),
                         alignment: stop.chipTrailing ? .leading : .trailing,
                         rotationDegrees: 0, rotationAnchor: .center) {
                chip(DistanceFormatter.text(stop.meters),
                     fill: isClosest ? theme.rail(1) : theme.card,
                     text: isClosest ? theme.numeral(on: 1) : theme.primaryText,
                     outline: isClosest ? nil : theme.clearButtonBorder, minWidth: 62)
            }
        }
        .frame(width: (maxX - minX) * scale, height: 24 * scale, alignment: .topLeading)
        .scaleEffect(pop.scale)
        .opacity(pop.opacity)
        .position(x: (minX + maxX) / 2 * scale, y: stop.dot.y * scale)
    }

    private func chip(_ text: String, fill: Color, text color: Color, outline: Color? = nil,
                      minWidth: CGFloat) -> some View {
        Text(text)
            .busText(TypeStyles.storyChip, scale: scale)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8 * scale)
            .frame(minWidth: minWidth * scale, minHeight: 24 * scale)
            .background(Capsule().fill(fill))
            .overlay {
                if let outline { Capsule().strokeBorder(outline, lineWidth: 1.5 * scale) }
            }
            .fixedSize()
    }
}
