import CoreGraphics
import Foundation
import Testing
@testable import Nubb

// White-box tests for TabSidebarCore.swift. They target edge cases the
// black-box suites don't reach: path normalization in the git walk, odd
// `.git`/HEAD encodings, scheduler interleavings, and degenerate inputs to the
// pure helpers. Every test is bounded (the fake clock caps its work loop).

// MARK: - Fake scheduler

private final class WhiteBoxScheduledWork: TabSidebarCancellable {
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

    func cancel() { isCancelled = true }

    var isPending: Bool { !isCancelled && !hasFired }
}

/// Manual clock. Work runs only from `advance(by:)`, in time order (ties in
/// scheduling order). The work loop is capped so a runaway reschedule cycle
/// fails the test instead of hanging it.
private final class WhiteBoxFakeScheduler: TabSidebarScheduler {
    private static let epsilon: TimeInterval = 1e-9
    private static let maxStepsPerAdvance = 10_000

    private(set) var now: TimeInterval = 0
    private var items: [WhiteBoxScheduledWork] = []
    private var nextSequence = 0
    private(set) var hitStepLimit = false
    private(set) var firedCount = 0

    var scheduledCount: Int { items.count }
    var pendingCount: Int { items.filter(\.isPending).count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TabSidebarCancellable {
        let item = WhiteBoxScheduledWork(fireAt: now + delay, sequence: nextSequence, work: work)
        nextSequence += 1
        items.append(item)
        return item
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        var steps = 0
        while let next = nextDue(before: target) {
            steps += 1
            if steps > Self.maxStepsPerAdvance {
                hitStepLimit = true
                break
            }
            now = max(now, next.fireAt)
            next.hasFired = true
            firedCount += 1
            next.work()
        }
        now = target
    }

    private func nextDue(before target: TimeInterval) -> WhiteBoxScheduledWork? {
        items
            .filter { $0.isPending && $0.fireAt <= target + Self.epsilon }
            .min { lhs, rhs in
                if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
                return lhs.sequence < rhs.sequence
            }
    }
}

@Suite
struct TabSidebarWhiteBoxTests {
    private let timing = TabSidebarPresentation.Timing.standard

    // MARK: - Fixtures

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-tab-sidebar-whitebox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
    }

    private func makeRepository(at directory: URL, head: String) throws {
        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        try makeDirectory(gitDirectory)
        try write(head, to: gitDirectory.appendingPathComponent("HEAD"))
    }

    private func makeCollapsed() -> (TabSidebarPresentation, WhiteBoxFakeScheduler) {
        let scheduler = WhiteBoxFakeScheduler()
        return (TabSidebarPresentation(isCollapsed: true, timing: .standard, scheduler: scheduler), scheduler)
    }

    private func expectInvariant(_ presentation: TabSidebarPresentation, sourceLocation: SourceLocation = #_sourceLocation) {
        if !presentation.isCollapsed {
            #expect(presentation.isPeeking == false, sourceLocation: sourceLocation)
        }
        #expect(presentation.isSidebarVisible == (!presentation.isCollapsed || presentation.isPeeking),
                sourceLocation: sourceLocation)
    }

    // MARK: - Git: walk termination and path normalization

    @Test func gitWalkFromRootTerminates() {
        // The walk must stop at "/" for every spelling of the root. A
        // regression in the stop condition hangs here.
        guard !FileManager.default.fileExists(atPath: "/.git") else { return }
        let roots: [URL] = [
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "//", isDirectory: true),
            URL(fileURLWithPath: "/..", isDirectory: true),
            URL(fileURLWithPath: "/../../..", isDirectory: true),
            URL(fileURLWithPath: "/./.", isDirectory: true),
            URL(string: "file:///")!,
        ]
        for root in roots {
            #expect(TabSidebarGit.branch(atDirectory: root) == nil, "\(root)")
        }
    }

    @Test func gitWalkFromSchemelessRelativeURLTerminates() {
        // Relative, unresolved paths such as ".." must still reach a stop.
        // The answer depends on the process cwd, so only require termination
        // and that an empty branch name is never produced.
        for raw in ["..", "../..", ".", "a/b/../..", ""] {
            guard let url = URL(string: raw) else { continue }
            let result = TabSidebarGit.branch(atDirectory: url)
            #expect(result.map { !$0.isEmpty } ?? true, "\(raw)")
        }
    }

    @Test func gitWalkResolvesDotAndDotDotComponents() throws {
        try withTemporaryDirectory { root in
            let repo = root.appendingPathComponent("repo", isDirectory: true)
            try makeRepository(at: repo, head: "ref: refs/heads/main\n")
            let other = root.appendingPathComponent("other", isDirectory: true)
            try makeDirectory(other)

            // other/../repo is repo, whose .git decides the answer.
            let viaDotDot = URL(fileURLWithPath: "other/../repo", isDirectory: true, relativeTo: root)
            #expect(TabSidebarGit.branch(atDirectory: viaDotDot) == "main")

            let viaDot = URL(fileURLWithPath: "./repo/./.", isDirectory: true, relativeTo: root)
            #expect(TabSidebarGit.branch(atDirectory: viaDot) == "main")

            // repo/sub/.. walks from repo, not from sub.
            let sub = repo.appendingPathComponent("sub", isDirectory: true)
            try makeDirectory(sub)
            let absolute = URL(fileURLWithPath: sub.path + "/..", isDirectory: true)
            #expect(TabSidebarGit.branch(atDirectory: absolute) == "main")
        }
    }

    @Test func gitWalkIgnoresTrailingAndDoubledSlashes() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main\n")
            let nested = root.appendingPathComponent("a/b", isDirectory: true)
            try makeDirectory(nested)
            for raw in [nested.path + "/", nested.path + "///", root.path + "//a//b//"] {
                #expect(TabSidebarGit.branch(atDirectory: URL(fileURLWithPath: raw)) == "main", "\(raw)")
            }
        }
    }

    @Test func gitWalkFromNonexistentDirectoryStillFindsAncestorRepo() throws {
        // A tab's cwd can be deleted while the shell sits in it. The walk is
        // over path components, so the enclosing repo still decides.
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main\n")
            let ghost = root.appendingPathComponent("gone/away", isDirectory: true)
            #expect(TabSidebarGit.branch(atDirectory: ghost) == "main")
        }
    }

    @Test func gitWalkFromInsideDotGitFindsTheRepo() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/main\n")
            let inside = root.appendingPathComponent(".git/refs/heads", isDirectory: true)
            try makeDirectory(inside)
            #expect(TabSidebarGit.branch(atDirectory: inside) == "main")
        }
    }

    @Test func gitWalkThroughSymlinkToRepoRoot() throws {
        try withTemporaryDirectory { root in
            let repo = root.appendingPathComponent("real/repo", isDirectory: true)
            try makeRepository(at: repo, head: "ref: refs/heads/linked\n")
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
            // link/.git exists through the symlink either way the path is read.
            #expect(TabSidebarGit.branch(atDirectory: link) == "linked")
        }
    }

    @Test func gitDirectorySymlinkIsFollowed() throws {
        try withTemporaryDirectory { root in
            let store = root.appendingPathComponent("store", isDirectory: true)
            try makeDirectory(store)
            try write("ref: refs/heads/via-link\n", to: store.appendingPathComponent("HEAD"))
            let work = root.appendingPathComponent("work", isDirectory: true)
            try makeDirectory(work)
            try FileManager.default.createSymbolicLink(
                at: work.appendingPathComponent(".git"), withDestinationURL: store)
            #expect(TabSidebarGit.branch(atDirectory: work) == "via-link")
        }
    }

    @Test func headThatIsADirectoryReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child.appendingPathComponent(".git/HEAD", isDirectory: true))
            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    @Test func headWithInvalidUTF8ReturnsNil() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            let gitDirectory = child.appendingPathComponent(".git", isDirectory: true)
            try makeDirectory(gitDirectory)
            try Data([0xFF, 0xFE, 0x80, 0x0A]).write(to: gitDirectory.appendingPathComponent("HEAD"))
            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    // MARK: - Git: .git file encodings

    @Test func gitFileWithCRLFAndExtraWhitespace() throws {
        try withTemporaryDirectory { root in
            let store = root.appendingPathComponent("store/wt", isDirectory: true)
            try makeDirectory(store)
            try write("ref: refs/heads/crlf\r\n", to: store.appendingPathComponent("HEAD"))

            let absolute = root.appendingPathComponent("abs", isDirectory: true)
            try makeDirectory(absolute)
            try write("gitdir:   \(store.path)   \r\n", to: absolute.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: absolute) == "crlf")

            let relative = root.appendingPathComponent("rel", isDirectory: true)
            try makeDirectory(relative)
            try write("\r\n gitdir:\t../store/wt \t\r\n\r\n", to: relative.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: relative) == "crlf")
        }
    }

    @Test func gitFileWithoutSpaceAfterColon() throws {
        try withTemporaryDirectory { root in
            let store = root.appendingPathComponent("store", isDirectory: true)
            try makeDirectory(store)
            try write("ref: refs/heads/tight\n", to: store.appendingPathComponent("HEAD"))
            let work = root.appendingPathComponent("work", isDirectory: true)
            try makeDirectory(work)
            try write("gitdir:\(store.path)\n", to: work.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: work) == "tight")
        }
    }

    @Test func gitFileWithTrailingSlashOnGitdir() throws {
        try withTemporaryDirectory { root in
            let store = root.appendingPathComponent("store", isDirectory: true)
            try makeDirectory(store)
            try write("ref: refs/heads/slashed\n", to: store.appendingPathComponent("HEAD"))
            let work = root.appendingPathComponent("work", isDirectory: true)
            try makeDirectory(work)
            try write("gitdir: \(store.path)/\n", to: work.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: work) == "slashed")

            let relative = root.appendingPathComponent("work2", isDirectory: true)
            try makeDirectory(relative)
            try write("gitdir: ../store/\n", to: relative.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: relative) == "slashed")
        }
    }

    @Test func gitFileWithEmptyGitdirDoesNotSearchParents() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            for (index, content) in ["gitdir:", "gitdir:   \r\n", "gitdir:\t\t\n"].enumerated() {
                let child = root.appendingPathComponent("child\(index)", isDirectory: true)
                try makeDirectory(child)
                try write(content, to: child.appendingPathComponent(".git"))
                #expect(TabSidebarGit.branch(atDirectory: child) == nil, "\(content.debugDescription)")
            }
        }
    }

    @Test func gitFileWithInvalidUTF8DoesNotSearchParents() throws {
        try withTemporaryDirectory { root in
            try makeRepository(at: root, head: "ref: refs/heads/parent\n")
            let child = root.appendingPathComponent("child", isDirectory: true)
            try makeDirectory(child)
            try Data([0x67, 0x69, 0xFF, 0xFE]).write(to: child.appendingPathComponent(".git"))
            #expect(TabSidebarGit.branch(atDirectory: child) == nil)
        }
    }

    // MARK: - Git: HEAD parsing

    @Test func headWithCRLF() {
        #expect(TabSidebarGit.branch(fromHead: "ref: refs/heads/main\r\n") == "main")
        #expect(TabSidebarGit.branch(fromHead: "\r\nref: refs/heads/feat/x\r\n\r\n") == "feat/x")
        let sha = "0123456789abcdef0123456789abcdef01234567"
        #expect(TabSidebarGit.branch(fromHead: sha + "\r\n") == "0123456")
    }

    @Test func headRefWithEmptyBranchNameNeverYieldsEmptyString() {
        // `ref: refs/heads/` has no name. Whatever is returned, an empty
        // label would render as a blank branch badge.
        let result = TabSidebarGit.branch(fromHead: "ref: refs/heads/\n")
        #expect(result != "")
        // Under the "any other ref is returned as written" rule:
        #expect(result == "refs/heads/")
    }

    @Test func headRefWithOnlyWhitespaceAfterColonIsNotEmpty() {
        for head in ["ref:", "ref: ", "ref:   \t\n", "ref:\r\n"] {
            let result = TabSidebarGit.branch(fromHead: head)
            #expect(result.map { !$0.isEmpty } ?? true, "\(head.debugDescription)")
        }
    }

    @Test func uppercaseHexObjectIdIsDetached() {
        let sha = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
        #expect(TabSidebarGit.branch(fromHead: sha) == "ABCDEF0")
    }

    @Test func objectIdOfThirtyNineOrSixtyFiveHexCharactersIsNil() {
        #expect(TabSidebarGit.branch(fromHead: String(repeating: "a", count: 39)) == nil)
        #expect(TabSidebarGit.branch(fromHead: String(repeating: "a", count: 63)) == nil)
        #expect(TabSidebarGit.branch(fromHead: String(repeating: "a", count: 65)) == nil)
    }

    @Test func fullwidthHexDigitsAreNotAnObjectId() {
        // Character.isHexDigit accepts fullwidth forms (U+FF10-FF19,
        // U+FF21-FF26, U+FF41-FF46). A git object id is ASCII hex, so a HEAD
        // of 40 fullwidth "ａ" is "anything else" and must give nil.
        let fullwidth = String(repeating: "\u{FF41}", count: 40)
        #expect(fullwidth.count == 40)
        #expect(TabSidebarGit.branch(fromHead: fullwidth) == nil)
    }

    @Test func objectIdWithCombiningMarksIsNil() {
        // 40 graphemes, each "a" + combining acute: not hex.
        let combining = String(repeating: "a\u{301}", count: 40)
        #expect(TabSidebarGit.branch(fromHead: combining) == nil)
    }

    // MARK: - Presentation: storms and interleavings

    @Test func edgeEnterStormSchedulesOneShow() {
        let (presentation, scheduler) = makeCollapsed()
        for _ in 0..<500 { presentation.pointerEnteredEdge() }
        #expect(scheduler.scheduledCount == 1)
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
        #expect(scheduler.hitStepLimit == false)
    }

    @Test func edgeEnterExitStormNeverPeeksAndLeavesNothingPending() {
        let (presentation, scheduler) = makeCollapsed()
        for _ in 0..<500 {
            presentation.pointerEnteredEdge()
            #expect(scheduler.pendingCount <= 1)
            scheduler.advance(by: timing.showDelay / 4)
            presentation.pointerExitedEdge()
            #expect(scheduler.pendingCount == 0)
        }
        scheduler.advance(by: 10)
        #expect(presentation.isPeeking == false)
        #expect(scheduler.hitStepLimit == false)
    }

    @Test func edgeStormWhilePeekingEndsHiddenAfterFinalExit() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
        for _ in 0..<500 {
            presentation.pointerExitedEdge()
            presentation.pointerEnteredEdge()
            #expect(scheduler.pendingCount == 0)
        }
        presentation.pointerExitedEdge()
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
    }

    @Test func toggleStormKeepsInvariantAndNothingPending() {
        let (presentation, scheduler) = makeCollapsed()
        for index in 0..<1_001 {
            if index % 3 == 0 { presentation.flash() }
            if index % 5 == 0 { presentation.pointerEnteredEdge() }
            presentation.toggle()
            expectInvariant(presentation)
            #expect(scheduler.pendingCount <= 1)
        }
        // 1001 toggles from collapsed ends pinned.
        #expect(presentation.isCollapsed == false)
        scheduler.advance(by: 10)
        #expect(presentation.isPeeking == false)
    }

    @Test func cancelledShowFromFlashNeverFiresLater() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.flash()
        presentation.dismissPeek()
        // The show scheduled by the edge enter was cancelled by flash.
        scheduler.advance(by: timing.showDelay * 2)
        #expect(presentation.isPeeking == false)
    }

    @Test func showCanBeRescheduledAfterToggleRoundTrip() {
        // toggle() must clear the pending show handle, otherwise the
        // `pendingShow == nil` guard blocks every later peek.
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.toggle()
        presentation.toggle()
        presentation.pointerExitedEdge()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
    }

    @Test func showCanBeRescheduledAfterFlashCancelsIt() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.flash()
        presentation.pointerExitedEdge()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == false)
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
    }

    @Test func showCanBeRescheduledAfterDismissPeek() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.pointerEnteredEdge()
        presentation.dismissPeek()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
    }

    @Test func hideAfterToggleRoundTripDoesNotFire() {
        // flash, pin, collapse again, then peek from the edge: the flash's
        // hide was cancelled by toggle and must not end the new peek early.
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        scheduler.advance(by: 0.5)
        presentation.toggle()
        presentation.toggle()
        presentation.pointerEnteredEdge()
        scheduler.advance(by: timing.showDelay)
        #expect(presentation.isPeeking == true)
        presentation.pointerEnteredCard()
        presentation.pointerExitedEdge()
        scheduler.advance(by: timing.flashDuration)
        #expect(presentation.isPeeking == true)
    }

    @Test func edgeExitDuringFlashReplacesFlashHide() {
        // Peeking via flash with the pointer passing through the edge zone:
        // the exit schedules a hideDelay hide that replaces the flash hide.
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.pointerEnteredEdge()
        presentation.pointerExitedEdge()
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: timing.hideDelay - 0.01)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
    }

    @Test func spuriousEdgeExitDuringFlashSchedulesHideDelayHide() {
        // pointerExitedEdge without a matching enter while peeking still
        // follows the rule: peeking and not over the card schedules a hide.
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.pointerExitedEdge()
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
    }

    @Test func endInteractionReplacesPendingFlashHide() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        presentation.beginInteraction()
        scheduler.advance(by: 0.1)
        presentation.endInteraction()
        #expect(scheduler.pendingCount == 1)
        // New hide due at 0.1 + 0.35, well before the 1.0 flash hide.
        scheduler.advance(by: timing.hideDelay - 0.01)
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0.01)
        #expect(presentation.isPeeking == false)
    }

    @Test func endInteractionUnderflowStormIsIgnored() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        for _ in 0..<1_000 { presentation.endInteraction() }
        // A single begin must still suppress the hide.
        presentation.beginInteraction()
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
        // And a single end brings the count back to zero.
        presentation.endInteraction()
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
    }

    @Test func deeplyNestedInteractionsNeedEveryEnd() {
        let (presentation, scheduler) = makeCollapsed()
        presentation.flash()
        for _ in 0..<1_000 { presentation.beginInteraction() }
        for _ in 0..<999 { presentation.endInteraction() }
        scheduler.advance(by: timing.flashDuration + 1)
        #expect(presentation.isPeeking == true)
        #expect(scheduler.pendingCount == 0)
        presentation.endInteraction()
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: timing.hideDelay)
        #expect(presentation.isPeeking == false)
    }

    @Test func zeroDelaysStillRespectRules() {
        let scheduler = WhiteBoxFakeScheduler()
        let zero = TabSidebarPresentation.Timing(showDelay: 0, hideDelay: 0, flashDuration: 0)
        let presentation = TabSidebarPresentation(isCollapsed: true, timing: zero, scheduler: scheduler)
        presentation.pointerEnteredEdge()
        #expect(presentation.isPeeking == false)
        scheduler.advance(by: 0)
        #expect(presentation.isPeeking == true)
        presentation.pointerExitedEdge()
        scheduler.advance(by: 0)
        #expect(presentation.isPeeking == false)
        presentation.flash()
        #expect(presentation.isPeeking == true)
        scheduler.advance(by: 0)
        #expect(presentation.isPeeking == false)
        #expect(scheduler.hitStepLimit == false)
    }

    @Test func pendingWorkAfterDeallocationDoesNotCrash() {
        let scheduler = WhiteBoxFakeScheduler()
        do {
            let presentation = TabSidebarPresentation(isCollapsed: true, timing: .standard, scheduler: scheduler)
            presentation.pointerEnteredEdge()
            scheduler.advance(by: timing.showDelay)
            presentation.pointerExitedEdge()
            presentation.flash()
            #expect(scheduler.pendingCount == 1)
        }
        scheduler.advance(by: 10)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.firedCount == 2)
    }

    // MARK: - Reorder

    /// Four stacked 20pt rows: midYs 10, 30, 50, 70.
    private var rows: [CGRect] { (0..<4).map { CGRect(x: 0, y: CGFloat($0) * 20, width: 200, height: 20) } }

    @Test func destinationWithOutOfRangeDraggedIndexConsidersAllRows() {
        // No row has that index, so "the rows other than draggedIndex" is
        // every row.
        for dragged in [-1, 4, 99, Int.min, Int.max] {
            #expect(TabSidebarReorder.destinationIndex(pointerY: 40, rowFrames: rows, draggedIndex: dragged) == 2)
            #expect(TabSidebarReorder.destinationIndex(pointerY: 500, rowFrames: rows, draggedIndex: dragged) == 4)
            #expect(TabSidebarReorder.destinationIndex(pointerY: -500, rowFrames: rows, draggedIndex: dragged) == 0)
        }
    }

    @Test func destinationOnEmptyRowsWithAnyDraggedIndexIsZero() {
        for dragged in [-1, 0, 5, Int.max] {
            #expect(TabSidebarReorder.destinationIndex(pointerY: 0, rowFrames: [], draggedIndex: dragged) == 0)
        }
    }

    @Test func destinationUsesRowOrderNotGeometryForUnsortedFrames() {
        // midYs in order: 70, 50, 30, 10. Dragging index 0 leaves 50, 30, 10.
        let reversed = Array(rows.reversed())
        #expect(TabSidebarReorder.destinationIndex(pointerY: 40, rowFrames: reversed, draggedIndex: 0) == 0)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 60, rowFrames: reversed, draggedIndex: 0) == 3)
        // Dragging index 3 (mid 10) leaves 70, 50, 30: first > 55 is index 0.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 55, rowFrames: reversed, draggedIndex: 3) == 0)
    }

    @Test func destinationWithDuplicatedFrames() {
        let same = Array(repeating: CGRect(x: 0, y: 0, width: 200, height: 20), count: 5)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 9, rowFrames: same, draggedIndex: 2) == 0)
        // midY 10 is not greater than 10.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 10, rowFrames: same, draggedIndex: 2) == 4)
    }

    @Test func destinationWithOverlappingFrames() {
        let overlapping = [
            CGRect(x: 0, y: 0, width: 200, height: 40),   // mid 20
            CGRect(x: 0, y: 10, width: 200, height: 40),  // mid 30
            CGRect(x: 0, y: 20, width: 200, height: 40),  // mid 40
        ]
        #expect(TabSidebarReorder.destinationIndex(pointerY: 25, rowFrames: overlapping, draggedIndex: 0) == 0)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 35, rowFrames: overlapping, draggedIndex: 0) == 1)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 35, rowFrames: overlapping, draggedIndex: 2) == 2)
    }

    @Test func destinationWithNonFinitePointerStaysInRange() {
        for y in [CGFloat.nan, .infinity, -.infinity] {
            let result = TabSidebarReorder.destinationIndex(pointerY: y, rowFrames: rows, draggedIndex: 1)
            #expect((0...3).contains(result), "\(y)")
        }
        #expect(TabSidebarReorder.destinationIndex(pointerY: -.infinity, rowFrames: rows, draggedIndex: 1) == 0)
        #expect(TabSidebarReorder.destinationIndex(pointerY: .infinity, rowFrames: rows, draggedIndex: 1) == 3)
    }

    @Test func movedWithExtremeIndicesReturnsItemsUnchanged() {
        let items = ["a", "b", "c"]
        for (source, destination) in [(Int.min, 0), (0, Int.min), (Int.max, 1), (1, Int.max), (-5, -5)] {
            #expect(TabSidebarReorder.moved(items, from: source, to: destination) == items)
        }
    }

    @Test func movedSingleElement() {
        #expect(TabSidebarReorder.moved(["only"], from: 0, to: 0) == ["only"])
        #expect(TabSidebarReorder.moved(["only"], from: 0, to: 1) == ["only"])
    }

    @Test func placementNeverReferencesANegativeIndex() {
        for destination in [-1, -10, Int.min] {
            let result = TabSidebarReorder.placement(forDestination: destination, remainingCount: 3)
            #expect(result == .before(0), "\(destination)")
        }
    }

    @Test func placementWithNoRemainingTabsIsNilEvenForNegativeDestination() {
        // Spec: remainingCount == 0 gives nil. `.before(0)` here would point
        // at a tab that does not exist.
        for destination in [-1, -10, Int.min] {
            #expect(TabSidebarReorder.placement(forDestination: destination, remainingCount: 0) == nil,
                    "\(destination)")
        }
    }

    @Test func placementAtIntMaxDestination() {
        #expect(TabSidebarReorder.placement(forDestination: Int.max, remainingCount: 3) == .after(2))
    }

    @Test func destinationThenPlacementRoundTripStaysInRange() {
        // The real drop path feeds destinationIndex into placement. For every
        // dragged row and pointer position the placement must reference a
        // remaining tab.
        let frames = rows
        for dragged in frames.indices {
            for y in stride(from: CGFloat(-20), through: 100, by: 5) {
                let destination = TabSidebarReorder.destinationIndex(pointerY: y, rowFrames: frames, draggedIndex: dragged)
                let remaining = frames.count - 1
                switch TabSidebarReorder.placement(forDestination: destination, remainingCount: remaining) {
                case .before(let index)?: #expect((0..<remaining).contains(index))
                case .after(let index)?: #expect(index == remaining - 1)
                case nil: Issue.record("nil placement with \(remaining) remaining tabs")
                }
            }
        }
    }

    // MARK: - Format

    @Test func abbreviatedPathWithRootHome() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a", home: "/") == "~/Users/a")
        #expect(TabSidebarFormat.abbreviatedPath("/x/", home: "/") == "~/x")
        #expect(TabSidebarFormat.abbreviatedPath("/x", home: "///") == "~/x")
    }

    @Test func abbreviatedPathOfOnlySlashes() {
        #expect(TabSidebarFormat.abbreviatedPath("///", home: "/Users/a") == "/")
        #expect(TabSidebarFormat.abbreviatedPath("//", home: "") == "/")
        #expect(TabSidebarFormat.abbreviatedPath("////", home: "//") == "~")
    }

    @Test func abbreviatedPathWithHomeOfManyTrailingSlashes() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a", home: "/Users/a////") == "~")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/x", home: "/Users/a////") == "~/x")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/ab", home: "/Users/a////") == "/Users/ab")
    }

    @Test func abbreviatedPathHomeLongerThanPath() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users", home: "/Users/a") == "/Users")
        #expect(TabSidebarFormat.abbreviatedPath("", home: "/Users/a") == "")
        #expect(TabSidebarFormat.abbreviatedPath("", home: "") == "")
    }

    @Test func abbreviatedPathWithNonASCIIHome() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/zoë/code", home: "/Users/zoë") == "~/code")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/zoë🎉/x", home: "/Users/zoë🎉") == "~/x")
    }

    @Test func displayTitleWithSlashOnlyDirectories() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "///") == "/")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "//a") == "a")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "a//") == "a")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "/Users/a/project/") == "project")
    }

    @Test func displayTitleWithTildeTrailingSlash() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "~/") == "~")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "~///") == "~")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "~/code/x/") == "x")
    }

    @Test func displayTitleWithRelativeDirectory() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "project") == "project")
    }

    @Test func displayTitleWithWhitespaceOnlyDirectoryUsesItAsComponent() {
        // The directory is non-nil and non-empty, so its last component is
        // used as written. It must not crash or fall through to "Terminal".
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "   ") == "   ")
        #expect(TabSidebarFormat.displayTitle(title: "\n", directory: "/a/ /") == " ")
    }

    // MARK: - Shortcuts

    @Test func singleTabWithNoGotoUsesLastTab() {
        #expect(TabSidebarShortcuts.labels(tabCount: 1, gotoTab: { _ in nil }, lastTab: { "LAST" }) == ["LAST"])
    }

    @Test func singleTabWithNothingBoundIsNil() {
        let labels = TabSidebarShortcuts.labels(tabCount: 1, gotoTab: { _ in nil }, lastTab: { nil })
        #expect(labels.count == 1)
        #expect(labels[0] == nil)
    }

    @Test func singleTabOnlyAsksForGotoOne() {
        var requested: [Int] = []
        _ = TabSidebarShortcuts.labels(tabCount: 1, gotoTab: { requested.append($0); return nil }, lastTab: { nil })
        #expect(requested.allSatisfy { $0 == 1 })
    }

    @Test func nineTabsWithNothingBoundOnlyLabelsLast() {
        let labels = TabSidebarShortcuts.labels(tabCount: 9, gotoTab: { _ in nil }, lastTab: { "LAST" })
        let expected: [String?] = [nil, nil, nil, nil, nil, nil, nil, nil, "LAST"]
        #expect(labels == expected)
    }

    @Test func tenTabsAllGotoBoundUsesLastTabForTenth() {
        let labels = TabSidebarShortcuts.labels(tabCount: 10, gotoTab: { "g\($0)" }, lastTab: { "LAST" })
        let expected: [String?] = ["g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8", "g9", "LAST"]
        #expect(labels == expected)
    }

    @Test func tenTabsWithNilLastTab() {
        let labels = TabSidebarShortcuts.labels(tabCount: 10, gotoTab: { "g\($0)" }, lastTab: { nil })
        #expect(labels.count == 10)
        #expect(labels[8] == "g9")
        #expect(labels[9] == nil)
    }

    @Test func sparseGotoBindingsFallBackOnlyOnLastIndex() {
        let odd: (Int) -> String? = { $0 % 2 == 1 ? "g\($0)" : nil }
        let labels = TabSidebarShortcuts.labels(tabCount: 4, gotoTab: odd, lastTab: { "LAST" })
        #expect(labels == ["g1", nil, "g3", "LAST"])
    }

    @Test func manyTabsStayBounded() {
        var gotoCalls = 0
        let labels = TabSidebarShortcuts.labels(
            tabCount: 1_000,
            gotoTab: { number in gotoCalls += 1; return number <= 9 ? "g\(number)" : nil },
            lastTab: { "LAST" })
        #expect(labels.count == 1_000)
        #expect(gotoCalls <= 9)
        #expect(labels[999] == "LAST")
        #expect(labels[9..<999].allSatisfy { $0 == nil })
    }

    // MARK: - Metrics

    @Test func clampedWidthWithNonFiniteProposalStaysInRange() {
        // A NaN width (e.g. from a corrupt saved value) must still be limited
        // to minimumWidth ... upper.
        let upper: CGFloat = 400
        for proposed in [CGFloat.nan, .infinity, -.infinity] {
            let width = TabSidebarMetrics.clampedWidth(proposed, windowWidth: 1_000)
            #expect(width >= TabSidebarMetrics.minimumWidth && width <= upper, "\(proposed) -> \(width)")
        }
        #expect(TabSidebarMetrics.clampedWidth(.infinity, windowWidth: 1_000) == 400)
        #expect(TabSidebarMetrics.clampedWidth(-.infinity, windowWidth: 1_000) == 180)
    }

    @Test func clampedWidthWithNonFiniteOrNegativeWindow() {
        #expect(TabSidebarMetrics.clampedWidth(300, windowWidth: .infinity) == 300)
        #expect(TabSidebarMetrics.clampedWidth(500, windowWidth: .infinity) == 400)
        #expect(TabSidebarMetrics.clampedWidth(300, windowWidth: -1_000) == 180)
        let nanWindow = TabSidebarMetrics.clampedWidth(300, windowWidth: .nan)
        #expect(nanWindow >= 180 && nanWindow <= 400)
    }
}
