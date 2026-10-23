import AppKit
import SwiftUI
import Testing
@testable import Ghostty
import NubbKit

/// The menu-shortcut path must translate the key equivalent with only the
/// command modifier applied: command can select a distinct layout table, while
/// the other modifiers live in the shortcut's modifier mask.
@MainActor
struct KeyboardShortcutTranslationTests {
    @Test func keyEquivalentIgnoresNonCommandModifiers() throws {
        var trigger = nubb_input_trigger_s()
        trigger.tag = NUBB_TRIGGER_PHYSICAL
        trigger.key.physical = NUBB_KEY_BACKQUOTE
        trigger.mods = nubb_input_mods_e(
            NUBB_MODS_SUPER.rawValue | NUBB_MODS_SHIFT.rawValue | NUBB_MODS_ALT.rawValue)

        let shortcut = try #require(Nubb.keyboardShortcut(for: trigger))
        let expected = try #require(KeyboardLayout.character(
            for: 0x32, // W3C Backquote
            modifiers: .command))
        #expect(shortcut.key.character == expected)
        #expect(shortcut.modifiers.contains(.shift))
        #expect(shortcut.modifiers.contains(.option))
        #expect(shortcut.modifiers.contains(.command))
    }
}
