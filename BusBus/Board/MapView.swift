import SwiftUI

/// The map: rails drawn with `Canvas`, everything else a real view on top.
struct MapView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var model: BoardViewModel
    /// Off on a still picture of the board, where there is nothing to press.
    var showsHint = true

    var body: some View {
        let scene = scene(in: layout.mapSize)
        ZStack(alignment: .topLeading) {
            // The rails and marks cross-fade when the trunk changes; the pucks slide, so they sit
            // outside the fade.
            Group {
                OnwardLayer(scene: scene, onTapStop: stopTapAction)
                MapRailsCanvas(scene: scene)
                StopLabelsLayer(scene: scene, passedStopCode: model.tappedDetail?.bus.lastStopCode,
                                onTapStop: stopTapAction,
                                onTapDash: dashTapAction)
            }
            .id(scene.trunkLineID)
            .transition(.opacity)

            stopTargets(scene: scene)

            pucks(scene: scene)
            nodeCaption(scene: scene)
            hint(scene: scene)
            promotionTargets(scene: scene)
        }
        // Changing `.id` replaces the identity of the layer below, so the cross-fade has to be
        // driven from out here, where the modifier's own state survives the swap.
        .animation(.easeInOut(duration: 0.4), value: scene.trunkLineID)
        .frame(width: layout.mapSize.width, height: layout.mapSize.height)
        // The −35° angle exists so a stop name can be any length, and the artboards let a long one
        // reach a little way into the empty right-hand side of the header band. Only the sides and
        // the foot of the map are a boundary.
        .clipShape(MapBounds(headroom: layout.headerHeight))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map")
    }

    private func scene(in size: CGSize) -> MapScene {
        let named: Set<String>? = layout.namesAllLines ? nil : Set([model.trunkLineID].compactMap { $0 })
        let inputs = model.mapInputs()
        let trunkID = model.trunkLineID ?? inputs.lines.first?.id ?? ""
        return MapLayoutEngine.layout(MapLayoutRequest(
            lines: inputs.lines,
            trunkLineID: trunkID,
            userStopCode: model.stop?.code ?? "",
            vehicles: inputs.vehicles,
            axis: layout.axis,
            preset: layout.preset,
            canvasSize: size,
            scale: layout.mapScale,
            namedLineIDs: named,
            highlightedLineID: model.tappedDetail?.line.id,
            tailBudget: layout.mapTailBudget,
            headCount: layout.mapHeadCount,
            minimumStopPitch: layout.mapMinimumStopPitch))
    }

    /// A still picture of the board, a wall display and Apple TV have nothing to tap a stop with:
    /// on a wall a tap is how the way out is revealed, and must stay that.
    private var stopTapAction: ((String) -> Void)? {
        #if os(tvOS)
        nil
        #else
        guard showsHint, !model.settings.wallMode else { return nil }
        return { [model] code in
            // A tap on the board lets go of a bus or the tip first, wherever it lands; only a tap
            // with nothing to let go of opens anything.
            guard !model.dismissesBeforeOpening else { return model.dismissTapped() }
            model.inspectStop(code: code)
        }
        #endif
    }

    private var dashTapAction: (() -> Void)? {
        guard stopTapAction != nil else { return nil }
        return { [model] in
            guard !model.dismissesBeforeOpening else { return model.dismissTapped() }
            model.showsFullRoute = true
        }
    }

    /// The marks are a few points across; each gets the standard target, under the pucks so a bus
    /// sitting at a stop is still the bus.
    @ViewBuilder private func stopTargets(scene: MapScene) -> some View {
        if let action = stopTapAction {
            ForEach(scene.stops) { mark in
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(mark.center)
                    .onTapGesture { action(mark.stopCode) }
                    .accessibilityHidden(true)
            }
        }
    }

    /// The same one-second tick the readout runs on, so what VoiceOver reads off a puck counts
    /// down with the number beside it instead of freezing between refreshes.
    private func pucks(scene: MapScene) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack(alignment: .topLeading) {
                ForEach(scene.pucks) { puck in
                    let bus = model.snapshot.buses.first { $0.id == puck.vehicleID }
                    let arrival = model.snapshot.arrivals.first { $0.bus?.id == puck.vehicleID }
                    BusPuckView(puck: puck,
                                minutes: arrival?.minutes(at: context.now),
                                stopsAway: bus?.stopsAway,
                                positionAge: bus?.positionAge) {
                        model.tap(busID: puck.vehicleID)
                    }
                    .position(puck.center)
                    .animation(.easeInOut(duration: 0.6), value: puck.center)
                }
            }
            .frame(width: layout.mapSize.width, height: layout.mapSize.height, alignment: .topLeading)
        }
    }

    private func nodeCaption(scene: MapScene) -> some View {
        YourStopCaption(convergence: scene.convergence)
            .accessibilityLabel(model.stop.map { "Your stop, \($0.name)" } ?? "Your stop" as LocalizedStringKey)
    }

    /// The remote has no finger to tap with.
    #if os(tvOS)
    private static let hintText: LocalizedStringKey = "PRESS SELECT TO INSPECT A BUS"
    #else
    private static let hintText: LocalizedStringKey = "TAP A BUS TO INSPECT IT"
    #endif

    @ViewBuilder private func hint(scene: MapScene) -> some View {
        if let anchor = scene.hintAnchor, showsHint, model.showsHint {
            AnchoredText(anchor: anchor, alignment: .topLeading, rotationDegrees: 0, rotationAnchor: .center) {
                Text(Self.hintText)
                    .busText(TypeStyles.hint, scale: layout.scale)
                    .foregroundStyle(theme.dashCaption)
            }
            .accessibilityHidden(true)
        }
    }

    /// On a narrow phone the two lines you are not catching are drawn as unnamed distance spines.
    /// Tapping one promotes it to the centre and brings the names with it.
    @ViewBuilder private func promotionTargets(scene: MapScene) -> some View {
        if !layout.namesAllLines {
            ForEach(scene.termini.filter { $0.lineID != scene.trunkLineID }) { terminus in
                Button {
                    model.promoteTrunk(terminus.lineID)
                } label: {
                    Color.clear
                        .frame(width: max(44, terminus.rect.width), height: max(44, terminus.rect.height))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: terminus.rect.midX, y: terminus.rect.midY)
                .accessibilityLabel("Show the route of line \(model.line(terminus.lineID)?.shortName ?? terminus.lineID)")
            }
        }
    }
}

/// The map's own frame, opened upward so a stop name is never cut off mid-word.
private struct MapBounds: Shape {
    var headroom: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - headroom,
                    width: rect.width, height: rect.height + headroom))
    }
}
