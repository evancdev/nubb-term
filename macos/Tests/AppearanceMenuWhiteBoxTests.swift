import AppKit
import Foundation
import Testing
@testable import Nubb
@testable import NubbKit

// White-box tests for the Appearance menu: AppearancePreview timing and
// state, AppearanceModel.previewText/commit, the menu item builders, and
// the preview overlay run through Nubb's real config loader.

// MARK: - Fixtures

private let wbAnimatedSource = "void mainImage(out vec4 c, in vec2 p) { c = vec4(sin(iTime)); }"
private let wbStillSource = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"

/// A unique temporary folder tree. Every model built here gets explicit
/// folder URLs, so real user folders are never read or written.
private final class WBSandbox {
    let root: URL
    let config: URL
    let userThemes: URL
    let bundledThemes: URL
    let userEffects: URL
    let bundledEffects: URL
    let extra: URL
    var reloads = 0

    init(
        userThemes userThemeFiles: [String: String] = [:],
        bundledThemes bundledThemeFiles: [String: String] = [
            "Sample": "background = #101010\n",
            "Second": "background = #202020\n",
        ],
        userEffects userEffectFiles: [String: String] = ["Pulse": wbAnimatedSource],
        bundledEffects bundledEffectFiles: [String: String] = ["CRT": wbStillSource],
        configText: String = "font-size = 13\n"
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-menu-whitebox-\(UUID().uuidString)", isDirectory: true)
        config = root.appendingPathComponent("config/config.nubb")
        userThemes = root.appendingPathComponent("themes", isDirectory: true)
        bundledThemes = root.appendingPathComponent("bundled-themes", isDirectory: true)
        userEffects = root.appendingPathComponent("shaders", isDirectory: true)
        bundledEffects = root.appendingPathComponent("bundled-shaders", isDirectory: true)
        extra = root.appendingPathComponent("extra", isDirectory: true)
        let fm = FileManager.default
        for dir in [config.deletingLastPathComponent(), userThemes, bundledThemes, userEffects, bundledEffects, extra] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try configText.write(to: config, atomically: true, encoding: .utf8)
        for (name, text) in userThemeFiles {
            try text.write(to: userThemes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (name, text) in bundledThemeFiles {
            try text.write(to: bundledThemes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (name, text) in userEffectFiles {
            try text.write(to: userEffects.appendingPathComponent("\(name).glsl"), atomically: true, encoding: .utf8)
        }
        for (name, text) in bundledEffectFiles {
            try text.write(to: bundledEffects.appendingPathComponent("\(name).glsl"), atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor
    func model() -> AppearanceModel {
        AppearanceModel(
            configURL: config,
            userThemesURL: userThemes,
            bundledThemesURL: bundledThemes,
            userEffectsURL: userEffects,
            bundledEffectsURL: bundledEffects,
            trash: { try FileManager.default.removeItem(at: $0) },
            reload: { [weak self] in self?.reloads += 1 }
        )
    }

    var appearanceURL: URL { config.deletingLastPathComponent().appendingPathComponent(AppearanceInclude.fileName) }
    var appearanceExists: Bool { FileManager.default.fileExists(atPath: appearanceURL.path) }
    var appearance: String { (try? String(contentsOf: appearanceURL, encoding: .utf8)) ?? "" }
    var configContents: String { (try? String(contentsOf: config, encoding: .utf8)) ?? "" }

    func writeAppearance(_ text: String) throws {
        try text.write(to: appearanceURL, atomically: true, encoding: .utf8)
    }

    func writeConfig(_ text: String) throws {
        try text.write(to: config, atomically: true, encoding: .utf8)
    }

    /// Writes a file outside every catalog folder and returns its path.
    @discardableResult
    func writeExtra(_ name: String, _ text: String) throws -> String {
        let url = extra.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    var crtPath: String { bundledEffects.appendingPathComponent("CRT.glsl").path }
}

private final class WBTask: AppearancePreviewCancellable {
    let fireTime: TimeInterval
    let delay: TimeInterval
    let order: Int
    let work: () -> Void
    var cancelled = false
    var ran = false

    init(fireTime: TimeInterval, delay: TimeInterval, order: Int, work: @escaping () -> Void) {
        self.fireTime = fireTime
        self.delay = delay
        self.order = order
        self.work = work
    }

    func cancel() { cancelled = true }
}

/// A scheduler with a manual clock. `advance(by:)` runs due, uncancelled
/// work in time order, ties in scheduling order.
private final class WBScheduler {
    private(set) var now: TimeInterval = 0
    private(set) var tasks: [WBTask] = []

    var schedule: AppearancePreview.Schedule {
        { [unowned self] delay, work in
            let task = WBTask(fireTime: self.now + delay, delay: delay, order: self.tasks.count, work: work)
            self.tasks.append(task)
            return task
        }
    }

    var pending: [WBTask] { tasks.filter { !$0.cancelled && !$0.ran } }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks
            .filter({ !$0.cancelled && !$0.ran && $0.fireTime <= target + 1e-9 })
            .min(by: { ($0.fireTime, $0.order) < ($1.fireTime, $1.order) }) {
            now = max(now, next.fireTime)
            next.ran = true
            next.work()
        }
        now = target
    }
}

private final class WBApplyLog {
    var calls: [String?] = []
}

@MainActor
private func wbPreview(
    _ model: AppearanceModel,
    _ scheduler: WBScheduler,
    _ log: WBApplyLog,
    delay: TimeInterval = 0.08
) -> AppearancePreview {
    AppearancePreview(model: model, delay: delay, schedule: scheduler.schedule, apply: { log.calls.append($0) })
}

private final class WBTarget: NSObject {
    @objc func pick(_ sender: Any?) {}
}

/// Titles of the items that show a check mark.
private func wbCheckedTitles(_ items: [NSMenuItem]) -> [String] {
    items.filter { $0.state == .on }.map(\.title)
}

private func wbChoices(_ items: [NSMenuItem]) -> [AppearanceChoice] {
    items.compactMap { $0.representedObject as? AppearanceChoice }
}

// MARK: - previewText and commit

@MainActor
struct AppearanceMenuPreviewTextWhiteBoxTests {
    /// Hovering must show exactly what clicking saves, including legacy
    /// color lines and a hand-written shader path the folders don't list.
    @Test func themePreviewMatchesCommittedFileWithLegacyLines() throws {
        let box = try WBSandbox()
        try box.writeAppearance("""
        background = #112233
        palette = 3=#445566
        custom-shader = /nowhere/hand.glsl
        custom-shader-animation = false

        """)
        let model = box.model()
        #expect(model.settings.overrides.values[.background] == ThemeRGB(r: 0x11, g: 0x22, b: 0x33))
        #expect(model.settings.effect == "/nowhere/hand.glsl")
        #expect(model.selectedEffect == nil)

        let text = try #require(model.previewText(for: .theme("Sample")))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("theme = Sample"))
        #expect(lines.contains("background = #112233"))
        #expect(lines.contains("palette = 3=#445566"))
        #expect(lines.contains("custom-shader = /nowhere/hand.glsl"))
        #expect(lines.contains("custom-shader-animation = false"))

        model.commit(.theme("Sample"))
        #expect(box.reloads == 1)
        #expect(box.appearance == text)
    }

    /// "None" drops a hand-written shader and its animation line but keeps
    /// the legacy colors. Picking a listed effect replaces the path.
    @Test func effectPreviewsReplaceUnlistedShaderPath() throws {
        let box = try WBSandbox()
        try box.writeAppearance("""
        theme = Second
        foreground = #abcdef
        custom-shader = /nowhere/hand.glsl
        custom-shader-animation = false

        """)
        let model = box.model()

        let none = try #require(model.previewText(for: .effect(nil)))
        #expect(!none.contains("custom-shader"))
        #expect(none.contains("theme = Second\n"))
        #expect(none.contains("foreground = #abcdef\n"))
        #expect(AppearanceSettings(parsing: none).effect == nil)
        #expect(AppearanceSettings(parsing: none).effectAnimates)

        let crt = try #require(model.previewText(for: .effect("CRT")))
        #expect(!crt.contains("/nowhere/hand.glsl"))
        #expect(crt.contains("custom-shader =\ncustom-shader = \(box.crtPath)\ncustom-shader-animation = false\n"))

        model.commit(.effect(nil))
        #expect(box.appearance == none)
        #expect(box.reloads == 1)
    }

    /// Clicking the item that's already checked changes nothing, yet commit
    /// still writes the file, adds the include line, and reloads once.
    @Test func committingNoOpChoiceStillSavesAndReloadsOnce() throws {
        let box = try WBSandbox()
        let model = box.model()
        #expect(model.previewText(for: .theme(nil)) == nil)
        #expect(!box.appearanceExists)

        model.commit(.theme(nil))
        #expect(box.reloads == 1)
        #expect(box.appearance == AppearanceSettings().serialized())
        #expect(box.configContents == "font-size = 13\n\n# Colors from the Nubb Appearance window.\n\(AppearanceInclude.directive)\n")

        model.commit(.effect(nil))
        #expect(box.reloads == 2)
        #expect(box.appearance == AppearanceSettings().serialized())
        // The include line is added only once.
        #expect(box.configContents.components(separatedBy: AppearanceInclude.directive).count == 2)
    }

    /// A `:` in a shader file name is fine: the path round-trips through
    /// the appearance file and the menu checks the effect after a commit.
    @Test func effectNameWithColonRoundTrips() throws {
        let box = try WBSandbox(userEffects: ["a:b": wbAnimatedSource], bundledEffects: [:])
        let model = box.model()
        let path = box.userEffects.appendingPathComponent("a:b.glsl").path
        #expect(model.effects.map(\.name) == ["a:b"])

        let text = try #require(model.previewText(for: .effect("a:b")))
        #expect(AppearanceSettings(parsing: text).effect == path)
        #expect(AppearanceSettings(parsing: text).effectAnimates)

        model.commit(.effect("a:b"))
        model.refresh()
        #expect(model.settings.effect == path)
        #expect(model.selectedEffect?.name == "a:b")

        let items = AppearanceMenuItems.effect(model: model, target: nil, action: nil)
        #expect(wbCheckedTitles(items) == ["a:b"])
        #expect(!items.contains { $0.title.hasPrefix("Other:") })
    }

    /// A theme file whose name contains `:` would read back as a broken
    /// light/dark pair, so the menu doesn't offer it.
    @Test func themeNameWithColonIsHiddenOrRoundTrips() throws {
        let box = try WBSandbox(bundledThemes: ["A:B": "background = #303030\n"])
        let model = box.model()
        let offered = wbChoices(AppearanceMenuItems.theme(model: model, target: nil, action: nil))
            .contains(.theme("A:B"))

        model.commit(.theme("A:B"))
        model.refresh()
        #expect(!offered || model.selectedName == "A:B")
    }

    /// A theme file name with a trailing space would be trimmed on reading,
    /// so the menu doesn't offer it.
    @Test func themeNameWithTrailingSpaceIsHiddenOrRoundTrips() throws {
        let box = try WBSandbox(bundledThemes: ["Trail ": "background = #303030\n"])
        let model = box.model()
        let offered = wbChoices(AppearanceMenuItems.theme(model: model, target: nil, action: nil))
            .contains(.theme("Trail "))
        #expect(!offered)

        model.commit(.theme("Trail "))
        model.refresh()
        #expect(!offered || model.selectedName == "Trail ")
    }

    /// A failed save while a preview is showing must not leave terminals
    /// stuck on the preview.
    @Test func failedCommitWhilePreviewingRestoresTerminals() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)

        preview.hover(.theme("Second"))
        scheduler.advance(by: 0.1)
        #expect(log.calls.count == 1)
        #expect(preview.previewing == .theme("Second"))

        // Replace the config folder with a plain file so the save fails.
        let dir = box.config.deletingLastPathComponent()
        try FileManager.default.removeItem(at: dir)
        try "not a folder".write(to: dir, atomically: true, encoding: .utf8)

        preview.commit(.theme("Second"))
        scheduler.advance(by: 1)
        #expect(model.lastError != nil)

        let restored = box.reloads > 0 || (log.calls.count == 2 && log.calls[1] == nil)
        #expect(restored)
    }
}

// MARK: - AppearancePreview timing

@MainActor
struct AppearancePreviewWhiteBoxTests {
    /// A zero delay still goes through the scheduler, never synchronously.
    @Test func zeroDelayHoverWaitsForScheduler() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log, delay: 0)
        let expected = try #require(model.previewText(for: .theme("Sample")))

        preview.hover(.theme("Sample"))
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
        #expect(scheduler.pending.map(\.delay) == [0])

        scheduler.advance(by: 0)
        #expect(log.calls == [expected])
        #expect(preview.previewing == .theme("Sample"))
        #expect(scheduler.pending.isEmpty)
    }

    /// Leaving an item and coming back re-applies it, since the restore in
    /// between showed the saved look.
    @Test func hoverSameThenNilThenSameReapplies() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)
        let sample = try #require(model.previewText(for: .theme("Sample")))

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(nil)
        scheduler.advance(by: 0.1)
        #expect(preview.previewing == nil)
        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)

        #expect(log.calls == [sample, nil, sample])
        #expect(preview.previewing == .theme("Sample"))
        #expect(box.reloads == 0)
    }

    /// A click that lands while a hover is still waiting saves without any
    /// preview, and the menu closing afterwards has nothing to restore.
    @Test func commitWithPendingHoverThenMenuClosedNeverApplies() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        #expect(scheduler.pending.count == 1)
        preview.commit(.theme("Second"))
        #expect(scheduler.pending.isEmpty)
        preview.menuClosed()
        #expect(scheduler.pending.isEmpty)
        scheduler.advance(by: 1)

        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
        #expect(box.reloads == 1)
        #expect(model.selectedName == "Second")
        #expect(box.appearance.contains("theme = Second\n"))
    }

    /// Two menuDidClose calls in a row (a submenu and its parent) restore
    /// the saved look exactly once.
    @Test func menuClosedTwiceRestoresOnce() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)
        let crt = try #require(model.previewText(for: .effect("CRT")))

        preview.hover(.effect("CRT"))
        scheduler.advance(by: 0.1)
        preview.menuClosed()
        preview.menuClosed()
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.first?.delay == 0)

        scheduler.advance(by: 0)
        #expect(log.calls == [crt, nil])
        #expect(preview.previewing == nil)

        preview.menuClosed()
        scheduler.advance(by: 1)
        #expect(log.calls == [crt, nil])
        #expect(box.reloads == 0)
    }

    /// Reopening the menu onto the same item before the restore runs keeps
    /// the preview without flashing back to the saved look.
    @Test func menuClosedThenHoverSameChoiceKeepsPreview() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)
        let sample = try #require(model.previewText(for: .theme("Sample")))

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.menuClosed()
        preview.hover(.theme("Sample"))
        scheduler.advance(by: 1)

        #expect(log.calls == [sample])
        #expect(preview.previewing == .theme("Sample"))

        preview.menuClosed()
        scheduler.advance(by: 0)
        #expect(log.calls == [sample, nil])
        #expect(preview.previewing == nil)
    }

    /// After a commit the preview forgets what it showed, so hovering the
    /// previously previewed item applies it again.
    @Test func hoverAfterCommitReappliesPreviouslyPreviewedChoice() throws {
        let box = try WBSandbox()
        let model = box.model()
        let scheduler = WBScheduler()
        let log = WBApplyLog()
        let preview = wbPreview(model, scheduler, log)
        let second = try #require(model.previewText(for: .theme("Second")))

        preview.hover(.theme("Second"))
        scheduler.advance(by: 0.1)
        preview.commit(.theme("Sample"))
        #expect(preview.previewing == nil)
        #expect(model.selectedName == "Sample")

        // The committed theme itself is now a no-op.
        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        #expect(log.calls == [second])

        preview.hover(.theme("Second"))
        scheduler.advance(by: 0.1)
        #expect(log.calls == [second, second])
        #expect(preview.previewing == .theme("Second"))
        #expect(box.reloads == 1)
    }
}

// MARK: - Menu items

@MainActor
struct AppearanceMenuItemsWhiteBoxTests {
    /// A user theme hiding a bundled one of the same name appears once,
    /// under My Themes, checked.
    @Test func userThemeHidingBundledThemeIsListedOnceAndChecked() throws {
        let box = try WBSandbox(userThemes: ["Sample": "background = #010101\n"])
        try box.writeAppearance("theme = Sample\n")
        let model = box.model()
        let target = WBTarget()
        let action = #selector(WBTarget.pick(_:))
        let items = AppearanceMenuItems.theme(model: model, target: target, action: action)

        #expect(items.map(\.title) == ["Nubb Default", "", "My Themes", "Sample", "Themes", "Second"])
        #expect(items[1].isSeparatorItem)
        #expect(wbCheckedTitles(items) == ["Sample"])
        #expect(wbChoices(items) == [.theme(nil), .theme("Sample"), .theme("Second")])
        #expect(items[3].target === target)
        #expect(items[3].action == action)
        #expect(model.selectedTheme?.location == .user)
    }

    /// A theme set to a file outside both folders still marks the menu, the
    /// way the Effect menu shows "Other:" for an unlisted shader.
    @Test func unlistedThemePathStillChecksOneItem() throws {
        let box = try WBSandbox()
        let dim = try box.writeExtra("Dim", "background-opacity = 0.4\n")
        try box.writeAppearance("theme = \(dim)\n")
        let model = box.model()
        #expect(model.selectedName == dim)
        #expect(model.selectedTheme == nil)

        let items = AppearanceMenuItems.theme(model: model, target: nil, action: nil)
        #expect(wbCheckedTitles(items).count == 1)
        #expect(!wbCheckedTitles(items).contains("Nubb Default"))
    }
}

// MARK: - Overlay through the real config loader

@MainActor
struct AppearanceMenuLoaderWhiteBoxTests {
    /// Previews built by a real model, loaded on top of a config that
    /// includes the appearance file with an absolute-path theme.
    @Test func modelPreviewsSwapAndClearAbsolutePathTheme() throws {
        let box = try WBSandbox()
        let dim = try box.writeExtra("Dim", "background-opacity = 0.4\n")
        let faint = try box.writeExtra("Faint", "background-opacity = 0.7\n")
        try box.writeConfig("config-file = ?\(box.appearanceURL.path)\n")
        try box.writeAppearance("theme = \(dim)\n")
        let model = box.model()
        #expect(model.selectedName == dim)
        #expect(Nubb.Config(at: box.config.path, overlay: nil).backgroundOpacity == 0.4)

        #expect(model.previewText(for: .theme(dim)) == nil)

        let faintText = try #require(model.previewText(for: .theme(faint)))
        let faintOverlay = try box.writeExtra("faint.nubb", AppearanceMenu.overlayText(faintText))
        #expect(Nubb.Config(at: box.config.path, overlay: faintOverlay).backgroundOpacity == 0.7)

        let noneText = try #require(model.previewText(for: .theme(nil)))
        let noneOverlay = try box.writeExtra("none.nubb", AppearanceMenu.overlayText(noneText))
        #expect(Nubb.Config(at: box.config.path, overlay: noneOverlay).backgroundOpacity == 1)

        // Previews never touch the saved files.
        #expect(box.appearance == "theme = \(dim)\n")
        #expect(box.reloads == 0)
    }
}
