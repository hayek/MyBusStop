import SwiftUI

/// Every line at the board's stop, the watched ones already ticked: more, fewer or others without
/// going back through the stop list. The same grid as setup's step 2, so the cap of three holds
/// here too.
struct BoardLinesSheet: View {
    var model: BoardViewModel
    @State private var setup: SetupViewModel
    @Environment(\.dismiss) private var dismiss

    init(model: BoardViewModel) {
        self.model = model
        _setup = State(initialValue: SetupViewModel(settings: model.settings))
    }

    var body: some View {
        LinePickerView(model: setup, confirmTitle: "DONE", onClose: { dismiss() }) {
            let before = model.lines.map(\.id)
            setup.confirm()
            // The same lines in the same order is the same board: nothing to clear and refetch.
            if model.lines.map(\.id) != before { model.configurationChanged() }
            dismiss()
        }
        .task {
            guard let stop = model.stop else { return }
            await setup.edit(stop, watching: model.lines)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
