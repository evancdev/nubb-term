import AppKit
import SwiftUI
import Testing
@testable import Ghostty
import GhosttyKit

/// The menu-shortcut path must translate the key equivalent with only the
/// command modifier applied: command can select a distinct layout table, while
/// the other modifiers live in the shortcut's modifier mask.
@MainActor
struct KeyboardShortcutTranslationTests {
    @Test func keyEquivalentIgnoresNonCommandModifiers() throws {
        var trigger = ghostty_input_trigger_s()
        trigger.tag = GHOSTTY_TRIGGER_PHYSICAL
        trigger.key.physical = GHOSTTY_KEY_BACKQUOTE
        trigger.mods = ghostty_input_mods_e(
            GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_ALT.rawValue)

        let shortcut = try #require(Ghostty.keyboardShortcut(for: trigger))
        let expected = try #require(KeyboardLayout.character(
            for: 0x32, // W3C Backquote
            modifiers: .command))
        #expect(shortcut.key.character == expected)
        #expect(shortcut.modifiers.contains(.shift))
        #expect(shortcut.modifiers.contains(.option))
        #expect(shortcut.modifiers.contains(.command))
    }
}
