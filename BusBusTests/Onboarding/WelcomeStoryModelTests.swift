import Testing
import Foundation
@testable import BusBus

@MainActor
struct WelcomeStoryModelTests {

    @Test func nextTurnsEachPageAndStopsAtTheLast() {
        let model = WelcomeStoryModel()
        #expect(model.page == .map)
        model.next()
        #expect(model.page == .wall)
        model.next()
        #expect(model.page == .nearby)
        model.next()
        #expect(model.page == .nearby)
    }

    @Test func aTimerArmedForAPageAlreadyLeftDoesNothing() {
        let model = WelcomeStoryModel()
        // NEXT, then the first page's timer firing before it is cancelled.
        model.next()
        model.next(from: .map)
        #expect(model.page == .wall)
        // The second page's own timer still turns it.
        model.next(from: .wall)
        #expect(model.page == .nearby)
    }

    @Test func previousGoesBackAPageAndReplaysTheFirst() {
        let start = Date(timeIntervalSince1970: 1_000)
        let model = WelcomeStoryModel(page: .nearby, now: start)
        model.previous(now: start.addingTimeInterval(1))
        #expect(model.page == .wall)
        model.previous(now: start.addingTimeInterval(2))
        #expect(model.page == .map)
        #expect(model.pageStartedAt == start.addingTimeInterval(2))
        // Nothing before the first page: it starts over.
        model.previous(now: start.addingTimeInterval(3))
        #expect(model.page == .map)
        #expect(model.pageStartedAt == start.addingTimeInterval(3))
    }

    @Test(arguments: [WelcomePage.map, .wall])
    func skipGoesToTheLocationPage(_ from: WelcomePage) {
        let model = WelcomeStoryModel(page: from)
        model.skip()
        #expect(model.page == .nearby)
    }

    @Test func eachPageStartsItsOwnClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let model = WelcomeStoryModel(now: start)
        #expect(model.pageStartedAt == start)
        model.next(now: start.addingTimeInterval(5))
        #expect(model.pageStartedAt == start.addingTimeInterval(5))
        model.skip(now: start.addingTimeInterval(7))
        #expect(model.pageStartedAt == start.addingTimeInterval(7))
        // Already on the last page: nothing changes, the clock included.
        model.next(now: start.addingTimeInterval(9))
        #expect(model.pageStartedAt == start.addingTimeInterval(7))
        model.restartClock(now: start.addingTimeInterval(20))
        #expect(model.pageStartedAt == start.addingTimeInterval(20))
    }

    // MARK: Building out

    let start = Date(timeIntervalSince1970: 1_000)
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func aPageBuildsOutBeforeItTurns() {
        let model = WelcomeStoryModel(now: start)
        model.next(animated: true, now: at(2))
        // Still on the map while it folds away, its clock untouched.
        #expect(model.page == .map)
        #expect(model.pageStartedAt == start)
        #expect(model.leaving == .init(target: .wall, startedAt: at(2)))
        model.finishLeaving(now: at(2.5))
        #expect(model.page == .wall)
        #expect(model.leaving == nil)
        #expect(model.pageStartedAt == at(2.5))
        // Nothing left to finish.
        model.finishLeaving(now: at(3))
        #expect(model.page == .wall && model.pageStartedAt == at(2.5))
    }

    /// The page's own timer starts the build out; NEXT pressed during it, or the timer firing after
    /// NEXT started one, turns the page only once.
    @Test func aTimerDuringABuildOutDoesNotTurnTwice() {
        let model = WelcomeStoryModel(page: .wall, now: start)
        model.next(animated: true, now: at(7.9))
        model.next(from: .wall, animated: true, now: at(8))
        #expect(model.leaving == .init(target: .nearby, startedAt: at(7.9)))
        model.finishLeaving(now: at(8.4))
        #expect(model.page == .nearby)
        // The same timer, late: the page it was armed for is gone.
        model.next(from: .wall, animated: true, now: at(8.5))
        #expect(model.page == .nearby && model.leaving == nil)

        let timed = WelcomeStoryModel(now: start)
        timed.next(from: .map, animated: true, now: at(8.5))
        timed.next(animated: true, now: at(8.6))
        #expect(timed.leaving == .init(target: .wall, startedAt: at(8.5)))
        timed.finishLeaving(now: at(9))
        #expect(timed.page == .wall)
    }

    /// Back during a build out changes where it is heading, not when it gets there, and a timer
    /// firing after it does not send the page on after all.
    @Test func backDuringABuildOutTurnsBackInstead() {
        let model = WelcomeStoryModel(page: .wall, now: start)
        model.next(animated: true, now: at(3))
        model.previous(animated: true, now: at(3.2))
        #expect(model.leaving == .init(target: .map, startedAt: at(3)))
        model.next(from: .wall, animated: true, now: at(3.3))
        #expect(model.leaving?.target == .map)
        model.finishLeaving(now: at(3.5))
        #expect(model.page == .map && model.pageStartedAt == at(3.5))
    }

    @Test func backOnTheFirstPageBuildsOutAndReplaysIt() {
        let model = WelcomeStoryModel(now: start)
        model.previous(animated: true, now: at(4))
        #expect(model.leaving == .init(target: .map, startedAt: at(4)))
        #expect(model.pageStartedAt == start)
        model.finishLeaving(now: at(4.5))
        #expect(model.page == .map && model.pageStartedAt == at(4.5))
    }

    @Test func skipBuildsOutToTheLocationPage() {
        let model = WelcomeStoryModel(now: start)
        model.skip(animated: true, now: at(1))
        #expect(model.page == .map && model.leaving?.target == .nearby)
        // SKIP again, or NEXT, while it folds away: still one turn, still to the location page.
        model.skip(animated: true, now: at(1.1))
        #expect(model.leaving == .init(target: .nearby, startedAt: at(1)))
        model.finishLeaving(now: at(1.5))
        #expect(model.page == .nearby && model.leaving == nil)
        // From the last page, going back builds it out too.
        model.previous(animated: true, now: at(3))
        #expect(model.page == .nearby && model.leaving?.target == .wall)
    }

    /// Back from elsewhere in the middle of a build out, the story lands on the page it was heading
    /// for and plays it from the start.
    @Test func comingBackMidBuildOutFinishesIt() {
        let model = WelcomeStoryModel(now: start)
        model.next(animated: true, now: at(2))
        model.restartClock(now: at(60))
        #expect(model.page == .wall && model.leaving == nil && model.pageStartedAt == at(60))
    }

    /// NEXT tapped on the last page just after a back tap on the last page: the story ends there. The build
    /// out under way becomes the story's own, keeping its time, and the page never turns to the second.
    @Test func answeringDuringABuildOutEndsTheStoryWhereItStands() {
        let model = WelcomeStoryModel(page: .nearby, now: start)
        model.previous(animated: true, now: at(3))
        model.end(with: .allowLocation, animated: true, now: at(3.25))
        #expect(model.answer == nil && model.leaving?.startedAt == at(3) && model.leaving?.ending == .allowLocation)
        model.finishLeaving(now: at(3.5))
        #expect(model.answer == .allowLocation)
        #expect(model.page == .nearby && model.pageStartedAt == start)
        // Nor does anything else once it has ended.
        model.next(animated: true, now: at(3.6))
        model.skip(now: at(3.7))
        model.previous(now: at(3.8))
        model.restartClock(now: at(4))
        model.end(with: .searchByName, now: at(4.1))
        #expect(model.page == .nearby && model.answer == .allowLocation)
    }

    /// Every way off the last page builds it out before the story closes: an answer, or its time
    /// running out.
    @Test(arguments: [WelcomeChoice.allowLocation, .searchByName, .timedOut])
    func theLastPageBuildsOutBeforeTheStoryEnds(_ choice: WelcomeChoice) {
        let model = WelcomeStoryModel(page: .nearby, now: start)
        model.end(with: choice, animated: true, now: at(8.5))
        #expect(model.answer == nil)
        #expect(model.leaving == .init(target: .nearby, startedAt: at(8.5), ending: choice))
        // Taps during the build out change nothing, a second answer included.
        model.previous(animated: true, now: at(8.6))
        model.end(with: .searchByName, animated: true, now: at(8.7))
        #expect(model.leaving == .init(target: .nearby, startedAt: at(8.5), ending: choice))
        model.finishLeaving(now: at(9))
        #expect(model.answer == choice && model.page == .nearby)
    }

    /// Back from elsewhere mid build out: the story it was ending ends.
    @Test func comingBackMidEndingEndsTheStory() {
        let model = WelcomeStoryModel(page: .nearby, now: start)
        model.end(with: .timedOut, animated: true, now: at(8.5))
        model.restartClock(now: at(30))
        #expect(model.answer == .timedOut)
    }

    /// A finger held on the story stops its clock; let go, it runs on with the held time not counted.
    @Test func holdingStopsTheClock() {
        let model = WelcomeStoryModel(now: start)
        model.hold(now: at(3))
        #expect(model.clock(at: at(10)) == at(3))
        model.release(now: at(10))
        #expect(model.heldSince == nil && model.pageStartedAt == at(7))
        // Four seconds into the page again, not eleven.
        #expect(model.clock(at: at(11)).timeIntervalSince(model.pageStartedAt) == 4)
    }

    /// Held during a build out, the build out stops too, and resumes where it was.
    @Test func holdingStopsABuildOut() {
        let model = WelcomeStoryModel(now: start)
        model.next(animated: true, now: at(8.5))
        model.hold(now: at(8.7))
        model.release(now: at(12.7))
        #expect(model.leaving?.startedAt == at(12.5))
        #expect(model.page == .map)
    }

    /// Coming back to the app lets go of a hold whose touch never ended.
    @Test func comingBackLetsGoOfAHold() {
        let model = WelcomeStoryModel(now: start)
        model.hold(now: at(2))
        model.restartClock(now: at(30))
        #expect(model.heldSince == nil && model.pageStartedAt == at(30))
        // A second hold before a release is the same hold.
        model.hold(now: at(31))
        model.hold(now: at(32))
        #expect(model.heldSince == at(31))
    }

    /// Reduce Motion: the story ends at once.
    @Test func withoutAnimationTheStoryEndsAtOnce() {
        let model = WelcomeStoryModel(page: .nearby, now: start)
        model.end(with: .searchByName, now: at(1))
        #expect(model.answer == .searchByName && model.leaving == nil)
    }

    /// Reduce Motion: no build out, the page turns at once.
    @Test func withoutAnimationThePageTurnsAtOnce() {
        let model = WelcomeStoryModel(now: start)
        model.next(animated: false, now: at(1))
        #expect(model.page == .wall && model.leaving == nil && model.pageStartedAt == at(1))
        model.previous(now: at(2))
        #expect(model.page == .map && model.leaving == nil)
        model.skip(now: at(3))
        #expect(model.page == .nearby && model.leaving == nil)
        // SKIP on the last page does nothing, clock included.
        model.skip(animated: true, now: at(4))
        #expect(model.leaving == nil && model.pageStartedAt == at(3))
    }
}
