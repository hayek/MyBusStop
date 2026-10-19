import SwiftUI

/// Page 1: the board's own map in miniature. Lines 41 and 18 run down to your stop, bus 41 rides
/// its rail in, and the readout beneath counts it down to NOW.
///
/// Geometry is the artboard's 350 × 320 map and the readout row under it, in design points,
/// multiplied by `scale`. It mirrors in a right-to-left language, as the board it shows does.
///
/// It builds in from its termini: the rails are drawn down from them, then the stops and names
/// appear and the readout rises in. It builds out the other way round.
struct WelcomeMapArt: View {
    @Environment(\.theme) private var theme
    var frame: WelcomeTimeline.MapFrame
    var scale: CGFloat

    static let mapSize = CGSize(width: 350, height: 320)
    /// Between the map and the readout row.
    static let readoutGap: CGFloat = 22
    static let readoutHeight: CGFloat = 64
    static let size = CGSize(width: mapSize.width, height: mapSize.height + readoutGap + readoutHeight)

    /// Line 41 is the one you are waiting for; 18 runs beside it.
    private static let waited = (number: "41", colorIndex: 1, x: CGFloat(200))
    private static let other = (number: "18", colorIndex: 0, x: CGFloat(115))
    private static let node = CGPoint(x: 200, y: 292)

    var body: some View {
        VStack(alignment: .leading, spacing: Self.readoutGap * scale) {
            map
            readout
        }
        .frame(width: Self.size.width * scale, height: Self.size.height * scale, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("A map of lines 41 and 18 running down to your stop. Bus 41 arrives as the countdown reaches now."))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Map

    private var map: some View {
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { context, _ in
                context.scaleBy(x: scale, y: scale)
                drawRails(in: &context)
                drawStops(in: &context)
            }
            // Positioned views mirror by themselves; a canvas is told to.
            .flipsForRightToLeftLayoutDirection(true)

            Group {
                terminusNumber(Self.waited.number, colorIndex: Self.waited.colorIndex, x: Self.waited.x)
                terminusNumber(Self.other.number, colorIndex: Self.other.colorIndex, x: Self.other.x)
            }
            .opacity(frame.termini)
            labels
                .opacity(frame.marks)
            puck(Self.other.number, colorIndex: Self.other.colorIndex,
                 center: CGPoint(x: Self.other.x, y: 36 + frame.puck18Y), ringed: false)
                .opacity(frame.puck18Opacity)
            puck(Self.waited.number, colorIndex: Self.waited.colorIndex,
                 center: CGPoint(x: Self.waited.x, y: 44 + frame.puck41Y), ringed: true)
                .opacity(frame.puck41Opacity)
        }
        .frame(width: Self.mapSize.width * scale, height: Self.mapSize.height * scale, alignment: .topLeading)
    }

    /// Each rail is drawn down from its terminus as far as the frame says, piece by piece: the solid
    /// run, the folded stops, and the run into your stop.
    private func drawRails(in context: inout GraphicsContext) {
        let round = StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
        let rails = [(Self.waited.x, Self.waited.colorIndex, frame.rail41), (Self.other.x, Self.other.colorIndex, frame.rail18)]
        for (x, index, drawn) in rails where drawn > 0 {
            let color = GraphicsContext.Shading.color(theme.rail(index))
            var last = Path()
            last.move(to: CGPoint(x: x, y: 150))
            if x == Self.waited.x {
                last.addLine(to: CGPoint(x: x, y: 262))
            } else {
                // Line 18 swings across to meet 41 above your stop.
                last.addLine(to: CGPoint(x: x, y: 196))
                last.addCurve(to: CGPoint(x: 200, y: 258), control1: CGPoint(x: 115, y: 232),
                              control2: CGPoint(x: 200, y: 222))
            }
            let pieces: [(path: Path, from: CGFloat, to: CGFloat, style: StrokeStyle)] = [
                (Path { $0.move(to: CGPoint(x: x, y: 26)); $0.addLine(to: CGPoint(x: x, y: 100)) }, 26, 100, round),
                // The run of stops the map folds away.
                (Path { $0.move(to: CGPoint(x: x, y: 100)); $0.addLine(to: CGPoint(x: x, y: 150)) }, 100, 150,
                 StrokeStyle(lineWidth: 12, dash: [14, 12])),
                (last, 150, 262, round),
            ]
            // How far down the rail is drawn, shared out over its pieces by height.
            let reach = 26 + (262 - 26) * drawn
            for piece in pieces where reach > piece.from {
                let share = min(1, (reach - piece.from) / (piece.to - piece.from))
                context.stroke(share < 1 ? piece.path.trimmedPath(from: 0, to: share) : piece.path,
                               with: color, style: piece.style)
            }
        }
        // The shared stub into your stop, with the stops.
        var marks = context
        marks.opacity = frame.marks
        marks.stroke(Path { $0.move(to: CGPoint(x: 200, y: 256)); $0.addLine(to: CGPoint(x: 200, y: 272)) },
                     with: .color(theme.primaryText), style: StrokeStyle(lineWidth: 14, lineCap: .round))
        var termini = context
        termini.opacity = frame.termini
        for (x, index) in [(Self.waited.x, Self.waited.colorIndex), (Self.other.x, Self.other.colorIndex)] {
            termini.fill(Path(roundedRect: CGRect(x: x - 15, y: 4, width: 30, height: 24), cornerRadius: 7),
                         with: .color(theme.rail(index)))
        }
    }

    private func drawStops(in canvas: inout GraphicsContext) {
        // The pulse carries the build in its own opacity, so it is drawn before the rest is dimmed.
        let pulse = Path(ellipseIn: CGRect(x: Self.node.x - 26, y: Self.node.y - 26, width: 52, height: 52))
        canvas.stroke(pulse, with: .color(theme.primaryText.opacity(frame.pulseOpacity)), lineWidth: 2)
        var context = canvas
        context.opacity = frame.marks
        let rings: [(CGFloat, CGFloat, Int)] = [
            (Self.waited.x, 56, Self.waited.colorIndex), (Self.waited.x, 172, Self.waited.colorIndex),
            (Self.waited.x, 216, Self.waited.colorIndex),
            (Self.other.x, 56, Self.other.colorIndex), (Self.other.x, 172, Self.other.colorIndex),
        ]
        for (x, y, index) in rings {
            let ring = Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18))
            context.fill(ring, with: .color(theme.background))
            context.stroke(ring, with: .color(theme.rail(index)), lineWidth: 5)
        }
        let node = Path(ellipseIn: CGRect(x: Self.node.x - 16, y: Self.node.y - 16, width: 32, height: 32))
        context.fill(node, with: .color(theme.background))
        context.stroke(node, with: .color(theme.primaryText), lineWidth: 8)
    }

    // MARK: Words

    private func terminusNumber(_ number: String, colorIndex: Int, x: CGFloat) -> some View {
        Text(verbatim: number)
            .busText(TypeStyles.storyTerminus, scale: scale)
            .foregroundStyle(theme.numeral(on: colorIndex))
            .position(x: x * scale, y: 16 * scale)
    }

    /// The artboard sets these on baselines; a label is placed by its middle, a cap height's half
    /// above the baseline.
    @ViewBuilder private var labels: some View {
        // Line 41's names start right of its rail; line 18's end left of its own.
        let leading: CGFloat = 223, beside: CGFloat = 95
        label(Text(verbatim: "VISTA PARK"), color: theme.lineText(Self.waited.colorIndex), x: leading, baseline: 21)
        label(Text(verbatim: "AIRPORT LOOP"), color: theme.secondaryText, x: leading, baseline: 60)
        label(Text("+\(5) STOPS"), color: theme.dashCaption, x: leading, baseline: 129)
        label(Text(verbatim: "CANAL ST"), color: theme.secondaryText, x: leading, baseline: 176)
        label(Text(verbatim: "DOCK GATE"), color: theme.secondaryText, x: leading, baseline: 220)
        label(Text(verbatim: "NORTHGATE"), color: theme.lineText(Self.other.colorIndex), x: 91, baseline: 21,
              trailing: true)
        label(Text(verbatim: "FOUNDRY RD"), color: theme.secondaryText, x: beside, baseline: 60, trailing: true)
        label(Text("+\(7) STOPS"), color: theme.dashCaption, x: beside, baseline: 129, trailing: true)
        label(Text(verbatim: "PIER FOUR"), color: theme.secondaryText, x: beside, baseline: 176, trailing: true)
        AnchoredText(anchor: CGPoint(x: 236 * scale, y: 293 * scale), alignment: .leading,
                     rotationDegrees: 0, rotationAnchor: .center) {
            Text("YOUR STOP")
                .busText(TypeStyles.storyYourStop, scale: scale)
                .foregroundStyle(theme.primaryText)
        }
    }

    private func label(_ text: Text, color: Color, x: CGFloat, baseline: CGFloat, trailing: Bool = false) -> some View {
        AnchoredText(anchor: CGPoint(x: x * scale, y: (baseline - 4) * scale),
                     alignment: trailing ? .trailing : .leading, rotationDegrees: 0, rotationAnchor: .center) {
            text
                .busText(TypeStyles.storyMapLabel, scale: scale)
                .foregroundStyle(color)
        }
    }

    /// The board's own puck. The bus you are waiting for carries the white ring, drawn here without
    /// the board's enlargement of a selected puck.
    private func puck(_ number: String, colorIndex: Int, center: CGPoint, ringed: Bool) -> some View {
        let mark = PuckMark(id: number, vehicleID: number, lineID: number, lineNumber: number,
                            colorIndex: colorIndex, center: center,
                            size: CGSize(width: 44 * scale, height: 34 * scale), cornerRadius: 10 * scale,
                            fontSize: 18 * scale, haloWidth: 5 * scale, ringWidth: 4 * scale,
                            isSelected: false, dimmed: false)
        return BusPuckMark(puck: mark)
            .overlay {
                if ringed {
                    RoundedRectangle(cornerRadius: mark.cornerRadius + mark.haloWidth + mark.ringWidth,
                                     style: .continuous)
                        .stroke(theme.primaryText, lineWidth: mark.ringWidth)
                        .padding(-(mark.haloWidth + mark.ringWidth / 2))
                }
            }
            .position(x: center.x * scale, y: center.y * scale)
    }

    // MARK: Readout

    /// The board's readout for bus 41: its badge, then the minutes, or NOW.
    private var readout: some View {
        HStack(alignment: .center, spacing: 16 * scale) {
            LineBadgeView(number: Self.waited.number, colorIndex: Self.waited.colorIndex, side: 58 * scale,
                          cornerRadius: 15 * scale, numeralSize: 30 * scale, ring: nil)
            Group {
                switch frame.readout {
                case .minutes(let minutes):
                    HStack(alignment: .lastTextBaseline, spacing: 10 * scale) {
                        Text(verbatim: "\(minutes)")
                            .busText(TypeStyles.storyNumeral, scale: scale)
                            .foregroundStyle(theme.primaryText)
                        Text("MIN")
                            .busText(TypeStyles.storyUnit, scale: scale)
                            .foregroundStyle(theme.unitColor(Self.waited.colorIndex))
                    }
                    .frame(height: TypeStyles.storyNumeral.size * (TypeStyles.storyNumeral.lineHeight ?? 1) * scale)
                case .now:
                    // The line's colour carries text in the dark; on cream it takes its darker ink.
                    Text("NOW")
                        .busText(TypeStyles.storyNow, scale: scale)
                        .foregroundStyle(theme.lineText(Self.waited.colorIndex))
                        .frame(height: TypeStyles.storyNow.size * (TypeStyles.storyNow.lineHeight ?? 1) * scale)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Self.readoutHeight * scale)
        .opacity(frame.readoutOpacity)
        .offset(y: frame.readoutOffsetY * scale)
    }
}
