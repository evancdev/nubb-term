import AppKit
import Combine

/// Per-tab sidebar data owned by each `TerminalController`: its working
/// directory and git branch, its latest activity, and the sidebar model of the
/// window it lives in.
final class TabSidebarTabState {
    private weak var controller: TerminalController?

    /// The raw working directory of the focused surface.
    private(set) var directory: String?

    /// The git branch for `directory`, if it is inside a repository.
    private(set) var branch: String?

    /// The latest status of this tab and whether it has unseen activity.
    var activity = TabSidebarActivity() {
        didSet {
            guard activity != oldValue else { return }
            changes.send()
        }
    }

    /// The sidebar shown in this tab's window. Created with the window's content.
    var model: TabSidebarModel?

    /// Reveals the collapsed sidebar when the pointer rests on the left edge.
    var pointerMonitor: TabSidebarPointerMonitor?

    /// Collapse state and width shared by every window of this tab's group.
    var groupState: TabSidebarGroupState

    /// Fires when anything a sidebar row shows for this tab may have changed.
    let changes = PassthroughSubject<Void, Never>()

    private var surfaceCancellables: Set<AnyCancellable> = []
    private var controllerCancellables: Set<AnyCancellable> = []

    init(controller: TerminalController) {
        self.controller = controller
        self.groupState = .restored()
    }

    /// Join another tab group's sidebar state, e.g. a new tab joining its parent.
    func adoptGroupState(_ state: TabSidebarGroupState) {
        groupState = state
        model?.presentation.setCollapsed(state.isCollapsed)
        model?.width = state.width
    }

    /// Start watching the controller. Called once its window has loaded.
    func attach() {
        guard let controller else { return }
        controllerCancellables = []

        controller.$surfaceTree
            .map { _ in () }
            .sink { [weak self] in self?.changes.send() }
            .store(in: &controllerCancellables)

        controller.$bell
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] in self?.changes.send() }
            .store(in: &controllerCancellables)

        controller.surfaceValuesPublisher(
            valueKeyPath: \.progressReport,
            publisherKeyPath: \.$progressReport)
        .map { _ in () }
        .sink { [weak self] in self?.changes.send() }
        .store(in: &controllerCancellables)

        controller.window?.publisher(for: \.title)
            .removeDuplicates()
            .sink { [weak self] _ in
                // Shells update the title after every command, which is also
                // when a `git checkout` may have moved the branch.
                self?.updateBranch()
                self?.changes.send()
            }
            .store(in: &controllerCancellables)
    }

    /// Follow the working directory of the newly focused surface.
    func focusedSurfaceDidChange(_ surface: Nubb.SurfaceView?) {
        surfaceCancellables = []
        guard let surface else { return }
        surface.$pwd
            .removeDuplicates()
            .sink { [weak self] pwd in
                self?.directory = (pwd?.isEmpty ?? true) ? nil : pwd
                self?.updateBranch()
                self?.changes.send()
            }
            .store(in: &surfaceCancellables)
    }

    private func updateBranch() {
        guard let directory else {
            branch = nil
            return
        }

        branch = TabSidebarGit.branch(atDirectory: URL(fileURLWithPath: directory, isDirectory: true))
    }

    /// True when the user can see this tab right now.
    var isVisible: Bool {
        guard NSApp.isActive, let window = controller?.window else { return false }
        return window.isKeyWindow
    }
}

// MARK: - Activity recording

/// Routes terminal events (notifications, bells, finished commands) to the
/// sidebar state of the tab that produced them.
enum TabSidebarActivityRecorder {
    private static func state(for surface: Nubb.SurfaceView) -> TabSidebarTabState? {
        (BaseTerminalController.controller(owning: surface) as? TerminalController)?.tabSidebar
    }

    static func recordNotification(_ surface: Nubb.SurfaceView, title: String, body: String) {
        DispatchQueue.main.async {
            guard let state = state(for: surface) else { return }
            state.activity.recordNotification(title: title, body: body, isVisible: state.isVisible)
        }
    }

    static func recordBell(_ surface: Nubb.SurfaceView) {
        DispatchQueue.main.async {
            guard let state = state(for: surface) else { return }
            state.activity.recordBell(isVisible: state.isVisible)
        }
    }

    static func recordCommandFinished(_ surface: Nubb.SurfaceView, exitCode: Int?, duration: Duration, threshold: Duration) {
        DispatchQueue.main.async {
            guard let state = state(for: surface) else { return }
            state.activity.recordCommandFinished(
                exitCode: exitCode,
                duration: duration,
                threshold: threshold,
                isVisible: state.isVisible)
        }
    }

    /// Clear the unseen marker of whatever tab is in front of the user.
    static func markKeyWindowSeen() {
        guard NSApp.isActive,
              let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
        controller.tabSidebar.activity.markSeen()
    }
}
