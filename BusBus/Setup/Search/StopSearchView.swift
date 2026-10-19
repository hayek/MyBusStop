import SwiftUI
import MapKit

#if !os(tvOS)
/// The search screen: a field to type into, the map edge to edge under it, and the stops in view in
/// a drawer over the map's foot — or, in a window wider than it is tall, in a panel beside it.
///
/// The map and the list show the same stops, and a tap on either is the same tap: both go through
/// `startConfirm`, so a stop is never chosen by a mis-tap on a small pin. SELECT STOP pushes the
/// stop's lines over this screen (`StopSearchFlow`), which waits beneath them as it was left.
struct StopSearchView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Resolved here rather than taken from the environment: this screen is presented on its own,
    /// and a screen that relies on an ancestor for its colours renders dark in silence.
    private var theme: Theme { Theme.resolve(colorScheme) }
    @Environment(\.scenePhase) private var scenePhase
    var model: SetupViewModel

    @FocusState private var fieldFocused: Bool
    @State private var position: MapCameraPosition = .automatic
    /// A stop for the map to centre in what the drawer leaves uncovered (the confirm step's).
    @State private var focusRequest: FocusRequest?
    /// Where the map last came to rest, for the confirm step to put it back on BACK.
    @State private var settledCamera: SavedCamera?
    /// How tall the drawer is drawn right now, mid-drag included, so the recenter button rides on
    /// it. Only for that: framing uses the height the drawer is settling to.
    @State private var drawerShownHeight: CGFloat = 0
    /// The list's place in the drawer, kept here so it outlives the drawer while the confirm panel
    /// stands in for it.
    @State private var listScroll = ScrollPosition(idType: String.self)
    @State private var listIsAtTop = true
    /// The confirm panel's height as drawn, from the screen's foot: what the map centres above.
    @State private var confirmPanelHeight: CGFloat?
    /// The confirm step's stop, waiting for the panel to be measured before the map moves to it.
    @State private var pendingFocus: GeoPoint?
    /// The panel height the map last centred the confirm step's stop above. The panel grows when
    /// a search result's lines arrive, and the stop is centred again above its new height.
    @State private var focusedPanelHeight: CGFloat?
    /// The height left above the keyboard. The layout is drawn behind the keyboard at full height,
    /// so the drawer does not jump when it comes up; only the list's foot makes room for it.
    @State private var heightAboveKeyboard: CGFloat?
    /// The line whose card the ⓘ in the confirm step opened.
    @State private var inspectedLine: LineCardRequest?

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightAboveKeyboard = $0 }
            .overlay {
                GeometryReader { proxy in
                    screen(size: proxy.size, safeArea: proxy.safeAreaInsets)
                }
                .ignoresSafeArea(.keyboard)
            }
            .background(theme.background.ignoresSafeArea())
            .busTheme()
            // Not again on coming back from the line picker: the confirm step is waiting there as
            // it was, and a fresh list behind it would undo what BACK promises to put back.
            .task {
                guard !model.search.isConfirming else { return }
                await model.loadNearby()
            }
            // An answer given in Settings, or a fix that timed out while the rider was away.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.reloadNearbyIfLocationChanged() }
            }
            // Core Location's own word that the answer changed. A Mac's window can stay active
            // while the rider is over in System Settings, so coming back is not always a scene
            // change; this is what turns the card into stops the moment location is allowed.
            .onChange(of: model.location.status) {
                Task { await model.reloadNearbyIfLocationChanged() }
            }
            .onAppear {
                if model.search.focusesFieldOnOpen, !model.search.isConfirming { fieldFocused = true }
            }
            .sheet(item: $inspectedLine) { request in
                LineCardView(request: request, settings: model.settings)
                    .busTheme()
            }
        .analyticsScreen("search")
    }

    // MARK: Layout

    private func screen(size: CGSize, safeArea: EdgeInsets) -> some View {
        let usesPanel = StopSearchSession.usesSidePanel(size)
        let panelWidth = Self.panelWidth(screenWidth: size.width)
        let scale = Self.scale(contentWidth: usesPanel ? panelWidth : size.width)
        let keyboard = max(0, size.height - (heightAboveKeyboard ?? size.height))
        // The list's foot clears whichever is taller: the home indicator, or the keyboard over it.
        let listFoot = max(safeArea.bottom, keyboard)
        return VStack(spacing: 0) {
            header(scale: scale)
            GeometryReader { area in
                mapArea(areaHeight: area.size.height, screenHeight: size.height + safeArea.bottom,
                        usesPanel: usesPanel, panelWidth: panelWidth, safeArea: safeArea,
                        listFoot: listFoot, scale: scale)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// The panel is a phone's width beside the map, never more than half the window.
    static func panelWidth(screenWidth: CGFloat) -> CGFloat { min(380, screenWidth * 0.5) }

    /// Read off the width the list is drawn in, a phone's in either layout: the rows are the
    /// phone's, and a wide window gives them a panel rather than larger type.
    static func scale(contentWidth: CGFloat) -> CGFloat { min(max(contentWidth / 390, 0.85), 1.2) }

    @ViewBuilder private func mapArea(areaHeight: CGFloat, screenHeight: CGFloat, usesPanel: Bool,
                                      panelWidth: CGFloat, safeArea: EdgeInsets, listFoot: CGFloat,
                                      scale: CGFloat) -> some View {
        // The panel reaches under a landscape phone's sensor housing, so the map's covered side
        // counts that strip too.
        let leadingCover = usesPanel ? panelWidth + safeArea.leading : 0
        let heights = DrawerHeights(areaHeight: areaHeight, screenHeight: screenHeight)
        let confirming = model.confirmingStop
        // Framed for the height the drawer is going to, not the one last drawn: clearing the field
        // reframes the stops and lowers the drawer in the same moment. Mid-confirm, the panel in
        // the drawer's place is what covers the map.
        let drawerCover = confirming != nil ? confirmPanelHeight ?? heights.height(model.search.drawer)
                                            : heights.height(model.search.drawer)
        let confirmCap = StopSearchSession.confirmPanelMaxHeight(heights)
        let bottomCover = usesPanel ? safeArea.bottom : drawerCover
        ZStack(alignment: usesPanel ? .topLeading : .bottom) {
            SearchMapView(model: model, position: $position, scale: scale,
                          bottomCover: bottomCover,
                          recenterLift: usesPanel || drawerShownHeight == 0 ? bottomCover : drawerShownHeight,
                          leadingCover: leadingCover, trailingInset: usesPanel ? safeArea.trailing : 0,
                          focusRequest: focusRequest,
                          onSelect: startConfirm,
                          onBack: back,
                          onCameraSettled: { camera, _ in settledCamera = camera })
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])

            Group {
                if usesPanel {
                    Group {
                        if let confirming {
                            confirmPanel(confirming, scale: scale, fillsHeight: true, bottomInset: safeArea.bottom)
                                .searchDrawerGround(isPanel: true, scale: scale)
                                .onAppear { focusIfPending(bottom: safeArea.bottom, leading: leadingCover) }
                        } else {
                            SearchDrawer(style: .panel, height: drawerHeight, scale: scale,
                                         scrollPosition: $listScroll, onScrolledToTop: { listIsAtTop = $0 }) {
                                SearchListHeader(model: model, scale: scale)
                            } content: {
                                list(scale: scale, foot: listFoot)
                            }
                        }
                    }
                    .frame(width: panelWidth)
                    .transition(.opacity)
                    .padding(.leading, safeArea.leading)
                    // The same ground under the sensor housing, so no sliver of map shows beside it.
                    .background(theme.background)
                    .ignoresSafeArea(.container, edges: .leading)
                } else if let confirming {
                    confirmPanel(confirming, scale: scale, fillsHeight: false, bottomInset: safeArea.bottom)
                        .searchDrawerGround(isPanel: false, scale: scale)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            confirmPanelHeight = height
                            focusIfPending(bottom: height, leading: 0)
                            refocusIfPanelResized(height)
                        }
                        // As tall as its lines need, up to a cap that leaves the stop room on the
                        // map above; past that, the lines scroll inside it.
                        .frame(maxHeight: confirmCap, alignment: .bottom)
                        .transition(.move(edge: .bottom))
                } else {
                    SearchDrawer(style: .drawer(heights),
                                 height: drawerHeight, scale: scale,
                                 scrollPosition: $listScroll, onScrolledToTop: { listIsAtTop = $0 }) {
                        SearchListHeader(model: model, scale: scale)
                    } content: {
                        list(scale: scale, foot: listFoot)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drawerShownHeight = $0 }
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.snappy(duration: 0.3), value: confirming?.id)
        }
    }

    private func confirmPanel(_ entry: NearbyStop, scale: CGFloat, fillsHeight: Bool,
                              bottomInset: CGFloat) -> some View {
        let meters = StopSearchSession.distance(to: entry, from: model.location.current)
        return ConfirmStopPanel(entry: entry, linesState: model.confirmLinesState ?? .loading,
                                failureCaption: model.confirmFailureCaption,
                                canSelect: model.canSelectConfirmingStop,
                                colorIndex: { model.colorIndex(for: $0) },
                                walkCaption: StopSearchSession.walkCaption(meters: meters),
                                scale: scale, fillsHeight: fillsHeight, bottomInset: bottomInset,
                                allowsShortcuts: !model.search.isPickingLines,
                                onBack: back, onSelect: { Task { await model.selectConfirmingStop() } },
                                onAboutLine: { line in
                                    inspectedLine = LineCardRequest(line: line, providerID: model.settings.providerID,
                                                                    stopCode: entry.stop.code)
                                },
                                hasCard: { model.settings.provider(id: model.settings.providerID).hasRouteShape(for: $0) })
            .id(entry.id)
    }

    private var drawerHeight: Binding<DrawerHeight> {
        Binding(get: { model.search.drawer }, set: { model.search.drawer = $0 })
    }

    private func list(scale: CGFloat, foot: CGFloat) -> some View {
        SearchListContent(model: model, scale: scale, bottomInset: foot,
                          onSelect: startConfirm, onFocusField: { fieldFocused = true })
    }

    /// The field, and CANCEL to leave the whole screen. A real text field, on solid ground over
    /// the map.
    private func header(scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }), focus: $fieldFocused,
                        scale: scale, clears: true)
                // Held as it is while a stop is being confirmed: new results would pull the list
                // out from under the panel, and BACK promises the list as the rider left it.
                .disabled(model.search.isConfirming)
            Button { model.closeSearch() } label: {
                Text("CANCEL")
                    .busText(TypeStyles.sectionHeaderPhone, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Escape on a Mac, as for any sheet — but not mid-confirm, where it means BACK.
            .keyboardShortcut(model.search.isConfirming ? nil : .cancelAction)
            .accessibilityHint("Close search")
            .accessibilityIdentifier("search.cancel")
        }
        .padding(.horizontal, Spacing.sideInsetPhone * scale)
        .padding(.vertical, 10 * scale)
        .background(theme.background)
        // Over the map's shadowed edge rather than under it.
        .zIndex(1)
    }

    // MARK: Choosing

    /// The one way in from a tapped row or pin: the stop is centred on the map and asked about,
    /// never chosen outright. What the rider was looking at is kept for BACK to put back.
    private func startConfirm(_ entry: NearbyStop) {
        // A second tap on the stop being asked about does nothing: BACK is the way out.
        guard !model.search.isConfirming else { return }
        fieldFocused = false
        let restore = SearchRestore(drawer: model.search.drawer,
                                    scrolledToStopID: listIsAtTop ? nil : listScroll.viewID(type: String.self),
                                    camera: settledCamera)
        focusRequest = nil
        focusedPanelHeight = nil
        pendingFocus = entry.stop.location
        Task { await model.beginConfirm(entry, restore: restore) }
    }

    /// Moves the map to the confirm step's stop once the panel's size is known, so the stop lands
    /// in the middle of what the panel leaves uncovered rather than under it.
    private func focusIfPending(bottom: CGFloat, leading: CGFloat) {
        guard let point = pendingFocus else { return }
        pendingFocus = nil
        focusedPanelHeight = bottom
        focusRequest = FocusRequest(point: point, bottomInset: bottom, leadingInset: leading,
                                    minDistance: StopSearchSession.confirmSpanMeters)
    }

    /// The portrait panel grew or shrank once the stop was centred — its lines came in, or turned
    /// out to be none — so the stop is centred again above the panel as it now stands, rather than
    /// left under it. Small changes are let be.
    private func refocusIfPanelResized(_ height: CGFloat) {
        guard pendingFocus == nil, let shown = focusedPanelHeight, abs(height - shown) > 12,
              let point = model.confirmingStop?.stop.location else { return }
        focusedPanelHeight = height
        focusRequest = FocusRequest(point: point, bottomInset: height, leadingInset: 0,
                                    minDistance: StopSearchSession.confirmSpanMeters)
    }

    /// BACK — the button, a tap on the map, or Escape: the drawer at its height and scroll, and
    /// the map where it was before the stop was centred.
    private func back() {
        guard let restore = withAnimation(.snappy(duration: 0.3), { model.backFromConfirm() }) else { return }
        focusRequest = nil
        pendingFocus = nil
        focusedPanelHeight = nil
        if let id = restore.scrolledToStopID {
            listScroll.scrollTo(id: id, anchor: .top)
        } else {
            listScroll.scrollTo(edge: .top)
        }
        if let camera = restore.camera {
            withAnimation(.easeInOut(duration: 0.4)) {
                position = .camera(MapCamera(centerCoordinate: camera.center.coordinate, distance: camera.distance))
            }
        }
        AccessibilityNotification.ScreenChanged(nil).post()
    }
}

#if DEBUG
/// The mock's stops around its own anchor, with location allowed: the screen as a rider with a fix
/// first sees it.
@MainActor private func previewModel(query: String = "") -> SetupViewModel {
    let suite = "StopSearchView.preview"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    let settings = SettingsStore(defaults: defaults)
    settings.providerOverride = MockTransitProvider()
    settings.regionIsAvailable = { _ in true }
    settings.providerHasKey = { _ in true }
    settings.transitousIsEnabled = { false }
    let location = LocationService(source: .init(status: { .authorizedAlways }, requestPermission: {},
                                                 fix: { _ in MockTransitProvider.anchor }))
    let model = SetupViewModel(settings: settings, location: location)
    model.openSearch()
    model.query = query
    return model
}

#Preview("Portrait") {
    StopSearchFlow(model: previewModel(), onConfirmLines: {})
}

#Preview("Landscape", traits: .fixedLayout(width: 852, height: 393)) {
    StopSearchFlow(model: previewModel(), onConfirmLines: {})
}

#Preview("Typing") {
    StopSearchFlow(model: previewModel(query: "harbor"), onConfirmLines: {})
}
#endif
#endif
