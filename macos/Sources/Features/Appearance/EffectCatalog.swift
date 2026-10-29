import Foundation

/// A shader file the Appearance menu can pick for `custom-shader`.
struct EffectEntry: Identifiable, Equatable {
    /// The file name without its extension, like "CRT".
    let name: String
    let location: ThemeEntry.Location
    let url: URL
    /// True when the shader reads the clock, so terminals have to redraw
    /// every frame to animate it.
    let animates: Bool

    var id: String { name }
}

/// Finds shader effects: GLSL files in the user's shaders folder and the
/// bundled set, which sit next to the themes folders.
enum EffectCatalog {
    /// `shaders` next to the user themes folder.
    static var userDirectory: URL {
        ThemeCatalog.userDirectory.deletingLastPathComponent()
            .appendingPathComponent("shaders", isDirectory: true)
    }

    /// `shaders` next to the bundled themes folder.
    static var bundledDirectory: URL? {
        ThemeCatalog.bundledDirectory?.deletingLastPathComponent()
            .appendingPathComponent("shaders", isDirectory: true)
    }

    /// Loads every effect, sorted by name. A user effect hides a bundled
    /// effect with the same name.
    static func load(
        user: URL = userDirectory,
        bundled: URL? = bundledDirectory
    ) -> [EffectEntry] {
        var byName: [String: EffectEntry] = [:]
        if let bundled {
            for entry in entries(in: bundled, location: .bundled) { byName[entry.name] = entry }
        }
        for entry in entries(in: user, location: .user) { byName[entry.name] = entry }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// True if the shader uses one of the clock inputs. Nubb only redraws
    /// every frame when a shader needs it, so still effects cost nothing
    /// while the terminal is idle.
    static func animates(_ source: String) -> Bool {
        ["iTime", "iFrame", "iDate"].contains { source.contains($0) }
    }

    private static func entries(in dir: URL, location: ThemeEntry.Location) -> [EffectEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }

        return names.compactMap { fileName in
            let url = dir.appendingPathComponent(fileName)
            guard !fileName.hasPrefix("."),
                  !fileName.contains(where: \.isNewline),
                  url.pathExtension.lowercased() == "glsl",
                  (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return EffectEntry(
                name: (fileName as NSString).deletingPathExtension,
                location: location,
                url: url,
                animates: animates(source)
            )
        }
    }
}
