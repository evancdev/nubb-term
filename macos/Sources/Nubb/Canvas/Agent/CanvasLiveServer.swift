import AppKit
import Darwin
import Foundation

/// Answers `nubb +canvas` commands that need the app: opening drawings,
/// moving the camera, and saving the user's edits before the CLI reads.
///
/// Requests come over a Unix socket, one JSON line each way. The work runs
/// on the main thread, where the canvases live.
final class CanvasLiveServer: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "com.evancdev.nubb.canvas-live", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    /// The app's server, started the first time a terminal needs the address.
    @MainActor
    static let shared: CanvasLiveServer? = {
        _ = CanvasLive.runningSockets()
        let server = CanvasLiveServer(path: CanvasLive.socketPath())
        do {
            try server.start()
            return server
        } catch {
            Nubb.logger.warning("canvas socket failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    /// Adds the socket address to a new terminal's environment.
    @MainActor
    static func addEnvironment(to environment: inout [String: String]) {
        guard environment[CanvasLive.environmentKey] == nil, let server = shared else { return }
        environment[CanvasLive.environmentKey] = server.path
    }

    // MARK: Lifecycle

    enum StartError: LocalizedError {
        case pathTooLong
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong: "socket path is too long"
            case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    func start() throws {
        precondition(listenFD < 0, "server already started")
        guard var address = CanvasLive.address(path) else { throw StartError.pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        guard listenFD >= 0 else { return }
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        CanvasLive.configure(fd, timeout: 10)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return }

        let reply: CanvasJSON
        if let data = CanvasLive.readLine(fd), let request = try? CanvasJSON.parse(data) {
            if request["v"]?.intValue != CanvasLive.protocolVersion {
                reply = .object(["ok": .bool(false), "error": .string("this nubb binary doesn't match the running app; open a new terminal")])
            } else {
                reply = DispatchQueue.main.sync { MainActor.assumeIsolated { CanvasLiveCommands.handle(request) } }
            }
        } else {
            reply = .object(["ok": .bool(false), "error": .string("malformed request")])
        }
        var data = reply.compact()
        data.append(0x0A)
        _ = CanvasLive.writeAll(fd, data)
    }
}

/// The app side of the viewer commands.
@MainActor
enum CanvasLiveCommands {
    static func handle(_ request: CanvasJSON) -> CanvasJSON {
        let command = request["command"]?.stringValue ?? ""
        let url = request["path"]?.stringValue.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let controller = url.flatMap { url in CanvasController.all.first { $0.url == url } }
        switch command {
        case "status":
            return status(controller, url: url)
        case "flush":
            guard let controller else { return .object(["ok": .bool(true), "open": .bool(false)]) }
            // Apply what the file says now, then write what the user did.
            controller.store.checkForChanges()
            controller.store.flush()
            return .object([
                "ok": .bool(true), "open": .bool(true),
                "editing": .bool(controller.canvasView.textEditing != nil || controller.editor.isInteracting),
            ])
        case "open":
            guard let url else { return failure("open needs a path") }
            let opened = controller ?? open(url, background: request["background"]?.boolValue == true)
            guard let opened else { return failure("can't open \(url.path)") }
            if request["background"]?.boolValue != true { opened.window?.makeKeyAndOrderFront(nil) }
            return applyView(request, to: opened)
        case "view":
            guard let url else { return failure("view needs a path") }
            guard let target = controller ?? open(url, background: false) else { return failure("can't open \(url.path)") }
            target.window?.makeKeyAndOrderFront(nil)
            return applyView(request, to: target)
        case "list":
            return .object(["ok": .bool(true), "open": .array(CanvasController.all.map { .string($0.url.path) })])
        default:
            return failure("unknown command \"\(command)\"")
        }
    }

    private static func failure(_ message: String) -> CanvasJSON {
        .object(["ok": .bool(false), "error": .string(message)])
    }

    private static func open(_ url: URL, background: Bool) -> CanvasController? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        let parent: NSWindow? = {
            if let main = NSApp.mainWindow, main.windowController is TabSidebarTab { return main }
            return TerminalController.preferredParent?.window
        }()
        let previous = NSApp.keyWindow
        let controller = CanvasController.open(url, nubb: delegate.nubb, from: parent)
        if background, let previous, previous !== controller.window {
            previous.tabGroup?.selectedWindow = previous
            previous.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    private static func status(_ controller: CanvasController?, url: URL?) -> CanvasJSON {
        guard let controller else {
            return .object(["ok": .bool(true), "open": .bool(false), "path": url.map { .string($0.path) } ?? .null])
        }
        let viewport = controller.canvasView.viewport
        let size = controller.canvasView.bounds.size
        let visible = viewport.toScene(CGRect(origin: .zero, size: size))
        return .object([
            "ok": .bool(true),
            "open": .bool(true),
            "path": .string(controller.url.path),
            "zoom": .number((viewport.zoom * 1000).rounded() / 1000),
            "visible": .array([visible.minX, visible.minY, visible.width, visible.height].map { .number((Double($0) * 10).rounded() / 10) }),
            "selected": .array(controller.editor.selection.sorted().map(CanvasJSON.string)),
            "editing": .bool(controller.canvasView.textEditing != nil),
            "focused": .bool(controller.window?.isKeyWindow == true),
            "elements": .number(Double(controller.editor.document.elements.count)),
            "unsaved": .bool(controller.store.hasPendingWrite),
        ])
    }

    /// Moves the camera as the request asks: to a frame by name or id, to
    /// elements, to a region, to everything, or to a zoom.
    private static func applyView(_ request: CanvasJSON, to controller: CanvasController) -> CanvasJSON {
        let view = controller.canvasView!
        view.layoutSubtreeIfNeeded()
        let document = controller.editor.document
        let padding = request["padding"]?.doubleValue ?? 60
        var target: CGRect?
        var maxZoom = request["zoom"]?.doubleValue ?? 1

        if let frame = request["frame"]?.stringValue {
            guard let element = CanvasQuery.frame(named: frame, in: document) else {
                return failure("no frame named \"\(frame)\"" + CanvasQuery.frameHint(frame, in: document))
            }
            target = element.sceneBounds
            maxZoom = request["zoom"]?.doubleValue ?? CanvasViewport.maxZoom
        } else if let ids = request["ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty {
            let wanted = CanvasOps.withFrameChildren(Set(ids), in: document)
            let elements = document.elements.filter { wanted.contains($0.id) }
            let missing = Set(ids).subtracting(document.elements.map(\.id))
            guard !elements.isEmpty else { return failure("no elements \(missing.sorted().joined(separator: ", "))") }
            target = CanvasRenderer.sceneBounds(of: elements)
            maxZoom = request["zoom"]?.doubleValue ?? 1
            if request["select"]?.boolValue == true { controller.editor.select(Set(ids).intersection(document.elements.map(\.id))) }
        } else if let region = request["region"]?.arrayValue?.compactMap(\.doubleValue), region.count == 4 {
            target = CGRect(x: region[0], y: region[1], width: region[2], height: region[3])
            maxZoom = request["zoom"]?.doubleValue ?? CanvasViewport.maxZoom
        } else if request["fit"]?.boolValue == true {
            target = CanvasRenderer.sceneBounds(of: document.elements)
            maxZoom = request["zoom"]?.doubleValue ?? 1
        }

        if let target, !target.isNull {
            view.viewport = .fitting(target, in: view.bounds.size, padding: padding, maxZoom: maxZoom)
        } else if let zoom = request["zoom"]?.doubleValue {
            var next = view.viewport
            next.zoom(to: zoom, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            view.viewport = next
        }
        if let id = request["hover"]?.stringValue {
            // Point at an element: its name, where the pointer would rest.
            let document = controller.editor.document
            guard let element = document.element(id: id) ?? document.element(id: CanvasLayout.partID(id, "label")).flatMap({ $0.containerId.flatMap(document.element(id:)) }) else {
                return failure("no element \"\(id)\"")
            }
            guard let name = element.hoverName else { return failure("\"\(id)\" has no name to show; set one with name=") }
            let point = element.type.isLinear && element.points.count > 1
                ? element.toScene(CGPoint(x: (element.points[0].x + element.points[1].x) / 2, y: (element.points[0].y + element.points[1].y) / 2))
                : element.center
            let screen = view.viewport.toScreen(point)
            view.lastPointer = screen
            view.showHover(name, for: element.id, near: screen)
        }
        return status(controller, url: controller.url)
    }
}
