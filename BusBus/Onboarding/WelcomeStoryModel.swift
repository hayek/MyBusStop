import Foundation
import Observation

/// How the rider left the story's last page.
nonisolated enum WelcomeChoice: Hashable, Sendable {
    case allowLocation
    case searchByName
    /// Neither: the last page's time ran out with no answer.
    case timedOut
}

/// Which page of the welcome story is showing, and since when. It knows nothing of settings or
/// location: the view reports the rider's choice and the root acts on it.
///
/// A page is left in two steps when it builds out: `leaving` is set, the page plays its build out,
/// and `finishLeaving` then turns it. With `animated` off (Reduce Motion, renders) the page turns
/// at once. The story ends the same way: the last page builds out, then `answer` is set.
@MainActor @Observable final class WelcomeStoryModel {
    /// A build out under way: where it is heading, and when it began.
    struct Leaving: Hashable, Sendable {
        var target: WelcomePage
        var startedAt: Date
        /// Set when the build out ends the story rather than turning a page.
        var ending: WelcomeChoice?
    }

    private(set) var page: WelcomePage
    /// What the page's pictures and its progress bar are timed from.
    private(set) var pageStartedAt: Date
    /// Set while the page builds out; the page itself has not changed yet.
    private(set) var leaving: Leaving?
    /// When a finger came down on the story and held it still, as a story holds while pressed; nil
    /// while it runs.
    private(set) var heldSince: Date?
    /// How the story ended, once its last build out has played: the root closes it on this.
    private(set) var answer: WelcomeChoice?
    /// The story has ended: no page turns again.
    var isFinished: Bool { answer != nil }

    init(page: WelcomePage = .map, now: Date = Date()) {
        self.page = page
        pageStartedAt = now
    }

    /// Turns to the next page. The last one stays.
    func next(animated: Bool = false, now: Date = Date()) {
        guard let next = page.next else { return }
        leave(to: next, animated: animated, now: now)
    }

    /// Turns on from `page` only if it is still showing and nothing is leaving it: a timer that was
    /// armed for a page the rider has already left, or is already leaving, with NEXT, back or SKIP
    /// must not turn the page again.
    func next(from page: WelcomePage, animated: Bool = false, now: Date = Date()) {
        guard page == self.page, leaving == nil else { return }
        next(animated: animated, now: now)
    }

    /// Back a page, the way a story goes back on a tap at its leading edge. On the first page it
    /// plays that page again.
    func previous(animated: Bool = false, now: Date = Date()) {
        leave(to: page.previous ?? page, animated: animated, now: now)
    }

    /// Straight to the page that asks for location. Already there, nothing changes.
    func skip(animated: Bool = false, now: Date = Date()) {
        guard (leaving?.target ?? page) != .nearby else { return }
        leave(to: .nearby, animated: animated, now: now)
    }

    /// Ends the story with the rider's answer, or with none when the last page's time runs out. The
    /// page builds out first; a build out already under way (back, tapped just before) becomes the
    /// story's own, keeping its time, and never turns the page. A second answer changes nothing.
    func end(with choice: WelcomeChoice, animated: Bool = false, now: Date = Date()) {
        guard !isFinished, leaving?.ending == nil else { return }
        if leaving != nil {
            leaving?.ending = choice
        } else if animated {
            leaving = Leaving(target: page, startedAt: now, ending: choice)
        } else {
            answer = choice
        }
    }

    /// Holds the story where it stands while a finger is down: the page's clock, its build out,
    /// and so its timer and progress bar, all stop.
    func hold(now: Date = Date()) {
        guard heldSince == nil, !isFinished else { return }
        heldSince = now
    }

    /// Lets the story run on from where it was held, the held time not counted.
    func release(now: Date = Date()) {
        guard let heldSince else { return }
        self.heldSince = nil
        let held = max(0, now.timeIntervalSince(heldSince))
        pageStartedAt += held
        leaving?.startedAt += held
    }

    /// The story's time at `date`: the moment it was held, while it is.
    func clock(at date: Date) -> Date {
        heldSince.map { min($0, date) } ?? date
    }

    /// Turns the page a build out was heading for, or ends the story. The view calls it when the
    /// build out has played.
    func finishLeaving(now: Date = Date()) {
        guard !isFinished, let leaving else { return }
        if let ending = leaving.ending { return answer = ending }
        self.leaving = nil
        go(to: leaving.target, now: now)
    }

    /// Starts the current page's pictures over: after a page change, and on coming back to the
    /// app, so nothing is found half-played or already finished. A build out cut short lands on the
    /// page it was heading for.
    func restartClock(now: Date = Date()) {
        heldSince = nil
        if leaving != nil { return finishLeaving(now: now) }
        pageStartedAt = now
    }

    /// Starts a build out towards `target`, or turns straight to it. A second tap while a page is
    /// building out changes where it is heading but not when it gets there, so the page turns once.
    private func leave(to target: WelcomePage, animated: Bool, now: Date) {
        if isFinished || leaving?.ending != nil { return }
        if leaving != nil {
            leaving?.target = target
        } else if animated {
            leaving = Leaving(target: target, startedAt: now)
        } else {
            go(to: target, now: now)
        }
    }

    /// The page, played from its start. The same page again is a replay.
    private func go(to page: WelcomePage, now: Date) {
        self.page = page
        pageStartedAt = now
        // Turned under a held finger (NEXT with another): the new page is held from its start.
        if heldSince != nil { heldSince = now }
    }
}
