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
        #expect(AppearanceInclude.isPresent(in: "config-file = \"?/Users/x/appearance.nubb\""))
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
        #expect(!themes[0].isDark)
        #expect(themes[1].isDark)
    }
}
