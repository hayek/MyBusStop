import Foundation

/// Parses the Israel MOT GTFS `route_long_name`, shared by bus.gov.il and Stride:
/// "השיטה/מגרשי טניס-נשר<->ת. מרכזית חוף הכרמל/הורדה-חיפה-2#"
///  origin stop - origin city <-> destination stop - destination city - direction+alternative
/// Stop or city names that contain "-" themselves can split wrongly; good enough for display.
nonisolated struct IsraelRouteLongName: Sendable {
    var origin: String?
    var destination: String?

    init(_ longName: String) {
        let parts = longName.components(separatedBy: "<->")
        guard parts.count == 2 else { return }
        origin = Self.place(parts[0])
        let destination = parts[1].replacingOccurrences(of: #"-[0-9]+[^-]*$"#, with: "", options: .regularExpression)
        self.destination = Self.place(destination)
    }

    /// "stop-city" → "stop, city"
    private static func place(_ text: String) -> String {
        guard let dash = text.lastIndex(of: "-") else { return text }
        let stop = text[..<dash].trimmingCharacters(in: .whitespaces)
        let city = text[text.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        return city.isEmpty ? stop : "\(stop), \(city)"
    }
}
