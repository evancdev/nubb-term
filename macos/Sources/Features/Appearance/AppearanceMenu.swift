import AppKit

/// A theme or effect someone can hover over or pick in the Appearance menu.
enum AppearanceChoice: Hashable {
    /// A theme by name, or nil for Nubb's default colors.
    case theme(String?)
    /// An effect by name, or nil for no effect.
    case effect(String?)
}

protocol AppearancePreviewCancellable {
    func cancel()
}

extension DispatchWorkItem: AppearancePreviewCancellable {}

/// Shows what a hovered menu item would look like in every open terminal,
/// without saving it. Waits a moment after each hover so sweeping the
/// pointer down the list doesn't reload the config for every item.
@MainActor
final class AppearancePreview {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> AppearancePreviewCancellable

    static let mainQueue: Schedule = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    /// The choice terminals show right now, nil when they show the saved
    /// config.
    private(set) var previewing: AppearanceChoice?

    private let model: AppearanceModel
    private let delay: TimeInterval
    private let schedule: Schedule
    private let apply: (String?) -> Void
    private var pending: AppearancePreviewCancellable?

    /// `apply(text)` shows `text` on top of the config, and `apply(nil)`
    /// goes back to the saved config.
    init(
        model: AppearanceModel,
        delay: TimeInterval = 0.08,
        schedule: @escaping Schedule = AppearancePreview.mainQueue,
        apply: @escaping (String?) -> Void
    ) {
        self.model = model
        self.delay = delay
        self.schedule = schedule
        self.apply = apply
    }

    /// The pointer moved onto `choice`, or off every choice with nil.
    func hover(_ choice: AppearanceChoice?) {
        later(delay) { [weak self] in self?.show(choice) }
    }

    /// Saves `choice`. The reload that follows replaces any preview. If the
    /// save fails there's no reload, so the saved look is put back here.
    func commit(_ choice: AppearanceChoice) {
        cancelPending()
        let wasPreviewing = previewing != nil
        previewing = nil
        model.commit(choice)
        if wasPreviewing, model.lastError != nil { apply(nil) }
    }

    /// The menu closed. AppKit sends the click after this, so the restore
    /// waits a turn of the run loop, and a click cancels it.
    func menuClosed() {
        cancelPending()
        guard previewing != nil else { return }
        later(0) { [weak self] in self?.show(nil) }
    }

    private func show(_ choice: AppearanceChoice?) {
        pending = nil
        let text = choice.flatMap { model.previewText(for: $0) }
        if let text {
            guard choice != previewing else { return }
            previewing = choice
            apply(text)
        } else if previewing != nil {
            previewing = nil
            apply(nil)
        }
    }

    private func later(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        cancelPending()
        pending = schedule(delay, work)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}

/// Builds the items of the Theme and Effect submenus.
@MainActor
enum AppearanceMenuItems {
    static func theme(model: AppearanceModel, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        var items = [choice("Nubb Default", .theme(nil), on: model.settings.theme == .none, target, action)]

        // A theme set by path or by a name no folder has.
        if let name = model.selectedName, model.selectedTheme == nil {
            items.append(other(name))
        }

        items.append(.separator())
        let sections = [("My Themes", model.userThemes), ("Themes", model.bundledThemes)]
        for (title, themes) in sections where !themes.isEmpty {
            items.append(header(title))
            // A name that can't be written as a `theme` value would be lost
            // on the next read, so it isn't offered.
            for theme in themes where canWrite(theme.name) {
                items.append(choice(theme.name, .theme(theme.name), on: theme.name == model.selectedName, target, action))
            }
        }
        return items
    }

    /// True if `theme = <name>` reads back as the same single theme.
    static func canWrite(_ name: String) -> Bool {
        ThemeChoice(configValue: name) == ThemeChoice(single: name)
    }

    static func effect(model: AppearanceModel, target: AnyObject?, action: Selector?) -> [NSMenuItem] {
        var items = [choice("None", .effect(nil), on: model.settings.effect == nil, target, action)]

        // A shader file set by hand that isn't in either folder.
        if let path = model.settings.effect, model.selectedEffect == nil {
            items.append(other(path))
        }

        items.append(.separator())
        let sections = [("My Effects", model.userEffects), ("Effects", model.bundledEffects)]
        for (title, effects) in sections where !effects.isEmpty {
            items.append(header(title))
            for effect in effects {
                let on = effect.url.path == model.selectedEffect?.url.path
                items.append(choice(effect.name, .effect(effect.name), on: on, target, action))
            }
        }

        items.append(.separator())
        let folder = NSMenuItem(title: "Show Shaders Folder", action: #selector(AppearanceMenu.showShadersFolder(_:)), keyEquivalent: "")
        folder.target = target
        items.append(folder)
        return items
    }

    private static func choice(
        _ title: String,
        _ choice: AppearanceChoice,
        on: Bool,
        _ target: AnyObject?,
        _ action: Selector?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = choice
        item.state = on ? .on : .off
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A checked, disabled item for a choice that came from somewhere the
    /// menu doesn't list.
    private static func other(_ path: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Other: \((path as NSString).lastPathComponent)", action: nil, keyEquivalent: "")
        item.state = .on
        item.isEnabled = false
        return item
    }
}

/// Fills the Nubb > Appearance submenus each time they open and previews
/// whatever the pointer rests on.
@MainActor
final class AppearanceMenu: NSObject, NSMenuDelegate {
    /// Also used by the Edit Colors window, so both see the same choice.
    let model: AppearanceModel
    private let app: Nubb.App
    private let themeMenu: NSMenu
    private let effectMenu: NSMenu
    private var preview: AppearancePreview!

    /// Where the preview overlay is written. Each preview replaces it.
    private let overlayURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("nubb-appearance-preview-\(ProcessInfo.processInfo.processIdentifier).nubb")

    init?(app: Nubb.App, themeMenu: NSMenu, effectMenu: NSMenu) {
        let path = app.configFilePath
        guard !path.isEmpty else { return nil }
        self.app = app
        self.themeMenu = themeMenu
        self.effectMenu = effectMenu
        self.model = AppearanceModel(configURL: URL(fileURLWithPath: path)) { [weak app] in
            app?.reloadConfig()
        }
        super.init()

        preview = AppearancePreview(model: model) { [weak self] text in self?.show(text) }
        themeMenu.delegate = self
        effectMenu.delegate = self
        themeMenu.autoenablesItems = false
        effectMenu.autoenablesItems = false
    }

    // MARK: NSMenuDelegate

    /// Without this, AppKit fills these menus to look for key equivalents
    /// on every key press. None of their items have one.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        let items = menu === themeMenu
            ? AppearanceMenuItems.theme(model: model, target: self, action: #selector(pick(_:)))
            : AppearanceMenuItems.effect(model: model, target: self, action: #selector(pick(_:)))
        menu.items = items
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        preview.hover(item?.representedObject as? AppearanceChoice)
    }

    func menuDidClose(_ menu: NSMenu) {
        preview.menuClosed()
    }

    // MARK: Actions

    @objc func pick(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AppearanceChoice else { return }
        preview.commit(choice)
    }

    @objc func showShadersFolder(_ sender: Any?) {
        preview.menuClosed()
        model.openUserEffectsFolder()
    }

    // MARK: Showing previews

    /// The preview loads on top of the saved config, which already includes
    /// `appearance.nubb`. Resetting its options first lets a preview of
    /// "Nubb Default" or "None" undo the saved theme or effect.
    nonisolated static func overlayText(_ text: String) -> String {
        "theme =\ncustom-shader =\ncustom-shader-animation =\n" + text
    }

    private func show(_ text: String?) {
        guard let text else {
            app.reloadConfig()
            return
        }
        do {
            try Self.overlayText(text).write(to: overlayURL, atomically: true, encoding: .utf8)
        } catch {
            Nubb.logger.warning("appearance preview failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        app.previewConfig(overlay: overlayURL.path)
    }
}
