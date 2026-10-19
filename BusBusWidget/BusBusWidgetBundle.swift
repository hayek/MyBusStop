import SwiftUI
import WidgetKit

@main struct BusBusWidgetBundle: WidgetBundle {
    init() {
        // The extension is its own process: the app's registration does not reach it.
        FontRegistrar.registerBundledFonts()
    }

    var body: some Widget {
        NextBusWidget()
    }
}
