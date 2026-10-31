import AppKit

// MARK: - Pointer input

extension CanvasView {
    /// What the current mouse drag does.
    enum Drag {
        case none
        /// Panning: the screen point the drag started at and the offset then.
        case pan(start: CGPoint, offset: CGPoint)
        /// The selection tool pressed on something but hasn't moved yet.
        case press(start: CGPoint, screen: CGPoint, deselect: String?, duplicate: Bool)
        /// Moving the selection. `originals` holds the moved elements as they
        /// were when the move started.
        case move(start: CGPoint, originals: [String: CanvasElement])
        case marquee(start: CGPoint, current: CGPoint, base: Set<String>)
        /// `grab` is how far the pointer was from the box edge the handle moves.
        case resize(handle: CanvasTransform.Handle, frame: SelectionFrame, grab: CGVector, originals: [CanvasElement])
        case rotate(center: CGPoint, start: CGPoint, originals: [CanvasElement])
        /// Drawing a rectangle, diamond, or ellipse.
        case create(id: String, start: CGPoint)
        /// Drawing a line or arrow by dragging. Turns into point-by-point
        /// drawing when released without moving.
        case linear(id: String, screen: CGPoint, moved: Bool)
        /// Dragging one point of the selected line.
        case point(id: String, index: Int)
        case freedraw(id: String)
        case erase
    }

    /// Movement in screen points before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    func screenPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textEditing != nil {
            // A click outside the text being edited finishes it, like
            // Excalidraw. The click does nothing else.
            commitTextEditing()
            return
        }

        let screen = screenPoint(event)
        lastPointer = screen
        let scene = viewport.toScene(screen)

        if spaceHeld || editor.tool == .hand {
            drag = .pan(start: screen, offset: viewport.offset)
            NSCursor.closedHand.set()
            return
        }

        if let id = multipoint {
            continueMultipoint(id, at: scene, finish: event.clickCount >= 2)
            return
        }

        guard editor.isEditable || editor.tool == .selection else { return }

        switch editor.tool {
        case .selection: selectionDown(at: scene, screen: screen, event: event)
        case .rectangle, .diamond, .ellipse: beginShape(at: scene)
        case .arrow, .line: beginLinear(at: scene, screen: screen)
        case .freedraw: beginFreedraw(at: scene)
        case .text: textToolClick(at: scene)
        case .eraser:
            drag = .erase
            erase(at: scene)
        case .hand: break
        }
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let screen = screenPoint(event)
        lastPointer = screen
        let scene = viewport.toScene(screen)
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)

        switch drag {
        case .none:
            break

        case let .pan(start, offset):
            var next = viewport
            next.offset = CGPoint(x: offset.x + screen.x - start.x, y: offset.y + screen.y - start.y)
            viewport = next

        case let .press(start, pressScreen, _, duplicate):
            guard hypot(screen.x - pressScreen.x, screen.y - pressScreen.y) >= Self.dragThreshold else { return }
            beginMove(from: start, duplicate: duplicate || alt)
            updateMove(to: scene, axisLock: shift)

        case .move:
            updateMove(to: scene, axisLock: shift)

        case let .marquee(start, _, base):
            drag = .marquee(start: start, current: scene, base: base)
            updateMarquee()

        case let .resize(handle, frame, grab, originals):
            let pointer = CGPoint(x: scene.x - grab.dx, y: scene.y - grab.dy)
            updateResize(handle: handle, frame: frame, originals: originals, pointer: pointer, keepAspect: shift, fromCenter: alt)

        case let .rotate(center, start, originals):
            let rotated = CanvasTransform.rotate(originals, center: center, from: start, to: scene, snap: shift)
            replace(rotated)

        case let .create(id, start):
            updateShape(id, from: start, to: scene, square: shift, fromCenter: alt)

        case let .linear(id, pressScreen, moved):
            if !moved && hypot(screen.x - pressScreen.x, screen.y - pressScreen.y) < Self.dragThreshold { return }
            drag = .linear(id: id, screen: pressScreen, moved: true)
            setLastPoint(of: id, to: scene, snap: shift)
            updateBindingHighlight(for: id, at: scene)

        case let .point(id, index):
            movePoint(index, of: id, to: scene, snap: shift)
            if let element = editor.element(id), index == 0 || index == element.points.count - 1 {
                updateBindingHighlight(for: id, at: scene)
            }

        case let .freedraw(id):
            appendFreedrawPoint(id, at: scene)

        case .erase:
            erase(at: scene)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let screen = screenPoint(event)
        let scene = viewport.toScene(screen)
        let current = drag
        drag = .none

        switch current {
        case .none:
            break

        case .pan:
            updateCursor(at: screen)

        case let .press(_, _, deselect, _):
            if let deselect {
                let group = CanvasOps.expandGroups([deselect], in: editor.document)
                editor.select(editor.selection.subtracting(group))
            }

        case .move:
            // Dropped into a frame or dragged out of one, as in Excalidraw.
            let moved = CanvasOps.withBoundText(editor.selection, in: editor.document)
            editor.updateInteraction { CanvasOps.updateFrameMembership(of: moved, pointer: scene, in: &$0) }
            editor.endInteraction()

        case .resize, .rotate:
            editor.endInteraction()

        case .marquee:
            break

        case let .create(id, _):
            finishShape(id)

        case let .linear(id, _, moved):
            if moved {
                finishLinear(id)
            } else {
                // A click without dragging draws point by point.
                multipoint = id
                setLastPoint(of: id, to: scene, snap: false)
            }

        case let .point(id, index):
            finishPointDrag(id, index: index)

        case let .freedraw(id):
            appendFreedrawPoint(id, at: scene, force: true)
            editor.updateInteraction { CanvasOps.updateFrameMembership(of: [id], pointer: scene, in: &$0) }
            editor.setInteractionSelection([])
            editor.endInteraction()
            if !editor.toolLocked && editor.tool != .freedraw { editor.tool = .selection }

        case .erase:
            let ids = erasing
            erasing = []
            if !ids.isEmpty {
                editor.perform(select: editor.selection.subtracting(ids)) { document in
                    CanvasOps.delete(ids, in: &document)
                }
            }
        }
        bindingHighlight = nil
        overlay.needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let screen = screenPoint(event)
        lastPointer = screen
        if let id = multipoint {
            let scene = viewport.toScene(screen)
            setLastPoint(of: id, to: scene, snap: event.modifierFlags.contains(.shift))
            updateBindingHighlight(for: id, at: scene)
        }
        updateCursor(at: screen)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let scene = viewport.toScene(screenPoint(event))
        lastPointer = screenPoint(event)
        if let hit = element(at: scene), !editor.selection.contains(hit.id) {
            editor.select(CanvasOps.expandGroups([hit.id], in: editor.document))
        }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        let screen = screenPoint(event)
        drag = .pan(start: screen, offset: viewport.offset)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        drag = .none
        updateCursor(at: screenPoint(event))
    }

    // MARK: Scroll and zoom

    override func scrollWheel(with event: NSEvent) {
        let screen = screenPoint(event)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            zoom(by: exp(Double(delta) * 0.01), around: screen)
            return
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        var next = viewport
        next.offset = CGPoint(
            x: viewport.offset.x + event.scrollingDeltaX * scale,
            y: viewport.offset.y + event.scrollingDeltaY * scale)
        viewport = next
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Double(event.magnification), around: screenPoint(event))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(viewport.zoom - 1) < 0.01 {
            fitToContent()
        } else {
            var next = viewport
            next.zoom(to: 1, around: screenPoint(event))
            viewport = next
        }
    }

    // MARK: Cursor

    func updateCursor(at screen: CGPoint) {
        if spaceHeld || editor.tool == .hand {
            NSCursor.openHand.set()
            return
        }
        switch editor.tool {
        case .selection:
            if handle(at: screen) != nil || linearPoint(at: screen) != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        case .text:
            NSCursor.iBeam.set()
        case .eraser:
            NSCursor.pointingHand.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    // MARK: Selection tool

    private func selectionDown(at scene: CGPoint, screen: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)

        if event.clickCount >= 2 {
            doubleClick(at: scene)
            return
        }

        if !shift, let (element, index) = linearPoint(at: screen) {
            editor.beginInteraction()
            drag = .point(id: element.id, index: index)
            return
        }

        if !shift, editor.isEditable, let (handle, frame) = handle(at: screen) {
            editor.beginInteraction()
            if handle == .rotation {
                drag = .rotate(center: frame.center, start: scene, originals: frame.elements)
            } else {
                let anchor = handleAnchor(handle, in: frame)
                let grab = CGVector(dx: scene.x - anchor.x, dy: scene.y - anchor.y)
                drag = .resize(handle: handle, frame: frame, grab: grab, originals: frame.elements)
            }
            return
        }

        let hit = element(at: scene)
        if let hit {
            let group = CanvasOps.expandGroups([hit.id], in: editor.document)
            var deselect: String?
            if shift {
                if editor.selection.contains(hit.id) {
                    deselect = hit.id
                } else {
                    editor.select(editor.selection.union(group))
                }
            } else if !editor.selection.contains(hit.id) {
                editor.select(group)
            }
            drag = .press(start: scene, screen: screen, deselect: deselect, duplicate: alt)
            return
        }

        // Inside the selection's box: drag it, even where a transparent
        // shape has no fill to grab.
        if !shift, !editor.selection.isEmpty, isInsideSelection(scene) {
            drag = .press(start: scene, screen: screen, deselect: nil, duplicate: alt)
            return
        }

        let base = shift ? editor.selection : []
        if !shift { editor.clearSelection() }
        drag = .marquee(start: scene, current: scene, base: base)
    }

    private func doubleClick(at scene: CGPoint) {
        guard editor.isEditable else { return }
        if let hit = element(at: scene) ?? textContainer(at: scene) {
            switch hit.type {
            case .text:
                beginTextEditing(existing: hit.id)
            case .rectangle, .diamond, .ellipse, .arrow, .line:
                beginTextEditing(container: hit.id, at: scene)
            default:
                break
            }
            return
        }
        beginTextEditing(newAt: scene)
    }

    private func textToolClick(at scene: CGPoint) {
        if let hit = element(at: scene) ?? textContainer(at: scene) {
            if hit.type == .text {
                beginTextEditing(existing: hit.id)
                return
            }
            if hit.type.isContainer || hit.type.isLinear {
                beginTextEditing(container: hit.id, at: scene)
                return
            }
        }
        beginTextEditing(newAt: scene)
    }

    /// The topmost shape whose inside contains `scene`, filled or not.
    /// Excalidraw labels a transparent shape when you double-click inside it.
    private func textContainer(at scene: CGPoint) -> CanvasElement? {
        editor.document.elements.last { element in
            element.type.isContainer && !element.locked
                && element.outlinePath.contains(element.toLocal(scene))
        }
    }

    // MARK: Move

    private func beginMove(from start: CGPoint, duplicate: Bool) {
        guard editor.isEditable else {
            drag = .none
            return
        }
        editor.beginInteraction()
        if duplicate {
            let ids = editor.selection
            var made: Set<String> = []
            editor.updateInteraction { document in
                made = CanvasOps.duplicate(ids, in: &document, offset: .zero)
            }
            editor.setInteractionSelection(made)
        }

        let document = editor.document
        let movable = CanvasOps.withFrameChildren(editor.selection, in: document)
        var originals: [String: CanvasElement] = [:]
        for element in document.elements where movable.contains(element.id) && !element.locked {
            originals[element.id] = element
        }
        let ids = Set(originals.keys)
        editor.updateInteraction { document in
            CanvasOps.unbindMovedLines(ids, in: &document)
        }
        // Unbinding changed versions: take the originals again.
        for element in editor.document.elements where ids.contains(element.id) {
            originals[element.id] = element
        }
        drag = .move(start: start, originals: originals)
    }

    private func updateMove(to scene: CGPoint, axisLock: Bool) {
        guard case let .move(start, originals) = drag else { return }
        var dx = scene.x - start.x, dy = scene.y - start.y
        if axisLock {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        let ids = Set(originals.keys)
        editor.updateInteraction { document in
            for i in document.elements.indices {
                guard let original = originals[document.elements[i].id] else { continue }
                var element = document.elements[i]
                element.x = original.x + Double(dx)
                element.y = original.y + Double(dy)
                CanvasOps.touch(&element)
                document.elements[i] = element
            }
            CanvasOps.updateRelations(changed: ids, in: &document)
        }
    }

    // MARK: Marquee

    private func updateMarquee() {
        guard case let .marquee(start, current, base) = drag else { return }
        let rect = CanvasGeometry.normalizedRect(start, current)
        let document = editor.document
        let positions = CanvasOps.index(document)
        var inside = Set<String>()
        for element in document.elements where !element.locked && !CanvasOps.isBoundText(element, positions: positions) {
            if element.isInside(rect) { inside.insert(element.id) }
        }
        editor.select(base.union(CanvasOps.expandGroups(inside, in: document)))
        overlay.needsDisplay = true
    }

    // MARK: Resize and rotate

    private func updateResize(
        handle: CanvasTransform.Handle,
        frame: SelectionFrame,
        originals: [CanvasElement],
        pointer: CGPoint,
        keepAspect: Bool,
        fromCenter: Bool
    ) {
        if originals.count == 1 {
            replace([CanvasTransform.resize(originals[0], handle: handle, to: pointer, keepAspect: keepAspect, fromCenter: fromCenter)])
        } else {
            replace(CanvasTransform.resizeGroup(originals, box: frame.box, handle: handle, to: pointer, fromCenter: fromCenter))
        }
    }

    /// Puts transformed elements into the document during an interaction.
    private func replace(_ elements: [CanvasElement]) {
        let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        let ids = Set(byID.keys)
        editor.updateInteraction { document in
            for i in document.elements.indices {
                guard var element = byID[document.elements[i].id] else { continue }
                CanvasOps.touch(&element)
                document.elements[i] = element
            }
            CanvasOps.updateRelations(changed: ids, in: &document)
        }
    }

    // MARK: Shapes

    private func beginShape(at scene: CGPoint) {
        guard let type = editor.tool.elementType else { return }
        var element = CanvasElement(type: type)
        editor.style.apply(to: &element)
        element.x = Double(scene.x)
        element.y = Double(scene.y)
        editor.beginInteraction()
        editor.setInteractionSelection([])
        editor.updateInteraction { $0.elements.append(element) }
        drag = .create(id: element.id, start: scene)
    }

    private func updateShape(_ id: String, from start: CGPoint, to scene: CGPoint, square: Bool, fromCenter: Bool) {
        var dx = scene.x - start.x, dy = scene.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect: CGRect
        if fromCenter {
            rect = CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        } else {
            rect = CanvasGeometry.normalizedRect(start, CGPoint(x: start.x + dx, y: start.y + dy))
        }
        editor.updateInteraction { document in
            CanvasOps.update(id, in: &document) { element in
                element.x = Double(rect.minX)
                element.y = Double(rect.minY)
                element.width = Double(rect.width)
                element.height = Double(rect.height)
            }
        }
    }

    private func finishShape(_ id: String) {
        guard let element = editor.element(id), element.width >= 1, element.height >= 1 else {
            // A click without a drag draws nothing, like Excalidraw.
            editor.cancelInteraction()
            return
        }
        // Drawn over a frame: it belongs to the frame.
        editor.updateInteraction { CanvasOps.updateFrameMembership(of: [id], pointer: element.center, in: &$0) }
        editor.setInteractionSelection([id])
        editor.endInteraction()
        if !editor.toolLocked { editor.tool = .selection }
    }

    // MARK: Lines and arrows

    private func beginLinear(at scene: CGPoint, screen: CGPoint) {
        guard let type = editor.tool.elementType else { return }
        var element = CanvasElement(type: type)
        editor.style.apply(to: &element)
        element.x = Double(scene.x)
        element.y = Double(scene.y)
        element.points = [.zero, .zero]
        editor.beginInteraction()
        editor.setInteractionSelection([])
        editor.updateInteraction { $0.elements.append(element) }
        drag = .linear(id: element.id, screen: screen, moved: false)
    }

    /// Moves the last point of a line, snapping to 15° steps when asked.
    private func setLastPoint(of id: String, to scene: CGPoint, snap: Bool) {
        guard let element = editor.element(id), element.points.count >= 2 else { return }
        movePoint(element.points.count - 1, of: id, to: scene, snap: snap)
    }

    private func movePoint(_ index: Int, of id: String, to scene: CGPoint, snap: Bool) {
        guard let element = editor.element(id), element.points.indices.contains(index) else { return }
        var points = element.points.map(element.toScene)
        var target = scene
        if snap, points.count > 1 {
            let anchor = points[index == 0 ? 1 : index - 1]
            let angle = CanvasGeometry.snapAngle(atan2(scene.dy - anchor.dy, scene.dx - anchor.dx))
            let length = hypot(scene.dx - anchor.dx, scene.dy - anchor.dy)
            target = CGPoint(x: anchor.dx + cos(angle) * length, y: anchor.dy + sin(angle) * length)
        }
        points[index] = target
        editor.updateInteraction { document in
            CanvasOps.update(id, in: &document) { CanvasOps.setScenePoints(points, of: &$0) }
            CanvasOps.updateRelations(changed: [id], in: &document)
        }
    }

    /// The shape an arrow end at `scene` would attach to.
    private func bindingTarget(for id: String, at scene: CGPoint) -> CanvasElement? {
        guard let element = editor.element(id), element.type == .arrow else { return nil }
        return CanvasBinder.target(at: scene, in: editor.document, excluding: [id], zoom: viewport.zoom)
    }

    private func updateBindingHighlight(for id: String, at scene: CGPoint) {
        let target = bindingTarget(for: id, at: scene)?.id
        if target != bindingHighlight {
            bindingHighlight = target
            overlay.needsDisplay = true
        }
    }

    private func continueMultipoint(_ id: String, at scene: CGPoint, finish: Bool) {
        guard let element = editor.element(id) else {
            multipoint = nil
            return
        }
        let points = element.points.map(element.toScene)
        let committed = points.count >= 2 ? points[points.count - 2] : points[0]
        let near = hypot(scene.dx - committed.dx, scene.dy - committed.dy) * viewport.zoom < CanvasGeometry.lineConfirmThreshold
        if finish || near {
            finishLinear(id)
            return
        }
        // Commit the floating point and start a new one.
        var next = points
        next[next.count - 1] = scene
        next.append(scene)
        editor.updateInteraction { document in
            CanvasOps.update(id, in: &document) { CanvasOps.setScenePoints(next, of: &$0) }
        }
    }

    /// Finishes the line being drawn: drops the floating point, binds the
    /// ends of arrows, and selects it.
    func finishLinear(_ id: String) {
        let wasMultipoint = multipoint == id
        multipoint = nil
        bindingHighlight = nil
        guard var element = editor.element(id) else {
            editor.endInteraction()
            return
        }

        var points = element.points.map(element.toScene)
        if wasMultipoint, points.count > 2 {
            // The last point follows the pointer: drop it.
            points.removeLast()
        }
        let length = zip(points, points.dropFirst()).reduce(0.0) { $0 + hypot($1.1.dx - $1.0.dx, $1.1.dy - $1.0.dy) }
        guard points.count >= 2, length * viewport.zoom >= 1 else {
            editor.cancelInteraction()
            return
        }

        editor.updateInteraction { document in
            CanvasOps.update(id, in: &document) { CanvasOps.setScenePoints(points, of: &$0) }
        }
        element = editor.element(id) ?? element

        if element.type == .arrow {
            bindEnds(of: id, points: points)
        }
        // A line drawn starting in a frame belongs to it, as in Excalidraw.
        if let start = points.first {
            editor.updateInteraction { CanvasOps.updateFrameMembership(of: [id], pointer: start, in: &$0) }
        }

        editor.setInteractionSelection([id])
        editor.endInteraction()
        if !editor.toolLocked { editor.tool = .selection }
    }

    private func bindEnds(of id: String, points: [CGPoint]) {
        let last = points.count - 1
        let document = editor.document
        let zoom = viewport.zoom
        let startTarget = CanvasBinder.target(at: points[0], in: document, excluding: [id], zoom: zoom)
        var endTarget = CanvasBinder.target(at: points[last], in: document, excluding: [id], zoom: zoom)
        // A two-point arrow from a shape to itself can't point anywhere.
        if points.count == 2, endTarget?.id == startTarget?.id { endTarget = nil }

        editor.updateInteraction { document in
            let startFocus = startTarget.map { CanvasBinder.focus(element: $0, adjacent: points[1], end: points[0]) } ?? 0
            let endFocus = endTarget.map { CanvasBinder.focus(element: $0, adjacent: points[last - 1], end: points[last]) } ?? 0
            CanvasOps.bind(id, end: .start, to: startTarget?.id, focus: startFocus, in: &document)
            CanvasOps.bind(id, end: .end, to: endTarget?.id, focus: endFocus, in: &document)
            CanvasOps.updateRelations(changed: [id], in: &document)
        }
    }

    private func finishPointDrag(_ id: String, index: Int) {
        if let element = editor.element(id), element.type == .arrow,
           index == 0 || index == element.points.count - 1 {
            let points = element.points.map(element.toScene)
            let end: CanvasShapeBuilder.ArrowEnd = index == 0 ? .start : .end
            let other = end == .start ? element.endBinding?.elementId : element.startBinding?.elementId
            var target = CanvasBinder.target(at: points[index], in: editor.document, excluding: [id], zoom: viewport.zoom)
            if points.count == 2, target?.id == other { target = nil }
            let adjacent = points[index == 0 ? 1 : index - 1]
            let focus = target.map { CanvasBinder.focus(element: $0, adjacent: adjacent, end: points[index]) } ?? 0
            editor.updateInteraction { document in
                CanvasOps.bind(id, end: end, to: target?.id, focus: focus, in: &document)
                CanvasOps.updateRelations(changed: [id], in: &document)
            }
        }
        editor.endInteraction()
    }

    // MARK: Freehand

    private func beginFreedraw(at scene: CGPoint) {
        var element = CanvasElement(type: .freedraw)
        editor.style.apply(to: &element)
        element.x = Double(scene.x)
        element.y = Double(scene.y)
        element.points = [.zero]
        element.simulatePressure = true
        editor.beginInteraction()
        editor.setInteractionSelection([])
        editor.updateInteraction { $0.elements.append(element) }
        drag = .freedraw(id: element.id)
    }

    private func appendFreedrawPoint(_ id: String, at scene: CGPoint, force: Bool = false) {
        guard let element = editor.element(id) else { return }
        let local = CGPoint(x: scene.dx - element.x, y: scene.dy - element.y)
        if let last = element.points.last,
           hypot(local.dx - last.dx, local.dy - last.dy) * viewport.zoom < (force ? 0.01 : 1) {
            return
        }
        editor.updateInteraction { document in
            CanvasOps.update(id, in: &document) { element in
                element.points.append(local)
                let box = CanvasGeometry.bounds(of: element.points)
                element.width = Double(box.width)
                element.height = Double(box.height)
            }
        }
    }

    // MARK: Eraser

    private func erase(at scene: CGPoint) {
        guard let hit = element(at: scene) else { return }
        let group = CanvasOps.withBoundText(CanvasOps.expandGroups([hit.id], in: editor.document), in: editor.document)
        if !group.isSubset(of: erasing) {
            erasing.formUnion(group)
        }
    }

    // MARK: Tool changes

    /// Finishes anything in progress before the tool changes.
    func toolWillChange() {
        if let id = multipoint { finishLinear(id) }
        if textEditing != nil { commitTextEditing() }
    }
}
