import Foundation
import CoreGraphics

/// Route fixtures reconstructed from the design artboards. They live in the app target so the
/// mock provider and the unit tests describe exactly the same routes.
nonisolated enum MapFixtures {
    static func stop(_ name: String) -> MapStopInput {
        MapStopInput(code: name.uppercased().replacingOccurrences(of: " ", with: "-"), name: name.uppercased())
    }

    /// Anonymous stops swallowed by a dashed run. They exist in the data; the drawing hides them.
    static func filler(_ prefix: String, _ count: Int) -> [MapStopInput] {
        (1...count).map { stop("\(prefix) \($0)") }
    }

    static let user = "HARBOR GATE"
    static var userCode: String { stop(user).code }

    // MARK: Main — nothing merges before the user's stop (Main.dc.html)

    static let line41Main = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 4)
        + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])

    static let line18Main = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 6)
        + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("OAK & 5TH"), stop("PIER FOUR"), stop("GRANITE ROW"), stop(user)])

    static let line7Main = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 9)
        + [stop("OLD MILL"), stop("COLLEGE RD"), stop("RIVER BEND"), stop("SOUTH PIER"), stop("CUSTOM HOUSE"), stop(user)])

    static let main = [line18Main, line41Main, line7Main]

    // MARK: Merge A — 18 joins 41 at MILL JUNCTION; 7 stays independent (Merge1.dc.html)

    static let line41A = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 5)
        + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("MILL JUNCTION"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])

    static let line18A = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 7)
        + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("MILL JUNCTION"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])

    static let line7A = line7Main

    static let mergeA = [line18A, line41A, line7A]

    // MARK: Merge B — 18 joins at BELL TOWER, 7 joins later at PIER FOUR (Merge2.dc.html)

    static let line41B = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 4)
        + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])

    static let line18B = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 6)
        + [stop("CIVIC CTR"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])

    static let line7B = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 8)
        + [stop("OLD MILL"), stop("COLLEGE RD"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])

    static let mergeB = [line18B, line41B, line7B]

    // MARK: Merge C — all three share everything after WEST MARKET (Merge3.dc.html)

    static let line41C = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 6)
        + [stop("LOWER QUAY"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])

    static let line18C = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 5)
        + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])

    static let line7C = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 8)
        + [stop("OLD MILL"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])

    static let mergeC = [line18C, line41C, line7C]

    // MARK: Corridor — two lines only, 18 joining 41 six stops out and sharing the whole run in

    static let line41Corridor = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 16)
        + [stop("LOWER QUAY")] + corridor)

    static let line18Corridor = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 20)
        + [stop("CIVIC CTR")] + corridor)

    /// Everything from the junction to the user's stop, on both lines.
    private static var corridor: [MapStopInput] {
        [stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("CUSTOM HOUSE"),
         stop("PIER FOUR"), stop("DOCK GATE"), stop(user)]
    }

    static let corridorPair = [line41Corridor, line18Corridor]

    static func request(_ lines: [MapLineInput],
                        trunk: String = "41",
                        axis: MapAxis = .horizontal,
                        preset: MapSizePreset = .landscape,
                        canvas: CGSize = CGSize(width: 1280, height: 380),
                        scale: CGFloat = 1,
                        vehicles: [MapVehicleInput] = [],
                        named: Set<String>? = nil,
                        highlighted: String? = nil) -> MapLayoutRequest {
        MapLayoutRequest(lines: lines, trunkLineID: trunk, userStopCode: userCode, vehicles: vehicles,
                         axis: axis, preset: preset, canvasSize: canvas, scale: scale,
                         namedLineIDs: named, highlightedLineID: highlighted)
    }
}

/// The four route topologies the mock provider can serve, mirroring the artboards.
nonisolated enum MockScenario: String, CaseIterable, Sendable {
    case main, mergeA, mergeB, mergeC, corridor

    var lines: [MapLineInput] {
        switch self {
        case .main: MapFixtures.main
        case .mergeA: MapFixtures.mergeA
        case .mergeB: MapFixtures.mergeB
        case .mergeC: MapFixtures.mergeC
        case .corridor: MapFixtures.corridorPair
        }
    }

    var title: String {
        switch self {
        case .main: "Main — nothing merges"
        case .mergeA: "Merge A — one shared corridor"
        case .mergeB: "Merge B — two junctions"
        case .mergeC: "Merge C — common trunk"
        case .corridor: "Corridor — two lines, long shared run"
        }
    }
}
