import os
import SwiftUI
import NubbKit

// MARK: C Extensions

extension Nubb {
    // The user notification category identifier
    static let userNotificationCategory = "com.evancdev.nubb.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.evancdev.nubb.userNotification.Show"
}

// MARK: Build Info

extension Nubb {
    struct Info {
        var mode: nubb_build_mode_e
        var version: String
    }

    static var info: Info {
        let raw = nubb_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: General Helpers

extension Nubb {
    enum LaunchSource: String {
        case cli
        case app
        case zig_run
    }

    /// True when this process is the host app for XCTest unit tests. The
    /// test host must stay headless: no windows, no activation, no dock icon.
    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Returns the mechanism that launched the app. This is based on an env var so
    /// its up to the env var being set in the correct circumstance.
    static var launchSource: LaunchSource {
        guard let envValue = ProcessInfo.processInfo.environment["NUBB_MAC_LAUNCH_SOURCE"] else {
            // We default to the CLI because the app bundle always sets the
            // source. If its unset we assume we're in a CLI environment.
            return .cli
        }

        // If the env var is set but its unknown then we default back to the app.
        return LaunchSource(rawValue: envValue) ?? .app
    }
}

// MARK: Swift Types for C Types

extension Nubb {
    class AllocatedString {
        private let cString: nubb_string_s

        init(_ c: nubb_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            nubb_string_free(cString)
        }
    }
}

extension Nubb {
    enum SetFloatWIndow {
        case on
        case off
        case toggle

        static func from(_ c: nubb_action_float_window_e) -> Self? {
            switch c {
            case NUBB_FLOAT_WINDOW_ON:
                return .on

            case NUBB_FLOAT_WINDOW_OFF:
                return .off

            case NUBB_FLOAT_WINDOW_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    enum SetSecureInput {
        case on
        case off
        case toggle

        static func from(_ c: nubb_action_secure_input_e) -> Self? {
            switch c {
            case NUBB_SECURE_INPUT_ON:
                return .on

            case NUBB_SECURE_INPUT_OFF:
                return .off

            case NUBB_SECURE_INPUT_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// Initialize from a Nubb API enum.
        static func from(direction: nubb_action_goto_split_e) -> Self? {
            switch direction {
            case NUBB_GOTO_SPLIT_PREVIOUS:
                return .previous

            case NUBB_GOTO_SPLIT_NEXT:
                return .next

            case NUBB_GOTO_SPLIT_UP:
                return .up

            case NUBB_GOTO_SPLIT_DOWN:
                return .down

            case NUBB_GOTO_SPLIT_LEFT:
                return .left

            case NUBB_GOTO_SPLIT_RIGHT:
                return .right

            default:
                return nil
            }
        }

        func toNative() -> nubb_action_goto_split_e {
            switch self {
            case .previous:
                return NUBB_GOTO_SPLIT_PREVIOUS

            case .next:
                return NUBB_GOTO_SPLIT_NEXT

            case .up:
                return NUBB_GOTO_SPLIT_UP

            case .down:
                return NUBB_GOTO_SPLIT_DOWN

            case .left:
                return NUBB_GOTO_SPLIT_LEFT

            case .right:
                return NUBB_GOTO_SPLIT_RIGHT
            }
        }
    }

    /// Enum used for resizing splits. This is the direction the split divider will move.
    enum SplitResizeDirection {
        case up, down, left, right

        static func from(direction: nubb_action_resize_split_direction_e) -> Self? {
            switch direction {
            case NUBB_RESIZE_SPLIT_UP:
                return .up
            case NUBB_RESIZE_SPLIT_DOWN:
                return .down
            case NUBB_RESIZE_SPLIT_LEFT:
                return .left
            case NUBB_RESIZE_SPLIT_RIGHT:
                return .right
            default:
                return nil
            }
        }

        func toNative() -> nubb_action_resize_split_direction_e {
            switch self {
            case .up:
                return NUBB_RESIZE_SPLIT_UP
            case .down:
                return NUBB_RESIZE_SPLIT_DOWN
            case .left:
                return NUBB_RESIZE_SPLIT_LEFT
            case .right:
                return NUBB_RESIZE_SPLIT_RIGHT
            }
        }
    }
}

// MARK: SplitFocusDirection Extensions

extension Nubb.SplitFocusDirection {
    /// Convert to a SplitTree.FocusDirection for the given ViewType.
    func toSplitTreeFocusDirection<ViewType>() -> SplitTree<ViewType>.FocusDirection {
        switch self {
        case .previous:
            return .previous

        case .next:
            return .next

        case .up:
            return .spatial(.up)

        case .down:
            return .spatial(.down)

        case .left:
            return .spatial(.left)

        case .right:
            return .spatial(.right)
        }
    }
}

extension Nubb {
    /// One representation of clipboard contents. The data is binary-safe;
    /// textual consumers use `string`.
    struct ClipboardContent {
        let mime: String
        let data: Data

        /// The data as text, if it is valid UTF-8.
        var string: String? { String(data: data, encoding: .utf8) }

        static func from(content: nubb_clipboard_content_s) -> ClipboardContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            let data: Data = if content.len > 0 {
                Data(bytes: dataPtr, count: content.len)
            } else {
                Data()
            }

            return ClipboardContent(
                mime: String(cString: mimePtr),
                data: data
            )
        }
    }

    /// Enum for the macos-window-buttons config option
    enum MacOSWindowButtons: String {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }
}

// MARK: Surface Notification

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    static let nubbConfigDidChange = Notification.Name("com.evancdev.nubb.configDidChange")
    static let NubbConfigChangeKey = nubbConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    static let nubbColorDidChange = Notification.Name("com.evancdev.nubb.nubbColorDidChange")
    static let NubbColorChangeKey = nubbColorDidChange.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let nubbMoveTab = Notification.Name("com.evancdev.nubb.moveTab")
    static let NubbMoveTabKey = nubbMoveTab.rawValue

    /// Close tab
    static let nubbCloseTab = Notification.Name("com.evancdev.nubb.closeTab")

    /// Close other tabs
    static let nubbCloseOtherTabs = Notification.Name("com.evancdev.nubb.closeOtherTabs")

    /// Close tabs to the right of the focused tab
    static let nubbCloseTabsOnTheRight = Notification.Name("com.evancdev.nubb.closeTabsOnTheRight")

    /// Close window
    static let nubbCloseWindow = Notification.Name("com.evancdev.nubb.closeWindow")

    /// Resize the window to a default size.
    static let nubbResetWindowSize = Notification.Name("com.evancdev.nubb.resetWindowSize")

    /// Ring the bell
    static let nubbBellDidRing = Notification.Name("com.evancdev.nubb.nubbBellDidRing")

    /// The active selection changed
    static let nubbSelectionDidChange = Notification.Name("com.evancdev.nubb.nubbSelectionDidChange")

    /// Readonly mode changed
    static let nubbDidChangeReadonly = Notification.Name("com.evancdev.nubb.didChangeReadonly")
    static let ReadonlyKey = nubbDidChangeReadonly.rawValue + ".readonly"
    static let nubbCommandPaletteDidToggle = Notification.Name("com.evancdev.nubb.commandPaletteDidToggle")

    /// Toggle the tab sidebar of the window containing the surface (the notification object).
    static let nubbToggleTabSidebar = Notification.Name("com.evancdev.nubb.toggleTabSidebar")

    /// Toggle maximize of current window
    static let nubbMaximizeDidToggle = Notification.Name("com.evancdev.nubb.maximizeDidToggle")

    /// Notification sent when scrollbar updates
    static let nubbDidUpdateScrollbar = Notification.Name("com.evancdev.nubb.didUpdateScrollbar")
    static let ScrollbarKey = nubbDidUpdateScrollbar.rawValue + ".scrollbar"

    /// Focus the search field
    static let nubbSearchFocus = Notification.Name("com.evancdev.nubb.searchFocus")
}

// NOTE: I am moving all of these to Notification.Name extensions over time. This
// namespace was the old namespace.
extension Nubb.Notification {
    /// Used to pass a configuration along when creating a new tab/window/split.
    static let NewSurfaceConfigKey = "com.evancdev.nubb.newSurfaceConfig"

    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let nubbNewSplit = Notification.Name("com.evancdev.nubb.newSplit")

    /// Close the calling surface.
    static let nubbCloseSurface = Notification.Name("com.evancdev.nubb.closeSurface")

    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let nubbFocusSplit = Notification.Name("com.evancdev.nubb.focusSplit")
    static let SplitDirectionKey = nubbFocusSplit.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let nubbGotoTab = Notification.Name("com.evancdev.nubb.gotoTab")
    static let GotoTabKey = nubbGotoTab.rawValue

    /// New tab. Has base surface config requested in userinfo.
    static let nubbNewTab = Notification.Name("com.evancdev.nubb.newTab")

    /// New window. Has base surface config requested in userinfo.
    static let nubbNewWindow = Notification.Name("com.evancdev.nubb.newWindow")

    /// Present terminal. Bring the surface's window to focus without activating the app.
    static let nubbPresentTerminal = Notification.Name("com.evancdev.nubb.presentTerminal")

    /// Toggle fullscreen of current window
    static let nubbToggleFullscreen = Notification.Name("com.evancdev.nubb.toggleFullscreen")
    static let FullscreenModeKey = nubbToggleFullscreen.rawValue

    /// Notification sent to toggle split maximize/unmaximize.
    static let didToggleSplitZoom = Notification.Name("com.evancdev.nubb.didToggleSplitZoom")

    /// Notification sent to the active split view to resize the split.
    static let didResizeSplit = Notification.Name("com.evancdev.nubb.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification sent to the split root to equalize split sizes
    static let didEqualizeSplits = Notification.Name("com.evancdev.nubb.didEqualizeSplits")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("com.evancdev.nubb.didUpdateRendererHealth")

    /// Notifications related to key sequences
    static let didContinueKeySequence = Notification.Name("com.evancdev.nubb.didContinueKeySequence")
    static let didEndKeySequence = Notification.Name("com.evancdev.nubb.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"

    /// Notifications related to key tables
    static let didChangeKeyTable = Notification.Name("com.evancdev.nubb.didChangeKeyTable")
    static let KeyTableKey = didChangeKeyTable.rawValue + ".action"
}

// Make the input enum hashable.
extension nubb_input_key_e: @retroactive Hashable {}
