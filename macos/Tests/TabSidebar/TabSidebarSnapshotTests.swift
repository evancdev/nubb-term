import AppKit
import SwiftUI
import Testing
@testable import Nubb

/// Renders the sidebar rows to PNGs when NUBB_SIDEBAR_SNAPSHOT_DIR is set so
/// the look can be checked without launching the app. Skipped otherwise.
@Suite
struct TabSidebarSnapshotTests {
    private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["NUBB_SIDEBAR_SNAPSHOT_DIR"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private final class Token {}

    private static func item(
        _ token: Token,
        title: String,
        directory: String?,
        branch: String? = nil,
        color: TerminalTabColor = .none,
        selected: Bool = false,
        shortcut: String?,
        activity: TabSidebarActivity = .init(),
        progress: Nubb.Action.ProgressReport? = nil
    ) -> TabSidebarItem {
        TabSidebarItem(
            id: ObjectIdentifier(token),
            title: title,
            directory: directory,
            branch: branch,
            tabColor: color,
            isSelected: selected,
            shortcut: shortcut,
            activity: activity,
            progress: progress,
            isZoomed: false,
            hasBell: false)
    }

    @MainActor @Test(.enabled(if: outputDirectory != nil))
    func renderRows() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tokens = (0..<5).map { _ in Token() }
        var waiting = TabSidebarActivity()
        waiting.recordNotification(title: "Needs your input", body: "", isVisible: false)
        var failed = TabSidebarActivity()
        failed.recordCommandFinished(exitCode: 1, duration: .seconds(30), threshold: .seconds(5), isVisible: false)
        var finished = TabSidebarActivity()
        finished.recordCommandFinished(exitCode: 0, duration: .seconds(30), threshold: .seconds(5), isVisible: true)

        let items = [
            Self.item(tokens[0], title: "zsh", directory: "~/code/nubb", branch: "main", shortcut: "⌘1"),
            Self.item(tokens[1], title: "claude", directory: "~/code/nubb-tab-sidebar", branch: "feat/tab-sidebar",
                      color: .blue, selected: true, shortcut: "⌘2", activity: waiting),
            Self.item(tokens[2], title: "zig build test", directory: "~/code/nubb", branch: "main", shortcut: "⌘3",
                      progress: .init(state: .set, progress: 62)),
            Self.item(tokens[3], title: "cargo test", directory: "~/code/other", branch: "a1b2c3d",
                      color: .purple, shortcut: "⌘4", activity: failed),
            Self.item(tokens[4], title: "ssh build-box", directory: nil, shortcut: "⌘9", activity: finished),
        ]

        for scheme in [ColorScheme.dark, .light] {
            let view = VStack(alignment: .leading, spacing: 2) {
                TabSidebarFloatingHeader {}
                    .padding(.horizontal, -8)
                ForEach(items) { item in
                    TabSidebarRow(
                        item: item,
                        isWindowKey: true,
                        canClose: true,
                        isRenaming: false,
                        initialTitle: "",
                        onSelect: {},
                        onClose: {},
                        onRename: {},
                        onCommitRename: { _ in })
                }
            }
            .padding(8)
            .frame(width: 240)
            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let name = scheme == .dark ? "rows-dark.png" : "rows-light.png"
            try png.write(to: directory.appendingPathComponent(name))
        }
    }
}
