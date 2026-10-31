import AppKit

/// Whether canvases draw light or dark. Excalidraw starts light whatever the
/// system does, so canvases do too unless the person picks otherwise.
enum CanvasAppearance: String, CaseIterable {
    case light
    case dark
    case system

    static let defaultsKey = "CanvasAppearance"
    static let didChange = Notification.Name("NubbCanvasAppearanceDidChange")

    /// Where the choice is saved. Tests swap in their own.
    static var defaults: UserDefaults = .standard

    static var current: CanvasAppearance {
        get { defaults.string(forKey: defaultsKey).flatMap(CanvasAppearance.init(rawValue:)) ?? .light }
        set {
            guard newValue != current else { return }
            defaults.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match System"
        }
    }

    /// The appearance canvases use, or nil to follow the window.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    /// Light if the canvas is dark now, dark otherwise, as Excalidraw's
    /// Option-Shift-D does.
    static func toggle(from view: NSView) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        current = dark ? .light : .dark
    }
}

/// Menu items that pick the canvas appearance, for the View menu and the
/// canvas's context menu.
final class CanvasAppearanceMenu: NSObject, NSMenuItemValidation {
    static let shared = CanvasAppearanceMenu()

    /// A "Canvas Theme" item whose submenu has one item per choice.
    func makeItem(title: String = "Canvas Theme") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for choice in CanvasAppearance.allCases {
            let option = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice.rawValue
            if choice == .system { menu.addItem(.separator()) }
            menu.addItem(option)
        }
        item.submenu = menu
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = CanvasAppearance(rawValue: raw) else { return }
        CanvasAppearance.current = choice
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let raw = item.representedObject as? String {
            item.state = raw == CanvasAppearance.current.rawValue ? .on : .off
        }
        return true
    }
}
