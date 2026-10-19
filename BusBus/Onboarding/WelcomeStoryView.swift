import SwiftUI

// Not on Apple TV, which opens on the saved stops and has no touch to hold a story with.
#if !os(tvOS)

/// The first-install welcome: three pages that show what the app is before it asks for anything,
/// ending on the one request for location. It turns its own pages, the way a story does, unless
/// Reduce Motion or VoiceOver is on; NEXT and SKIP are always there, and a tap on the leading third
/// of the picture or the words goes back a page and one on the trailing third goes on; a finger
/// held down on them holds the story. On a Mac, clicks do the same, and so do the arrow keys.
/// Each page builds in and builds out, however it is left, except under Reduce Motion, where
/// pages simply cross-fade.
///
/// Laid out in the artboard's 390-point column. Every design measurement is multiplied by one
/// scale, the house way, so text keeps its readable floor and grows with Dynamic Type.
struct WelcomeStoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    /// Resolved here rather than taken from the environment: the story is laid over the stop list
    /// on its own, and a screen that relies on an ancestor for its colours renders dark in silence.
    private var theme: Theme { Theme.resolve(colorScheme) }

    @State private var model: WelcomeStoryModel
    /// Holds the pictures on their resting frame whatever the settings say — for render tests.
    private var holdsStill: Bool
    var onFinish: (WelcomeChoice) -> Void

    init(model: WelcomeStoryModel? = nil, holdsStill: Bool = false,
         onFinish: @escaping (WelcomeChoice) -> Void) {
        _model = State(initialValue: model ?? WelcomeStoryModel())
        self.holdsStill = holdsStill
        self.onFinish = onFinish
    }

    /// The artboard's column and the art box within it.
    private static let designWidth: CGFloat = 390
    private static let artHeight: CGFloat = 420
    /// Past this the column stops widening and is centred: an iPad.
    private static let maxColumnWidth: CGFloat = 440
    private static let maxScale: CGFloat = 1.3
    /// Everything in the portrait column but the art, at the artboard's size.
    private static let chromeHeight: CGFloat = 330

    private var still: Bool { reduceMotion || holdsStill }
    private var autoAdvances: Bool { !holdsStill && WelcomeTimeline.autoAdvances(reduceMotion: reduceMotion, voiceOver: voiceOver) }

    /// A finger down on the picture or the words.
    @GestureState private var pressing = false
    /// When the press under way began, to tell a tap from a hold.
    @State private var pressBegan: Date?
    /// Holds the keyboard, so the arrow keys step through the pages on a Mac or an iPad's keyboard.
    @FocusState private var hasKeyboard: Bool

    /// Whether leaving a page plays its build out first.
    private var buildsOut: Bool { !still }

    /// What arms the page timer: a new page, the page replayed, a build out starting or changing
    /// course, a finger holding the story or letting it go, the app coming back, or the settings
    /// changing.
    private struct TimerKey: Hashable {
        var page: WelcomePage
        var startedAt: Date
        var leaving: WelcomeStoryModel.Leaving?
        var isHeld: Bool
        var isActive: Bool
        var autoAdvances: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let landscape = size.width > size.height && size.height < 560
            Group {
                if landscape { landscapeBody(size: size) } else { portraitBody(size: size) }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(theme.background.ignoresSafeArea())
        .busTheme()
        // The arrow keys page through the story, as a story's taps do: forward is the trailing
        // arrow, so right in English and left in Hebrew and Arabic. The last page has no next;
        // it waits for an answer.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onAppear { hasKeyboard = true }
        .onKeyPress(.rightArrow) { step(forward: layoutDirection == .leftToRight) }
        .onKeyPress(.leftArrow) { step(forward: layoutDirection == .rightToLeft) }
        .task(id: TimerKey(page: model.page, startedAt: model.pageStartedAt, leaving: model.leaving,
                           isHeld: model.heldSince != nil,
                           isActive: scenePhase == .active, autoAdvances: autoAdvances)) {
            guard scenePhase == .active, model.heldSince == nil else { return }
            if let leaving = model.leaving {
                // The page turns when its build out has played.
                let remaining = WelcomeTimeline.buildOutSeconds - Date().timeIntervalSince(leaving.startedAt)
                if remaining > 0 { try? await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
                guard !Task.isCancelled else { return }
                turn { model.finishLeaving() }
                return
            }
            let page = model.page
            guard autoAdvances else { return }
            // Timed from the page's start, not this task's: the task restarts when VoiceOver goes off
            // mid-page, and the page must not be given its whole time again.
            let delay = page.buildOutAfter - .milliseconds(Int(elapsed(at: Date()) * 1000))
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            // The last page has nothing to turn to: with no answer, it builds out and the story
            // closes onto the stop list, which asks for location again from its NEARBY card.
            if page.next == nil {
                if model.page == page, model.leaving == nil { finish(.timedOut) }
                return
            }
            // NEXT may have turned the page, or started leaving it, before this task was told it is
            // out of date.
            model.next(from: page, animated: true)
        }
        // Pressed, the story holds where it is, as a story does; let go, it runs on.
        .onChange(of: pressing) { _, pressing in
            if pressing { pressBegan = Date(); model.hold() } else { model.release() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from elsewhere, the page starts over rather than being found half-played.
            if phase == .active { model.restartClock() }
        }
        // The last page has built out: the root takes the story away.
        .onChange(of: model.answer) { _, answer in if let answer { onFinish(answer) } }
        // A new page is a new screen to VoiceOver, which starts reading it again from the top.
        .onChange(of: model.page) { AccessibilityNotification.ScreenChanged(nil).post() }
        .analyticsScreen("welcome")
    }

    // MARK: Layouts

    private func portraitBody(size: CGSize) -> some View {
        let column = min(size.width, Self.maxColumnWidth)
        let artRoom = max(200, size.height - Self.chromeHeight)
        let scale = min(Self.maxScale, column / Self.designWidth, artRoom / Self.artHeight)
        // A column narrower than the screen (an iPad) is set as one block in the middle, its buttons
        // under the words. On a phone the column is the screen, and the buttons sit at the foot.
        let composed = size.width > Self.maxColumnWidth
        let content = VStack(alignment: .leading, spacing: 0) {
            chrome(scale: scale)
            art(scale: scale)
                .frame(maxWidth: .infinity)
                .frame(height: Self.artHeight * scale)
                .storyTaps(press)
                .padding(.top, 12 * scale)
            words(scale: scale)
                .storyTaps(press)
                .padding(.top, 20 * scale)
            if composed {
                Color.clear.frame(height: 40 * scale)
            } else {
                Spacer(minLength: 20 * scale)
            }
            buttons(scale: scale)
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(width: column)
        let minHeight = composed ? nil : size.height
        return ViewThatFits(in: .vertical) {
            // Measured at its natural height: it is chosen only if that fits the screen.
            content.frame(minHeight: minHeight)
            // Large Dynamic Type on a small phone: the column scrolls rather than clipping.
            ScrollView {
                content.frame(minHeight: size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A phone on its side: the picture on the leading half, the words and buttons beside it.
    private func landscapeBody(size: CGSize) -> some View {
        let half = (size.width - 40 - 24) / 2
        let artRoom = size.height - 16 - 24 - 56
        let scale = min(Self.maxScale, half / Self.designWidth, artRoom / Self.artHeight)
        return VStack(alignment: .leading, spacing: 0) {
            chrome(scale: 1)
            HStack(alignment: .top, spacing: 24) {
                art(scale: scale)
                    .frame(width: half, height: Self.artHeight * scale)
                    .storyTaps(press)
                let side = VStack(alignment: .leading, spacing: 20) {
                    words(scale: max(scale, 0.8))
                    buttons(scale: max(scale, 0.8))
                }
                // Scrolls only when large Dynamic Type needs it to.
                ViewThatFits(in: .vertical) {
                    side
                    ScrollView { side }
                }
                .frame(width: half)
            }
            .padding(.top, 12)
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: Pieces

    /// Progress bars, the page counter and SKIP.
    private func chrome(scale: CGFloat) -> some View {
        VStack(spacing: 12) {
            let barsMove = !still && autoAdvances && scenePhase == .active && model.heldSince == nil
            TimelineView(StoryFrames(fps: 30, until: barsMove ? model.pageStartedAt + model.page.barFillSeconds : nil)) { context in
                let fills = WelcomeTimeline.barFill(page: model.page, elapsed: elapsed(at: context.date),
                                                    still: still || !autoAdvances)
                HStack(spacing: 6) {
                    ForEach(fills.indices, id: \.self) { index in
                        Capsule()
                            .fill(theme.clearButtonBorder)
                            .overlay(alignment: .leading) {
                                GeometryReader { bar in
                                    Capsule()
                                        .fill(theme.primaryText)
                                        .frame(width: bar.size.width * fills[index])
                                }
                            }
                            .clipShape(Capsule())
                    }
                }
                .frame(height: 4)
            }
            .accessibilityHidden(true)

            HStack {
                Text("\(model.page.rawValue + 1) / \(WelcomePage.allCases.count)")
                    .busText(TypeStyles.storyCaption, scale: scale)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel(Text("Page \(model.page.rawValue + 1) of \(WelcomePage.allCases.count)"))
                Spacer()
                if model.page != .nearby {
                    Button { turn { model.skip(animated: buildsOut) } } label: {
                        Text("SKIP")
                            .busText(TypeStyles.storyCaption, scale: scale)
                            .foregroundStyle(theme.secondaryText)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Skip to finding stops near you"))
                }
            }
            .frame(height: 28)
        }
    }

    /// The page's picture, played from when the page began, and built out once it is being left.
    private func art(scale: CGFloat) -> some View {
        TimelineView(StoryFrames(fps: 60, until: artMovesUntil)) { context in
            let t = elapsed(at: context.date)
            let leaving = leavingElapsed(at: context.date)
            switch model.page {
            case .map:
                WelcomeMapArt(frame: WelcomeTimeline.map(at: t, leaving: leaving, still: still), scale: scale)
            case .wall:
                WelcomeWallArt(frame: WelcomeTimeline.wall(at: t, leaving: leaving, still: still), scale: scale)
            case .nearby:
                WelcomeNearbyArt(frame: WelcomeTimeline.nearby(at: t, leaving: leaving, still: still), scale: scale)
            }
        }
        // The tap at the leading edge, for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Previous page"), goBack)
    }

    /// The page's title and message, rising in with the picture and rising away with it.
    private func words(scale: CGFloat) -> some View {
        TimelineView(StoryFrames(fps: 60, until: wordsMoveUntil)) { context in
            let frame = WelcomeTimeline.words(at: elapsed(at: context.date), leaving: leavingElapsed(at: context.date),
                                              still: still)
            wordsBlock(scale: scale)
                .opacity(frame.opacity)
                .offset(y: frame.offsetY * scale)
        }
        .id(model.page)
        // Under Reduce Motion the words don't move; they cross-fade as the page turns.
        .transition(.opacity)
    }

    private func wordsBlock(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text(title)
                .busText(TypeStyles.storyTitle, scale: scale)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .busText(TypeStyles.permissionBody, scale: scale)
                .foregroundStyle(theme.captionText)
                .lineSpacing(5 * scale)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: LocalizedStringKey {
        switch model.page {
        case .map: "Every bus to your stop, live."
        case .wall: "Made for the old iPhone in your drawer."
        case .nearby: "Find stops near you."
        }
    }

    private var message: LocalizedStringKey {
        switch model.page {
        case .map: "See where each bus is on its line, and exactly how many minutes until it reaches you."
        case .wall: "Hang an old iPhone or iPad by the door: plugged in, always on, readable from across the room. Works in your hand too."
        case .nearby: "Allow location to list the stops within 500 m, closest first. It's only used to find them, and never stored."
        }
    }

    @ViewBuilder private func buttons(scale: CGFloat) -> some View {
        let height = Spacing.buttonHeightPhone * max(scale, 0.85)
        let shape = RoundedRectangle(cornerRadius: Radius.phoneButton * max(scale, 0.85), style: .continuous)
        if model.page == .nearby {
            VStack(spacing: 6) {
                Button { finish(.allowLocation) } label: {
                    HStack(spacing: 12 * scale) {
                        LocationArrowGlyph(size: 18 * scale)
                        Text("NEXT")
                            .busText(TypeStyles.primaryButtonPhone, scale: scale)
                    }
                    .foregroundStyle(theme.primaryButtonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(shape.fill(theme.primaryButtonFill))
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                Button { finish(.searchByName) } label: {
                    Text("Search by name instead")
                        .busText(TypeStyles.storyLink, scale: scale)
                        .foregroundStyle(theme.captionText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            Button { turn { model.next(animated: buildsOut) } } label: {
                Text("NEXT")
                    .busText(TypeStyles.primaryButtonPhone, scale: scale)
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(shape.fill(theme.background))
                    .overlay(shape.strokeBorder(theme.primaryText, lineWidth: 2))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Time

    private func elapsed(at date: Date) -> Double { max(0, model.clock(at: date).timeIntervalSince(model.pageStartedAt)) }

    /// A finger (or on a Mac, the mouse) down on the picture or the words. From the moment it
    /// lands it holds the story, letting go when the touch ends or is cancelled. A short press that
    /// stays put is a tap as well: on the leading third it goes back a page, on the trailing third
    /// forward. One gesture does both, so a tap and a hold never compete for the same touch.
    private func press(_ zone: StoryTapZone) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, pressing, _ in pressing = true }
            .onEnded { value in
                let held = pressBegan.map { Date().timeIntervalSince($0) } ?? 0
                pressBegan = nil
                let moved = hypot(value.translation.width, value.translation.height)
                guard held < Self.tapSeconds, moved < 10 else { return }
                switch zone {
                case .back: goBack()
                case .forward: turn { model.next(animated: buildsOut) }
                case .hold: break
                }
            }
    }

    /// Longer than this, a press is a hold and turns nothing.
    private static let tapSeconds: TimeInterval = 0.3

    /// When the page's build out ends, while it is leaving.
    private var leavingEnds: Date? {
        model.leaving.map { $0.startedAt + WelcomeTimeline.buildOutSeconds }
    }

    /// Until when the picture moves: for good on pages 1 and 3, whose pulse and pings loop, and on
    /// page 2 until the bus on its phone arrives, or its build out has played. Nil holds it still.
    private var artMovesUntil: Date? {
        guard !still, scenePhase == .active, model.heldSince == nil else { return nil }
        if let leavingEnds { return leavingEnds }
        return model.page == .wall ? model.pageStartedAt + WelcomeTimeline.wallSettledSeconds : .distantFuture
    }

    /// Until when the words move: their rise in, or their build out. Nil holds them still.
    private var wordsMoveUntil: Date? {
        guard !still, scenePhase == .active, model.heldSince == nil else { return nil }
        return leavingEnds ?? model.pageStartedAt + WelcomeTimeline.wordsBuildInSeconds
    }

    /// How far into its build out the page is, or nil while it is staying.
    private func leavingElapsed(at date: Date) -> Double? {
        model.leaving.map { max(0, model.clock(at: date).timeIntervalSince($0.startedAt)) }
    }

    private func goBack() { turn { model.previous(animated: buildsOut) } }

    private func step(forward: Bool) -> KeyPress.Result {
        if forward { turn { model.next(animated: buildsOut) } } else { goBack() }
        return .handled
    }

    /// The rider's answer, or none when time ran out. The page builds out first, as every page does
    /// on its way out, then the root fades the story away (see `answer`).
    private func finish(_ choice: WelcomeChoice) {
        model.end(with: choice, animated: buildsOut)
    }

    /// Changes page, or starts building the page out. The pictures and words move on their own
    /// clocks; the animation is for what changes with the page itself — the counter, the buttons,
    /// and, under Reduce Motion, the quick cross-fade between one still page and the next.
    private func turn(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.25), change)
    }
}

/// Frames for the story's timelines: `fps` a second until `until`, then none, so a timeline with
/// nothing left to move stops asking to be drawn. Nil is a single frame: the timeline stands still.
private struct StoryFrames: TimelineSchedule {
    var fps: Double
    var until: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldSequence<Date, (Date?, Bool)> {
        // Always On's low-frequency updates can't animate: draw where things stand.
        let last = mode == .lowFrequency ? startDate : max(startDate, until ?? startDate)
        let interval = 1 / fps
        return sequence(first: startDate) { date in
            date < last ? min(last, date + interval) : nil
        }
    }
}

/// Where a press lands on the story's picture or words.
private enum StoryTapZone {
    case back, hold, forward
}

private extension View {
    /// The story's taps, as in a story: the leading third goes back a page, the trailing third
    /// forward, and the middle only holds. Leading is the left in English and the right in Hebrew
    /// and Arabic. What lies under the zones is only looked at, never pressed.
    func storyTaps<G: Gesture>(_ press: @escaping (StoryTapZone) -> G) -> some View {
        overlay {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach([StoryTapZone.back, .hold, .forward], id: \.self) { zone in
                        Color.clear
                            .frame(width: zone == .hold ? nil : proxy.size.width / 3)
                            .frame(maxWidth: zone == .hold ? .infinity : nil)
                            .contentShape(Rectangle())
                            .gesture(press(zone))
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

#endif

/// The location arrow on the last page's NEXT, which goes on to the location prompt. Never mirrored: a location arrow points the same way in
/// every language.
struct LocationArrowGlyph: View {
    var size: CGFloat

    var body: some View {
        let unit = size / 20
        let arrow = Path { path in
            path.move(to: CGPoint(x: 2 * unit, y: 9.2 * unit))
            path.addLine(to: CGPoint(x: 18 * unit, y: 2 * unit))
            path.addLine(to: CGPoint(x: 10.8 * unit, y: 18 * unit))
            path.addLine(to: CGPoint(x: 9 * unit, y: 11 * unit))
            path.closeSubpath()
        }
        ZStack {
            arrow.fill(.foreground)
            arrow.stroke(.foreground, style: StrokeStyle(lineWidth: 1.6 * unit, lineJoin: .round))
        }
        .frame(width: size, height: size)
        // Shapes follow the reading direction unless told otherwise.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
