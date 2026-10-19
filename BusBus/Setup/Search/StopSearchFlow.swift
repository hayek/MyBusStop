import SwiftUI

#if !os(tvOS)
/// The search screen as it is presented: the map search with its confirm step, and the chosen
/// stop's lines pushed over it, in one presentation of their own.
///
/// Choosing the lines is the last step of finding a stop, so it happens here rather than on the
/// app's own stack: the line picker's way back is to the confirm step exactly as it was left, the
/// same stop centred and the panel up, because the search screen beneath is the same view, never
/// rebuilt. SHOW THE MAP hands over to the board (`onConfirmLines`), and CANCEL on the search
/// screen still closes the lot.
struct StopSearchFlow: View {
    var model: SetupViewModel
    var onConfirmLines: () -> Void

    var body: some View {
        #if os(iOS)
        // A navigation stack, for the system's own way back: the bar's back button, and the swipe
        // from the leading edge.
        NavigationStack {
            StopSearchView(model: model)
                // The screen has its own header, with CANCEL in it.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: pickingLines) {
                    picker(onBack: nil)
                }
        }
        #else
        // On a Mac the search is a sheet, which has no window toolbar to hold a back button nor an
        // edge to swipe from, so the picker slides over the search screen with a BACK of its own,
        // Escape included. An overlay rather than a stack: a navigation stack, or even a ZStack,
        // around the search screen leaves XCTest finding no hit point on the list's rows, and
        // SearchFlowTests clicks them.
        StopSearchView(model: model)
            // Out of reach while the picker covers it, Tab and Space included, so nothing beneath
            // can be pressed again (SELECT STOP would clear the ticked lines). Not marked hidden
            // from accessibility even then: that modifier, whatever its value, costs XCTest its hit
            // points on the list's rows. The picker's modal trait keeps VoiceOver to it instead,
            // and a disabled control beneath does nothing if reached.
            .disabled(model.search.isPickingLines)
            .overlay {
                if model.search.isPickingLines {
                    picker(onBack: { model.backFromLines() })
                        .accessibilityAddTraits(.isModal)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.3), value: model.search.isPickingLines)
        #endif
    }

    private func picker(onBack: (() -> Void)?) -> some View {
        LinePickerView(model: model, onBack: onBack, onConfirm: onConfirmLines)
            // Captions built in code are only read again when rebuilt.
            .id(model.settings.language)
    }

    #if os(iOS)
    private var pickingLines: Binding<Bool> {
        Binding(get: { model.search.isPickingLines }, set: { if !$0 { model.backFromLines() } })
    }
    #endif
}
#endif
