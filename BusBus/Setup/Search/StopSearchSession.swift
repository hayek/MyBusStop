import Foundation
import CoreGraphics

/// How much of the map the search drawer covers.
nonisolated enum DrawerHeight: Hashable, Sendable { case small, medium, large }

/// The map's framing, kept to put it back after the confirm step.
nonisolated struct SavedCamera: Hashable, Sendable {
    var center: GeoPoint
    var distance: Double
}

/// What BACK puts back: the confirm step moves the map and the drawer out of the way, and the rider
/// expects to find the list exactly where they left it.
nonisolated struct SearchRestore: Hashable, Sendable {
    var drawer: DrawerHeight
    var scrolledToStopID: String?
    var camera: SavedCamera?
}

/// The search screen's own state, apart from what it finds: how tall the drawer is, and whether
/// the rider is confirming a stop. Kept as a plain value so the rules can be tested without a view.
nonisolated struct StopSearchSession: Hashable, Sendable {
    var isPresented = false
    var drawer: DrawerHeight = .medium
    /// The keyboard comes up as the screen opens (the welcome's "search by name" only).
    var focusesFieldOnOpen = false
    /// Set while confirming; it is both the mark of the confirm step and what BACK hands back.
    private(set) var restore: SearchRestore?
    /// SELECT STOP pushed the stop's lines over the confirm step, inside this screen. Set back by
    /// the line picker's back button, which leaves the confirm step as it was.
    var isPickingLines = false

    var isConfirming: Bool { restore != nil }

    /// Every opening starts fresh: the drawer at its resting height, and the keyboard only when asked.
    mutating func open(focusingField: Bool) {
        isPresented = true
        drawer = .medium
        focusesFieldOnOpen = focusingField
        restore = nil
        isPickingLines = false
    }

    /// The screen starts to go. What it shows is left as it is until it has gone (`dismissed`), so
    /// a confirm panel leaving with SELECT STOP or CANCEL goes down as itself rather than turning
    /// back into the drawer on its way out.
    mutating func close() {
        isPresented = false
        focusesFieldOnOpen = false
    }

    /// The screen is gone: the confirm step goes with it, and the lines pushed over it.
    mutating func dismissed() {
        restore = nil
        isPickingLines = false
    }

    /// The first letter typed pulls the drawer up to show the results, and clearing the field lets
    /// it settle again. Only those two moments: a rider who pulls the drawer down to see the map
    /// while typing keeps it there through the next letters. Not during the confirm step either:
    /// the panel there is not the list, and must stay where it is.
    mutating func queryChanged(wasEmpty: Bool, isEmpty: Bool) {
        guard !isConfirming, wasEmpty != isEmpty else { return }
        drawer = isEmpty ? .medium : .large
    }

    mutating func beginConfirm(_ restore: SearchRestore) {
        self.restore = restore
    }

    /// Hands back what was there before the confirm step, or nil when there was no confirm step.
    mutating func back() -> SearchRestore? {
        guard let restore else { return nil }
        self.restore = nil
        drawer = restore.drawer
        return restore
    }

    /// Beside the map rather than over it, when the window is wide enough to spare the room: a
    /// landscape phone is wide but short, and a narrow iPad window has no room to spare.
    static func usesSidePanel(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= 600
    }

    /// The tallest the confirm panel grows under the map, for a stop with many lines: a little more
    /// than the drawer's resting height, never past its tallest, so the stop it is about still has
    /// a good band of map to be centred in above it.
    static func confirmPanelMaxHeight(_ heights: DrawerHeights) -> CGFloat {
        min(heights.large, max(heights.medium, (heights.large + DrawerHeights.mapPeek) * 0.6))
    }

    /// The widest view, in metres, the confirm step shows its stop in: a stop picked from a whole
    /// city is brought down to its streets, and one picked at street level keeps the rider's zoom.
    static let confirmSpanMeters: Double = 1_500

    /// How far the rider is from the stop, or -1 when the rider's whereabouts are unknown. With a
    /// fix, the list's own figure when it has one, else measured (a search result carries none).
    /// Without one there is nothing to say: an area search with location off measures its rows
    /// from the middle of the map, and a walk from there would be a walk from nowhere.
    static func distance(to entry: NearbyStop, from rider: GeoPoint?) -> Double {
        guard let rider else { return -1 }
        if entry.distanceMeters >= 0 { return entry.distanceMeters }
        return rider.distance(to: entry.stop.location)
    }

    /// The code printed on the stop's sign, when the provider's id is one: short, letters and
    /// digits. Many providers key stops on long internal ids ("NSR:Quay:7203") that no sign
    /// carries, and those would only be noise under the stop's name.
    static func signCode(_ code: String) -> String? {
        guard (1...8).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              code.contains(where: \.isNumber) else { return nil }
        return code
    }

    /// "90 M · 2 MIN WALK". Nothing when the distance is unknown (a search result carries none, and
    /// without the rider's location there is nothing to measure from): "-1 M" would be worse than silence.
    static func walkCaption(meters: Double) -> String? {
        guard meters >= 0 else { return nil }
        // A brisk 80 metres a minute, and never "0 MIN" for a stop in sight.
        let minutes = max(1, Int((meters / 80).rounded(.up)))
        return "\(DistanceFormatter.text(meters)) · \(String(appLocalized: "\(minutes) MIN WALK"))"
    }
}
