import AppKit
import Combine
import SwiftUI

/// One row of the tab sidebar.
struct TabSidebarItem: Identifiable, Equatable {
    let id: ObjectIdentifier
    let title: String
    let directory: String?
    let branch: String?
    let tabColor: TerminalTabColor
    let isSelected: Bool
    let shortcut: String?
    let activity: TabSidebarActivity
    let progress: Nubb.Action.ProgressReport?
    let isZoomed: Bool
    let hasBell: Bool

    static func == (lhs: TabSidebarItem, rhs: TabSidebarItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.directory == rhs.directory &&
            lhs.branch == rhs.branch &&
            lhs.tabColor == rhs.tabColor &&
            lhs.isSelected == rhs.isSelected &&
            lhs.shortcut == rhs.shortcut &&
            lhs.activity == rhs.activity &&
            lhs.progress?.state == rhs.progress?.state &&
            lhs.progress?.progress == rhs.progress?.progress &&
            lhs.isZoomed == rhs.isZoomed &&
            lhs.hasBell == rhs.hasBell
    }
}

/// State shared by every window of one native tab group: whether the sidebar is
/// collapsed and how wide it is. Each window has its own sidebar view, so this
/// keeps them in sync while switching tabs.
final class TabSidebarGroupState {
    var isCollapsed: Bool
    var width: CGFloat

    init(isCollapsed: Bool, width: CGFloat) {
        self.isCollapsed = isCollapsed
        self.width = width
    }

    private static let collapsedKey = "TabSidebarCollapsed"
    private static let widthKey = "TabSidebarWidth"

    /// The state new windows start with: the last state the user chose.
    static func restored() -> TabSidebarGroupState {
        let defaults = UserDefaults.nubb
        let saved = (defaults.object(forKey: widthKey) as? Double).map { CGFloat($0) }
        let width = saved.map {
            min(max($0.isFinite ? $0 : TabSidebarMetrics.defaultWidth, TabSidebarMetrics.minimumWidth),
                TabSidebarMetrics.maximumWidth)
        }
        return .init(
            isCollapsed: defaults.bool(forKey: collapsedKey),
            width: width ?? TabSidebarMetrics.defaultWidth)
    }

    func save() {
        let defaults = UserDefaults.nubb
        defaults.set(isCollapsed, forKey: Self.collapsedKey)
        defaults.set(Double(width), forKey: Self.widthKey)
    }
}

/// Mirrors the native tab group of one window into sidebar rows and performs
/// tab actions on it. The native tab group stays the source of truth.
final class TabSidebarModel: ObservableObject {
    @Published private(set) var items: [TabSidebarItem] = []
    @Published var width: CGFloat = TabSidebarMetrics.defaultWidth
    @Published var renamingID: ObjectIdentifier?
    @Published var isWindowKey: Bool = false
    @Published private(set) var isEnabled: Bool = true

    let presentation: TabSidebarPresentation

    /// True when a tab other than the selected one has unseen activity.
    var hasBackgroundAttention: Bool {
        items.contains { !$0.isSelected && ($0.activity.needsAttention || $0.hasBell) }
    }

    /// The controller whose window hosts this sidebar.
    private weak var controller: TerminalController?

    private var cancellables: Set<AnyCancellable> = []
    private var observedControllers: [ObjectIdentifier: AnyCancellable] = [:]
    private var tabGroupObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var refreshScheduled = false

    /// `controller` is nil only in tests: the model then has no rows.
    init(controller: TerminalController?, groupState: TabSidebarGroupState) {
        self.controller = controller
        self.width = groupState.width
        self.presentation = TabSidebarPresentation(isCollapsed: groupState.isCollapsed)

        // Re-render our rows when the presentation changes so the docked and
        // floating sidebars share one source of truth.
        presentation.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            TerminalWindow.terminalWillCloseNotification,
            .nubbConfigDidChange,
        ] {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.setNeedsRefresh() }
                .store(in: &cancellables)
        }

        refresh()
    }

    deinit {
        tabGroupObservation?.invalidate()
    }

    // MARK: Refresh

    /// Coalesce bursts of changes (title updates, tab moves) into one refresh.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard let controller, let window = controller.window else {
            items = []
            return
        }

        let enabled = controller.isTabSidebarEnabled
        if enabled != isEnabled { isEnabled = enabled }
        (window as? TerminalWindow)?.syncNativeTabBarVisibility()

        observeTabGroup(of: window)

        let controllers = Self.tabControllers(of: window)
        observeControllers(controllers)

        let config = controller.nubb.config
        let labels = TabSidebarShortcuts.labels(
            tabCount: controllers.count,
            gotoTab: { index in Self.label(config, "goto_tab:\(index)") },
            lastTab: { Self.label(config, "last_tab") })
        let selected = window.tabGroup?.selectedWindow ?? window
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let newItems: [TabSidebarItem] = controllers.enumerated().map { index, tab in
            let tabWindow = tab.window
            let info = tab.tabSidebar
            let title = tab.titleOverride ?? tabWindow?.title ?? ""
            let directory = info.directory.map { TabSidebarFormat.abbreviatedPath($0, home: home) }
            return TabSidebarItem(
                id: ObjectIdentifier(tab),
                title: TabSidebarFormat.displayTitle(title: title, directory: directory),
                directory: directory,
                branch: info.branch,
                tabColor: (tabWindow as? TerminalWindow)?.tabColor ?? .none,
                isSelected: tabWindow === selected,
                shortcut: labels[safe: index] ?? nil,
                activity: info.activity,
                progress: tab.surfaceTree.lazy.compactMap(\.progressReport).first,
                isZoomed: tab.surfaceTree.zoomed != nil,
                hasBell: tab.bell)
        }

        if newItems != items { items = newItems }
        isWindowKey = window.isKeyWindow
    }

    private static func label(_ config: Nubb.Config, _ action: String) -> String? {
        MainActor.assumeIsolated { config.keyboardShortcut(for: action)?.description }
    }

    /// The terminal controllers of the window's tab group in tab order.
    static func tabControllers(of window: NSWindow) -> [TerminalController] {
        let windows = window.tabGroup?.windows ?? [window]
        return windows.compactMap { $0.windowController as? TerminalController }
    }

    private func observeTabGroup(of window: NSWindow) {
        let group = window.tabGroup
        guard group !== observedTabGroup || (group != nil && tabGroupObservation == nil) else { return }
        tabGroupObservation?.invalidate()
        tabGroupObservation = nil
        observedTabGroup = group
        tabGroupObservation = group?.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.setNeedsRefresh() }
        }
    }

    private func observeControllers(_ controllers: [TerminalController]) {
        let ids = Set(controllers.map(ObjectIdentifier.init))
        for key in observedControllers.keys where !ids.contains(key) {
            observedControllers.removeValue(forKey: key)
        }

        for tab in controllers where observedControllers[ObjectIdentifier(tab)] == nil {
            observedControllers[ObjectIdentifier(tab)] = tab.tabSidebar.changes
                .sink { [weak self] in self?.setNeedsRefresh() }
        }
    }

    // MARK: Actions

    private func controller(for id: ObjectIdentifier) -> TerminalController? {
        guard let window = controller?.window else { return nil }
        return Self.tabControllers(of: window).first { ObjectIdentifier($0) == id }
    }

    func select(_ id: ObjectIdentifier) {
        guard let target = controller(for: id), let window = target.window else { return }
        window.makeKeyAndOrderFront(nil)
        if let surface = target.focusedSurface {
            DispatchQueue.main.async { Nubb.moveFocus(to: surface, from: nil) }
        }
    }

    func close(_ id: ObjectIdentifier) {
        controller(for: id)?.closeTab(nil)
    }

    func closeOthers(_ id: ObjectIdentifier) {
        controller(for: id)?.closeOtherTabs(nil)
    }

    func closeBelow(_ id: ObjectIdentifier) {
        controller(for: id)?.closeTabsOnTheRight(nil)
    }

    func newTab() {
        controller?.newTab(nil)
    }

    func setColor(_ color: TerminalTabColor, for id: ObjectIdentifier) {
        (controller(for: id)?.window as? TerminalWindow)?.tabColor = color
        setNeedsRefresh()
    }

    func currentTitle(for id: ObjectIdentifier) -> String {
        guard let target = controller(for: id) else { return "" }
        return target.titleOverride ?? target.window?.title ?? ""
    }

    func beginRename(_ id: ObjectIdentifier) {
        presentation.beginInteraction()
        renamingID = id
    }

    func commitRename(_ id: ObjectIdentifier, title: String?) {
        defer {
            renamingID = nil
            presentation.endInteraction()
            refocusTerminal()
        }

        guard let title, let target = controller(for: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.titleOverride = trimmed.isEmpty ? nil : trimmed
        setNeedsRefresh()
    }

    func move(_ id: ObjectIdentifier, to destination: Int) {
        guard let window = controller?.window,
              let tabGroup = window.tabGroup,
              let moving = controller(for: id)?.window,
              let source = tabGroup.windows.firstIndex(of: moving),
              source != destination else { return }

        let remaining = tabGroup.windows.filter { $0 !== moving }
        guard let placement = TabSidebarReorder.placement(
            forDestination: destination,
            remainingCount: remaining.count) else { return }

        let wasSelected = tabGroup.selectedWindow === moving
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(moving)
        switch placement {
        case .before(let index):
            remaining[index].addTabbedWindowSafely(moving, ordered: .below)
        case .after(let index):
            remaining[index].addTabbedWindowSafely(moving, ordered: .above)
        }
        if wasSelected { moving.makeKey() }
        NSAnimationContext.endGrouping()

        // The tab group keeps the original selection; relabel shortcuts.
        TerminalController.all.forEach { $0.relabelTabs() }
        setNeedsRefresh()
    }

    func toggleCollapsed() {
        let collapse = !presentation.isCollapsed
        updateGroup { state, model in
            state.isCollapsed = collapse
            model?.presentation.setCollapsed(collapse)
        }
    }

    func commitWidth(_ width: CGFloat) {
        updateGroup { state, model in
            state.width = width
            model?.width = width
        }
    }

    /// Apply a change to the shared state of this window's tab group and to the
    /// sidebar of every window in the group, then remember it for new windows.
    private func updateGroup(_ update: (TabSidebarGroupState, TabSidebarModel?) -> Void) {
        guard let controller, let window = controller.window else { return }
        let state = controller.tabSidebar.groupState
        for tab in Self.tabControllers(of: window) {
            // Tabs dragged in from other windows adopt this group's state.
            tab.tabSidebar.groupState = state
            update(state, tab.tabSidebar.model)
        }
        state.save()
    }

    func refocusTerminal() {
        guard let controller, let surface = controller.focusedSurface else { return }
        controller.window?.makeFirstResponder(surface)
    }
}
