import Foundation

/// A real city for the mock's routes to stand in, so each language's App Store screenshots show
/// stops its riders know: the fixtures' placeholder names (MapFixtures) become that city's own
/// stops, the stop codes look like real ones, and the routes are laid out around its map.
///
/// Off unless the app is launched with `-screenshotPlace <key>`, which `scripts/screenshots.sh`
/// picks for each language. The places, and which language uses which, are in
/// ScreenshotPlaces.json, which the script reads too for where to put the simulator.
nonisolated struct MockPlace: Sendable, Decodable {
    /// The city as its riders write it, shown under a stop's name.
    var city: String
    var lat: Double
    var lon: Double
    /// The language the names are written in, for setting them in capitals.
    var language: String
    /// Placeholder name → the real stop's.
    var names: [String: String]

    static let current: MockPlace? = {
        guard let key = UserDefaults.standard.string(forKey: "screenshotPlace"),
              let url = Bundle.main.url(forResource: "ScreenshotPlaces", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.places[key]
    }()

    private struct File: Decodable {
        var places: [String: MockPlace]
    }

    var anchor: GeoPoint { GeoPoint(lat: lat, lon: lon) }

    /// The real stop's name, in capitals like the fixtures' (a script without case keeps its own).
    func name(for placeholder: String) -> String {
        guard let name = names[placeholder] else { return placeholder }
        return name.uppercased(with: Locale(identifier: language))
    }

    /// A five-digit code standing in for the fixture's, the same on every run.
    static func code(for fixtureCode: String) -> String {
        let hash = fixtureCode.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        return String(10_000 + hash % 90_000)
    }

    /// The fixture's code behind one `code(for:)` made.
    static func fixtureCode(for code: String) -> String {
        guard current != nil else { return code }
        return MockScenario.allCases.lazy.flatMap(\.lines).flatMap(\.stops)
            .first { Self.code(for: $0.code) == code }?.code ?? code
    }
}
