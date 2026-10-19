import Foundation
import CoreGraphics

// Input types for MapLayoutEngine. Nothing here knows about SwiftUI or about the
// transit provider layer — BoardViewModel adapts RoutePattern/TrackedBus into these,
// which keeps the engine testable with plain string fixtures.

nonisolated enum MapAxis: Hashable, Sendable {
    case horizontal   // travel runs left → right (landscape)
    case vertical     // travel runs top → bottom (portrait)
}

/// Which artboard's numbers apply. Chosen by `BoardLayout`, never by the engine.
nonisolated enum MapSizePreset: Hashable, Sendable {
    case landscape        // Main / Merge / BusDetail / MainLight (1280×720, 2–3 lines)
    case landscapeSingle  // SingleLine (1280×720, 1 line)
    case phone            // PhoneOneLine / PhoneTwoLines / PhonePortrait (390×844)
    case pad              // PadPortrait (834×1194)
}

nonisolated struct MapStopInput: Hashable, Sendable, Codable {
    var code: String
    var name: String

    init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

nonisolated struct MapLineInput: Identifiable, Hashable, Sendable {
    var id: String
    var number: String
    var colorIndex: Int
    /// Terminus first … user's stop LAST (inclusive). The adapter trims anything past the user's stop.
    var stops: [MapStopInput]
    /// Every stop past the user's, to the far terminus. The board draws the next one, faded, so
    /// the user's stop does not read as the end of the line.
    var onward: [MapStopInput]

    init(id: String, number: String, colorIndex: Int, stops: [MapStopInput], onward: [MapStopInput] = []) {
        self.id = id
        self.number = number
        self.colorIndex = colorIndex
        self.stops = stops
        self.onward = onward
    }
}

nonisolated struct MapVehicleInput: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    /// Index into `MapLineInput.stops`; 0 = at or just after the terminus.
    var lastStopIndex: Int
    /// 0…1 towards `stops[lastStopIndex + 1]`.
    var progressToNext: Double
    /// Carries the white ring (the next arrival in swap mode, the tapped bus in beside mode).
    var isSelected: Bool

    init(id: String, lineID: String, lastStopIndex: Int, progressToNext: Double, isSelected: Bool = false) {
        self.id = id
        self.lineID = lineID
        self.lastStopIndex = lastStopIndex
        self.progressToNext = progressToNext
        self.isSelected = isSelected
    }
}

nonisolated struct MapLayoutRequest: Hashable, Sendable {
    var lines: [MapLineInput]        // selection order, 1…3
    var trunkLineID: String
    var userStopCode: String
    var vehicles: [MapVehicleInput]
    var axis: MapAxis
    var preset: MapSizePreset
    var canvasSize: CGSize           // the map area, in points
    var scale: CGFloat               // 1.0 at the reference size
    /// Lines whose stops get names. nil = all. Phone portrait with 3 lines passes `[trunkLineID]`
    /// so the other two become unnamed distance spines.
    var namedLineIDs: Set<String>?
    /// BusDetail "beside" mode: everything except this line is dimmed. nil = nothing dimmed.
    var highlightedLineID: String?
    /// Stop marks the tail may spend, where the preset's (`MapMetrics.tailBudget`) is more than
    /// the canvas has room for: a widget folds more of the route into its "+N STOPS" run.
    var tailBudget: Int?
    /// Head stops drawn before each dashed run, where the preset's (`MapMetrics.headCount`) crowds
    /// a short canvas.
    var headCount: Int?
    /// The closest two drawn stops may come. Past it the dashes give up length rather than the
    /// stops, which on a board this short would put one name on top of the next.
    var minimumStopPitch: CGFloat?

    init(lines: [MapLineInput], trunkLineID: String, userStopCode: String, vehicles: [MapVehicleInput] = [],
         axis: MapAxis = .horizontal, preset: MapSizePreset = .landscape,
         canvasSize: CGSize = CGSize(width: 1280, height: 380), scale: CGFloat = 1,
         namedLineIDs: Set<String>? = nil, highlightedLineID: String? = nil, tailBudget: Int? = nil,
         headCount: Int? = nil, minimumStopPitch: CGFloat? = nil) {
        self.lines = lines
        self.trunkLineID = trunkLineID
        self.userStopCode = userStopCode
        self.vehicles = vehicles
        self.axis = axis
        self.preset = preset
        self.canvasSize = canvasSize
        self.scale = scale
        self.namedLineIDs = namedLineIDs
        self.highlightedLineID = highlightedLineID
        self.tailBudget = tailBudget
        self.headCount = headCount
        self.minimumStopPitch = minimumStopPitch
    }
}
