import Foundation

/// What the app and its widget call the widget, so the app can ask WidgetKit to redraw it.
nonisolated enum WidgetKind {
    static let nextBus = "com.hayek.BusBus.NextBus"
}

/// The URL a widget opens the app with: `busbus://setup?id=<SavedSetup.id>` for a stop from the
/// history, `busbus://open` for anything else.
nonisolated enum WidgetDeepLink {
    static let scheme = "busbus"

    static func url(for setup: SavedSetup?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        if let setup {
            components.host = "setup"
            // URLComponents percent-encodes the value, the "|" that joins the id's parts included.
            components.queryItems = [URLQueryItem(name: "id", value: setup.id)]
        } else {
            components.host = "open"
        }
        return components.url ?? URL(string: "\(scheme)://open")!
    }

    /// The saved setup a widget link names, or nil for any other link.
    static func setupID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "setup",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
