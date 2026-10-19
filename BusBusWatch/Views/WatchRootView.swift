import SwiftUI

/// The stop list, with the rider's default stop already pushed on the first frame — the phone's
/// rule that a board that exists is what opens — and a complication's stop when one is tapped.
struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    var store: WatchStore
    @State private var path: [String]
    @State private var boards = WatchBoardModels()

    init(store: WatchStore) {
        self.store = store
        // Staged, the stop list stays in front when it is what the screenshot is of.
        let opensBoard = WatchScreenshotStage.current?.screen != .stops
        _path = State(initialValue: [opensBoard ? HistoryLookup.defaultEntry(in: store.history)?.id : nil].compactMap { $0 })
    }

    var body: some View {
        // The iPhone's language and colours go on each screen's content, not on the stack: the
        // system's own chrome (the back button, the clock) follows the watch's language, and would
        // collide with a stack flipped to the other direction. It also keeps `path` outside the
        // environment's `.id(language)`, so a language sync leaves the rider on their board.
        NavigationStack(path: $path) {
            StopListView(store: store)
                .modifier(WatchEnvironment(store: store))
                .navigationDestination(for: String.self) { id in
                    if let setup = store.setup(id: id) {
                        // One model per stop: a different id is a different board.
                        StopBoardView(model: boards.model(for: setup), store: store)
                            .modifier(WatchEnvironment(store: store))
                            .id(id)
                    }
                }
        }
        .onChange(of: path) { _, path in boards.keep(only: path) }
        .onOpenURL { url in
            if let id = WidgetDeepLink.setupID(from: url), store.setup(id: id) != nil { path = [id] }
        }
        .onChange(of: store.history) { _, _ in
            // A stop removed on the phone leaves its board.
            path.removeAll { store.setup(id: $0) == nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reload() }
        }
    }
}
