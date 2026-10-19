import AppIntents

/// One entry of the rider's history, as the widget's editor lists it: the stop's name, and the
/// lines watched there underneath — the history picker's row, in the system's own list.
nonisolated struct SavedSetupEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stop"
    static let defaultQuery = SavedSetupQuery()

    var id: String
    var stopName: String
    var lines: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(stopName)", subtitle: "\(lines)")
    }

    init(_ setup: SavedSetup) {
        id = setup.id
        stopName = setup.stop.name
        lines = HistoryLookup.subtitle(for: setup)
    }

    /// An entry since removed from the history. Returned under its old id rather than dropped: a
    /// dropped one reaches the widget as no choice at all, and the widget would quietly show the
    /// top of the history instead of saying its stop has gone.
    init(removedID id: String) {
        self.id = id
        stopName = String(appLocalized: "Removed stop")
        lines = ""
    }
}

/// Reads the history the app shares (`SharedHistoryStore`), in the picker's order.
nonisolated struct SavedSetupQuery: EntityQuery {
    func entities(for identifiers: [SavedSetupEntity.ID]) async throws -> [SavedSetupEntity] {
        let history = SharedHistoryStore().load()
        return identifiers.map { id in
            history.first { $0.id == id }.map(SavedSetupEntity.init) ?? SavedSetupEntity(removedID: id)
        }
    }

    func suggestedEntities() async throws -> [SavedSetupEntity] {
        HistoryLookup.sorted(SharedHistoryStore().load()).map(SavedSetupEntity.init)
    }

    /// A new widget starts on the top of the picker: the pinned stop, or the last one used.
    func defaultResult() async -> SavedSetupEntity? {
        HistoryLookup.defaultEntry(in: SharedHistoryStore().load()).map(SavedSetupEntity.init)
    }
}
