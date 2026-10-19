import SwiftUI

/// The board itself: header, map, readout. One code path for every platform and orientation — the
/// only thing that changes is the size the system hands it.
struct BoardView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection

    @Bindable var model: BoardViewModel
    /// The board sits on top of the stop list, and changing stop is going back to it — which the
    /// navigation stack that owns them both does.
    var onChangeStop: () -> Void
    /// False for a still picture of the board (Apple TV's Top Shelf), drawn beside the live one:
    /// it must neither start the model's polling nor stop it when the picture is done.
    var drivesModel = true
    /// The board pulled to refresh, alongside its own refresh: the app looks for the stop the rider
    /// is standing at too.
    var onPull: @MainActor @Sendable () -> Void = {}
    @State private var housing = SensorHousing()
    /// A wall display out of hours, black until tapped: nobody is reading it, so it asks for nothing.
    @State private var wallIsDark = false

    /// The black screen stops the polling, and the tap that lifts it fetches at once, so the board
    /// it reveals is current rather than as old as the night.
    private func wallDarkChanged(_ dark: Bool) {
        wallIsDark = dark
        guard drivesModel else { return }
        if dark {
            model.stopPolling()
        } else if scenePhase != .background {
            model.start()
            Task { await model.refresh(.wake) }
        }
    }

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        // Reading the insets and spanning them are mutually exclusive: a view that takes over an
        // edge is told that edge's inset is zero. So the size is measured inside the safe area and
        // the board is widened back out by hand.
        GeometryReader { proxy in
            let safeArea = BoardLayout.SafeArea(proxy.safeAreaInsets)
            let full = CGSize(width: proxy.size.width + safeArea.leading + safeArea.trailing,
                              height: proxy.size.height + safeArea.top + safeArea.bottom)
            let layout = BoardLayout.resolve(size: full, lineCount: model.lines.count,
                                             horizontal: horizontalSizeClass, vertical: verticalSizeClass,
                                             safeArea: safeArea, housingEdge: housing.edge(in: layoutDirection),
                                             wall: model.settings.wallMode)
            let status = model.serviceStatus
            Group {
                if status.replacesBoard {
                    // The polling loop runs on behind this, so it gives way by itself on recovery.
                    ServiceDownView(layout: layout, status: status, serviceName: model.serviceName,
                                    lastSuccessAt: model.lastSuccessAt,
                                    statusMessage: RemoteFlags.shared.serviceStatusMessage,
                                    onChangeStop: onChangeStop,
                                    onSettings: { model.showsSettings = true })
                        .transition(.opacity)
                } else {
                    boardBody(layout: layout)
                    // Letting go of a bus is a tap anywhere that is not a bus. Pucks and the
                    // header's buttons are buttons, and a button wins over a tap behind it.
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissTapped() }
                    .overlayPreferenceValue(StopTitleAnchorKey.self) { anchor in
                        // Fades however it goes: its ×, a tap on the board, or its own timer.
                        ZStack { setupTip(anchor: anchor, layout: layout) }
                            .animation(.easeOut(duration: 0.25), value: model.showsSetupTip)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: status.replacesBoard)
            // Words built in code — the live label, the sub-line, every VoiceOver label — are only
            // read again when their view is rebuilt, so a new language rebuilds the board. The
            // sheet hangs off the reader outside this, and stays open.
            .id(model.settings.language)
            .padding(.top, layout.contentInsetTop)
            .padding(.bottom, layout.contentInsetBottom)
            .frame(width: full.width, height: full.height)
            // A GeometryReader lays its content out from its own top-leading corner, and that
            // corner is already inside the reservation, so the widened board has to be pulled back
            // out to the screen edge rather than left overhanging the far side.
            .offset(x: -safeArea.leading, y: -safeArea.top)
            // Nothing to pull on Apple TV, where the board polls on its own and the remote has
            // no drag to give.
            #if !os(tvOS)
            .modifier(PullToRefresh(size: proxy.size, isEnabled: !model.settings.wallMode) {
                await onPull()
                await model.refresh(.pull)
            })
            #endif
            // Behind the whole board, not just the map: on a wall display the numbers are half of
            // it, and a tap there has to reveal the way out too. Pucks sit above and still win.
            .modifier(WallModeModifier(isActive: model.settings.wallMode,
                                       schedule: model.settings.wallSchedule,
                                       onDarkChange: wallDarkChanged))
        }
        // The board spans the whole screen and does its own edge-keeping, so a margin is never
        // counted twice.
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        .sheet(isPresented: $model.showsSettings) {
            SettingsView(settings: model.settings)
        }
        #if !os(tvOS)
        .sheet(isPresented: $model.showsLinePicker) {
            BoardLinesSheet(model: model)
        }
        .sheet(item: $model.inspectedStop) { request in
            StopCardView(request: request, settings: model.settings)
                .busTheme()
        }
        .sheet(item: $model.inspectedLine) { request in
            LineCardView(request: request, settings: model.settings)
                .busTheme()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $model.showsFullRoute) {
            FullRouteView(model: model)
        }
        #elseif os(macOS)
        .sheet(isPresented: $model.showsFullRoute) {
            FullRouteView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        #endif
        .task { if drivesModel && !wallIsDark { model.start() } }
        // A full-screen cover takes the board off screen too, and the full route it covers it with
        // shows the same live buses: the board keeps polling for it.
        .onDisappear { if drivesModel && !model.showsFullRoute { model.stopPolling() } }
        .onChange(of: scenePhase) { _, phase in
            guard drivesModel else { return }
            // Coming back to the foreground, show current numbers immediately rather than waiting
            // out the polling interval; going away, stop asking for numbers nobody can see.
            if phase == .active {
                guard !wallIsDark else { return }
                model.start()
                Task { await model.refresh(.foreground) }
            } else if phase == .background {
                model.stopPolling()
            }
        }
        #if os(iOS)
        .statusBarHidden(model.settings.wallMode)
        .persistentSystemOverlays(model.settings.wallMode ? .hidden : .automatic)
        // With the status bar gone the header's gear sits in the corner Control Center is pulled
        // from, and the system held every tap there back to see whether it was a swipe. The board
        // goes first now; Control Center takes a second swipe, which a wall display wants anyway.
        .defersSystemGestures(on: model.settings.wallMode ? .top : [])
        #endif
        .analyticsScreen("board")
    }

    /// The first board's one tip, hung under the stop's name, the thing it says to tap. It waits
    /// out a service-down screen and comes back with the board.
    @ViewBuilder private func setupTip(anchor: Anchor<CGRect>?, layout: BoardLayout) -> some View {
        if model.showsSetupTip, let anchor, let name = model.stop?.name {
            GeometryReader { proxy in
                let title = proxy[anchor]
                SetupTipView(stopName: name, compact: layout.mode == .phone, scale: layout.scale) {
                    model.showsSetupTip = false
                }
                .padding(.leading, max(12, title.minX - 8))
                .padding(.trailing, 12)
                .padding(.top, title.maxY + 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private func boardBody(layout: BoardLayout) -> some View {
        if let readoutWidth = layout.wallReadoutWidth {
            HStack(spacing: 0) {
                WallReadoutView(layout: layout, model: model)
                    .frame(width: readoutWidth)
                WallColumnView(layout: layout, model: model,
                               onChangeStop: onChangeStop,
                               onSettings: { model.showsSettings = true })
            }
        } else {
            VStack(spacing: 0) {
                HeaderView(layout: layout, model: model,
                           onChangeStop: onChangeStop,
                           onSettings: { model.showsSettings = true })
                    .frame(height: layout.headerHeight)
                MapView(layout: layout, model: model)
                    .frame(height: layout.mapSize.height)
                    .padding(.leading, layout.mapInsetLeading)
                    .padding(.trailing, layout.mapInsetTrailing)
                readout(layout: layout)
                    .frame(height: layout.readoutHeight)
            }
        }
    }

    @ViewBuilder private func readout(layout: BoardLayout) -> some View {
        if layout.isCompact {
            CompactReadoutView(model: model, scale: layout.scale)
        } else {
            switch layout.mode {
            case .landscape, .landscapeSingle: ReadoutView(layout: layout, model: model)
            case .phone, .pad: ReadoutPortraitView(layout: layout, model: model)
            }
        }
    }
}

/// Pulling the board down asks for numbers now rather than at the next poll — the gesture riders
/// already try on any screen of times. The board fills the screen exactly and never scrolls, so it
/// is set in a scroll view of its own size that only moves to be pulled.
///
/// The scroll view sits inside the safe area, where the board is measured, and does not clip: the
/// board is drawn out past it to the screen edges and has to stay drawn there. A wall display is
/// left still — nobody pulls it, and a brush against it should not move it.
private struct PullToRefresh: ViewModifier {
    var size: CGSize
    var isEnabled: Bool
    var action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        ScrollView(.vertical) {
            // From the corner, as the reader it replaces placed it: the widened board overhangs
            // this frame, and a centred one would shift it by half the overhang.
            content.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollDisabled(!isEnabled)
        .refreshable { await action() }
    }
}

/// A window too small for the readout still says the one thing that matters.
struct CompactReadoutView: View {
    @Environment(\.theme) private var theme
    var model: BoardViewModel
    var scale: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if let primary = model.primary {
                    let countdown = primary.arrival.countdown(at: context.now)
                    if countdown.isHours {
                        Text("\(primary.line.shortName) · \(countdown.figure) HR")
                    } else {
                        Text("\(primary.line.shortName) · \(countdown.minutes) MIN")
                    }
                } else if model.isAwaitingFirstBoard {
                    SkeletonBlock(width: 140 * max(1, scale * 2), height: 14 * max(1, scale * 2),
                                  radius: 4 * max(1, scale * 2))
                        .shimmering()
                        .accessibilityLabel(Text("Loading arrivals"))
                } else {
                    Text("NO BUSES DUE")
                }
            }
            .busText(TypeStyles.kicker, scale: max(1, scale * 2))
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.readoutBand)
        }
    }
}
