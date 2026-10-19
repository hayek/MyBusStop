import AppIntents
import WidgetKit

/// What the rider sets when they edit the widget: which stop from their history it watches, and
/// what the large sizes show besides its next buses. The history is only where the stop is picked
/// from: a widget shows that one stop and nothing else of it.
struct SelectSavedSetupIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a stop"
    static let description = IntentDescription("Which of My stops the widget shows.")

    @Parameter(title: "Stop")
    var setup: SavedSetupEntity?

    // A complication has no large size, so the watch's editor offers only the stop.
    #if !os(watchOS)
    /// Replaces the first release's "Show your other stops" switch, under a key of its own: a
    /// widget set up before it opens on the map, the default. A widget later set to "Other stops",
    /// since removed, reads back as the map too (`LargeWidgetContent.init(rawValue:)`).
    @Parameter(title: "Large widget shows", default: .map)
    var largeContent: LargeWidgetContent
    #endif

    init() {}
}

extension LargeWidgetContent: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Large widget content"
    static let caseDisplayRepresentations: [LargeWidgetContent: DisplayRepresentation] = [
        .map: "Map",
        .laterBuses: "Later buses",
    ]
}
