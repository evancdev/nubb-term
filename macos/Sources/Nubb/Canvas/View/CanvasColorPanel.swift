import AppKit

/// Connects the shared macOS color panel to one canvas color at a time.
/// Each change in the panel is reported as an Excalidraw hex color.
@MainActor
final class CanvasColorPanel: NSObject {
    static let shared = CanvasColorPanel()

    private var onChange: ((String) -> Void)?

    func open(color: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        let rgba = CanvasColor.isTransparent(color)
            ? CanvasRGBA(red: 1, green: 1, blue: 1)
            : CanvasColor.resolve(color, theme: .light)
        panel.color = NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: 1)
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        onChange?(CanvasRGBA(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hexString)
    }
}
