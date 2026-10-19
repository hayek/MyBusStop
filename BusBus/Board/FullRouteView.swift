import SwiftUI

#if !os(tvOS)
/// Every stop of every watched line, terminus to terminus, in one long strip that scrolls along
/// the route — what the board's map folds into "+N STOPS". A strip at the foot shows the whole of
/// it at once, with a window on the part in view; dragging the window moves the view.
struct FullRouteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var model: BoardViewModel

    @State private var position = ScrollPosition()
    @State private var window = ScrollWindow()
    /// The orientation the view last centred the rider's stop for.
    @State private var centredFor: MapAxis?
    @State private var inspectedStop: StopCardRequest?
    /// Its own rather than the board's: the board is under this cover, and cannot present over it.
    @State private var inspectedLine: LineCardRequest?
    /// What prev, my stop and next last moved the view to. It opens on the rider's stop.
    @State private var focus: FullRouteNavigation.Focus = .userStop
    /// The route on a real map instead of the strip; offered only when a watched line has a road shape.
    @State private var showsMap = false

    private var canShowMap: Bool { model.lines.contains { model.canInspectLine($0) } }

    /// A phone on its side has height for two lanes only if the header and the strip give some.
    private var isShort: Bool { verticalSizeClass == .compact }
    private var headerHeight: CGFloat { isShort ? 48 : 60 }
    private var minimapHeight: CGFloat { isShort ? 56 : 72 }

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        GeometryReader { proxy in
            let axis: MapAxis = proxy.size.width > proxy.size.height ? .horizontal : .vertical
            let viewport = CGSize(width: proxy.size.width,
                                  height: max(0, proxy.size.height - headerHeight - minimapHeight))
            let inputs = model.fullRouteInputs()
            let scene = focused(FullRouteLayout.layout(FullRouteRequest(lines: inputs.lines, vehicles: inputs.vehicles,
                                                                        axis: axis, viewport: viewport)))
            VStack(spacing: 0) {
                header
                    .frame(height: headerHeight)
                if showsMap && canShowMap {
                    // The map takes the strip's place too: its window has nothing to show on a map.
                    FullRouteMapView(model: model) { code in inspectedStop = model.stopCard(code: code) }
                        // Room under the map's own marks for the toggle, which must not hide them.
                        .safeAreaPadding(.bottom, Self.toggleClearance)
                        .frame(width: viewport.width, height: viewport.height + minimapHeight)
                        .overlay(alignment: .bottomLeading) {
                            viewToggle(theme)
                                .padding(.leading, Spacing.sideInsetPhone)
                                .padding(.bottom, (minimapHeight - Self.toggleHeight) / 2)
                        }
                } else {
                    Group {
                        if scene.isEmpty {
                            Text("LOADING ROUTE")
                                .busText(TypeStyles.kicker)
                                .foregroundStyle(theme.dashCaption)
                        } else {
                            scroller(scene: scene, viewport: viewport)
                        }
                    }
                    .frame(width: viewport.width, height: viewport.height)
                    HStack(spacing: 0) {
                        // In the band, where it covers none of the strip; on the map it keeps this corner.
                        if canShowMap {
                            viewToggle(theme)
                                .padding(.leading, Spacing.sideInsetPhone)
                        }
                        FullRouteMinimapView(scene: scene, window: window) { stripPoint, minimap in
                            focus = .free
                            position.scrollTo(point: minimap.offset(centeredOn: stripPoint, visible: viewport))
                        }
                        FullRouteNavigator(scene: scene, window: window, focus: focus) { target in
                            move(to: target, in: scene, viewport: viewport)
                        }
                        .padding(.trailing, Spacing.sideInsetPhone)
                    }
                    .frame(height: minimapHeight)
                    .background(theme.readoutBand.ignoresSafeArea(edges: .bottom))
                }
            }
            .onChange(of: axis, initial: true) { _, _ in centre(scene, in: viewport) }
            .onChange(of: scene.isEmpty) { _, _ in centre(scene, in: viewport) }
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        // The board under the cover is off screen and may not hear the app come and go; this
        // view keeps its buses live, and stops asking for them in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.start()
                Task { await model.refresh(.foreground) }
            } else if phase == .background {
                model.stopPolling()
            }
        }
        .sheet(item: $inspectedStop) { request in
            StopCardView(request: request, settings: model.settings)
                .busTheme()
        }
        .sheet(item: $inspectedLine) { request in
            LineCardView(request: request, settings: model.settings)
                .busTheme()
        }
        .analyticsScreen("full_route")
    }

    /// How much of the foot of the map the toggle takes, kept clear of the map's own marks.
    private static let toggleClearance: CGFloat = 66
    private static let toggleHeight: CGFloat = 42

    /// The strip or the map, at the foot of the view on the left: two halves of one control.
    private func viewToggle(_ theme: Theme) -> some View {
        HStack(spacing: 0) {
            toggleHalf(systemImage: "point.topleft.down.to.point.bottomright.curvepath", label: "Full lines view",
                       isOn: !showsMap, theme: theme) { showsMap = false }
                .accessibilityIdentifier("fullRoute.strip")
            toggleHalf(systemImage: "map", label: "Map", isOn: showsMap, theme: theme) { showsMap = true }
                .accessibilityIdentifier("fullRoute.map")
        }
        .padding(3)
        .frame(height: Self.toggleHeight)
        .background(Capsule().fill(theme.background.opacity(0.94)))
        .overlay(Capsule().strokeBorder(theme.cardOutline, lineWidth: 1))
    }

    private func toggleHalf(systemImage: String, label: LocalizedStringKey, isOn: Bool, theme: Theme,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? theme.primaryText : theme.secondaryText)
                .frame(width: 44, height: 36)
                .background(Capsule().fill(isOn ? theme.closeButton : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The bus prev or next went to carries the ring here, so the eye finds it once the view has
    /// moved; until then the ring stays where the board puts it.
    private func focused(_ scene: FullRouteScene) -> FullRouteScene {
        guard case .bus(let id) = focus, scene.pucks.contains(where: { $0.vehicleID == id }) else { return scene }
        var scene = scene
        scene.pucks = scene.pucks.map { puck in
            var puck = puck
            puck.isSelected = puck.vehicleID == id
            return puck
        }
        return scene
    }

    /// Centres the view on the rider's stop or on a bus, and says which for VoiceOver.
    private func move(to target: FullRouteNavigator.Target, in scene: FullRouteScene, viewport: CGSize) {
        let point: CGPoint
        switch target {
        case .userStop:
            focus = .userStop
            point = scene.offset(centeringUserStopIn: viewport)
        case .bus(let puck):
            focus = .bus(puck.vehicleID)
            point = FullRouteMinimap.clamp(CGPoint(x: puck.center.x - viewport.width / 2,
                                                   y: puck.center.y - viewport.height / 2),
                                           visible: viewport, content: scene.contentSize)
            AccessibilityNotification.Announcement(String(appLocalized: "Bus \(puck.lineNumber)")).post()
        }
        withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(point: point) }
    }

    /// The rider's stop in the middle, once per orientation: after that the rider has the view.
    private func centre(_ scene: FullRouteScene, in viewport: CGSize) {
        guard !scene.isEmpty, centredFor != scene.axis else { return }
        centredFor = scene.axis
        position.scrollTo(point: scene.offset(centeringUserStopIn: viewport))
    }

    private var header: some View {
        FullRouteHeader(stopName: model.stop?.name ?? "", lines: model.lines,
                        colorIndex: { model.colorIndex($0.id) },
                        hasCard: { model.canInspectLine($0) },
                        onAboutLine: { line in
                            inspectedLine = LineCardRequest(line: line,
                                                            providerID: model.configuration?.providerID
                                                                ?? model.settings.providerID,
                                                            stopCode: model.stop?.code)
                        },
                        onClose: { dismiss() })
    }

    private func scroller(scene: FullRouteScene, viewport: CGSize) -> some View {
        ScrollView([.horizontal, .vertical]) {
            FullRouteContent(scene: scene, model: model) { code in
                inspectedStop = model.stopCard(code: code)
            }
            .frame(width: scene.contentSize.width, height: scene.contentSize.height, alignment: .topLeading)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            window.visible = rect
        }
        // The rider's own scroll lets go of the bus or stop the buttons went to; the next step
        // goes from wherever they have scrolled.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { focus = .free }
        }
    }
}

/// The part of the content in view, as the scroller last reported it. Kept in an object only the
/// strip reads, so a frame of scrolling redraws the strip's window and not the whole route.
@Observable private final class ScrollWindow {
    var visible: CGRect = .zero
}

private struct FullRouteHeader: View {
    @Environment(\.theme) private var theme
    var stopName: String
    var lines: [TransitLine]
    var colorIndex: (TransitLine) -> Int
    /// Whether a line's badge opens its card: only where its route can be drawn.
    var hasCard: (TransitLine) -> Bool
    var onAboutLine: (TransitLine) -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FULL ROUTE")
                    .busText(TypeStyles.headerCaption)
                    .foregroundStyle(theme.headerCaption)
                Text(stopName)
                    .busText(TypeStyles.titlePhone)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            // Each badge opens its line's card; the targets touch, so the badges sit 14 points apart.
            HStack(spacing: 0) {
                ForEach(lines) { line in
                    let badge = LineBadgeView(number: line.shortName, colorIndex: colorIndex(line),
                                              side: 30, cornerRadius: 8, numeralSize: 15, ring: nil)
                        .frame(width: 44, height: 44)
                    if hasCard(line) {
                        Button { onAboutLine(line) } label: { badge.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About line \(line.shortName)")
                    } else {
                        badge.accessibilityLabel("Line \(line.shortName)")
                    }
                }
            }
            Button(action: onClose) {
                CloseGlyph(scale: 1)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.closeButton))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close full route")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.sideInsetPhone)
    }
}

/// The long strip itself: rails and marks drawn, names and buses as real views on top.
private struct FullRouteContent: View {
    @Environment(\.theme) private var theme
    var scene: FullRouteScene
    var model: BoardViewModel
    var onTapStop: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            FullRouteCanvas(scene: scene)
            ForEach(scene.lines) { line in
                LineBadgeView(number: line.number, colorIndex: line.colorIndex, side: scene.badgeSide,
                              cornerRadius: Radius.badge(scene.badgeSide), numeralSize: 17, ring: nil)
                    .frame(width: scene.badgeSide, height: scene.badgeSide)
                    .position(line.badgeCenter)
                    .accessibilityLabel("Line \(line.number)")
            }
            ForEach(scene.stops) { stop in
                stopLabel(stop)
            }
            ForEach(scene.stops) { stop in
                // The mark is small; the finger gets the standard target around it, or the whole
                // capsule where lines run together.
                let span = markSpan(stop)
                Color.clear
                    .frame(width: max(44, span.width), height: max(44, span.height))
                    .contentShape(Rectangle())
                    .position(stop.center)
                    .onTapGesture { onTapStop(stop.code) }
                    .accessibilityHidden(true)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack(alignment: .topLeading) {
                    ForEach(scene.pucks) { puck in
                        BusPuckMark(puck: puck)
                            .position(puck.center)
                            .animation(.easeInOut(duration: 0.6), value: puck.center)
                            .accessibilityElement()
                            .accessibilityLabel(puckLabel(puck, now: context.now))
                    }
                }
                .frame(width: scene.contentSize.width, height: scene.contentSize.height, alignment: .topLeading)
            }
            .allowsHitTesting(false)
        }
    }

    private func markSpan(_ stop: FullRouteStop) -> CGSize {
        let xs = stop.memberCenters.map(\.x), ys = stop.memberCenters.map(\.y)
        return CGSize(width: (xs.max() ?? 0) - (xs.min() ?? 0) + 2 * scene.ringRadius,
                      height: (ys.max() ?? 0) - (ys.min() ?? 0) + 2 * scene.ringRadius)
    }

    private func stopLabel(_ stop: FullRouteStop) -> some View {
        AnchoredText(anchor: stop.labelAnchor,
                     alignment: scene.labelRotation == 0 ? .leading : .bottomLeading,
                     rotationDegrees: scene.labelRotation,
                     rotationAnchor: scene.labelRotation == 0 ? .center : .bottomLeading) {
            let tracked = LocaleAwareBusFont.isTracked(stop.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(stop.name.uppercased())
                    .font(.bus(tracked ? .spaceMonoBold : BusFace.spaceMonoBold.proportional, size: scene.labelFontSize))
                    .tracking(tracked ? scene.labelFontSize * 0.04 : 0)
                    .lineLimit(2)
                // The rider's own stop says so on a line of its own, so the name keeps its room.
                if stop.role == .userStop {
                    Text("YOUR STOP")
                        .busFont(.spaceMonoBold, size: scene.labelFontSize - 1, tracking: scene.labelFontSize * 0.06)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(color(for: stop))
            .multilineTextAlignment(.leading)
            .frame(width: stop.labelMaxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(stop.isPastUserStop ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onTapStop(stop.code) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Shows the stop’s lines, address and map"))
        }
    }

    private func color(for stop: FullRouteStop) -> Color {
        switch stop.role {
        case .userStop: theme.primaryText
        case .lastStop: theme.lineText(stop.colorIndex)
        case .stop: theme.stopName
        }
    }

    private func puckLabel(_ puck: PuckMark, now: Date) -> String {
        let arrival = model.snapshot.arrivals.first { $0.bus?.id == puck.vehicleID }
        var parts = [String(appLocalized: "Bus \(puck.lineNumber)")]
        if let minutes = arrival?.minutes(at: now) {
            parts.append(minutes == 0 ? String(appLocalized: "arriving now")
                         : String(appLocalized: "\(minutes) minutes away"))
        }
        return parts.formatted(.list(type: .and, width: .narrow).locale(AppLanguage.locale))
    }
}

/// Rails, rings, the rider's stop and the last stop. The part of each rail past the rider's stop is
/// drawn back: a bus there has already been by.
private struct FullRouteCanvas: View {
    @Environment(\.theme) private var theme
    var scene: FullRouteScene

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            for line in scene.lines {
                let color = theme.rail(line.colorIndex)
                for segment in line.segments {
                    var path = Path()
                    path.move(to: segment.from)
                    if segment.bends {
                        path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
                    } else {
                        path.addLine(to: segment.to)
                    }
                    context.stroke(path, with: .color(segment.faded ? color.opacity(0.35) : color),
                                   style: StrokeStyle(lineWidth: scene.railWidth, lineCap: .round, lineJoin: .round))
                }
            }
            for stop in scene.stops {
                let color = theme.rail(stop.colorIndex).opacity(stop.isPastUserStop ? 0.35 : 1)
                switch stop.role {
                case .userStop:
                    mark(stop, radius: scene.nodeRadius, width: scene.ringStroke + 1, color: theme.primaryText,
                         in: &context)
                case .lastStop where !stop.isShared:
                    let side = scene.ringRadius * 2 + scene.ringStroke
                    let rect = CGRect(x: stop.center.x - side / 2, y: stop.center.y - side / 2, width: side, height: side)
                    context.fill(Path(roundedRect: rect, cornerRadius: Radius.terminusBar, style: .continuous),
                                 with: .color(color))
                default:
                    // One capsule across lines calling together, in the ink rather than any one
                    // line's colour: the wait there is shared, as on the board.
                    mark(stop, radius: scene.ringRadius, width: scene.ringStroke,
                         color: stop.isShared ? theme.primaryText.opacity(stop.isPastUserStop ? 0.35 : 1) : color,
                         in: &context)
                }
            }
        }
        .frame(width: scene.contentSize.width, height: scene.contentSize.height)
        // The names and buses above are positioned views, which SwiftUI mirrors for a right-to-left
        // language; the canvas has to be told to follow them.
        .flipsForRightToLeftLayoutDirection(true)
        .accessibilityHidden(true)
    }

    /// A ring on one line, or a capsule spanning every line calling at the stop together.
    private func mark(_ stop: FullRouteStop, radius: CGFloat, width: CGFloat, color: Color,
                      in context: inout GraphicsContext) {
        let xs = stop.memberCenters.map(\.x), ys = stop.memberCenters.map(\.y)
        let rect = CGRect(x: (xs.min() ?? 0) - radius, y: (ys.min() ?? 0) - radius,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0) + radius * 2,
                          height: (ys.max() ?? 0) - (ys.min() ?? 0) + radius * 2)
        let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        if theme.isMonochrome {
            var cut = context
            cut.blendMode = .destinationOut
            cut.fill(shape, with: .color(.black))
        } else {
            context.fill(shape, with: .color(theme.background))
        }
        context.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: width))
    }
}

/// The whole route in a few points, and a window on what the view above shows. A touch anywhere
/// on it, or a drag, moves the window there.
/// Prev, my stop and next, beside the strip: from bus to bus along the line, and back to the
/// rider's stop. Reads the scroll window, so it is redrawn as the view scrolls and nothing else is.
private struct FullRouteNavigator: View {
    @Environment(\.theme) private var theme
    var scene: FullRouteScene
    var window: ScrollWindow
    var focus: FullRouteNavigation.Focus
    var onMove: (Target) -> Void

    enum Target {
        case userStop
        case bus(PuckMark)
    }

    private var centerAlong: CGFloat {
        scene.axis == .horizontal ? window.visible.midX : window.visible.midY
    }

    private func neighbour(_ direction: Int) -> PuckMark? {
        FullRouteNavigation.step(direction, from: focus, in: scene, visibleCenterAlong: centerAlong)
    }

    var body: some View {
        let previous = neighbour(-1), next = neighbour(1)
        HStack(spacing: 6) {
            button("chevron.backward", label: "Previous bus", enabled: previous != nil) {
                previous.map { onMove(.bus($0)) }
            }
            button("scope", label: "My stop", enabled: !scene.isEmpty) { onMove(.userStop) }
            button("chevron.forward", label: "Next bus", enabled: next != nil) {
                next.map { onMove(.bus($0)) }
            }
        }
    }

    private func button(_ symbol: String, label: LocalizedStringKey, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 44, height: 40)
                // The header's close button's ground, so the view's controls read as one set.
                .background(RoundedRectangle(cornerRadius: Radius.badgeSmall, style: .continuous)
                    .fill(theme.closeButton))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(Text(label))
    }
}

private struct FullRouteMinimapView: View {
    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    var scene: FullRouteScene
    var window: ScrollWindow
    private var visible: CGRect { window.visible }
    var onSeek: (CGPoint, FullRouteMinimap) -> Void

    /// A stop's dot: inside the 4-point rail, and well under a bus's 10 × 8 or the rider's 8.
    private static let stopDot: CGFloat = 2.5

    private static let inset = EdgeInsets(top: 10, leading: Spacing.sideInsetPhone,
                                          bottom: 10, trailing: Spacing.sideInsetPhone)

    var body: some View {
        GeometryReader { proxy in
            let strip = CGSize(width: max(0, proxy.size.width - Self.inset.leading - Self.inset.trailing),
                               height: max(0, proxy.size.height - Self.inset.top - Self.inset.bottom))
            let minimap = FullRouteMinimap(axis: scene.axis, content: scene.contentSize, strip: strip,
                                           railsAcross: scene.railsAcross)
            Canvas(rendersAsynchronously: false) { context, _ in
                draw(minimap: minimap, strip: strip, in: &context)
            }
            .frame(width: strip.width, height: strip.height)
            .flipsForRightToLeftLayoutDirection(true)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !scene.isEmpty else { return }
                // The strip is drawn mirrored in a right-to-left language, but the touch is not.
                var point = value.location
                if layoutDirection == .rightToLeft { point.x = strip.width - point.x }
                onSeek(point, minimap)
            })
            .padding(Self.inset)
            .accessibilityElement()
            .accessibilityLabel("Route overview")
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                let window = minimap.window(visible: visible)
                let step = max(window.width, 1)
                let center = CGPoint(x: window.midX + (direction == .increment ? step : -step), y: window.midY)
                onSeek(center, minimap)
            }
        }
    }

    private var accessibilityValue: String {
        let along = scene.axis == .horizontal ? scene.contentSize.width : scene.contentSize.height
        guard along > 0 else { return "" }
        let start = scene.axis == .horizontal ? visible.minX : visible.minY
        let percent = Int((max(0, start) / along * 100).rounded())
        return String(appLocalized: "\(percent) percent along the route")
    }

    private func draw(minimap: FullRouteMinimap, strip: CGSize, in context: inout GraphicsContext) {
        for route in scene.lines {
            let color = theme.rail(route.colorIndex)
            // One path per shade: a see-through stroke drawn segment by segment would darken
            // where each one's round end overlaps the next, and read as a dotted line.
            for faded in [false, true] {
                var path = Path()
                for segment in route.segments where segment.faded == faded {
                    let from = minimap.point(segment.from)
                    if path.currentPoint != from { path.move(to: from) }
                    path.addLine(to: minimap.point(segment.to))
                }
                context.stroke(path, with: .color(faded ? color.opacity(0.35) : color),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        // Every stop as a dot punched in its rail, the strip's own scale of the route's length.
        // Smaller than a bus or the rider's stop, which are drawn over them.
        for stop in scene.stops where stop.role != .userStop {
            for center in stop.memberCenters {
                let p = minimap.point(center)
                let dot = Path(ellipseIn: CGRect(x: p.x - Self.stopDot / 2, y: p.y - Self.stopDot / 2,
                                                 width: Self.stopDot, height: Self.stopDot))
                if theme.isMonochrome {
                    var cut = context
                    cut.blendMode = .destinationOut
                    cut.fill(dot, with: .color(.black))
                } else {
                    context.fill(dot, with: .color(theme.background))
                }
            }
        }
        for stop in scene.stops where stop.role == .userStop {
            for center in stop.memberCenters {
                let node = minimap.point(center)
                context.fill(Path(ellipseIn: CGRect(x: node.x - 4, y: node.y - 4, width: 8, height: 8)),
                             with: .color(theme.primaryText))
            }
        }
        for puck in scene.pucks {
            let p = minimap.point(puck.center)
            context.fill(Path(roundedRect: CGRect(x: p.x - 5, y: p.y - 4, width: 10, height: 8), cornerRadius: 2),
                         with: .color(theme.rail(puck.colorIndex)))
        }
        let window = minimap.window(visible: visible)
        guard window.width > 0, window.height > 0 else { return }
        let frame = Path(roundedRect: window, cornerRadius: 4)
        context.fill(frame, with: .color(theme.primaryText.opacity(0.12)))
        context.stroke(frame, with: .color(theme.primaryText), style: StrokeStyle(lineWidth: 2))
    }

}
#endif
