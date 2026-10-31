import CoreGraphics
import Foundation
import Testing
@testable import Nubb

/// Undo, the three-way merge, and the document edits the editor builds on.
@Suite
struct CanvasEditingTests {
    static func rect(_ id: String, x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 60) -> CanvasElement {
        var element = CanvasElement(id: id, type: .rectangle)
        element.x = x
        element.y = y
        element.width = width
        element.height = height
        element.seed = 1
        element.versionNonce = 1
        element.updated = 0
        return element
    }

    static func arrow(_ id: String, from start: CGPoint, to end: CGPoint) -> CanvasElement {
        var element = CanvasElement(id: id, type: .arrow)
        element.x = start.dx
        element.y = start.dy
        element.points = [.zero, CGPoint(x: end.dx - start.dx, y: end.dy - start.dy)]
        CanvasOps.normalizePoints(&element)
        return element
    }

    // MARK: History

    @Test @MainActor func undoAndRedoRestoreTheDrawing() {
        let editor = CanvasEditor(document: CanvasDocument(elements: [Self.rect("a")]))
        let start = editor.document

        editor.perform { document in
            CanvasOps.update("a", in: &document) { $0.x = 50 }
            document.elements.append(Self.rect("b", x: 200))
        }
        let edited = editor.document
        #expect(editor.canUndo)

        editor.undo()
        #expect(editor.document == start)
        #expect(editor.canRedo)

        editor.redo()
        #expect(editor.document == edited)
    }

    @Test @MainActor func interactionIsOneUndoStep() {
        let editor = CanvasEditor(document: CanvasDocument(elements: [Self.rect("a")]))
        editor.beginInteraction()
        for step in 1...20 {
            editor.updateInteraction { document in
                CanvasOps.update("a", in: &document) { $0.x = Double(step) }
            }
        }
        editor.endInteraction()
        #expect(editor.history.undoStack.count == 1)
        editor.undo()
        #expect(editor.document.elements[0].x == 0)
    }

    @Test @MainActor func cancelledInteractionLeavesNoTrace() {
        let editor = CanvasEditor(document: CanvasDocument(elements: [Self.rect("a")]))
        let start = editor.document
        editor.beginInteraction()
        editor.updateInteraction { $0.elements.append(Self.rect("b")) }
        editor.cancelInteraction()
        #expect(editor.document == start)
        #expect(!editor.canUndo)
    }

    @Test @MainActor func undoKeepsChangesMergedFromTheFile() {
        let editor = CanvasEditor(document: CanvasDocument(elements: [Self.rect("a")]))
        editor.perform { document in CanvasOps.update("a", in: &document) { $0.x = 10 } }

        // An agent adds an element to the file.
        var merged = editor.document
        merged.elements.append(Self.rect("agent", x: 300))
        editor.applyExternal(merged)

        editor.undo()
        #expect(editor.document.elements.first { $0.id == "a" }?.x == 0)
        #expect(editor.document.elements.contains { $0.id == "agent" }, "undo only reverts the user's own edits")
    }

    @Test @MainActor func readOnlyEditorRefusesChanges() {
        let editor = CanvasEditor(document: CanvasDocument(elements: [Self.rect("a")]))
        editor.isEditable = false
        editor.perform { $0.elements.removeAll() }
        #expect(editor.document.elements.count == 1)
    }

    @Test func historyIsCapped() {
        var history = CanvasHistory()
        let a = CanvasDocument(elements: [Self.rect("a")])
        var b = a
        b.elements[0].x = 1
        for _ in 0..<(CanvasHistory.limit + 50) {
            history.record(CanvasHistory.diff(from: a, to: b, selectionBefore: [], selectionAfter: [])!)
        }
        #expect(history.undoStack.count == CanvasHistory.limit)
    }

    @Test @MainActor func sliderDragIsOneUndoStep() {
        var start = Self.rect("a")
        start.opacity = 100
        let editor = CanvasEditor(document: CanvasDocument(elements: [start, Self.rect("b", x: 300)]))
        editor.select(["a"])

        // Dragging the opacity slider reports every tick.
        for value in stride(from: 90.0, through: 30, by: -10) {
            editor.applyStyle(coalescing: "opacity") { $0.opacity = value }
        }
        #expect(editor.history.undoStack.count == 1)
        #expect(editor.document.elements[0].opacity == 30)

        // A different control is its own step.
        editor.applyStyle { $0.strokeColor = "#e03131" }
        #expect(editor.history.undoStack.count == 2)
        editor.applyStyle(coalescing: "opacity") { $0.opacity = 20 }
        #expect(editor.history.undoStack.count == 3)

        editor.undo()
        editor.undo()
        editor.undo()
        #expect(editor.document.elements[0].opacity == 100)
        #expect(editor.document.elements[0].strokeColor == start.strokeColor)

        // A new selection starts a new step even with the same key.
        editor.redo()
        editor.redo()
        editor.redo()
        editor.select(["b"])
        editor.applyStyle(coalescing: "opacity") { $0.opacity = 50 }
        #expect(editor.history.undoStack.count == 4)
    }

    @Test func coalescingStopsAfterAPause() {
        var history = CanvasHistory()
        let a = CanvasDocument(elements: [Self.rect("a")])
        var b = a
        b.elements[0].x = 1
        var c = b
        c.elements[0].x = 2
        let now = Date()
        history.record(CanvasHistory.diff(from: a, to: b, selectionBefore: [], selectionAfter: [])!, coalescing: "k", at: now)
        history.record(
            CanvasHistory.diff(from: b, to: c, selectionBefore: [], selectionAfter: [])!,
            coalescing: "k", at: now.addingTimeInterval(CanvasHistory.coalescingWindow + 0.1))
        #expect(history.undoStack.count == 2)

        // Combined steps keep the first before and the last after.
        let combined = CanvasHistory.combine(history.undoStack[0], history.undoStack[1])
        #expect(combined.before["a"]??.x == 0)
        #expect(combined.after["a"]??.x == 2)
    }

    // MARK: Merge

    @Test func mergeTakesEachSidesEdits() {
        let base = CanvasDocument(elements: [Self.rect("a"), Self.rect("b", x: 200)])
        var local = base
        CanvasOps.update("a", in: &local) { $0.x = 10 }
        var remote = base
        CanvasOps.update("b", in: &remote) { $0.x = 210 }
        remote.elements.append(Self.rect("c", x: 400))

        let merged = CanvasMerge.merge(base: base, local: local, remote: remote)
        #expect(merged.elements.map(\.id) == ["a", "b", "c"])
        #expect(merged.element(id: "a")?.x == 10)
        #expect(merged.element(id: "b")?.x == 210)
    }

    @Test func mergeConflictTakesHigherVersion() {
        let base = CanvasDocument(elements: [Self.rect("a")])
        var local = base
        CanvasOps.update("a", in: &local) { $0.x = 10 }
        var remote = base
        CanvasOps.update("a", in: &remote) { $0.x = 20 }
        CanvasOps.update("a", in: &remote) { $0.y = 20 }
        #expect(CanvasMerge.merge(base: base, local: local, remote: remote).element(id: "a")?.x == 20)

        // Equal versions: the open drawing wins.
        var remoteOnce = base
        CanvasOps.update("a", in: &remoteOnce) { $0.x = 30 }
        #expect(CanvasMerge.merge(base: base, local: local, remote: remoteOnce).element(id: "a")?.x == 10)
    }

    @Test func mergeDeletesAndKeepsEditedDeletes() {
        let base = CanvasDocument(elements: [Self.rect("a"), Self.rect("b")])
        var remote = base
        remote.elements.removeAll { $0.id == "b" }
        let merged = CanvasMerge.merge(base: base, local: base, remote: remote)
        #expect(merged.elements.map(\.id) == ["a"])

        // Deleted remotely but edited locally: the edit survives.
        var local = base
        CanvasOps.update("b", in: &local) { $0.x = 5 }
        #expect(CanvasMerge.merge(base: base, local: local, remote: remote).element(id: "b") != nil)
    }

    @Test func mergeKeepsRemoteReorder() {
        let base = CanvasDocument(elements: [Self.rect("a"), Self.rect("b"), Self.rect("c")])
        var remote = base
        remote.elements.reverse()
        var local = base
        local.elements.append(Self.rect("d"))
        let merged = CanvasMerge.merge(base: base, local: local, remote: remote)
        #expect(merged.elements.map(\.id) == ["c", "b", "a", "d"], "the user's new topmost element stays on top")

        // A new element in the middle goes right above its neighbor below.
        var middle = base
        middle.elements.insert(Self.rect("m"), at: 1)
        #expect(CanvasMerge.merge(base: base, local: middle, remote: remote).elements.map(\.id) == ["c", "b", "a", "m"])
    }

    // MARK: Ops

    @Test func deleteTakesLabelAndUnbinds() {
        var container = Self.rect("box")
        container.addBoundElement(id: "label", type: "text")
        container.addBoundElement(id: "arr", type: "arrow")
        var label = CanvasElement(id: "label", type: .text)
        label.containerId = "box"
        var arrow = Self.arrow("arr", from: CGPoint(x: 300, y: 30), to: CGPoint(x: 120, y: 30))
        arrow.endBinding = CanvasBinding(elementId: "box", gap: 6)
        var document = CanvasDocument(elements: [container, label, arrow])

        CanvasOps.delete(["box"], in: &document)
        #expect(document.elements.map(\.id) == ["arr"])
        #expect(document.elements[0].endBinding == nil)
    }

    @Test func duplicateRemapsBindingsAndGroups() {
        var a = Self.rect("a")
        a.groupIds = ["g"]
        a.addBoundElement(id: "arr", type: "arrow")
        var b = Self.rect("b", x: 300)
        b.groupIds = ["g"]
        b.addBoundElement(id: "arr", type: "arrow")
        var arrow = Self.arrow("arr", from: CGPoint(x: 110, y: 30), to: CGPoint(x: 290, y: 30))
        arrow.groupIds = ["g"]
        arrow.startBinding = CanvasBinding(elementId: "a", gap: 6)
        arrow.endBinding = CanvasBinding(elementId: "b", gap: 6)
        var document = CanvasDocument(elements: [a, b, arrow])

        let made = CanvasOps.duplicate(["a", "b", "arr"], in: &document, offset: CGVector(dx: 10, dy: 10))
        #expect(made.count == 3)
        #expect(document.elements.count == 6)
        let copies = document.elements.filter { made.contains($0.id) }
        let copyArrow = copies.first { $0.type == .arrow }!
        #expect(made.contains(copyArrow.startBinding!.elementId))
        #expect(made.contains(copyArrow.endBinding!.elementId))
        #expect(Set(copies.flatMap(\.groupIds)).count == 1)
        #expect(copies[0].groupIds != ["g"])
        #expect(copies.allSatisfy { $0.seed != 1 })
    }

    @Test func reorderMovesAndKeepsLabelsOnTop() {
        var box = Self.rect("box")
        box.addBoundElement(id: "label", type: "text")
        var label = CanvasElement(id: "label", type: .text)
        label.containerId = "box"
        var document = CanvasDocument(elements: [box, label, Self.rect("x"), Self.rect("y")])

        CanvasOps.reorder(["box"], .front, in: &document)
        #expect(document.elements.map(\.id) == ["x", "y", "box", "label"])
        CanvasOps.reorder(["box"], .backward, in: &document)
        #expect(document.elements.map(\.id) == ["x", "box", "label", "y"])
        CanvasOps.reorder(["box"], .back, in: &document)
        #expect(document.elements.map(\.id) == ["box", "label", "x", "y"])
        CanvasOps.reorder(["box"], .forward, in: &document)
        #expect(document.elements.map(\.id) == ["x", "box", "label", "y"])
    }

    @Test func groupAndUngroup() {
        var document = CanvasDocument(elements: [Self.rect("a"), Self.rect("b"), Self.rect("c")])
        CanvasOps.group(["a", "b"], in: &document)
        #expect(CanvasOps.expandGroups(["a"], in: document) == ["a", "b"])
        CanvasOps.ungroup(["a"], in: &document)
        #expect(CanvasOps.expandGroups(["a"], in: document) == ["a"])
    }

    @Test func boundArrowFollowsItsShape() {
        let box = Self.rect("box", x: 200, y: 0, width: 100, height: 100)
        let arrow = Self.arrow("arr", from: CGPoint(x: 0, y: 50), to: CGPoint(x: 194, y: 50))
        var document = CanvasDocument(elements: [box, arrow])
        CanvasOps.bind("arr", end: .end, to: "box", in: &document)
        #expect(document.element(id: "box")?.boundElements?.contains { $0.id == "arr" } == true)

        CanvasOps.update("box", in: &document) { $0.y = 100 }
        CanvasOps.updateRelations(changed: ["box"], in: &document)
        let moved = document.element(id: "arr")!
        let end = moved.toScene(moved.points.last!)
        let target = document.element(id: "box")!
        // The end stays the binding gap away from the moved box's outline.
        #expect(end.dy > 100, "the arrow end moved down with the box")
        let distance = CanvasGeometry.distance(end, toSegment: CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 200))
        let toTop = CanvasGeometry.distance(end, toSegment: CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100))
        #expect(min(distance, toTop) < CanvasBinder.defaultGap + 1)
        #expect(!target.outlinePath.contains(target.toLocal(end)))
    }

    @Test func bindingFocusKeepsTheAim() {
        let box = Self.rect("box", x: 0, y: 0, width: 100, height: 100)
        // Aimed at the upper half of the box's left side.
        let focus = CanvasBinder.focus(element: box, adjacent: CGPoint(x: -200, y: 25), end: CGPoint(x: -6, y: 25))
        #expect(focus < 0 || focus > 0)
        let point = CanvasBinder.focusPoint(element: box, focus: focus, adjacent: CGPoint(x: -200, y: 25))
        #expect(abs(point.dy - 25) < 1, "the focus point lies on the drawn line")
        #expect(CanvasBinder.focus(element: box, adjacent: CGPoint(x: -200, y: 50), end: CGPoint(x: -6, y: 50)) == 0)
    }

    @Test func labelGrowsItsContainer() {
        var box = Self.rect("box", width: 100, height: 40)
        var label = CanvasElement(id: "label", type: .text)
        label.containerId = "box"
        label.textAlign = "center"
        label.verticalAlign = "middle"
        label.text = "one\ntwo\nthree\nfour"
        label.originalText = label.text
        CanvasOps.layoutLabel(&label, container: box)
        #expect(CanvasOps.growToFit(&box, label: label))
        #expect(box.height >= label.height + CanvasGeometry.boundTextPadding * 2)
        CanvasOps.layoutLabel(&label, container: box)
        #expect(label.y >= box.y && label.y + label.height <= box.y + box.height + 0.5)
        #expect(abs((label.x + label.width / 2) - (box.x + box.width / 2)) < 1, "centered")
    }

    // MARK: Transform

    @Test func resizeFromCornerAnchorsOppositeCorner() {
        let box = Self.rect("a", x: 10, y: 20, width: 100, height: 50)
        let resized = CanvasTransform.resize(box, handle: .bottomRight, to: CGPoint(x: 210, y: 120), keepAspect: false, fromCenter: false)
        #expect(resized.x == 10 && resized.y == 20)
        #expect(resized.width == 200 && resized.height == 100)

        let flipped = CanvasTransform.resize(box, handle: .bottomRight, to: CGPoint(x: 0, y: 0), keepAspect: false, fromCenter: false)
        #expect(flipped.x == 0 && flipped.y == 0)
        #expect(flipped.width == 10 && flipped.height == 20)
    }

    @Test func rotateSnapsTo15Degrees() {
        let box = Self.rect("a", x: 0, y: 0, width: 100, height: 100)
        let rotated = CanvasTransform.rotate(
            [box], center: box.center, from: CGPoint(x: 50, y: -50), to: CGPoint(x: 150, y: 40), snap: true)
        let degrees = rotated[0].angle * 180 / .pi
        #expect(abs(degrees.remainder(dividingBy: 15)) < 0.001)
        #expect(abs(rotated[0].center.dx - 50) < 0.001 && abs(rotated[0].center.dy - 50) < 0.001)
    }

    // MARK: Viewport

    @Test func viewportZoomKeepsAnchor() {
        var viewport = CanvasViewport(zoom: 1, offset: CGPoint(x: 30, y: 40))
        let anchor = CGPoint(x: 200, y: 150)
        let before = viewport.toScene(anchor)
        viewport.zoom(to: 2.5, around: anchor)
        let after = viewport.toScene(anchor)
        #expect(abs(before.dx - after.dx) < 1e-9 && abs(before.dy - after.dy) < 1e-9)
        viewport.zoom(to: 1000, around: anchor)
        #expect(viewport.zoom == CanvasViewport.maxZoom)
    }

    @Test func viewportFitsContent() {
        let fitted = CanvasViewport.fitting(CGRect(x: 1000, y: 1000, width: 400, height: 200), in: CGSize(width: 800, height: 600))
        let center = fitted.toScreen(CGPoint(x: 1200, y: 1100))
        #expect(abs(center.dx - 400) < 1e-9 && abs(center.dy - 300) < 1e-9)
        #expect(fitted.zoom == 1, "fits without zooming in past 100%")
    }
}
