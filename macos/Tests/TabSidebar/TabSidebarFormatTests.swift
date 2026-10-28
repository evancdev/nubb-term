import CoreGraphics
import Foundation
import Testing
@testable import Nubb

// MARK: - TabSidebarFormat

@Suite
struct TabSidebarFormatTests {
    // MARK: abbreviatedPath

    @Test func pathEqualToHomeIsTilde() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a", home: "/Users/a") == "~")
    }

    @Test func pathInsideHomeIsAbbreviated() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/code/x", home: "/Users/a") == "~/code/x")
    }

    @Test func pathSharingOnlyAPrefixWithHomeIsUnchanged() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/ab", home: "/Users/a") == "/Users/ab")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/ab/code", home: "/Users/a") == "/Users/ab/code")
    }

    @Test func pathOutsideHomeIsUnchanged() {
        #expect(TabSidebarFormat.abbreviatedPath("/tmp/build", home: "/Users/a") == "/tmp/build")
    }

    @Test func trailingSlashOnPathIsDropped() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/", home: "/Users/a") == "~")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/code/x/", home: "/Users/a") == "~/code/x")
        #expect(TabSidebarFormat.abbreviatedPath("/tmp/build//", home: "/Users/a") == "/tmp/build")
    }

    @Test func trailingSlashOnHomeIsDropped() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a", home: "/Users/a/") == "~")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/code", home: "/Users/a/") == "~/code")
    }

    @Test func emptyHomeReturnsSlashTrimmedPath() {
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a/code/", home: "") == "/Users/a/code")
        #expect(TabSidebarFormat.abbreviatedPath("/Users/a", home: "") == "/Users/a")
    }

    @Test func rootStaysRoot() {
        #expect(TabSidebarFormat.abbreviatedPath("/", home: "/Users/a") == "/")
        #expect(TabSidebarFormat.abbreviatedPath("/", home: "") == "/")
    }

    @Test func rootHomeEqualToRootPathIsTilde() {
        // `/` stays `/` after trimming, so path == home.
        #expect(TabSidebarFormat.abbreviatedPath("/", home: "/") == "~")
    }

    // MARK: displayTitle

    @Test func displayTitleUsesTrimmedTitle() {
        #expect(TabSidebarFormat.displayTitle(title: "  vim main.swift \n", directory: "~/code/x") == "vim main.swift")
    }

    @Test func displayTitleFallsBackToLastPathComponent() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "~/code/x") == "x")
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "/Users/a/project") == "project")
    }

    @Test func displayTitleBlankTitleFallsBackToDirectory() {
        #expect(TabSidebarFormat.displayTitle(title: " \n\t ", directory: "~/code/x") == "x")
    }

    @Test func displayTitleTildeDirectoryStaysTilde() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "~") == "~")
    }

    @Test func displayTitleRootDirectoryStaysRoot() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "/") == "/")
    }

    @Test func displayTitleNilDirectoryIsTerminal() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: nil) == "Terminal")
        #expect(TabSidebarFormat.displayTitle(title: "   ", directory: nil) == "Terminal")
    }

    @Test func displayTitleEmptyDirectoryIsTerminal() {
        #expect(TabSidebarFormat.displayTitle(title: "", directory: "") == "Terminal")
    }
}

// MARK: - TabSidebarShortcuts

@Suite
struct TabSidebarShortcutsTests {
    /// Default bindings from the spec: goto_tab 1-8 bound, 9 unbound.
    private func defaultGoto(_ number: Int) -> String? {
        (1...8).contains(number) ? "⌘\(number)" : nil
    }

    @Test func threeTabsWithDefaults() {
        let labels = TabSidebarShortcuts.labels(tabCount: 3, gotoTab: defaultGoto, lastTab: { "⌘9" })
        #expect(labels == ["⌘1", "⌘2", "⌘3"])
    }

    @Test func tenTabsWithDefaults() {
        let labels = TabSidebarShortcuts.labels(tabCount: 10, gotoTab: defaultGoto, lastTab: { "⌘9" })
        let expected: [String?] = ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", nil, "⌘9"]
        #expect(labels == expected)
    }

    @Test func nineTabsWithDefaultsUsesLastTabForNinth() {
        let labels = TabSidebarShortcuts.labels(tabCount: 9, gotoTab: defaultGoto, lastTab: { "⌘9" })
        let expected: [String?] = ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9"]
        #expect(labels == expected)
    }

    @Test func singleTabUsesGotoBeforeLastTab() {
        let labels = TabSidebarShortcuts.labels(tabCount: 1, gotoTab: defaultGoto, lastTab: { "LAST" })
        #expect(labels == ["⌘1"])
    }

    @Test func lastIndexFallsBackToLastTabWhenGotoUnbound() {
        let labels = TabSidebarShortcuts.labels(tabCount: 2, gotoTab: { _ in nil }, lastTab: { "LAST" })
        #expect(labels == [nil, "LAST"])
    }

    @Test func boundGotoNineWinsOverLastTabOnNinthTab() {
        let labels = TabSidebarShortcuts.labels(tabCount: 9, gotoTab: { "g\($0)" }, lastTab: { "LAST" })
        #expect(labels.count == 9)
        #expect(labels.last == "g9")
    }

    @Test func tabsBeyondNineGetNilExceptLast() {
        let labels = TabSidebarShortcuts.labels(tabCount: 12, gotoTab: { "g\($0)" }, lastTab: { "LAST" })
        let expected: [String?] = ["g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8", "g9", nil, nil, "LAST"]
        #expect(labels == expected)
    }

    @Test func unboundLastTabLeavesLastLabelNil() {
        let labels = TabSidebarShortcuts.labels(tabCount: 11, gotoTab: defaultGoto, lastTab: { nil })
        #expect(labels.count == 11)
        #expect(labels[8] == nil)
        #expect(labels[10] == nil)
    }

    @Test func gotoTabNeverCalledAboveNine() {
        var requested: [Int] = []
        _ = TabSidebarShortcuts.labels(
            tabCount: 20,
            gotoTab: { number in
                requested.append(number)
                return nil
            },
            lastTab: { "LAST" }
        )
        #expect(!requested.isEmpty)
        #expect(requested.allSatisfy { (1...9).contains($0) })
    }

    @Test func zeroTabsReturnsEmpty() {
        #expect(TabSidebarShortcuts.labels(tabCount: 0, gotoTab: defaultGoto, lastTab: { "⌘9" }).isEmpty)
    }

    @Test func negativeTabCountReturnsEmpty() {
        #expect(TabSidebarShortcuts.labels(tabCount: -3, gotoTab: defaultGoto, lastTab: { "⌘9" }).isEmpty)
    }
}

// MARK: - TabSidebarMetrics

@Suite
struct TabSidebarMetricsTests {
    @Test func widthConstants() {
        #expect(TabSidebarMetrics.defaultWidth == 240)
        #expect(TabSidebarMetrics.minimumWidth == 180)
        #expect(TabSidebarMetrics.maximumWidth == 400)
    }

    @Test func proposedWithinRangeIsUnchanged() {
        #expect(TabSidebarMetrics.clampedWidth(250, windowWidth: 1_000) == 250)
    }

    @Test func proposedBelowMinimumClampsToMinimum() {
        #expect(TabSidebarMetrics.clampedWidth(100, windowWidth: 1_000) == 180)
        #expect(TabSidebarMetrics.clampedWidth(-20, windowWidth: 1_000) == 180)
    }

    @Test func wideWindowCapsAtMaximumWidth() {
        // 60% of 1000 is 600, so the 400 maximum applies.
        #expect(TabSidebarMetrics.clampedWidth(500, windowWidth: 1_000) == 400)
    }

    @Test func mediumWindowCapsAtSixtyPercent() {
        // 60% of 500 is 300.
        #expect(TabSidebarMetrics.clampedWidth(350, windowWidth: 500) == 300)
        #expect(TabSidebarMetrics.clampedWidth(290, windowWidth: 500) == 290)
    }

    @Test func narrowWindowNeverGoesBelowMinimum() {
        // 60% of 200 is 120, below the minimum, so the upper bound is 180.
        #expect(TabSidebarMetrics.clampedWidth(250, windowWidth: 200) == 180)
        #expect(TabSidebarMetrics.clampedWidth(100, windowWidth: 200) == 180)
        #expect(TabSidebarMetrics.clampedWidth(250, windowWidth: 0) == 180)
    }

    @Test func boundsAreInclusive() {
        #expect(TabSidebarMetrics.clampedWidth(180, windowWidth: 1_000) == 180)
        #expect(TabSidebarMetrics.clampedWidth(400, windowWidth: 1_000) == 400)
    }
}

// MARK: - TabSidebarReorder

@Suite
struct TabSidebarReorderTests {
    /// Four stacked 20pt rows: midYs 10, 30, 50, 70.
    private let rows: [CGRect] = (0..<4).map { CGRect(x: 0, y: CGFloat($0) * 20, width: 200, height: 20) }

    // MARK: destinationIndex

    @Test func emptyRowsReturnZero() {
        #expect(TabSidebarReorder.destinationIndex(pointerY: 100, rowFrames: [], draggedIndex: 0) == 0)
    }

    @Test func onlyDraggedRowReturnsZero() {
        let single = [CGRect(x: 0, y: 0, width: 200, height: 20)]
        #expect(TabSidebarReorder.destinationIndex(pointerY: 50, rowFrames: single, draggedIndex: 0) == 0)
    }

    @Test func pointerAboveAllRowsGoesFirst() {
        #expect(TabSidebarReorder.destinationIndex(pointerY: -5, rowFrames: rows, draggedIndex: 2) == 0)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 5, rowFrames: rows, draggedIndex: 2) == 0)
    }

    @Test func pointerBelowAllRowsGoesLast() {
        // Three remaining rows, so the last index is 3.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 200, rowFrames: rows, draggedIndex: 0) == 3)
    }

    @Test func draggedRowIsExcludedFromComparison() {
        // Remaining rows when dragging index 1: midYs 10, 50, 70.
        // pointerY 40 is past row 0's mid but before 50, so k = 1.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 40, rowFrames: rows, draggedIndex: 1) == 1)
        // pointerY 35 is past the dragged row's own mid (30), which is ignored.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 35, rowFrames: rows, draggedIndex: 1) == 1)
    }

    @Test func draggingDownPastRows() {
        // Dragging row 0. Remaining midYs 30, 50, 70.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 55, rowFrames: rows, draggedIndex: 0) == 2)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 25, rowFrames: rows, draggedIndex: 0) == 0)
    }

    @Test func pointerExactlyAtMidYIsNotGreater() {
        // Dragging row 0. Remaining midYs 30, 50, 70. midY must be strictly
        // greater than pointerY, so 50 is skipped and 70 is first.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 50, rowFrames: rows, draggedIndex: 0) == 2)
    }

    @Test func draggingLastRowUp() {
        // Dragging row 3. Remaining midYs 10, 30, 50.
        #expect(TabSidebarReorder.destinationIndex(pointerY: 15, rowFrames: rows, draggedIndex: 3) == 1)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 65, rowFrames: rows, draggedIndex: 3) == 3)
    }

    @Test func rowsWithGapsUseMidY() {
        let spaced = [
            CGRect(x: 0, y: 0, width: 200, height: 30),    // mid 15
            CGRect(x: 0, y: 40, width: 200, height: 30),   // mid 55
            CGRect(x: 0, y: 100, width: 200, height: 60),  // mid 130
        ]
        #expect(TabSidebarReorder.destinationIndex(pointerY: 100, rowFrames: spaced, draggedIndex: 0) == 1)
        #expect(TabSidebarReorder.destinationIndex(pointerY: 140, rowFrames: spaced, draggedIndex: 0) == 2)
    }

    // MARK: moved

    @Test func moveForward() {
        let items = ["a", "b", "c", "d"]
        #expect(TabSidebarReorder.moved(items, from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(TabSidebarReorder.moved(items, from: 0, to: 3) == ["b", "c", "d", "a"])
    }

    @Test func moveBackward() {
        let items = ["a", "b", "c", "d"]
        #expect(TabSidebarReorder.moved(items, from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(TabSidebarReorder.moved(items, from: 2, to: 1) == ["a", "c", "b", "d"])
    }

    @Test func moveToSameIndexIsUnchanged() {
        let items = ["a", "b", "c"]
        #expect(TabSidebarReorder.moved(items, from: 1, to: 1) == items)
    }

    @Test func movedElementLandsAtDestination() {
        let items = Array(0..<8)
        for source in items.indices {
            for destination in items.indices {
                let result = TabSidebarReorder.moved(items, from: source, to: destination)
                #expect(result.count == items.count)
                #expect(result[destination] == items[source])
                var others = result
                others.remove(at: destination)
                #expect(others == items.filter { $0 != items[source] })
            }
        }
    }

    @Test func outOfRangeSourceReturnsItemsUnchanged() {
        let items = ["a", "b", "c"]
        #expect(TabSidebarReorder.moved(items, from: 3, to: 0) == items)
        #expect(TabSidebarReorder.moved(items, from: -1, to: 0) == items)
    }

    @Test func outOfRangeDestinationReturnsItemsUnchanged() {
        let items = ["a", "b", "c"]
        #expect(TabSidebarReorder.moved(items, from: 0, to: 3) == items)
        #expect(TabSidebarReorder.moved(items, from: 0, to: -1) == items)
    }

    @Test func movingInEmptyArrayReturnsEmpty() {
        let items: [Int] = []
        #expect(TabSidebarReorder.moved(items, from: 0, to: 0).isEmpty)
    }

    // MARK: placement

    @Test func destinationBeforeRemainingTab() {
        #expect(TabSidebarReorder.placement(forDestination: 0, remainingCount: 3) == .before(0))
        #expect(TabSidebarReorder.placement(forDestination: 2, remainingCount: 3) == .before(2))
    }

    @Test func destinationAtEndGoesAfterLastRemainingTab() {
        #expect(TabSidebarReorder.placement(forDestination: 3, remainingCount: 3) == .after(2))
        #expect(TabSidebarReorder.placement(forDestination: 1, remainingCount: 1) == .after(0))
    }

    @Test func destinationPastEndGoesAfterLastRemainingTab() {
        #expect(TabSidebarReorder.placement(forDestination: 10, remainingCount: 3) == .after(2))
    }

    @Test func noRemainingTabsGivesNil() {
        #expect(TabSidebarReorder.placement(forDestination: 0, remainingCount: 0) == nil)
        #expect(TabSidebarReorder.placement(forDestination: 5, remainingCount: 0) == nil)
    }
}
