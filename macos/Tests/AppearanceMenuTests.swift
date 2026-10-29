import AppKit
import Foundation
import Testing
@testable import Nubb
@testable import NubbKit

// MARK: - Fixtures

/// A unique temporary folder tree with config, theme and effect folders,
/// removed on deinit. Every AppearanceModel built here gets explicit URLs.
private final class MenuSandbox {
    let root: URL
    let config: URL
    let userThemes: URL
    let bundledThemes: URL
    let userEffects: URL
    let bundledEffects: URL
    var reloads = 0

    static let animatedSource = "void mainImage(out vec4 c, in vec2 p) { c = vec4(sin(iTime)); }"
    static let stillSource = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"

    /// - Parameters:
    ///   - userThemeNames: theme files written to the user themes folder.
    ///   - bundledThemeNames: theme files written to the bundled themes folder.
    ///   - userEffects: `(name, animates)` pairs written as `<name>.glsl`.
    ///   - bundledEffects: `(name, animates)` pairs written as `<name>.glsl`.
    init(
        userThemeNames: [String] = [],
        bundledThemeNames: [String] = ["Sample", "Second"],
        userEffects userEffectFiles: [(String, Bool)] = [("Pulse", true)],
        bundledEffects bundledEffectFiles: [(String, Bool)] = [("CRT", false)]
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-menu-tests-\(UUID().uuidString)", isDirectory: true)
        config = root.appendingPathComponent("config/config.nubb")
        userThemes = root.appendingPathComponent("themes", isDirectory: true)
        bundledThemes = root.appendingPathComponent("bundled-themes", isDirectory: true)
        userEffects = root.appendingPathComponent("shaders", isDirectory: true)
        bundledEffects = root.appendingPathComponent("bundled-shaders", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: userThemes, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundledThemes, withIntermediateDirectories: true)
        try fm.createDirectory(at: userEffects, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundledEffects, withIntermediateDirectories: true)
        try "font-size = 13\n".write(to: config, atomically: true, encoding: .utf8)
        for (index, name) in userThemeNames.enumerated() {
            try "background = #00000\(index % 10)\n"
                .write(to: userThemes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (index, name) in bundledThemeNames.enumerated() {
            try "background = #ffffe\(index % 10)\n"
                .write(to: bundledThemes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (name, animates) in userEffectFiles {
            try (animates ? Self.animatedSource : Self.stillSource)
                .write(to: userEffects.appendingPathComponent("\(name).glsl"), atomically: true, encoding: .utf8)
        }
        for (name, animates) in bundledEffectFiles {
            try (animates ? Self.animatedSource : Self.stillSource)
                .write(to: bundledEffects.appendingPathComponent("\(name).glsl"), atomically: true, encoding: .utf8)
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

    /// Write `appearance.nubb` before building the model so it starts from these settings.
    func seed(_ settings: AppearanceSettings) throws {
        try settings.serialized().write(to: appearanceURL, atomically: true, encoding: .utf8)
    }

    var appearanceURL: URL { config.deletingLastPathComponent().appendingPathComponent("appearance.nubb") }
    var appearanceExists: Bool { FileManager.default.fileExists(atPath: appearanceURL.path) }
    var appearance: String { (try? String(contentsOf: appearanceURL, encoding: .utf8)) ?? "" }

    var crtPath: String { bundledEffects.appendingPathComponent("CRT.glsl").path }
    var pulsePath: String { userEffects.appendingPathComponent("Pulse.glsl").path }
}

/// A cancellable token recorded by the fake scheduler.
private final class MenuFakeTask: AppearancePreviewCancellable {
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
/// work in time order (ties in scheduling order).
private final class MenuFakeScheduler {
    private(set) var now: TimeInterval = 0
    private(set) var tasks: [MenuFakeTask] = []

    var schedule: AppearancePreview.Schedule {
        { [unowned self] delay, work in
            let task = MenuFakeTask(fireTime: self.now + delay, delay: delay, order: self.tasks.count, work: work)
            self.tasks.append(task)
            return task
        }
    }

    var pending: [MenuFakeTask] { tasks.filter { !$0.cancelled && !$0.ran } }

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

/// Records every `apply` call.
private final class MenuApplyLog {
    var calls: [String?] = []
}

@MainActor
private func makeMenuPreview(
    _ model: AppearanceModel,
    _ scheduler: MenuFakeScheduler,
    _ log: MenuApplyLog
) -> AppearancePreview {
    AppearancePreview(model: model, delay: 0.08, schedule: scheduler.schedule, apply: { log.calls.append($0) })
}

/// The expected preview text: current settings with a change applied.
@MainActor
private func menuExpected(_ model: AppearanceModel, _ change: (inout AppearanceSettings) -> Void) -> String {
    var settings = model.settings
    change(&settings)
    return settings.serialized()
}

// MARK: - 1. Config overlay

struct AppearanceMenuConfigOverlayTests {
    private final class MenuConfigFiles {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-menu-overlay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ text: String, _ name: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    @Test func overlayValuesWinOverConfig() throws {
        let files = try MenuConfigFiles()
        let config = try files.write("background-opacity = 0.5\n", "config.nubb")
        let overlay = try files.write("background-opacity = 0.8\n", "overlay.nubb")
        let loaded = Nubb.Config(at: config, overlay: overlay)
        #expect(loaded.backgroundOpacity == 0.8)
    }

    @Test func nilOverlayBehavesLikePlainLoad() throws {
        let files = try MenuConfigFiles()
        let config = try files.write("background-opacity = 0.5\n", "config.nubb")
        let loaded = Nubb.Config(at: config, overlay: nil)
        #expect(loaded.backgroundOpacity == 0.5)
        #expect(loaded.backgroundOpacity == Nubb.Config(at: config).backgroundOpacity)
    }

    @Test func overlayWithoutTheKeyKeepsConfigValue() throws {
        let files = try MenuConfigFiles()
        let config = try files.write("background-opacity = 0.5\n", "config.nubb")
        let overlay = try files.write("font-size = 15\n", "overlay.nubb")
        let loaded = Nubb.Config(at: config, overlay: overlay)
        #expect(loaded.backgroundOpacity == 0.5)
    }

    @Test func missingOverlayFileIsIgnored() throws {
        let files = try MenuConfigFiles()
        let config = try files.write("background-opacity = 0.5\n", "config.nubb")
        let missing = files.root.appendingPathComponent("no-such-overlay.nubb").path
        let loaded = Nubb.Config(at: config, overlay: missing)
        #expect(loaded.backgroundOpacity == 0.5)
        #expect(loaded.backgroundOpacity == Nubb.Config(at: config).backgroundOpacity)
    }

    @Test func overlayAppliesOverDefaultWhenConfigOmitsKey() throws {
        let files = try MenuConfigFiles()
        let config = try files.write("font-size = 13\n", "config.nubb")
        let overlay = try files.write("background-opacity = 0.3\n", "overlay.nubb")
        #expect(Nubb.Config(at: config, overlay: nil).backgroundOpacity == 1.0)
        #expect(Nubb.Config(at: config, overlay: overlay).backgroundOpacity == 0.3)
    }
}

// MARK: - 2. AppearanceChoice and previewText

@MainActor
struct AppearanceMenuPreviewTextTests {
    @Test func appearanceChoiceIsHashable() {
        let set: Set<AppearanceChoice> = [.theme(nil), .theme("A"), .effect(nil), .effect("A"), .theme("A")]
        #expect(set.count == 4)
        #expect(AppearanceChoice.theme("A") != AppearanceChoice.effect("A"))
        #expect(AppearanceChoice.theme(nil) != AppearanceChoice.effect(nil))
    }

    @Test func themeChoiceGivesSerializedSettingsWithTheme() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let text = model.previewText(for: .theme("Sample"))
        #expect(text == menuExpected(model) { $0.theme = ThemeChoice(single: "Sample") })
        #expect(text?.contains("theme = Sample") == true)
    }

    @Test func themeSameAsCurrentGivesNil() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        try box.seed(seeded)
        let model = box.model()
        #expect(model.settings.theme == ThemeChoice(single: "Sample"))
        #expect(model.previewText(for: .theme("Sample")) == nil)
        #expect(model.previewText(for: .theme("Second")) != nil)
    }

    @Test func nilThemeOnDefaultGivesNilAndOnThemeGivesText() throws {
        let box = try MenuSandbox()
        let model = box.model()
        #expect(model.settings.theme == .none)
        #expect(model.previewText(for: .theme(nil)) == nil)

        let box2 = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        try box2.seed(seeded)
        let themed = box2.model()
        let text = themed.previewText(for: .theme(nil))
        #expect(text == menuExpected(themed) { $0.theme = .none })
        #expect(text?.contains("theme =") == false)
    }

    @Test func singleThemeOverPairIsNeverEqual() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(light: "Sample", dark: "Second")
        try box.seed(seeded)
        let model = box.model()
        #expect(model.settings.theme.isPair)
        #expect(model.selectedName == "Second")
        let text = model.previewText(for: .theme("Second"))
        #expect(text != nil)
        #expect(text == menuExpected(model) { $0.theme = ThemeChoice(single: "Second") })
    }

    @Test func effectNameUsesEntryPathAndAnimates() throws {
        let box = try MenuSandbox()
        let model = box.model()

        let still = model.previewText(for: .effect("CRT"))
        #expect(still == menuExpected(model) {
            $0.effect = box.crtPath
            $0.effectAnimates = false
        })
        #expect(still?.contains("custom-shader = \(box.crtPath)") == true)
        #expect(still?.contains("custom-shader-animation = false") == true)

        let animated = model.previewText(for: .effect("Pulse"))
        #expect(animated == menuExpected(model) {
            $0.effect = box.pulsePath
            $0.effectAnimates = true
        })
        #expect(animated?.contains("custom-shader = \(box.pulsePath)") == true)
        #expect(animated?.contains("custom-shader-animation") == false)
    }

    @Test func unknownEffectGivesNil() throws {
        let box = try MenuSandbox()
        let model = box.model()
        #expect(model.previewText(for: .effect("Nope")) == nil)
    }

    @Test func noEffectOnNoEffectGivesNil() throws {
        let box = try MenuSandbox()
        let model = box.model()
        #expect(model.settings.effect == nil)
        #expect(model.previewText(for: .effect(nil)) == nil)
    }

    @Test func sameEffectAsCurrentGivesNil() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.effect = box.crtPath
        seeded.effectAnimates = false
        try box.seed(seeded)
        let model = box.model()
        #expect(model.selectedEffect?.name == "CRT")
        #expect(model.previewText(for: .effect("CRT")) == nil)
    }

    @Test func effectNilClearsEffectAndResetsAnimatesKeepingTheme() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        seeded.effect = box.crtPath
        seeded.effectAnimates = false
        try box.seed(seeded)
        let model = box.model()

        let text = model.previewText(for: .effect(nil))
        var expected = AppearanceSettings()
        expected.theme = ThemeChoice(single: "Sample")
        expected.effect = nil
        expected.effectAnimates = true
        #expect(text == expected.serialized())
        #expect(text?.contains("theme = Sample") == true)
        #expect(text?.contains("custom-shader") == false)
    }

    @Test func themeChoiceKeepsEffect() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.effect = box.crtPath
        seeded.effectAnimates = false
        try box.seed(seeded)
        let model = box.model()

        let text = model.previewText(for: .theme("Second"))
        #expect(text == menuExpected(model) { $0.theme = ThemeChoice(single: "Second") })
        #expect(text?.contains("theme = Second") == true)
        #expect(text?.contains("custom-shader = \(box.crtPath)") == true)
        #expect(text?.contains("custom-shader-animation = false") == true)
    }

    @Test func effectChoiceKeepsTheme() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(light: "Sample", dark: "Second")
        try box.seed(seeded)
        let model = box.model()
        let text = model.previewText(for: .effect("Pulse"))
        var expected = AppearanceSettings()
        expected.theme = ThemeChoice(light: "Sample", dark: "Second")
        expected.effect = box.pulsePath
        expected.effectAnimates = true
        #expect(text == expected.serialized())
    }

    @Test func previewTextLeavesSettingsFilesAndReloadAlone() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let before = model.settings
        let reloads = box.reloads
        #expect(!box.appearanceExists)

        _ = model.previewText(for: .theme("Sample"))
        _ = model.previewText(for: .theme(nil))
        _ = model.previewText(for: .effect("CRT"))
        _ = model.previewText(for: .effect("Pulse"))
        _ = model.previewText(for: .effect(nil))
        _ = model.previewText(for: .effect("Nope"))

        #expect(model.settings == before)
        #expect(model.selectedName == nil)
        #expect(model.selectedEffect == nil)
        #expect(box.reloads == reloads)
        #expect(!box.appearanceExists)
    }

    @Test func previewTextDoesNotRewriteExistingAppearanceFile() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        try box.seed(seeded)
        let model = box.model()
        let contents = box.appearance
        let reloads = box.reloads
        let before = model.settings

        _ = model.previewText(for: .theme("Second"))
        _ = model.previewText(for: .effect("CRT"))

        #expect(box.appearance == contents)
        #expect(box.reloads == reloads)
        #expect(model.settings == before)
    }
}

// MARK: - 3. AppearancePreview

@MainActor
struct AppearanceMenuPreviewTests {
    @Test func hoverAppliesOnlyAfterDelay() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let expected = model.previewText(for: .theme("Sample"))

        preview.hover(.theme("Sample"))
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.first?.delay == 0.08)

        scheduler.advance(by: 0.05)
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)

        scheduler.advance(by: 0.05)
        #expect(log.calls == [expected])
        #expect(preview.previewing == .theme("Sample"))
    }

    @Test func hoverDoesNotTouchSettingsOrReload() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let before = model.settings
        let reloads = box.reloads

        preview.hover(.effect("CRT"))
        scheduler.advance(by: 1)
        preview.hover(.theme("Second"))
        scheduler.advance(by: 1)
        preview.hover(nil)
        scheduler.advance(by: 1)

        #expect(model.settings == before)
        #expect(box.reloads == reloads)
        #expect(!box.appearanceExists)
    }

    @Test func rapidHoversApplyOnlyTheLast() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.02)
        preview.hover(.effect("CRT"))
        scheduler.advance(by: 0.02)
        preview.hover(.theme("Second"))
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.tasks.filter(\.cancelled).count == 2)

        scheduler.advance(by: 0.5)
        #expect(log.calls == [model.previewText(for: .theme("Second"))])
        #expect(preview.previewing == .theme("Second"))
    }

    @Test func hoverSwitchesBetweenPreviews() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.effect("Pulse"))
        scheduler.advance(by: 0.1)

        #expect(log.calls == [
            model.previewText(for: .theme("Sample")),
            model.previewText(for: .effect("Pulse")),
        ])
        #expect(preview.previewing == .effect("Pulse"))
    }

    @Test func hoveringSameChoiceTwiceAppliesOnce() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)

        #expect(log.calls == [model.previewText(for: .theme("Sample"))])
        #expect(preview.previewing == .theme("Sample"))
    }

    @Test func hoverNilRestoresSavedLook() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.effect("CRT"))
        scheduler.advance(by: 0.1)
        preview.hover(nil)
        #expect(log.calls.count == 1)
        #expect(preview.previewing == .effect("CRT"))
        #expect(scheduler.pending.first?.delay == 0.08)

        scheduler.advance(by: 0.1)
        #expect(log.calls == [model.previewText(for: .effect("CRT")), nil])
        #expect(preview.previewing == nil)

        // Again with nothing previewing: no repeated restore.
        preview.hover(nil)
        scheduler.advance(by: 0.1)
        #expect(log.calls.count == 2)
    }

    @Test func hoverNilWithNothingPreviewingDoesNothing() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(nil)
        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
    }

    @Test func hoverNilCancelsPendingHover() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.03)
        preview.hover(nil)
        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
    }

    @Test func hoverOverNoOpChoiceWhilePreviewingRestores() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        #expect(model.previewText(for: .theme(nil)) == nil)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.theme(nil))
        scheduler.advance(by: 0.1)
        #expect(log.calls == [model.previewText(for: .theme("Sample")), nil])
        #expect(preview.previewing == nil)

        // Another no-op hover with nothing previewing does not restore again.
        preview.hover(.effect(nil))
        scheduler.advance(by: 0.1)
        #expect(log.calls.count == 2)
        #expect(preview.previewing == nil)
    }

    @Test func hoverOverUnknownEffectWhilePreviewingRestores() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.effect("Pulse"))
        scheduler.advance(by: 0.1)
        preview.hover(.effect("Nope"))
        scheduler.advance(by: 0.1)
        #expect(log.calls == [model.previewText(for: .effect("Pulse")), nil])
        #expect(preview.previewing == nil)
    }

    @Test func hoverOverNoOpChoiceWithNothingPreviewingDoesNothing() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        try box.seed(seeded)
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.effect(nil))
        scheduler.advance(by: 0.1)
        preview.hover(.effect("Nope"))
        scheduler.advance(by: 0.1)
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
    }

    @Test func commitSavesReloadsOnceAndNeverApplies() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads

        preview.commit(.theme("Sample"))
        #expect(box.reloads == reloads + 1)
        #expect(box.appearanceExists)
        #expect(box.appearance.contains("theme = Sample"))
        #expect(model.settings.theme == ThemeChoice(single: "Sample"))
        #expect(model.selectedName == "Sample")
        #expect(preview.previewing == nil)

        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)
    }

    @Test func commitEffectWritesShaderPath() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads

        preview.commit(.effect("CRT"))
        #expect(box.reloads == reloads + 1)
        #expect(box.appearance.contains("custom-shader = \(box.crtPath)"))
        #expect(box.appearance.contains("custom-shader-animation = false"))
        #expect(model.selectedEffect?.name == "CRT")
        #expect(model.settings.effect == box.crtPath)

        preview.commit(.effect(nil))
        #expect(box.reloads == reloads + 2)
        #expect(!box.appearance.contains("custom-shader"))
        #expect(model.settings.effect == nil)

        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)
    }

    @Test func commitWhilePreviewingClearsPreviewWithoutApply() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads

        preview.hover(.theme("Second"))
        scheduler.advance(by: 0.1)
        #expect(log.calls.count == 1)
        #expect(preview.previewing == .theme("Second"))

        preview.commit(.theme("Second"))
        #expect(preview.previewing == nil)
        #expect(box.reloads == reloads + 1)
        #expect(box.appearance.contains("theme = Second"))

        preview.menuClosed()
        scheduler.advance(by: 1)
        #expect(log.calls.count == 1)
    }

    @Test func commitCancelsPendingHover() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads
        let sampleText = model.previewText(for: .theme("Sample"))

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.effect("CRT"))
        preview.commit(.effect("CRT"))
        #expect(scheduler.pending.isEmpty)

        scheduler.advance(by: 1)
        #expect(log.calls == [sampleText])
        #expect(preview.previewing == nil)
        #expect(box.reloads == reloads + 1)
        #expect(box.appearance.contains("custom-shader = \(box.crtPath)"))
    }

    @Test func commitCancelsPendingMenuClosedRestore() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads
        let sampleText = model.previewText(for: .theme("Sample"))

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.menuClosed()
        #expect(scheduler.pending.count == 1)
        preview.commit(.theme("Sample"))
        #expect(scheduler.pending.isEmpty)

        scheduler.advance(by: 1)
        #expect(log.calls == [sampleText])
        #expect(!log.calls.contains(where: { $0 == nil }))
        #expect(preview.previewing == nil)
        #expect(box.reloads == reloads + 1)
        #expect(box.appearance.contains("theme = Sample"))
    }

    @Test func menuClosedRestoresWithZeroDelay() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.effect("Pulse"))
        scheduler.advance(by: 0.1)
        preview.menuClosed()
        #expect(log.calls.count == 1)
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.first?.delay == 0)

        scheduler.advance(by: 0)
        #expect(log.calls == [model.previewText(for: .effect("Pulse")), nil])
        #expect(preview.previewing == nil)

        scheduler.advance(by: 1)
        #expect(log.calls.count == 2)
    }

    @Test func menuClosedCancelsPendingHover() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.hover(.theme("Sample"))
        scheduler.advance(by: 0.1)
        preview.hover(.theme("Second"))
        preview.menuClosed()
        scheduler.advance(by: 1)
        #expect(log.calls == [model.previewText(for: .theme("Sample")), nil])
        #expect(preview.previewing == nil)
    }

    @Test func menuClosedWithNothingPreviewingDoesNothing() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)
        let reloads = box.reloads

        preview.menuClosed()
        #expect(scheduler.tasks.isEmpty)
        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)

        // A pending hover that never ran is cancelled and nothing is restored.
        preview.hover(.theme("Sample"))
        let scheduled = scheduler.tasks.count
        preview.menuClosed()
        #expect(scheduler.tasks.count == scheduled)
        #expect(scheduler.pending.isEmpty)
        scheduler.advance(by: 1)
        #expect(log.calls.isEmpty)
        #expect(preview.previewing == nil)
        #expect(box.reloads == reloads)
        #expect(!box.appearanceExists)
    }

    @Test func mainQueueSchedulerRunsWorkAndHonorsCancel() async throws {
        var ran = false
        var cancelledRan = false
        let cancelled = AppearancePreview.mainQueue(0) { cancelledRan = true }
        cancelled.cancel()
        _ = AppearancePreview.mainQueue(0.01) { ran = true }
        for _ in 0 ..< 100 where !ran {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(ran)
        #expect(!cancelledRan)
    }
}

// MARK: - 4. Menu items

private final class MenuTestTarget: NSObject {
    @objc func pick(_ sender: Any?) {}
}

/// A compact description of one menu item: `---`, `[Header]`, or `Title (on|off)`.
@MainActor
private func menuShape(_ items: [NSMenuItem]) -> [String] {
    items.map { item in
        if item.isSeparatorItem { return "---" }
        if item.representedObject == nil && item.action == nil && !item.isEnabled && item.state == .off {
            return "[\(item.title)]"
        }
        return "\(item.title) (\(item.state == .on ? "on" : "off"))"
    }
}

@MainActor
struct AppearanceMenuItemsTests {
    private let target = MenuTestTarget()
    private let action = #selector(MenuTestTarget.pick(_:))

    private func expectChoice(
        _ item: NSMenuItem?,
        _ choice: AppearanceChoice,
        state: NSControl.StateValue,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let item else {
            Issue.record("missing item for \(choice)", sourceLocation: sourceLocation)
            return
        }
        #expect(item.representedObject as? AppearanceChoice == choice, sourceLocation: sourceLocation)
        #expect(item.target === target, sourceLocation: sourceLocation)
        #expect(item.action == action, sourceLocation: sourceLocation)
        #expect(item.isEnabled, sourceLocation: sourceLocation)
        #expect(item.state == state, sourceLocation: sourceLocation)
    }

    private func expectHeader(_ item: NSMenuItem?, _ title: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let item else {
            Issue.record("missing header \(title)", sourceLocation: sourceLocation)
            return
        }
        #expect(item.title == title, sourceLocation: sourceLocation)
        #expect(!item.isSeparatorItem, sourceLocation: sourceLocation)
        #expect(!item.isEnabled, sourceLocation: sourceLocation)
        #expect(item.representedObject == nil, sourceLocation: sourceLocation)
        #expect(item.action == nil, sourceLocation: sourceLocation)
        #expect(item.state == .off, sourceLocation: sourceLocation)
    }

    @Test func themeItemsOrderWithDefaultSelected() throws {
        let box = try MenuSandbox(userThemeNames: ["Mine", "Alpha"], bundledThemeNames: ["Sample", "Second"])
        let model = box.model()
        let items = AppearanceMenuItems.theme(model: model, target: target, action: action)

        #expect(menuShape(items) == [
            "Nubb Default (on)",
            "---",
            "[My Themes]",
            "Alpha (off)",
            "Mine (off)",
            "[Themes]",
            "Sample (off)",
            "Second (off)",
        ])
        #expect(items.count == 8)
        expectChoice(items[0], .theme(nil), state: .on)
        #expect(items[0].title == "Nubb Default")
        #expect(items[1].isSeparatorItem)
        expectHeader(items[2], "My Themes")
        expectChoice(items[3], .theme("Alpha"), state: .off)
        expectChoice(items[4], .theme("Mine"), state: .off)
        expectHeader(items[5], "Themes")
        expectChoice(items[6], .theme("Sample"), state: .off)
        expectChoice(items[7], .theme("Second"), state: .off)
    }

    @Test func themeItemsCheckSelectedTheme() throws {
        let box = try MenuSandbox(userThemeNames: ["Mine"], bundledThemeNames: ["Sample", "Second"])
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Sample")
        try box.seed(seeded)
        let model = box.model()
        let items = AppearanceMenuItems.theme(model: model, target: target, action: action)

        #expect(menuShape(items) == [
            "Nubb Default (off)",
            "---",
            "[My Themes]",
            "Mine (off)",
            "[Themes]",
            "Sample (on)",
            "Second (off)",
        ])
        expectChoice(items.first, .theme(nil), state: .off)
        expectChoice(items.first { $0.title == "Sample" }, .theme("Sample"), state: .on)
        expectChoice(items.first { $0.title == "Mine" }, .theme("Mine"), state: .off)
    }

    @Test func themeItemsCheckUserTheme() throws {
        let box = try MenuSandbox(userThemeNames: ["Mine"], bundledThemeNames: ["Sample"])
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(single: "Mine")
        try box.seed(seeded)
        let model = box.model()
        let items = AppearanceMenuItems.theme(model: model, target: target, action: action)
        #expect(menuShape(items) == [
            "Nubb Default (off)", "---", "[My Themes]", "Mine (on)", "[Themes]", "Sample (off)",
        ])
    }

    @Test func themeItemsCheckDarkThemeOfPair() throws {
        let box = try MenuSandbox(bundledThemeNames: ["Sample", "Second"])
        var seeded = AppearanceSettings()
        seeded.theme = ThemeChoice(light: "Sample", dark: "Second")
        try box.seed(seeded)
        let model = box.model()
        let items = AppearanceMenuItems.theme(model: model, target: target, action: action)
        #expect(menuShape(items) == [
            "Nubb Default (off)", "---", "[Themes]", "Sample (off)", "Second (on)",
        ])
    }

    @Test func themeItemsOmitEmptySections() throws {
        let onlyBundled = try MenuSandbox(userThemeNames: [], bundledThemeNames: ["Sample"])
        let bundledItems = AppearanceMenuItems.theme(model: onlyBundled.model(), target: target, action: action)
        #expect(menuShape(bundledItems) == ["Nubb Default (on)", "---", "[Themes]", "Sample (off)"])

        let onlyUser = try MenuSandbox(userThemeNames: ["Mine"], bundledThemeNames: [])
        let userItems = AppearanceMenuItems.theme(model: onlyUser.model(), target: target, action: action)
        #expect(menuShape(userItems) == ["Nubb Default (on)", "---", "[My Themes]", "Mine (off)"])

        let empty = try MenuSandbox(userThemeNames: [], bundledThemeNames: [])
        let emptyItems = AppearanceMenuItems.theme(model: empty.model(), target: target, action: action)
        #expect(menuShape(emptyItems) == ["Nubb Default (on)", "---"])
        expectChoice(emptyItems.first, .theme(nil), state: .on)
    }

    @Test func themeItemsUsePassedNilTargetAndAction() throws {
        let box = try MenuSandbox(bundledThemeNames: ["Sample"])
        let items = AppearanceMenuItems.theme(model: box.model(), target: nil, action: nil)
        let choices = items.filter { $0.representedObject is AppearanceChoice }
        #expect(choices.count == 2)
        for item in choices {
            #expect(item.target == nil)
            #expect(item.action == nil)
        }
    }

    @Test func effectItemsOrderWithNoneSelected() throws {
        let box = try MenuSandbox(
            userEffects: [("Pulse", true), ("Aura", false)],
            bundledEffects: [("CRT", false), ("Bloom", true)]
        )
        let model = box.model()
        let items = AppearanceMenuItems.effect(model: model, target: target, action: action)

        #expect(menuShape(items) == [
            "None (on)",
            "---",
            "[My Effects]",
            "Aura (off)",
            "Pulse (off)",
            "[Effects]",
            "Bloom (off)",
            "CRT (off)",
            "---",
            "Show Shaders Folder (off)",
        ])
        #expect(items.count == 10)
        expectChoice(items[0], .effect(nil), state: .on)
        #expect(items[1].isSeparatorItem)
        expectHeader(items[2], "My Effects")
        expectChoice(items[3], .effect("Aura"), state: .off)
        expectChoice(items[4], .effect("Pulse"), state: .off)
        expectHeader(items[5], "Effects")
        expectChoice(items[6], .effect("Bloom"), state: .off)
        expectChoice(items[7], .effect("CRT"), state: .off)
        #expect(items[8].isSeparatorItem)
    }

    @Test func showShadersFolderItem() throws {
        let box = try MenuSandbox()
        let items = AppearanceMenuItems.effect(model: box.model(), target: target, action: action)
        let show = try #require(items.last)
        #expect(show.title == "Show Shaders Folder")
        #expect(show.isEnabled)
        #expect(show.representedObject == nil)
        #expect(!(show.representedObject is AppearanceChoice))
        #expect(show.action != nil)
        #expect(show.action != action)
        #expect(show.state == .off)
        let beforeLast = items[items.count - 2]
        #expect(beforeLast.isSeparatorItem)
    }

    @Test func effectItemsCheckSelectedEffect() throws {
        let box = try MenuSandbox()
        var seeded = AppearanceSettings()
        seeded.effect = box.crtPath
        seeded.effectAnimates = false
        try box.seed(seeded)
        let model = box.model()
        #expect(model.selectedEffect?.name == "CRT")
        let items = AppearanceMenuItems.effect(model: model, target: target, action: action)

        #expect(menuShape(items) == [
            "None (off)",
            "---",
            "[My Effects]",
            "Pulse (off)",
            "[Effects]",
            "CRT (on)",
            "---",
            "Show Shaders Folder (off)",
        ])
        expectChoice(items.first, .effect(nil), state: .off)
        expectChoice(items.first { $0.title == "CRT" }, .effect("CRT"), state: .on)
        expectChoice(items.first { $0.title == "Pulse" }, .effect("Pulse"), state: .off)
        #expect(!items.contains { $0.title.hasPrefix("Other") })
    }

    @Test func effectItemsShowOtherForUnknownShader() throws {
        let box = try MenuSandbox()
        let elsewhere = box.root.appendingPathComponent("elsewhere/Weird Glow.glsl")
        var seeded = AppearanceSettings()
        seeded.effect = elsewhere.path
        try box.seed(seeded)
        let model = box.model()
        #expect(model.settings.effect == elsewhere.path)
        #expect(model.selectedEffect == nil)
        let items = AppearanceMenuItems.effect(model: model, target: target, action: action)

        #expect(items.count == 9)
        expectChoice(items[0], .effect(nil), state: .off)
        let other = items[1]
        #expect(other.title == "Other: Weird Glow.glsl")
        #expect(other.state == .on)
        #expect(!other.isEnabled)
        #expect(other.representedObject == nil)
        #expect(other.action == nil)
        #expect(!other.isSeparatorItem)
        #expect(items[2].isSeparatorItem)
        #expect(Array(menuShape(items).dropFirst(2)) == [
            "---",
            "[My Effects]",
            "Pulse (off)",
            "[Effects]",
            "CRT (off)",
            "---",
            "Show Shaders Folder (off)",
        ])
    }

    @Test func effectItemsOmitEmptySections() throws {
        let onlyBundled = try MenuSandbox(userEffects: [], bundledEffects: [("CRT", false)])
        #expect(menuShape(AppearanceMenuItems.effect(model: onlyBundled.model(), target: target, action: action)) == [
            "None (on)", "---", "[Effects]", "CRT (off)", "---", "Show Shaders Folder (off)",
        ])

        let onlyUser = try MenuSandbox(userEffects: [("Pulse", true)], bundledEffects: [])
        #expect(menuShape(AppearanceMenuItems.effect(model: onlyUser.model(), target: target, action: action)) == [
            "None (on)", "---", "[My Effects]", "Pulse (off)", "---", "Show Shaders Folder (off)",
        ])

        let empty = try MenuSandbox(userEffects: [], bundledEffects: [])
        let items = AppearanceMenuItems.effect(model: empty.model(), target: target, action: action)
        #expect(menuShape(items) == ["None (on)", "---", "---", "Show Shaders Folder (off)"])
        expectChoice(items.first, .effect(nil), state: .on)
        #expect(items.last?.action != nil)
        #expect(items.last?.action != action)
    }

    @Test func effectItemsUsePassedNilTargetAndAction() throws {
        let box = try MenuSandbox()
        let items = AppearanceMenuItems.effect(model: box.model(), target: nil, action: nil)
        let choices = items.filter { $0.representedObject is AppearanceChoice }
        #expect(choices.count == 3)
        for item in choices {
            #expect(item.target == nil)
            #expect(item.action == nil)
            #expect(item.isEnabled)
        }
        let show = try #require(items.last)
        #expect(show.title == "Show Shaders Folder")
        #expect(show.action != nil)
    }

    @Test func itemsReflectModelAfterCommit() throws {
        let box = try MenuSandbox()
        let model = box.model()
        let scheduler = MenuFakeScheduler()
        let log = MenuApplyLog()
        let preview = makeMenuPreview(model, scheduler, log)

        preview.commit(.theme("Second"))
        preview.commit(.effect("Pulse"))
        let themes = AppearanceMenuItems.theme(model: model, target: target, action: action)
        let effects = AppearanceMenuItems.effect(model: model, target: target, action: action)
        #expect(themes.first { $0.state == .on }?.title == "Second")
        #expect(effects.first { $0.state == .on }?.title == "Pulse")
        #expect(themes.filter { $0.state == .on }.count == 1)
        #expect(effects.filter { $0.state == .on }.count == 1)
    }
}
