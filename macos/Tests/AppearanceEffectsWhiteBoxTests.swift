import Foundation
import Testing
@testable import Nubb

private let whiteBoxHeader = "# Written by the Nubb Appearance window. It replaces this file on each change.\n\n"

private let whiteBoxAnimated = "void mainImage(out vec4 c, in vec2 p) { c = vec4(sin(iTime)); }"
private let whiteBoxStill = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"

/// A unique temporary folder, removed on deinit.
private final class WhiteBoxTempDir {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-effects-whitebox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to folder: URL, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

// MARK: - EffectCatalog internals

struct EffectCatalogWhiteBoxTests {
    @Test func symlinkedFileIsListedUnderTheLinkPath() throws {
        let tmp = try WhiteBoxTempDir()
        let user = try tmp.folder("user")
        let elsewhere = try tmp.folder("elsewhere")
        try tmp.write(whiteBoxAnimated, to: elsewhere, "real.txt")
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("Linked.glsl"),
            withDestinationURL: elsewhere.appendingPathComponent("real.txt"))
        try tmp.write(whiteBoxStill, to: user, "real.glsl")
        try FileManager.default.createSymbolicLink(
            atPath: user.appendingPathComponent("Relative.glsl").path,
            withDestinationPath: "real.glsl")

        let effects = EffectCatalog.load(user: user, bundled: nil)
        #expect(effects.map(\.name) == ["Linked", "real", "Relative"])
        let linked = try #require(effects.first { $0.name == "Linked" })
        #expect(linked.url.path == user.appendingPathComponent("Linked.glsl").path)
        #expect(linked.animates == true)
        let relative = try #require(effects.first { $0.name == "Relative" })
        #expect(relative.url.path == user.appendingPathComponent("Relative.glsl").path)
        #expect(relative.animates == false)
    }

    @Test func symlinkToFolderAndDanglingSymlinkAreSkipped() throws {
        let tmp = try WhiteBoxTempDir()
        let user = try tmp.folder("user")
        let target = try tmp.folder("target-dir")
        try tmp.write(whiteBoxStill, to: target, "inside.glsl")
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("Folder.glsl"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("Dangling.glsl"),
            withDestinationURL: tmp.root.appendingPathComponent("missing.glsl"))
        try tmp.write(whiteBoxStill, to: user, "Kept.glsl")

        #expect(EffectCatalog.load(user: user, bundled: nil).map(\.name) == ["Kept"])
    }

    @Test func oddFileNamesAndMultipleDots() throws {
        let tmp = try WhiteBoxTempDir()
        let user = try tmp.folder("user")
        try tmp.write("x", to: user, ".glsl")
        try tmp.write("x", to: user, "glsl")
        try tmp.write("x", to: user, "a.b.glsl")
        try tmp.write("x", to: user, "y.txt.glsl")
        try tmp.write("x", to: user, "x.glsl.txt")

        let effects = EffectCatalog.load(user: user, bundled: nil)
        #expect(effects.map(\.name) == ["a.b", "y.txt"])
        let ab = try #require(effects.first { $0.name == "a.b" })
        #expect(ab.url.path == user.appendingPathComponent("a.b.glsl").path)
    }

    @Test func uppercaseUserExtensionHidesBundledLowercase() throws {
        let tmp = try WhiteBoxTempDir()
        let user = try tmp.folder("user")
        let bundled = try tmp.folder("bundled")
        try tmp.write(whiteBoxAnimated, to: user, "CRT.GLSL")
        try tmp.write(whiteBoxStill, to: bundled, "CRT.glsl")

        let effects = EffectCatalog.load(user: user, bundled: bundled)
        #expect(effects.count == 1)
        let crt = try #require(effects.first)
        #expect(crt.name == "CRT")
        #expect(crt.location == .user)
        #expect(crt.url.path == user.appendingPathComponent("CRT.GLSL").path)
        #expect(crt.animates == true)
    }
}

// MARK: - AppearanceSettings internals

struct AppearanceEffectSettingsWhiteBoxTests {
    @Test func oddAnimationValues() {
        // The line is trimmed, and quotes are stripped like any value.
        #expect(AppearanceSettings(parsing: "custom-shader-animation =   false   \n").effectAnimates == false)
        #expect(AppearanceSettings(parsing: "custom-shader-animation = \"false\"\n").effectAnimates == false)
        #expect(AppearanceSettings(parsing: "custom-shader-animation=false\n").effectAnimates == false)
        // Only the exact lowercase word turns animation off.
        #expect(AppearanceSettings(parsing: "custom-shader-animation = FALSE\n").effectAnimates == true)
        #expect(AppearanceSettings(parsing: "custom-shader-animation = False\n").effectAnimates == true)
        #expect(AppearanceSettings(parsing: "custom-shader-animation = 0\n").effectAnimates == true)
        // An empty value resets to the default, which animates.
        #expect(AppearanceSettings(parsing: """
            custom-shader-animation = false
            custom-shader-animation =
            """).effectAnimates == true)
    }

    @Test func invalidAnimationValueKeepsEarlierValue() {
        // The Zig loader rejects `FALSE` (enum parsing is case sensitive)
        // and keeps the earlier `false`, so terminals don't animate.
        let settings = AppearanceSettings(parsing: """
            custom-shader-animation = false
            custom-shader-animation = FALSE
            """)
        #expect(settings.effectAnimates == false)
    }

    @Test func emptyQuotedShaderClears() {
        let settings = AppearanceSettings(parsing: """
            custom-shader = /a/First.glsl
            custom-shader = ""
            """)
        #expect(settings.effect == nil)
    }

    @Test func pathWithEqualsAndHashRoundTrips() {
        var settings = AppearanceSettings()
        settings.effect = "/a = b/#c/x.glsl"
        let text = settings.serialized()
        #expect(text == whiteBoxHeader + "custom-shader =\ncustom-shader = /a = b/#c/x.glsl\n")
        let parsed = AppearanceSettings(parsing: text)
        #expect(parsed.effect == "/a = b/#c/x.glsl")
        #expect(parsed.overrides.isEmpty)
        #expect(parsed == settings)
    }

    @Test func optionalAndTildePathsSerializeVerbatim() {
        let optional = AppearanceSettings(parsing: "custom-shader = ?/x/CRT.glsl\n")
        #expect(optional.effect == "?/x/CRT.glsl")
        #expect(optional.serialized() == whiteBoxHeader + "custom-shader =\ncustom-shader = ?/x/CRT.glsl\n")

        let tilde = AppearanceSettings(parsing: "custom-shader = \"~/shaders/My Glow.glsl\"\n")
        #expect(tilde.effect == "~/shaders/My Glow.glsl")
        #expect(tilde.serialized() == whiteBoxHeader + "custom-shader =\ncustom-shader = ~/shaders/My Glow.glsl\n")
        #expect(AppearanceSettings(parsing: tilde.serialized()) == tilde)
    }

    @Test func legacyColorLinesInterleavedWithShaderLines() {
        let settings = AppearanceSettings(parsing: """
            background = #112233
            custom-shader = /x/a.glsl
            palette = 1=#ff0000
            custom-shader-animation = false
            foreground = #abcdef
            """)
        #expect(settings.effect == "/x/a.glsl")
        #expect(settings.effectAnimates == false)
        #expect(settings.overrides.values == [
            .background: ThemeRGB(r: 0x11, g: 0x22, b: 0x33),
            .foreground: ThemeRGB(r: 0xAB, g: 0xCD, b: 0xEF),
        ])
        #expect(settings.overrides.palette == [1: ThemeRGB(r: 0xFF, g: 0, b: 0)])
        #expect(settings.serialized() == whiteBoxHeader
            + "custom-shader =\n"
            + "custom-shader = /x/a.glsl\n"
            + "custom-shader-animation = false\n"
            + "background = #112233\n"
            + "foreground = #abcdef\n"
            + "palette = 1=#ff0000\n")
    }

    @Test func newlineInEffectPathCannotInjectLines() {
        // macOS file names may contain newlines, and the config format can't
        // hold one, so such a path is never written.
        var settings = AppearanceSettings()
        settings.effect = "/x/a\ntheme = Evil.glsl"
        #expect(settings.serialized() == whiteBoxHeader)
        let parsed = AppearanceSettings(parsing: settings.serialized())
        #expect(parsed.theme == .none)
        #expect(parsed.effect == nil)
    }
}

// MARK: - AppearanceModel internals

@MainActor
struct AppearanceEffectModelWhiteBoxTests {
    private final class Sandbox {
        let root: URL
        let config: URL
        let userThemes: URL
        let bundledThemes: URL
        let userEffects: URL
        let bundledEffects: URL
        var reloads = 0

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-effects-whitebox-model-\(UUID().uuidString)", isDirectory: true)
            config = root.appendingPathComponent("config/config.nubb")
            userThemes = root.appendingPathComponent("themes", isDirectory: true)
            bundledThemes = root.appendingPathComponent("bundled-themes", isDirectory: true)
            userEffects = root.appendingPathComponent("shaders", isDirectory: true)
            bundledEffects = root.appendingPathComponent("bundled-shaders", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: bundledThemes, withIntermediateDirectories: true)
            try fm.createDirectory(at: userEffects, withIntermediateDirectories: true)
            try fm.createDirectory(at: bundledEffects, withIntermediateDirectories: true)
            try "font-size = 13".write(to: config, atomically: true, encoding: .utf8)
            try "background = #000000\n"
                .write(to: bundledThemes.appendingPathComponent("Sample"), atomically: true, encoding: .utf8)
            try whiteBoxStill
                .write(to: bundledEffects.appendingPathComponent("CRT.glsl"), atomically: true, encoding: .utf8)
            try whiteBoxAnimated
                .write(to: userEffects.appendingPathComponent("Pulse.glsl"), atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func model(userEffectsURL: URL? = nil) -> AppearanceModel {
            AppearanceModel(
                configURL: config,
                userThemesURL: userThemes,
                bundledThemesURL: bundledThemes,
                userEffectsURL: userEffectsURL ?? userEffects,
                bundledEffectsURL: bundledEffects,
                trash: { try FileManager.default.removeItem(at: $0) },
                reload: { [weak self] in self?.reloads += 1 }
            )
        }

        var appearanceURL: URL { config.deletingLastPathComponent().appendingPathComponent("appearance.nubb") }
        var appearance: String { (try? String(contentsOf: appearanceURL, encoding: .utf8)) ?? "" }
        func writeAppearance(_ text: String) throws {
            try text.write(to: appearanceURL, atomically: true, encoding: .utf8)
        }

        var crtPath: String { bundledEffects.appendingPathComponent("CRT.glsl").path }
        var pulsePath: String { userEffects.appendingPathComponent("Pulse.glsl").path }
    }

    @Test func folderURLWithOrWithoutTrailingSlashMatchesStoredPath() throws {
        let box = try Sandbox()
        try box.writeAppearance("custom-shader =\ncustom-shader = \(box.pulsePath)\n")

        let slashed = URL(fileURLWithPath: box.userEffects.path + "/", isDirectory: true)
        let bare = URL(fileURLWithPath: box.userEffects.path, isDirectory: false)
        for folder in [slashed, bare] {
            let model = box.model(userEffectsURL: folder)
            #expect(model.selectedEffect?.name == "Pulse")
            #expect(model.selectedEffect?.url.path == box.pulsePath)
            let before = model.settings
            model.selectEffect("Pulse")
            #expect(model.settings == before)
        }
    }

    @Test func handWrittenPathsShowAsUnlistedButAreKept() throws {
        // The window writes absolute paths. Paths written by hand with `?`,
        // relative to the config, or through a symlinked folder may name a
        // listed file, but they show as an unlisted file and are kept as is.
        let box = try Sandbox()
        let link = box.root.appendingPathComponent("linked-shaders")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.userEffects)
        for path in ["?" + box.pulsePath, "../shaders/Pulse.glsl", link.path + "/Pulse.glsl"] {
            try box.writeAppearance("custom-shader =\ncustom-shader = \(path)\n")
            let model = box.model()
            #expect(model.settings.effect == path)
            #expect(model.selectedEffect == nil)
        }
    }

    @Test func newlineInFileNameIsNotListed() throws {
        let box = try Sandbox()
        try whiteBoxStill.write(
            to: box.userEffects.appendingPathComponent("Two\nLines.glsl"), atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.effects.map(\.name) == ["CRT", "Pulse"])
    }

    @Test func optionalAndTildePathsSurviveThemeSaveUnchanged() throws {
        let box = try Sandbox()
        for path in ["?/nowhere/CRT.glsl", "~/nubb-whitebox-\(UUID().uuidString)/x.glsl"] {
            try box.writeAppearance("custom-shader =\ncustom-shader = \(path)\ncustom-shader-animation = false\n")
            let model = box.model()
            #expect(model.selectedEffect == nil)
            model.select("Sample")
            model.saveNow()
            #expect(model.settings.effect == path)
            #expect(model.settings.effectAnimates == false)
            #expect(box.appearance == whiteBoxHeader
                + "theme = Sample\n"
                + "custom-shader =\n"
                + "custom-shader = \(path)\n"
                + "custom-shader-animation = false\n")
        }
    }

    @Test func deletedEffectKeepsPathAfterRefreshAndCanBeCleared() throws {
        let box = try Sandbox()
        let model = box.model()
        model.selectEffect("Pulse")
        model.saveNow()
        try FileManager.default.removeItem(atPath: box.pulsePath)
        model.refresh()

        #expect(model.effects.map(\.name) == ["CRT"])
        #expect(model.selectedEffect == nil)
        #expect(model.settings.effect == box.pulsePath)
        #expect(model.settings.effectAnimates == true)

        let reloads = box.reloads
        model.selectEffect(nil)
        #expect(model.settings.effect == nil)
        model.saveNow()
        #expect(box.reloads == reloads + 1)
        #expect(box.appearance == whiteBoxHeader)
    }

    @Test func effectsDifferingOnlyByCaseAreSelectedExactly() throws {
        let box = try Sandbox()
        try whiteBoxStill
            .write(to: box.bundledEffects.appendingPathComponent("Glow.glsl"), atomically: true, encoding: .utf8)
        try whiteBoxAnimated
            .write(to: box.userEffects.appendingPathComponent("glow.glsl"), atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(Set(model.effects.map(\.name)) == ["CRT", "Glow", "glow", "Pulse"])

        model.selectEffect("glow")
        #expect(model.settings.effect == box.userEffects.appendingPathComponent("glow.glsl").path)
        #expect(model.settings.effectAnimates == true)
        #expect(model.selectedEffect?.location == .user)

        model.selectEffect("Glow")
        #expect(model.settings.effect == box.bundledEffects.appendingPathComponent("Glow.glsl").path)
        #expect(model.settings.effectAnimates == false)
        #expect(model.selectedEffect?.location == .bundled)
        #expect(model.selectedEffect?.name == "Glow")
    }

    @Test func storedBundledPathHiddenByUserEffectIsNotSelected() throws {
        let box = try Sandbox()
        try box.writeAppearance("custom-shader =\ncustom-shader = \(box.crtPath)\ncustom-shader-animation = false\n")
        try whiteBoxAnimated
            .write(to: box.userEffects.appendingPathComponent("CRT.glsl"), atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.selectedEffect == nil)
        #expect(model.settings.effect == box.crtPath)

        model.selectEffect("CRT")
        #expect(model.settings.effect == box.userEffects.appendingPathComponent("CRT.glsl").path)
        #expect(model.settings.effectAnimates == true)
        #expect(model.selectedEffect?.location == .user)
    }

    @Test func settingColorFoldsLegacyOverridesButKeepsEffect() throws {
        let box = try Sandbox()
        try box.writeAppearance("""
            custom-shader =
            custom-shader = \(box.crtPath)
            custom-shader-animation = false
            background = #112233

            """)
        let model = box.model()
        #expect(model.settings.overrides.values[.background] == ThemeRGB(r: 0x11, g: 0x22, b: 0x33))

        model.setColor(.key(.foreground), ThemeRGB(r: 1, g: 2, b: 3))
        model.saveNow()
        let name = try #require(model.selectedName)
        #expect(model.settings.overrides.isEmpty)
        #expect(model.settings.effect == box.crtPath)
        #expect(model.settings.effectAnimates == false)
        #expect(model.selectedEffect?.name == "CRT")
        #expect(box.appearance == whiteBoxHeader
            + "theme = \(name)\n"
            + "custom-shader =\n"
            + "custom-shader = \(box.crtPath)\n"
            + "custom-shader-animation = false\n")
        let themeText = try String(contentsOf: box.userThemes.appendingPathComponent(name), encoding: .utf8)
        #expect(themeText.contains("background = #112233\n"))
        #expect(themeText.contains("foreground = #010203\n"))
    }

    @Test func reselectingEffectPicksUpNewAnimationFlag() throws {
        // The animation flag is decided when the effect is picked. If the
        // shader later starts using iTime, picking it again updates the flag.
        let box = try Sandbox()
        let model = box.model()
        model.selectEffect("CRT")
        model.saveNow()
        #expect(model.settings.effectAnimates == false)

        try whiteBoxAnimated.write(to: URL(fileURLWithPath: box.crtPath), atomically: true, encoding: .utf8)
        model.refresh()
        #expect(model.selectedEffect?.animates == true)
        #expect(model.settings.effectAnimates == false)

        model.selectEffect("CRT")
        #expect(model.settings.effectAnimates == true)
    }
}
