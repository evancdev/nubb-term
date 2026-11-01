import AppKit
import Foundation
import Testing
@testable import Nubb

/// The agent CLI end to end, in process: specs in, files out, hand edits
/// kept, lint, and render.
@Suite(.serialized)
@MainActor
struct CanvasAgentTests {
    /// A folder for one test, with its own agent state.
    private final class Sandbox {
        let directory: URL
        let state: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("nubb-canvas-agent-\(UUID().uuidString)", isDirectory: true)
            state = directory.appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CanvasAgentStore.directoryOverride = state
        }

        deinit {
            CanvasAgentStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

        /// Runs `nubb +canvas <args>`.
        @discardableResult
        func run(_ args: String..., stdin: String = "") -> CanvasCommandResult {
            var context = CanvasCommandContext(cwd: directory)
            context.readStdin = { Data(stdin.utf8) }
            return CanvasCommands.run(args, context: context)
        }

        func document(_ name: String) throws -> CanvasDocument {
            try CanvasDocument.decode(Data(contentsOf: url(name)))
        }

        func write(_ document: CanvasDocument, to name: String) throws {
            try document.encoded().write(to: url(name), options: .atomic)
        }
    }

    /// An explainer panel like agents draw: a title, a paragraph, boxes
    /// with arrows, and code.
    private static func panel(_ index: Int, title: String) -> String {
        """
        {"frame": "\(index). \(title)", "id": "p\(index)", "children": [
          {"text": "\(title)", "size": "xl", "id": "p\(index)title"},
          {"text": "Requests enter at the edge and fan out to shards, so no single machine has to hold every key or answer every request.", "id": "p\(index)para"},
          {"row": [{"box": "Client", "id": "p\(index)a", "fill": "blue"}, {"box": "Router", "id": "p\(index)b", "fill": "green"}, {"box": "Shard", "id": "p\(index)c"}], "gap": 100, "align": "center"},
          {"arrow": "sends", "from": "p\(index)a", "to": "p\(index)b", "id": "p\(index)x"},
          {"arrow": "stores", "from": "p\(index)b", "to": "p\(index)c", "id": "p\(index)y"},
          {"code": "shard = hash(key) % 16\\nshard.write(key, value)", "id": "p\(index)code"}
        ]}
        """
    }

    private static let lesson: String = {
        let titles = ["Shards", "Routing", "Replication", "Elections", "Reads", "Queues", "Splits", "Together"]
        let panels = titles.enumerated().map { panel($0.offset + 1, title: $0.element) }
        return "{\"defaults\": {\"frame\": {\"fill\": \"gray.0\"}}, \"nodes\": [{\"grid\": [\(panels.joined(separator: ","))], \"columns\": 2, \"id\": \"lesson\"}]}"
    }()

    // MARK: Apply and ids

    @Test func eightPanelLessonAppliesCleanly() throws {
        let box = try Sandbox()
        let result = box.run("apply", "lesson.excalidraw", Self.lesson, "--lint")
        #expect(result.exit == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("lint: no problems"))

        let document = try box.document("lesson.excalidraw")
        let frames = document.elements.filter { $0.type == .frame }
        #expect(frames.count == 8)
        let titles = ["Shards", "Routing", "Replication", "Elections", "Reads", "Queues", "Splits", "Together"]
        let expected: [String?] = titles.enumerated().map { "\($0.offset + 1). \($0.element)" }
        #expect(frames.map(\.frameName) == expected)
        // Every id the spec gave is in the file, with Excalidraw parts next to it.
        for id in ["p1title", "p1para", "p1a", "p1a:label", "p1x", "p1x:label", "p1code", "p1code:code"] {
            #expect(document.element(id: id) != nil, "missing \(id)")
        }
        // Frames sit above their elements, labels right above containers.
        let order = document.elements.map(\.id)
        let firstFrame = order.firstIndex(of: "p1")!
        #expect(order.firstIndex(of: "p1title")! < firstFrame)
        #expect(order.firstIndex(of: "p1a:label") == order.firstIndex(of: "p1a")! + 1)
        // Arrows are bound both ways, in Excalidraw's current format.
        let arrow = document.element(id: "p1x")!
        #expect(arrow.startBinding?.elementId == "p1a")
        #expect(arrow.endBinding?.elementId == "p1b")
        #expect(arrow.startBinding?.mode == "orbit")
        #expect(document.element(id: "p1a")!.boundElements?.contains { $0.id == "p1x" } == true)

        // Applying the same spec again changes nothing.
        let before = try Data(contentsOf: box.url("lesson.excalidraw"))
        let again = box.run("apply", "lesson.excalidraw", Self.lesson)
        #expect(again.stdout.contains("no changes"), "\(again.stdout)")
        #expect(try Data(contentsOf: box.url("lesson.excalidraw")) == before)
    }

    @Test func specErrorsListEveryProblemWithItsPath() throws {
        let box = try Sandbox()
        let result = box.run("apply", "x.excalidraw", """
        {"nodes": [{"frame": "A", "children": [{"box": "x", "fill": "bleu"}, {"text": "y", "colr": "red"}, {"grid": []}]}]}
        """)
        #expect(result.exit == 2)
        #expect(result.stderr.contains("3 problems"))
        #expect(result.stderr.contains("nodes[0].children[0].fill"))
        #expect(result.stderr.contains("did you mean \"blue\""))
        #expect(result.stderr.contains("nodes[0].children[1].colr"))
        #expect(result.stderr.contains("did you mean \"color\""))
        #expect(result.stderr.contains("a grid needs \"columns\""))
        #expect(!FileManager.default.fileExists(atPath: box.url("x.excalidraw").path))
    }

    @Test func childrenWithoutIdsKeepTheirIdsWhenSiblingsAreAdded() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", #"{"stack": ["First", "Second", "Third"], "id": "s"}"#)
        let before = try box.document("a.excalidraw")
        #expect(before.element(id: "s.1")?.text == "Second")
        box.run("apply", "a.excalidraw", #"{"stack": ["Zeroth", "First", "Second", "Third"], "id": "s"}"#)
        let after = try box.document("a.excalidraw")
        #expect(after.element(id: "s.1")?.text == "Second")
        #expect(after.element(id: "s.0")?.text == "First")
        #expect(after.elements.contains { $0.text == "Zeroth" })
    }

    // MARK: Set, move, delete

    @Test func setChangesTextByIdAndRelaysOut() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        let code = try box.document("a.excalidraw").element(id: "p1code")!
        let result = box.run("set", "a.excalidraw", "p1para", "text=Short now.")
        #expect(result.exit == 0, "\(result.stderr)")
        let document = try box.document("a.excalidraw")
        #expect(document.element(id: "p1para")?.text == "Short now.")
        // The paragraph got shorter, so what's below moved up.
        #expect(document.element(id: "p1code")!.y < code.y)
        // A label's container: set on the node changes its label.
        box.run("set", "a.excalidraw", "p1a", "label=Browser")
        #expect(try box.document("a.excalidraw").element(id: "p1a:label")?.text == "Browser")
        // Unknown ids say what's close.
        let missing = box.run("set", "a.excalidraw", "p1prara", "text=x")
        #expect(missing.exit == 1)
        #expect(missing.stderr.contains("did you mean \"p1para\""), "\(missing.stderr)")
    }

    @Test func moveAndDeleteTakeWhatsInside() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        let frame = try box.document("a.excalidraw").element(id: "p1")!
        let title = try box.document("a.excalidraw").element(id: "p1title")!
        box.run("move", "a.excalidraw", "p1", "100", "50")
        var document = try box.document("a.excalidraw")
        #expect(document.element(id: "p1")!.x == frame.x + 100)
        #expect(document.element(id: "p1title")!.y == title.y + 50)

        box.run("delete", "a.excalidraw", "p1b")
        document = try box.document("a.excalidraw")
        #expect(document.element(id: "p1b") == nil)
        #expect(document.element(id: "p1b:label") == nil)
        // Arrows to it aren't drawn, and lint has nothing to say.
        #expect(document.element(id: "p1x") == nil)
        #expect(box.run("lint", "a.excalidraw").exit == 0)
    }

    // MARK: Hand edits

    /// The person drags a box and edits a label in the viewer; the agent's
    /// next change keeps both.
    @Test func handEditsSurviveTheNextApply() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        var document = try box.document("a.excalidraw")
        let original = document.element(id: "p1b")!
        // Drag the Router box (with its label) 40 right, 70 down.
        for id in ["p1b", "p1b:label"] {
            CanvasOps.update(id, in: &document) { $0.x += 40; $0.y += 70 }
        }
        CanvasOps.updateRelations(changed: ["p1b"], in: &document)
        // Rename the Client box.
        CanvasOps.update("p1a:label", in: &document) { $0.originalText = "Phone"; $0.text = "Phone" }
        try box.write(document, to: "a.excalidraw")

        let changes = box.run("changes", "a.excalidraw")
        #expect(changes.stdout.contains("p1b  moved by 40,70"), "\(changes.stdout)")
        #expect(changes.stdout.contains("p1a:label  text: \"Client\" -> \"Phone\""), "\(changes.stdout)")

        // The agent edits something else, then applies the whole spec again.
        let set = box.run("set", "a.excalidraw", "p1title", "text=Shards, revisited")
        #expect(set.stdout.contains("kept 2 changes"), "\(set.stdout)")
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        document = try box.document("a.excalidraw")
        let moved = document.element(id: "p1b")!
        // A hand move is kept relative to where layout puts the node, so
        // it rides along when the layout around it changes: the narrower
        // "Phone" box made the row shorter, and Router moved with it.
        let client = document.element(id: "p1a")!
        let reflow = client.width - Self.boxWidth("Client")
        #expect(abs(moved.x - (original.x + 40 + reflow)) < 0.01, "\(moved.x) \(original.x) \(reflow)")
        #expect(abs(moved.y - (original.y + 70)) < 0.01)
        #expect(document.element(id: "p1a:label")?.text == "Phone")
        // Arrows still meet the moved box.
        let arrow = document.element(id: "p1y")!
        #expect(arrow.startBinding?.elementId == "p1b")
        let start = arrow.toScene(arrow.points[0])
        #expect(CanvasLint.distance(from: start, to: moved) < 12)
        // Apply put its title back; the person's label stays.
        #expect(document.element(id: "p1title")?.text == "Shards")
        #expect(box.run("lint", "a.excalidraw", "--only", "loose-arrow,broken-ref").exit == 0)

        // When the agent changes the label itself, its text wins.
        box.run("set", "a.excalidraw", "p1a", "label=Laptop")
        #expect(try box.document("a.excalidraw").element(id: "p1a:label")?.text == "Laptop")

        // reset drops the move.
        box.run("reset", "a.excalidraw", "p1b")
        let reset = try box.document("a.excalidraw")
        #expect(abs(reset.element(id: "p1b")!.x - (original.x + reset.element(id: "p1a")!.width - Self.boxWidth("Client"))) < 0.01)
        #expect(abs(reset.element(id: "p1b")!.y - original.y) < 0.01)
    }

    /// The width layout gives a box with `label`, as the panel draws it.
    private static func boxWidth(_ label: String) -> Double {
        let text = CanvasText.measure(label, family: CanvasFont.Family.handDrawn.rawValue, fontSize: 20, lineHeight: 1.25)
        return ((Double(text.width) + 40) * 100 - 1e-6).rounded(.up) / 100
    }

    /// A dragged box keeps exactly where it was put while nothing around it
    /// changes size.
    @Test func handMoveIsExactWhenLayoutIsStable() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        var document = try box.document("a.excalidraw")
        let original = document.element(id: "p1b")!
        for id in ["p1b", "p1b:label"] { CanvasOps.update(id, in: &document) { $0.x += 40; $0.y += 70 } }
        CanvasOps.updateRelations(changed: ["p1b"], in: &document)
        try box.write(document, to: "a.excalidraw")
        box.run("set", "a.excalidraw", "p1code", "code=shard = crc32(key) % 16")
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        let after = try box.document("a.excalidraw").element(id: "p1b")!
        #expect(abs(after.x - (original.x + 40)) < 0.01)
        #expect(abs(after.y - (original.y + 70)) < 0.01)
    }

    @Test func movingAFrameByHandMovesItOnceNotTwice() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        var document = try box.document("a.excalidraw")
        let frame = document.element(id: "p1")!
        let code = document.element(id: "p1code")!
        // Dragging a frame moves everything in it, as Excalidraw does.
        let ids = CanvasOps.withFrameChildren(["p1"], in: document)
        for id in ids { CanvasOps.update(id, in: &document) { $0.x += 300; $0.y -= 20 } }
        CanvasOps.updateRelations(changed: ids, in: &document)
        try box.write(document, to: "a.excalidraw")

        box.run("set", "a.excalidraw", "p1para", "text=Different words now.")
        document = try box.document("a.excalidraw")
        #expect(abs(document.element(id: "p1")!.x - (frame.x + 300)) < 0.01)
        #expect(abs(document.element(id: "p1code")!.x - (code.x + 300)) < 0.01)
    }

    @Test func deletedByHandStaysDeleted() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        var document = try box.document("a.excalidraw")
        CanvasOps.delete(["p1code"], in: &document)
        try box.write(document, to: "a.excalidraw")
        let result = box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        #expect(result.stdout.contains("deleted by hand: p1code"), "\(result.stdout)")
        #expect(try box.document("a.excalidraw").element(id: "p1code") == nil)
        box.run("reset", "a.excalidraw", "p1code")
        #expect(try box.document("a.excalidraw").element(id: "p1code") != nil)
    }

    @Test func handDrawnElementsAndArrowsStay() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", Self.panel(1, title: "Shards"))
        var document = try box.document("a.excalidraw")
        let shard = document.element(id: "p1c")!
        // The person draws a note and an arrow from it to the Shard box.
        var note = CanvasElement(id: "noteXYZ", type: .ellipse)
        note.x = shard.x
        note.y = shard.y + 200
        note.width = 100
        note.height = 60
        var arrow = CanvasElement(id: "arrowXYZ", type: .arrow)
        CanvasOps.setScenePoints([CGPoint(x: note.center.x, y: note.y), CGPoint(x: shard.center.x, y: shard.y + shard.height + 8)], of: &arrow)
        document.elements.append(note)
        document.elements.append(arrow)
        CanvasOps.bind("arrowXYZ", end: .end, to: "p1c", in: &document)
        try box.write(document, to: "a.excalidraw")

        // The agent moves the Shard box; the person's arrow follows it.
        box.run("move", "a.excalidraw", "p1c", "0", "-40")
        document = try box.document("a.excalidraw")
        #expect(document.element(id: "noteXYZ") != nil)
        let after = document.element(id: "arrowXYZ")!
        let moved = document.element(id: "p1c")!
        #expect(after.endBinding?.elementId == "p1c")
        #expect(CanvasLint.distance(from: after.toScene(after.points.last!), to: moved) < 12)
        #expect(moved.boundElements?.contains { $0.id == "arrowXYZ" } == true)
    }

    // MARK: Lint

    @Test func lintFindsABrokenParagraphWithIdAndPixels() throws {
        let box = try Sandbox()
        box.run("apply", "lesson.excalidraw", Self.lesson)
        #expect(box.run("lint", "lesson.excalidraw").exit == 0)

        // Too wide for its frame, which has a set width.
        box.run("set", "lesson.excalidraw", "p3", "width=640")
        #expect(box.run("lint", "lesson.excalidraw").exit == 0)
        box.run("set", "lesson.excalidraw", "p3para", "width=900")
        var result = box.run("lint", "lesson.excalidraw")
        #expect(result.exit == 1)
        #expect(result.stdout.contains("overflow  p3para: sticks out of frame \"3. Replication\" by"), "\(result.stdout)")
        box.run("set", "lesson.excalidraw", "p3para", "width=null")
        #expect(box.run("lint", "lesson.excalidraw").exit == 0)

        // Text written into the file without updating its size.
        var document = try box.document("lesson.excalidraw")
        CanvasOps.update("p5para", in: &document) {
            $0.text += " And then a much longer sentence was pasted in by a script that never measured anything at all."
            $0.originalText = $0.text
        }
        try box.write(document, to: "lesson.excalidraw")
        result = box.run("lint", "lesson.excalidraw", "--json")
        #expect(result.exit == 1)
        let issues = try CanvasJSON.parse(Data(result.stdout.utf8))["issues"]?.arrayValue ?? []
        let overflow = issues.first { $0["kind"]?.stringValue == "overflow" && $0["id"]?.stringValue == "p5para" }
        #expect(overflow != nil, "\(result.stdout)")
        #expect((overflow?["px"]?.doubleValue ?? 0) > 100)
        #expect(overflow?["frame"]?.stringValue == "5. Reads")
        #expect(issues.contains { $0["kind"]?.stringValue == "stale-size" && $0["id"]?.stringValue == "p5para" })

        // fix rewraps it.
        box.run("fix", "lesson.excalidraw")
        #expect(box.run("lint", "lesson.excalidraw", "--only", "stale-size,overflow").exit == 0)
    }

    @Test func lintFindsLooseArrowsOverlapsAndSmallText() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", """
        {"nodes": [
          {"box": "A", "id": "a", "at": [0, 0]},
          {"box": "B", "id": "b", "at": [300, 0]},
          {"text": "Over here", "id": "t1", "at": [0, 200]},
          {"text": "Over there", "id": "t2", "at": [20, 205]},
          {"text": "tiny", "id": "t3", "size": 4, "at": [0, 400]},
          {"type": "arrow", "id": "loose", "x": 120, "y": 25, "points": [[0, 0], [100, 0]]}
        ]}
        """)
        let result = box.run("lint", "a.excalidraw")
        #expect(result.stdout.contains("overlap  t1 and t2 overlap"), "\(result.stdout)")
        #expect(result.stdout.contains("loose-arrow  loose:"), "\(result.stdout)")
        #expect(result.stdout.contains("small-text  t3"), "\(result.stdout)")
    }

    @Test func lintIsFastOnBigDrawings() throws {
        let box = try Sandbox()
        // 25 panels of 15 elements each, about 10,000 px tall.
        let panels = (1...25).map { Self.panel($0, title: "Panel \($0)") }
        let spec = "{\"nodes\": [{\"stack\": [\(panels.joined(separator: ","))], \"id\": \"big\"}]}"
        let started = Date()
        #expect(box.run("apply", "big.excalidraw", spec).exit == 0)
        let applied = Date().timeIntervalSince(started)
        let document = try box.document("big.excalidraw")
        #expect(document.elements.count >= 375)
        #expect(CanvasRenderer.sceneBounds(of: document.elements).height > 9000)
        let lintStart = Date()
        let issues = CanvasLint.run(document)
        let linted = Date().timeIntervalSince(lintStart)
        #expect(issues.isEmpty, "\(issues.prefix(3))")
        #expect(applied < 5)
        #expect(linted < 1)
    }

    // MARK: Render

    @Test func renderingAFrameMatchesTheViewer() throws {
        let box = try Sandbox()
        box.run("apply", "lesson.excalidraw", Self.lesson)
        let result = box.run("render", "lesson.excalidraw", "--frame", "6", "--scale", "1", "-o", "p6.png")
        #expect(result.exit == 0, "\(result.stderr)")
        #expect(result.stdout.contains("\"6. Queues\""))
        let image = try #require(NSImage(contentsOf: box.url("p6.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let document = try box.document("lesson.excalidraw")
        let frame = try #require(document.element(id: "p6"))
        #expect(abs(Double(image.width) - (frame.width + 40)) <= 1)

        // The same pixels as the renderer the viewer uses, on the same area.
        var options = CanvasExport.Options()
        options.scale = 1
        options.only = CanvasOps.withFrameChildren(["p6"], in: document)
        options.region = frame.sceneBounds.insetBy(dx: -20, dy: -20)
        let direct = try CanvasExport.image(document, options: options)
        let (a, b) = (Self.rgba(image), Self.rgba(direct))
        #expect(a.count == b.count)
        let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 2 }.count
        #expect(differing == 0, "\(differing) of \(a.count) bytes differ")

        // And what the viewer's own view draws: the same shapes, cached. A
        // window is a whole number of points, so compare a whole area.
        options.region = options.region!.integral
        let editor = CanvasEditor(document: document)
        let view = CanvasView(editor: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: options.region!.width, height: options.region!.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // After the first layout, which fits the drawing on screen.
        view.viewport = CanvasViewport(zoom: 1, offset: CGPoint(x: -options.region!.minX, y: -options.region!.minY))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.close()
        let viewer = try #require(rep.cgImage)
        // The viewer draws at the screen's scale; render at the same one.
        let scale = Double(viewer.width) / Double(options.region!.width)
        var scaled = options
        scaled.scale = scale
        let reference = Self.rgba(try CanvasExport.image(document, options: scaled), width: viewer.width, height: viewer.height)
        let viewerPixels = Self.rgba(viewer)
        var close = 0, total = 0
        for y in stride(from: 0, to: viewer.height, by: 2) {
            for x in stride(from: 0, to: viewer.width, by: 2) {
                let i = (y * viewer.width + x) * 4
                total += 1
                if (0..<3).allSatisfy({ abs(Int(reference[i + $0]) - Int(viewerPixels[i + $0])) <= 24 }) { close += 1 }
            }
        }
        #expect(Double(close) / Double(total) > 0.995, "\(close) of \(total) sampled pixels match the viewer")
        if let dump = ProcessInfo.processInfo.environment["NUBB_CANVAS_TEST_DUMP"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dump + "/viewer.png"))
            try? FileManager.default.copyItem(at: box.url("p6.png"), to: URL(fileURLWithPath: dump + "/render.png"))
        }

        // SVG and PDF too.
        #expect(box.run("render", "lesson.excalidraw", "--frame", "6. Queues", "-o", "p6.svg").exit == 0)
        let svg = try String(contentsOf: box.url("p6.svg"), encoding: .utf8)
        #expect(svg.hasPrefix("<svg"))
        #expect(svg.contains("clipPath"))
        #expect(box.run("render", "lesson.excalidraw", "--region", "0,0,400,300", "-o", "r.pdf").exit == 0)
        #expect(try Data(contentsOf: box.url("r.pdf")).prefix(4) == Data("%PDF".utf8))
        // Unknown frames list what there is.
        #expect(box.run("render", "lesson.excalidraw", "--frame", "Nope").stderr.contains("frames: \"1. Shards\""))
    }

    /// The image as 8-bit sRGB RGBA bytes, scaled to `width` x `height`.
    private static func rgba(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> [UInt8] {
        let width = width ?? image.width, height = height ?? image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    // MARK: Excalidraw compatibility

    @Test func filesHaveWhatExcalidrawNeeds() throws {
        let box = try Sandbox()
        box.run("apply", "lesson.excalidraw", Self.lesson)
        let json = try CanvasJSON.parse(Data(contentsOf: box.url("lesson.excalidraw")))
        #expect(json["type"]?.stringValue == "excalidraw")
        #expect(json["version"]?.intValue == 2)
        let elements = json["elements"]?.arrayValue ?? []
        let ids = Set(elements.compactMap { $0["id"]?.stringValue })
        for element in elements {
            let type = element["type"]?.stringValue ?? ""
            for key in ["id", "x", "y", "width", "height", "angle", "strokeColor", "backgroundColor", "fillStyle",
                        "strokeWidth", "strokeStyle", "roughness", "opacity", "seed", "version", "versionNonce",
                        "isDeleted", "groupIds", "boundElements", "updated", "link", "locked", "frameId", "roundness"] {
                #expect(element[key] != nil, "\(element["id"]?.stringValue ?? "?") has no \(key)")
            }
            if type == "text" {
                for key in ["text", "originalText", "fontSize", "fontFamily", "textAlign", "verticalAlign", "containerId", "lineHeight", "autoResize"] {
                    #expect(element[key] != nil)
                }
                // Text in Excalidraw's own fonts.
                #expect([3, 5].contains(element["fontFamily"]?.intValue ?? 0))
            }
            if type == "arrow" {
                #expect(element["elbowed"]?.boolValue == false)
                for end in ["startBinding", "endBinding"] {
                    let binding = element[end]
                    #expect(binding?["mode"]?.stringValue == "orbit")
                    #expect(binding?["fixedPoint"]?.arrayValue?.count == 2)
                    #expect(ids.contains(binding?["elementId"]?.stringValue ?? ""))
                }
            }
            for bound in element["boundElements"]?.arrayValue ?? [] {
                #expect(ids.contains(bound["id"]?.stringValue ?? ""))
            }
            if let frame = element["frameId"]?.stringValue { #expect(ids.contains(frame)) }
        }
    }

    @Test func elbowArrowsHaveRightAngles() throws {
        let box = try Sandbox()
        box.run("apply", "a.excalidraw", """
        {"nodes": [{"box": "A", "id": "a", "at": [0, 0]}, {"box": "B", "id": "b", "at": [300, 200]},
                   {"arrow": "", "id": "e", "from": "a", "to": "b", "fromSide": "right", "toSide": "top"}]}
        """)
        let arrow = try #require(try box.document("a.excalidraw").element(id: "e"))
        #expect(arrow.isElbowArrow)
        for (p, q) in zip(arrow.points, arrow.points.dropFirst()) {
            #expect(abs(p.x - q.x) < 0.01 || abs(p.y - q.y) < 0.01)
        }
        #expect(box.run("lint", "a.excalidraw", "--only", "loose-arrow").exit == 0)
    }

    // MARK: Reading

    @Test func readCommandsDescribeTheDrawing() throws {
        let box = try Sandbox()
        box.run("apply", "lesson.excalidraw", Self.lesson)
        #expect(box.run("info", "lesson.excalidraw").stdout.contains("8 frames"))
        #expect(box.run("frames", "lesson.excalidraw").stdout.contains("\"8. Together\""))
        let list = box.run("list", "lesson.excalidraw", "--frame", "2", "--type", "text")
        #expect(list.stdout.contains("p2title  text"))
        #expect(!list.stdout.contains("p1title"))
        let node = try CanvasJSON.parse(Data(box.run("get", "lesson.excalidraw", "p3").stdout.utf8))
        #expect(node["type"]?.stringValue == "frame")
        let spec = try CanvasJSON.parse(Data(box.run("spec", "lesson.excalidraw").stdout.utf8))
        #expect(spec["nodes"]?.arrayValue?.count == 1)
        let measured = box.run("measure", "Requests fan out to shards", "--size", "20", "--width", "120", "--json")
        let lines = try CanvasJSON.parse(Data(measured.stdout.utf8))["lines"]?.arrayValue ?? []
        #expect(lines.count >= 2)
        #expect(box.run("help").stdout.contains("HOW TO MAKE A DIAGRAM"))
        #expect(box.run("help", "spec").stdout.contains("STYLE FIELDS"))
        #expect(box.run("frobnicate").stderr.contains("unknown command"))
    }

    // MARK: Hover names

    /// Hover names: set in the spec, written to customData, changed with
    /// `set`, kept when the person edits one, replaced when the agent
    /// changes the same one, and shown by list, changes, and SVG.
    @Test func hoverNamesFollowTheSpecAndKeepHandEdits() throws {
        let box = try Sandbox()
        let spec = """
        {"nodes": [{"frame": "F", "id": "f", "children": [
          {"row": [{"box": "API", "id": "api", "name": "Go service"}, {"box": "DB", "id": "db", "name": "Postgres"}], "gap": 80},
          {"arrow": "", "from": "api", "to": "db", "id": "a", "name": "SQL over TLS"},
          {"code": "x = 1", "id": "c", "name": "The write"},
          {"text": "Note", "id": "t", "name": "  "}
        ]}]}
        """
        #expect(box.run("apply", "a.excalidraw", spec).exit == 0)
        var document = try box.document("a.excalidraw")
        #expect(document.element(id: "api")?.hoverName == "Go service")
        #expect(document.element(id: "api")?.extra["customData"] == .object(["name": .string("Go service")]))
        #expect(document.element(id: "api:label")?.hoverName == nil, "the name goes on the box, not its label")
        #expect(document.element(id: "a")?.hoverName == "SQL over TLS")
        #expect(document.element(id: "c")?.hoverName == "The write")
        #expect(document.element(id: "c:code")?.hoverName == nil)
        #expect(document.element(id: "t")?.extra["customData"] == nil, "a blank name writes nothing")
        #expect(box.run("list", "a.excalidraw").stdout.contains("api  rectangle"))
        #expect(box.run("list", "a.excalidraw").stdout.contains("name \"Go service\""))

        // Where a name can't go, the spec says why.
        let bad = box.run("apply", "b.excalidraw", #"{"nodes": [{"frame": "F", "name": "x", "children": [{"row": [{"box": "a"}], "name": "y"}, {"box": "b", "name": 3}]}]}"#)
        #expect(bad.exit == 2)
        #expect(bad.stderr.contains("nodes[0].name: a frame's name is its title"), "\(bad.stderr)")
        #expect(bad.stderr.contains("nodes[0].children[0].name: a row isn't drawn"), "\(bad.stderr)")
        #expect(bad.stderr.contains("nodes[0].children[1].name: expected the text to show on hover"), "\(bad.stderr)")

        // The person renames DB in Excalidraw, which also keeps a field of
        // its own in customData.
        CanvasOps.update("db", in: &document) { $0.extra["customData"] = .object(["name": .string("Orders DB"), "tag": .number(7)]) }
        try box.write(document, to: "a.excalidraw")
        #expect(box.run("changes", "a.excalidraw").stdout.contains("db  name: \"Postgres\" -> \"Orders DB\""))

        // The agent changes something else and applies again: kept.
        box.run("set", "a.excalidraw", "api", "label=Gateway")
        box.run("apply", "a.excalidraw", spec)
        #expect(try box.document("a.excalidraw").element(id: "db")?.hoverName == "Orders DB")
        let same = try Data(contentsOf: box.url("a.excalidraw"))
        #expect(box.run("apply", "a.excalidraw", spec).stdout.contains("no changes"))
        #expect(try Data(contentsOf: box.url("a.excalidraw")) == same)

        // The agent renames DB itself: its name wins, the person's other
        // customData stays.
        box.run("set", "a.excalidraw", "db", "name=Primary Postgres")
        document = try box.document("a.excalidraw")
        #expect(document.element(id: "db")?.extra["customData"] == .object(["name": .string("Primary Postgres"), "tag": .number(7)]))
        // An empty name removes it; a frame's name is still its title.
        box.run("set", "a.excalidraw", "a", "name=")
        box.run("set", "a.excalidraw", "f", "name=Write path")
        document = try box.document("a.excalidraw")
        #expect(document.element(id: "a")?.hoverName == nil)
        #expect(document.element(id: "f")?.frameName == "Write path")
        // A part's id names its node: the code block, not its text.
        box.run("set", "a.excalidraw", "c:code", "name=Line one")
        document = try box.document("a.excalidraw")
        #expect(document.element(id: "c")?.hoverName == "Line one")
        #expect(document.element(id: "c:code")?.hoverName == nil)
        // Something the person drew takes a name in the file.
        var note = CanvasElement(id: "noteXYZ", type: .ellipse)
        note.x = 0
        note.y = 400
        note.width = 80
        note.height = 40
        document.elements.append(note)
        try box.write(document, to: "a.excalidraw")
        box.run("set", "a.excalidraw", "noteXYZ", "name=Mine")
        #expect(try box.document("a.excalidraw").element(id: "noteXYZ")?.hoverName == "Mine")

        // SVG renders carry the names as tooltips, escaped.
        box.run("set", "a.excalidraw", "api", "name=<API> & co")
        #expect(box.run("render", "a.excalidraw", "-o", "a.svg").exit == 0)
        let svg = try String(contentsOf: box.url("a.svg"), encoding: .utf8)
        #expect(svg.contains("<title>&lt;API&gt; &amp; co</title>"))
        #expect(svg.contains("<title>Primary Postgres</title>"))
    }
}
