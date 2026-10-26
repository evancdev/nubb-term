import Foundation

/// A theme file from the user's themes folder or the bundled set.
struct ThemeEntry: Identifiable, Equatable {
    enum Location: String {
        case user
        case bundled
    }

    let name: String
    let location: Location
    let url: URL
    let colors: ThemeColors

    var id: String { name }
}

/// Finds and parses theme files the same way Nubb's config loader does:
/// the user folder first, then the bundled themes.
enum ThemeCatalog {
    /// `$XDG_CONFIG_HOME/nubb/themes`, or `~/.config/nubb/themes`.
    static var userDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("nubb/themes", isDirectory: true)
    }

    /// The themes folder inside the app bundle, or under `NUBB_RESOURCES_DIR`.
    static var bundledDirectory: URL? {
        if let dir = ProcessInfo.processInfo.environment["NUBB_RESOURCES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("themes", isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("nubb/themes", isDirectory: true)
    }

    /// Loads every theme, sorted by name. A user theme hides a bundled theme
    /// with the same name, matching how Nubb resolves `theme`.
    static func load(
        user: URL = userDirectory,
        bundled: URL? = bundledDirectory
    ) -> [ThemeEntry] {
        var byName: [String: ThemeEntry] = [:]
        if let bundled {
            for entry in entries(in: bundled, location: .bundled) { byName[entry.name] = entry }
        }
        for entry in entries(in: user, location: .user) { byName[entry.name] = entry }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func entries(in dir: URL, location: ThemeEntry.Location) -> [ThemeEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension != "md",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ThemeEntry(
                name: url.lastPathComponent,
                location: location,
                url: url,
                colors: ThemeColors(parsing: text)
            )
        }
    }
}
