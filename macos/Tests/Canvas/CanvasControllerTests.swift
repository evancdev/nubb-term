import AppKit
import Foundation
import Testing
@testable import Nubb

/// A canvas tab as the app opens it: a real window and controller on a file.
@Suite(.serialized)
@MainActor
struct CanvasControllerTests {
    private static func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nubb-canvas-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("drawing.excalidraw")
    }

    private static func wait(timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static var app: Nubb.App? { (NSApp.delegate as? AppDelegate)?.nubb }

    /// Nothing but the window refers to its controller, and windows don't
    /// retain their controllers. The canvas must stay alive, saving and
    /// watching its file, until its window closes, and go away after.
    @Test func staysAliveWhileOpenAndIsReleasedAfterClosing() async throws {
        guard let app = Self.app else { return }
        let url = try Self.temporaryFile()

        weak var weakController: CanvasController?
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let controller = CanvasController.open(url, nubb: app, from: nil)
            weakController = controller
            weakWindow = controller.window
            controller.window?.orderOut(nil)
        }

        // A few turns later, after any autorelease pools drained.
        try await Task.sleep(for: .milliseconds(100))
        #expect(weakController != nil)
        if let controller = weakController {
            try await Self.exercise(controller, url: url, app: app)
        }

        #expect(await Self.wait { weakController == nil })
        #expect(await Self.wait { weakWindow == nil })
        #expect(CanvasController.all.isEmpty)
    }

    /// Edits, merges an outside change, reopens, and closes. Kept apart so
    /// the test holds no strong reference once it returns.
    private static func exercise(_ controller: CanvasController, url: URL, app: Nubb.App) async throws {
        #expect(controller.window?.windowController === controller)
        #expect(CanvasController.all.contains { $0 === controller })

        // It still saves edits and sees outside changes.
        controller.store.writeDelay = 0
        controller.editor.perform { $0.elements.append(CanvasEditingTests.rect("mine")) }
        controller.store.flush()
        let saved = try CanvasDocument.decode(Data(contentsOf: url))
        #expect(saved.elements.map(\.id) == ["mine"])

        var agent = saved
        agent.elements.append(CanvasEditingTests.rect("agent", x: 300))
        try agent.encoded().write(to: url, options: .atomic)
        #expect(await wait { controller.editor.document.elements.count == 2 })

        // Reopening the same file brings back the same tab.
        #expect(CanvasController.open(url, nubb: app, from: nil) === controller)
        controller.window?.orderOut(nil)

        controller.closeImmediately()
    }
}
