import Foundation
import Testing
@testable import Nubb

// MARK: - Fake scheduler

/// One unit of work registered with `FakeScheduler`.
private final class FakeScheduledWork: TabSidebarCancellable {
    let fireAt: TimeInterval
    let sequence: Int
    let work: () -> Void
    private(set) var isCancelled = false
    var hasFired = false

    init(fireAt: TimeInterval, sequence: Int, work: @escaping () -> Void) {
        self.fireAt = fireAt
        self.sequence = sequence
        self.work = work
    }

    func cancel() {
        isCancelled = true
    }

    var isPending: Bool { !isCancelled && !hasFired }
}

/// Scheduler with a manual clock. Work only runs from `advance(by:)`, in time
/// order (ties in scheduling order), and cancelled work never runs.
private final class FakeScheduler: TabSidebarScheduler {
    /// Tolerance so that summed decimal steps (0.07 + 0.01) reach 0.08.
    private static let epsilon: TimeInterval = 1e-9

    private(set) var now: TimeInterval = 0
    private var items: [FakeScheduledWork] = []
    private var nextSequence = 0

    /// Total number of `schedule` calls ever made.
    var scheduledCount: Int { items.count }

    /// Work that is neither cancelled nor already run.
    var pendingCount: Int { items.filter(\.isPending).count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TabSidebarCancellable {
        let item = FakeScheduledWork(fireAt: now + delay, sequence: nextSequence, work: work)
        nextSequence += 1
        items.append(item)
        return item
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let next = nextDue(before: target) {
            now = max(now, next.fireAt)
            next.hasFired = true
            next.work()
        }
        now = target
    }

    private func nextDue(before target: TimeInterval) -> FakeScheduledWork? {
        items
            .filter { $0.isPending && $0.fireAt <= target + Self.epsilon }
            .min { lhs, rhs in
                if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
                return lhs.sequence < rhs.sequence
            }
    }
}

// MARK: - Fake scheduler self-checks

@Suite
struct TabSidebarFakeSchedulerTests {
    @Test func runsDueWorkInTimeOrderAndSkipsCancelled() {
        let scheduler = FakeScheduler()
        var log: [String] = []
        _ = scheduler.schedule(after: 2) { log.append("b") }
        _ = scheduler.schedule(after: 1) { log.append("a") }
        let cancelled = scheduler.schedule(after: 1.5) { log.append("x") }
        _ = scheduler.schedule(after: 3) { log.append("c") }
        cancelled.cancel()

        scheduler.advance(by: 2.5)
        #expect(log == ["a", "b"])
        scheduler.advance(by: 1)
        #expect(log == ["a", "b", "c"])
    }
}

// MARK: - Presentation

@Suite
struct TabSidebarPresentationTests {
    private let timing = TabSidebarPresentation.Timing.standard

    private func makeCollapsed() -> (TabSidebarPresentation, FakeScheduler) {
        let scheduler = FakeScheduler()
        let presentation = TabSidebarPresentation(isCollapsed: true, timing: .standard, scheduler: scheduler)
        return (presentation, scheduler)
    }

    private func makePinned() -> (TabSidebarPresentation, FakeScheduler) {
        let scheduler = FakeScheduler()
        let presentation = TabSidebarPresentation(isCollapsed: false, timing: .standard, scheduler: scheduler)
        return (presentation, scheduler)
    }

    /// Collapsed and peeking because the pointer rested on the edge zone.
    /// The pointer is still in the edge zone afterwards.
    private func makePeekingFromEdge() -> (TabSidebarPresentation, FakeScheduler) {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        return (presentation, scheduler)
    }

    // MARK: Timing and initial state

    @Test func standardTimingValues() {
        let standard = TabSidebarPresentation.Timing.standard
        #expect(standard.showDelay == 0.08)
        #expect(standard.hideDelay == 0.35)
        #expect(standard.flashDuration == 1.0)
    }

    @Test func initCollapsedIsHiddenAndNotPeeking() {
        let (presentation, scheduler) = makeCollapsed()
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isPeeking == false)
        #expect(presentation.isSidebarVisible == false)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func initPinnedIsVisibleAndNotPeeking() {
        let (presentation, _) = makePinned()
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
        #expect(presentation.isSidebarVisible == true)
    }

    @Test func peekingWhileCollapsedIsVisible() {
        let (presentation, _) = makePeekingFromEdge()
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isPeeking == true)
        #expect(presentation.isSidebarVisible == true)
    }

    // MARK: toggle / setCollapsed

    @Test func toggleFlipsCollapsedBothWays() {
        let (presentation, _) = makePinned()
        presentation.toggle()
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isSidebarVisible == false)
        presentation.toggle()
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isSidebarVisible == true)
    }

    @Test func toggleWhilePeekingPinsAndClearsPeeking() {
        let (presentation, _) = makePeekingFromEdge()
        presentation.toggle()
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
    }

    @Test func toggleCancelsPendingShow() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.toggle()
        presentation.toggle()
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 5)
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isPeeking == false)
    }

    @Test func toggleCancelsPendingHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        #expect(scheduler.pendingCount == 1)
        presentation.toggle()
        #expect(scheduler.pendingCount == 0)
    }

    @Test func setCollapsedToSameValueIsNoOp() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.setCollapsed(true)
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isPeeking == true)
        #expect(scheduler.pendingCount == 1)
        // The flash hide was not cancelled.
        scheduler.advance(by: timing.flashDuration)
        #expect(presentation.isPeeking == false)
    }

    @Test func setCollapsedFalseWhenPinnedIsNoOp() {
        let (presentation, _) = makePinned()
        presentation.setCollapsed(false)
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
    }

    @Test func setCollapsedToNewValueBehavesLikeToggle() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.setCollapsed(false)
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
        #expect(scheduler.pendingCount == 0)
        presentation.setCollapsed(true)
        #expect(presentation.isCollapsed == true)
        #expect(presentation.isPeeking == false)
    }

    @Test func setCollapsedCancelsPendingShow() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.setCollapsed(false)
        presentation.setCollapsed(true)
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == false)
    }

    // MARK: Edge zone

    @Test func edgeEnterShowsAfterShowDelay() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        #expect(presentation.isPeeking == false)
        scheduler.advance(by: 0.07)
        #expect(presentation.isPeeking == false)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == true)
        #expect(presentation.isCollapsed == true)
    }

    @Test func secondEdgeEnterWhileShowPendingDoesNotReschedule() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: 0.05)
        presentation.pointerEnteredEdge()
        #expect(scheduler.scheduledCount == 1)
        // The original show still fires at 0.08, not 0.05 + 0.08.
        scheduler.advance(by: 0.03)
        #expect(presentation.isPeeking == true)
    }

    @Test func edgeEnterWhenPinnedDoesNothingVisible() {
        let (presentation, scheduler) = makePinned()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: 5)
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
        #expect(presentation.isSidebarVisible == true)
    }

    @Test func edgeEnterWhilePeekingCancelsPendingHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        #expect(scheduler.pendingCount == 1)
        presentation.pointerEnteredEdge()
        // The hide is cancelled and no show is scheduled while already peeking.
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func edgeExitCancelsPendingShow() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: 0.05)
        presentation.pointerExitedEdge()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == false)
    }

    @Test func edgeExitBeforeShowDoesNotScheduleHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.pointerExitedEdge()
        #expect(scheduler.pendingCount == 0)
    }

    @Test func edgeExitWhilePeekingHidesAfterHideDelay() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerExitedEdge()
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.34)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
        #expect(presentation.isCollapsed == true)
    }

    @Test func edgeExitWhilePeekingOverCardDoesNotHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerEnteredCard()
        presentation.pointerExitedEdge()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func peekCanBeReopenedAfterHiding() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerExitedEdge()
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
    }

    // MARK: Card

    @Test func cardEnterCancelsPendingHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerExitedEdge()
        #expect(scheduler.pendingCount == 1)
        presentation.pointerEnteredCard()
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func cardExitOutsideEdgeHidesAfterHideDelay() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerEnteredCard()
        presentation.pointerExitedEdge()
        presentation.pointerExitedCard()
        scheduler.advance(by: 0.34)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
    }

    @Test func cardExitIntoEdgeZoneDoesNotHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerEnteredCard()
        presentation.pointerExitedCard()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func cardExitWhenNotPeekingSchedulesNothing() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredCard()
        presentation.pointerExitedCard()
        #expect(scheduler.pendingCount == 0)
        #expect(presentation.isPeeking == false)
    }

    @Test func cardExitWhenPinnedChangesNothing() {
        let (presentation, scheduler) = makePinned()
        presentation.pointerEnteredCard()
        presentation.pointerExitedCard()
        scheduler.advance(by: 5)
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
    }

    // MARK: Hide replacement and suppression

    @Test func schedulingHideReplacesPendingHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerExitedEdge()
        scheduler.advance(by: 0.2)
        // Pointer is over neither the card nor the edge: reschedules the hide.
        presentation.pointerExitedCard()
        #expect(scheduler.pendingCount == 1)
        // The first hide would have fired 0.35 after the edge exit.
        scheduler.advance(by: 0.2)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.15)
        #expect(presentation.isPeeking == false)
    }

    @Test func secondFlashReplacesPendingHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        scheduler.advance(by: 0.5)
        presentation.flash()
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: 0.9)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.1)
        #expect(presentation.isPeeking == false)
    }

    @Test func hideFiringWhilePointerOverCardChangesNothing() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredCard()
        presentation.flash()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
        #expect(presentation.isCollapsed == true)
    }

    @Test func hideFiringWhilePointerInEdgeZoneChangesNothing() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.flash()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
    }

    @Test func hideFiringDuringInteractionChangesNothing() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.beginInteraction()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
    }

    // MARK: flash

    @Test func flashWhenCollapsedPeeksImmediatelyThenHides() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        #expect(presentation.isPeeking == true)
        #expect(presentation.isCollapsed == true)
        scheduler.advance(by: 0.99)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
    }

    @Test func flashWhenPinnedDoesNothing() {
        let (presentation, scheduler) = makePinned()
        presentation.flash()
        #expect(presentation.isPeeking == false)
        #expect(presentation.isCollapsed == false)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func flashCancelsPendingShow() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        #expect(scheduler.pendingCount == 1)
        presentation.flash()
        // Only the flash hide remains.
        #expect(scheduler.pendingCount == 1)
        #expect(presentation.isPeeking == true)
    }

    @Test func flashUsesCustomFlashDuration() {
        let scheduler = FakeScheduler()
        let custom = TabSidebarPresentation.Timing(showDelay: 0.5, hideDelay: 0.7, flashDuration: 3)
        let presentation = TabSidebarPresentation(isCollapsed: true, timing: custom, scheduler: scheduler)
        presentation.flash()
        scheduler.advance(by: 2.9)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.1)
        #expect(presentation.isPeeking == false)
    }

    @Test func edgeUsesCustomShowAndHideDelays() {
        let scheduler = FakeScheduler()
        let custom = TabSidebarPresentation.Timing(showDelay: 0.5, hideDelay: 0.7, flashDuration: 3)
        let presentation = TabSidebarPresentation(isCollapsed: true, timing: custom, scheduler: scheduler)
        presentation.pointerEnteredEdge()
        scheduler.advance(by: 0.4)
        #expect(presentation.isPeeking == false)
        scheduler.advance(by: 0.1)
        #expect(presentation.isPeeking == true)
        presentation.pointerExitedEdge()
        scheduler.advance(by: 0.6)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.1)
        #expect(presentation.isPeeking == false)
    }

    // MARK: dismissPeek

    @Test func dismissPeekHidesImmediatelyAndCancelsHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.dismissPeek()
        #expect(presentation.isPeeking == false)
        #expect(presentation.isCollapsed == true)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func dismissPeekCancelsPendingShow() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.dismissPeek()
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == false)
    }

    @Test func dismissPeekWhenPinnedKeepsSidebarPinned() {
        let (presentation, _) = makePinned()
        presentation.dismissPeek()
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
        #expect(presentation.isSidebarVisible == true)
    }

    // MARK: Interactions

    @Test func interactionsNestUntilCountReachesZero() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.beginInteraction()
        presentation.beginInteraction()
        presentation.endInteraction()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)

        presentation.endInteraction()
        scheduler.advance(by: 0.34)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
    }

    @Test func endInteractionWithoutBeginIsIgnored() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        // Ignored: must not drive the counter negative.
        presentation.endInteraction()
        presentation.beginInteraction()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
    }

    @Test func endingInteractionOverCardDoesNotHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerEnteredCard()
        presentation.pointerExitedEdge()
        presentation.beginInteraction()
        presentation.endInteraction()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func endingInteractionInEdgeZoneDoesNotHide() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.beginInteraction()
        presentation.endInteraction()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == true)
    }

    @Test func endingInteractionWhenNotPeekingSchedulesNothing() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.beginInteraction()
        presentation.endInteraction()
        #expect(scheduler.pendingCount == 0)
        #expect(presentation.isPeeking == false)
    }

    @Test func interactionAfterPointerLeavesHidesWhenItEnds() {
        let (presentation, scheduler) = makePeekingFromEdge()
        presentation.pointerEnteredCard()
        presentation.pointerExitedEdge()
        presentation.beginInteraction()
        presentation.pointerExitedCard()
        scheduler.advance(by: 5)
        // The hide from leaving the card fired during the interaction.
        #expect(presentation.isPeeking == true)
        presentation.endInteraction()
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
    }

    // MARK: Invariant

    @Test func pinnedNeverPeeksThroughAnyInput() {
        let (presentation, scheduler) = makePinned()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: 1)
        presentation.flash()
        presentation.pointerEnteredCard()
        presentation.beginInteraction()
        presentation.endInteraction()
        presentation.pointerExitedCard()
        presentation.pointerExitedEdge()
        scheduler.advance(by: 5)
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
    }

    @Test func pinningDuringPeekNeverLeavesPeekingSet() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.pointerEnteredEdge()
        presentation.toggle()
        #expect(presentation.isCollapsed == false)
        #expect(presentation.isPeeking == false)
        presentation.pointerExitedEdge()
        scheduler.advance(by: 5)
        #expect(presentation.isPeeking == false)
    }
}
