#if os(tvOS)
import SwiftUI

/// Step 2 on the TV: up to three of the stop's lines, then the board. A line is a focusable tile
/// that toggles; once three are chosen the rest wait until one is let go, as on the phone.
struct TVLinePickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: SetupViewModel
    var onConfirm: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 40)]

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let stop = model.chosenStop {
                    Text(stop.name)
                        .busText(TypeStyles.titleLandscape, scale: 1.6)
                        .foregroundStyle(theme.primaryText)
                }
                Text(verbatim: "\(model.footerCount) · \(model.footerHint)")
                    .busText(TypeStyles.kicker, scale: 1.6)
                    .foregroundStyle(theme.secondaryText)

                if model.isLoadingLines {
                    ProgressView()
                } else if let error = model.loadError, model.linesAtStop.isEmpty {
                    Text(verbatim: error).foregroundStyle(theme.stale)
                    Button("Try again") {
                        if let stop = model.chosenStop { Task { await model.choose(stop) } }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                        ForEach(model.linesAtStop, id: \.id) { line in
                            let selected = model.isSelected(line)
                            Button { model.toggle(line) } label: {
                                TVLineTile(line: line, colorIndex: model.colorIndex(for: line), isSelected: selected)
                            }
                            .buttonStyle(.card)
                            .disabled(model.isFull && !selected)
                        }
                    }
                }

                Button(action: onConfirm) {
                    Text("Show board")
                        .padding(.horizontal, 40)
                }
                .disabled(!model.canConfirm)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        .analyticsScreen("tv_line_picker")
    }
}

private struct TVLineTile: View {
    @Environment(\.theme) private var theme
    var line: TransitLine
    var colorIndex: Int
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LineBadgeView(number: line.shortName, colorIndex: colorIndex, side: 64, cornerRadius: 14,
                              numeralSize: 30, ring: nil, dimmed: !isSelected)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                    .accessibilityHidden(true)
            }
            if let destination = line.destinationLabel, !destination.isEmpty {
                Text(destination)
                    .busText(TypeStyles.kicker)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(24)
        .frame(width: 220, height: 170, alignment: .topLeading)
        .background(theme.card)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
