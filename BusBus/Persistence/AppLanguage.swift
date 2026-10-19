import SwiftUI

/// The language the app speaks. Nil follows the device, the way every app does; a choice in
/// Settings overrides it for BusBus alone and takes effect at once, without a relaunch.
///
/// Two lookups have to agree. SwiftUI resolves `Text` against the `locale` in its environment,
/// which the root sets from here. Strings built in code are resolved with `String(appLocalized:)`,
/// which carries the same locale explicitly, because `String(localized:)` only ever reads the
/// bundle's launch-time language.
nonisolated enum AppLanguage {
    static let defaultsKey = "settings.language"

    /// Everything the string catalog is translated into, English first.
    static let supported = ["en", "am", "ar", "cs", "de", "es", "et", "eu", "fi", "fil", "fr", "he", "hi",
                            "hmn-Latn", "hu", "it", "ja", "ko", "lt", "nb", "nl", "nn", "pa", "pl", "pt-BR",
                            "pt-PT", "ro", "ru", "sl", "so", "sv", "tr", "vi", "zh-Hans", "zh-Hant"]

    /// The chosen language code, or nil to follow the device. Read from the standard defaults so a
    /// string built anywhere, on any thread, agrees with what Settings shows.
    static var override: String? {
        if let pinned { return pinned }
        #if BUSBUS_WIDGET
        // The widget has no Settings of its own: it speaks whatever the app was set to.
        return AppGroup.defaults.string(forKey: SharedKeys.language).flatMap { supported.contains($0) ? $0 : nil }
        #else
        return UserDefaults.standard.string(forKey: defaultsKey).flatMap { supported.contains($0) ? $0 : nil }
        #endif
    }

    /// A language fixed for the current task, ahead of the one chosen in Settings. The tests run
    /// inside the app, so without it they read whatever language was last picked on that device.
    @TaskLocal static var pinned: String?

    static var locale: Locale { override.map(Locale.init(identifier:)) ?? .current }

    static func set(_ code: String?, in defaults: UserDefaults) {
        defaults.set(code, forKey: defaultsKey)
        // The same key iOS writes for a per-app language in the Settings app, so the next launch
        // starts in the chosen language too, down to the system's own location prompt.
        if let code { defaults.set([code], forKey: "AppleLanguages") } else { defaults.removeObject(forKey: "AppleLanguages") }
    }

    /// Each language named in itself — "עברית", "日本語" — so a rider who cannot read the current
    /// language can still find their own.
    static func name(of code: String) -> String {
        // The system has no name for Hmong in itself in the Latin script, so it would say
        // "Hmong (Latin)" to the Hmong reader looking for "Hmoob".
        if code == "hmn-Latn" { return "Hmoob" }
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    static func layoutDirection(for code: String) -> LayoutDirection {
        Locale.Language(identifier: code).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

extension String {
    /// `String(localized:)` in the language chosen in Settings.
    nonisolated init(appLocalized resource: LocalizedStringResource) {
        var resource = resource
        resource.locale = AppLanguage.locale
        self.init(localized: resource)
    }
}
