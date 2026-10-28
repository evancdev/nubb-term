import AppKit
import Combine

// MARK: - TerminalController + Tab Sidebar

extension TerminalController {
    /// True when this window shows the tab sidebar instead of the native tab bar.
    /// Windows with the hidden titlebar style can't hold tabs, and the
    /// titlebar tabs style already is a tab strip, so neither shows it.
    var isTabSidebarEnabled: Bool {
        guard nubb.config.macosTabSidebar, let window else { return false }
        if window is HiddenTitlebarTerminalWindow { return false }
        if #available(macOS 26.0, *), window is TitlebarTabsTahoeTerminalWindow { return false }
        return true
    }

    @IBAction func toggleTabSidebar(_ sender: Any?) {
        guard isTabSidebarEnabled else { return }
        tabSidebar.model?.toggleCollapsed()
    }

    /// Rename this tab inline in the sidebar of the window in front. Returns
    /// false when the sidebar can't show the field.
    @discardableResult
    func beginTabSidebarRename() -> Bool {
        guard isTabSidebarEnabled,
              let window,
              let host = (window.tabGroup?.selectedWindow ?? window).windowController as? TerminalController,
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

// MARK: - TerminalWindow + Native Tab Bar

extension TerminalWindow {
    /// The sidebar replaces the native tab bar, so hide the tab bar while the
    /// sidebar is enabled and bring it back when it is turned off.
    func syncNativeTabBarVisibility() {
        let hide = terminalController?.isTabSidebarEnabled ?? false
        for accessory in titlebarAccessoryViewControllers where isTabBar(accessory) {
            if accessory.isHidden != hide { accessory.isHidden = hide }
        }
    }
}

// MARK: - Titlebar Accessory

/// The sidebar toggle and a new tab button placed after the window buttons.
/// The toggle shows a dot while the sidebar is collapsed and a tab in the
/// background wants attention.
final class TabSidebarTitlebarAccessory: NSTitlebarAccessoryViewController {
    private let model: TabSidebarModel
    private let onNewTab: () -> Void
    private let button = NSButton()
    private let newTabButton = NSButton()
    private let dot = NSView()
    private var cancellables: Set<AnyCancellable> = []

    /// `onNewTab` defaults to opening a tab next to this window's tab.
    init(model: TabSidebarModel, onNewTab: (() -> Void)? = nil) {
        self.model = model
        self.onNewTab = onNewTab ?? { [weak model] in model?.newTab() }
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 62, height: 28))

        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Tab Sidebar")
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggle(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        newTabButton.bezelStyle = .texturedRounded
        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newTabButton)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dot)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 62),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
            newTabButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            newTabButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 26),
            newTabButton.heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
        ])

        view = container

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    private func update() {
        isHidden = !model.isEnabled
        let collapsed = model.presentation.isCollapsed
        button.toolTip = collapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        dot.isHidden = !(collapsed && model.hasBackgroundAttention)
        let shortcut = (NSApp.delegate as? AppDelegate)?.nubb.config.keyboardShortcut(for: "new_tab")?.description
        newTabButton.toolTip = shortcut.map { "New Tab (\($0))" } ?? "New Tab"
    }

    @objc private func toggle(_ sender: Any?) {
        model.toggleCollapsed()
    }

    @objc private func newTab(_ sender: Any?) {
        onNewTab()
    }
}
