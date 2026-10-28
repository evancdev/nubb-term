import AppKit
import Testing
@testable import Nubb

/// The titlebar accessory: the sidebar toggle with a new tab button right
/// after it. Clicks go through the real NSButtons.
@Suite
struct TabSidebarTitlebarAccessoryTests {
    @MainActor
    private func makeAccessory(onNewTab: @escaping () -> Void) -> (TabSidebarTitlebarAccessory, TabSidebarModel) {
        let model = TabSidebarModel(
            controller: nil,
            groupState: TabSidebarGroupState(isCollapsed: false, width: TabSidebarMetrics.defaultWidth))
        let accessory = TabSidebarTitlebarAccessory(model: model, onNewTab: onNewTab)
        accessory.loadView()
        accessory.view.layoutSubtreeIfNeeded()
        return (accessory, model)
    }

    @MainActor
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
    }

    @MainActor @Test
    func newTabButtonSitsRightAfterTheSidebarToggle() throws {
        let (accessory, _) = makeAccessory {}
        let buttons = buttons(in: accessory.view)
        try #require(buttons.count == 2)

        let toggle = buttons[0]
        let plus = buttons[1]
        #expect(toggle.image?.accessibilityDescription == "Toggle Tab Sidebar")
        #expect(plus.image?.accessibilityDescription == "New Tab")
        #expect(plus.frame.minX >= toggle.frame.maxX)
        #expect(plus.frame.minX - toggle.frame.maxX <= 4)
        #expect(abs(plus.frame.midY - toggle.frame.midY) <= 1)
        #expect(plus.frame.maxX <= accessory.view.frame.width)
        #expect(plus.toolTip?.hasPrefix("New Tab") == true)
    }

    @MainActor @Test
    func clickingPlusOpensOneNewTab() throws {
        var newTabs = 0
        let (accessory, model) = makeAccessory { newTabs += 1 }
        let plus = try #require(buttons(in: accessory.view).last)

        plus.performClick(nil)

        #expect(newTabs == 1)
        #expect(model.presentation.isCollapsed == false)
    }

    @MainActor @Test
    func toggleAndPlusAreSeparateActions() throws {
        var newTabs = 0
        let (accessory, _) = makeAccessory { newTabs += 1 }
        let buttons = buttons(in: accessory.view)
        let toggle = try #require(buttons.first)
        let plus = try #require(buttons.last)

        // The toggle collapses the sidebar (needs a real window to take
        // effect) and must never open a tab.
        #expect(toggle.action != plus.action)
        #expect(toggle.target === accessory)
        toggle.performClick(nil)
        #expect(newTabs == 0)
    }
}
