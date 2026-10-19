import Testing
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers
@testable import BusBus

/// The widget in every size, state and look, as PNGs for the App Store and the website. Off
/// unless `WIDGET_SHOTS` names the device (iphone, ipad, mac or watch), which `scripts/screenshots.sh
/// widgets` does; every render comes back as an attachment, named for where the script files it:
///
///     <language>+<look>+<family>-<state>.png
///
/// The data is the app screenshots' own (`ScreenshotMode`): the mock's HARBOR GATE watching 18, 41
/// and 7, the rider's history and line colours, and numbers fetched around the frozen 9:41 — so a
/// widget shows the buses the board does. Each picture is `NextBusTimeline`'s first entry, drawn
/// by `NextBusWidgetView` inside the widget's rounded container, transparent outside it.
///
/// Outside a widget host there is no system to render tinted or vibrant, so those looks set
/// `widgetRenderingMode` — which switches the views to their monochrome theme and outlined badges
/// exactly as on a device — and then do the system's part by hand: everything drawn is used as a
/// mask for one ink, over the glass behind it. Where the system gives the accented group
/// (`widgetAccentable`) the tint and the rest a paler one, here all of it takes the tint.
///
/// StandBy is drawn the same way: the small widget without its container background, laid out at
/// its home screen size inside StandBy's narrower margins, then scaled up as StandBy scales it, on
/// black; and at night vibrant, masked into StandBy's red.
@MainActor
struct WidgetScreenshotTests {
    /// The device named in the environment, or nil for an ordinary test run.
    static let device = ProcessInfo.processInfo.environment["WIDGET_SHOTS"].flatMap(Device.init)

    enum Device: String {
        case iphone, ipad, mac
        /// The watch's complications, drawn on the iPhone simulator by the same accessory views.
        case watch

        /// Point sizes as iOS 27 lays a widget out on a 6.9" iPhone (17 Pro Max) and a 13" iPad,
        /// read from the simulators' own widget metrics; the lock screen's from the HIG's table.
        /// macOS has neither: the Mac takes the large iPhone's from the HIG, extra large is two
        /// mediums and a gap, and portrait three smalls and two gaps, as on the others.
        var families: [(WidgetFamily, CGSize)] {
            switch self {
            case .iphone:
                #if os(iOS)
                [(.systemSmall, CGSize(width: 176.67, height: 176.67)),
                 (.systemMedium, CGSize(width: 378, height: 176.67)), (.systemLarge, CGSize(width: 378, height: 394)),
                 (.systemExtraLargePortrait, CGSize(width: 378, height: 611.33)),
                 (.accessoryCircular, CGSize(width: 76, height: 76)),
                 (.accessoryRectangular, CGSize(width: 172, height: 76)), (.accessoryInline, CGSize(width: 257, height: 26))]
                #else
                []
                #endif
            case .ipad:
                [(.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 378.25, height: 170)),
                 (.systemLarge, CGSize(width: 378.25, height: 378.25)),
                 (.systemExtraLarge, CGSize(width: 794.75, height: 378.25)),
                 (.systemExtraLargePortrait, CGSize(width: 378.25, height: 586.5))]
            case .mac:
                [(.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 364, height: 170)),
                 (.systemLarge, CGSize(width: 364, height: 382)), (.systemExtraLarge, CGSize(width: 752, height: 382)),
                 (.systemExtraLargePortrait, CGSize(width: 364, height: 594))]
            case .watch:
                // 46 mm, then the 42 and 49 mm circle and rectangle, from the HIG's complication
                // tables (`WidgetLayoutFitTests.watchSizes`). The corner is not a family iOS knows:
                // `everyWidget` draws it on its own.
                #if os(iOS)
                [(.accessoryCircular, CGSize(width: 58, height: 58)),
                 (.accessoryRectangular, CGSize(width: 176, height: 56)), (.accessoryInline, CGSize(width: 178, height: 22)),
                 (.accessoryCircular, CGSize(width: 54, height: 54)), (.accessoryRectangular, CGSize(width: 162, height: 52)),
                 (.accessoryCircular, CGSize(width: 60, height: 60)), (.accessoryRectangular, CGSize(width: 180, height: 58))]
                #else
                []
                #endif
            }
        }

        /// The App Store's device scale.
        var scale: CGFloat { self == .iphone ? 3 : 2 }

        /// "46mm" for a watch complication of this size; nil elsewhere, where a family has one size.
        func caseSize(_ size: CGSize) -> String? {
            guard self == .watch else { return nil }
            switch size.width {
            case 54, 162: return "42mm"
            case 60, 180: return "49mm"
            default: return "46mm"
            }
        }

        /// The corner complication's glyph box at 46 mm, as `WidgetLayoutFitTests` measures it.
        static let cornerSize = CGSize(width: 40, height: 40)

        /// The container's corner, from the same metrics; the Mac's matches it by eye.
        var cornerRadius: CGFloat {
            switch self {
            case .iphone: 30.03
            case .ipad: 28.9
            case .mac: 22
            case .watch: 0
            }
        }

        /// The system's content margins on the home screen, from the same metrics.
        var margin: CGFloat {
            switch self {
            case .iphone: 19.39
            case .ipad: 18.66
            case .mac: 16
            case .watch: 0
            }
        }

        /// StandBy's margins round the small widget once its background is gone, and how much it
        /// scales the widget up: to 400 points square on a 6.9" iPhone.
        static let standByMargin: CGFloat = 7.83
        static let standByScale: CGFloat = 400 / 176.67

        /// Besides full colour: the home screen's tinted look, or the Mac desktop's, which drains
        /// a widget of colour while windows are in front of it.
        var monochromeLook: Look { self == .mac || self == .watch ? .vibrant : .tinted }
    }

    /// How the system draws the widget.
    enum Look: String {
        case fullColor, tinted, vibrant
        /// StandBy by day, and at night, when it turns everything red.
        case standBy, standByNight

        var renderingMode: WidgetRenderingMode {
            switch self {
            case .fullColor, .standBy: .fullColor
            case .tinted: .accented
            case .vibrant, .standByNight: .vibrant
            }
        }

        var isStandBy: Bool { self == .standBy || self == .standByNight }

        /// The glass behind a monochrome widget and the ink its content takes. Tinted is the home
        /// screen's blue, the Mac's the desktop's grey, both see-through like the real thing.
        func glassAndInk(_ appearance: Appearance) -> (Color, Color) {
            let dark = appearance == .dark
            switch self {
            case .fullColor, .standBy: return (.clear, .clear)
            // By luminance alone, the brightest a deep red, on the black StandBy draws on.
            case .standByNight: return (.black, Color(red: 0.93, green: 0.13, blue: 0.09))
            case .tinted:
                return dark ? (Color(red: 0.07, green: 0.12, blue: 0.19).opacity(0.92), Color(red: 0.66, green: 0.83, blue: 1))
                            : (Color(red: 0.85, green: 0.91, blue: 0.98).opacity(0.92), Color(red: 0.1, green: 0.28, blue: 0.5))
            case .vibrant:
                return dark ? (.black.opacity(0.4), .white.opacity(0.85)) : (.white.opacity(0.5), .black.opacity(0.72))
            }
        }
    }

    static var languages: [String] { list("WIDGET_SHOT_LANGUAGES", default: ["en", "he"]) }
    static var appearances: [Appearance] {
        list("WIDGET_SHOT_APPEARANCES", default: ["light", "dark"]).compactMap(Appearance.init)
    }

    private static func list(_ key: String, default fallback: [String]) -> [String] {
        ProcessInfo.processInfo.environment[key].map { $0.split(separator: " ").map(String.init) } ?? fallback
    }

    // MARK: Staging

    /// What the widget can be showing. The board states are HARBOR GATE's with numbers fetched
    /// this long before 9:41; the two others have no board at all.
    enum Scene: CaseIterable {
        case live, stale, noLiveData, noHistory, removedStop

        var name: String {
            switch self {
            case .live: "live"
            case .stale: "stale"
            case .noLiveData: "no-live-data"
            case .noHistory: "no-history"
            case .removedStop: "removed-stop"
            }
        }

        /// Live a moment ago; stale from 9:27, which the header says; too old to count down from.
        var fetchedAgo: TimeInterval? {
            switch self {
            case .live: 20
            case .stale: 14 * 60
            case .noLiveData: 45 * 60
            case .noHistory, .removedStop: nil
            }
        }
    }

    /// The first picture of `scene`, exactly as the timeline provider would build it from the
    /// rider's history and the numbers kept for it.
    private func entry(_ scene: Scene, family: WidgetFamily, content: LargeWidgetContent,
                       appearance: Appearance) -> NextBusEntry {
        let mode = ScreenshotMode(screen: .board, appearance: appearance, lineCount: 3, orientation: .portrait)
        let settings = mode.makeSettings()
        let now = ScreenshotMode.frozenNow
        let history = scene == .noHistory ? [] : settings.savedSetups
        let chosen = history.first
        let mock = MockTransitProvider(scenario: mode.scenario)

        // The chosen stop's numbers as the board saved them, with its buses placed for the map.
        func saved(_ setup: SavedSetup, fetchedAt: Date) -> WidgetSnapshot {
            let arrivals = setup.lines.flatMap { line in
                mock.arrivals(for: line, at: setup.stop, now: fetchedAt).map { arrival in
                    let bus = mock.position(of: arrival, line: line, at: setup.stop, now: fetchedAt)
                    return WidgetArrival(lineID: line.id, expectedAt: arrival.expectedAt, isRealtime: arrival.isRealtime,
                                         stopsAway: bus?.stopsAway, progressToNext: bus?.progressToNext,
                                         busID: bus.map { _ in arrival.tripId ?? line.id })
                }
            }
            return WidgetSnapshot(setupID: setup.id, fetchedAt: fetchedAt,
                                  arrivals: arrivals.sorted { $0.expectedAt < $1.expectedAt })
        }
        let fetchedAt = scene.fetchedAgo.map { now.addingTimeInterval(-$0) }
        let snapshot: WidgetSnapshot? = if let chosen, let fetchedAt { saved(chosen, fetchedAt: fetchedAt) } else { nil }

        // The routes the board saved when it showed the stop: each line's fixture, up to the stop.
        let routes = chosen.map { setup in
            WidgetRoutes(setupID: setup.id, lines: Dictionary(uniqueKeysWithValues: mode.scenario.lines.compactMap { line in
                line.stops.lastIndex { $0.code == setup.stop.code }.map { (line.id, Array(line.stops.prefix($0 + 1))) }
            }))
        }
        let layout = WidgetLayout.for(family, content: content,
                                      hasMap: chosen.map { WidgetMap.canDraw($0, routes: routes) } ?? false)
        let entries = NextBusTimeline.entries(
            history: history, chosenID: scene == .removedStop ? "REMOVED|18" : chosen?.id,
            snapshot: snapshot,
            routes: routes, layout: layout, palette: settings.paletteAssignments, appearance: appearance, now: now)
        return entries[0]
    }

    // MARK: Drawing

    /// The widget as the system frames it: the container's shape and background, the content
    /// margins, and for a monochrome look the system's ink and glass.
    @ViewBuilder private func framed(_ entry: NextBusEntry, family: WidgetFamily, size: CGSize,
                                     look: Look, device: Device) -> some View {
        let widget = NextBusWidgetView(entry: entry, family: family, showsBackground: look.isStandBy ? false : nil)
            .environment(\.widgetRenderingMode, look.renderingMode)
        if isAccessory(family) {
            // The lock screen draws these straight on the wallpaper, in white it blends into it.
            // The circle's `AccessoryWidgetBackground` is the system's to fill, and draws nothing
            // here: its frosted disc is put back, as the lock screen tints it.
            widget
                .frame(width: size.width, height: size.height)
                .foregroundStyle(.white)
                .background {
                    if isCircular(family) { Circle().fill(.white.opacity(0.18)) }
                }
        } else if look.isStandBy {
            // No container at all: the widget's content, straight on the black StandBy draws.
            let margin = Device.standByMargin
            let content = widget
                .frame(width: size.width - 2 * margin, height: size.height - 2 * margin)
                .padding(margin)
            let (glass, ink) = look.glassAndInk(.dark)
            if look == .standBy {
                content.background(.black)
            } else {
                ink.frame(width: size.width, height: size.height).mask { content }.background(glass)
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
            let content = widget
                .frame(width: size.width - 2 * device.margin, height: size.height - 2 * device.margin)
                .padding(device.margin)
            switch look {
            case .fullColor:
                let theme = Theme.widget(renderingMode: .fullColor, colorScheme: entry.appearance.colorScheme ?? .dark,
                                         appearance: entry.appearance)
                content.background(theme.background).clipShape(shape)
            case .tinted, .vibrant, .standBy, .standByNight:
                let (glass, ink) = look.glassAndInk(entry.appearance)
                // A colour takes whatever it is offered, so it is given the widget's size.
                ink.frame(width: size.width, height: size.height).mask { content }.background(glass).clipShape(shape)
            }
        }
    }

    private func isAccessory(_ family: WidgetFamily) -> Bool {
        #if os(iOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        #else
        false
        #endif
    }

    private func isCircular(_ family: WidgetFamily) -> Bool {
        #if os(iOS)
        family == .accessoryCircular
        #else
        false
        #endif
    }

    private func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extra-large"
        case .systemExtraLargePortrait: "extra-large-portrait"
        #if os(iOS)
        case .accessoryCircular: "circular"
        case .accessoryRectangular: "rectangular"
        case .accessoryInline: "inline"
        #endif
        default: "\(family)"
        }
    }

    private func variantName(_ content: LargeWidgetContent) -> String {
        switch content {
        case .map: "map"
        case .laterBuses: "later"
        }
    }

    private func png(_ view: some View, scale: CGFloat, colorScheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: Shots

    /// A watch face draws its complications vibrant or in full colour, whatever the appearance.
    private static let watchLooks: [(Appearance, Look, String)] = [(.dark, .vibrant, "vibrant"), (.dark, .fullColor, "color")]

    #if os(iOS)
    /// The watch's corner: its glyph, and under it the label the face curves along the bezel,
    /// which only a watch can draw curved.
    private func corner(_ entry: NextBusEntry, look: Look) -> some View {
        let view = AccessoryCornerView(entry: entry)
        return VStack(spacing: 4) {
            view.frame(width: Device.cornerSize.width, height: Device.cornerSize.height)
            Text(verbatim: view.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .modifier(WidgetEnvironment(appearance: .dark))
        .environment(\.widgetRenderingMode, look.renderingMode)
        .foregroundStyle(.white)
        .fixedSize()
    }
    #endif

    @Test(.enabled(if: device != nil, "Set WIDGET_SHOTS to iphone, ipad, mac or watch"))
    func everyWidget() throws {
        let device = try #require(Self.device)
        // The frozen 9:41 and every time on a widget are read in the zone the script pins.
        #expect(TimeZone.current.identifier == "Asia/Jerusalem", "run with TZ=Asia/Jerusalem")
        var count = 0
        for language in Self.languages {
            try AppLanguage.$pinned.withValue(language) {
                for (family, size) in device.families {
                    let lock = isAccessory(family)
                    // The lock screen is vibrant whatever the appearance: those are drawn once.
                    var looks: [(Appearance, Look, String)] = device == .watch ? Self.watchLooks : lock
                        ? [(.dark, .vibrant, "lock")]
                        : Self.appearances.flatMap { appearance in
                            [(appearance, Look.fullColor, appearance.rawValue),
                             (appearance, device.monochromeLook, "\(appearance.rawValue)-\(device.monochromeLook.rawValue)")]
                        }
                    // StandBy shows the iPhone's small widget, dark whatever the appearance.
                    if device == .iphone, family == .systemSmall {
                        looks += [(.dark, .standBy, "standby"), (.dark, .standByNight, "standby-night")]
                    }
                    // What goes with the readout is the rider's choice on the large sizes.
                    let contentChoices: [LargeWidgetContent] =
                        [.systemLarge, .systemExtraLarge, .systemExtraLargePortrait].contains(family)
                        ? LargeWidgetContent.allCases : [.map]
                    for (appearance, look, lookName) in looks {
                        for scene in Scene.allCases {
                            let choices = scene.fetchedAgo == nil ? [LargeWidgetContent.map] : contentChoices
                            for content in choices {
                                let variant = choices.count > 1 ? "-\(variantName(content))" : ""
                                let file = [familyName(family), device.caseSize(size)].compactMap { $0 }.joined(separator: "-")
                                let name = "\(language)+\(lookName)+\(file)-\(scene.name)\(variant).png"
                                let entry = entry(scene, family: family, content: content, appearance: appearance)
                                let view = framed(entry, family: family, size: size, look: look, device: device)
                                let scale = device.scale * (look.isStandBy ? Device.standByScale : 1)
                                let data = try png(view, scale: scale, colorScheme: appearance.colorScheme ?? .dark)
                                Attachment.record(data, named: name)
                                count += 1
                            }
                        }
                    }
                }
                #if os(iOS)
                if device == .watch {
                    for (_, look, lookName) in Self.watchLooks {
                        for scene in Scene.allCases {
                            let entry = entry(scene, family: .systemSmall, content: .laterBuses, appearance: .dark)
                            let data = try png(corner(entry, look: look), scale: device.scale, colorScheme: .dark)
                            Attachment.record(data, named: "\(language)+\(lookName)+corner-\(scene.name).png")
                            count += 1
                        }
                    }
                }
                #endif
            }
        }
        #expect(count > 0)
    }
}
