import SwiftUI

/// The board is drawn for a dark room by default, but it is an app as well as a wall display, so
/// it follows whatever the device is set to unless the rider says otherwise.
nonisolated enum Appearance: String, CaseIterable, Codable, Sendable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: String(appLocalized: "System")
        case .dark: String(appLocalized: "Dark")
        case .light: String(appLocalized: "Light")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
