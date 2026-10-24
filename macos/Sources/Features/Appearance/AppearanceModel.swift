import AppKit
import Combine

/// State for the Appearance window. Every change writes `appearance.nubb`
/// and reloads the config, so open terminals update while you pick.
@MainActor
final class AppearanceModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case single
        case pair

        var id: String { rawValue }
    }

    enum Slot: String, CaseIterable, Identifiable {
        case light
        case dark

        var id: String { rawValue }
    }

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
    @Published var mode: Mode = .single
    @Published var slot: Slot = .dark
    @Published var search = ""
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
        mode = settings.theme.isPair ? .pair : .single
    }

    private func reloadThemes() {
        themes = ThemeCatalog.load(user: userThemesURL, bundled: bundledThemesURL)
    }

    // MARK: Theme list

    private func matches(_ theme: ThemeEntry) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || theme.name.localizedCaseInsensitiveContains(query)
    }

    var userThemes: [ThemeEntry] { themes.filter { $0.location == .user && matches($0) } }
    var bundledThemes: [ThemeEntry] { themes.filter { $0.location == .bundled && matches($0) } }

    /// The theme name the list highlights.
    var selectedName: String? {
        switch mode {
        case .single: settings.theme.dark ?? settings.theme.light
        case .pair: slot == .light ? settings.theme.light : settings.theme.dark
        }
    }

    /// The theme that the preview and the color wells show.
    var previewTheme: ThemeEntry? {
        guard let name = selectedName else { return nil }
        return themes.first { $0.name == name }
    }

    /// The selected theme if it's one of yours, so color changes save into it.
    var editableTheme: ThemeEntry? {
        guard let theme = previewTheme, theme.location == .user else { return nil }
        return theme
    }

    /// What the terminal shows for the previewed theme plus the overrides.
    var previewColors: ResolvedColors {
        let base = previewTheme?.colors ?? ThemeColors()
        return ResolvedColors(base.merged(with: settings.overrides))
    }

    func select(_ name: String?) {
        var theme = settings.theme
        switch mode {
        case .single:
            theme = ThemeChoice(single: name)
        case .pair:
            if slot == .light {
                theme.light = name
                if theme.dark == nil { theme.dark = name }
            } else {
                theme.dark = name
                if theme.light == nil { theme.light = name }
            }
        }
        settings.theme = theme
        save()
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode == .single {
            let keep = settings.theme.dark ?? settings.theme.light
            settings.theme = ThemeChoice(single: keep)
            save()
        }
    }

    // MARK: Colors

    func isOverridden(_ key: ThemeColorKey) -> Bool {
        settings.overrides.values[key] != nil
    }

    func isOverridden(palette index: Int) -> Bool {
        settings.overrides.palette[index] != nil
    }

    /// Sets a color. For your own theme this edits the theme. For a bundled
    /// theme it's an override on top. Nil removes the override.
    func setColor(_ key: ThemeColorKey, _ color: ThemeRGB?) {
        if let color, let theme = editableTheme {
            let hadOverride = settings.overrides.values[key] != nil
            var colors = theme.colors
            colors.values[key] = color
            settings.overrides.values[key] = nil
            guard colors != theme.colors || hadOverride else { return }
            updateTheme(theme, colors: colors)
            return
        }

        // Picking the theme's own color is the same as no override.
        let themeColor = ResolvedColors(previewTheme?.colors ?? ThemeColors()).value(for: key)
        let new = color == themeColor ? nil : color
        guard settings.overrides.values[key] != new else { return }
        settings.overrides.values[key] = new
        save(delay: 0.15)
    }

    func setColor(palette index: Int, _ color: ThemeRGB?) {
        if let color, let theme = editableTheme {
            let hadOverride = settings.overrides.palette[index] != nil
            var colors = theme.colors
            colors.palette[index] = color
            settings.overrides.palette[index] = nil
            guard colors != theme.colors || hadOverride else { return }
            updateTheme(theme, colors: colors)
            return
        }

        let themeColor = ResolvedColors(previewTheme?.colors ?? ThemeColors()).palette[index]
        let new = color == themeColor ? nil : color
        guard settings.overrides.palette[index] != new else { return }
        settings.overrides.palette[index] = new
        save(delay: 0.15)
    }

    private func updateTheme(_ theme: ThemeEntry, colors: ThemeColors) {
        let updated = ThemeEntry(name: theme.name, location: theme.location, url: theme.url, colors: colors)
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            themes[index] = updated
        }
        dirtyTheme = updated
        save(delay: 0.15)
    }

    func clearOverrides() {
        settings.overrides = ThemeColors()
        save()
    }

    var hasOverrides: Bool { !settings.overrides.isEmpty }

    // MARK: Creating and managing themes

    var existingNames: Set<String> { Set(themes.map(\.name)) }

    func beginCreate() {
        let name = ThemeFile.suggestedName(basedOn: previewTheme?.name, existing: existingNames)
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
            case .create: try createTheme(named: name)
            case .rename(let old): try renameTheme(old, to: name)
            }
            namePrompt = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves the current colors (theme plus your changes) as a new theme in
    /// your themes folder and switches to it.
    private func createTheme(named name: String) throws {
        let colors = (previewTheme?.colors ?? ThemeColors()).merged(with: settings.overrides)
        try writeDirtyTheme()
        try FileManager.default.createDirectory(at: userThemesURL, withIntermediateDirectories: true)
        let url = userThemesURL.appendingPathComponent(name)
        try ThemeFile.text(for: colors).write(to: url, atomically: true, encoding: .utf8)
        reloadThemes()
        settings.overrides = ThemeColors()
        select(name)
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

    // MARK: Finder

    /// Opens the user themes folder in Finder, creating it first.
    func openUserThemesFolder() {
        try? FileManager.default.createDirectory(at: userThemesURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userThemesURL)
    }

    /// Shows `appearance.nubb` in Finder, or its folder if it doesn't exist yet.
    func revealAppearanceFile() {
        if FileManager.default.fileExists(atPath: appearanceURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([appearanceURL])
        } else {
            NSWorkspace.shared.open(configURL.deletingLastPathComponent())
        }
    }

    // MARK: Saving

    /// Writes `appearance.nubb` and any edited theme, makes sure the main
    /// config includes the appearance file, and reloads. The list and the
    /// color wells can fire many changes in a row (arrow keys, dragging in
    /// the color panel), so this waits a moment and only writes the latest
    /// state.
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
