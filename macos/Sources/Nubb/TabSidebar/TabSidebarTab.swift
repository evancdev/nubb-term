import AppKit
import Combine

/// A tab the sidebar can list: terminals and canvases.
///
/// The native tab group stays the source of truth. Every window in it has a
/// controller that conforms to this, and the sidebar reads rows from them
/// and sends actions back.
protocol TabSidebarTab: NSWindowController {
    /// The row title, before falling back to the directory.
    var tabSidebarTitle: String { get }

    /// The SF Symbol shown at the start of the row.
    var tabSidebarSymbol: String { get }

    /// Fires when anything the row shows may have changed.
    var tabSidebarChanges: AnyPublisher<Void, Never> { get }

    /// The sidebar state of this tab: activity, the window's sidebar model,
    /// and the group's collapsed state and width.
    var tabSidebar: TabSidebarTabState { get }

    /// The row details. Terminals report their directory, branch, and
    /// progress.
    var tabSidebarDetails: TabSidebarDetails { get }

    /// The user's title for this tab, or nil to use the default.
    var tabSidebarTitleOverride: String? { get set }

    /// Closes this tab, asking first when work would be lost.
    func closeTab(_ sender: Any?)

    /// Closes the other tabs of the group.
    func closeOtherTabs(_ sender: Any?)

    /// Closes the tabs after this one.
    func closeTabsOnTheRight(_ sender: Any?)

    /// Opens a terminal tab next to this one.
    func openNewTab()

    /// Moves keyboard focus into the tab's content.
    func focusTabContent()

    /// Relabels the tab shortcuts of the window's tab group.
    func relabelTabs()
}

/// What a sidebar row shows below the title.
struct TabSidebarDetails {
    var directory: String?
    var branch: String?
    var progress: Nubb.Action.ProgressReport?
    var isZoomed = false
    var hasBell = false
}

extension TabSidebarTab {
    /// True when this window shows the tab sidebar instead of the native tab bar.
    /// Windows with the hidden titlebar style can't hold tabs, and the
    /// titlebar tabs style already is a tab strip, so neither shows it.
    var isTabSidebarEnabled: Bool {
        guard let delegate = NSApp.delegate as? AppDelegate,
              delegate.nubb.config.macosTabSidebar,
              let window else { return false }
        if window is HiddenTitlebarTerminalWindow { return false }
        if #available(macOS 26.0, *), window is TitlebarTabsTahoeTerminalWindow { return false }
        return true
    }

    /// Rename this tab inline in the sidebar of the window in front. Returns
    /// false when the sidebar can't show the field.
    @discardableResult
    func beginTabSidebarRename() -> Bool {
        guard isTabSidebarEnabled,
              let window,
              let host = (window.tabGroup?.selectedWindow ?? window).windowController as? TabSidebarTab,
              let model = host.tabSidebar.model else { return false }

        // A collapsed sidebar peeks out so the rename field is visible.
        if model.presentation.isCollapsed {
            model.presentation.flash()
        }
        model.beginRename(ObjectIdentifier(self))
        return true
    }

    func validateTabSidebarMenuItem(_ item: NSMenuItem) -> Bool {
        let collapsed = tabSidebar.model?.presentation.isCollapsed ?? false
        item.title = collapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        return isTabSidebarEnabled
    }

    /// Adds the sidebar toggle next to the window buttons and starts watching
    /// the pointer for edge peeks.
    func installTabSidebarChrome(model: TabSidebarModel) {
        guard let window else { return }
        tabSidebar.pointerMonitor = TabSidebarPointerMonitor(window: window, model: model)
        guard window.styleMask.contains(.titled) else { return }
        window.addTitlebarAccessoryViewController(TabSidebarTitlebarAccessory(model: model))
    }
}
