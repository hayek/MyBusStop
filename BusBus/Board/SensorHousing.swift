import SwiftUI

/// Which edge of the screen the sensor housing sits behind, when there is one.
///
/// In landscape the system reserves the same margin on both sides whichever way the phone is
/// facing, so that content does not jump when it is turned around. That symmetry means the geometry
/// cannot say which side is actually obstructed — but only one side is, and on a board that reads
/// from across a room the other side is worth having. The scene's own orientation is what
/// distinguishes them.
@MainActor @Observable final class SensorHousing {
    /// The physical side of the screen, as the device is held. Nil when nothing is obstructed:
    /// portrait, a Mac window, or a device without a housing.
    private(set) var side: Side?

    nonisolated enum Side { case left, right }

    /// The same side in the board's own terms. The safe-area insets it is weighed against are
    /// leading and trailing, and in a right-to-left language leading is the right-hand side.
    func edge(in direction: LayoutDirection) -> HorizontalEdge? { Self.edge(of: side, in: direction) }

    nonisolated static func edge(of side: Side?, in direction: LayoutDirection) -> HorizontalEdge? {
        side.map { side in
            switch (side, direction) {
            case (.left, .leftToRight), (.right, .rightToLeft): .leading
            default: .trailing
            }
        }
    }

    #if os(iOS)
    private var observation: Task<Void, Never>?

    init() {
        update()
        // Turning the phone end over end in landscape does not change the size of anything, so no
        // layout pass is triggered and only the orientation itself reports the flip.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observation = Task { [weak self] in
            let flips = NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification)
            for await _ in flips {
                guard let self else { break }
                self.update()
            }
        }
    }

    /// Measured on an iPhone in the simulator: with the interface in `.landscapeLeft` the housing
    /// is on the right, and in `.landscapeRight` on the left. The two enumerations for orientation
    /// are mirror images of each other, so this is recorded rather than reasoned.
    private func update() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: side = .right
        case .landscapeRight: side = .left
        default: side = nil
        }
    }
    #else
    init() { side = nil }
    #endif
}
