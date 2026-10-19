#if os(iOS)
import Testing
import SwiftUI
import UIKit
import WidgetKit
@testable import BusBus

/// Every widget size, drawn at the smallest sizes the system hands out, fits without clipping.
///
/// Measured rather than eyeballed: a widget has no scrolling, and anything taller than its box is
/// simply cut off. Set `TEST_RUNNER_WIDGET_RENDER_DIR` to a folder to also get every render as a
/// PNG.
@MainActor
struct WidgetLayoutFitTests {
    enum Family: String, CaseIterable {
        case small, medium, large, extraLarge, extraLargePortrait, standBy
        /// The watch's complications, drawn by the same accessory views the lock screen uses.
        case circular, rectangular, inline, corner
    }

    /// The system's content margins round a widget's content, before iOS 27.
    static let margin: CGFloat = 16

    /// Widget sizes in points, with the content margins round them: the iPad mini's, the smallest
    /// iPhones', and a 6.1" iPhone's; and what iOS 27 gives a 6.3" iPhone (17 Pro, 18 Pro) and a
    /// 13" iPad, read from the simulators' own widget metrics. The portrait extra large is three
    /// smalls and the two gaps between them tall, which is how every one of those comes out.
    ///
    /// StandBy lays the small widget out at the home screen's size with the narrower margins it
    /// keeps once the background goes, and only then scales it up (by 2.2 on a 6.3" iPhone): so
    /// its box is the small one. The smallest iPhone's margin is the others' proportion of it.
    static let sizes: [(Family, CGSize, CGFloat)] = [
        (.small, CGSize(width: 141, height: 141), margin), (.small, CGSize(width: 148, height: 148), margin),
        (.small, CGSize(width: 158, height: 158), margin), (.small, CGSize(width: 164.33, height: 164.33), 18.04),
        (.medium, CGSize(width: 292, height: 141), margin), (.medium, CGSize(width: 321, height: 148), margin),
        (.medium, CGSize(width: 338, height: 158), margin), (.medium, CGSize(width: 349.67, height: 164.33), 18.04),
        (.large, CGSize(width: 292, height: 311), margin), (.large, CGSize(width: 321, height: 324), margin),
        (.large, CGSize(width: 338, height: 354), margin), (.large, CGSize(width: 349.67, height: 365), 18.04),
        (.extraLarge, CGSize(width: 634, height: 305), margin), (.extraLarge, CGSize(width: 715, height: 330), margin),
        (.extraLargePortrait, CGSize(width: 292, height: 481), margin),
        (.extraLargePortrait, CGSize(width: 321, height: 500), margin),
        (.extraLargePortrait, CGSize(width: 349.67, height: 565.67), 18.04),
        (.extraLargePortrait, CGSize(width: 378.25, height: 586.5), 18.66),
        (.standBy, CGSize(width: 148, height: 148), 6.5), (.standBy, CGSize(width: 164.33, height: 164.33), 7.28),
        (.standBy, CGSize(width: 176.67, height: 176.67), 7.83),
    ]

    /// Watch complication sizes in points, from the HIG's complication tables (the watch
    /// simulators do not expose their metrics): 40, 42, 44, 46 and 49 mm where the family's size
    /// changes, the smallest and the largest where only those are published. No margin: the face
    /// gives the view its whole box. The corner's is the glyph's box; its curved label is measured
    /// on its own (`cornerLabelBudget`).
    static let watchSizes: [(Family, CGSize)] = [
        (.circular, CGSize(width: 50, height: 50)), (.circular, CGSize(width: 54, height: 54)),
        (.circular, CGSize(width: 58, height: 58)), (.circular, CGSize(width: 60, height: 60)),
        (.rectangular, CGSize(width: 150, height: 47)), (.rectangular, CGSize(width: 162, height: 52)),
        (.rectangular, CGSize(width: 168, height: 52)), (.rectangular, CGSize(width: 176, height: 56)),
        (.rectangular, CGSize(width: 180, height: 58)),
        (.inline, CGSize(width: 133, height: 18)), (.inline, CGSize(width: 178, height: 22)),
        (.corner, CGSize(width: 32, height: 32)), (.corner, CGSize(width: 40, height: 40)),
    ]

    /// How long the corner's curved label may run, set in the system's 12 pt: about an eighth of
    /// the bezel on the smallest watch. An estimate, not a published size — it holds the countdown
    /// ("12 MIN", "1:15 HR") to the corner rather than letting it creep along the edge. The stop's
    /// name, shown when nothing is due, is the system's to truncate.
    static let cornerLabelBudget: CGFloat = 60

    static let languages = ["en", "de", "fi", "he", "ja"]

    private static func entries() -> [(String, NextBusEntry)] {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // The sample draws the map on the large sizes; `later` lists the stop's later buses instead.
        var live = NextBusEntry.sample(at: now)
        // The longest the sub-line gets: a scheduled bus, a few stops away.
        live.arrivals[1].isRealtime = false
        live.arrivals[0].stopsAway = 12
        var stale = live
        stale.liveness = .stale(asOf: now.addingTimeInterval(-14 * 60))
        stale.map?.vehiclesAreStale = true
        var later = live
        later.content = .laterBuses
        var hours = live
        hours.arrivals = hours.arrivals.map { var a = $0; a.expectedAt += 2 * 3600; return a }
        var expired = live
        expired.arrivals = []
        expired.liveness = .expired
        expired.map?.vehicles = []
        // A stop never opened on the board since: no routes, so the map falls back to a list.
        var noRoutes = live
        noRoutes.content = .laterBuses
        noRoutes.map = nil
        let missing = NextBusEntry(date: now, state: .notConfigured, setup: nil, arrivals: [], liveness: .expired)
        return [("live", live), ("stale", stale), ("later", later), ("hours", hours),
                ("expired", expired), ("no-routes", noRoutes), ("missing", missing)]
    }

    @ViewBuilder private func view(_ family: Family, _ entry: NextBusEntry) -> some View {
        switch family {
        case .small: SmallWidgetView(entry: entry)
        case .medium: MediumWidgetView(entry: entry)
        case .large: LargeWidgetView(entry: entry, arrangement: .stack)
        case .extraLarge: LargeWidgetView(entry: entry, arrangement: .columns)
        case .extraLargePortrait: LargeWidgetView(entry: entry, arrangement: .portrait)
        case .standBy: SmallWidgetView(entry: entry)
        case .circular: AccessoryCircularView(entry: entry)
        case .rectangular: AccessoryRectangularView(entry: entry)
        // The face sets an inline complication on one line, truncated; so does this.
        case .inline: AccessoryInlineView(entry: entry).lineLimit(1)
        case .corner: AccessoryCornerView(entry: entry)
        }
    }

    @Test(arguments: languages)
    func everySizeFits(language: String) throws {
        let directory = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"].map { URL(filePath: $0) }
        try AppLanguage.$pinned.withValue(language) {
            for (family, size, margin) in Self.sizes {
                let content = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
                let environment = WidgetEnvironment(appearance: .dark, showsBackgroundOverride: family != .standBy)
                for (name, entry) in Self.entries() {
                    let label = "\(language)-\(family.rawValue)-\(Int(size.width))x\(Int(size.height))-\(name)"
                    // Offered the box, a view that needs more than it takes more, and a widget cuts
                    // that off. Text that may truncate is allowed to: that is what lineLimit is for.
                    let measured = ImageRenderer(content: view(family, entry).modifier(environment))
                    measured.proposedSize = ProposedViewSize(content)
                    let size = try #require(measured.uiImage).size
                    // The image is whole points, rounded up: a point over is rounding, not overflow.
                    #expect(size.height <= content.height + 1, "\(label): \(size.height) pt tall in \(content.height)")
                    #expect(size.width <= content.width + 1, "\(label): \(size.width) pt wide in \(content.width)")

                    if let directory {
                        let boxed = ImageRenderer(content: view(family, entry)
                            .modifier(environment)
                            .frame(width: content.width, height: content.height, alignment: .top)
                            .padding(margin)
                            .background(Theme.dark.background))
                        boxed.scale = 2
                        try boxed.uiImage?.pngData()?.write(to: directory.appending(path: "\(label).png"))
                    }
                }
            }
        }
    }

    /// The four complications at every watch size, in the vibrant look most faces draw them in.
    @Test(arguments: languages)
    func everyWatchSizeFits(language: String) throws {
        try AppLanguage.$pinned.withValue(language) {
            for (family, size) in Self.watchSizes {
                for (name, entry) in Self.entries() {
                    let label = "\(language)-\(family.rawValue)-\(Int(size.width))x\(Int(size.height))-\(name)"
                    let measured = ImageRenderer(content: view(family, entry)
                        .modifier(WidgetEnvironment(appearance: .dark))
                        .environment(\.widgetRenderingMode, .vibrant))
                    measured.proposedSize = ProposedViewSize(size)
                    let rendered = try #require(measured.uiImage).size
                    // An inline complication is set in the face's own font, at the face's size: its
                    // height is the system's, and only its width is the view's to keep.
                    if family != .inline {
                        #expect(rendered.height <= size.height + 1, "\(label): \(rendered.height) pt tall in \(size.height)")
                    }
                    #expect(rendered.width <= size.width + 1, "\(label): \(rendered.width) pt wide in \(size.width)")

                    // Only a countdown is the view's to keep short: with nothing due it shows the glyph.
                    guard family == .corner, !entry.arrivals.isEmpty else { continue }
                    let text = ImageRenderer(content: Text(verbatim: AccessoryCornerView(entry: entry).label)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize())
                    let width = try #require(text.uiImage).size.width
                    #expect(width <= Self.cornerLabelBudget, "\(label): corner label \(width) pt long")
                }
            }
        }
    }
}
#endif
