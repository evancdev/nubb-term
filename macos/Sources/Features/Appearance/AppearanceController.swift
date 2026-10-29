import Cocoa
import SwiftUI

/// Owns the single Edit Colors window.
@MainActor
final class AppearanceController: NSWindowController, NSWindowDelegate {
    private static var shared: AppearanceController?

    private let model: AppearanceModel

    /// Shows the window, creating it on first use. Pass the Appearance
    /// menu's model so a pick in the menu shows here and isn't overwritten
    /// by the window's next save.
    static func show(app: Nubb.App, model sharedModel: AppearanceModel? = nil) {
        if let shared {
            shared.model.refresh()
            shared.showWindow(nil)
            return
        }

        let model: AppearanceModel
        if let sharedModel {
            sharedModel.refresh()
            model = sharedModel
        } else {
            let path = app.configFilePath
            guard !path.isEmpty else {
                Nubb.logger.warning("appearance window has no config file to write to")
                return
            }
            model = AppearanceModel(configURL: URL(fileURLWithPath: path)) { [weak app] in
                app?.reloadConfig()
            }
        }
        let controller = AppearanceController(model: model)
        shared = controller
        controller.showWindow(nil)
    }

    private init(model: AppearanceModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Colors"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: AppearanceView(model: model))
        window.center()
        window.setFrameAutosaveName("NubbAppearance")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
