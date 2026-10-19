import SwiftUI

#if !os(tvOS)
/// The head of the search drawer: whose stops are listed, and how many. It is also the strip the
/// drawer is dragged by, so it stays on screen at every height.
struct SearchListHeader: View {
    @Environment(\.theme) private var theme
    var model: SetupViewModel
    var scale: CGFloat

    var body: some View {
        HStack(alignment: .center) {
            Text(model.isShowingResults ? "RESULTS" : model.isAreaSearch ? "THIS AREA" : "NEARBY" as LocalizedStringKey)
                .busText(TypeStyles.sectionHeaderPhone, scale: scale)
                .foregroundStyle(theme.stopName)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !model.isShowingResults, !model.nearbyCaption.isEmpty {
                Text(model.nearbyCaption)
                    .busText(TypeStyles.countCaptionPhone, scale: scale)
                    .foregroundStyle(theme.dashCaption)
                    .shimmering(model.nearbyState == .locating)
            }
        }
        .frame(minHeight: 44, alignment: .center)
    }
}

/// What the search drawer lists: the stops around the rider (or the area they searched) with what
/// stands in for them while location is off or still coming, or the numbered results of what they
/// typed — and under either, whose data it is.
struct SearchListContent: View {
    @Environment(\.theme) private var theme
    var model: SetupViewModel
    var scale: CGFloat
    /// Room kept under the last line, for the home indicator or the keyboard over the drawer.
    var bottomInset: CGFloat
    /// A row tapped: the one way into the confirm step, shared with the map's pins.
    var onSelect: (NearbyStop) -> Void
    /// The denied card's way round: search by name instead.
    var onFocusField: () -> Void

    private var spacing: CGFloat { Spacing.nearbyRowGapPhone * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            searchTerms
            locationCard
            rows
            SetupServiceFooter(model: model, compact: true, scale: scale)
                .padding(.top, 14 * scale)
        }
        .padding(.horizontal, Spacing.sideInsetPhone * scale)
        .padding(.top, 4 * scale)
        .padding(.bottom, bottomInset + 20 * scale)
    }

    // MARK: Pieces

    /// What the rider has searched for before. Tapping one runs it again.
    @ViewBuilder private var searchTerms: some View {
        if !model.recentSearches.isEmpty && !model.isShowingResults {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8 * scale) {
                    ForEach(model.recentSearches, id: \.self) { term in
                        SearchTermChip(term: term, compact: true, scale: scale) {
                            model.search(for: term)
                        }
                    }
                }
            }
            .scrollClipDisabled()
            // The drawer turns its own scrolling off below its tallest height, and a nested
            // scroll view inherits that; the chips scroll sideways at any height.
            .scrollDisabled(false)
        }
    }

    /// Location off, or not asked for yet: said at the top of the list, where the stops would be.
    @ViewBuilder private var locationCard: some View {
        let state = model.nearbyState
        if !model.isShowingResults {
            if state == .denied || state == .restricted {
                LocationDeniedCard(isRestricted: state == .restricted, compact: true, scale: scale,
                                   onSearch: onFocusField)
            } else if state == .needsPermission && model.nearby.isEmpty {
                LocationPermissionCard(compact: true, scale: scale) {
                    Task { await model.loadNearby(force: true, askingPermission: true) }
                }
            }
        }
    }

    /// The stops, or their placeholders while the first of them are on the way. Stops already
    /// listed stay put while newer ones load, and shimmer to say they are about to change.
    @ViewBuilder private var rows: some View {
        if model.isShowingResults {
            resultRows
        } else if model.nearbyState == .needsPermission && model.nearby.isEmpty {
            // Still rows under the card: where the stops will be, once the rider allows it.
            StopListSkeleton(count: 3, compact: true, scale: scale, spacing: spacing, shimmers: false)
                .opacity(0.5)
        } else if model.nearby.isEmpty && isLoadingNearby {
            StopListSkeleton(count: 4, compact: true, scale: scale, spacing: spacing)
        } else {
            VStack(spacing: spacing) {
                ForEach(model.nearby) { entry in
                    NearbyStopRow(entry: entry, colorIndex: { model.colorIndex(for: $0) },
                                  compact: true, scale: scale) {
                        onSelect(entry)
                    }
                    .id(entry.id)
                }
            }
            // The rows are what the drawer's scroll position counts in, for BACK to scroll to.
            .scrollTargetLayout()
            .shimmering(isLoadingNearby)
        }
    }

    /// The results, numbered as their pins are. The list is the map's own (`mapStops`), so every
    /// row has a pin and every number means the same stop in both places.
    @ViewBuilder private var resultRows: some View {
        let stops = model.mapStops
        if stops.isEmpty && model.isSearching {
            StopListSkeleton(count: 4, compact: false, scale: scale, showsDistance: false, spacing: spacing)
        } else if stops.isEmpty {
            // A search that could not be made says why, rather than that no stop has the name.
            Text(model.searchFailureCaption ?? String(appLocalized: "NO STOPS MATCH"))
                .busText(TypeStyles.countCaptionPhone, scale: scale)
                .foregroundStyle(theme.dashCaption)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            VStack(spacing: spacing) {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, entry in
                    RecentStopRow(stop: entry.stop, compact: false, scale: scale, number: index + 1) {
                        onSelect(entry)
                    }
                    .id(entry.id)
                }
            }
            .scrollTargetLayout()
            .shimmering(model.isSearching)
        }
    }

    private var isLoadingNearby: Bool { model.isLoadingStops || model.nearbyState == .locating }
}
#endif

/// Whose stops these are, a way to switch where operators overlap (Hong Kong), and the credit
/// line the data's licence asks for. The region follows the rider's location, so this is the one
/// place that says which city the list is from.
struct SetupServiceFooter: View {
    @Environment(\.theme) private var theme
    var model: SetupViewModel
    var compact: Bool
    var scale: CGFloat

    var body: some View {
        let caption = compact ? TypeStyles.countCaptionPhone : TypeStyles.countCaption
        VStack(alignment: .leading, spacing: 6 * scale) {
            if let regionCaption = model.regionCaption {
                if let region = model.currentRegion, model.regionsHere.count > 1 {
                    Menu {
                        ForEach(model.regionsHere) { other in
                            Button(other.name) { Task { await model.switchRegion(to: other) } }
                        }
                    } label: {
                        HStack(spacing: 6 * scale) {
                            Text(regionCaption)
                                .busText(caption, scale: scale)
                            Image(systemName: "chevron.down")
                                .font(.system(size: caption.size(at: scale) * 0.9, weight: .bold))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(appLocalized: "Showing stops in \(region.name). Choose another operator"))
                } else {
                    Text(regionCaption)
                        .busText(caption, scale: scale)
                }
            }
            if let notice = model.serviceNotice {
                Text(notice)
                    .busText(caption, scale: scale)
                    .foregroundStyle(theme.late)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let attribution = model.attribution {
                Text(AttributedString(creditLine: attribution))
                    .busText(compact ? TypeStyles.creditLinePhone : TypeStyles.creditLine, scale: scale)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.dashCaption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AttributedString {
    /// A licence's credit line with any web address in it made tappable, for the licences that ask
    /// for a link (Transitous: its sources page).
    init(creditLine: String) {
        self.init(creditLine)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: creditLine, range: NSRange(creditLine.startIndex..., in: creditLine)) {
            guard let url = match.url, let range = Range(match.range, in: creditLine),
                  let lower = AttributedString.Index(range.lowerBound, within: self),
                  let upper = AttributedString.Index(range.upperBound, within: self) else { continue }
            self[lower..<upper].link = url
        }
    }
}
