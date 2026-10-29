import Foundation
import Testing
@testable import Nubb
@testable import NubbKit

/// Checks the preview overlay against Nubb's real config loader.
struct AppearanceOverlayTests {
    private final class Files {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-overlay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, _ text: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    @Test func overlayResetsTheSavedTheme() throws {
        let files = try Files()
        let theme = try files.write("Dim", "background-opacity = 0.4\n")
        let config = try files.write("config", "theme = \(theme)\n")

        #expect(Nubb.Config(at: config, overlay: nil).backgroundOpacity == 0.4)

        // Previewing "Nubb Default" writes no theme line, so only the reset
        // at the top of the overlay drops the saved theme.
        let none = try files.write("none.nubb", AppearanceMenu.overlayText(AppearanceSettings().serialized()))
        #expect(Nubb.Config(at: config, overlay: none).backgroundOpacity == 1)
    }

    @Test func overlayThemeReplacesTheSavedTheme() throws {
        let files = try Files()
        let saved = try files.write("Dim", "background-opacity = 0.4\n")
        let other = try files.write("Faint", "background-opacity = 0.7\n")
        let config = try files.write("config", "theme = \(saved)\n")

        var settings = AppearanceSettings()
        settings.theme = ThemeChoice(single: other)
        let overlay = try files.write("preview.nubb", AppearanceMenu.overlayText(settings.serialized()))
        #expect(Nubb.Config(at: config, overlay: overlay).backgroundOpacity == 0.7)
    }

    @Test func overlayKeepsOtherSavedOptions() throws {
        let files = try Files()
        let config = try files.write("config", "background-opacity = 0.5\nfont-size = 15\n")
        let overlay = try files.write("preview.nubb", AppearanceMenu.overlayText(AppearanceSettings().serialized()))
        #expect(Nubb.Config(at: config, overlay: overlay).backgroundOpacity == 0.5)
    }
}
