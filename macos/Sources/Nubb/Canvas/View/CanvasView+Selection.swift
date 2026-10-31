import AppKit

// MARK: - Selection geometry and overlay

extension CanvasView {
    static let handleSize: CGFloat = 8
    static let handleSpacing: CGFloat = 4
    static let rotationGap: CGFloat = 16
    static let pointRadius: CGFloat = 5

    /// The color of selection outlines and handles.
    var selectionColor: CGColor {
        theme == .dark
            ? CGColor(srgbRed: 0.66, green: 0.65, blue: 1, alpha: 1)
            : CGColor(srgbRed: 0.41, green: 0.40, blue: 0.86, alpha: 1)
    }

    /// The box the transform handles sit on. One element gets its own
    /// rotated box; several share an axis-aligned box.
    struct SelectionFrame {
        /// The single element, when only one is selected.
        var element: CanvasElement?
        /// The box in the element's local coordinates, or in scene
        /// coordinates when several elements are selected.
        var box: CGRect
        var elements: [CanvasElement]

        func toScene(_ point: CGPoint) -> CGPoint {
            element?.toScene(point) ?? point
        }

        var angle: Double { element?.angle ?? 0 }

        /// The rotation center in scene coordinates.
        var center: CGPoint {
            element?.center ?? CGPoint(x: box.midX, y: box.midY)
        }
    }

    /// The elements resize and rotate act on: the selection without the
    /// labels, which follow their containers.
    var transformTargets: [CanvasElement] {
        let positions = CanvasOps.index(editor.document)
        return editor.selectedElements.filter { !CanvasOps.isBoundText($0, positions: positions) }
    }

    var selectionFrame: SelectionFrame? {
        let targets = transformTargets
        guard !targets.isEmpty else { return nil }
        if targets.count == 1 {
            return SelectionFrame(element: targets[0], box: targets[0].localBounds, elements: targets)
        }
        return SelectionFrame(element: nil, box: CanvasRenderer.sceneBounds(of: targets), elements: targets)
    }

    /// The single selected line or arrow, whose points can be dragged.
    var selectedLinear: CanvasElement? {
        let targets = transformTargets
        guard targets.count == 1, targets[0].type.isLinear, !targets[0].locked else { return nil }
        return targets[0]
    }

    /// The handles to show for the selection.
    func visibleHandles(for frame: SelectionFrame) -> [CanvasTransform.Handle] {
        if frame.elements.contains(where: \.locked) { return [] }
        if let element = frame.element {
            if element.type.isLinear && element.points.count <= 2 { return [] }
            if element.type == .text {
                return [.topLeft, .topRight, .bottomRight, .bottomLeft, .rotation]
            }
        }
        let width = frame.box.width * viewport.zoom
        let height = frame.box.height * viewport.zoom
        var handles: [CanvasTransform.Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .rotation]
        if width > Self.handleSize * 4 { handles += [.top, .bottom] }
        if height > Self.handleSize * 4 { handles += [.left, .right] }
        // Tiny selections keep one corner and rotation, so they can still be
        // grabbed.
        if width < Self.handleSize * 2 || height < Self.handleSize * 2 {
            handles = [.bottomRight, .rotation]
        }
        return handles
    }

    /// The box with the handle spacing added, in the frame's coordinates.
    private func paddedBox(_ frame: SelectionFrame) -> CGRect {
        let pad = (Self.handleSpacing + Self.handleSize / 2) / viewport.zoom
        return frame.box.insetBy(dx: -pad, dy: -pad)
    }

    /// The center of a handle in screen coordinates.
    func handleCenter(_ handle: CanvasTransform.Handle, in frame: SelectionFrame) -> CGPoint {
        let padded = paddedBox(frame)
        var local = handle.position(in: padded)
        if handle == .rotation {
            local.y -= (Self.rotationGap + Self.handleSize / 2) / viewport.zoom
        }
        return viewport.toScreen(frame.toScene(local))
    }

    /// The scene point of the real box edge a handle moves, used so a drag
    /// doesn't jump by the handle spacing.
    func handleAnchor(_ handle: CanvasTransform.Handle, in frame: SelectionFrame) -> CGPoint {
        frame.toScene(handle.position(in: frame.box))
    }

    func handle(at screenPoint: CGPoint) -> (CanvasTransform.Handle, SelectionFrame)? {
        guard let frame = selectionFrame else { return nil }
        for handle in visibleHandles(for: frame) {
            let center = handleCenter(handle, in: frame)
            if hypot(center.x - screenPoint.x, center.y - screenPoint.y) <= Self.handleSize {
                return (handle, frame)
            }
        }
        return nil
    }

    /// The point of the selected line under `screenPoint`.
    func linearPoint(at screenPoint: CGPoint) -> (CanvasElement, Int)? {
        guard let element = selectedLinear else { return nil }
        for (index, point) in element.points.enumerated().reversed() {
            let screen = viewport.toScreen(element.toScene(point))
            if hypot(screen.x - screenPoint.x, screen.y - screenPoint.y) <= Self.pointRadius + 3 {
                return (element, index)
            }
        }
        return nil
    }

    /// Whether `scenePoint` is inside the selection's box.
    func isInsideSelection(_ scenePoint: CGPoint) -> Bool {
        guard let frame = selectionFrame else { return false }
        let local = frame.element?.toLocal(scenePoint) ?? scenePoint
        let pad = 4 / viewport.zoom
        return frame.box.insetBy(dx: -pad, dy: -pad).contains(local)
    }

    // MARK: Hit testing

    /// The click tolerance in scene units.
    var hitThreshold: Double { 8 / viewport.zoom }

    /// The topmost element under `scenePoint`. A click on a label picks
    /// its container.
    func element(at scenePoint: CGPoint, includeLocked: Bool = false) -> CanvasElement? {
        let document = editor.document
        let positions = CanvasOps.index(document)
        for element in document.elements.reversed() {
            if hiddenElements.contains(element.id) { continue }
            if element.locked && !includeLocked { continue }
            guard element.hitTest(scenePoint, threshold: hitThreshold) else { continue }
            if CanvasOps.isBoundText(element, positions: positions), let container = element.containerId,
               let index = positions[container] {
                return document.elements[index]
            }
            return element
        }
        return nil
    }

    // MARK: Overlay

    func drawOverlay(in context: CGContext) {
        context.setLineWidth(1)
        let color = selectionColor

        if let highlight = bindingHighlight, let target = editor.element(highlight) {
            context.saveGState()
            context.concatenate(viewport.transform)
            drawOutline(of: target, in: context, color: color.copy(alpha: 0.35) ?? color, width: 6 / viewport.zoom)
            context.restoreGState()
        }

        // A faint outline ties the hover name to its element.
        if let id = hover.shownID, !editor.selection.contains(id), let target = editor.element(id) {
            context.saveGState()
            context.concatenate(viewport.transform)
            drawOutline(of: target, in: context, color: color.copy(alpha: 0.45) ?? color, width: 1.5 / viewport.zoom)
            context.restoreGState()
        }

        if case let .marquee(start, current, _) = drag {
            let rect = viewport.toScreen(CanvasGeometry.normalizedRect(start, current))
            context.setFillColor(color.copy(alpha: 0.08) ?? color)
            context.fill(rect)
            context.setStrokeColor(color)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }

        guard textEditing == nil, multipoint == nil, !isCreating, let frame = selectionFrame else { return }

        // Each selected element gets a box; several also get a shared one.
        context.setStrokeColor(color)
        if frame.elements.count > 1 {
            context.setLineDash(phase: 0, lengths: [4, 4])
            for element in frame.elements {
                strokeBox(element.localBounds, toScene: element.toScene, in: context)
            }
            context.setLineDash(phase: 0, lengths: [])
        }

        if let linear = selectedLinear, linear.points.count <= 2 {
            drawPoints(of: linear, in: context)
            return
        }

        let pad = (Self.handleSpacing + Self.handleSize / 2) / viewport.zoom
        strokeBox(frame.box.insetBy(dx: -pad, dy: -pad), toScene: frame.toScene, in: context)

        guard !isTransforming || isRotating else {
            return
        }
        for handle in visibleHandles(for: frame) {
            drawHandle(handle, at: handleCenter(handle, in: frame), angle: frame.angle, in: context)
        }
        if let linear = selectedLinear {
            drawPoints(of: linear, in: context)
        }
    }

    private var isCreating: Bool {
        switch drag {
        case .create, .linear, .freedraw: true
        default: false
        }
    }

    private var isTransforming: Bool {
        switch drag {
        case .move, .resize, .rotate: true
        default: false
        }
    }

    private var isRotating: Bool {
        if case .rotate = drag { return true }
        return false
    }

    private func strokeBox(_ box: CGRect, toScene: (CGPoint) -> CGPoint, in context: CGContext) {
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ].map { viewport.toScreen(toScene($0)) }
        context.addLines(between: corners)
        context.closePath()
        context.strokePath()
    }

    private func drawHandle(_ handle: CanvasTransform.Handle, at center: CGPoint, angle: Double, in context: CGContext) {
        let size = Self.handleSize
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(angle))
        let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        let path = handle == .rotation
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.addPath(path)
        context.setFillColor(CanvasColor.cgColor(editor.document.viewBackgroundColor, theme: theme))
        context.setStrokeColor(selectionColor)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private func drawPoints(of element: CanvasElement, in context: CGContext) {
        let r = Self.pointRadius
        for point in element.points {
            let screen = viewport.toScreen(element.toScene(point))
            let rect = CGRect(x: screen.x - r, y: screen.y - r, width: r * 2, height: r * 2)
            context.addEllipse(in: rect)
        }
        context.setFillColor(CanvasColor.cgColor(editor.document.viewBackgroundColor, theme: theme))
        context.setStrokeColor(selectionColor)
        context.drawPath(using: .fillStroke)
    }

    private func drawOutline(of element: CanvasElement, in context: CGContext, color: CGColor, width: Double) {
        context.saveGState()
        let center = element.center
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(element.angle))
        context.translateBy(x: CGFloat(element.x) - center.x, y: CGFloat(element.y) - center.y)
        context.addPath(element.outlinePath)
        context.setStrokeColor(color)
        context.setLineWidth(CGFloat(width))
        context.strokePath()
        context.restoreGState()
    }
}
