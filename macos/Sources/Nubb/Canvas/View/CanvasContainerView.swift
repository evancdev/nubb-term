import AppKit
import SwiftUI

/// The canvas with its floating toolbar, style panel, and zoom controls.
/// Each piece of chrome is its own hosting view sized to its content, so
/// clicks outside them reach the canvas.
final class CanvasContainerView: NSView {
    let canvas: CanvasView

    private var hostingViews: [NSView] = []

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let editor = canvas.editor
        let ui = editor.ui

        let hint = host(CanvasEmptyHintHost(ui: ui), passThrough: true)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let toolbar = host(CanvasToolbar(
            ui: ui,
            onSelect: { [weak canvas] tool in
                canvas?.setTool(tool)
                canvas?.window?.makeFirstResponder(canvas)
            },
            onToggleLock: { [weak editor] in editor?.toolLocked.toggle() }))
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        let banner = host(CanvasErrorBannerHost(ui: ui), passThrough: true)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
        ])

        let panel = host(CanvasStylePanelHost(
            ui: ui,
            apply: { [weak editor] key, change in editor?.applyStyle(coalescing: key, change) },
            onLayer: { [weak editor] direction in editor?.reorderSelection(direction) },
            onDuplicate: { [weak editor] in editor?.duplicateSelection() },
            onDelete: { [weak editor] in editor?.deleteSelection() }))
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            panel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
        ])

        let footer = host(CanvasFooter(
            ui: ui,
            onZoomOut: { [weak canvas] in canvas?.zoomStep(in: false) },
            onZoomIn: { [weak canvas] in canvas?.zoomStep(in: true) },
            onResetZoom: { [weak canvas] in canvas?.resetZoom() },
            onUndo: { [weak canvas] in canvas?.undo(nil) },
            onRedo: { [weak canvas] in canvas?.redo(nil) }))
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func host<Content: View>(_ view: Content, passThrough: Bool = false) -> NSView {
        let hosting: NSView
        if passThrough {
            let pass = PassThroughHostingView(rootView: view)
            pass.sizingOptions = [.intrinsicContentSize]
            hosting = pass
        } else {
            let normal = NSHostingView(rootView: view)
            normal.sizingOptions = [.intrinsicContentSize]
            hosting = normal
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        hostingViews.append(hosting)
        return hosting
    }
}

/// A hosting view that never takes clicks.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Hosts that show or hide their content

private struct CanvasEmptyHintHost: View {
    @ObservedObject var ui: CanvasUIState

    var body: some View {
        if ui.isEmpty && ui.loadError == nil {
            CanvasEmptyHint()
        }
    }
}

private struct CanvasErrorBannerHost: View {
    @ObservedObject var ui: CanvasUIState

    var body: some View {
        if let error = ui.loadError {
            CanvasErrorBanner(message: error)
        }
    }
}

private struct CanvasStylePanelHost: View {
    @ObservedObject var ui: CanvasUIState
    let apply: (String?, (inout CanvasStyle) -> Void) -> Void
    let onLayer: (CanvasOps.Reorder) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if ui.showsStylePanel {
            CanvasStylePanel(
                ui: ui, applyCoalescing: apply, onLayer: onLayer, onDuplicate: onDuplicate, onDelete: onDelete)
        }
    }
}
