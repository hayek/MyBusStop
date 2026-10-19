import Foundation

/// How far a rider has come through the first-install welcome: the story, then the one tip on the
/// first board, then nothing ever again. One value rather than a flag per step, so no combination
/// of them can show the tip before the story or the story after the board.
nonisolated enum OnboardingProgress: String, Codable, Sendable {
    /// Nothing seen yet: the story opens the app.
    case welcome
    /// The story is done; the tip waits for the first board.
    case tipPending
    case done

    /// What a launch starts from.
    ///
    /// Anyone who installed before the story existed has no stored value. A saved stop or any
    /// history means they already know the app, so they are treated as done — nothing is written
    /// for them, the rule simply resolves the same way on every launch. A value that is not one of
    /// ours is ignored the same way.
    static func initial(stored: String?, hasConfiguration: Bool, hasHistory: Bool) -> OnboardingProgress {
        if let stored = stored.flatMap(OnboardingProgress.init(rawValue:)) { return stored }
        return hasConfiguration || hasHistory ? .done : .welcome
    }
}
