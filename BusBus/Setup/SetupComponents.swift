import SwiftUI

/// A row or chip's ground.
///
/// Light mode is one continuous cream field with no panels on it, so a filled card would be
/// invisible there. It becomes a rule instead, exactly as the readout's THEN card does.
struct RowBackground: View {
    @Environment(\.theme) private var theme
    var radius: CGFloat
    var scale: CGFloat
    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        if theme.isLight {
            shape.strokeBorder(theme.cardOutline, lineWidth: Stroke.cardOutline * scale)
        } else {
            shape.fill(theme.card)
        }
    }
}

/// The search field. A real `TextField` with a real label, so it works with a keyboard, with
/// VoiceOver and on a Mac.
struct SearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    /// Lets the screen put the keyboard up by itself (the welcome story's search by name).
    var focus: FocusState<Bool>.Binding
    var scale: CGFloat
    /// A clear (×) button while there is text: on the search screen the rider types, clears and
    /// types again without leaving the field.
    var clears = false

    private var showsClear: Bool { clears && !text.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            MagnifierGlyph(size: 20 * scale)
                .padding(.leading, 20 * scale)
                .padding(.trailing, 10 * scale)
            TextField("Search stop or line", text: $text)
                .busText(TypeStyles.searchInputPhone, scale: scale)
                .foregroundStyle(theme.primaryText)
                .textFieldStyle(.plain)
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                // On the field itself rather than the row around it, which would hand the same
                // label to the clear button.
                .accessibilityLabel("Search stops or lines")
                .accessibilityIdentifier("search.field")
                .padding(.trailing, showsClear ? 4 * scale : 24 * scale)
            if showsClear {
                Button { text = "" } label: {
                    CloseGlyph(scale: scale * 0.75)
                        .frame(width: 26 * scale, height: 26 * scale)
                        .background(Circle().fill(theme.closeButton))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8 * scale)
                .accessibilityLabel("CLEAR")
            }
        }
        .searchFieldChrome(compact: true, scale: scale)
    }
}

extension View {
    /// The search field's box: its height, ground and border. The home's search bar wears it too —
    /// a button that opens the search screen, drawn as the field it leads to so the two read as
    /// one control.
    func searchFieldChrome(compact: Bool, scale: CGFloat) -> some View {
        modifier(SearchFieldChrome(compact: compact, scale: scale))
    }
}

private struct SearchFieldChrome: ViewModifier {
    @Environment(\.theme) private var theme
    var compact: Bool
    var scale: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: (compact ? Radius.chip : Radius.searchField) * scale,
                                     style: .continuous)
        content
            .frame(height: (compact ? Spacing.searchHeightPhone : Spacing.searchHeight) * scale)
            .background(shape.fill(theme.card))
            .overlay(shape.strokeBorder(theme.searchBorder, lineWidth: Stroke.searchBorder * scale))
    }
}

struct MagnifierGlyph: View {
    @Environment(\.theme) private var theme
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.stopName, lineWidth: size * 0.108)
                .frame(width: size * 0.625, height: size * 0.625)
                .offset(x: -size * 0.06, y: -size * 0.06)
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: size * 0.21, y: size * 0.21))
            }
            .stroke(theme.stopName, style: StrokeStyle(lineWidth: size * 0.108, lineCap: .round))
            .frame(width: size * 0.21, height: size * 0.21)
            .offset(x: size * 0.22, y: size * 0.22)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A stop in the NEARBY list: how far, what it is called, and which lines call there — capped at
/// three badges plus a count, because the row has to stay scannable.
struct NearbyStopRow: View {
    @Environment(\.theme) private var theme
    var entry: NearbyStop
    var colorIndex: (TransitLine) -> Int
    var compact: Bool
    var scale: CGFloat
    var action: () -> Void

    private var shownLines: [TransitLine] { Array(entry.lines.prefix(3)) }
    private var overflow: Int { max(0, entry.lines.count - 3) }

    var body: some View {
        Button(action: action) {
            // The name is what the rider reads, so badges give way to the count before the name
            // is squeezed: "Tai Po Market Station" beside K12, K17, K18 would otherwise be "TA…".
            ViewThatFits(in: .horizontal) {
                content(badges: 3)
                content(badges: 2)
                content(badges: 1)
                // Past that the name shrinks rather than losing the last badge: a row of "+3"
                // says nothing about which lines stop there.
                content(badges: 1, shrinkingName: true)
            }
            .padding(.horizontal, (compact ? 16 : 24) * scale)
            .frame(height: (compact ? Spacing.nearbyRowHeightPhone : Spacing.nearbyRowHeight) * scale)
            .frame(maxWidth: .infinity)
            .background(RowBackground(radius: (compact ? Radius.phoneRow : Radius.row) * scale, scale: scale))
            // In light mode the row's ground is an outline, and a `Spacer` is nothing at all, so
            // without this only the glyphs and the border itself would answer a tap.
            .contentShape(RoundedRectangle(cornerRadius: (compact ? Radius.phoneRow : Radius.row) * scale,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func content(badges: Int, shrinkingName: Bool = false) -> some View {
        let shown = entry.lines.prefix(badges)
        let hidden = entry.lines.count - shown.count
        return HStack(spacing: (compact ? 12 : 22) * scale) {
            Text(DistanceFormatter.text(entry.distanceMeters))
                .busText(compact ? TypeStyles.distanceChipPhone : TypeStyles.distanceChip, scale: scale)
                .foregroundStyle(theme.rail(1))
                .frame(width: (compact ? 52 : 76) * scale, alignment: .leading)
            VStack(alignment: .leading, spacing: (compact ? 2 : 4) * scale) {
                Text(entry.stop.name)
                    .busText(compact ? TypeStyles.nearbyNamePhone : TypeStyles.nearbyName, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(shrinkingName ? 0.7 : 1)
                StopAddressLine(stop: entry.stop, compact: compact, scale: scale)
            }
            Spacer(minLength: 8 * scale)
            ForEach(shown, id: \.id) { line in
                LineBadgeView(number: line.shortName, colorIndex: colorIndex(line),
                              side: (compact ? 30 : 38) * scale,
                              cornerRadius: (compact ? 8 : 10) * scale,
                              numeralSize: (compact ? 15 : 18) * scale, ring: nil)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .busText(compact ? TypeStyles.overflowCountPhone : TypeStyles.overflowCount, scale: scale)
                    .foregroundStyle(theme.stopName)
                    .fixedSize()
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [entry.stop.name, DistanceFormatter.accessibleText(entry.distanceMeters)]
        if !entry.lines.isEmpty {
            let names = shownLines.map(\.shortName).joined(separator: ", ")
            parts.append(overflow > 0 ? String(appLocalized: "lines \(names) and \(overflow) more")
                                      : String(appLocalized: "lines \(names)"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Opens a stop's card — its lines, address and map — without choosing it.
struct StopInfoButton: View {
    @Environment(\.theme) private var theme
    var stopName: String
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(stopName)")
    }
}

/// Opens a line's card — its route on a map and its stops — beside a row that lists the line.
struct LineInfoButton: View {
    @Environment(\.theme) private var theme
    var lineNumber: String
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About line \(lineNumber)")
    }
}

/// A stop chosen before. No distance, no badges — you already know this one.
struct RecentStopRow: View {
    @Environment(\.theme) private var theme
    var stop: TransitStop
    var compact: Bool
    var scale: CGFloat
    /// A search result's place in the list, drawn at the leading edge to match its numbered pin.
    var number: Int? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: (compact ? 12 : 18) * scale) {
                if let number { numberBadge(number) }
                VStack(alignment: .leading, spacing: (compact ? 2 : 4) * scale) {
                    Text(stop.name)
                        .busText(compact ? TypeStyles.recentNamePhone : TypeStyles.recentName, scale: scale)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    StopAddressLine(stop: stop, compact: compact, scale: scale)
                }
            }
            .padding(.horizontal, (compact ? 16 : 24) * scale)
            .frame(height: (compact ? 56 : Spacing.nearbyRowHeight) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowBackground(radius: (compact ? Radius.chip : Radius.row) * scale, scale: scale))
            .contentShape(RoundedRectangle(cornerRadius: (compact ? Radius.chip : Radius.row) * scale,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The same mark as the result's pin (`StopPin`), so row and pin read as one stop.
    private func numberBadge(_ number: Int) -> some View {
        let side = (compact ? 30 : 38) * scale
        return Text(number, format: .number)
            .busText(TypeStyles.badgeNumeral((compact ? 15 : 18) * scale))
            .foregroundStyle(theme.primaryButtonText)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, side * 0.1)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.3, style: .continuous).fill(theme.primaryButtonFill))
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        guard let number else { return String(appLocalized: "Recent stop, \(stop.name)") }
        return "\(String(appLocalized: "Stop \(number)")), \(stop.name)"
    }
}

/// A term the rider has searched for before. Tapping it runs that search again.
struct SearchTermChip: View {
    @Environment(\.theme) private var theme
    var term: String
    var compact: Bool
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(term)
                .busText(compact ? TypeStyles.recentNamePhone : TypeStyles.recentName, scale: scale)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, (compact ? 14 : 18) * scale)
                .frame(height: (compact ? 40 : 48) * scale)
                .background(ChipBackground(scale: scale))
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search again for \(term)")
    }
}

/// A stop the rider has watched, with the lines they watched there. Tapping it goes straight back
/// to that board — the lines are already chosen, so there is nothing to pick.
struct HistorySetupRow: View {
    @Environment(\.theme) private var theme
    var setup: SavedSetup
    var colorIndex: (TransitLine) -> Int
    var compact: Bool
    var scale: CGFloat
    var isEditing: Bool
    var onUse: () -> Void
    var onTogglePin: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: (compact ? 10 : 14) * scale) {
            Button(action: onUse) {
                HStack(spacing: (compact ? 12 : 22) * scale) {
                    if setup.pinned && !isEditing {
                        Image(systemName: "pin.fill")
                            .font(.system(size: (compact ? 12 : 14) * scale, weight: .bold))
                            .foregroundStyle(theme.stopName)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: (compact ? 2 : 4) * scale) {
                        Text(setup.stop.name)
                            .busText(compact ? TypeStyles.nearbyNamePhone : TypeStyles.nearbyName, scale: scale)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        StopAddressLine(stop: setup.stop, compact: compact, scale: scale)
                    }
                    Spacer(minLength: 8 * scale)
                    ForEach(setup.lines, id: \.id) { line in
                        LineBadgeView(number: line.shortName, colorIndex: colorIndex(line),
                                      side: (compact ? 30 : 38) * scale,
                                      cornerRadius: (compact ? 8 : 10) * scale,
                                      numeralSize: (compact ? 15 : 18) * scale, ring: nil)
                    }
                }
                .padding(.horizontal, (compact ? 16 : 24) * scale)
                .frame(height: (compact ? Spacing.nearbyRowHeightPhone : Spacing.nearbyRowHeight) * scale)
                .frame(maxWidth: .infinity)
                .background(RowBackground(radius: (compact ? Radius.phoneRow : Radius.row) * scale, scale: scale))
                .contentShape(RoundedRectangle(cornerRadius: (compact ? Radius.phoneRow : Radius.row) * scale,
                                               style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isEditing)
            .accessibilityLabel(accessibilityLabel)

            if isEditing {
                Button(action: onTogglePin) {
                    Image(systemName: setup.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 17 * scale, weight: .bold))
                        .foregroundStyle(setup.pinned ? theme.primaryText : theme.stopName)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(setup.pinned ? "Unpin \(setup.stop.name)" : "Pin \(setup.stop.name)" as LocalizedStringKey)

                Button(action: onRemove) {
                    CloseGlyph(scale: scale)
                        .frame(width: 34 * scale, height: 34 * scale)
                        .background(Circle().fill(theme.closeButton))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(setup.stop.name)")
            }
        }
    }

    private var accessibilityLabel: String {
        let lines = setup.lines.map(\.shortName).joined(separator: ", ")
        return setup.pinned ? String(appLocalized: "\(setup.stop.name), pinned, lines \(lines)")
                            : String(appLocalized: "\(setup.stop.name), lines \(lines)")
    }
}


extension View {
    /// Swiping a saved stop away removes it, without going through EDIT first. A full swipe does
    /// it in one go. The TV has no swipe, and keeps EDIT for this.
    func swipeToRemove(_ remove: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        swipeActions {
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
            }
        }
        #endif
    }

    /// Outside a `List`, rows only swipe inside a scroll view marked as holding them.
    func swipeRowsContainer() -> some View {
        #if os(tvOS)
        self
        #else
        swipeActionsContainer()
        #endif
    }
}

/// The capsule equivalent of `RowBackground`.
struct ChipBackground: View {
    @Environment(\.theme) private var theme
    var scale: CGFloat

    var body: some View {
        if theme.isLight {
            Capsule().strokeBorder(theme.cardOutline, lineWidth: Stroke.cardOutline * scale)
        } else {
            Capsule().fill(theme.card)
        }
    }
}

/// Stands in the NEARBY list until the rider has been asked for their location: what allowing it
/// gets them, and the one button that asks. The system prompt is never shown before this tap.
struct LocationPermissionCard: View {
    @Environment(\.theme) private var theme
    var compact: Bool
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: (compact ? 14 : 18) * scale) {
                PinGlyph(size: (compact ? 30 : 36) * scale)
                Text("See stops within 500 m")
                    .busText(compact ? TypeStyles.permissionTitlePhone : TypeStyles.permissionTitle, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only used to find the stops around you, and only while BusBus is open.")
                .busText(compact ? TypeStyles.permissionBodyPhone : TypeStyles.permissionBody, scale: scale)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, (compact ? 12 : 14) * scale)
            Button(action: action) {
                Text("CONTINUE")
                    .busText(compact ? TypeStyles.primaryButtonPhone : TypeStyles.primaryButton, scale: scale)
                    .foregroundStyle(theme.numeral(on: 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: (compact ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * scale)
                    .background(RoundedRectangle(cornerRadius: (compact ? Radius.phoneButton : Radius.button) * scale,
                                                 style: .continuous).fill(theme.rail(1)))
                    .contentShape(RoundedRectangle(cornerRadius: (compact ? Radius.phoneButton : Radius.button) * scale,
                                                   style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, (compact ? 18 : 22) * scale)
        }
        .padding((compact ? 22 : 28) * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RowBackground(radius: Radius.readoutCard * scale, scale: scale))
    }
}

/// Stands in the NEARBY list when location is off, in place of `LocationPermissionCard`: why the
/// list is empty, the way to turn it back on, and the way round it. It says so once, calmly, and
/// never asks again by itself — the rider already answered.
///
/// A rider who turned location off can turn it on again, so the card sends them to the one place
/// that does it. When the device's owner turned it off (Screen Time, or a school's or employer's
/// management) that place is a switch the rider cannot move, so the card only offers search.
struct LocationDeniedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    var isRestricted: Bool
    var compact: Bool
    var scale: CGFloat
    /// Puts the keyboard on the search field, the other way to find a stop.
    var onSearch: () -> Void

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (compact ? Radius.phoneButton : Radius.button) * scale, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: (compact ? 14 : 18) * scale) {
                PinGlyph(size: (compact ? 30 : 36) * scale, color: theme.stopName, slashGap: theme.card)
                Text("Location is off")
                    .busText(compact ? TypeStyles.permissionTitlePhone : TypeStyles.permissionTitle, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(isRestricted
                 ? "Location is turned off on this device, so the stops around you can't be listed."
                 : "Turn it on to list the stops around you. It's only used to find them, and never stored." as LocalizedStringKey)
                .busText(compact ? TypeStyles.permissionBodyPhone : TypeStyles.permissionBody, scale: scale)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, (compact ? 12 : 14) * scale)
            if !isRestricted, let url = LocationService.settingsURL {
                openSettingsButton(url)
                    .padding(.top, (compact ? 18 : 22) * scale)
            }
            Button(action: onSearch) {
                Text("Search by name instead")
                    .busText(compact ? TypeStyles.permissionBodyPhone : TypeStyles.permissionBody, scale: scale)
                    .foregroundStyle(theme.captionText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, (isRestricted ? (compact ? 14 : 18) : (compact ? 6 : 8)) * scale)
        }
        .padding(.horizontal, (compact ? 22 : 28) * scale)
        .padding(.top, (compact ? 22 : 28) * scale)
        // The link's 44 pt target already carries air under its words; the full padding would
        // double it.
        .padding(.bottom, (compact ? 12 : 16) * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RowBackground(radius: Radius.readoutCard * scale, scale: scale))
    }

    /// The same yellow button as CONTINUE on `LocationPermissionCard`, with the mark for leaving the app: this one opens
    /// Settings rather than answering here. At least its fixed height, and taller rather than
    /// clipped when Dynamic Type makes the words wrap.
    private func openSettingsButton(_ url: URL) -> some View {
        let style = compact ? TypeStyles.primaryButtonPhone : TypeStyles.primaryButton
        return Button { openURL(url) } label: {
            HStack(spacing: (compact ? 10 : 12) * scale) {
                Text("OPEN SETTINGS")
                    .busText(style, scale: scale)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: style.size(at: scale) * 0.9, weight: .black))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.numeral(on: 1))
            .padding(.vertical, 10 * scale)
            .frame(maxWidth: .infinity)
            .frame(minHeight: (compact ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * scale)
            .background(buttonShape.fill(theme.rail(1)))
            .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings, where you can turn on location for this app.")
    }
}

/// A map pin drawn in outline, in the button's yellow unless told otherwise: a round head narrowing
/// to a point, with a hole in the head. Given `slashGap`, it is struck through for location that is
/// off, the slash cut out of the pin in that colour (the ground it sits on) so the two read apart.
struct PinGlyph: View {
    @Environment(\.theme) private var theme
    var size: CGFloat
    var color: Color?
    var slashGap: Color?

    var body: some View {
        let line = size * 0.09
        let color = color ?? theme.rail(1)
        ZStack {
            Path { path in
                let width = size * 0.66
                let radius = width / 2
                let center = CGPoint(x: size / 2, y: line / 2 + radius)
                let tip = CGPoint(x: size / 2, y: size - line / 2)
                // The sides leave the head at 40° below its equator and meet at the tip.
                let angle = Angle.degrees(40)
                path.addArc(center: center, radius: radius, startAngle: angle,
                            endAngle: .degrees(180) - angle, clockwise: true)
                path.addQuadCurve(to: tip, control: CGPoint(x: size / 2 - radius * 0.35, y: center.y + radius * 1.05))
                path.addQuadCurve(to: CGPoint(x: center.x + radius * cos(angle.radians),
                                              y: center.y + radius * sin(angle.radians)),
                                  control: CGPoint(x: size / 2 + radius * 0.35, y: center.y + radius * 1.05))
                path.closeSubpath()
            }
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            Circle()
                .strokeBorder(color, lineWidth: line)
                .frame(width: size * 0.3, height: size * 0.3)
                .position(x: size / 2, y: line / 2 + size * 0.33)
            if let slashGap {
                let slash = Path { path in
                    path.move(to: CGPoint(x: size * 0.1, y: size * 0.08))
                    path.addLine(to: CGPoint(x: size * 0.9, y: size * 0.92))
                }
                slash.stroke(slashGap, style: StrokeStyle(lineWidth: line * 3, lineCap: .round))
                slash.stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
