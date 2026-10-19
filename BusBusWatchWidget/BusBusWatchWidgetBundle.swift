import SwiftUI
import WidgetKit

@main struct BusBusWatchWidgetBundle: WidgetBundle {
    // The extension's own process and bundle: the app's registration does not reach it.
    init() { FontRegistrar.registerBundledFonts() }
    var body: some Widget { WatchNextBusWidget() }
}
