import Foundation
import Testing
@testable import Nubb

private let effectsHeader = "# Written by the Nubb Appearance window. It replaces this file on each change.\n\n"

/// A unique temporary folder tree, removed on deinit.
private final class EffectsTempDir {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-effects-tests-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - EffectCatalog

struct EffectCatalogTests {
    @Test func listsOnlyVisibleGLSLFilesCaseInsensitively() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        try tmp.write("void main() {}", to: user, "CRT.glsl")
        try tmp.write("void main() {}", to: user, "Glow.GLSL")
        try tmp.write("void main() {}", to: user, "Soft.Glsl")
        try tmp.write("void main() {}", to: user, ".Hidden.glsl")
        try tmp.write("notes", to: user, "notes.txt")
        try tmp.write("readme", to: user, "README.md")
        try tmp.write("void main() {}", to: user, "Plain")
        try FileManager.default.createDirectory(
            at: user.appendingPathComponent("x.glsl", isDirectory: true),
            withIntermediateDirectories: true)

        let effects = EffectCatalog.load(user: user, bundled: nil)
        #expect(effects.map(\.name) == ["CRT", "Glow", "Soft"])
        #expect(effects.allSatisfy { $0.location == .user })
    }

    @Test func skipsNonUTF8Files() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        try Data([0xC3, 0x28, 0xFF, 0xFE, 0x80]).write(to: user.appendingPathComponent("Broken.glsl"))
        try tmp.write("void main() {}", to: user, "Good.glsl")

        let effects = EffectCatalog.load(user: user, bundled: nil)
        #expect(effects.map(\.name) == ["Good"])
    }

    @Test func namesStripExtensionAndURLsAppendFileName() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        let bundled = try tmp.folder("bundled")
        try tmp.write("void main() {}", to: user, "Cursor Trail.glsl")
        try tmp.write("void main() {}", to: bundled, "CRT.glsl")
        try tmp.write("void main() {}", to: bundled, "Bloom.GLSL")

        let effects = EffectCatalog.load(user: user, bundled: bundled)
        #expect(effects.map(\.name) == ["Bloom", "CRT", "Cursor Trail"])

        let bloom = try #require(effects.first { $0.name == "Bloom" })
        #expect(bloom.location == .bundled)
        #expect(bloom.url.path == bundled.appendingPathComponent("Bloom.GLSL").path)
        #expect(bloom.id == "Bloom")

        let crt = try #require(effects.first { $0.name == "CRT" })
        #expect(crt.location == .bundled)
        #expect(crt.url.path == bundled.appendingPathComponent("CRT.glsl").path)

        let trail = try #require(effects.first { $0.name == "Cursor Trail" })
        #expect(trail.location == .user)
        #expect(trail.url.path == user.appendingPathComponent("Cursor Trail.glsl").path)
        #expect(trail.id == "Cursor Trail")
    }

    @Test func userEffectHidesBundledEffectWithSameName() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        let bundled = try tmp.folder("bundled")
        try tmp.write("uniform float iTime;", to: user, "CRT.glsl")
        try tmp.write("void main() {}", to: bundled, "CRT.glsl")
        try tmp.write("void main() {}", to: bundled, "Bloom.glsl")

        let effects = EffectCatalog.load(user: user, bundled: bundled)
        #expect(effects.map(\.name) == ["Bloom", "CRT"])
        let crt = try #require(effects.first { $0.name == "CRT" })
        #expect(crt.location == .user)
        #expect(crt.url.path == user.appendingPathComponent("CRT.glsl").path)
        #expect(crt.animates == true)
        #expect(effects.filter { $0.name == "CRT" }.count == 1)
    }

    @Test func missingOrNilFoldersContributeNothing() throws {
        let tmp = try EffectsTempDir()
        let missingUser = tmp.root.appendingPathComponent("no-such-user", isDirectory: true)
        let missingBundled = tmp.root.appendingPathComponent("no-such-bundled", isDirectory: true)
        #expect(EffectCatalog.load(user: missingUser, bundled: nil).isEmpty)
        #expect(EffectCatalog.load(user: missingUser, bundled: missingBundled).isEmpty)

        let bundled = try tmp.folder("bundled")
        try tmp.write("void main() {}", to: bundled, "CRT.glsl")
        let onlyBundled = EffectCatalog.load(user: missingUser, bundled: bundled)
        #expect(onlyBundled.map(\.name) == ["CRT"])
        #expect(onlyBundled.first?.location == .bundled)

        let user = try tmp.folder("user")
        try tmp.write("void main() {}", to: user, "Glow.glsl")
        let onlyUser = EffectCatalog.load(user: user, bundled: missingBundled)
        #expect(onlyUser.map(\.name) == ["Glow"])
        #expect(onlyUser.first?.location == .user)
    }

    @Test func sortsWithLocalizedStandardCompare() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        let bundled = try tmp.folder("bundled")
        try tmp.write("x", to: user, "Glow 10.glsl")
        try tmp.write("x", to: bundled, "Glow 2.glsl")
        try tmp.write("x", to: user, "Beta.glsl")
        try tmp.write("x", to: bundled, "alpha.glsl")

        let effects = EffectCatalog.load(user: user, bundled: bundled)
        #expect(effects.map(\.name) == ["alpha", "Beta", "Glow 2", "Glow 10"])
    }

    @Test func animatesMatchesTimeSubstrings() {
        #expect(EffectCatalog.animates("float t = iTime;"))
        #expect(EffectCatalog.animates("int f = iFrame;"))
        #expect(EffectCatalog.animates("vec4 d = iDate;"))
        #expect(EffectCatalog.animates("float dt = iTimeDelta;"))
        #expect(EffectCatalog.animates("float c = iTimeCursorChange;"))
        #expect(!EffectCatalog.animates("float t = itime;"))
        #expect(!EffectCatalog.animates("float t = ITIME; int f = iframe; vec4 d = idate;"))
        #expect(!EffectCatalog.animates("vec2 r = iResolution.xy; vec4 c = texture(iChannel0, r);"))
        #expect(!EffectCatalog.animates(""))
    }

    @Test func entryAnimatesFollowsFileContents() throws {
        let tmp = try EffectsTempDir()
        let user = try tmp.folder("user")
        let animated = "void mainImage(out vec4 c, in vec2 p) { c = vec4(sin(iTime)); }"
        let still = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"
        try tmp.write(animated, to: user, "Pulse.glsl")
        try tmp.write(still, to: user, "Still.glsl")
        try tmp.write("// uses itime only in lowercase", to: user, "Lower.glsl")

        let effects = EffectCatalog.load(user: user, bundled: nil)
        #expect(effects.map(\.name) == ["Lower", "Pulse", "Still"])
        #expect(effects.map(\.animates) == [false, true, false])
        #expect(effects[1].animates == EffectCatalog.animates(animated))
        #expect(effects[2].animates == EffectCatalog.animates(still))
    }
}

// MARK: - AppearanceSettings

struct AppearanceEffectSettingsTests {
    @Test func defaultsAreNoEffectAndAnimating() {
        let settings = AppearanceSettings()
        #expect(settings.effect == nil)
        #expect(settings.effectAnimates == true)
    }

    @Test func parsesShaderPath() {
        let settings = AppearanceSettings(parsing: "custom-shader = /x/CRT.glsl\n")
        #expect(settings.effect == "/x/CRT.glsl")
        #expect(settings.effectAnimates == true)
        #expect(settings.theme == .none)
    }

    @Test func laterShaderLinesWin() {
        let settings = AppearanceSettings(parsing: """
            custom-shader = /a/First.glsl
            custom-shader = /b/Second.glsl
            """)
        #expect(settings.effect == "/b/Second.glsl")
    }

    @Test func emptyShaderLineClears() {
        let cleared = AppearanceSettings(parsing: """
            custom-shader = /a/First.glsl
            custom-shader =
            """)
        #expect(cleared.effect == nil)

        let reset = AppearanceSettings(parsing: """
            custom-shader = /a/First.glsl
            custom-shader =
            custom-shader = /b/Second.glsl
            """)
        #expect(reset.effect == "/b/Second.glsl")
    }

    @Test func stripsSurroundingQuotes() {
        let settings = AppearanceSettings(parsing: "custom-shader = \"/a b/x.glsl\"\n")
        #expect(settings.effect == "/a b/x.glsl")
    }

    @Test func parsesAnimationFlag() {
        #expect(AppearanceSettings(parsing: "custom-shader-animation = false\n").effectAnimates == false)
        #expect(AppearanceSettings(parsing: "custom-shader-animation = true\n").effectAnimates == true)
        #expect(AppearanceSettings(parsing: "custom-shader-animation = always\n").effectAnimates == true)
        #expect(AppearanceSettings(parsing: """
            custom-shader-animation = false
            custom-shader-animation = always
            """).effectAnimates == true)
        #expect(AppearanceSettings(parsing: """
            custom-shader-animation = true
            custom-shader-animation = false
            """).effectAnimates == false)
    }

    @Test func shaderLinesDoNotChangeThemeOrColors() {
        let parsed = AppearanceSettings(parsing: """
            theme = Nord
            custom-shader =
            custom-shader = /x/CRT.glsl
            """)
        var expected = AppearanceSettings()
        expected.theme = ThemeChoice(single: "Nord")
        expected.effect = "/x/CRT.glsl"
        #expect(parsed == expected)
        #expect(parsed.theme == ThemeChoice(single: "Nord"))
    }

    @Test func nilEffectSerializesAsBefore() {
        #expect(AppearanceSettings().serialized() == effectsHeader)

        var notAnimating = AppearanceSettings()
        notAnimating.effectAnimates = false
        #expect(notAnimating.serialized() == effectsHeader)

        var themed = AppearanceSettings()
        themed.theme = ThemeChoice(single: "Nord")
        themed.effectAnimates = false
        #expect(themed.serialized() == effectsHeader + "theme = Nord\n")
        #expect(!themed.serialized().contains("custom-shader"))
    }

    @Test func serializesEffectWithoutTheme() {
        var settings = AppearanceSettings()
        settings.effect = "/x/CRT.glsl"
        #expect(settings.serialized() == effectsHeader
            + "custom-shader =\n"
            + "custom-shader = /x/CRT.glsl\n")

        settings.effectAnimates = false
        #expect(settings.serialized() == effectsHeader
            + "custom-shader =\n"
            + "custom-shader = /x/CRT.glsl\n"
            + "custom-shader-animation = false\n")
    }

    @Test func serializesNordExampleExactly() {
        var settings = AppearanceSettings()
        settings.theme = ThemeChoice(single: "Nord")
        settings.effect = "/x/CRT.glsl"
        settings.effectAnimates = false
        let expected = """
            # Written by the Nubb Appearance window. It replaces this file on each change.

            theme = Nord
            custom-shader =
            custom-shader = /x/CRT.glsl
            custom-shader-animation = false

            """
        #expect(settings.serialized() == expected)
    }

    @Test func serializesThemeThenEffectWhenAnimating() {
        var settings = AppearanceSettings()
        settings.theme = ThemeChoice(single: "Nord")
        settings.effect = "/x/Pulse.glsl"
        #expect(settings.serialized() == effectsHeader
            + "theme = Nord\n"
            + "custom-shader =\n"
            + "custom-shader = /x/Pulse.glsl\n")
    }

    @Test func emptyShaderLineHasNoTrailingSpace() {
        var settings = AppearanceSettings()
        settings.effect = "/x/CRT.glsl"
        let lines = settings.serialized().components(separatedBy: "\n")
        #expect(lines.contains("custom-shader ="))
        #expect(!lines.contains("custom-shader = "))
    }

    @Test func effectLinesComeBeforeColorLines() throws {
        var settings = AppearanceSettings()
        settings.theme = ThemeChoice(single: "Nord")
        settings.effect = "/x/CRT.glsl"
        settings.overrides.values[.cursorColor] = ThemeRGB(hex: "#ff9e64")
        let text = settings.serialized()
        #expect(text.hasPrefix(effectsHeader
            + "theme = Nord\n"
            + "custom-shader =\n"
            + "custom-shader = /x/CRT.glsl\n"))
        let shader = try #require(text.range(of: "custom-shader = /x/CRT.glsl\n"))
        let color = try #require(text.range(of: "cursor-color = #ff9e64\n"))
        #expect(shader.upperBound <= color.lowerBound)
    }

    @Test func roundTrips() {
        var withTheme = AppearanceSettings()
        withTheme.theme = ThemeChoice(single: "Nord")
        withTheme.effect = "/x/CRT.glsl"
        withTheme.effectAnimates = false
        #expect(AppearanceSettings(parsing: withTheme.serialized()) == withTheme)

        var spaced = AppearanceSettings()
        spaced.effect = "/a b/Cursor Trail.glsl"
        #expect(AppearanceSettings(parsing: spaced.serialized()) == spaced)

        var animating = AppearanceSettings()
        animating.effect = "/x/Pulse.glsl"
        animating.effectAnimates = true
        #expect(AppearanceSettings(parsing: animating.serialized()) == animating)

        var none = AppearanceSettings()
        none.theme = ThemeChoice(single: "Nord")
        #expect(AppearanceSettings(parsing: none.serialized()) == none)
        #expect(AppearanceSettings(parsing: AppearanceSettings().serialized()) == AppearanceSettings())
    }
}

// MARK: - AppearanceModel

@MainActor
struct AppearanceEffectModelTests {
    private final class EffectsSandbox {
        let root: URL
        let config: URL
        let userThemes: URL
        let bundledThemes: URL
        let userEffects: URL
        let bundledEffects: URL
        var reloads = 0

        static let animatedSource = "void mainImage(out vec4 c, in vec2 p) { c = vec4(sin(iTime)); }"
        static let stillSource = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-effects-model-\(UUID().uuidString)", isDirectory: true)
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
            try "background = #ffffff\n"
                .write(to: bundledThemes.appendingPathComponent("Second"), atomically: true, encoding: .utf8)
            try Self.stillSource
                .write(to: bundledEffects.appendingPathComponent("CRT.glsl"), atomically: true, encoding: .utf8)
            try Self.animatedSource
                .write(to: userEffects.appendingPathComponent("Pulse.glsl"), atomically: true, encoding: .utf8)
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

        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        var appearanceURL: URL { config.deletingLastPathComponent().appendingPathComponent("appearance.nubb") }
        var appearance: String { read(appearanceURL) }

        var crtPath: String { bundledEffects.appendingPathComponent("CRT.glsl").path }
        var pulsePath: String { userEffects.appendingPathComponent("Pulse.glsl").path }
    }

    @Test func loadsEffectsAndSplitsByLocation() throws {
        let box = try EffectsSandbox()
        try "x".write(to: box.userEffects.appendingPathComponent("Aura.glsl"), atomically: true, encoding: .utf8)
        try "x".write(to: box.bundledEffects.appendingPathComponent("Bloom.glsl"), atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.effects.map(\.name) == ["Aura", "Bloom", "CRT", "Pulse"])
        #expect(model.userEffects.map(\.name) == ["Aura", "Pulse"])
        #expect(model.bundledEffects.map(\.name) == ["Bloom", "CRT"])
        #expect(model.effects == EffectCatalog.load(user: box.userEffects, bundled: box.bundledEffects))
        #expect(model.selectedEffect == nil)
        #expect(model.settings.effect == nil)
    }

    @Test func selectingStillEffectWritesFileAndReloads() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        let before = box.reloads
        model.selectEffect("CRT")
        #expect(model.settings.effect == box.crtPath)
        #expect(model.settings.effectAnimates == false)
        #expect(model.selectedEffect?.name == "CRT")
        #expect(model.selectedEffect?.location == .bundled)
        model.saveNow()
        #expect(box.reloads == before + 1)
        #expect(box.appearance == effectsHeader
            + "custom-shader =\n"
            + "custom-shader = \(box.crtPath)\n"
            + "custom-shader-animation = false\n")
        #expect(AppearanceInclude.isPresent(in: box.read(box.config)))
    }

    @Test func selectingAnimatedEffectOmitsAnimationLine() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("Pulse")
        #expect(model.settings.effect == box.pulsePath)
        #expect(model.settings.effectAnimates == true)
        #expect(model.selectedEffect?.name == "Pulse")
        #expect(model.selectedEffect?.location == .user)
        model.saveNow()
        #expect(box.appearance == effectsHeader
            + "custom-shader =\n"
            + "custom-shader = \(box.pulsePath)\n")
    }

    @Test func switchingEffectsUpdatesAnimationFlag() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("CRT")
        #expect(model.settings.effectAnimates == false)
        model.selectEffect("Pulse")
        #expect(model.settings.effect == box.pulsePath)
        #expect(model.settings.effectAnimates == true)
        model.selectEffect("CRT")
        #expect(model.settings.effect == box.crtPath)
        #expect(model.settings.effectAnimates == false)
    }

    @Test func selectingNilClearsEffect() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("CRT")
        model.saveNow()
        let afterFirst = box.reloads

        model.selectEffect(nil)
        #expect(model.settings.effect == nil)
        #expect(model.settings.effectAnimates == true)
        #expect(model.selectedEffect == nil)
        model.saveNow()
        #expect(box.reloads == afterFirst + 1)
        #expect(box.appearance == effectsHeader)
    }

    @Test func selectingNilWithNoEffectDoesNothing() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        let before = model.settings
        model.selectEffect(nil)
        #expect(model.settings == before)
        #expect(model.settings.effect == nil)
        #expect(model.settings.effectAnimates == true)
    }

    @Test func selectingCurrentEffectAgainDoesNothing() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("CRT")
        let before = model.settings
        model.selectEffect("CRT")
        #expect(model.settings == before)
        #expect(model.settings.effect == box.crtPath)
    }

    @Test func selectingUnknownEffectDoesNothing() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("Nope")
        #expect(model.settings.effect == nil)
        #expect(model.selectedEffect == nil)

        model.selectEffect("Pulse")
        let before = model.settings
        model.selectEffect("Nope")
        model.selectEffect("Missing Effect")
        #expect(model.settings == before)
        #expect(model.settings.effect == box.pulsePath)
        #expect(model.settings.effectAnimates == true)
        #expect(model.selectedEffect?.name == "Pulse")
    }

    @Test func choosingThemeKeepsEffect() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("CRT")
        model.saveNow()
        model.select("Sample")
        model.saveNow()
        #expect(model.selectedName == "Sample")
        #expect(model.settings.effect == box.crtPath)
        #expect(model.settings.effectAnimates == false)
        #expect(box.appearance == effectsHeader
            + "theme = Sample\n"
            + "custom-shader =\n"
            + "custom-shader = \(box.crtPath)\n"
            + "custom-shader-animation = false\n")
    }

    @Test func choosingEffectKeepsTheme() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        model.select("Second")
        model.saveNow()
        model.selectEffect("Pulse")
        model.saveNow()
        #expect(model.selectedName == "Second")
        #expect(model.settings.theme == ThemeChoice(single: "Second"))
        #expect(box.appearance == effectsHeader
            + "theme = Second\n"
            + "custom-shader =\n"
            + "custom-shader = \(box.pulsePath)\n")

        model.selectEffect(nil)
        model.saveNow()
        #expect(box.appearance == effectsHeader + "theme = Second\n")
    }

    @Test func readsEffectFromExistingAppearanceFile() throws {
        let box = try EffectsSandbox()
        try (effectsHeader
            + "theme = Sample\n"
            + "custom-shader =\n"
            + "custom-shader = \(box.crtPath)\n"
            + "custom-shader-animation = false\n")
            .write(to: box.appearanceURL, atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.settings.effect == box.crtPath)
        #expect(model.settings.effectAnimates == false)
        #expect(model.selectedEffect?.name == "CRT")
        #expect(model.selectedName == "Sample")
    }

    @Test func unmatchedPathIsKeptAcrossSaves() throws {
        let box = try EffectsSandbox()
        let missing = box.root.appendingPathComponent("elsewhere/Gone.glsl").path
        try "custom-shader =\ncustom-shader = \(missing)\n"
            .write(to: box.appearanceURL, atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.selectedEffect == nil)
        #expect(model.settings.effect == missing)

        model.select("Sample")
        model.saveNow()
        #expect(model.selectedEffect == nil)
        #expect(model.settings.effect == missing)
        #expect(box.appearance == effectsHeader
            + "theme = Sample\n"
            + "custom-shader =\n"
            + "custom-shader = \(missing)\n")

        model.select("Second")
        model.saveNow()
        #expect(box.appearance == effectsHeader
            + "theme = Second\n"
            + "custom-shader =\n"
            + "custom-shader = \(missing)\n")
    }

    @Test func eachSaveReloadsOnce() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        let start = box.reloads
        model.selectEffect("CRT")
        model.saveNow()
        #expect(box.reloads == start + 1)
        model.selectEffect("Pulse")
        model.saveNow()
        #expect(box.reloads == start + 2)
        model.selectEffect(nil)
        model.saveNow()
        #expect(box.reloads == start + 3)
    }

    @Test func refreshPicksUpNewEffectFiles() throws {
        let box = try EffectsSandbox()
        let model = box.model()
        #expect(model.effects.map(\.name) == ["CRT", "Pulse"])

        try EffectsSandbox.animatedSource
            .write(to: box.userEffects.appendingPathComponent("Aura.glsl"), atomically: true, encoding: .utf8)
        try EffectsSandbox.stillSource
            .write(to: box.bundledEffects.appendingPathComponent("Bloom.glsl"), atomically: true, encoding: .utf8)
        model.refresh()

        #expect(model.effects.map(\.name) == ["Aura", "Bloom", "CRT", "Pulse"])
        #expect(model.userEffects.map(\.name) == ["Aura", "Pulse"])
        #expect(model.bundledEffects.map(\.name) == ["Bloom", "CRT"])
        let aura = try #require(model.effects.first { $0.name == "Aura" })
        #expect(aura.animates == true)
        #expect(aura.url.path == box.userEffects.appendingPathComponent("Aura.glsl").path)

        model.selectEffect("Bloom")
        #expect(model.settings.effect == box.bundledEffects.appendingPathComponent("Bloom.glsl").path)
        #expect(model.settings.effectAnimates == false)
        #expect(model.selectedEffect?.name == "Bloom")
    }

    @Test func refreshKeepsAChangeWaitingToSave() throws {
        // The menu refreshes the shared model each time it opens. A pick in
        // the Edit Colors window that hasn't saved yet must not be dropped.
        let box = try EffectsSandbox()
        let model = box.model()
        model.selectEffect("CRT")
        let before = box.reloads
        model.refresh()
        #expect(model.settings.effect == box.crtPath)
        #expect(box.reloads == before + 1)
        #expect(box.appearance.contains("custom-shader = \(box.crtPath)\n"))
    }

    @Test func userEffectHidesBundledInModel() throws {
        let box = try EffectsSandbox()
        try EffectsSandbox.animatedSource
            .write(to: box.userEffects.appendingPathComponent("CRT.glsl"), atomically: true, encoding: .utf8)
        let model = box.model()
        #expect(model.effects.map(\.name) == ["CRT", "Pulse"])
        #expect(model.bundledEffects.isEmpty)
        model.selectEffect("CRT")
        #expect(model.settings.effect == box.userEffects.appendingPathComponent("CRT.glsl").path)
        #expect(model.settings.effectAnimates == true)
    }
}
