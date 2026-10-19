import SwiftUI

/// One stop's board at watch scale: the header with its live dot, the next bus, THEN, and the
/// later buses there is room for, counting down every second while the app is in front.
struct StopBoardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// Made once per stop by `WatchBoardModels`, not here: this view is rebuilt with its parent.
    var model: WatchStopModel
    var store: WatchStore

    var body: some View {
        ScrollView {
            // Always On keeps the numeral, on the minute; the seconds are for a raised wrist.
            TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 60 : 1)) { context in
                board(model.entry(at: context.now, palette: store.palette, appearance: store.appearance))
            }
        }
        .background(theme.background)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
    }

    private func board(_ entry: NextBusEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(entry: entry, titleSize: 17, showsCode: false, showsLiveDot: !isLuminanceReduced,
                         titleLineLimit: 2)
            if let next = entry.arrivals.first {
                WidgetPrimaryReadout(entry: entry, arrival: next, metrics: .watch)
                if let then = entry.arrivals.dropFirst().first {
                    WidgetThenCard(entry: entry, arrival: then, style: .row, scale: 0.8)
                }
                ForEach(Array(entry.arrivals.dropFirst(2).prefix(WidgetLayout.largeLaterRows).enumerated()),
                        id: \.offset) { _, arrival in
                    WidgetArrivalRow(entry: entry, arrival: arrival)
                }
            } else if let message = WidgetMessage(entry) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.title)
                        .busText(TypeStyle(.archivoBlack, 20, tracking: -0.01))
                        .foregroundStyle(theme.primaryText)
                        .minimumScaleFactor(0.7)
                    detail(for: message)
                        .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.06))
                        .foregroundStyle(theme.dashCaption)
                }
            }
            if let attribution = model.provider?.attribution {
                Text(verbatim: attribution)
                    .busText(TypeStyles.creditLinePhone)
                    .foregroundStyle(theme.dashCaption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 4)
    }

    /// The widget's words, reworded where the watch knows more: whether it may ask at all, and
    /// whether it just tried and failed.
    private func detail(for message: WidgetMessage) -> Text {
        guard message == .expired else { return Text(message.detail) }
        switch model.expiredDetail {
        case .connecting: return Text(verbatim: LiveState.connecting.label)
        case .cantReachFeed: return Text("CAN'T REACH THE FEED")
        case .openOnIPhone: return Text("OPEN MY BUS STOP ON YOUR IPHONE")
        }
    }
}
