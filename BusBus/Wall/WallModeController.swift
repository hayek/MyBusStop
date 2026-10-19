import SwiftUI
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#elseif os(macOS)
import AppKit
#endif

/// Keeps an always-on wall display alive and healthy: the screen stays awake, the composition
/// drifts a little so an OLED panel does not burn the layout in, and at night the whole board dims
/// rather than switching to a light theme that would light up the room. The screen is held awake
/// even out of hours: the board goes black instead (`WallModeModifier`).
@MainActor @Observable final class WallModeController {
    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "wall")

    /// Eight positions, two points across, cycled every few minutes.
    static let driftPositions: [CGSize] = [
        CGSize(width: 0, height: 0), CGSize(width: 2, height: 0),
        CGSize(width: 2, height: 2), CGSize(width: 0, height: 2),
        CGSize(width: -2, height: 2), CGSize(width: -2, height: 0),
        CGSize(width: -2, height: -2), CGSize(width: 0, height: -2),
    ]
    static let driftInterval: TimeInterval = 180
    /// Below this screen brightness the room is dark enough to dim the board.
    static let dimBelowBrightness = 0.25
    /// Not a Range: 23..<6 wraps past midnight, and Swift traps on a range whose lower bound is
    /// above its upper bound.
    static let nightStartHour = 23
    static let nightEndHour = 6
    /// How long a tap shows the board out of hours, counted from the last touch.
    static let peekDuration: TimeInterval = 20
    static let fadeInDuration: TimeInterval = 0.4
    static let fadeOutDuration: TimeInterval = 1.5

    private(set) var isActive = false
    #if os(macOS)
    private var activity: (any NSObjectProtocol)?
    #endif

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        active ? beginKeepingAwake() : endKeepingAwake()
    }

    private func beginKeepingAwake() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Wall display")
        #endif
        Self.log.info("wall mode on")
    }

    private func endKeepingAwake() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
        Self.log.info("wall mode off")
    }

    static func driftOffset(at date: Date) -> CGSize {
        let step = Int(date.timeIntervalSinceReferenceDate / driftInterval)
        return driftPositions[((step % driftPositions.count) + driftPositions.count) % driftPositions.count]
    }

    /// The backlight setting of the screen the board is actually on — the nearest thing the system
    /// exposes to an ambient reading. Nil where there is none to read.
    static func screenBrightness() -> Double? {
        #if canImport(UIKit) && !os(tvOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene.map { Double($0.screen.brightness) }
        #else
        return nil
        #endif
    }

    /// How much to dim, 0 to 1. There is no public ambient-light reading, so the backlight is used
    /// as a proxy and the clock as a backstop — which is the only signal a desk Mac has.
    static func dimming(at date: Date, brightness: Double?, calendar: Calendar = .current) -> Double {
        var amount = 0.0
        if let brightness, brightness < dimBelowBrightness { amount = 0.45 }
        let hour = calendar.component(.hour, from: date)
        if hour >= nightStartHour || hour < nightEndHour {
            amount = max(amount, 0.3)
        }
        return amount
    }
}

/// Applies the wall-mode behaviours that belong to the view: the drift, the night dimming, and the
/// black screen outside the schedule.
struct WallModeModifier: ViewModifier {
    @State private var controller = WallModeController()
    /// Recomputed on a timer rather than read in `body`: the schedule turns over on its own, with
    /// nothing else changing to prompt a redraw.
    @State private var isWithinSchedule = true
    /// The last touch anywhere in the app. Starts at the board's appearance, so a board opened out
    /// of hours shows itself before it goes black.
    @State private var lastInteraction = Date()
    @State private var peekHasLapsed = false
    @Environment(\.scenePhase) private var scenePhase
    var isActive: Bool
    var schedule: WallSchedule = .alwaysOn
    /// Told when the board goes black and when it comes back, so the board can stop and resume
    /// asking for arrivals.
    var onDarkChange: (Bool) -> Void = { _ in }

    /// The app keeps the screen on for as long as it is a wall display. Out of hours it goes black
    /// on its own terms rather than handing the screen to Auto-Lock, so a tap is always enough to
    /// read the board.
    private var isDark: Bool { isActive && !isWithinSchedule && peekHasLapsed }

    func body(content: Content) -> some View {
        Group {
            if isActive {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let offset = WallModeController.driftOffset(at: context.date)
                    let dimming = WallModeController.dimming(at: context.date,
                                                             brightness: WallModeController.screenBrightness())
                    content
                        .offset(x: offset.width, y: offset.height)
                        .animation(.easeInOut(duration: 2), value: offset)
                        .overlay {
                            Color.black
                                .opacity(dimming)
                                .allowsHitTesting(false)
                                .animation(.easeInOut(duration: 2), value: dimming)
                                .ignoresSafeArea()
                        }
                }
                // A wall display is read from across a room at a fixed size; Dynamic Type is a
                // hand-mode affordance.
                .dynamicTypeSize(.large)
            } else {
                content
            }
        }
        .overlay {
            if isDark {
                // Takes the waking tap itself, so it cannot land on a bus underneath.
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { noteInteraction() }
                    .accessibilityElement()
                    .accessibilityLabel("Board is dark")
                    .accessibilityHint("Shows the board for 20 seconds.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { noteInteraction() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: isDark ? WallModeController.fadeOutDuration
                                               : WallModeController.fadeInDuration), value: isDark)
        #if os(iOS)
        .background { InteractionObserver(onInteraction: noteInteraction).allowsHitTesting(false) }
        #elseif os(macOS)
        .onAppear { interactionMonitor.start(noteInteraction) }
        .onDisappear { interactionMonitor.stop() }
        #endif
        .task(id: schedule) { await followSchedule() }
        .task(id: lastInteraction) { await lapsePeek() }
        .onChange(of: isDark) { _, dark in onDarkChange(dark) }
        // Bringing the app forward is someone about to read it, as much as a tap is.
        .onChange(of: scenePhase) { _, phase in if phase == .active { noteInteraction() } }
        .onAppear { controller.setActive(isActive) }
        .onChange(of: isActive) { _, active in
            if active { noteInteraction() }
            controller.setActive(active)
        }
        .onDisappear { controller.setActive(false) }
    }

    private func noteInteraction() {
        lastInteraction = Date()
    }

    /// Restarted by every touch: the board stays lit until the last one is twenty seconds old.
    private func lapsePeek() async {
        peekHasLapsed = false
        try? await Task.sleep(for: .seconds(WallModeController.peekDuration))
        if !Task.isCancelled { peekHasLapsed = true }
    }

    /// Half a minute is fine for a boundary measured in hours, and costs nothing next to the
    /// board's own refresh.
    private func followSchedule() async {
        while !Task.isCancelled {
            isWithinSchedule = schedule.isOn(at: Date())
            try? await Task.sleep(for: .seconds(30))
        }
    }

    #if os(macOS)
    @State private var interactionMonitor = InteractionMonitor()
    #endif
}

#if os(iOS)
/// Hears every touch in the board's window — the board, its sheets, the settings — without taking
/// any of them, so a rider working the app is never cut off by the screen going black.
private struct InteractionObserver: UIViewRepresentable {
    var onInteraction: () -> Void

    func makeUIView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onInteraction = onInteraction
        return view
    }

    func updateUIView(_ view: ObservingView, context: Context) {
        view.onInteraction = onInteraction
    }

    final class ObservingView: UIView {
        var onInteraction: () -> Void = {}
        private lazy var recognizer = TouchRecognizer { [weak self] in self?.onInteraction() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        override func removeFromSuperview() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            super.removeFromSuperview()
        }
    }

    /// Reports a touch and steps aside at once, so no other gesture ever waits on it.
    final class TouchRecognizer: UIGestureRecognizer {
        private let onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed
        }
    }
}
#endif

#if os(macOS)
/// The Mac's version of a touch: a click, a scroll or a key anywhere in the app.
@MainActor private final class InteractionMonitor {
    private var monitor: Any?

    func start(_ onInteraction: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { event in
            onInteraction()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
