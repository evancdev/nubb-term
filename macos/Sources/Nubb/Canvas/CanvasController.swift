import AppKit
import Combine
import SwiftUI

/// A tab showing one drawing file.
///
/// The window joins the terminal tab group like any other tab and shows the
/// same tab sidebar. Edits are saved to the file shortly after they happen,
/// and changes other programs make to the file are merged in live.
final class CanvasController: NSWindowController, NSWindowDelegate, TabSidebarTab {
    let nubb: Nubb.App
    let store: CanvasStore
    let editor: CanvasEditor
    let session: CanvasSession
    private(set) var canvasView: CanvasView!

    private(set) lazy var tabSidebar = TabSidebarTabState(controller: self)

    var tabSidebarTitleOverride: String? {
        didSet {
            updateTitle()
            tabSidebar.changes.send()
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    var url: URL { store.url }

    /// The open canvases. A window doesn't keep its controller alive, and
    /// nothing else in the window refers back to it, so this does until the
    /// window closes.
    private static var retained: [CanvasController] = []

    /// All open canvases.
    static var all: [CanvasController] { retained }

    // MARK: Opening

    /// Opens `url` as a tab of `parent`'s window, or brings it to the front
    /// when it's already open.
    @discardableResult
    static func open(_ url: URL, nubb: Nubb.App, from parent: NSWindow?) -> CanvasController {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = all.first(where: { $0.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let controller = CanvasController(nubb: nubb, url: url)
        controller.present(from: parent)
        return controller
    }

    /// Creates a new empty drawing in the default folder and opens it.
    @discardableResult
    static func openNew(nubb: Nubb.App, from parent: NSWindow?) -> CanvasController {
        open(CanvasFiles.newFileURL(), nubb: nubb, from: parent)
    }

    init(nubb: Nubb.App, url: URL) {
        self.nubb = nubb
        self.store = CanvasStore(url: url)
        self.editor = CanvasEditor()
        self.session = CanvasSession(editor: editor, store: store)

        let window = CanvasWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)

        super.init(window: window)
        window.delegate = self

        setUpContent()
        session.open()
        updateTitle()
        // Agents in any terminal can find the viewer once a drawing is open.
        _ = CanvasLiveServer.shared

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.store.flush() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .nubbConfigDidChange)
            .sink { [weak self] _ in self?.tabSidebar.model?.setNeedsRefresh() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpContent() {
        guard let window else { return }
        let canvas = CanvasView(editor: editor)
        canvasView = canvas
        canvas.keyBindingHandler = { [weak self] event in self?.performKeyBinding(event) ?? false }

        let sidebarModel = TabSidebarModel(controller: self, groupState: tabSidebar.groupState)
        tabSidebar.model = sidebarModel
        let container = CanvasContainerView(canvas: canvas)
        let root = NSHostingView(rootView: CanvasRootView(sidebar: sidebarModel, container: container))
        root.sizingOptions = []
        window.contentView = root
        tabSidebar.attach()
        installTabSidebarChrome(model: sidebarModel)

        session.isBusy = { [weak canvas] in canvas?.textEditing != nil }
        session.onLoadStateChange = { [weak canvas] in canvas?.fitToContent(animated: false) }
    }

    /// Shows the window as a tab of `parent`, or on its own.
    private func present(from parent: NSWindow?) {
        guard let window else { return }
        if !Self.retained.contains(where: { $0 === self }) { Self.retained.append(self) }
        if let parentController = parent?.windowController as? TabSidebarTab {
            tabSidebar.adoptGroupState(parentController.tabSidebar.groupState)
        }
        var tabbed = false
        if let parent, parent.tabbingMode != .disallowed, parent.isVisible {
            // AppKit merges and offers "+" only for windows with the same
            // tabbing identifier.
            window.tabbingIdentifier = parent.tabbingIdentifier
            window.setFrame(parent.frame, display: false)
            if parent.isMiniaturized { parent.deminiaturize(nil) }
            let anchor = parent.tabGroup?.selectedWindow ?? parent
            tabbed = anchor.addTabbedWindowSafely(window, ordered: .above)
            if tabbed { anchor.tabGroup?.selectedWindow = window }
        }
        if !tabbed { window.center() }
        showWindowSafely(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvasView)
        relabelTabs()
        DispatchQueue.main.async { [weak self] in
            self?.tabSidebar.model?.presentation.flash()
            self?.relabelTabs()
        }
    }

    // MARK: Title

    private func updateTitle() {
        window?.title = tabSidebarTitle
        window?.representedURL = url
        tabSidebar.changes.send()
    }

    // MARK: TabSidebarTab

    var tabSidebarTitle: String {
        tabSidebarTitleOverride ?? url.deletingPathExtension().lastPathComponent
    }

    var tabSidebarSymbol: String { "scribble.variable" }

    var tabSidebarChanges: AnyPublisher<Void, Never> {
        tabSidebar.changes.eraseToAnyPublisher()
    }

    var tabSidebarDetails: TabSidebarDetails {
        TabSidebarDetails(directory: url.deletingLastPathComponent().path)
    }

    func openNewTab() {
        _ = TerminalController.newTab(nubb, from: window)
    }

    func focusTabContent() {
        window?.makeFirstResponder(canvasView)
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeImmediately()
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard let window, let group = window.tabGroup else { return }
        for other in group.windows where other !== window {
            if let terminal = other.windowController as? TerminalController {
                terminal.closeTab(nil)
            } else if let canvas = other.windowController as? CanvasController {
                canvas.closeImmediately()
            }
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let window, let group = window.tabGroup,
              let index = group.windows.firstIndex(of: window) else { return }
        for other in group.windows[(index + 1)...] {
            if let terminal = other.windowController as? TerminalController {
                terminal.closeTab(nil)
            } else if let canvas = other.windowController as? CanvasController {
                canvas.closeImmediately()
            }
        }
    }

    func relabelTabs() {
        // Terminals put the goto_tab shortcuts on their native tab labels.
        let terminal = window?.tabGroup?.windows.lazy.compactMap { $0.windowController as? TerminalController }.first
        terminal?.relabelTabs()
        tabSidebar.model?.setNeedsRefresh()
    }

    // MARK: Closing

    /// Saves and closes. Edits are saved as they happen, so nothing asks.
    func closeImmediately() {
        if canvasView.textEditing != nil { canvasView.commitTextEditing() }
        store.flush()
        window?.close()
    }

    @IBAction func close(_ sender: Any?) {
        closeImmediately()
    }

    @IBAction func closeWindow(_ sender: Any?) {
        guard let window else { return }
        let windows = window.tabGroup?.windows ?? [window]
        if let terminal = windows.lazy.compactMap({ $0.windowController as? TerminalController }).first {
            terminal.closeWindow(nil)
            for other in windows {
                (other.windowController as? CanvasController)?.closeImmediately()
            }
        } else {
            for other in windows {
                (other.windowController as? CanvasController)?.closeImmediately()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if canvasView.textEditing != nil { canvasView.commitTextEditing() }
        store.flush()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        session.close()
        tabSidebar.pointerMonitor = nil
        cancellables = []
        NotificationCenter.default.post(name: TerminalWindow.terminalWillCloseNotification, object: window)
        DispatchQueue.main.async {
            // Released a turn later: AppKit doesn't retain the delegate while
            // calling it.
            Self.retained.removeAll { $0 === self }
            // Let the remaining tabs relabel and refresh their sidebars.
            for terminal in TerminalController.all { terminal.relabelTabs() }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        tabSidebar.activity.markSeen()
        tabSidebar.model?.setNeedsRefresh()
        canvasView.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) {
        store.flush()
    }

    // MARK: Actions

    @IBAction func newTab(_ sender: Any?) {
        openNewTab()
    }

    /// The native tab bar's "+" button.
    override func newWindowForTab(_ sender: Any?) {
        openNewTab()
    }

    @IBAction func toggleTabSidebar(_ sender: Any?) {
        guard isTabSidebarEnabled else { return }
        tabSidebar.model?.toggleCollapsed()
    }

    @IBAction func changeTabTitle(_ sender: Any?) {
        if beginTabSidebarRename() { return }
        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to use the file name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tabSidebarTitleOverride ?? tabSidebarTitle
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.tabSidebarTitleOverride = value.isEmpty ? nil : value
        }
    }

    /// Shows the file in Finder.
    @IBAction func revealCanvasInFinder(_ sender: Any?) {
        store.flush()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the file's path, for handing the drawing to an agent.
    @IBAction func copyCanvasPath(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: Key bindings

    /// Runs the Nubb key binding for `event`, if any, so tab and window
    /// shortcuts work while a canvas is in front. Only actions that make
    /// sense without a terminal are handled.
    private func performKeyBinding(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
              let window else { return false }

        typealias Binding = (action: String, perform: () -> Void)
        var actions: [Binding] = []
        actions.append(("new_tab", { [weak self] in self?.openNewTab() }))
        actions.append(("new_window", { [weak self] in
            guard let self else { return }
            _ = TerminalController.newWindow(self.nubb)
        }))
        actions.append(("close_surface", { [weak self] in self?.closeImmediately() }))
        actions.append(("close_tab", { [weak self] in self?.closeImmediately() }))
        actions.append(("close_window", { [weak self] in self?.closeWindow(nil) }))
        actions.append(("toggle_tab_sidebar", { [weak self] in self?.toggleTabSidebar(nil) }))
        actions.append(("previous_tab", { Self.gotoTab(in: window, offset: -1) }))
        actions.append(("next_tab", { Self.gotoTab(in: window, offset: 1) }))
        actions.append(("last_tab", { Self.gotoTab(in: window, index: Int.max) }))
        for index in 1...9 {
            actions.append(("goto_tab:\(index)", { Self.gotoTab(in: window, index: index - 1) }))
        }

        for binding in actions {
            guard let shortcut = nubb.config.keyboardShortcut(for: binding.action),
                  Self.event(event, matches: shortcut) else { continue }
            binding.perform()
            return true
        }
        return false
    }

    private static func event(_ event: NSEvent, matches shortcut: KeyboardShortcut) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var wanted: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { wanted.insert(.command) }
        if shortcut.modifiers.contains(.control) { wanted.insert(.control) }
        if shortcut.modifiers.contains(.option) { wanted.insert(.option) }
        if shortcut.modifiers.contains(.shift) { wanted.insert(.shift) }

        let key = String(shortcut.key.character).lowercased()
        let plain = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == wanted && plain == key { return true }
        // Shifted punctuation like `{` reports the shifted character.
        if wanted.contains(.shift), flags == wanted,
           let unshifted = event.characters(byApplyingModifiers: flags.subtracting(.shift))?.lowercased(),
           unshifted == key {
            return true
        }
        return false
    }

    private static func gotoTab(in window: NSWindow, offset: Int) {
        guard let group = window.tabGroup, group.windows.count > 1,
              let selected = group.selectedWindow,
              let index = group.windows.firstIndex(of: selected) else { return }
        let count = group.windows.count
        group.windows[((index + offset) % count + count) % count].makeKeyAndOrderFront(nil)
    }

    private static func gotoTab(in window: NSWindow, index: Int) {
        guard let windows = window.tabGroup?.windows, !windows.isEmpty else { return }
        windows[min(index, windows.count - 1)].makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu validation

extension CanvasController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleTabSidebar(_:)):
            return validateTabSidebarMenuItem(item)
        case #selector(closeTabsOnTheRight(_:)):
            guard let window, let group = window.tabGroup,
                  let index = group.windows.firstIndex(of: window) else { return false }
            return index < group.windows.count - 1
        case #selector(closeOtherTabs(_:)):
            return (window?.tabGroup?.windows.count ?? 1) > 1
        default:
            return true
        }
    }
}

// MARK: - Window

/// The window of a canvas tab. It tabs with terminal windows.
final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        guard isTabBar(childViewController) else { return }
        childViewController.identifier = TerminalWindow.tabBarIdentifier
        // AppKit fills the placeholder a turn after the tab is created.
        syncNativeTabBarVisibility()
        DispatchQueue.main.async { [weak self] in self?.syncNativeTabBarVisibility() }
    }

    override func becomeMain() {
        super.becomeMain()
        syncNativeTabBarVisibility()
    }

    /// The sidebar replaces the native tab bar, as in terminal windows.
    func syncNativeTabBarVisibility() {
        let hide = (windowController as? TabSidebarTab)?.isTabSidebarEnabled ?? false
        for accessory in titlebarAccessoryViewControllers where isTabBar(accessory) {
            if accessory.isHidden != hide { accessory.isHidden = hide }
        }
    }

    /// The same check as `TerminalWindow.isTabBar`: the tab bar, or the empty
    /// placeholder AppKit adds at the bottom of the titlebar before it.
    private func isTabBar(_ accessory: NSTitlebarAccessoryViewController) -> Bool {
        if let identifier = accessory.identifier { return identifier == TerminalWindow.tabBarIdentifier }
        if accessory.view.contains(className: "NSTabBar") { return true }
        return accessory.layoutAttribute == .bottom
            && accessory.view.className == "NSView"
            && accessory.view.subviews.isEmpty
    }
}

// MARK: - Root view

/// The sidebar next to the canvas, like a terminal window's layout.
private struct CanvasRootView: View {
    @ObservedObject var sidebar: TabSidebarModel
    let container: CanvasContainerView

    var body: some View {
        TabSidebarContainer(model: sidebar) {
            CanvasContainerRepresentable(container: container)
        }
    }
}

private struct CanvasContainerRepresentable: NSViewRepresentable {
    let container: CanvasContainerView

    func makeNSView(context: Context) -> CanvasContainerView { container }
    func updateNSView(_ nsView: CanvasContainerView, context: Context) {}
}
