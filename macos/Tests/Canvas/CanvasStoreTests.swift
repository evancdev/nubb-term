import AppKit
import Foundation
import Testing
@testable import Nubb

/// Saving to and watching the drawing file.
@Suite(.serialized)
struct CanvasStoreTests {
    private static func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-canvas-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("drawing.excalidraw")
    }

    /// Yields the main actor until `condition` holds or `timeout` passes, so
    /// main queue work like file events runs meanwhile.
    @MainActor
    private static func wait(timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test @MainActor func createsMissingFileAndWritesEdits() throws {
        let url = try Self.temporaryFile()
        let store = CanvasStore(url: url)
        store.writeDelay = 0
        let document = try store.read()
        #expect(document.elements.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.scheduleWrite(CanvasDocument(elements: [CanvasEditingTests.rect("a")]))
        #expect(store.hasPendingWrite)
        store.flush()
        #expect(!store.hasPendingWrite)
        let saved = try CanvasDocument.decode(Data(contentsOf: url))
        #expect(saved.elements.map(\.id) == ["a"])
        #expect(store.base == saved)
    }

    @Test @MainActor func reportsOutsideEditsButNotItsOwn() async throws {
        let url = try Self.temporaryFile()
        let store = CanvasStore(url: url)
        store.writeDelay = 0
        _ = try store.read()
        var changes: [CanvasDocument] = []
        store.onExternalChange = { remote, _ in changes.append(remote) }
        store.startWatching()
        defer { store.stopWatching() }

        // Nubb's own write is not an outside change.
        store.scheduleWrite(CanvasDocument(elements: [CanvasEditingTests.rect("mine")]))
        store.flush()
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.isEmpty)

        // An agent replaces the file atomically, as most tools save.
        var agent = store.base
        agent.elements.append(CanvasEditingTests.rect("agent", x: 300))
        try agent.encoded().write(to: url, options: .atomic)
        #expect(await Self.wait { changes.count == 1 })
        #expect(changes.last?.elements.map(\.id) == ["mine", "agent"])

        // An in-place write is seen too, after the first replace swapped the
        // watched file.
        agent.elements.append(CanvasEditingTests.rect("again", x: 600))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: agent.encoded())
        try handle.close()
        #expect(await Self.wait { changes.count == 2 })
        #expect(changes.last?.elements.count == 3)
    }

    @Test @MainActor func ignoresHalfWrittenFiles() throws {
        let url = try Self.temporaryFile()
        let store = CanvasStore(url: url)
        _ = try store.read()
        var changes = 0
        store.onExternalChange = { _, _ in changes += 1 }
        try Data(#"{"elements": [{"type": "rect"#.utf8).write(to: url)
        store.checkForChanges()
        #expect(changes == 0)
        try Data(#"{"elements": [{"type": "rectangle"}]}"#.utf8).write(to: url)
        store.checkForChanges()
        #expect(changes == 1)
    }

    @Test @MainActor func sessionMergesAgentEditsIntoOpenDrawing() async throws {
        let url = try Self.temporaryFile()
        try CanvasDocument(elements: [CanvasEditingTests.rect("a")]).encoded().write(to: url)

        let editor = CanvasEditor()
        let store = CanvasStore(url: url)
        let session = CanvasSession(editor: editor, store: store)
        session.open()
        defer { session.close() }

        // The user moves the box; the save is still waiting when the agent
        // adds a shape.
        store.writeDelay = 10
        editor.perform { CanvasOps.update("a", in: &$0) { $0.x = 50 } }
        #expect(store.hasPendingWrite)
        var agent = try CanvasDocument.decode(Data(contentsOf: url))
        agent.elements.append(CanvasEditingTests.rect("agent", x: 400))
        try agent.encoded().write(to: url, options: .atomic)

        #expect(await Self.wait { editor.document.elements.count == 2 })
        #expect(editor.document.element(id: "a")?.x == 50, "the user's edit survives")
        #expect(editor.document.element(id: "agent") != nil, "the agent's edit shows up")

        store.flush()
        let saved = try CanvasDocument.decode(Data(contentsOf: url))
        #expect(saved.element(id: "a")?.x == 50)
        #expect(saved.element(id: "agent") != nil, "the waiting save doesn't drop the agent's shape")
    }

    @Test @MainActor func sessionWaitsForTheUserToFinish() async throws {
        let url = try Self.temporaryFile()
        try CanvasDocument(elements: [CanvasEditingTests.rect("a")]).encoded().write(to: url)
        let editor = CanvasEditor()
        let store = CanvasStore(url: url)
        let session = CanvasSession(editor: editor, store: store)
        session.open()
        defer { session.close() }

        editor.beginInteraction()
        editor.updateInteraction { CanvasOps.update("a", in: &$0) { $0.x = 5 } }
        var agent = try CanvasDocument.decode(Data(contentsOf: url))
        agent.elements.append(CanvasEditingTests.rect("agent"))
        try agent.encoded().write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(editor.document.elements.count == 1, "nothing changes under a drag")

        editor.endInteraction()
        #expect(editor.document.elements.count == 2)
        #expect(editor.document.element(id: "a")?.x == 5)
    }

    @Test @MainActor func brokenFileIsReadOnlyUntilFixed() async throws {
        let url = try Self.temporaryFile()
        try Data("{ not json".utf8).write(to: url)
        let editor = CanvasEditor()
        let store = CanvasStore(url: url)
        let session = CanvasSession(editor: editor, store: store)
        session.open()
        defer { session.close() }

        #expect(!editor.isEditable)
        #expect(editor.ui.loadError != nil)
        editor.perform { $0.elements.append(CanvasEditingTests.rect("x")) }
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json", "the broken file is never overwritten")

        try CanvasDocument(elements: [CanvasEditingTests.rect("fixed")]).encoded().write(to: url, options: .atomic)
        #expect(await Self.wait { editor.isEditable })
        #expect(editor.ui.loadError == nil)
        #expect(editor.document.elements.map(\.id) == ["fixed"])
    }

    @Test func newFileNamesDontCollide() throws {
        let directory = try Self.temporaryFile().deletingLastPathComponent()
        let date = Date(timeIntervalSince1970: 0)
        let first = CanvasFiles.newFileURL(in: directory, date: date)
        try Data().write(to: first)
        let second = CanvasFiles.newFileURL(in: directory, date: date)
        #expect(first != second)
        #expect(second.pathExtension == "excalidraw")
        #expect(CanvasFiles.isCanvasFile(second.path))
    }
}
