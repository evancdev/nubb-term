import NubbKit

extension FullscreenMode {
    /// Initialize from a Nubb fullscreen action.
    static func from(ghostty: nubb_action_fullscreen_e) -> Self? {
        return switch ghostty {
        case NUBB_FULLSCREEN_NATIVE:
                .native

        case NUBB_FULLSCREEN_MACOS_NON_NATIVE:
                .nonNative

        case NUBB_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU:
                .nonNativeVisibleMenu

        case NUBB_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH:
                .nonNativePaddedNotch

        default:
            nil
        }
    }
}
