import Foundation

// The pure, AppKit-free logic behind the tab sidebar. Everything here is unit
// tested in `macos/Tests/TabSidebar`.

// MARK: - Scheduling

protocol TabSidebarCancellable {
    func cancel()
}

protocol TabSidebarScheduler {
    /// Run `work` once after `delay` seconds unless cancelled first.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TabSidebarCancellable
}

extension DispatchWorkItem: TabSidebarCancellable {}

/// Production scheduler backed by the main dispatch queue.
final class TabSidebarMainQueueScheduler: TabSidebarScheduler {
    init() {}

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> TabSidebarCancellable {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return item
    }
}

// MARK: - Presentation

/// The collapse and peek state machine of one window's sidebar.
///
/// Pinned (`isCollapsed == false`): the sidebar is docked and takes layout space.
/// Collapsed: the sidebar is hidden, and resting the pointer on the window's left
/// edge makes it "peek" out as a floating overlay until the pointer leaves it.
final class TabSidebarPresentation: ObservableObject {
    struct Timing: Equatable {
        var showDelay: TimeInterval
        var hideDelay: TimeInterval
        var flashDuration: TimeInterval

        static let standard = Timing(showDelay: 0.08, hideDelay: 0.35, flashDuration: 1.0)
    }

    @Published private(set) var isCollapsed: Bool
    @Published private(set) var isPeeking: Bool = false

    /// True when the sidebar is on screen in any form.
    var isSidebarVisible: Bool { !isCollapsed || isPeeking }

    let timing: Timing
    private let scheduler: TabSidebarScheduler

    private var pendingShow: TabSidebarCancellable?
    private var pendingHide: TabSidebarCancellable?
    private var pointerInEdge = false
    private var pointerInCard = false
    private var interactions = 0

    init(isCollapsed: Bool,
         timing: Timing = .standard,
         scheduler: TabSidebarScheduler = TabSidebarMainQueueScheduler()) {
        self.isCollapsed = isCollapsed
        self.timing = timing
        self.scheduler = scheduler
    }

    func toggle() {
        cancelShow()
        cancelHide()
        isPeeking = false
        isCollapsed.toggle()
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        toggle()
    }

    func pointerEnteredEdge() {
        pointerInEdge = true
        guard isCollapsed else { return }
        if isPeeking {
            cancelHide()
            return
        }

        guard pendingShow == nil else { return }
        pendingShow = scheduler.schedule(after: timing.showDelay) { [weak self] in
            guard let self else { return }
            self.pendingShow = nil
            guard self.isCollapsed else { return }
            self.isPeeking = true
        }
    }

    func pointerExitedEdge() {
        pointerInEdge = false
        cancelShow()
        if isPeeking && !pointerInCard {
            scheduleHide(after: timing.hideDelay)
        }
    }

    func pointerEnteredCard() {
        pointerInCard = true
        cancelHide()
    }

    func pointerExitedCard() {
        pointerInCard = false
        if isPeeking && !pointerInEdge {
            scheduleHide(after: timing.hideDelay)
        }
    }

    /// Briefly reveal the sidebar while collapsed, e.g. when a tab is created.
    func flash() {
        guard isCollapsed else { return }
        cancelShow()
        isPeeking = true
        scheduleHide(after: timing.flashDuration)
    }

    func dismissPeek() {
        cancelShow()
        cancelHide()
        isPeeking = false
    }

    /// Bracket an interaction inside the peeking sidebar (rename field, drag,
    /// context menu) so it doesn't hide underneath the user.
    func beginInteraction() {
        interactions += 1
    }

    func endInteraction() {
        guard interactions > 0 else { return }
        interactions -= 1
        guard interactions == 0 else { return }
        if isPeeking && !pointerInCard && !pointerInEdge {
            scheduleHide(after: timing.hideDelay)
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelHide()
        pendingHide = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.pendingHide = nil
            guard !self.pointerInCard, !self.pointerInEdge, self.interactions == 0 else { return }
            self.isPeeking = false
        }
    }

    private func cancelShow() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }
}

// MARK: - Activity

/// The latest status line of a tab and whether it has unseen activity.
struct TabSidebarActivity: Equatable {
    private(set) var status: String?
    private(set) var needsAttention: Bool = false
    private(set) var isError: Bool = false

    init() {}

    mutating func recordNotification(title: String, body: String, isVisible: Bool) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        status = !title.isEmpty ? title : (!body.isEmpty ? body : "Notification")
        isError = false
        if !isVisible { needsAttention = true }
    }

    mutating func recordBell(isVisible: Bool) {
        if !isVisible { needsAttention = true }
    }

    mutating func recordCommandFinished(
        exitCode: Int?,
        duration: Duration,
        threshold: Duration,
        isVisible: Bool
    ) {
        guard duration >= threshold else { return }
        switch exitCode {
        case nil, 0?:
            status = "Finished"
            isError = false
        case let code?:
            status = "Failed (exit \(code))"
            isError = true
        }
        if !isVisible { needsAttention = true }
    }

    mutating func markSeen() {
        needsAttention = false
    }
}

// MARK: - Git

enum TabSidebarGit {
    /// The branch checked out for `directory`, read straight from `.git` so we
    /// never spawn `git`. Detached heads return the short object id.
    static func branch(atDirectory directory: URL, fileManager: FileManager = .default) -> String? {
        // Walk path strings rather than URLs: URL.deletingLastPathComponent
        // turns "/" into "/.." instead of stopping at the root.
        var path = (directory.standardizedFileURL.path as NSString).standardizingPath
        if path.isEmpty { path = "/" }
        while true {
            let current = URL(fileURLWithPath: path, isDirectory: true)
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard let gitDir = isDirectory.boolValue ? dotGit : gitDirectory(fromFile: dotGit, base: current) else {
                    return nil
                }

                let head = gitDir.appendingPathComponent("HEAD")
                guard let data = fileManager.contents(atPath: head.path),
                      let contents = String(data: data, encoding: .utf8) else { return nil }
                return branch(fromHead: contents)
            }

            guard path != "/" else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            path = parent.isEmpty ? "/" : parent
        }
    }

    /// Parses a `.git` file (`gitdir: <path>`) used by worktrees and submodules.
    private static func gitDirectory(fromFile file: URL, base: URL) -> URL? {
        guard let data = try? Data(contentsOf: file),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    static func branch(fromHead contents: String) -> String? {
        let head = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref:"
        if head.hasPrefix(refPrefix) {
            let ref = head.dropFirst(refPrefix.count).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { return nil }
            let heads = "refs/heads/"
            if ref.hasPrefix(heads), ref.count > heads.count {
                return String(ref.dropFirst(heads.count))
            }
            return ref
        }

        let isObjectId = (head.count == 40 || head.count == 64) && head.allSatisfy { $0.isASCII && $0.isHexDigit }
        return isObjectId ? String(head.prefix(7)) : nil
    }
}

// MARK: - Formatting

enum TabSidebarFormat {
    static func abbreviatedPath(_ path: String, home: String) -> String {
        let path = trimmingTrailingSlashes(path)
        let home = trimmingTrailingSlashes(home)
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home == "/" ? "/" : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    static func displayTitle(title: String, directory: String?) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        guard let directory, !directory.isEmpty else { return "Terminal" }
        let trimmed = trimmingTrailingSlashes(directory)
        if trimmed == "/" || trimmed == "~" { return trimmed }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func trimmingTrailingSlashes(_ value: String) -> String {
        var result = Substring(value)
        while result.count > 1 && result.hasSuffix("/") {
            result = result.dropLast()
        }
        return String(result)
    }
}

// MARK: - Shortcuts

enum TabSidebarShortcuts {
    /// One shortcut label per tab: `goto_tab:N` for the first nine tabs and
    /// `last_tab` for the final tab when nothing else claims it.
    static func labels(
        tabCount: Int,
        gotoTab: (Int) -> String?,
        lastTab: () -> String?
    ) -> [String?] {
        guard tabCount > 0 else { return [] }
        return (0..<tabCount).map { index in
            if index < 9, let label = gotoTab(index + 1) { return label }
            if index == tabCount - 1 { return lastTab() }
            return nil
        }
    }
}

// MARK: - Metrics

enum TabSidebarMetrics {
    static let defaultWidth: CGFloat = 240
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 400

    /// The width of the left edge strip that reveals a collapsed sidebar.
    static let edgeZoneWidth: CGFloat = 6

    static func clampedWidth(_ proposed: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let upper = max(minimumWidth, min(maximumWidth, windowWidth.isFinite ? windowWidth * 0.6 : maximumWidth))
        // min/max pass NaN through, so a broken proposal falls back to the default.
        let width = proposed.isNaN ? defaultWidth : proposed
        return min(max(width, minimumWidth), upper)
    }
}

// MARK: - Reorder

enum TabSidebarReorder {
    enum Placement: Equatable {
        case before(Int)
        case after(Int)
    }

    /// The final index of the dragged row for a pointer at `pointerY`, in a
    /// top-left origin coordinate space.
    static func destinationIndex(pointerY: CGFloat, rowFrames: [CGRect], draggedIndex: Int) -> Int {
        let others = rowFrames.enumerated()
            .filter { $0.offset != draggedIndex }
            .map(\.element)
        return others.firstIndex { $0.midY > pointerY } ?? others.count
    }

    static func moved<T>(_ items: [T], from source: Int, to destination: Int) -> [T] {
        guard items.indices.contains(source), items.indices.contains(destination) else { return items }
        var result = items
        let item = result.remove(at: source)
        result.insert(item, at: destination)
        return result
    }

    /// Where to re-attach a moved tab relative to the remaining tabs.
    static func placement(forDestination destination: Int, remainingCount: Int) -> Placement? {
        guard remainingCount > 0 else { return nil }
        if destination < remainingCount { return .before(max(0, destination)) }
        return .after(remainingCount - 1)
    }
}
