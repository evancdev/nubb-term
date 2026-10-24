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

    enum Brightness: String, CaseIterable, Identifiable {
        case all
        case dark
        case light

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .dark: "Dark"
            case .light: "Light"
            }
        }
    }

    @Published private(set) var themes: [ThemeEntry] = []
    @Published private(set) var settings = AppearanceSettings()
    @Published var mode: Mode = .single
    @Published var slot: Slot = .dark
    @Published var search = ""
    @Published var brightness: Brightness = .all
    @Published private(set) var lastError: String?

    /// The main config file. The model adds one include line to it.
    let configURL: URL

    /// The file this window owns, next to the main config.
    var appearanceURL: URL {
        configURL.deletingLastPathComponent().appendingPathComponent(AppearanceInclude.fileName)
    }

    private let reload: () -> Void
    private var pendingSave: Task<Void, Never>?

    init(configURL: URL, reload: @escaping () -> Void) {
        self.configURL = configURL
        self.reload = reload
        refresh()
    }

    /// Re-reads the theme folders and the appearance file.
    func refresh() {
        themes = ThemeCatalog.load()
        if let text = try? String(contentsOf: appearanceURL, encoding: .utf8) {
            settings = AppearanceSettings(parsing: text)
        } else {
            settings = AppearanceSettings()
        }
        mode = settings.theme.isPair ? .pair : .single
    }

    var filteredThemes: [ThemeEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return themes.filter { theme in
            switch brightness {
            case .all: break
            case .dark: if !theme.isDark { return false }
            case .light: if theme.isDark { return false }
            }
            return query.isEmpty || theme.name.localizedCaseInsensitiveContains(query)
        }
    }

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

    func isOverridden(_ key: ThemeColorKey) -> Bool {
        settings.overrides.values[key] != nil
    }

    func isOverridden(palette index: Int) -> Bool {
        settings.overrides.palette[index] != nil
    }

    func setOverride(_ key: ThemeColorKey, _ color: ThemeRGB?) {
        // Picking the theme's own color is the same as no override.
        let themeColor = ResolvedColors(previewTheme?.colors ?? ThemeColors()).value(for: key)
        let new = color == themeColor ? nil : color
        guard settings.overrides.values[key] != new else { return }
        settings.overrides.values[key] = new
        save(delay: 0.15)
    }

    func setOverride(palette index: Int, _ color: ThemeRGB?) {
        let themeColor = ResolvedColors(previewTheme?.colors ?? ThemeColors()).palette[index]
        let new = color == themeColor ? nil : color
        guard settings.overrides.palette[index] != new else { return }
        settings.overrides.palette[index] = new
        save(delay: 0.15)
    }

    func clearOverrides() {
        settings.overrides = ThemeColors()
        save()
    }

    var hasOverrides: Bool { !settings.overrides.isEmpty }

    /// Opens the user themes folder in Finder, creating it first.
    func openUserThemesFolder() {
        let dir = ThemeCatalog.userDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Shows `appearance.nubb` in Finder, or its folder if it doesn't exist yet.
    func revealAppearanceFile() {
        if FileManager.default.fileExists(atPath: appearanceURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([appearanceURL])
        } else {
            NSWorkspace.shared.open(configURL.deletingLastPathComponent())
        }
    }

    /// Writes `appearance.nubb`, makes sure the main config includes it,
    /// and reloads. The list and the color wells can fire many changes in
    /// a row (arrow keys, dragging in the color panel), so this waits a
    /// moment and only writes the latest state.
    func save(delay: Double = 0.06) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                try write()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                return
            }
            reload()
        }
    }

    private func write() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try settings.serialized().write(to: appearanceURL, atomically: true, encoding: .utf8)

        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard !AppearanceInclude.isPresent(in: config) else { return }
        let updated = config + AppearanceInclude.appendText(after: config)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
