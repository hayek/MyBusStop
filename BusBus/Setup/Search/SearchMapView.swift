import SwiftUI
import MapKit

#if !os(tvOS)
/// A stop for the search map to put in the middle of what the rider can see, past the drawer or
/// panel over it. Set it to nil before asking for the same stop twice: only a change moves the map.
struct FocusRequest: Equatable {
    var point: GeoPoint
    /// How much of the map's foot the drawer or confirm panel covers, in points.
    var bottomInset: CGFloat
    /// How much of the map's leading side the side panel covers, in points.
    var leadingInset: CGFloat
    /// The widest view, in metres across, the stop is shown in: a map showing more than this zooms
    /// in to it, and one showing less keeps its zoom.
    var minDistance: Double
}

/// The search screen's map, edge to edge under the drawer: the stops the list names (numbered
/// while the rider is typing), the rider, a search of wherever the map has been moved to, and the
/// way back to the rider.
///
/// Everything it frames, it frames in the part the drawer or panel leaves uncovered (`cover`): a
/// stop under the drawer is on screen and still out of sight.
struct SearchMapView: View {
    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    var model: SetupViewModel
    @Binding var position: MapCameraPosition
    var scale: CGFloat
    /// How much of the map the drawer (from the foot) or the side panel (from the leading side)
    /// lies over, for framing: the drawer's settled height, not one caught mid-move.
    var bottomCover: CGFloat
    /// The drawer's top as drawn right now, mid-drag included: the recenter button rides on it.
    var recenterLift: CGFloat
    var leadingCover: CGFloat
    /// Kept clear at the trailing edge for the sensor housing of a phone on its side.
    var trailingInset: CGFloat = 0
    var focusRequest: FocusRequest?
    /// A pin tapped: the same way into the confirm step as a row.
    var onSelect: (NearbyStop) -> Void
    /// The map tapped around the confirm step's stop: the same as its BACK.
    var onBack: () -> Void = {}
    /// Where the map came to rest after any move, for BACK to put it back there.
    var onCameraSettled: (SavedCamera, MKMapRect) -> Void

    /// Where the map settled after the last move, whoever made it.
    @State private var viewport: Viewport?
    /// The middle of what the rider could see where the app last put the map, or where they last
    /// searched. Moving away from it is what offers a new search.
    @State private var anchor: GeoPoint?
    @State private var mapSize: CGSize = .zero

    private struct Viewport {
        /// What the map shows edge to edge, under the drawer too.
        var rect: MKMapRect
        /// The middle of the uncovered part, and its shorter side in metres.
        var visibleCenter: GeoPoint
        var visibleSpanMeters: Double
    }

    /// What the map has to be reframed for.
    private struct FitKey: Hashable {
        var stopIDs: [String]
        var isShowingResults: Bool
        var isAreaSearch: Bool
        var hasRider: Bool
    }

    private var fitKey: FitKey {
        FitKey(stopIDs: model.mapStops.map(\.id), isShowingResults: model.isShowingResults,
               isAreaSearch: model.isAreaSearch, hasRider: model.location.current != nil)
    }

    /// The listed stops, and the confirm step's stop with them even when a refresh behind the
    /// panel has dropped it from the list: the stop being asked about never leaves the map.
    private var pins: [NearbyStop] {
        let listed = model.mapStops
        guard let confirming = model.confirmingStop, !listed.contains(where: { $0.id == confirming.id }) else {
            return listed
        }
        return listed + [confirming]
    }

    private var cover: MapCover {
        MapCover(leading: leadingCover, bottom: bottomCover, layoutDirection: layoutDirection)
    }

    var body: some View {
        // Read here, not in the annotation: MapKit builds annotation content outside this body, so
        // a read in there is never tracked and the pins would keep the first stop picked out.
        let focusedStopID = model.focusedStopID
        let confirmingID = model.confirmingStop?.id
        let numbered = model.isShowingResults
        let listedCount = model.mapStops.count
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            ForEach(Array(pins.enumerated()), id: \.element.id) { index, entry in
                Annotation(entry.stop.name, coordinate: entry.stop.location.coordinate, anchor: .center) {
                    let isConfirmed = entry.id == confirmingID
                    // Mid-confirm, the other stops stay on the map for their bearings, faded and
                    // out of reach: a tap there is a tap on the map, which is BACK.
                    let isFaded = confirmingID != nil && !isConfirmed
                    StopPin(name: entry.stop.name, number: numbered && index < listedCount ? index + 1 : nil,
                            isFocused: entry.id == focusedStopID, showsHalo: isConfirmed, scale: scale) {
                        onSelect(entry)
                    }
                    .opacity(isFaded ? 0.4 : 1)
                    .allowsHitTesting(!isFaded)
                    .accessibilityHidden(isFaded)
                    .animation(.easeOut(duration: 0.25), value: isFaded)
                }
                .annotationTitles(.hidden)
            }
        }
        // The only pins are ours: the map's own transit stops would be a second, unpickable set.
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // Only while confirming: at any other time a tap gesture on the map would hold back its
        // own double-tap zoom and sit over the pins' taps for nothing.
        .gesture(TapGesture().onEnded { onBack() },
                 including: model.search.isConfirming ? .all : .subviews)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // The first frame comes before the map knows its size, so it could not allow for the
            // drawer; framed again once it does.
            let isFirst = mapSize == .zero
            mapSize = size
            if isFirst { reframe() }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let visible = MapFraming.visibleRect(of: context.rect, in: mapSize, cover: cover)
            viewport = Viewport(rect: context.rect,
                                visibleCenter: GeoPoint(MKMapPoint(x: visible.midX, y: visible.midY).coordinate),
                                visibleSpanMeters: MapFraming.spanMeters(of: visible))
            onCameraSettled(SavedCamera(center: GeoPoint(context.camera.centerCoordinate),
                                        distance: context.camera.distance), context.rect)
        }
        .onChange(of: fitKey, initial: true) { reframe() }
        .onChange(of: focusRequest) { _, request in
            guard let request else { return }
            focus(on: request)
        }
        .overlay(alignment: .top) {
            if showsSearchButton {
                searchButton
                    .padding(.top, 10 * scale)
                    .padding(.leading, leadingCover)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsRecenterButton {
                recenterButton
                    .padding(.trailing, trailingInset + 10 * scale)
                    .padding(.bottom, recenterLift + 10 * scale)
            }
        }
        .animation(.snappy(duration: 0.25), value: showsSearchButton)
        .animation(.snappy(duration: 0.25), value: showsRecenterButton)
    }

    // MARK: Framing

    /// An area the rider searched stays where they put it; everything else is framed. An empty
    /// result leaves the map where it was, rather than flying off to nothing.
    private func reframe() {
        // The confirm step holds the map on its stop; BACK puts back the camera from before it.
        guard !model.search.isConfirming else { return }
        if model.isAreaSearch, !model.isShowingResults {
            anchor = model.stopsCenter
        } else if !(model.isShowingResults && model.mapStops.isEmpty) {
            fit()
        }
    }

    /// The listed stops, with the rider among them when they are the stops around the rider, or
    /// the region the search covers when there is nothing to frame yet.
    private func fit(aroundRider: Bool = false) {
        let showsResults = model.isShowingResults && !aroundRider
        var points = (showsResults ? model.mapStops : model.nearby).map(\.stop.location)
        // Nearby stops are framed with the rider among them, so the map says which way to walk.
        if !showsResults, let rider = model.location.current { points.append(rider) }
        let target: MKMapRect
        if !points.isEmpty {
            target = MapFraming.rect(around: points, minimumMeters: 700)
        } else if let bounds = model.currentRegion?.bounds {
            // Location off: the region the search covers, to be browsed and searched by area.
            target = MapFraming.rect(around: [GeoPoint(lat: bounds.minLat, lon: bounds.minLon),
                                              GeoPoint(lat: bounds.maxLat, lon: bounds.maxLon)],
                                     minimumMeters: 0, padding: 0)
        } else {
            return
        }
        anchor = GeoPoint(MKMapPoint(x: target.midX, y: target.midY).coordinate)
        let rect = MapFraming.rect(showing: target, in: mapSize, cover: cover)
        withAnimation(.easeInOut(duration: 0.35)) { position = .rect(rect) }
    }

    /// The stop in the middle of what the drawer or panel leaves uncovered, zoomed in only when the
    /// map shows more than the request allows.
    private func focus(on request: FocusRequest) {
        let cover = MapCover(leading: request.leadingInset, bottom: request.bottomInset,
                             layoutDirection: layoutDirection)
        let rect = MapFraming.rect(centering: request.point, from: viewport?.rect, in: mapSize, cover: cover,
                                   widestSpanMeters: request.minDistance)
        withAnimation(.easeInOut(duration: 0.4)) { position = .rect(rect) }
    }

    private var hasMoved: Bool {
        guard let viewport, let anchor else { return false }
        return MapFraming.hasMoved(from: anchor, to: viewport.visibleCenter, spanMeters: viewport.visibleSpanMeters)
    }

    // MARK: Controls

    /// Offered once the map has been moved, and always when there is nothing listed — that is the
    /// only way to stops for a rider who has not shared where they are.
    private var showsSearchButton: Bool {
        guard !model.isShowingResults, !model.search.isConfirming, viewport != nil else { return false }
        return hasMoved || model.nearby.isEmpty
    }

    private var canSearchHere: Bool {
        guard let viewport else { return false }
        return viewport.visibleSpanMeters <= MapFraming.searchableSpanMeters
    }

    private var searchButton: some View {
        Button {
            guard let viewport else { return }
            anchor = viewport.visibleCenter
            Task { await model.searchArea(around: viewport.visibleCenter, spanMeters: viewport.visibleSpanMeters) }
        } label: {
            Text(canSearchHere ? "SEARCH THIS AREA" : "ZOOM IN TO SEARCH" as LocalizedStringKey)
                .busText(TypeStyles.countCaptionPhone, scale: scale)
                .foregroundStyle(theme.primaryButtonText)
                .padding(.horizontal, 16 * scale)
                .frame(height: 36 * scale)
                .background(Capsule().fill(theme.primaryButtonFill))
                // The search is under way; the button says so without growing a spinner.
                .shimmering(model.isLoadingStops, tint: theme.primaryButtonText)
                .shadow(color: .black.opacity(0.18), radius: 6 * scale, y: 2 * scale)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSearchHere || model.isLoadingStops)
        .accessibilityIdentifier("search.here")
        .transition(.opacity)
    }

    /// Whenever there is a fix to go back to, and the map is not held on a stop being confirmed.
    private var showsRecenterButton: Bool { model.location.current != nil && !model.search.isConfirming }

    private var recenterButton: some View {
        Button {
            // Where the rider is now, not where they were when the screen opened: the stops around
            // them, looked up again, and framed even when the list comes back the same. Unless a
            // stop was tapped while the fix was coming: the map is then held on that stop.
            Task {
                await model.loadNearby(force: true, relocate: true)
                guard !model.search.isConfirming else { return }
                fit(aroundRider: true)
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17 * scale, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 44 * scale, height: 44 * scale)
                .background(Circle().fill(theme.background))
                .shadow(color: .black.opacity(0.18), radius: 6 * scale, y: 2 * scale)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to stops near you")
        .accessibilityIdentifier("search.recenter")
        .transition(.opacity)
    }
}
#endif
