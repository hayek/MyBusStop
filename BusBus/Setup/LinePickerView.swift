import SwiftUI

/// One line in the grid. Unselected it is an outline in the line's colour; selected it fills with
/// that colour and takes a check. Past three, the rest simply stop responding — never an error.
struct LineChipView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Resolved here rather than taken from the environment: this screen is presented on its
    /// own, and a screen that relies on an ancestor for its colours renders dark in silence.
    private var theme: Theme { Theme.resolve(colorScheme) }
    var line: TransitLine
    var colorIndex: Int
    var isSelected: Bool
    var isMuted: Bool
    var compact: Bool
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(line.shortName)
                        .busText(compact ? TypeStyles.chipNumberPhone : TypeStyles.chipNumber, scale: scale)
                        .foregroundStyle(isSelected ? theme.numeral(on: colorIndex) : theme.rail(colorIndex))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    if isSelected { checkMark }
                }
                Spacer(minLength: 0)
                Text(line.destinationLabel ?? "")
                    .busText(compact ? TypeStyles.chipDestinationPhone : TypeStyles.chipDestination, scale: scale)
                    .foregroundStyle(isSelected ? theme.numeral(on: colorIndex) : theme.stopName)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding((compact ? 12 : 18) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: (compact ? Spacing.chipHeightPhone : Spacing.chipHeight) * scale)
            .background(RoundedRectangle(cornerRadius: (compact ? Radius.chip : Radius.row) * scale, style: .continuous)
                .fill(isSelected ? theme.rail(colorIndex) : theme.chipUnselected))
            .overlay(RoundedRectangle(cornerRadius: (compact ? Radius.chip : Radius.row) * scale, style: .continuous)
                .strokeBorder(theme.rail(colorIndex), lineWidth: Stroke.chipBorder * scale))
        }
        .buttonStyle(.plain)
        .opacity(isMuted ? 0.3 : 1)
        .disabled(isMuted)
        .accessibilityLabel(line.destinationLabel.map { "Line \(line.shortName) to \($0)" } ?? "Line \(line.shortName)" as LocalizedStringKey)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var checkMark: some View {
        let side = (compact ? 24.0 : 30.0) * scale
        // The artboard's 15 × 12 glyph, centred in its circle.
        return Path { path in
            path.move(to: CGPoint(x: side * 0.30, y: side * 0.50))
            path.addLine(to: CGPoint(x: side * 0.433, y: side * 0.633))
            path.addLine(to: CGPoint(x: side * 0.70, y: side * 0.35))
        }
        .stroke(theme.primaryText, style: StrokeStyle(lineWidth: Stroke.check * scale,
                                                      lineCap: .round, lineJoin: .round))
        .frame(width: side, height: side)
        .background(Circle().fill(theme.background))
        .accessibilityHidden(true)
    }
}

/// Step 2: up to three lines, and the hard cap is the design.
struct LinePickerView: View {
    @Environment(\.theme) private var theme
    var model: SetupViewModel
    /// The board's sheet says what its button does there: the map is already behind it.
    var confirmTitle: LocalizedStringKey = "SHOW THE MAP"
    /// Shown as a sheet over the board, it has a way to leave without changing anything.
    var onClose: (() -> Void)?
    /// Pushed inside search where the system draws no back button (a Mac's sheet): BACK to the
    /// stop it was asked about, Escape included.
    var onBack: (() -> Void)?
    var onConfirm: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = BoardLayout.resolve(size: proxy.size, lineCount: 3)
            let compact = layout.mode == .phone
            let columns = compact ? 3 : (layout.mode == .pad ? 4 : 6)
            let gap = (compact ? Spacing.setupGridGapPhone : Spacing.setupGridGap) * layout.scale

            VStack(alignment: .leading, spacing: 0) {
                header(layout: layout, compact: compact)
                ScrollView {
                    let grid = Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
                    Group {
                        if model.isLoadingLines && model.linesAtStop.isEmpty {
                            // One sweep across the whole grid, not one per chip.
                            LazyVGrid(columns: grid, spacing: gap) {
                                ForEach(0..<columns * 2, id: \.self) { index in
                                    LineChipSkeleton(compact: compact, scale: layout.scale,
                                                     destinationFraction: [0.8, 0.6, 0.7, 0.5][index % 4])
                                }
                            }
                            .shimmering()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Loading lines"))
                        } else {
                            LazyVGrid(columns: grid, spacing: gap) {
                                ForEach(model.linesAtStop, id: \.id) { line in
                                    LineChipView(line: line, colorIndex: model.colorIndex(for: line),
                                                 isSelected: model.isSelected(line),
                                                 isMuted: model.isFull && !model.isSelected(line),
                                                 compact: compact, scale: layout.scale) {
                                        model.toggle(line)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, (compact ? 22 : 34) * layout.scale)
                }
                footer(layout: layout, compact: compact)
            }
            .padding(.horizontal, compact ? 20 * layout.scale : layout.sideInset)
            .padding(.top, compact ? 22 * layout.scale : layout.sideInset)
            .padding(.bottom, compact ? 24 * layout.scale : layout.sideInset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        .analyticsScreen("line_picker")
    }

    private func header(layout: BoardLayout, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 12 * layout.scale) {
            if let onBack {
                backButton(layout: layout, compact: compact, action: onBack)
            }
            titles(layout: layout, compact: compact)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: (compact ? 17 : 20) * layout.scale, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -10)
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityLabel(Text("Dismiss"))
            }
        }
    }

    /// The search confirm step's own BACK, in the same outline, so the way back reads as the same
    /// step undone.
    private func backButton(layout: BoardLayout, compact: Bool, action: @escaping () -> Void) -> some View {
        let height = (compact ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * layout.scale * 0.8
        return Button(action: action) {
            HStack(spacing: 6 * layout.scale) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14 * layout.scale, weight: .heavy))
                    .accessibilityHidden(true)
                Text("BACK")
                    .busText(compact ? TypeStyles.clearButtonPhone : TypeStyles.clearButton, scale: layout.scale)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 16 * layout.scale)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Radius.button * layout.scale, style: .continuous)
                .strokeBorder(theme.clearButtonBorder, lineWidth: Stroke.cardOutline * layout.scale))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .keyboardShortcut(.cancelAction)
        #endif
        .accessibilityIdentifier("lines.back")
    }

    private func titles(layout: BoardLayout, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: (compact ? 4 : 6) * layout.scale) {
            Text(model.chosenStop?.name ?? "")
                .busText(compact ? TypeStyles.setupTitleLinePhone : TypeStyles.setupTitle, scale: layout.scale)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("PICK UP TO 3 LINES TO WATCH")
                .busText(compact ? TypeStyles.pickerSubtitlePhone : TypeStyles.pickerSubtitle, scale: layout.scale)
                .foregroundStyle(theme.stopName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func footer(layout: BoardLayout, compact: Bool) -> some View {
        let height = (compact ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * layout.scale
        let counts = VStack(alignment: .leading, spacing: 8 * layout.scale) {
            Text(model.footerCount)
                .busText(compact ? TypeStyles.footerCountPhone : TypeStyles.footerCount, scale: layout.scale)
                .foregroundStyle(theme.primaryText)
            Text(model.footerHint)
                .busText(compact ? TypeStyles.footerHintPhone : TypeStyles.footerHint, scale: layout.scale)
                .foregroundStyle(theme.stopName)
        }
        let buttons = HStack(spacing: (compact ? 12 : 16) * layout.scale) {
            Button { model.clearSelection() } label: {
                Text("CLEAR")
                    .busText(compact ? TypeStyles.clearButtonPhone : TypeStyles.clearButton, scale: layout.scale)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: compact ? .infinity : nil)
                    .padding(.horizontal, compact ? 0 : 28 * layout.scale)
                    .frame(width: compact ? 104 * layout.scale : nil, height: height)
                    .background(RoundedRectangle(cornerRadius: Radius.button * layout.scale, style: .continuous)
                        .strokeBorder(theme.clearButtonBorder, lineWidth: Stroke.cardOutline * layout.scale))
            }
            .buttonStyle(.plain)

            Button(action: onConfirm) {
                HStack(spacing: 12 * layout.scale) {
                    Text(confirmTitle)
                        .busText(compact ? TypeStyles.primaryButtonPhone : TypeStyles.primaryButton, scale: layout.scale)
                    ArrowGlyph(scale: layout.scale)
                }
                .foregroundStyle(theme.primaryButtonText)
                .frame(maxWidth: compact ? .infinity : nil)
                .padding(.horizontal, compact ? 0 : 36 * layout.scale)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: Radius.button * layout.scale, style: .continuous)
                    .fill(theme.primaryButtonFill))
            }
            .buttonStyle(.plain)
            .disabled(!model.canConfirm)
            .opacity(model.canConfirm ? 1 : 0.4)
            #if !os(tvOS)
            .keyboardShortcut(.defaultAction)
            #endif
        }

        if compact {
            VStack(alignment: .leading, spacing: 16 * layout.scale) { counts; buttons }
                .padding(.top, 16 * layout.scale)
        } else {
            HStack(alignment: .center) { counts; Spacer(); buttons }
                .padding(.top, 20 * layout.scale)
        }
    }
}

struct ArrowGlyph: View {
    @Environment(\.theme) private var theme
    var scale: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 8 * scale))
            path.addLine(to: CGPoint(x: 22 * scale, y: 8 * scale))
            path.move(to: CGPoint(x: 14 * scale, y: 0))
            path.addLine(to: CGPoint(x: 22 * scale, y: 8 * scale))
            path.addLine(to: CGPoint(x: 14 * scale, y: 16 * scale))
        }
        .stroke(theme.primaryButtonText, style: StrokeStyle(lineWidth: Stroke.chevron * scale,
                                                            lineCap: .round, lineJoin: .round))
        .frame(width: 22 * scale, height: 16 * scale)
        .flipsForRightToLeftLayoutDirection(true)
        .accessibilityHidden(true)
    }
}
