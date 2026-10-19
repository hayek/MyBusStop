import SwiftUI

/// Everything the watch app's views read from the environment, set on each screen's content
/// inside the navigation stack (never on the stack, whose system chrome follows the watch's own
/// language): the appearance and language chosen on the iPhone. `WidgetEnvironment`'s two lines,
/// without the widget container a WidgetKit view needs and an app's must not have.
struct WatchEnvironment: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var inheritedLocale
    @Environment(\.layoutDirection) private var inheritedDirection
    var store: WatchStore

    func body(content: Content) -> some View {
        let appearance = store.appearance
        // Read from the store so a sync redraws; `AppLanguage.override` reads the same key.
        let language = store.language.flatMap { _ in AppLanguage.override }
        content
            // Captions built in code are rebuilt when the language changes, as `RootView` does.
            .id(language)
            .environment(\.theme, Theme.resolve(appearance.colorScheme ?? colorScheme))
            .environment(\.widgetIsMonochrome, false)
            .environment(\.locale, language.map(Locale.init(identifier:)) ?? inheritedLocale)
            .environment(\.layoutDirection, language.map(AppLanguage.layoutDirection(for:)) ?? inheritedDirection)
            .preferredColorScheme(appearance.colorScheme)
    }
}
