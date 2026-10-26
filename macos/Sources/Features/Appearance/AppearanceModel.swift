import AppKit
import Combine

/// State for the Appearance window. Every change writes `appearance.nubb`
/// and reloads the config, so open terminals update while you pick.
///
/// The window edits one theme at a time. Your own themes save as you edit.
/// Changing a color on a bundled theme (or on Nubb's defaults) first saves
/// a copy under your themes, so bundled files are never touched.
@MainActor
final class AppearanceModel: ObservableObject {
    /// The name prompt for creating or renaming a theme.
    struct NamePrompt: Identifiable {
        enum Kind: Equatable {
            case create
            case rename(String)
        }

        let kind: Kind
        var name: String

        var id: String {
            switch kind {
            case .create: "create"
            case .rename(let old): "rename:\(old)"
            }
        }
    }

    @Published private(set) var themes: [ThemeEntry] = []
    @Published private(set) var settings = AppearanceSettings()
    @Published var namePrompt: NamePrompt?
    @Published private(set) var lastError: String?

    /// The main config file. The model adds one include line to it.
    let configURL: URL

    /// Where new themes go.
    let userThemesURL: URL

    private let bundledThemesURL: URL?

    /// The file this window owns, next to the main config.
    var appearanceURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent(AppearanceInclude.fileName)
    }

    private let reload: () -> Void
    private let trash: (URL) throws -> Void
    private var pendingSave: Task<Void, Never>?

    /// A user theme edited in memory and not yet written to disk.
    private var dirtyTheme: ThemeEntry?

    init(
        configURL: URL,
        userThemesURL: URL = ThemeCatalog.userDirectory,
        bundledThemesURL: URL? = ThemeCatalog.bundledDirectory,
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        reload: @escaping () -> Void
    ) {
        self.configURL = configURL
        self.userThemesURL = userThemesURL
        self.bundledThemesURL = bundledThemesURL
        self.trash = trash
        self.reload = reload
        refresh()
    }

    /// Re-reads the theme folders and the appearance file.
    func refresh() {
        reloadThemes()
        if let text = try? String(contentsOf: appearanceURL, encoding: .utf8) {
            settings = AppearanceSettings(parsing: text)
        } else {
            settings = AppearanceSettings()
        }
    }

    private func reloadThemes() {
        themes = ThemeCatalog.load(user: userThemesURL, bundled: bundledThemesURL)
    }

    // MARK: Picking a theme

    var userThemes: [ThemeEntry] { themes.filter { $0.location == .user } }
    var bundledThemes: [ThemeEntry] { themes.filter { $0.location == .bundled } }

    /// The theme being shown and edited. Nil means Nubb's default colors.
    /// A config with separate light and dark themes shows the dark one.
    var selectedName: String? { settings.theme.dark ?? settings.theme.light }

    /// True when the config picks separate light and dark themes. Picking
    /// a theme in the window replaces both with one.
    var hasLightDarkPair: Bool { settings.theme.isPair }

    var selectedTheme: ThemeEntry? {
        guard let name = selectedName else { return nil }
        return themes.first { $0.name == name }
    }

    /// The selected theme if it's one of yours, so color changes save into it.
    var editableTheme: ThemeEntry? {
        guard let theme = selectedTheme, theme.location == .user else { return nil }
        return theme
    }

    /// The selected theme's colors, plus any color lines an older version
    /// of this window left in `appearance.nubb`. This is what terminals show.
    private var currentColors: ThemeColors {
        (selectedTheme?.colors ?? ThemeColors()).merged(with: settings.overrides)
    }

    var previewColors: ResolvedColors { ResolvedColors(currentColors) }

    func select(_ name: String?) {
        guard name != selectedName || hasLightDarkPair else { return }
        settings.theme = ThemeChoice(single: name)
        save()
    }

    /// Every choice in menu order: Nubb's default, your themes, then the
    /// bundled ones.
    var themeOrder: [String?] {
        [nil] + userThemes.map(\.name) + bundledThemes.map(\.name)
    }

    /// Moves to the next or previous theme in menu order.
    func step(by offset: Int) {
        let order = themeOrder
        let current = order.firstIndex { $0 == selectedName } ?? 0
        let next = min(max(current + offset, 0), order.count - 1)
        guard next != current else { return }
        select(order[next])
    }

    // MARK: Colors

    /// Sets one color. Your own theme saves it directly. Anything else is
    /// first copied to a new theme of yours, which you keep editing.
    func setColor(_ slot: ColorSlot, _ color: ThemeRGB) {
        guard previewColors[slot] != color else { return }
        var colors = currentColors
        colors.set(slot, color)
        settings.overrides = ThemeColors()

        if let theme = editableTheme {
            updateTheme(theme, colors: colors)
            return
        }

        let name = ThemeFile.suggestedName(basedOn: selectedName, existing: existingNames)
        do {
            try createTheme(named: name, colors: colors)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateTheme(_ theme: ThemeEntry, colors: ThemeColors) {
        let updated = ThemeEntry(name: theme.name, location: theme.location, url: theme.url, colors: colors)
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            themes[index] = updated
        }
        dirtyTheme = updated
        save(delay: 0.15)
    }

    // MARK: Creating and managing themes

    var existingNames: Set<String> { Set(themes.map(\.name)) }

    func beginCreate() {
        let name = ThemeFile.suggestedName(basedOn: selectedName, existing: existingNames)
        namePrompt = NamePrompt(kind: .create, name: name)
    }

    func beginRename() {
        guard let theme = editableTheme else { return }
        namePrompt = NamePrompt(kind: .rename(theme.name), name: theme.name)
    }

    /// Problems with the prompt's name, or nil if it's fine.
    func nameProblem(_ prompt: NamePrompt) -> String? {
        var existing = existingNames
        if case .rename(let old) = prompt.kind { existing.remove(old) }
        if case .failure(let error) = ThemeFile.validate(name: prompt.name, existing: existing) {
            return error.localizedDescription
        }
        return nil
    }

    func commit(_ prompt: NamePrompt) {
        var existing = existingNames
        if case .rename(let old) = prompt.kind { existing.remove(old) }
        guard case .success(let name) = ThemeFile.validate(name: prompt.name, existing: existing) else { return }

        do {
            switch prompt.kind {
            case .create: try createTheme(named: name, colors: currentColors)
            case .rename(let old): try renameTheme(old, to: name)
            }
            namePrompt = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Writes `colors` as a new theme in your themes folder and switches to it.
    private func createTheme(named name: String, colors: ThemeColors) throws {
        try writeDirtyTheme()
        try FileManager.default.createDirectory(at: userThemesURL, withIntermediateDirectories: true)
        let url = userThemesURL.appendingPathComponent(name)
        try ThemeFile.text(for: colors).write(to: url, atomically: true, encoding: .utf8)
        reloadThemes()
        settings.overrides = ThemeColors()
        settings.theme = ThemeChoice(single: name)
        save()
    }

    private func renameTheme(_ old: String, to new: String) throws {
        guard old != new, let theme = themes.first(where: { $0.name == old && $0.location == .user }) else { return }
        try writeDirtyTheme()
        let url = theme.url.deletingLastPathComponent().appendingPathComponent(new)
        try FileManager.default.moveItem(at: theme.url, to: url)
        reloadThemes()
        replaceReferences(to: old, with: new)
        save()
    }

    /// Moves the selected user theme to the Trash.
    func trashSelectedTheme() {
        guard let theme = editableTheme else { return }
        do {
            if dirtyTheme?.name == theme.name { dirtyTheme = nil }
            try trash(theme.url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        reloadThemes()

        // A bundled theme with the same name takes over. Otherwise fall
        // back to Nubb's default colors.
        if !existingNames.contains(theme.name) {
            replaceReferences(to: theme.name, with: nil)
        }
        save()
    }

    private func replaceReferences(to old: String, with new: String?) {
        var theme = settings.theme
        if theme.light == old { theme.light = new }
        if theme.dark == old { theme.dark = new }
        if theme.light == nil { theme.light = theme.dark }
        if theme.dark == nil { theme.dark = theme.light }
        settings.theme = theme
    }

    /// Opens the user themes folder in Finder, creating it first.
    func openUserThemesFolder() {
        try? FileManager.default.createDirectory(at: userThemesURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userThemesURL)
    }

    // MARK: Saving

    /// Writes `appearance.nubb` and any edited theme, makes sure the main
    /// config includes the appearance file, and reloads. Arrow keys and the
    /// color panel can fire many changes in a row, so this waits a moment
    /// and only writes the latest state.
    func save(delay: Double = 0.06) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Writes everything and reloads right away.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try write()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        reload()
    }

    private func writeDirtyTheme() throws {
        guard let theme = dirtyTheme else { return }
        try ThemeFile.text(for: theme.colors).write(to: theme.url, atomically: true, encoding: .utf8)
        dirtyTheme = nil
    }

    private func write() throws {
        try writeDirtyTheme()

        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try settings.serialized().write(to: appearanceURL, atomically: true, encoding: .utf8)

        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard !AppearanceInclude.isPresent(in: config) else { return }
        let updated = config + AppearanceInclude.appendText(after: config)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
