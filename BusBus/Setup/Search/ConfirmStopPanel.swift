import SwiftUI

#if !os(tvOS)
/// The confirm step's panel, in the drawer's place: the stop a tap picked out, said in full, the
/// lines that call there, and the two ways on — BACK to the list as it was, or SELECT STOP to go
/// on to choosing which of those lines to watch.
///
/// A tap on a small pin or a long list is easy to get wrong, so nothing is chosen until the rider
/// has seen the stop's name, where it is and which lines call there — each with where it goes, as
/// the line number alone rarely says which stop across the road this is.
struct ConfirmStopPanel: View {
    @Environment(\.theme) private var theme
    var entry: NearbyStop
    var linesState: SetupViewModel.ConfirmLines
    /// What to say when the lines could not be looked up.
    var failureCaption: String?
    /// Off for a stop known to have no lines: there is nothing to choose from.
    var canSelect = true
    var colorIndex: (TransitLine) -> Int
    /// "90 M · 2 MIN WALK", or nil when there is nothing to measure from.
    var walkCaption: String?
    var scale: CGFloat
    /// Beside the map rather than under it: the buttons go to the panel's foot, under the thumb.
    var fillsHeight = false
    /// Kept clear under the buttons, for the home indicator.
    var bottomInset: CGFloat = 0
    /// Off while the line picker is pushed over the panel: its Escape and Return are the picker's.
    var allowsShortcuts = true
    var onBack: () -> Void
    var onSelect: () -> Void
    /// The ⓘ beside a line: its card, with its route. Nil leaves the rows without one.
    var onAboutLine: ((TransitLine) -> Void)? = nil
    /// Whether a line gets the ⓘ: only where its route can be drawn.
    var hasCard: (TransitLine) -> Bool = { _ in true }

    @AccessibilityFocusState private var nameFocused: Bool
    @State private var lookedUpAddress: String?
    /// The stop `lookedUpAddress` was found for. Back from the line picker the panel appears
    /// again and its task runs again for the same stop; the address found is kept, rather than
    /// blanked and looked up a second time.
    @State private var lookedUpStopID: String?
    /// The rows' own height, so the list is drawn no taller than they are and scrolls only once
    /// the panel's room runs out.
    @State private var rowsHeight: CGFloat?

    private var badgeSide: CGFloat { 30 * scale }
    private var rowGap: CGFloat { 10 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            Text(entry.stop.name)
                .busText(TypeStyles.setupTitleLinePhone, scale: scale)
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8 * scale)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($nameFocused)
            whereabouts
                .padding(.top, 4 * scale)
            linesArea
                .padding(.top, 14 * scale)
                .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
            buttons
                .padding(.top, 16 * scale)
        }
        .padding(.horizontal, Spacing.sideInsetPhone * scale)
        .padding(.top, 20 * scale)
        .padding(.bottom, max(bottomInset, 12 * scale) + 8 * scale)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .task(id: entry.stop.id) {
            guard lookedUpStopID != entry.stop.id else { return }
            lookedUpAddress = nil
            guard StopAddresses.needsLookup(entry.stop) else { return }
            lookedUpAddress = await StopAddresses.shared.address(for: entry.stop)
            if !Task.isCancelled { lookedUpStopID = entry.stop.id }
        }
        .task {
            // The list the rider was moving through has gone: VoiceOver starts again here, on the
            // stop it is asking about. Focus is moved a beat after the screen change, which would
            // otherwise put VoiceOver back on the panel's first element.
            AccessibilityNotification.ScreenChanged(nil).post()
            try? await Task.sleep(for: .milliseconds(150))
            nameFocused = true
        }
        .analyticsScreen("stop_confirm")
    }

    // MARK: Pieces

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
            Text("THIS STOP?")
                .busText(TypeStyles.sectionHeaderPhone, scale: scale)
                .foregroundStyle(theme.stopName)
            Spacer(minLength: 0)
            if let walkCaption {
                Text(walkCaption)
                    .busText(TypeStyles.countCaptionPhone, scale: scale)
                    .foregroundStyle(theme.rail(1))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Where the stop stands, and the code on its sign when it has a short one: two stops of the
    /// same name across a road differ only there.
    private var whereabouts: some View {
        let address = StopAddresses.text(for: entry.stop, lookedUp: lookedUpAddress)
        let code = StopSearchSession.signCode(entry.stop.code)
        return HStack(spacing: 10 * scale) {
            Text(address ?? " ")
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHidden(address == nil)
            if let code {
                Text("STOP \(code)")
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .busText(TypeStyles.stopAddressPhone, scale: scale)
        .foregroundStyle(theme.dashCaption)
        .accessibilityElement(children: .combine)
    }

    /// The lines that call here, one row each, in whatever room the panel has between the address
    /// and the buttons: the list scrolls when there are more than fit, and the buttons stay put.
    /// The loading shimmer and the captions for no lines, or no answer, stand in the same place.
    @ViewBuilder private var linesArea: some View {
        switch linesState {
        case .loading:
            VStack(alignment: .leading, spacing: rowGap) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12 * scale) {
                        SkeletonBlock(width: badgeSide, height: badgeSide, radius: 8 * scale)
                        SkeletonBlock(width: [150, 110, 130][index] * scale, height: 12 * scale, radius: 4 * scale)
                    }
                }
            }
            .shimmering()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading lines"))
        case .lines(let lines):
            ScrollView {
                VStack(alignment: .leading, spacing: onAboutLine == nil ? rowGap : 0) {
                    ForEach(lines, id: \.id) { line in
                        row(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            // Beside the map the list has the whole column to fill. Under it, the list is as tall
            // as its rows, up to what the panel's cap leaves (an estimate until they are measured).
            .frame(maxHeight: fillsHeight ? .infinity
                                          : rowsHeight ?? CGFloat(lines.count) * (badgeSide + rowGap))
        case .noLines:
            linesCaption(String(appLocalized: "NO LINES STOP HERE"))
        case .failed:
            linesCaption(failureCaption ?? "")
        }
    }

    /// The badge, as on the board, and where the line goes — or comes from, when a feed only
    /// names the headsign. Read-only: choosing which to watch is the line picker's. The ⓘ at its
    /// end opens the line's card; with it the rows are its 44 points tall, with no gap between.
    private func row(_ line: TransitLine) -> some View {
        let destination = line.destinationLabel
        return HStack(spacing: 12 * scale) {
            HStack(spacing: 12 * scale) {
                LineBadgeView(number: line.shortName, colorIndex: colorIndex(line), side: badgeSide,
                              cornerRadius: 8 * scale, numeralSize: 15 * scale, ring: nil)
                Text(destination ?? "")
                    .busText(TypeStyles.confirmLinePhone, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(destination.map { "Line \(line.shortName) to \($0)" } ?? "Line \(line.shortName)" as LocalizedStringKey)
            if let onAboutLine, hasCard(line) {
                LineInfoButton(lineNumber: line.shortName, scale: scale) { onAboutLine(line) }
                    // Out to the panel's edge, where the glyph lines up with the buttons below.
                    .padding(.trailing, -12 * scale)
            } else if onAboutLine != nil {
                // The rows keep the ⓘ's height, so a line without one sits like the rest.
                Color.clear.frame(width: 1, height: 44)
            }
        }
    }

    /// A caption in the lines' place, as tall as one row so the panel keeps its shape.
    private func linesCaption(_ text: String) -> some View {
        Text(text)
            .busText(TypeStyles.countCaptionPhone, scale: scale)
            .foregroundStyle(theme.stopName)
            .frame(minHeight: badgeSide, alignment: .leading)
    }

    /// BACK takes a third, SELECT STOP the rest: the way on is the larger target, the way back
    /// still an easy one.
    private var buttons: some View {
        let height = Spacing.buttonHeightPhone * scale
        let gap = 12 * scale
        return GeometryReader { proxy in
            let third = max(0, (proxy.size.width - gap) / 3)
            HStack(spacing: gap) {
                backButton(height: height)
                    .frame(width: third)
                selectButton(height: height)
                    .frame(width: third * 2)
            }
        }
        .frame(height: height)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.phoneButton * scale, style: .continuous)
    }

    private func backButton(height: CGFloat) -> some View {
        Button(action: onBack) {
            HStack(spacing: 6 * scale) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14 * scale, weight: .heavy))
                    .accessibilityHidden(true)
                Text("BACK")
                    .busText(TypeStyles.clearButtonPhone, scale: scale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8 * scale)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(buttonShape.strokeBorder(theme.clearButtonBorder, lineWidth: Stroke.cardOutline * scale))
            .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        // Escape on a Mac, the way out of anything that asks.
        .keyboardShortcut(allowsShortcuts ? .cancelAction : nil)
        .accessibilityIdentifier("confirm.back")
    }

    private func selectButton(height: CGFloat) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 10 * scale) {
                Text("SELECT STOP")
                    .busText(TypeStyles.primaryButtonPhone, scale: scale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 16 * scale, weight: .black))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.primaryButtonText)
            .padding(.horizontal, 10 * scale)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(buttonShape.fill(theme.primaryButtonFill))
            .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        // Dimmed as the line picker's own SHOW THE MAP is with nothing chosen; VoiceOver hears it
        // as unavailable, and why.
        .disabled(!canSelect)
        .opacity(canSelect ? 1 : 0.4)
        .accessibilityHint(canSelect ? Text(verbatim: "") : Text("NO LINES STOP HERE"))
        .keyboardShortcut(allowsShortcuts ? .defaultAction : nil)
        .accessibilityIdentifier("confirm.select")
    }
}

#if DEBUG
#Preview("Confirm") {
    let lines = ["7", "18", "41", "63", "104"].map { TransitLine(id: $0, shortName: $0, destination: "DEPOT") }
    let entry = NearbyStop(stop: TransitStop(code: "41122", name: "Dizengoff Center", city: "Tel Aviv",
                                             location: GeoPoint(lat: 32.075, lon: 34.775),
                                             address: "Dizengoff 50"),
                           distanceMeters: 90, lines: lines)
    VStack {
        Spacer()
        ConfirmStopPanel(entry: entry, linesState: .lines(lines), colorIndex: { Int($0.id) ?? 0 },
                         walkCaption: StopSearchSession.walkCaption(meters: 90), scale: 1, bottomInset: 34,
                         onBack: {}, onSelect: {})
    }
    .background(Theme.dark.background)
    .busTheme()
}

#Preview("No lines") {
    let entry = NearbyStop(stop: TransitStop(code: "41489", name: "Industrial Zone", city: "Tel Aviv",
                                             location: GeoPoint(lat: 32.075, lon: 34.775)),
                           distanceMeters: 90, lines: [])
    VStack {
        Spacer()
        ConfirmStopPanel(entry: entry, linesState: .noLines, canSelect: false, colorIndex: { _ in 0 },
                         walkCaption: StopSearchSession.walkCaption(meters: 90), scale: 1, bottomInset: 34,
                         onBack: {}, onSelect: {})
    }
    .background(Theme.dark.background)
    .busTheme()
}
#endif
#endif
