import SwiftUI

/// Page 2: an old phone dropping onto a hook by the front door, the charger's cable reaching it,
/// and the board lighting up on its screen.
///
/// Drawn in the artboard's 390 × 470 scene, shown at 348 × 420 design points times `scale`. The
/// room is a picture of a hallway at night, so it is dark in both themes; the board on the phone
/// mirrors in a right-to-left language, so the whole picture does.
///
/// It builds in with the room coming up out of the dark before the phone drops onto its hook, and
/// builds out with the phone's screen going dark and the room lifting away.
struct WelcomeWallArt: View {
    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    var frame: WelcomeTimeline.WallFrame
    var scale: CGFloat

    static let size = CGSize(width: 348, height: 420)
    private static let scene = CGSize(width: 390, height: 470)

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            context.scaleBy(x: Self.size.width / Self.scene.width * scale,
                            y: Self.size.height / Self.scene.height * scale)
            drawRoom(in: &context)
            drawCable(in: &context)
            drawGlow(in: &context)
            drawPhone(in: &context)
        }
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
        .clipShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
        .flipsForRightToLeftLayoutDirection(true)
        .opacity(frame.sceneOpacity)
        .offset(y: frame.sceneY * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("An old phone hung on the wall by the door, plugged in, showing the bus map."))
        .accessibilityAddTraits(.isImage)
    }

    private func drawRoom(in canvas: inout GraphicsContext) {
        var room = canvas
        room.opacity = frame.room
        room.fill(Path(CGRect(origin: .zero, size: Self.scene)), with: .color(theme.welcomeRoom))
        room.fill(Path(CGRect(x: 0, y: 430, width: 390, height: 40)), with: .color(theme.welcomeFloor))
        room.stroke(Path { $0.move(to: CGPoint(x: 0, y: 430)); $0.addLine(to: CGPoint(x: 390, y: 430)) },
                    with: .color(theme.welcomeWallLine), lineWidth: 2)

        // What hangs on the wall settles onto it a moment after the room comes up.
        var context = canvas
        context.opacity = frame.fixtures
        context.translateBy(x: 0, y: frame.fixturesY)

        // The front door, in its frame, with two panels and a handle.
        context.stroke(Path(CGRect(x: 20, y: 62, width: 154, height: 368)),
                       with: .color(theme.welcomeWallLine), lineWidth: 3)
        let door = Path(roundedRect: CGRect(x: 28, y: 70, width: 138, height: 360), cornerRadius: 4)
        context.fill(door, with: .color(theme.welcomeDoor))
        context.stroke(door, with: .color(theme.welcomeFixture), lineWidth: 4)
        for panel in [CGRect(x: 46, y: 92, width: 102, height: 140), CGRect(x: 46, y: 250, width: 102, height: 160)] {
            context.stroke(Path(roundedRect: panel, cornerRadius: 3), with: .color(theme.welcomeWallLine), lineWidth: 3)
        }
        context.fill(Path(ellipseIn: CGRect(x: 142, y: 256, width: 12, height: 12)), with: .color(theme.welcomeHardware))

        // The light switch, and the socket the phone is plugged into.
        context.stroke(Path(roundedRect: CGRect(x: 190, y: 238, width: 16, height: 26), cornerRadius: 3),
                       with: .color(theme.welcomeFixture), lineWidth: 3)
        context.stroke(Path(roundedRect: CGRect(x: 282, y: 380, width: 30, height: 38), cornerRadius: 5),
                       with: .color(theme.welcomeFixture), lineWidth: 3)
        var pins = Path()
        for x in [292.0, 302.0] {
            pins.move(to: CGPoint(x: x, y: 392))
            pins.addLine(to: CGPoint(x: x, y: 402))
        }
        context.stroke(pins, with: .color(theme.welcomeFixture), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    private func drawCable(in context: inout GraphicsContext) {
        guard frame.cable > 0 else { return }
        var cable = Path()
        cable.move(to: CGPoint(x: 297, y: 252))
        cable.addCurve(to: CGPoint(x: 297, y: 382), control1: CGPoint(x: 297, y: 300), control2: CGPoint(x: 288, y: 334))
        context.stroke(cable.trimmedPath(from: 0, to: frame.cable), with: .color(theme.welcomeCable),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// The board's light on the wall around the phone.
    private func drawGlow(in context: inout GraphicsContext) {
        guard frame.glow > 0 else { return }
        let amber = LinePalette.rail(1, isLight: false)
        var glow = context
        glow.opacity = frame.glow
        // A unit circle stretched to the ellipse, so the gradient is elliptical with it.
        glow.translateBy(x: 297, y: 206)
        glow.scaleBy(x: 120, y: 76)
        glow.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                  with: .radialGradient(Gradient(colors: [amber.opacity(0.22), amber.opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: 1))
    }

    private func drawPhone(in context: inout GraphicsContext) {
        var phone = context
        phone.opacity = frame.phoneOpacity
        phone.translateBy(x: 0, y: frame.phoneY)

        let body = Path(roundedRect: CGRect(x: 222, y: 162, width: 150, height: 88), cornerRadius: 14)
        phone.fill(body, with: .color(theme.welcomePhoneBody))
        phone.stroke(body, with: .color(theme.welcomePhoneEdge), lineWidth: 3)
        phone.fill(Path(roundedRect: CGRect(x: 236, y: 172, width: 112, height: 68), cornerRadius: 3),
                   with: .color(theme.welcomePhoneScreen))
        phone.stroke(Path(ellipseIn: CGRect(x: 354, y: 200, width: 12, height: 12)),
                     with: .color(theme.welcomeHardware), lineWidth: 2)

        // The board waking: the story's two lines, 41 and 18 as on the first page, into one stop.
        // The line being caught runs straight in; the other bends to meet it.
        var screen = phone
        screen.opacity = frame.phoneOpacity * frame.screen
        let rail = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        var joining = Path()
        joining.move(to: CGPoint(x: 264, y: 192))
        joining.addLine(to: CGPoint(x: 298, y: 192))
        joining.addCurve(to: CGPoint(x: 326, y: 216), control1: CGPoint(x: 312, y: 192), control2: CGPoint(x: 312, y: 216))
        screen.stroke(joining, with: .color(LinePalette.rail(0, isLight: false)), style: rail)
        screen.stroke(Path { $0.move(to: CGPoint(x: 264, y: 216)); $0.addLine(to: CGPoint(x: 326, y: 216)) },
                      with: .color(LinePalette.rail(1, isLight: false)), style: rail)
        drawBadge("18", colorIndex: 0, centre: CGPoint(x: 250, y: 192), in: &screen)
        drawBadge("41", colorIndex: 1, centre: CGPoint(x: 250, y: 216), in: &screen)
        let node = Path(ellipseIn: CGRect(x: 329, y: 211, width: 10, height: 10))
        screen.fill(node, with: .color(theme.welcomePhoneScreen))
        screen.stroke(node, with: .color(theme.welcomePhoneEdge), lineWidth: 2.5)

        // A bus on 41, on its way in.
        var puck = phone
        puck.opacity = frame.phoneOpacity * frame.puckOpacity
        let mark = Path(roundedRect: CGRect(x: 264 + frame.puckX, y: 212, width: 10, height: 8), cornerRadius: 2)
        puck.fill(mark, with: .color(LinePalette.rail(1, isLight: false)))
        puck.stroke(mark, with: .color(theme.welcomePhoneScreen), lineWidth: 1.5)
    }

    /// A line's number at the start of its rail, as the board's termini carry them. The picture is
    /// mirrored in a right-to-left language, so the number is flipped back to read the right way.
    private func drawBadge(_ number: String, colorIndex: Int, centre: CGPoint, in context: inout GraphicsContext) {
        let badge = Path(roundedRect: CGRect(x: centre.x - 10, y: centre.y - 7, width: 20, height: 14), cornerRadius: 3.5)
        context.fill(badge, with: .color(LinePalette.rail(colorIndex, isLight: false)))
        var label = context
        label.translateBy(x: centre.x, y: centre.y)
        if layoutDirection == .rightToLeft { label.scaleBy(x: -1, y: 1) }
        label.draw(Text(verbatim: number)
                       .font(.custom(BusFace.archivoBlack.rawValue, fixedSize: 10))
                       .foregroundStyle(LinePalette.numeral(on: colorIndex, isLight: false)),
                   at: .zero)
    }
}
