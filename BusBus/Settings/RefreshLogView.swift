#if DEBUG
import SwiftUI

/// Debug screen: every refresh of the board, newest first — what set it off, and for each line
/// what the feed returned against what the board showed.
struct RefreshLogView: View {
    var log: RefreshLog = .shared

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text(verbatim: "No refreshes yet. Open a board and they appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: entry.at.formatted(RefreshLog.stamp))
                        Text(verbatim: entry.trigger.label).bold()
                        Spacer()
                        Text(verbatim: RefreshLog.summary(entry))
                            .foregroundStyle(color(for: entry.outcome))
                    }
                    Text(verbatim: "\(entry.stop) · \(entry.provider)")
                        .foregroundStyle(.secondary)
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: RefreshLog.describe(line))
                            .foregroundStyle(line.error != nil || line.shown == 0 ? .red : .primary)
                    }
                }
                .font(.caption.monospaced())
                // Nothing to select with on Apple TV.
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
            }
        }
        .navigationTitle(Text(verbatim: "Refresh log"))
        .toolbar {
            #if !os(tvOS)
            ToolbarItem {
                ShareLink(item: log.text)
                    .disabled(log.entries.isEmpty)
            }
            #endif
            ToolbarItem {
                Button(role: .destructive) { log.clear() } label: { Text(verbatim: "Clear") }
                    .disabled(log.entries.isEmpty)
            }
        }
    }

    private func color(for outcome: RefreshLogEntry.Outcome) -> Color {
        switch outcome {
        case .updated: .green
        case .failed: .red
        case .skipped, .joined: .orange
        }
    }
}
#endif
