import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One picture of the widget: what it shows at `date`. The widget makes it a `TimelineEntry`.
nonisolated struct NextBusEntry: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case board
        /// Nothing in the history yet: the app has to be used once first.
        case noHistory
        /// The entry the widget was set to is gone from the history.
        case notConfigured
    }

    var date: Date
    var state: State
    var setup: SavedSetup?
    /// Still to come at `date`, soonest first. Empty once the numbers are too old to show.
    var arrivals: [WidgetArrival]
    var liveness: WidgetLiveness
    /// What the large sizes show besides the readout, once a map with no routes to draw has fallen
    /// back to the later buses.
    var content: LargeWidgetContent = .laterBuses
    /// The board's map at `date`, when the content is the map.
    var map: WidgetMapFrame?
    var palette: [String: Int] = [:]
    var appearance: Appearance = .system

    /// The line's colour as the app assigned it (`SettingsStore.colorIndex(for:)`).
    func colorIndex(for lineID: String) -> Int {
        LineColorAssigner.provisionalIndex(for: lineID, persisted: palette)
    }

    func line(for arrival: WidgetArrival) -> TransitLine? {
        setup?.lines.first { $0.id == arrival.lineID }
    }

    /// How much the Smart Stack should raise this picture (`WidgetTimelineMath.relevanceScore`): only
    /// a board with numbers to count down, never a message nor numbers too old to show.
    var relevanceScore: Float? {
        guard state == .board, liveness != .expired else { return nil }
        return WidgetTimelineMath.relevanceScore(secondsToNext: arrivals.first.map { $0.expectedAt.timeIntervalSince(date) })
    }

    /// For the gallery, and for WidgetKit's placeholder while the first timeline loads.
    static func sample(at date: Date) -> NextBusEntry {
        let stop = TransitStop(code: "21470", name: "Allenby / Rothschild", city: "Tel Aviv",
                               location: GeoPoint(lat: 32.064, lon: 34.774))
        func line(_ id: String) -> TransitLine {
            TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                        isAccessible: nil, brandColorIndex: nil)
        }
        let setup = SavedSetup(stop: stop, lines: [line("18"), line("41"), line("7")], lastUsedAt: date)
        let arrivals = [(18, 4), (41, 11), (7, 16), (18, 22), (41, 31)].map { (id: Int, minutes: Int) -> WidgetArrival in
            // Line 7's feed has no positions: it shows up on the map without a bus.
            let stopsAway: Int? = id == 7 ? nil : max(1, minutes / 2)
            return WidgetArrival(lineID: String(id), expectedAt: date.addingTimeInterval(Double(minutes) * 60 - 20),
                                 isRealtime: id != 7, stopsAway: stopsAway, progressToNext: 0.4)
        }
        // The lines' colours as setup would assign them, so no two rails of the map share one.
        let palette = ["18": 0, "41": 1, "7": 2]
        var entry = NextBusEntry(date: date, state: .board, setup: setup, arrivals: arrivals, liveness: .live,
                                 content: .map, palette: palette)
        entry.map = WidgetMap.frame(setup: setup, routes: sampleRoutes(to: stop), arrivals: arrivals,
                                    fetchedAt: date, liveness: .live, palette: palette, date: date)
        return entry
    }

    /// Three routes into the sample's stop, with its buses a few stops out, for the gallery's map.
    private static func sampleRoutes(to stop: TransitStop) -> WidgetRoutes {
        func route(_ line: String, _ names: [String], hidden: Int) -> [MapStopInput] {
            let head = names.prefix(1).map { MapStopInput(code: "\(line)-\($0)", name: $0) }
            let middle = (1...hidden).map { MapStopInput(code: "\(line)-\($0)", name: "") }
            let tail = names.dropFirst().map { MapStopInput(code: "\(line)-\($0)", name: $0) }
            return head + middle + tail + [MapStopInput(code: stop.code, name: stop.name)]
        }
        return WidgetRoutes(setupID: SavedSetup.identifier(stop: stop, lineIDs: ["18", "41", "7"]), lines: [
            "18": route("18", ["BAT YAM", "HERZL", "BALFOUR", "NAHALAT BINYAMIN"], hidden: 14),
            "41": route("41", ["UNIVERSITY", "IBN GABIROL", "RABIN SQUARE", "HABIMA"], hidden: 9),
            "7": route("7", ["JAFFA PORT", "YEFET", "KEREM", "MAGEN DAVID"], hidden: 11),
        ])
    }
}

/// What the large and extra large widgets spend their room on, besides the readout. The rider
/// picks it when editing the widget ("Large widget shows"); the portrait extra large follows it too.
/// Every size shows the one stop the widget is set to, and nothing else from the history.
nonisolated enum LargeWidgetContent: String, Codable, Hashable, Sendable, CaseIterable {
    /// The board's map: the lines, their stops and the buses on them.
    case map
    /// The arrivals after the two the readout shows.
    case laterBuses

    /// The raw values a widget's configuration was saved with. The first map release also offered
    /// the rest of the history ("otherStops"); a widget still set to it opens on the map, the default.
    init?(rawValue: String) {
        switch rawValue {
        case "map", "otherStops": self = .map
        case "laterBuses": self = .laterBuses
        default: return nil
        }
    }

    /// What is actually drawn. The map needs routes the app saves when it shows the stop's board
    /// (`WidgetRoutes`); until then the widget lists the stop's later buses.
    func resolved(hasMap: Bool) -> LargeWidgetContent {
        self == .map && !hasMap ? .laterBuses : self
    }
}

/// How many of the stop's arrivals a widget size has room for. The views lay out exactly this many
/// rows, and the timeline only redraws for what they show.
nonisolated struct WidgetLayout: Hashable, Sendable {
    /// The readout's two: the next bus and the one after it.
    static let readoutArrivals = 2
    static let largeLaterRows = 4
    static let extraLargeLaterRows = 6
    /// Beside the map, the extra large widget's later buses share their column with the readout.
    static let extraLargeMapLaterRows = 2
    /// The portrait extra large stacks the readout over its list, three smalls tall.
    static let extraLargePortraitLaterRows = 7

    /// What the large sizes show; `.laterBuses` on the others, which draw neither.
    var content: LargeWidgetContent = .laterBuses
    /// Arrivals at the chosen stop on screen at once.
    var arrivalsShown: Int

    #if canImport(WidgetKit)
    /// - Parameters:
    ///   - content: the rider's choice, resolved here against what there is to show.
    ///   - hasMap: routes are saved for the chosen stop.
    static func `for`(_ family: WidgetFamily, content chosen: LargeWidgetContent, hasMap: Bool) -> WidgetLayout {
        let content = chosen.resolved(hasMap: hasMap)
        switch (family, content) {
        // The system sizes do not exist on watchOS; every complication gets the readout's two.
        #if !os(watchOS)
        case (.systemLarge, .map), (.systemExtraLargePortrait, .map):
            // The map, and under it the readout: the next bus and THEN.
            return WidgetLayout(content: .map, arrivalsShown: readoutArrivals)
        case (.systemLarge, .laterBuses):
            return WidgetLayout(content: content, arrivalsShown: readoutArrivals + largeLaterRows)
        case (.systemExtraLarge, .map):
            return WidgetLayout(content: .map, arrivalsShown: readoutArrivals + extraLargeMapLaterRows)
        case (.systemExtraLarge, .laterBuses):
            return WidgetLayout(content: content, arrivalsShown: readoutArrivals + extraLargeLaterRows)
        case (.systemExtraLargePortrait, .laterBuses):
            return WidgetLayout(content: content, arrivalsShown: readoutArrivals + extraLargePortraitLaterRows)
        #endif
        default:
            return WidgetLayout(arrivalsShown: readoutArrivals)
        }
    }
    #endif
}

/// Every picture of a widget from `now` on, from the history and the last numbers known. Pure,
/// so the timeline provider only has to load and fetch.
nonisolated enum NextBusTimeline {
    static func entries(history: [SavedSetup], chosenID: String?,
                        snapshot: WidgetSnapshot?, routes: WidgetRoutes? = nil,
                        layout: WidgetLayout, palette: [String: Int], appearance: Appearance,
                        now: Date) -> [NextBusEntry] {
        let setup: SavedSetup, numbers: WidgetSnapshot?
        switch resolve(history: history, chosenID: chosenID, snapshot: snapshot, layout: layout,
                       palette: palette, appearance: appearance, now: now) {
        case .message(let entry): return [entry]
        case .board(let resolved, let own): (setup, numbers) = (resolved, own)
        }

        let dates = numbers.map {
            WidgetTimelineMath.entryDates(for: $0.upcoming(at: now), fetchedAt: $0.fetchedAt, now: now,
                                          arrivalsShown: layout.arrivalsShown)
        } ?? [now]
        // The series' last moment is where it runs out: past it nothing is counted down.
        let runsOut = dates.count > 1 ? dates.last : nil

        return dates.map { date in
            picture(at: date, isOver: runsOut.map { date >= $0 } ?? false, setup: setup, snapshot: numbers,
                    routes: routes, layout: layout, palette: palette, appearance: appearance)
        }
    }

    /// The timeline's first entry alone — the picture at `now` — without working out the rest of the
    /// series: what a board redrawn every second needs. The first moment is never past the series'
    /// end (`entryDates` puts the end more than a second after `now`), so nothing is cut short here.
    static func entry(history: [SavedSetup], chosenID: String?,
                      snapshot: WidgetSnapshot?, routes: WidgetRoutes? = nil,
                      layout: WidgetLayout, palette: [String: Int], appearance: Appearance,
                      now: Date) -> NextBusEntry {
        switch resolve(history: history, chosenID: chosenID, snapshot: snapshot, layout: layout,
                       palette: palette, appearance: appearance, now: now) {
        case .message(let entry): return entry
        case .board(let setup, let snapshot):
            return picture(at: now, isOver: false, setup: setup, snapshot: snapshot, routes: routes, layout: layout,
                           palette: palette, appearance: appearance)
        }
    }

    private enum Resolved {
        case board(SavedSetup, WidgetSnapshot?)
        case message(NextBusEntry)
    }

    /// The stop the widget shows, with its numbers only if they are its own; or the message instead.
    private static func resolve(history: [SavedSetup], chosenID: String?, snapshot: WidgetSnapshot?,
                                layout: WidgetLayout, palette: [String: Int], appearance: Appearance,
                                now: Date) -> Resolved {
        func blank(_ state: NextBusEntry.State) -> Resolved {
            .message(NextBusEntry(date: now, state: state, setup: nil, arrivals: [], liveness: .expired,
                                  content: layout.content, palette: palette, appearance: appearance))
        }
        switch HistoryLookup.resolve(id: chosenID, in: history) {
        case .noHistory: return blank(.noHistory)
        case .missing: return blank(.notConfigured)
        case .setup(let setup):
            // Someone else's numbers are never drawn under this stop's name.
            return .board(setup, snapshot?.setupID == setup.id ? snapshot : nil)
        }
    }

    /// One picture of the board at `date`. `isOver`: the series has run out by then.
    private static func picture(at date: Date, isOver: Bool, setup: SavedSetup, snapshot: WidgetSnapshot?,
                                routes: WidgetRoutes?, layout: WidgetLayout, palette: [String: Int],
                                appearance: Appearance) -> NextBusEntry {
        var liveness = WidgetLiveness.expired
        var arrivals: [WidgetArrival] = []
        if let snapshot, !isOver {
            liveness = WidgetTimelineMath.liveness(fetchedAt: snapshot.fetchedAt, now: date)
            arrivals = liveness == .expired ? [] : snapshot.upcoming(at: date)
            // Every bus the feed named has come and gone. More are surely on the way, but this
            // snapshot does not know them, so the widget says to look, not that none are due.
            if arrivals.isEmpty, !snapshot.arrivals.isEmpty { liveness = .expired }
        }
        // Rails and stops whatever the numbers; buses only while there are numbers to place them by.
        let map = layout.content == .map
            ? WidgetMap.frame(setup: setup, routes: routes, arrivals: arrivals, fetchedAt: snapshot?.fetchedAt,
                              liveness: liveness, palette: palette, date: date)
            : nil
        // The stops still to go count down with the minutes, as the buses on the map move.
        if let fetchedAt = snapshot?.fetchedAt {
            arrivals = arrivals.map { arrival in
                var advanced = arrival
                advanced.stopsAway = WidgetMap.stopsAway(of: arrival, fetchedAt: fetchedAt, at: date)
                return advanced
            }
        }
        return NextBusEntry(date: date, state: .board, setup: setup, arrivals: arrivals, liveness: liveness,
                            content: layout.content, map: map,
                            palette: palette, appearance: appearance)
    }
}
