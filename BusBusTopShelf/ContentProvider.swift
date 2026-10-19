import SwiftUI
import TVServices
import UIKit
import os

/// Apple TV's Top Shelf: with BusBus in the top row of the Home Screen, a full-screen carousel of
/// the saved stops, one slide each: the stop's board as the app last drew it, or its next buses
/// when that picture is old. Selecting a slide opens that stop's board.
///
/// The system asks for the content when it wants it, and again after the app says it changed (a
/// board refresh or a history change). The slides are still pictures, so each says the time it was
/// drawn rather than pretending to count down.
///
/// The target is a plain app extension: tvOS's own extension product type links
/// `TVExtensionMain`, which on tvOS 27 returns at once, and the extension quit before loading.
nonisolated final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        await TopShelfBuilder.content(now: .now)
    }
}

@MainActor enum TopShelfBuilder {
    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "topshelf")
    /// As many as the history holds: the shelf scrolls, and the rider chose each of them.
    static let limit = SavedSetups.limit

    static func content(now: Date) async -> (any TVTopShelfContent)? {
        FontRegistrar.registerBundledFonts()
        let shared = SharedHistoryStore()
        let history = Array(TVStopOrder.ordered(shared.load()).prefix(limit))
        let palette = shared.paletteAssignments()
        let scheme = shared.appearance().colorScheme ?? .dark
        let images = TopShelfImages()
        // The shelf may still be showing the last pictures while this fetches: they are only
        // deleted once the new ones are written.
        defer { images.removeAll(except: images.written) }

        // Nothing saved yet: the static banner (the app's Top Shelf images) says what the app is.
        guard !history.isEmpty else { return nil }

        await refreshSnapshots(for: history, now: now)
        let snapshots = WidgetSnapshotStore()
        let disabled = shared.disabledProviders()
        let glances = StopGlances.build(history: history, snapshot: { snapshots.load(setupID: $0) }, now: now)
        let items = glances.map { glance in
            let item = TVTopShelfCarouselItem(identifier: glance.id)
            item.title = glance.setup.stop.name
            item.contextTitle = glance.setup.stop.city
            // Switched off remotely, it says so and opens nothing; a provider only the app can
            // call still shows what the app last saw.
            let providerID = glance.setup.providerID ?? WidgetProviderGate.legacyProviderID
            let available = !(disabled ?? WidgetProviderGate.offUntilMirrored).contains(providerID)
            if available {
                item.displayAction = TVTopShelfAction(url: glance.deepLink)
                item.playAction = TVTopShelfAction(url: glance.deepLink)
                item.summary = summary(of: glance)
            } else {
                item.summary = String(appLocalized: "Not available here")
            }
            // The board itself when the app drew it lately; the next buses, large, when not.
            let picture = TopShelfBoards.freshPicture(for: glance.id, now: now).flatMap(images.copy)
                ?? images.render(TVGlanceSlide(glance: glance,
                                               colorIndex: { LineColorAssigner.provisionalIndex(for: $0, persisted: palette) },
                                               drawnAt: now),
                                 scheme: scheme)
            if let picture {
                item.setImageURL(picture, for: .screenScale1x)
                item.setImageURL(picture, for: .screenScale2x)
            }
            return item
        }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }

    /// "112 · 10 MIN   245 · 2 · 42 MIN": each line and its next buses, for the slide's details.
    static func summary(of glance: StopGlance) -> String {
        glance.lines.map { "\($0.line.shortName) · \(TVStopCard.times($0.next))" }.joined(separator: "    ")
    }

    /// Fetches the stops whose numbers are over a minute old, in parallel, as the widget would.
    /// A stop that fails keeps what it had.
    private static func refreshSnapshots(for history: [SavedSetup], now: Date) async {
        let fetcher = WidgetArrivalsFetcher()
        let store = WidgetSnapshotStore()
        let stale = StopGlances.needingFetch(history: history, snapshot: { store.load(setupID: $0) }, now: now)
            .filter(fetcher.canFetch)
        guard !stale.isEmpty else { return }
        await withTaskGroup(of: WidgetSnapshot?.self) { group in
            for setup in stale {
                group.addTask { try? await fetcher.fetch(setup, now: now) }
            }
            for await snapshot in group {
                if let snapshot { store.save(snapshot) }
            }
        }
        log.info("refetched \(stale.count) stops for the Top Shelf")
    }
}

/// The card pictures, in the App Group container where the system can read them. Every picture
/// gets a name of its own: the system keeps a picture it has seen under a URL, and would show the
/// old numbers again.
@MainActor final class TopShelfImages {
    let directory: URL? = AppGroup.containerURL?.appending(path: "Library/Caches/TopShelf", directoryHint: .isDirectory)
    /// What this load has written, which the shelf is about to show.
    private(set) var written: Set<URL> = []

    /// Drawn in the app's language and its direction, as the widget is.
    func render(_ view: some View, scheme: ColorScheme) -> URL? {
        guard let directory else { return nil }
        let language = AppLanguage.override
        // The theme is chosen from the colour scheme it finds, so the scheme goes on outside it.
        let renderer = ImageRenderer(content: view
            .busTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.locale, AppLanguage.locale)
            .environment(\.layoutDirection, language.map(AppLanguage.layoutDirection(for:))
                         ?? (Locale.current.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)))
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = directory.appending(path: "\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written.insert(url.standardizedFileURL)
            return url
        } catch {
            return nil
        }
    }

    /// The app's picture of a board, under a name of this load's own.
    func copy(_ source: URL) -> URL? {
        guard let directory else { return nil }
        let url = directory.appending(path: "\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url)
            written.insert(url.standardizedFileURL)
            return url
        } catch {
            return nil
        }
    }

    /// Every earlier picture: the shelf has been handed the new ones.
    func removeAll(except keep: Set<URL>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where !keep.contains(file.standardizedFileURL) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
