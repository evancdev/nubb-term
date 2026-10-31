import AppKit
import Combine

/// The drawing surface: renders the document, shows the selection, and
/// turns pointer and keyboard input into editor changes.
///
/// The view draws on demand only. Edits redraw just the area of the
/// elements that changed, found by comparing element versions. Shapes are
/// built once per element version (see `CanvasRenderer`), so panning and
/// zooming replay cached paths. Nothing runs while the canvas is idle.
final class CanvasView: NSView {
    let editor: CanvasEditor
    let renderer = CanvasRenderer()
    let overlay = CanvasOverlayView()

    var viewport = CanvasViewport() {
        didSet {
            guard viewport != oldValue else { return }
            if viewport.zoom != oldValue.zoom {
                renderer.zoom = viewport.zoom
                frameZoomChanged()
            }
            needsDisplay = true
            overlay.needsDisplay = true
            editor.ui.set(\.zoom, viewport.zoom)
            layoutTextEditor()
            onViewportChange?()
        }
    }

    /// Called after the camera moves, e.g. to remember it.
    var onViewportChange: (() -> Void)?

    var theme: CanvasTheme = .light {
        didSet {
            guard theme != oldValue else { return }
            renderer.theme = theme
            editor.ui.set(\.theme, theme)
            needsDisplay = true
            overlay.needsDisplay = true
            updateTextEditorStyle()
        }
    }

    /// Handles key presses that are Nubb keybindings, like switching tabs.
    /// Returns true when the key was used.
    var keyBindingHandler: ((NSEvent) -> Bool)?

    // MARK: Interaction state (used by the extensions)

    /// The current mouse drag.
    var drag: Drag = .none

    /// A line or arrow being drawn point by point: its last point follows
    /// the pointer until the line is finished.
    var multipoint: String?

    /// The shape an arrow end would attach to, highlighted while drawing.
    var bindingHighlight: String?

    /// The text being edited, if any.
    var textEditing: TextEditing?
    var textView: CanvasTextView?

    /// Elements the eraser will delete, drawn faded.
    var erasing: Set<String> = [] {
        didSet { markDirty(erasing.symmetricDifference(oldValue)) }
    }

    /// Elements not drawn, such as the text being edited.
    var hiddenElements: Set<String> = [] {
        didSet { markDirty(hiddenElements.symmetricDifference(oldValue)) }
    }

    var spaceHeld = false
    var lastPointer: CGPoint?

    /// The scene point of the last mouse event, for pasting.
    var lastScenePointer: CGPoint? {
        lastPointer.map(viewport.toScene)
    }

    // MARK: Change tracking

    private struct Painted {
        var version: Int
        var versionNonce: Int
        var bounds: CGRect
    }

    private var painted: [String: Painted] = [:]
    private var paintedOrder: [String] = []
    private var paintedBackground = ""
    private var needsInitialFit = true
    private var trackingArea: NSTrackingArea?

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true

        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        editor.onDocumentChange = { [weak self] in self?.documentDidChange() }
        editor.onExternalChange = { [weak self] ids in self?.elementsReplaced(ids) }
        editor.onSelectionChange = { [weak self] in self?.overlay.needsDisplay = true }
        syncTheme()
        documentDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        if needsInitialFit, bounds.width > 0, bounds.height > 0 {
            needsInitialFit = false
            fitToContent(animated: false)
        }
        layoutTextEditor()
    }

    /// Shows the whole drawing, or the origin when it is empty.
    func fitToContent(animated: Bool = true, maxZoom: Double = 1) {
        let content = CanvasRenderer.sceneBounds(of: editor.document.elements)
        if content.isNull {
            viewport = CanvasViewport(zoom: 1, offset: CGPoint(x: 0, y: 0))
        } else {
            viewport = .fitting(content, in: visibleCanvasSize, padding: 60, maxZoom: maxZoom)
        }
    }

    /// Zooms to the selected elements.
    func zoomToSelection() {
        let selected = editor.selectedElements
        guard !selected.isEmpty else { return fitToContent() }
        let content = CanvasRenderer.sceneBounds(of: selected)
        viewport = .fitting(content, in: visibleCanvasSize, padding: 80, maxZoom: CanvasViewport.maxZoom)
    }

    private var visibleCanvasSize: CGSize { bounds.size }

    func zoom(by factor: Double, around anchor: CGPoint? = nil) {
        var next = viewport
        next.zoom(to: viewport.zoom * factor, around: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY))
        viewport = next
    }

    func zoomStep(in zoomIn: Bool) {
        var next = viewport
        next.zoom(to: CanvasViewport.steppedZoom(from: viewport.zoom, in: zoomIn), around: CGPoint(x: bounds.midX, y: bounds.midY))
        viewport = next
    }

    func resetZoom() {
        var next = viewport
        next.zoom(to: 1, around: CGPoint(x: bounds.midX, y: bounds.midY))
        viewport = next
    }

    // MARK: Theme

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncTheme()
    }

    private func syncTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        theme = dark ? .dark : .light
        renderer.theme = theme
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let document = editor.document
        context.setFillColor(CanvasColor.cgColor(document.viewBackgroundColor, theme: theme))
        context.fill(dirtyRect)

        context.saveGState()
        context.concatenate(viewport.transform)
        renderer.draw(
            document, in: context,
            visible: viewport.toScene(dirtyRect),
            hidden: hiddenElements, dimmed: erasing)
        context.restoreGState()
    }

    /// Redraws the area of the elements in `ids`.
    func markDirty(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var dirty = CGRect.null
        for element in editor.document.elements where ids.contains(element.id) {
            dirty = dirty.union(renderer.paintBounds(of: element))
        }
        setNeedsDisplay(sceneRect: dirty)
    }

    func setNeedsDisplay(sceneRect rect: CGRect) {
        guard !rect.isNull else { return }
        setNeedsDisplay(viewport.toScreen(rect).insetBy(dx: -2, dy: -2))
    }

    /// Elements replaced from the file keep their version numbers when an
    /// agent edits the JSON by hand, so drop what was cached about them.
    private func elementsReplaced(_ ids: Set<String>) {
        var dirty = CGRect.null
        for id in ids {
            if let old = painted.removeValue(forKey: id) { dirty = dirty.union(old.bounds) }
        }
        renderer.invalidate(ids)
        setNeedsDisplay(sceneRect: dirty)
    }

    /// Frame outlines keep their screen width, so the area they paint
    /// changes with the zoom.
    private func frameZoomChanged() {
        for element in editor.document.elements where element.type == .frame {
            painted[element.id]?.bounds = renderer.paintBounds(of: element)
        }
    }

    /// Finds what changed since the last draw and redraws only that area.
    func documentDidChange() {
        let document = editor.document
        overlay.needsDisplay = true
        editor.ui.set(\.isEmpty, document.elements.isEmpty)

        if document.viewBackgroundColor != paintedBackground {
            paintedBackground = document.viewBackgroundColor
            needsDisplay = true
        }

        var dirty = CGRect.null
        var next: [String: Painted] = [:]
        next.reserveCapacity(document.elements.count)
        var order: [String] = []
        order.reserveCapacity(document.elements.count)

        for element in document.elements {
            order.append(element.id)
            if let old = painted[element.id],
               old.version == element.version, old.versionNonce == element.versionNonce {
                next[element.id] = old
                continue
            }
            let bounds = renderer.paintBounds(of: element)
            dirty = dirty.union(bounds)
            if let old = painted[element.id] { dirty = dirty.union(old.bounds) }
            next[element.id] = Painted(version: element.version, versionNonce: element.versionNonce, bounds: bounds)
        }

        var removed = false
        for (id, old) in painted where next[id] == nil {
            dirty = dirty.union(old.bounds)
            removed = true
        }

        // A changed stacking order of unchanged elements redraws everything:
        // it is rare and the overlap area isn't worth computing.
        let oldCommon = paintedOrder.filter { next[$0] != nil }
        let newCommon = order.filter { painted[$0] != nil }
        if oldCommon != newCommon { needsDisplay = true }

        painted = next
        paintedOrder = order
        if removed { renderer.prune(keeping: Set(order)) }
        setNeedsDisplay(sceneRect: dirty)

        if textEditing != nil { layoutTextEditor() }
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.firstResponder === window {
            window.makeFirstResponder(self)
        }
    }
}

// MARK: - Overlay

/// Draws the selection, handles, and in-progress feedback above the
/// drawing, so selection changes don't redraw the elements.
final class CanvasOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Clicks go to the canvas below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawOverlay(in: context)
    }
}
