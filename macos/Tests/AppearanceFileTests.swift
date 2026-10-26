import Foundation
import Testing
@testable import Nubb

struct AppearanceFileTests {
    @Test func parsesHexColors() {
        #expect(ThemeRGB(hex: "#1a2B3c") == ThemeRGB(r: 0x1A, g: 0x2B, b: 0x3C))
        #expect(ThemeRGB(hex: "1a2b3c") == ThemeRGB(r: 0x1A, g: 0x2B, b: 0x3C))
        #expect(ThemeRGB(hex: "#abc") == ThemeRGB(r: 0xAA, g: 0xBB, b: 0xCC))
        #expect(ThemeRGB(hex: "#12345") == nil)
        #expect(ThemeRGB(hex: "#zzzzzz") == nil)
        #expect(ThemeRGB(r: 0x1A, g: 0x2B, b: 0x3C).hex == "#1a2b3c")
    }

    @Test func parsesThemeFile() {
        let colors = ThemeColors(parsing: """
            # comment
            palette = 0=#21222c
            palette = 15 = #ffffff
            background = #282a36
            foreground = #f8f8f2
            cursor-color = #f8f8f2
            selection-background = #44475a
            font-size = 14
            palette = 300=#000000
            """)
        #expect(colors.palette[0] == ThemeRGB(hex: "#21222c"))
        #expect(colors.palette[15] == ThemeRGB(hex: "#ffffff"))
        #expect(colors.palette[300] == nil)
        #expect(colors.values[.background] == ThemeRGB(hex: "#282a36"))
        #expect(colors.values[.cursorColor] == ThemeRGB(hex: "#f8f8f2"))
        #expect(colors.values[.cursorText] == nil)
    }

    @Test func resolvesFallbacks() {
        var colors = ThemeColors()
        colors.values[.background] = ThemeRGB(hex: "#000000")
        colors.values[.foreground] = ThemeRGB(hex: "#eeeeee")
        let resolved = ResolvedColors(colors)
        #expect(resolved.cursor == ThemeRGB(hex: "#eeeeee"))
        #expect(resolved.cursorText == ThemeRGB(hex: "#000000"))
        #expect(resolved.selectionBackground == ThemeRGB(hex: "#eeeeee"))
        #expect(resolved.palette.count == 16)
        #expect(resolved.palette[1] == ThemeRGB(hex: "#cc6666"))
    }

    @Test func overridesWinOverTheme() {
        var theme = ThemeColors()
        theme.values[.background] = ThemeRGB(hex: "#111111")
        theme.palette[2] = ThemeRGB(hex: "#00ff00")
        var overrides = ThemeColors()
        overrides.values[.background] = ThemeRGB(hex: "#222222")
        let merged = theme.merged(with: overrides)
        #expect(merged.values[.background] == ThemeRGB(hex: "#222222"))
        #expect(merged.palette[2] == ThemeRGB(hex: "#00ff00"))
    }

    @Test func parsesThemeChoice() {
        #expect(ThemeChoice(configValue: "Nord") == ThemeChoice(single: "Nord"))
        #expect(ThemeChoice(configValue: "light:Rose Pine Dawn, dark:Rose Pine")
            == ThemeChoice(light: "Rose Pine Dawn", dark: "Rose Pine"))
        #expect(ThemeChoice(configValue: "dark:A,light:B") == ThemeChoice(light: "B", dark: "A"))
        #expect(ThemeChoice(configValue: "light:A") == nil)
        #expect(ThemeChoice(configValue: "") == nil)
    }

    @Test func writesThemeChoice() {
        #expect(ThemeChoice.none.configValue == nil)
        #expect(ThemeChoice(single: "Nord").configValue == "Nord")
        #expect(ThemeChoice(light: "A", dark: "B").configValue == "light:A,dark:B")
        #expect(ThemeChoice(light: "A", dark: "B").isPair)
        #expect(!ThemeChoice(single: "A").isPair)
    }

    @Test func settingsRoundTrip() {
        var settings = AppearanceSettings()
        settings.theme = ThemeChoice(light: "Catppuccin Latte", dark: "Catppuccin Mocha")
        settings.overrides.values[.cursorColor] = ThemeRGB(hex: "#ff9e64")
        settings.overrides.palette[1] = ThemeRGB(hex: "#f7768e")
        let text = settings.serialized()
        #expect(text.contains("theme = light:Catppuccin Latte,dark:Catppuccin Mocha\n"))
        #expect(text.contains("cursor-color = #ff9e64\n"))
        #expect(text.contains("palette = 1=#f7768e\n"))
        #expect(AppearanceSettings(parsing: text) == settings)
    }

    @Test func emptySettingsWriteNoTheme() {
        let text = AppearanceSettings().serialized()
        #expect(!text.contains("theme ="))
        #expect(AppearanceSettings(parsing: text) == AppearanceSettings())
    }

    @Test func detectsInclude() {
        #expect(AppearanceInclude.isPresent(in: "font-size = 13\nconfig-file = ?appearance.nubb\n"))
        #expect(AppearanceInclude.isPresent(in: "config-file = \"?/home/user/appearance.nubb\""))
        #expect(!AppearanceInclude.isPresent(in: "# config-file = ?appearance.nubb\n"))
        #expect(!AppearanceInclude.isPresent(in: "config-file = ?other.nubb\n"))
    }

    @Test func appendsIncludeOnItsOwnLine() {
        let noNewline = "font-size = 13"
        let appended = noNewline + AppearanceInclude.appendText(after: noNewline)
        #expect(appended.hasSuffix("\n\(AppearanceInclude.directive)\n"))
        #expect(appended.hasPrefix("font-size = 13\n"))
        #expect(AppearanceInclude.isPresent(in: appended))
        #expect(AppearanceInclude.isPresent(in: AppearanceInclude.appendText(after: "")))
    }

    @Test func catalogPrefersUserThemes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-theme-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try "background = #000000\n".write(to: bundled.appendingPathComponent("Nord"), atomically: true, encoding: .utf8)
        try "background = #ffffff\n".write(to: bundled.appendingPathComponent("Alpha"), atomically: true, encoding: .utf8)
        try "background = #111111\n".write(to: user.appendingPathComponent("Nord"), atomically: true, encoding: .utf8)
        try "notes".write(to: bundled.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let themes = ThemeCatalog.load(user: user, bundled: bundled)
        #expect(themes.map(\.name) == ["Alpha", "Nord"])
        #expect(themes[1].location == .user)
        #expect(themes[1].colors.values[.background] == ThemeRGB(hex: "#111111"))
    }

    @Test func themeFileSetsEveryColorAndRoundTrips() {
        var colors = ThemeColors()
        colors.values[.background] = ThemeRGB(hex: "#101820")
        colors.palette[4] = ThemeRGB(hex: "#3366ff")
        let text = ThemeFile.text(for: colors)
        #expect(text.split(separator: "\n").count == 22)
        #expect(text.contains("background = #101820\n"))
        #expect(text.contains("palette = 4=#3366ff\n"))
        let parsed = ThemeColors(parsing: text)
        #expect(ResolvedColors(parsed) == ResolvedColors(colors))
        #expect(parsed.values.count == ThemeColorKey.allCases.count)
    }

    @Test func validatesThemeNames() {
        let existing: Set<String> = ["Nord"]
        #expect(ThemeFile.validate(name: "  My Theme ", existing: existing) == .success("My Theme"))
        #expect(ThemeFile.validate(name: "", existing: existing) == .failure(.empty))
        #expect(ThemeFile.validate(name: "Nord", existing: existing) == .failure(.taken))
        for bad in ["a/b", "a:b", "a,b", "a=b", ".hidden", "a\\b"] {
            #expect(ThemeFile.validate(name: bad, existing: existing) == .failure(.invalidCharacter))
        }
    }

    @Test func suggestsUnusedNames() {
        #expect(ThemeFile.suggestedName(basedOn: "Nord", existing: []) == "Nord Custom")
        #expect(ThemeFile.suggestedName(basedOn: "Nord", existing: ["Nord Custom"]) == "Nord Custom 2")
        #expect(ThemeFile.suggestedName(basedOn: nil, existing: []) == "Nubb Custom")
    }

    @Test func colorListCoversEveryColorOnce() {
        let slots = ColorSlot.all
        #expect(slots.count == ThemeColorKey.allCases.count + 16)
        #expect(Set(slots).count == slots.count)
        for key in ThemeColorKey.allCases { #expect(slots.contains(.key(key))) }
        for index in 0..<16 { #expect(slots.contains(.palette(index))) }
        for slot in slots {
            #expect(!slot.name.isEmpty)
            #expect(!slot.usage.isEmpty)
            #expect(slot.name.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }

    @Test func previewUsesEveryColor() {
        let shown = Set(PreviewScript.lines.flatMap { $0.flatMap(\.slots) })
        for slot in ColorSlot.all where slot != .key(.background) {
            #expect(shown.contains(slot), "\(slot.name) isn't in the preview")
        }
    }

    @Test func setsOneSlot() {
        var colors = ThemeColors()
        colors.set(.palette(3), ThemeRGB(r: 1, g: 2, b: 3))
        colors.set(.key(.cursorText), ThemeRGB(r: 4, g: 5, b: 6))
        let resolved = ResolvedColors(colors)
        #expect(resolved[.palette(3)] == ThemeRGB(r: 1, g: 2, b: 3))
        #expect(resolved[.key(.cursorText)] == ThemeRGB(r: 4, g: 5, b: 6))
    }
}

/// Drives AppearanceModel against temporary folders.
@MainActor
struct AppearanceModelTests {
    private final class Sandbox {
        let root: URL
        let config: URL
        let user: URL
        let bundled: URL
        var reloads = 0

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-appearance-\(UUID().uuidString)", isDirectory: true)
            config = root.appendingPathComponent("config/config.nubb")
            user = root.appendingPathComponent("themes", isDirectory: true)
            bundled = root.appendingPathComponent("bundled", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
            try "font-size = 13".write(to: config, atomically: true, encoding: .utf8)
            try "background = #0e1019\nforeground = #fffaf4\npalette = 1=#ff000f\n"
                .write(to: bundled.appendingPathComponent("Sample"), atomically: true, encoding: .utf8)
            try "background = #000000\n"
                .write(to: bundled.appendingPathComponent("Second"), atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func model() -> AppearanceModel {
            AppearanceModel(
                configURL: config,
                userThemesURL: user,
                bundledThemesURL: bundled,
                trash: { try FileManager.default.removeItem(at: $0) },
                reload: { [weak self] in self?.reloads += 1 }
            )
        }

        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        var appearanceURL: URL { config.deletingLastPathComponent().appendingPathComponent("appearance.nubb") }

        var appearance: String { read(appearanceURL) }
    }

    @Test func selectingWritesAppearanceAndInclude() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")
        model.saveNow()
        #expect(box.appearance.contains("theme = Sample\n"))
        #expect(box.read(box.config).hasPrefix("font-size = 13\n"))
        #expect(AppearanceInclude.isPresent(in: box.read(box.config)))
        #expect(box.reloads == 1)

        // A second save doesn't add the include again.
        model.saveNow()
        #expect(box.read(box.config).components(separatedBy: AppearanceInclude.directive).count == 2)
    }

    @Test func editingBundledThemeSavesACopy() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")
        model.setColor(.key(.cursorColor), ThemeRGB(hex: "#ff9e64")!)
        model.saveNow()

        #expect(model.selectedName == "Sample Custom")
        #expect(model.editableTheme != nil)
        let file = box.read(box.user.appendingPathComponent("Sample Custom"))
        #expect(file.contains("background = #0e1019\n"))
        #expect(file.contains("cursor-color = #ff9e64\n"))
        #expect(file.contains("palette = 1=#ff000f\n"))
        #expect(box.appearance.contains("theme = Sample Custom\n"))
        #expect(!box.appearance.contains("cursor-color"))

        // The bundled file is untouched.
        #expect(!box.read(box.bundled.appendingPathComponent("Sample")).contains("cursor-color"))

        // Further edits go into the copy instead of making another one.
        model.setColor(.palette(2), ThemeRGB(hex: "#00ff00")!)
        model.saveNow()
        #expect(model.selectedName == "Sample Custom")
        #expect(model.userThemes.count == 1)
        #expect(box.read(box.user.appendingPathComponent("Sample Custom")).contains("palette = 2=#00ff00\n"))
    }

    @Test func editingDefaultColorsSavesACopy() throws {
        let box = try Sandbox()
        let model = box.model()
        model.setColor(.key(.background), ThemeRGB(hex: "#101010")!)
        model.saveNow()
        #expect(model.selectedName == "Nubb Custom")
        #expect(box.read(box.user.appendingPathComponent("Nubb Custom")).contains("background = #101010\n"))
    }

    @Test func settingTheSameColorDoesNothing() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")
        model.setColor(.key(.background), ThemeRGB(hex: "#0e1019")!)
        #expect(model.selectedName == "Sample")
        #expect(model.userThemes.isEmpty)
    }

    @Test func foldsOldOverridesIntoTheCopy() throws {
        let box = try Sandbox()
        try "theme = Sample\nforeground = #abcdef\n".write(to: box.appearanceURL, atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.previewColors.foreground == ThemeRGB(hex: "#abcdef"))

        model.setColor(.palette(4), ThemeRGB(hex: "#3366ff")!)
        model.saveNow()
        let file = box.read(box.user.appendingPathComponent("Sample Custom"))
        #expect(file.contains("foreground = #abcdef\n"))
        #expect(file.contains("palette = 4=#3366ff\n"))
        #expect(!box.appearance.contains("foreground"))
    }

    @Test func pickingAThemeReplacesALightDarkPair() throws {
        let box = try Sandbox()
        try "theme = light:Sample,dark:Second\n".write(to: box.appearanceURL, atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.hasLightDarkPair)
        #expect(model.selectedName == "Second")
        model.select("Second")
        model.saveNow()
        #expect(!model.hasLightDarkPair)
        #expect(box.appearance.contains("theme = Second\n"))
    }

    @Test func createsThemeFromCurrentColors() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")

        model.beginCreate()
        let prompt = try #require(model.namePrompt)
        #expect(prompt.name == "Sample Custom")
        model.commit(prompt)
        model.saveNow()

        #expect(model.namePrompt == nil)
        #expect(model.selectedName == "Sample Custom")
        #expect(model.editableTheme != nil)
        let file = box.read(box.user.appendingPathComponent("Sample Custom"))
        #expect(file.contains("background = #0e1019\n"))
        #expect(file.contains("palette = 1=#ff000f\n"))
        #expect(box.appearance.contains("theme = Sample Custom\n"))
    }

    @Test func editsSaveIntoUserTheme() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")
        model.beginCreate()
        model.commit(try #require(model.namePrompt))

        model.setColor(.key(.background), ThemeRGB(hex: "#000000")!)
        model.setColor(.palette(2), ThemeRGB(hex: "#00ff00")!)
        #expect(model.previewColors.background == ThemeRGB(hex: "#000000"))
        #expect(model.userThemes.count == 1)
        model.saveNow()

        let file = box.read(box.user.appendingPathComponent("Sample Custom"))
        #expect(file.contains("background = #000000\n"))
        #expect(file.contains("palette = 2=#00ff00\n"))
        #expect(!box.appearance.contains("background"))
    }

    @Test func renamesAndTrashesUserTheme() throws {
        let box = try Sandbox()
        let model = box.model()
        model.select("Sample")
        model.beginCreate()
        model.commit(try #require(model.namePrompt))

        model.beginRename()
        var prompt = try #require(model.namePrompt)
        prompt.name = "Sample"
        #expect(model.nameProblem(prompt) == "A theme with this name already exists.")
        prompt.name = "Renamed"
        #expect(model.nameProblem(prompt) == nil)
        model.commit(prompt)
        model.saveNow()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: box.user.appendingPathComponent("Renamed").path))
        #expect(!fm.fileExists(atPath: box.user.appendingPathComponent("Sample Custom").path))
        #expect(model.selectedName == "Renamed")
        #expect(box.appearance.contains("theme = Renamed\n"))

        model.trashSelectedTheme()
        model.saveNow()
        #expect(!fm.fileExists(atPath: box.user.appendingPathComponent("Renamed").path))
        #expect(model.selectedName == nil)
        #expect(!box.appearance.contains("theme ="))
    }
}
