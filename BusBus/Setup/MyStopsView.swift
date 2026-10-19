import SwiftUI

#if !os(tvOS)
/// The home: the rider's saved stops, and the way to find another.
///
/// A rider who comes back opens a stop they keep, so those come first and open in one tap — they
/// were confirmed once already. Finding a new stop wants the map big, so it happens on a screen of
/// its own: the search bar here only looks like a field, and opens that screen. Landscape is the
/// same one column, centred; there is nothing left to put in a second.
struct MyStopsView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Resolved here rather than taken from the environment: this screen is presented on its
    /// own, and a screen that relies on an ancestor for its colours renders dark in silence.
    private var theme: Theme { Theme.resolve(colorScheme) }
    var model: SetupViewModel
    var onOpenSettings: () -> Void
    /// Nil hides the feedback bubble: a build without a feedback token has nowhere to send it.
    var onOpenFeedback: (() -> Void)? = nil
    /// A saved stop already knows its lines, so it goes straight to its board.
    var onResume: (SavedSetup) -> Void
    /// The stop whose card the ⓘ beside its row opened.
    @State private var inspectedStop: StopCardRequest?

    /// The column a wide window centres, at scale 1: a phone's rows, given room to breathe.
    private static let columnWidth: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            let layout = BoardLayout.resolve(size: proxy.size, lineCount: 3)
            let compact = layout.mode == .phone
            ScrollView {
                content(compact: compact, scale: layout.scale)
                    .padding(.horizontal, (compact ? Spacing.sideInsetPhone : Spacing.sideInsetPad) * layout.scale)
                    .padding(.top, (compact ? 22 : 36) * layout.scale)
                    .padding(.bottom, 24 * layout.scale)
                    .frame(maxWidth: compact ? .infinity : Self.columnWidth * layout.scale)
                    // At least the screen's height, so the region caption sits at its foot when
                    // there are only a few stops above it.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .swipeRowsContainer()
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        .sheet(item: $inspectedStop) { request in
            StopCardView(request: request, settings: model.settings)
                .busTheme()
        }
        // The last stop swiped away mid-edit leaves no EDIT to tap; the next one saved should not
        // arrive already in edit mode.
        .onChange(of: model.history.isEmpty) { _, isEmpty in
            if isEmpty { model.isEditingHistory = false }
        }
        .analyticsScreen("my_stops")
    }

    private func content(compact: Bool, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: isWelcome ? .top : .center) {
                title(compact: compact, scale: scale)
                Spacer(minLength: 8 * scale)
                trailingControls(compact: compact, scale: scale)
            }
            searchBar(compact: compact, scale: scale)
                .padding(.top, (compact ? 18 : 22) * scale)

            Group {
                if model.history.isEmpty {
                    findFirstCard(compact: compact, scale: scale)
                } else {
                    VStack(spacing: (compact ? Spacing.nearbyRowGapPhone : Spacing.nearbyRowGap) * scale) {
                        historyRows(compact: compact, scale: scale)
                        addStopRow(compact: compact, scale: scale)
                    }
                }
            }
            .padding(.top, (compact ? 22 : 28) * scale)

            Spacer(minLength: (compact ? 24 : 28) * scale)
            footer(compact: compact, scale: scale)
        }
    }

    // MARK: Header

    /// A rider who has not been asked for their location yet, and has no stop saved, is opening
    /// the app for the first time: they are welcomed with a question rather than a label. One who
    /// came through the welcome story has been welcomed already. A staged screenshot never asks.
    private var isWelcome: Bool {
        model.location.needsPermission && ScreenshotMode.current == nil
            && model.history.isEmpty && model.settings.onboarding == .welcome
    }

    @ViewBuilder private func title(compact: Bool, scale: CGFloat) -> some View {
        if isWelcome {
            VStack(alignment: .leading, spacing: (compact ? 8 : 10) * scale) {
                Text("WELCOME")
                    .busText(compact ? TypeStyles.sectionHeaderPhone : TypeStyles.sectionHeader, scale: scale)
                    .foregroundStyle(theme.stopName)
                Text("Where do you catch the bus?")
                    .busText(compact ? TypeStyles.welcomeTitlePhone : TypeStyles.welcomeTitle, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            Text("MY STOPS")
                .busText(compact ? TypeStyles.setupTitlePhone : TypeStyles.setupTitle, scale: scale)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// EDIT, the feedback bubble and the gear. EDIT turns the rows into a list you can pin and
    /// prune rather than one you open stops from; with nothing saved there is nothing to edit.
    @ViewBuilder private func trailingControls(compact: Bool, scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !model.history.isEmpty {
                Button { model.isEditingHistory.toggle() } label: {
                    Text(model.isEditingHistory ? "DONE" : "EDIT" as LocalizedStringKey)
                        .busText(compact ? TypeStyles.countCaptionPhone : TypeStyles.countCaption, scale: scale)
                        .foregroundStyle(model.isEditingHistory ? theme.primaryText : theme.stopName)
                        .padding(.horizontal, 8 * scale)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isEditingHistory ? "Finish editing my stops" : "Edit my stops" as LocalizedStringKey)
            }
            // Set in the title's own size and weight: beside the one heading, they are the only
            // other things the eye should find.
            if let onOpenFeedback {
                FeedbackBubbleButton(size: glyphSize(compact: compact, scale: scale),
                                     weight: .black, color: theme.primaryText, action: onOpenFeedback)
            }
            #if DEBUG
            SettingsGearButton(size: glyphSize(compact: compact, scale: scale),
                               weight: .black, color: theme.primaryText, action: onOpenSettings)
            #endif
        }
    }

    /// A symbol's drawn glyph is smaller than its point size, so it is set a touch above the
    /// title's to read as the same height beside it.
    private func glyphSize(compact: Bool, scale: CGFloat) -> CGFloat {
        let title = compact ? TypeStyles.setupTitlePhone : TypeStyles.setupTitle
        return title.size(at: scale) * 0.92
    }

    /// Drawn as the search field, but a button: there is nothing to type into here, and the field
    /// that takes the typing is the search screen's. It opens on the map, keyboard down.
    private func searchBar(compact: Bool, scale: CGFloat) -> some View {
        Button { model.openSearch() } label: {
            HStack(spacing: 0) {
                MagnifierGlyph(size: (compact ? 20 : 24) * scale)
                    .padding(.leading, (compact ? 20 : 26) * scale)
                    .padding(.trailing, (compact ? 10 : 14) * scale)
                Text("Search stop or line")
                    .busText(compact ? TypeStyles.searchInputPhone : TypeStyles.searchInput, scale: scale)
                    .foregroundStyle(theme.stopName)
                    .lineLimit(1)
                Spacer(minLength: 24 * scale)
            }
            .searchFieldChrome(compact: compact, scale: scale)
            .contentShape(RoundedRectangle(cornerRadius: (compact ? Radius.chip : Radius.searchField) * scale,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search stops or lines")
        .accessibilityIdentifier("home.search")
    }

    // MARK: Saved stops

    /// All of them, not a first few: this is the whole screen now. A row can be swiped away on its
    /// own, as well as pruned under EDIT.
    private func historyRows(compact: Bool, scale: CGFloat) -> some View {
        ForEach(model.history) { setup in
            HStack(spacing: 4 * scale) {
                HistorySetupRow(setup: setup, colorIndex: { model.colorIndex(for: $0) },
                                compact: compact, scale: scale,
                                isEditing: model.isEditingHistory,
                                onUse: { onResume(setup) },
                                onTogglePin: { model.togglePin(setup) },
                                onRemove: { model.remove(setup) })
                // Beside the row rather than inside it: the row is one button that opens the stop,
                // and a button inside another is a tap that goes to whichever SwiftUI prefers.
                if !model.isEditingHistory {
                    StopInfoButton(stopName: setup.stop.name, scale: scale) {
                        inspectedStop = StopCardRequest(stop: setup.stop,
                                                        providerID: setup.providerID ?? model.settings.providerID,
                                                        watched: setup.lines)
                    }
                }
            }
            .swipeToRemove { model.remove(setup) }
        }
    }

    /// Another way into search, where the eye lands after the last stop. Dashed, as a place for a
    /// stop that is not there yet.
    private func addStopRow(compact: Bool, scale: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: (compact ? Radius.phoneRow : Radius.row) * scale, style: .continuous)
        return Button { model.openSearch() } label: {
            HStack(spacing: 10 * scale) {
                Image(systemName: "plus")
                    .font(.system(size: (compact ? 15 : 18) * scale, weight: .heavy))
                    .accessibilityHidden(true)
                Text("ADD A STOP")
                    .busText(compact ? TypeStyles.sectionHeaderPhone : TypeStyles.sectionHeader, scale: scale)
            }
            .foregroundStyle(theme.stopName)
            .frame(maxWidth: .infinity)
            .frame(height: (compact ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * scale)
            .overlay(shape.strokeBorder(theme.cardOutline,
                                        style: StrokeStyle(lineWidth: Stroke.cardOutline * scale,
                                                           dash: [6 * scale, 5 * scale])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.addStop")
    }

    /// Nothing saved yet — a first launch, or every stop removed: one card in the rows' place that
    /// says how a stop is found, and opens search to find it.
    private func findFirstCard(compact: Bool, scale: CGFloat) -> some View {
        Button { model.openSearch() } label: {
            HStack(alignment: .center, spacing: (compact ? 14 : 18) * scale) {
                PinGlyph(size: (compact ? 30 : 36) * scale)
                VStack(alignment: .leading, spacing: (compact ? 6 : 8) * scale) {
                    Text("Find your first stop")
                        .busText(compact ? TypeStyles.permissionTitlePhone : TypeStyles.permissionTitle, scale: scale)
                        .foregroundStyle(theme.primaryText)
                    Text("Search by name, or look around you on the map")
                        .busText(compact ? TypeStyles.permissionBodyPhone : TypeStyles.permissionBody, scale: scale)
                        .foregroundStyle(theme.secondaryText)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: (compact ? 15 : 18) * scale, weight: .bold))
                    .foregroundStyle(theme.stopName)
                    .accessibilityHidden(true)
            }
            .padding((compact ? 22 : 28) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowBackground(radius: Radius.readoutCard * scale, scale: scale))
            .contentShape(RoundedRectangle(cornerRadius: Radius.readoutCard * scale, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.findFirst")
    }

    // MARK: Footer

    /// Whose stops these are. The operator switch, service notice and credit line sit in the
    /// search screen's drawer instead, beside the stops they are about.
    @ViewBuilder private func footer(compact: Bool, scale: CGFloat) -> some View {
        if let caption = model.regionCaption {
            Text(caption)
                .busText(compact ? TypeStyles.countCaptionPhone : TypeStyles.countCaption, scale: scale)
                .foregroundStyle(theme.dashCaption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
/// The mock provider, with the given stops already saved.
@MainActor private func previewModel(savingStops count: Int) async -> SetupViewModel {
    let suite = "MyStopsView.preview.\(count)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    let settings = SettingsStore(defaults: defaults)
    settings.providerOverride = MockTransitProvider()
    let model = SetupViewModel(settings: settings)
    let stops = (try? await settings.provider.searchStops(query: "a")) ?? []
    for stop in stops.prefix(count) {
        let lines = (try? await settings.provider.lines(atStop: stop)) ?? []
        settings.apply(stop: stop, lines: Array(lines.prefix(2)), providerID: settings.providerID)
    }
    return model
}

private struct MyStopsPreview: View {
    var count: Int
    @State private var model: SetupViewModel?

    var body: some View {
        Group {
            if let model { MyStopsView(model: model, onOpenSettings: {}, onResume: { _ in }) }
        }
        .task { model = await previewModel(savingStops: count) }
    }
}

#Preview("Saved stops") { MyStopsPreview(count: 4) }
#Preview("Nothing saved") { MyStopsPreview(count: 0) }
#endif
#endif
