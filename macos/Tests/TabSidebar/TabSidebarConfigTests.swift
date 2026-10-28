import Foundation
import SwiftUI
import Testing
@testable import Nubb

@Suite
struct TabSidebarConfigTests {
    @Test func macosTabSidebarDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosTabSidebar == true)
    }

    @Test func macosTabSidebarSetToFalse() throws {
        let config = try TemporaryConfig("macos-tab-sidebar = false")
        #expect(config.macosTabSidebar == false)
    }

    @Test func macosTabSidebarExplicitlyTrue() throws {
        let config = try TemporaryConfig("macos-tab-sidebar = true")
        #expect(config.macosTabSidebar == true)
    }

    @MainActor @Test
    func toggleTabSidebarDefaultsToCommandB() throws {
        let config = try TemporaryConfig("")
        let shortcut = try #require(config.keyboardShortcut(for: "toggle_tab_sidebar"))
        #expect(shortcut.description == "⌘B")
    }

    @MainActor @Test
    func toggleTabSidebarUnbindRemovesShortcut() throws {
        let config = try TemporaryConfig("keybind = super+b=unbind")
        #expect(config.keyboardShortcut(for: "toggle_tab_sidebar") == nil)
    }
}
