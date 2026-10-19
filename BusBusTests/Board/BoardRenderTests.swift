import Testing
import SwiftUI
import Foundation
import CoreGraphics
import CoreLocation
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
@testable import BusBus

/// Renders the real board to an image and then reads its pixels. This is the check a unit test on
/// the engine cannot make: that the whole SwiftUI composition actually lays out and draws. The PNGs
/// are written to BUSBUS_RENDER_DIR when it is set, so they can also be compared against the
/// artboards by eye.
@MainActor
struct BoardRenderTests {

    /// The rendered board, as colours that can be asked questions.
    private struct Raster {
        var width: Int
        var height: Int
        /// Points to pixels: every render is drawn at 2×.
        var scale: CGFloat
        private var bytes: [UInt8]

        init?(_ image: CGImage, scale: CGFloat) {
            width = image.width
            height = image.height
            self.scale = scale
            let info = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let raw = context.data else { return nil }
            bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: width * height * 4))
        }

        func color(x: Int, y: Int) -> UInt32 {
            let offset = (y * width + x) * 4
            return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
        }

        /// Every distinct colour in a horizontal band, given in points.
        func colors(fromY: CGFloat, toY: CGFloat) -> Set<UInt32> {
            var found: Set<UInt32> = []
            for y in stride(from: max(0, Int(fromY * scale)), to: min(height, Int(toY * scale)), by: 2) {
                for x in stride(from: 0, to: width, by: 2) { found.insert(color(x: x, y: y)) }
            }
            return found
        }

        /// How many sampled pixels in a band are exactly this colour, across the whole width or, given
        /// `columns` in points, across only those.
        func count(of color: UInt32, fromY: CGFloat, toY: CGFloat, columns: Range<CGFloat>? = nil) -> Int {
            let fromX = columns.map { max(0, Int($0.lowerBound * scale)) } ?? 0
            let toX = columns.map { min(width, Int($0.upperBound * scale)) } ?? width
            var total = 0
            for y in stride(from: max(0, Int(fromY * scale)), to: min(height, Int(toY * scale)), by: 2) {
                for x in stride(from: fromX, to: toX, by: 2) where self.color(x: x, y: y) == color { total += 1 }
            }
            return total
        }

        /// Where along a row, in points, pixels of this colour are.
        func xs(of color: UInt32, atY y: CGFloat) -> [CGFloat] {
            let row = Int(y * scale)
            guard row >= 0, row < height else { return [] }
            return stride(from: 0, to: width, by: 1).filter { self.color(x: $0, y: row) == color }
                .map { CGFloat($0) / scale }
        }

        /// The colour that covers most of a band — the ground it is drawn on.
        func dominantColor(fromY: CGFloat, toY: CGFloat) -> UInt32 {
            var counts: [UInt32: Int] = [:]
            for y in stride(from: max(0, Int(fromY * scale)), to: min(height, Int(toY * scale)), by: 2) {
                for x in stride(from: 0, to: width, by: 2) { counts[color(x: x, y: y), default: 0] += 1 }
            }
            return counts.max { $0.value < $1.value }?.key ?? 0
        }
    }

    private static func makeModel(scenario: MockScenario, lineIDs: [String],
                                  trunk: String? = nil,
                                  health: ServiceHealthMonitor = .shared) async -> BoardViewModel {
        let defaults = UserDefaults(suiteName: "render-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerID = "mock"
        settings.mockScenario = scenario

        let provider = settings.provider
        let stop = try! await provider.searchStops(query: MapFixtures.user).first!
        let all = try! await provider.lines(atStop: stop)
        let lines = lineIDs.compactMap { id in all.first { $0.id == id } }
        settings.apply(stop: stop, lines: lines, providerID: "mock")

        let model = BoardViewModel(settings: settings, cache: TransitCache(directory: Self.temporaryDirectory()),
                                   health: health)
        // Promoted before the first fetch: afterwards the trunk's own half-minute settle window
        // would hold the change back, which is the behaviour the board wants and the test does not.
        if let trunk { model.promoteTrunk(trunk) }
        await model.refresh()
        return model
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("render-cache-\(UUID().uuidString)")
    }

    /// Points to pixels, on every platform and whatever the simulator's own screen is.
    private static let renderScale: CGFloat = 2

    private static func render(_ view: some View, size: CGSize, name: String) -> Raster? {
        guard let image = snapshot(view, size: size) else { return nil }
        let directory = ProcessInfo.processInfo.environment["BUSBUS_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("busbus-renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return Raster(image, scale: renderScale)
    }

    #if canImport(UIKit)
    /// Drawn the way the screen draws it: hosted in a window of the app the tests run inside, laid
    /// out, and snapshotted. `ImageRenderer` cannot stand in here — it draws a scroll view as its
    /// background alone, and the board and the stop list both sit in one, so it drew them as a
    /// single flat colour.
    ///
    /// The view is given no safe area and the traits `ImageRenderer` used to hand over — light,
    /// the default text size, no size class — so a render depends on the view and the environment
    /// the test gives it, not on the simulator's settings. It is drawn once, before anything can
    /// animate: an `.onAppear` or `.task` only runs after the render has been taken.
    private static func snapshot(_ view: some View, size: CGSize) -> CGImage? {
        let root = view
            .environment(\.horizontalSizeClass, nil)
            .environment(\.verticalSizeClass, nil)
            // This window lies under the app's status bar whatever its insets are made to say, so a
            // scroll view at its top — the board's own — draws the bar's edge effect, a blur, over
            // the header. On a screen the board sits inside the safe area and there is none.
            .scrollEdgeEffectHidden(true, for: .top)
            .frame(width: size.width, height: size.height)
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let host = UIHostingController(rootView: root)
        host.traitOverrides.userInterfaceStyle = .light
        host.traitOverrides.preferredContentSizeCategory = .large
        host.traitOverrides.layoutDirection = .leftToRight

        let wereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(wereEnabled)
            window.isHidden = true
            window.rootViewController = nil
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        // The status bar's and the home indicator's reservations, taken back off: the tests lay
        // their views out edge to edge, as `ImageRenderer` did.
        let inset = window.safeAreaInsets
        host.additionalSafeAreaInsets = UIEdgeInsets(top: -inset.top, left: -inset.left,
                                                     bottom: -inset.bottom, right: -inset.right)
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        // Plain sRGB, so a colour reads back as the exact value the palette gives it.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        return image.cgImage
    }
    #else
    /// The Mac's counterpart: hosted in a window of its own, laid out and cached, since
    /// `ImageRenderer` draws a scroll view as its background alone here too. The window is never
    /// shown; light, and drawn once before anything can animate, as on iOS.
    private static func snapshot(_ view: some View, size: CGSize) -> CGImage? {
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        // Drawn straight into plain sRGB, so a colour reads back as the exact value the palette gives
        // it; converting afterwards rounds some of them a step off.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * renderScale),
                                         pixelsHigh: Int(size.height * renderScale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB)
        else { return nil }
        rep.size = size
        host.cacheDisplay(in: frame, to: rep)
        return rep.cgImage
    }
    #endif

    /// What a rendered board has to show before it can be called one: more than a single flat
    /// colour, the rail of every watched line somewhere inside the map, and one ground under both the
    /// map and the readout.
    private static func expectBoard(_ view: some View, size: CGSize, name: String,
                                    model: BoardViewModel, isLight: Bool = false,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        guard let raster = render(view, size: size, name: name) else {
            Issue.record("\(name) did not render", sourceLocation: sourceLocation)
            return
        }
        let layout = BoardLayout.resolve(size: size, lineCount: model.lines.count)
        let mapTop = layout.headerHeight
        let mapBottom = layout.headerHeight + layout.mapSize.height

        let whole = raster.colors(fromY: 0, toY: size.height)
        #expect(whole.count > 1, "\(name) is a single flat colour", sourceLocation: sourceLocation)

        let inMap = raster.colors(fromY: mapTop, toY: mapBottom)
        let palette = isLight ? LinePalette.lightRail : LinePalette.darkRail
        for line in model.lines {
            #expect(inMap.contains(palette[LinePalette.wrap(model.colorIndex(line.id))]),
                    "\(name): no rail drawn for line \(line.shortName)", sourceLocation: sourceLocation)
        }

        let map = raster.dominantColor(fromY: mapTop, toY: mapBottom)
        let band = raster.dominantColor(fromY: mapBottom, toY: size.height)
        #expect(map == band, "\(name): the readout sits on a different ground from the map",
                sourceLocation: sourceLocation)
    }

    @Test func landscapeBoardRenders() async {
        let model = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"])
        #expect(model.snapshot.patterns.count == 3)
        #expect(!model.snapshot.buses.isEmpty)
        Self.expectBoard(BoardView(model: model) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 1280, height: 720), name: "Main", model: model)
    }

    @Test func mergeScenariosRender() async {
        // Merge B is the only artboard with two junctions at different points along the trunk, and
        // it only has them when 41 is the trunk — so the render pins it rather than taking whichever
        // line happens to be arriving first.
        for scenario in [MockScenario.mergeA, .mergeB, .mergeC] {
            let model = await Self.makeModel(scenario: scenario, lineIDs: ["18", "41", "7"],
                                             trunk: scenario == .mergeB ? "41" : nil)
            if scenario == .mergeB { #expect(model.trunkLineID == "41") }
            Self.expectBoard(BoardView(model: model) {}.environment(\.colorScheme, .dark),
                             size: CGSize(width: 1280, height: 720), name: scenario.rawValue, model: model)
        }
    }

    @Test func singleLineRenders() async {
        let model = await Self.makeModel(scenario: .main, lineIDs: ["41"])
        Self.expectBoard(BoardView(model: model) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 1280, height: 720), name: "SingleLine", model: model)
    }

    /// A Mac window well under the reference board. Everything shrinks together here, which is how
    /// the supporting text ended up too small to read.
    @Test func smallLandscapeWindowRenders() async {
        let model = await Self.makeModel(scenario: .mergeB, lineIDs: ["18", "41", "7"])
        #expect(Self.render(BoardView(model: model) {}.environment(\.colorScheme, .light),
                            size: CGSize(width: 1000, height: 460), name: "SmallWindow") != nil)
    }

    @Test func lightThemeRenders() async {
        let model = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"])
        Self.expectBoard(BoardView(model: model) {}.environment(\.colorScheme, .light),
                         size: CGSize(width: 1280, height: 720), name: "MainLight",
                         model: model, isLight: true)
    }

    @Test func portraitBoardsRender() async {
        let three = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"])
        Self.expectBoard(BoardView(model: three) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 390, height: 844), name: "PhonePortrait", model: three)
        Self.expectBoard(BoardView(model: three) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 834, height: 1194), name: "PadPortrait", model: three)

        let two = await Self.makeModel(scenario: .main, lineIDs: ["18", "41"])
        Self.expectBoard(BoardView(model: two) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 390, height: 844), name: "PhoneTwoLines", model: two)

        let one = await Self.makeModel(scenario: .main, lineIDs: ["41"])
        Self.expectBoard(BoardView(model: one) {}.environment(\.colorScheme, .dark),
                         size: CGSize(width: 390, height: 844), name: "PhoneOneLine", model: one)
    }

    /// A tapped bus in portrait opens in the readout, as it does in landscape, rather than in a
    /// sheet over the board: the card's outline, in the tapped line's colour, is drawn below the map.
    @Test func tappedBusInPortraitRenders() async {
        let model = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"])
        model.settings.tapBehaviourOverride = .beside
        // Line 7 runs behind its timetable in the mock, so the card carries the delay badge too.
        let bus = model.snapshot.buses.first { $0.lineID == "7" && $0.id != model.primary?.arrival.bus?.id }!
        model.tap(busID: bus.id)
        let detail = try! #require(model.tappedDetail)
        for scheme in [ColorScheme.dark, .light] {
            let palette = scheme == .light ? LinePalette.lightRail : LinePalette.darkRail
            let outline = palette[LinePalette.wrap(detail.colorIndex)]
            for (size, name) in [(CGSize(width: 390, height: 844), "PhoneTapped"),
                                 (CGSize(width: 834, height: 1194), "PadTapped")] {
                let name = name + (scheme == .light ? "Light" : "")
                guard let raster = Self.render(BoardView(model: model) {}.environment(\.colorScheme, scheme),
                                               size: size, name: name) else {
                    Issue.record("\(name) did not render")
                    continue
                }
                let layout = BoardLayout.resolve(size: size, lineCount: model.lines.count)
                let readoutTop = layout.headerHeight + layout.mapSize.height
                #expect(raster.colors(fromY: readoutTop, toY: size.height).contains(outline),
                        "\(name): the tapped card is not in the readout")
            }
        }
    }

    @Test func setupScreensRender() async {
        let defaults = UserDefaults(suiteName: "render-setup-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerID = "mock"
        let model = SetupViewModel(settings: settings)
        // Seeded so the rows and the grid have something to draw: an empty screen proves nothing.
        let stop = try! await settings.provider.searchStops(query: MapFixtures.user).first!
        model.query = MapFixtures.user
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!model.results.isEmpty)
        #expect(Self.render(StopSearchView(model: model)
                                .environment(\.colorScheme, .dark),
                            size: CGSize(width: 1280, height: 720), name: "StopSearch") != nil)

        await model.choose(stop)
        // Every slot taken, so the muted state of the lines you cannot add is on screen too.
        for line in model.linesAtStop { model.toggle(line) }
        #expect(model.isFull)
        #expect(Self.render(LinePickerView(model: model, onConfirm: {}).environment(\.colorScheme, .dark),
                            size: CGSize(width: 1280, height: 720), name: "LinePicker") != nil)
        #expect(Self.render(LinePickerView(model: model, onConfirm: {}).environment(\.colorScheme, .dark),
                            size: CGSize(width: 390, height: 844), name: "LinePickerPhone") != nil)

        // The stop just set up, saved: the home has a row to draw, in the centred column and on a phone.
        model.confirm()
        #expect(!model.history.isEmpty)
        for (size, name) in [(CGSize(width: 1280, height: 720), "MyStops"), (CGSize(width: 390, height: 844), "MyStopsPhone")] {
            #expect(Self.render(MyStopsView(model: model, onOpenSettings: {}, onResume: { _ in })
                                    .environment(\.colorScheme, .dark),
                                size: size, name: name) != nil)
        }

    }

    /// A stop with more lines than the confirm panel has room for: under the map the panel stops at
    /// its cap and the list scrolls inside it, the buttons still at its foot; beside the map the list
    /// fills the column. Written out for a look as well as drawn.
    @Test func confirmPanelWithManyLinesRenders() async {
        let defaults = UserDefaults(suiteName: "render-confirm-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerID = "mock"
        let model = SetupViewModel(settings: settings)
        model.openSearch()
        let lines = (1...14).map { TransitLine(id: "\($0)", shortName: "\($0 * 7)", destination: "TERMINAL \($0)") }
        let entry = NearbyStop(stop: TransitStop(code: "41122", name: "Dizengoff Center", city: "Tel Aviv",
                                                 location: GeoPoint(lat: 32.075, lon: 34.775)),
                               distanceMeters: 90, lines: lines)
        await model.beginConfirm(entry, restore: SearchRestore(drawer: .medium, scrolledToStopID: nil, camera: nil))
        for (size, name) in [(CGSize(width: 390, height: 844), "ConfirmManyLinesPhone"),
                             (CGSize(width: 1280, height: 720), "ConfirmManyLines")] {
            #expect(Self.render(StopSearchView(model: model).environment(\.colorScheme, .dark),
                                size: size, name: name) != nil)
        }
    }

    /// The feed is down, the device is offline, or the provider is switched off: the board gives way
    /// to a screen of its own, in every layout and both directions, and draws none of the map.
    @Test func serviceDownScreensRender() async {
        let health = ServiceHealthMonitor(reporter: .silent)
        #if DEBUG
        health.simulatedOutage = nil
        #endif
        let model = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"], health: health)
        for _ in 0..<ServiceHealth.outageThreshold {
            health.recordFailure(providerID: "mock", endpoint: "refresh", error: TransitError.badResponse("HTTP 503"))
        }
        #expect(model.serviceStatus.replacesBoard)

        // The accent defaults to Theme.dark.late; the foot of the screen is the readout band.
        let band: UInt32 = 0x08080B
        func expectDown(_ view: some View, size: CGSize, name: String, accent: UInt32? = 0xFF3B3F,
                        sourceLocation: SourceLocation = #_sourceLocation) {
            guard let raster = Self.render(view, size: size, name: name) else {
                Issue.record("\(name) did not render", sourceLocation: sourceLocation)
                return
            }
            let colors = raster.colors(fromY: 0, toY: size.height)
            #expect(colors.count > 2, "\(name) is blank", sourceLocation: sourceLocation)
            // Line 1's rail is the same red as the status accent, so it cannot testify.
            #expect(colors.isDisjoint(with: LinePalette.darkRail.dropFirst()),
                    "\(name) still draws the map", sourceLocation: sourceLocation)
            if let accent {
                #expect(colors.contains(accent), "\(name) lacks its status colour",
                        sourceLocation: sourceLocation)
            }
            // The band at the foot, where CHANGE STOP sits, is the readout band's colour.
            #expect(raster.dominantColor(fromY: size.height - 20, toY: size.height) == band,
                    "\(name) has no band", sourceLocation: sourceLocation)
        }
        func board() -> some View { BoardView(model: model) {}.environment(\.colorScheme, .dark) }

        expectDown(board(), size: CGSize(width: 1280, height: 720), name: "ServiceDown-Landscape")
        expectDown(board(), size: CGSize(width: 390, height: 844), name: "ServiceDown-Phone")
        expectDown(board(), size: CGSize(width: 834, height: 1194), name: "ServiceDown-Pad")
        expectDown(board().environment(\.layoutDirection, .rightToLeft).environment(\.locale, Locale(identifier: "he")),
                   size: CGSize(width: 390, height: 844), name: "ServiceDown-RTL-he")

        // With a message from the console under it.
        expectDown(ServiceDownView(layout: BoardLayout.resolve(size: CGSize(width: 390, height: 844), lineCount: 3),
                                   status: .down(since: .now), serviceName: "Israel · bus.gov.il",
                                   lastSuccessAt: Date().addingTimeInterval(-7200),
                                   statusMessage: "bus.gov.il stopped answering at 14:05. We're on it.",
                                   onChangeStop: {}, onSettings: {})
                    .background(Theme.dark.background).environment(\.theme, .dark),
                   size: CGSize(width: 390, height: 844), name: "ServiceDown-Message")

        health.setOnline(false)
        #expect(model.serviceStatus == .offline)
        expectDown(board(), size: CGSize(width: 1280, height: 720), name: "ServiceDown-Offline", accent: nil)

        health.setOnline(true)
        model.settings.regionIsAvailable = { _ in false }
        #expect(model.serviceStatus == .disabled)
        expectDown(board(), size: CGSize(width: 390, height: 844), name: "ServiceDown-Disabled", accent: nil)
    }

    /// The welcome story, every page, on a phone, a small phone, an iPad and a phone on its side, in
    /// both appearances. Held on its resting frames so every run draws the same thing.
    @Test func welcomeStoryRenders() {
        let sizes: [(CGSize, String)] = [(CGSize(width: 390, height: 844), "Phone"),
                                         (CGSize(width: 375, height: 667), "SmallPhone"),
                                         (CGSize(width: 834, height: 1194), "Pad"),
                                         (CGSize(width: 844, height: 390), "PhoneLandscape")]
        for page in WelcomePage.allCases {
            for (size, sizeName) in sizes {
                for scheme in [ColorScheme.dark, .light] {
                    let name = "Welcome\(page.rawValue + 1)-\(sizeName)" + (scheme == .light ? "-Light" : "")
                    let story = WelcomeStoryView(model: WelcomeStoryModel(page: page), holdsStill: true) { _ in }
                        .environment(\.colorScheme, scheme)
                    guard let raster = Self.render(story, size: size, name: name) else {
                        Issue.record("\(name) did not render")
                        continue
                    }
                    let colors = raster.colors(fromY: 0, toY: size.height)
                    #expect(colors.count > 2, "\(name) is blank")
                    let ground: UInt32 = scheme == .light ? 0xF4F2EC : 0x08080B
                    #expect(raster.dominantColor(fromY: 0, toY: size.height) == ground || page == .wall,
                            "\(name) is not on the board's ground")
                    let rails = scheme == .light ? LinePalette.lightRail : LinePalette.darkRail
                    switch page {
                    case .map:
                        #expect(colors.contains(rails[0]) && colors.contains(rails[1]), "\(name) lacks lines 18 and 41")
                    case .wall:
                        // The room is the same dark picture in both appearances, lit by line 41's amber.
                        #expect(colors.contains(0x0D0D12), "\(name) lacks its room")
                    case .nearby:
                        #expect(colors.contains(rails[1]), "\(name) lacks the nearest stop's chip")
                    }
                }
            }
        }

        // On the artboard's own phone, the map sits in its art band, under the counter and above the words.
        let map = Self.render(WelcomeStoryView(model: WelcomeStoryModel(page: .map), holdsStill: true) { _ in }
                                .environment(\.colorScheme, .dark),
                              size: CGSize(width: 390, height: 844), name: "Welcome1-Band")
        let band = map?.colors(fromY: 72, toY: 72 + 420) ?? []
        #expect(band.contains(LinePalette.darkRail[0]) && band.contains(LinePalette.darkRail[1]))
        let nearby = Self.render(WelcomeStoryView(model: WelcomeStoryModel(page: .nearby), holdsStill: true) { _ in }
                                   .environment(\.colorScheme, .dark),
                                 size: CGSize(width: 390, height: 844), name: "Welcome3-Band")
        #expect(nearby?.colors(fromY: 72, toY: 72 + 420).contains(LinePalette.darkRail[1]) == true)
    }

    @Test(arguments: ["he", "ar"])
    func welcomeStoryRendersRightToLeft(_ code: String) {
        for page in WelcomePage.allCases {
            let story = WelcomeStoryView(model: WelcomeStoryModel(page: page), holdsStill: true) { _ in }
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: code))
                .environment(\.colorScheme, .dark)
            let raster = Self.render(story, size: CGSize(width: 390, height: 844),
                                     name: "RTL-\(code)-Welcome\(page.rawValue + 1)")
            #expect((raster?.colors(fromY: 0, toY: 844).count ?? 0) > 2, "\(code) page \(page.rawValue + 1) is blank")
        }
    }

    /// Each page's picture caught partway through its build in and its build out, side by side, in
    /// both reading directions: pages 1 and 2 mirror, page 3 does not. Drawn from the timeline at
    /// fixed moments, so the frames are the same on every run.
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func welcomeBuildsRender(_ direction: LayoutDirection) {
        // (seconds into the page, seconds into its build out)
        let moments: [WelcomePage: [(Double, Double?)]] = [
            .map: [(0.45, nil), (1.0, nil), (8.7, 0.2), (8.85, 0.35)],
            .wall: [(0.3, nil), (1.3, nil), (8.15, 0.15), (8.3, 0.3)],
            .nearby: [(0.45, nil), (0.85, nil), (4.15, 0.15), (4.3, 0.3)],
        ]
        let cell = CGSize(width: 390, height: 440)
        for page in WelcomePage.allCases {
            let frames = moments[page] ?? []
            let strip = HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { index in
                    let (t, leaving) = frames[index]
                    Group {
                        switch page {
                        case .map: WelcomeMapArt(frame: WelcomeTimeline.map(at: t, leaving: leaving, still: false), scale: 1)
                        case .wall: WelcomeWallArt(frame: WelcomeTimeline.wall(at: t, leaving: leaving, still: false), scale: 1)
                        case .nearby:
                            WelcomeNearbyArt(frame: WelcomeTimeline.nearby(at: t, leaving: leaving, still: false), scale: 1)
                        }
                    }
                    .frame(width: cell.width, height: cell.height)
                }
            }
            .background(Theme.dark.background)
            .busTheme()
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, direction)
            let name = "WelcomeBuild\(page.rawValue + 1)-" + (direction == .rightToLeft ? "RTL" : "LTR")
            let size = CGSize(width: cell.width * CGFloat(frames.count), height: cell.height)
            guard let raster = Self.render(strip, size: size, name: name) else {
                Issue.record("\(name) did not render")
                continue
            }
            #expect(raster.colors(fromY: 0, toY: size.height).count > 2, "\(name) is blank")
            guard page == .map else { continue }
            // The rails are drawn down from their termini and pulled back up into them: less of them
            // shows partway through each build than further on in it.
            func rail(_ index: Int) -> Int {
                let slot = direction == .rightToLeft ? frames.count - 1 - index : index
                let columns = CGFloat(slot) * cell.width ..< CGFloat(slot + 1) * cell.width
                return LinePalette.darkRail.prefix(2).reduce(0) {
                    $0 + raster.count(of: $1, fromY: 0, toY: size.height, columns: columns)
                }
            }
            #expect(rail(0) < rail(1), "\(name): the rails are not drawn in")
            #expect(rail(3) < rail(2), "\(name): the rails are not pulled back")
            #expect(rail(3) > 0, "\(name): the termini are gone too soon")
        }
    }

    /// The first board's tip: the inverted surface in both appearances, its arrow on the leading
    /// side, under the stop name, whichever way the language reads. Drawn on its own, so the arrow
    /// can be found against a known ground.
    @Test func setupTipRenders() {
        let size = CGSize(width: 390, height: 160)
        func tip(_ scheme: ColorScheme, _ direction: LayoutDirection) -> some View {
            SetupTipView(stopName: "Harbor Gate", compact: true, scale: 1) {}
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.resolve(scheme).background)
                .busTheme()
                .environment(\.colorScheme, scheme)
                .environment(\.layoutDirection, direction)
        }
        for scheme in [ColorScheme.dark, .light] {
            let surface: UInt32 = scheme == .light ? 0x14140F : 0xFFFFFF
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let name = "SetupTip" + (scheme == .light ? "-Light" : "") + (direction == .rightToLeft ? "-RTL" : "")
                guard let raster = Self.render(tip(scheme, direction), size: size, name: name) else {
                    Issue.record("\(name) did not render")
                    continue
                }
                #expect(raster.count(of: surface, fromY: 20, toY: 100) > 4000, "\(name) has no card")
                // Just above the card only the arrow is drawn: near the leading edge.
                let arrow = raster.xs(of: surface, atY: 15)
                #expect(!arrow.isEmpty, "\(name) has no arrow")
                if direction == .leftToRight {
                    #expect(arrow.allSatisfy { $0 < size.width / 3 }, "\(name): the arrow is not on the left")
                } else {
                    #expect(arrow.allSatisfy { $0 > size.width * 2 / 3 }, "\(name): the arrow is not on the right")
                }
            }
        }
    }

    /// The search drawer with location off: the card in both appearances, right to left, on a phone
    /// and in the wide layout's side panel, and without its Settings button when the device's owner
    /// turned location off. The real search screen, with Core Location standing in to give its
    /// answer.
    @Test func locationDeniedCardRenders() async {
        struct Case {
            var name: String
            var scheme: ColorScheme = .dark
            var direction: LayoutDirection = .leftToRight
            var locale = "en"
            var restricted = false
            var compact = true
        }
        let cases = [
            Case(name: "LocationDenied-Phone"),
            Case(name: "LocationDenied-Phone-Light", scheme: .light),
            Case(name: "LocationDenied-Phone-RTL-he", direction: .rightToLeft, locale: "he"),
            Case(name: "LocationRestricted-Phone", restricted: true),
            Case(name: "LocationDenied-Wide-Light", scheme: .light, compact: false),
        ]
        for item in cases {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "render-denied-\(UUID().uuidString)")!)
            settings.providerID = "mock"
            let answer: CLAuthorizationStatus = item.restricted ? .restricted : .denied
            let location = LocationService(source: LocationService.Source(status: { answer },
                                                                          requestPermission: {},
                                                                          fix: { _ in nil }))
            let model = SetupViewModel(settings: settings, location: location)
            await model.loadNearby()
            #expect(model.nearbyState == (item.restricted ? .restricted : .denied))

            let size = item.compact ? CGSize(width: 390, height: 844) : CGSize(width: 1280, height: 720)
            let view = StopSearchView(model: model)
                .environment(\.colorScheme, item.scheme)
                .environment(\.layoutDirection, item.direction)
                .environment(\.locale, Locale(identifier: item.locale))
            guard let raster = Self.render(view, size: size, name: item.name) else {
                Issue.record("\(item.name) did not render")
                continue
            }
            let yellow = (item.scheme == .light ? LinePalette.lightRail : LinePalette.darkRail)[1]
            let button = raster.count(of: yellow, fromY: 0, toY: size.height)
            if item.restricted {
                #expect(button == 0, "\(item.name): a Settings button the rider cannot use")
            } else {
                // The button's fill, not just the pin: a 58 pt bar most of the column wide.
                #expect(button > 4000, "\(item.name) has no OPEN SETTINGS button")
            }
            if item.scheme == .dark {
                #expect(raster.count(of: 0x15151B, fromY: 0, toY: size.height) > 2000, "\(item.name) has no card")
            }
        }
    }

    /// Hebrew and Arabic are chosen in Settings as often as they are the device's language, so the
    /// whole flow is drawn right to left the way the root applies it: mirrored layout, RTL locale.
    @Test(arguments: ["he", "ar"])
    func rightToLeftScreensRender(_ code: String) async {
        // The root sets both halves of the language: SwiftUI's locale for `Text`, and the app's own
        // for strings built in code (NEXT ARRIVAL, ARRIVES, LIVE). Pinned here too, or the board
        // would draw those in whatever language the test runner happens to be in.
        await AppLanguage.$pinned.withValue(code) {
            #expect(String(appLocalized: "NEXT ARRIVAL") != "NEXT ARRIVAL")
            await drawRightToLeft(code)
        }
    }

    private func drawRightToLeft(_ code: String) async {
        func rtl(_ view: some View) -> some View {
            view.environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: code))
                .environment(\.colorScheme, .dark)
        }
        let board = await Self.makeModel(scenario: .main, lineIDs: ["18", "41", "7"])
        Self.expectBoard(rtl(BoardView(model: board) {}), size: CGSize(width: 1280, height: 720),
                         name: "RTL-\(code)-Main", model: board)
        Self.expectBoard(rtl(BoardView(model: board) {}), size: CGSize(width: 390, height: 844),
                         name: "RTL-\(code)-PhonePortrait", model: board)

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "render-rtl-\(UUID().uuidString)")!)
        settings.providerID = "mock"
        let model = SetupViewModel(settings: settings)
        let stop = try! await settings.provider.searchStops(query: MapFixtures.user).first!
        model.query = MapFixtures.user
        try? await Task.sleep(for: .milliseconds(500))
        #expect(Self.render(rtl(StopSearchView(model: model)),
                            size: CGSize(width: 390, height: 844), name: "RTL-\(code)-StopSearchPhone") != nil)
        await model.choose(stop)
        for line in model.linesAtStop.prefix(2) { model.toggle(line) }
        #expect(Self.render(rtl(LinePickerView(model: model, onConfirm: {})),
                            size: CGSize(width: 390, height: 844), name: "RTL-\(code)-LinePickerPhone") != nil)
        #expect(Self.render(rtl(LinePickerView(model: model, onConfirm: {})),
                            size: CGSize(width: 1280, height: 720), name: "RTL-\(code)-LinePicker") != nil)
        model.confirm()
        #expect(Self.render(rtl(MyStopsView(model: model, onOpenSettings: {}, onResume: { _ in })),
                            size: CGSize(width: 390, height: 844), name: "RTL-\(code)-MyStopsPhone") != nil)
    }
}

/// Guards the bug the rendered boards exposed: the pattern cache was keyed on the adapter alone,
/// so switching the mock scenario kept serving whichever set of routes was loaded first.
@MainActor
struct TransitCacheTests {

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pattern-cache-\(UUID().uuidString)")
    }

    private static func provider(_ scenario: MockScenario) -> MockTransitProvider {
        var mock = MockTransitProvider()
        mock.scenario = scenario
        return mock
    }

    @Test func scenariosDoNotShareCachedRoutes() async throws {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        let mergeA = Self.provider(.mergeA)
        let mergeC = Self.provider(.mergeC)

        let stop = try #require(await mergeA.searchStops(query: MapFixtures.user).first)
        let line = try #require(await mergeA.lines(atStop: stop).first { $0.id == "41" })
        let patternA = try await cache.pattern(for: line, providerID: mergeA.datasetID) {
            try await mergeA.routePattern(for: line)
        }
        let patternC = try await cache.pattern(for: line, providerID: mergeC.datasetID) {
            try await mergeC.routePattern(for: line)
        }

        #expect(patternA.stops.map(\.stop.code) != patternC.stops.map(\.stop.code))
        #expect(patternA.stops.contains { $0.stop.code == "MILL-JUNCTION" })
        #expect(patternC.stops.contains { $0.stop.code == "WEST-MARKET" })
    }

    @Test func oneDatasetStillHitsTheCache() async throws {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        let mock = MockTransitProvider()
        let stop = try #require(await mock.searchStops(query: MapFixtures.user).first)
        let line = try #require(await mock.lines(atStop: stop).first)
        let fetches = FetchCounter()
        for _ in 0..<3 {
            _ = try await cache.pattern(for: line, providerID: mock.datasetID) {
                await fetches.record()
                return try await mock.routePattern(for: line)
            }
        }
        #expect(await fetches.count == 1)
    }
}

/// Counts network round trips across the concurrent callers the cache is meant to collapse.
private actor FetchCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Counts fetches from inside a sendable closure.
private nonisolated final class FetchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Everything except a bus's current position is timetable data, so it is kept and read back before
/// the network is asked anything.
@MainActor
struct StaticDataCacheTests {

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("static-cache-\(UUID().uuidString)")
    }

    @Test func theLinesAtAStopAreFetchedOnce() async throws {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        let mock = MockTransitProvider()
        let stop = try #require(await mock.searchStops(query: MapFixtures.user).first)
        let fetches = FetchCount()
        for _ in 0..<3 {
            _ = try await cache.lines(atStop: stop, providerID: mock.datasetID) {
                fetches.record()
                return try await mock.lines(atStop: stop)
            }
        }
        #expect(fetches.count == 1)
    }

    @Test func nearbyStopsAreFetchedOncePerPlace() async throws {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        let mock = MockTransitProvider()
        let here = GeoPoint(lat: 32.900, lon: 34.950)
        let elsewhere = GeoPoint(lat: 32.700, lon: 34.800)
        let fetches = FetchCount()
        func load(_ point: GeoPoint) async throws -> [NearbyStop] {
            try await cache.nearby(around: point, radiusMeters: 500, providerID: mock.datasetID) {
                fetches.record()
                return try await mock.stopsNearby(point, radiusMeters: 500)
            }
        }
        _ = try await load(here)
        _ = try await load(here)
        #expect(fetches.count == 1)
        _ = try await load(elsewhere)
        #expect(fetches.count == 2)
    }

    /// A stale route still draws the right shape, which is better than an empty board.
    @Test func aFailedRefreshFallsBackToWhatIsStored() async throws {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        let mock = MockTransitProvider()
        let stop = try #require(await mock.searchStops(query: MapFixtures.user).first)
        let first = try await cache.lines(atStop: stop, providerID: mock.datasetID) {
            try await mock.lines(atStop: stop)
        }
        #expect(!first.isEmpty)

        let again = try await cache.lines(atStop: stop, providerID: mock.datasetID) {
            throw TransitError.badResponse("offline")
        }
        #expect(again.map(\.id) == first.map(\.id))
    }

    @Test func nothingIsServedForAKeyThatWasNeverStored() async {
        let cache = TransitCache(directory: Self.temporaryDirectory())
        #expect(await cache.cachedPattern(for: "41", providerID: "mock.main") == nil)
    }
}
