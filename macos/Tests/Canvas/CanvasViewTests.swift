import AppKit
import Foundation
import Testing
@testable import Nubb

/// Drives a real `CanvasView` with mouse and key events in a window that is
/// never shown, and renders drawings to check what they look like.
@Suite(.serialized)
@MainActor
struct CanvasViewTests {
    /// A canvas in an offscreen window, at zoom 1 with the scene origin at
    /// the view's top left.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let editor: CanvasEditor
        let canvas: CanvasView

        init(document: CanvasDocument = CanvasDocument()) {
            editor = CanvasEditor(document: document)
            canvas = CanvasView(editor: editor)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            canvas.viewport = CanvasViewport()
            window.makeFirstResponder(canvas)
        }

        /// The window point for a scene point. The canvas is flipped and
        /// fills the window, so window y is measured from the bottom.
        private func windowPoint(_ scene: CGPoint) -> NSPoint {
            let local = canvas.viewport.toScreen(scene)
            return canvas.convert(local, to: nil)
        }

        private func mouse(_ type: NSEvent.EventType, _ scene: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: windowPoint(scene), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        func drag(_ points: [CGPoint], flags: NSEvent.ModifierFlags = []) {
            guard let first = points.first else { return }
            canvas.mouseDown(with: mouse(.leftMouseDown, first, flags: flags))
            for point in points.dropFirst() {
                canvas.mouseDragged(with: mouse(.leftMouseDragged, point, flags: flags))
            }
            canvas.mouseUp(with: mouse(.leftMouseUp, points.last!, flags: flags))
        }

        func click(_ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: mouse(.leftMouseDown, point, clicks: clicks, flags: flags))
            canvas.mouseUp(with: mouse(.leftMouseUp, point, clicks: clicks, flags: flags))
        }

        func move(_ point: CGPoint) {
            canvas.mouseMoved(with: mouse(.mouseMoved, point))
        }

        func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
            canvas.keyDown(with: event)
        }

        func type(_ text: String) {
            canvas.textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: Drawing tools

    /// A filled rectangle, so clicks anywhere inside hit it.
    private static func box(_ id: String, x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 60) -> CanvasElement {
        var element = CanvasEditingTests.rect(id, x: x, y: y, width: width, height: height)
        element.backgroundColor = "#a5d8ff"
        return element
    }

    @Test func drawsRectangleAndSelectsIt() throws {
        let h = Harness()
        h.key("r")
        #expect(h.editor.tool == .rectangle)
        h.drag([CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 140), CGPoint(x: 300, y: 220)])

        let element = try #require(h.editor.document.elements.first)
        #expect(element.type == .rectangle)
        #expect(element.x == 100 && element.y == 100)
        #expect(element.width == 200 && element.height == 120)
        #expect(element.roundness == .adaptive)
        #expect(h.editor.selection == [element.id])
        #expect(h.editor.tool == .selection, "the tool goes back to selection after drawing")
        #expect(h.editor.history.undoStack.count == 1)
    }

    // MARK: Frames

    private static func frame(_ id: String, x: Double, y: Double, width: Double = 300, height: Double = 200) -> CanvasElement {
        var frame = CanvasElement(id: id, type: .frame)
        frame.x = x
        frame.y = y
        frame.width = width
        frame.height = height
        frame.frameName = "Panel"
        return frame
    }

    /// Like Excalidraw: a shape drawn over a frame belongs to it, a box
    /// dragged out of it leaves it, and one dropped into another frame
    /// joins that one. One undo step each.
    @Test func elementsJoinAndLeaveFramesWhenDrawnOrDragged() throws {
        var document = CanvasDocument()
        document.elements = [Self.frame("f1", x: 50, y: 50), Self.frame("f2", x: 450, y: 50)]
        let h = Harness(document: document)

        h.key("r")
        h.drag([CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 140), CGPoint(x: 200, y: 160)])
        let drawn = try #require(h.editor.document.elements.first { $0.type == .rectangle })
        #expect(drawn.frameId == "f1")
        // Its frame sits above it.
        let order = h.editor.document.elements.map(\.id)
        #expect(order.firstIndex(of: drawn.id)! < order.firstIndex(of: "f1")!)

        // Dragged into the other frame.
        h.drag([CGPoint(x: 150, y: 130), CGPoint(x: 300, y: 130), CGPoint(x: 550, y: 130)])
        #expect(h.editor.element(drawn.id)?.frameId == "f2")
        // Out of every frame.
        h.drag([CGPoint(x: 550, y: 130), CGPoint(x: 550, y: 400), CGPoint(x: 550, y: 500)])
        #expect(h.editor.element(drawn.id)?.frameId == nil)
        // Undo puts it back in f2.
        h.editor.undo()
        #expect(h.editor.element(drawn.id)?.frameId == "f2")
    }

    /// Dragging a frame takes its elements along and keeps them in it.
    @Test func draggingAFrameKeepsItsElements() throws {
        var document = CanvasDocument()
        var inside = Self.box("b1", x: 100, y: 100)
        inside.frameId = "f1"
        document.elements = [inside, Self.frame("f1", x: 50, y: 50)]
        let h = Harness(document: document)
        // Grab the frame by its border, then drag it.
        h.click(CGPoint(x: 51, y: 120))
        h.editor.select(["f1"])
        h.drag([CGPoint(x: 51, y: 60), CGPoint(x: 151, y: 60), CGPoint(x: 251, y: 60)])
        let moved = try #require(h.editor.element("b1"))
        #expect(moved.frameId == "f1")
        #expect(moved.x == 300)
    }

    @Test func shiftDrawsSquareAndClickDrawsNothing() {
        let h = Harness()
        h.key("o")
        h.drag([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40)], flags: .shift)
        #expect(h.editor.document.elements.first?.width == h.editor.document.elements.first?.height)

        h.key("d")
        h.click(CGPoint(x: 500, y: 500))
        #expect(h.editor.document.elements.count == 1)
        #expect(!h.editor.isInteracting)
    }

    @Test func toolLockKeepsTool() {
        let h = Harness()
        h.key("r")
        h.key("q")
        h.drag([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)])
        h.drag([CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 50)])
        #expect(h.editor.document.elements.count == 2)
        #expect(h.editor.tool == .rectangle)
    }

    @Test func arrowBindsToShapesAndFollowsThem() throws {
        let h = Harness(document: CanvasDocument(elements: [
            Self.box("left", x: 0, y: 0, width: 100, height: 100),
            Self.box("right", x: 300, y: 0, width: 100, height: 100),
        ]))
        h.key("a")
        h.drag([CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 350, y: 50)])

        let arrow = try #require(h.editor.document.elements.first { $0.type == .arrow })
        #expect(arrow.startBinding?.elementId == "left")
        #expect(arrow.endBinding?.elementId == "right")
        let start = arrow.toScene(arrow.points.first!)
        let end = arrow.toScene(arrow.points.last!)
        #expect(abs(start.dx - (100 + CanvasBinder.defaultGap)) < 1, "starts outside the left box")
        #expect(abs(end.dx - (300 - CanvasBinder.defaultGap)) < 1, "ends outside the right box")
        #expect(h.editor.document.element(id: "left")?.boundElements?.contains { $0.id == arrow.id } == true)

        // Moving the right box drags the arrow end along.
        h.click(CGPoint(x: 350, y: 50))
        h.drag([CGPoint(x: 350, y: 50), CGPoint(x: 350, y: 150), CGPoint(x: 350, y: 250)])
        let moved = try #require(h.editor.document.element(id: arrow.id))
        #expect(moved.toScene(moved.points.last!).dy > 150)
    }

    @Test func clickingDrawsLinePointByPoint() throws {
        let h = Harness()
        h.key("l")
        h.click(CGPoint(x: 0, y: 0))
        h.move(CGPoint(x: 100, y: 0))
        h.click(CGPoint(x: 100, y: 0))
        h.move(CGPoint(x: 100, y: 100))
        h.click(CGPoint(x: 100, y: 100))
        h.key("\r", code: 0x24)

        let line = try #require(h.editor.document.elements.first)
        #expect(line.type == .line)
        #expect(line.points.count == 3)
        #expect(line.toScene(line.points[2]) == CGPoint(x: 100, y: 100))
        #expect(h.editor.history.undoStack.count == 1, "the whole line is one undo step")
    }

    @Test func freehandRecordsPoints() throws {
        let h = Harness()
        h.key("p")
        h.drag((0...20).map { CGPoint(x: Double($0) * 5, y: sin(Double($0) / 3) * 20 + 50) })
        let stroke = try #require(h.editor.document.elements.first)
        #expect(stroke.type == .freedraw)
        #expect(stroke.points.count > 15)
        #expect(stroke.points.first == .zero)
    }

    @Test func eraserDeletesWhatItTouches() {
        let h = Harness(document: CanvasDocument(elements: [
            Self.box("a", x: 0, y: 0), Self.box("b", x: 300, y: 0),
        ]))
        h.key("e")
        h.drag([CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 30)])
        #expect(h.editor.document.elements.map(\.id) == ["b"])
        h.editor.undo()
        #expect(h.editor.document.elements.count == 2)
    }

    // MARK: Selection

    @Test func clickSelectsAndDragMoves() {
        let h = Harness(document: CanvasDocument(elements: [Self.box("a", x: 0, y: 0)]))
        h.drag([CGPoint(x: 50, y: 30), CGPoint(x: 60, y: 40), CGPoint(x: 150, y: 130)])
        #expect(h.editor.selection == ["a"])
        let moved = h.editor.document.elements[0]
        #expect(moved.x == 100 && moved.y == 100)
        h.editor.undo()
        #expect(h.editor.document.elements[0].x == 0)
    }

    @Test func marqueeSelectsEnclosedElements() {
        let h = Harness(document: CanvasDocument(elements: [
            CanvasEditingTests.rect("in", x: 100, y: 100, width: 50, height: 50),
            CanvasEditingTests.rect("out", x: 400, y: 400, width: 50, height: 50),
        ]))
        h.drag([CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 300)])
        #expect(h.editor.selection == ["in"])
    }

    @Test func transparentShapesAreHitByTheirOutline() {
        let h = Harness(document: CanvasDocument(elements: [CanvasEditingTests.rect("a", x: 0, y: 0, width: 200, height: 100)]))
        h.click(CGPoint(x: 100, y: 50))
        #expect(h.editor.selection.isEmpty, "the empty middle of a transparent shape isn't the shape")
        h.click(CGPoint(x: 1, y: 50))
        #expect(h.editor.selection == ["a"])
        // Once selected, it drags from anywhere inside its box.
        h.drag([CGPoint(x: 100, y: 50), CGPoint(x: 110, y: 50), CGPoint(x: 150, y: 50)])
        #expect(h.editor.document.elements[0].x == 50)
    }

    @Test func shiftClickAddsAndRemoves() {
        let h = Harness(document: CanvasDocument(elements: [
            Self.box("a", x: 0, y: 0), Self.box("b", x: 300, y: 0),
        ]))
        h.click(CGPoint(x: 50, y: 30))
        h.click(CGPoint(x: 350, y: 30), flags: .shift)
        #expect(h.editor.selection == ["a", "b"])
        h.click(CGPoint(x: 50, y: 30), flags: .shift)
        #expect(h.editor.selection == ["b"])
    }

    @Test func clickingAGroupSelectsAllOfIt() {
        var a = Self.box("a", x: 0, y: 0)
        a.groupIds = ["g"]
        var b = Self.box("b", x: 300, y: 0)
        b.groupIds = ["g"]
        let h = Harness(document: CanvasDocument(elements: [a, b]))
        h.click(CGPoint(x: 50, y: 30))
        #expect(h.editor.selection == ["a", "b"])
    }

    @Test func handleResizesSelection() throws {
        let h = Harness(document: CanvasDocument(elements: [Self.box("a", x: 100, y: 100, width: 100, height: 100)]))
        h.click(CGPoint(x: 150, y: 150))
        let frame = try #require(h.canvas.selectionFrame)
        let handle = h.canvas.handleCenter(.bottomRight, in: frame)
        let start = h.canvas.viewport.toScene(handle)
        h.drag([start, CGPoint(x: start.dx + 50, y: start.dy + 30), CGPoint(x: start.dx + 100, y: start.dy + 100)])
        let resized = h.editor.document.elements[0]
        #expect(resized.x == 100 && resized.y == 100)
        #expect(abs(resized.width - 200) < 0.01 && abs(resized.height - 200) < 0.01)
    }

    @Test func keyboardEditsSelection() {
        let h = Harness(document: CanvasDocument(elements: [Self.box("a")]))
        h.click(CGPoint(x: 50, y: 30))
        h.key(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 0x7C)
        #expect(h.editor.document.elements[0].x == 1)
        h.key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), code: 0x7D, flags: .shift)
        #expect(h.editor.document.elements[0].y == 5)

        h.key("d", flags: .command)
        #expect(h.editor.document.elements.count == 2)
        #expect(h.editor.selection.count == 1 && !h.editor.selection.contains("a"))

        h.key("\u{7F}", code: 0x33)
        #expect(h.editor.document.elements.map(\.id) == ["a"])

        h.canvas.selectAll(nil)
        #expect(h.editor.selection == ["a"])
        h.key("\u{1B}", code: 0x35)
        #expect(h.editor.selection.isEmpty)
    }

    // MARK: Text

    @Test func typesTextIntoNewElement() throws {
        let h = Harness()
        h.click(CGPoint(x: 200, y: 200), clicks: 2)
        #expect(h.canvas.textEditing != nil)
        h.type("Hello")
        h.canvas.commitTextEditing()

        let text = try #require(h.editor.document.elements.first)
        #expect(text.type == .text)
        #expect(text.text == "Hello")
        #expect(text.width > 30 && text.height >= 20)
        #expect(h.editor.selection == [text.id])
        #expect(h.editor.history.undoStack.count == 1)
    }

    @Test func emptyTextIsDiscarded() {
        let h = Harness()
        h.key("t")
        h.click(CGPoint(x: 100, y: 100))
        h.canvas.commitTextEditing()
        #expect(h.editor.document.elements.isEmpty)
        #expect(!h.editor.canUndo)
    }

    @Test func doubleClickShapeAddsLabel() throws {
        let h = Harness(document: CanvasDocument(elements: [CanvasEditingTests.rect("box", x: 0, y: 0, width: 200, height: 80)]))
        h.click(CGPoint(x: 100, y: 40), clicks: 2)
        h.type("Label")
        h.canvas.commitTextEditing()

        let box = try #require(h.editor.document.element(id: "box"))
        let labelID = try #require(box.boundTextID)
        let label = try #require(h.editor.document.element(id: labelID))
        #expect(label.containerId == "box")
        #expect(label.text == "Label")
        #expect(abs((label.x + label.width / 2) - 100) < 1, "centered in the box")
        #expect(h.editor.document.elements.map(\.id) == ["box", labelID], "the label sits above its box")

        // Moving the box moves its label.
        h.drag([CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 20), CGPoint(x: 120, y: 20)])
        let movedLabel = try #require(h.editor.document.element(id: labelID))
        #expect(abs(movedLabel.x - (label.x + 100)) < 0.01)
    }

    // MARK: Clipboard

    @Test func copyAndPasteThroughPasteboard() throws {
        let h = Harness(document: CanvasDocument(elements: [Self.box("a", x: 0, y: 0)]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nubb-canvas-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        h.click(CGPoint(x: 50, y: 30))
        h.canvas.copySelection(to: pasteboard)
        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.contains("excalidraw/clipboard"))

        h.move(CGPoint(x: 500, y: 400))
        h.canvas.paste(from: pasteboard)
        #expect(h.editor.document.elements.count == 2)
        let pasted = try #require(h.editor.document.elements.last)
        #expect(pasted.id != "a")
        #expect(abs(pasted.center.dx - 500) < 0.01 && abs(pasted.center.dy - 400) < 0.01)
        #expect(h.editor.selection == [pasted.id])
    }

    @Test func pastingPlainTextMakesTextElement() throws {
        let h = Harness()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nubb-canvas-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("note to self", forType: .string)
        h.canvas.paste(from: pasteboard)
        let text = try #require(h.editor.document.elements.first)
        #expect(text.type == .text && text.text == "note to self")
    }

    // MARK: Zoom

    @Test func scrollPansAndCommandScrollZooms() {
        let h = Harness()
        h.canvas.zoom(by: 2, around: CGPoint(x: 400, y: 300))
        #expect(h.canvas.viewport.zoom == 2)
        #expect(h.editor.ui.zoom == 2)
        h.canvas.zoomStep(in: false)
        #expect(abs(h.canvas.viewport.zoom - 1.9) < 1e-9)
        h.canvas.resetZoom()
        #expect(h.canvas.viewport.zoom == 1)
    }

    // MARK: Rendering

    @Test func redrawsReuseCachedShapes() throws {
        let document = try CanvasDocument.decode(Data(CanvasDocumentTests.excalidrawFile.utf8))
        let renderer = CanvasRenderer()
        let context = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let visible = CGRect(x: -1000, y: -1000, width: 4000, height: 4000)
        renderer.draw(document, in: context, visible: visible)
        let built = renderer.buildCount
        #expect(built == document.elements.count)

        for _ in 0..<10 { renderer.draw(document, in: context, visible: visible) }
        #expect(renderer.buildCount == built, "panning and zooming never rebuild shapes")

        // Moving an element changes its version but not its shape.
        var moved = document
        CanvasOps.update("rect-1", in: &moved) { $0.x += 50 }
        renderer.draw(moved, in: context, visible: visible)
        #expect(renderer.buildCount == built)

        // Resizing does rebuild it.
        CanvasOps.update("rect-1", in: &moved) { $0.width += 50 }
        renderer.draw(moved, in: context, visible: visible)
        #expect(renderer.buildCount == built + 1)

        // Elements far outside the visible area aren't built at all.
        let fresh = CanvasRenderer()
        fresh.draw(document, in: context, visible: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        #expect(fresh.buildCount == 0)
    }

    @Test func rendersDrawingToImage() throws {
        let document = try CanvasDocument.decode(Data(CanvasDocumentTests.excalidrawFile.utf8))
        let image = try #require(CanvasRenderer.image(of: document, scale: 1))
        #expect(image.width > 300 && image.height > 100)

        // The hachured box has its blue fill somewhere inside.
        let data = try #require(image.dataProvider?.data as Data?)
        var bluish = 0
        for offset in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
            if b > 200 && r < 200 && g > 180 { bluish += 1 }
        }
        #expect(bluish > 50)

        if let directory = Self.snapshotDirectory {
            try Self.writeSnapshots(to: directory)
        }
    }

    // MARK: Snapshots

    /// The whole canvas tab, chrome included, with a shape selected so the
    /// style panel shows. The color rows must fit in the panel, and each
    /// piece of chrome must be inside the window.
    @Test func chromeFitsWithStylePanelOpen() throws {
        let editor = CanvasEditor(document: Self.sampler())
        let canvas = CanvasView(editor: editor)
        let container = CanvasContainerView(canvas: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        // The canvas draws light unless set otherwise. Ask for dark here
        // without touching the saved setting.
        container.appearance = NSAppearance(named: .darkAqua)
        container.layoutSubtreeIfNeeded()
        canvas.fitToContent(animated: false)
        editor.select(["e0", "e3"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        container.layoutSubtreeIfNeeded()

        let panel = try #require(Self.descendant(of: container) { String(describing: type(of: $0)).contains("CanvasStylePanelHost") })
        #expect(editor.ui.theme == .dark, "swatches follow the canvas theme")
        #expect(panel.frame.width <= 230, "the style panel stays narrow")
        #expect(container.bounds.contains(panel.frame))
        let wells = Self.descendants(of: panel) { $0 is NSColorWell || String(describing: type(of: $0)).contains("ColorWell") }
        #expect(wells.isEmpty, "custom colors use a swatch, not a wide color well")

        if let directory = Self.snapshotDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("canvas-chrome.png"))
        }
        window.close()
    }

    /// The custom color swatch opens the shared color panel. Picking a color
    /// there reports it as hex, and a run of picks is one undo step.
    @Test func colorPanelSetsTheSelectionColor() throws {
        let editor = CanvasEditor(document: Self.sampler())
        editor.select(["e0"])
        let panel = NSColorPanel.shared
        CanvasColorPanel.shared.open(color: "#1e1e1e") { hex in
            editor.applyStyle(coalescing: "strokeColor") { $0.strokeColor = hex }
        }
        defer { panel.orderOut(nil) }
        #expect(panel.isVisible || panel.isContinuous, "the panel is set up for live changes")

        for red in [0.2, 0.5, 1.0] {
            panel.color = NSColor(srgbRed: red, green: 0, blue: 0, alpha: 1)
            CanvasColorPanel.shared.colorChanged(panel)
        }
        #expect(editor.element("e0")?.strokeColor == "#ff0000")
        #expect(editor.history.undoStack.count == 1)
        editor.undo()
        #expect(editor.element("e0")?.strokeColor == Self.sampler().elements[0].strokeColor)
    }

    /// Canvases start light even in a dark window, as Excalidraw does. The
    /// theme setting switches every open canvas live, and Match System
    /// follows the window.
    @Test func canvasThemeSettingOverridesTheWindow() throws {
        let suite = "CanvasThemeTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = CanvasAppearance.defaults
        CanvasAppearance.defaults = defaults
        defer {
            CanvasAppearance.defaults = saved
            defaults.removePersistentDomain(forName: suite)
        }

        let editor = CanvasEditor(document: Self.sampler())
        let canvas = CanvasView(editor: editor)
        let container = CanvasContainerView(canvas: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        defer { window.close() }

        #expect(CanvasAppearance.current == .light)
        #expect(canvas.theme == .light, "a dark window still gets a light canvas")
        #expect(editor.ui.theme == .light)

        CanvasAppearance.current = .dark
        #expect(canvas.theme == .dark)
        CanvasAppearance.current = .system
        #expect(canvas.theme == .dark, "Match System follows the dark window")
        window.appearance = NSAppearance(named: .aqua)
        #expect(canvas.theme == .light)

        CanvasAppearance.toggle(from: canvas)
        #expect(CanvasAppearance.current == .dark)
        #expect(canvas.theme == .dark)
        #expect(defaults.string(forKey: CanvasAppearance.defaultsKey) == "dark", "the choice is saved")

        let item = CanvasAppearanceMenu.shared.makeItem()
        let options = item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
        #expect(options.map(\.title) == ["Light", "Dark", "Match System"])
        for option in options { _ = CanvasAppearanceMenu.shared.validateMenuItem(option) }
        #expect(options.map(\.state) == [.off, .on, .off])
        CanvasAppearanceMenu.shared.choose(options[0])
        #expect(canvas.theme == .light)
        // The light canvas mustn't paint under the translucent sidebar and
        // title bar next to it, which would tint them.
        #expect(container.clipsToBounds && canvas.clipsToBounds)
    }

    /// The chrome in light mode, written next to the dark one for a look.
    @Test func chromeInLightMode() throws {
        let editor = CanvasEditor(document: Self.sampler())
        let canvas = CanvasView(editor: editor)
        let container = CanvasContainerView(canvas: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        canvas.fitToContent(animated: false)
        editor.select(["e12"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        container.layoutSubtreeIfNeeded()
        #expect(editor.ui.theme == .light)

        if let directory = Self.snapshotDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("canvas-chrome-light.png"))
        }
        window.close()
    }

    private static func descendant(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
        descendants(of: view, where: match).first
    }

    private static func descendants(of view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = []
        for subview in view.subviews {
            if match(subview) { found.append(subview) }
            found += descendants(of: subview, where: match)
        }
        return found
    }

    private static var snapshotDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["NUBB_CANVAS_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Renders a sampler of every element kind in both themes, for checking
    /// the look by eye. Runs when NUBB_CANVAS_SNAPSHOT_DIR is set.
    private static func writeSnapshots(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = sampler()
        for theme in [CanvasTheme.light, .dark] {
            let image = try #require(CanvasRenderer.image(of: document, scale: 2, theme: theme))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(theme == .light ? "canvas-light.png" : "canvas-dark.png"))
        }
        try document.encoded().write(to: directory.appendingPathComponent("sampler.excalidraw"))
    }

    static func sampler() -> CanvasDocument {
        var elements: [CanvasElement] = []
        func add(_ type: CanvasElementType, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ configure: (inout CanvasElement) -> Void = { _ in }) {
            var element = CanvasElement(id: "e\(elements.count)", type: type)
            element.seed = 1000 + elements.count
            element.x = x
            element.y = y
            element.width = w
            element.height = h
            CanvasStyle().apply(to: &element)
            configure(&element)
            elements.append(element)
        }

        add(.rectangle, 0, 0, 160, 100) { $0.backgroundColor = "#a5d8ff"; $0.fillStyle = "hachure" }
        add(.rectangle, 200, 0, 160, 100) { $0.backgroundColor = "#b2f2bb"; $0.fillStyle = "cross-hatch"; $0.roundness = nil }
        add(.rectangle, 400, 0, 160, 100) { $0.backgroundColor = "#ffec99"; $0.fillStyle = "solid"; $0.strokeStyle = "dashed" }
        add(.diamond, 0, 140, 160, 110) { $0.backgroundColor = "#ffc9c9"; $0.fillStyle = "solid" }
        add(.ellipse, 200, 140, 160, 110) { $0.backgroundColor = "#d0bfff"; $0.fillStyle = "zigzag"; $0.strokeStyle = "dotted" }
        add(.ellipse, 400, 140, 160, 110) { $0.roughness = 0; $0.strokeColor = "#e03131"; $0.strokeWidth = 4 }
        add(.arrow, 0, 300, 0, 0) { element in
            element.points = [.zero, CGPoint(x: 160, y: -20), CGPoint(x: 260, y: 30)]
            CanvasOps.normalizePoints(&element)
            element.endArrowhead = "arrow"
            element.startArrowhead = "dot"
        }
        add(.arrow, 300, 300, 0, 0) { element in
            element.points = [.zero, CGPoint(x: 220, y: 0)]
            CanvasOps.normalizePoints(&element)
            element.roundness = nil
            element.endArrowhead = "triangle"
            element.startArrowhead = "bar"
            element.strokeColor = "#1971c2"
        }
        add(.line, 0, 360, 0, 0) { element in
            element.points = [.zero, CGPoint(x: 80, y: -40), CGPoint(x: 160, y: 0), CGPoint(x: 0, y: 0)]
            CanvasOps.normalizePoints(&element)
            element.backgroundColor = "#ffc9c9"
            element.fillStyle = "solid"
        }
        add(.freedraw, 220, 340, 0, 0) { element in
            element.points = (0...40).map { CGPoint(x: Double($0) * 6, y: sin(Double($0) / 4) * 25) }
            let box = CanvasGeometry.bounds(of: element.points)
            element.width = Double(box.width)
            element.height = Double(box.height)
            element.strokeColor = "#2f9e44"
        }
        add(.text, 0, 420, 0, 0) { element in
            element.text = "Hand-drawn text\nsecond line"
            element.originalText = element.text
            element.fontSize = 24
            element.lineHeight = CanvasText.defaultLineHeight(family: element.fontFamily)
            CanvasOps.remeasure(&element)
        }
        add(.text, 300, 420, 0, 0) { element in
            element.text = "let code = true"
            element.originalText = element.text
            element.fontFamily = CanvasFont.Family.comicShanns.rawValue
            element.lineHeight = CanvasText.defaultLineHeight(family: element.fontFamily)
            CanvasOps.remeasure(&element)
        }
        add(.rectangle, 300, 500, 200, 70) { $0.angle = 0.3; $0.opacity = 60; $0.backgroundColor = "#a5d8ff"; $0.fillStyle = "solid" }

        // A labeled box.
        add(.rectangle, 0, 500, 220, 80) { $0.addBoundElement(id: "label", type: "text") }
        var label = CanvasElement(id: "label", type: .text)
        label.containerId = elements.last!.id
        label.text = "Labeled box"
        label.originalText = label.text
        label.textAlign = "center"
        label.verticalAlign = "middle"
        CanvasOps.layoutLabel(&label, container: elements.last!)
        elements.append(label)

        var document = CanvasDocument(elements: elements)
        document.viewBackgroundColor = "#ffffff"
        return document
    }
}
