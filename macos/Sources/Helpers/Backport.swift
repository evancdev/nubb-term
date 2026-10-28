import SwiftUI

// All backport view/scene modifiers go as an extension on this. We use this
// so we can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
    }

    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        if #available(macOS 14, *) {
            return content.onKeyPress(key, phases: .down, action: { keyPress in
                switch action(keyPress.modifiers) {
                case .handled: return .handled
                case .ignored: return .ignored
                }
            })
        } else {
            return content
        }
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .columnResize(directions: .leading)
        case .resizeRight: return .columnResize(directions: .trailing)
        case .resizeUp: return .rowResize(directions: .up)
        case .resizeDown: return .rowResize(directions: .down)
        case .resizeUpDown: return .rowResize
        case .resizeLeftRight: return .columnResize
        }
    }
}

enum BackportGlass {
    case regular, clear

    @available(macOS 26, *)
    var official: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

/// Backported `TextField` that supports text selection on macOS 26 and up. The `selection`
/// has no effect on versions below macOS 26.
///
/// Although the API is available from macOS 15, we force it to be 26. Because on macOS 15,
/// SwiftUI will crash when deleting texts, even for this simple example.
///
///     struct ContentView: View {
///         @State private var text = ""
///         @State private var selection: TextSelection?
///         var body: some View {
///             TextField("Search", text: $text, selection: $selection)
///         }
///     }
struct BackportSelectionTextField: View {
    private let titleKey: LocalizedStringKey
    @Binding private var text: String
    @Binding private var textSelection: Range<String.Index>?

    init(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        selection: Binding<Range<String.Index>?>
    ) {
        self.titleKey = titleKey
        self._text = text
        self._textSelection = selection
    }

    var body: some View {
        if #available(macOS 26, *) {
            TextField(
                titleKey,
                text: _text,
                selection: Binding(
                    get: {
                        if let textSelection {
                            TextSelection(range: textSelection)
                        } else {
                            nil
                        }
                    },
                    set: { selection in
                        if let selection,
                           case .selection(let range) = selection.indices {
                            self.textSelection = range
                        } else {
                            self.textSelection = nil
                        }
                    }
                )
            )
        } else {
            TextField(titleKey, text: _text)
        }
    }
}
