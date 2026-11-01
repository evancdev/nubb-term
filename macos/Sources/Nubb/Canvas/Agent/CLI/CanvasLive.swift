import Darwin
import Foundation

/// The link between `nubb +canvas` and the running app, over a Unix socket
/// in the per-user temporary folder.
///
/// Each request and reply is one line of JSON. Requests carry a command
/// (`open`, `view`, `status`, `flush`) and the drawing's absolute path.
/// Only processes of the same user can connect: the socket is mode 0600
/// and each peer's uid is checked.
enum CanvasLive {
    static let protocolVersion = 1
    static let environmentKey = "NUBB_CANVAS_SOCKET"
    static let socketPrefix = "nubb-canvas-"
    static let maximumMessageSize = 8 << 20

    /// Where the app puts its socket: the per-user temporary folder, found
    /// with `confstr` so a shell with its own `TMPDIR` still finds it.
    /// `NUBB_CANVAS_SOCKET_DIR` moves it, so a second copy of the app (a
    /// preview build, a test) stays out of sight of agents using the
    /// first one.
    static var socketDirectory: String {
        if let override = ProcessInfo.processInfo.environment["NUBB_CANVAS_SOCKET_DIR"], !override.isEmpty {
            return override
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return path }
        }
        return NSTemporaryDirectory()
    }

    static func socketPath(pid: pid_t = getpid()) -> String {
        (socketDirectory as NSString).appendingPathComponent("\(socketPrefix)\(pid).sock")
    }

    /// Sockets of running Nubb processes, the newest process first.
    static func runningSockets(in directory: String = socketDirectory) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var found: [(pid: pid_t, path: String)] = []
        for name in names where name.hasPrefix(socketPrefix) && name.hasSuffix(".sock") {
            let pidText = name.dropFirst(socketPrefix.count).dropLast(".sock".count)
            guard let pid = pid_t(pidText) else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            if kill(pid, 0) == -1 && errno == ESRCH {
                unlink(path)
                continue
            }
            found.append((pid, path))
        }
        return found.sorted { $0.pid > $1.pid }.map(\.path)
    }

    // MARK: Sockets

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func configure(_ fd: Int32, timeout seconds: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads up to a newline.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumMessageSize {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if let newline = data.firstIndex(of: 0x0A) { return data[..<newline] }
        }
        return data.isEmpty || data.count > maximumMessageSize ? nil : data
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

// MARK: - Client

/// Sends viewer commands to the running app from the CLI.
struct CanvasLiveClient {
    /// The sockets to try: `NUBB_CANVAS_SOCKET` first, then every running
    /// Nubb.
    var sockets: [String]

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CanvasLiveClient? {
        var sockets: [String] = []
        if let path = environment[CanvasLive.environmentKey], !path.isEmpty { sockets.append(path) }
        for path in CanvasLive.runningSockets() where !sockets.contains(path) { sockets.append(path) }
        return sockets.isEmpty ? nil : CanvasLiveClient(sockets: sockets)
    }

    /// Sends `request` to one app and returns its reply, or nil when it
    /// can't be reached.
    func send(_ request: [String: CanvasJSON], to path: String, timeout: Int = 10) -> CanvasJSON? {
        guard var address = CanvasLive.address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        CanvasLive.configure(fd, timeout: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var message = request
        message["v"] = .number(Double(CanvasLive.protocolVersion))
        var data = CanvasJSON.object(message).compact()
        data.append(0x0A)
        guard CanvasLive.writeAll(fd, data), let reply = CanvasLive.readLine(fd) else { return nil }
        return try? CanvasJSON.parse(reply)
    }

    /// Sends `request` to every reachable app and returns the replies.
    func broadcast(_ request: [String: CanvasJSON], timeout: Int = 3) -> [(path: String, reply: CanvasJSON)] {
        sockets.compactMap { path in send(request, to: path, timeout: timeout).map { (path, $0) } }
    }

    /// Asks every app that has `url` open to write the user's unsaved
    /// edits now, so the CLI reads them. Returns whether one has it open,
    /// and whether the user is typing in it.
    @discardableResult
    func flush(_ url: URL) -> (open: Bool, editing: Bool) {
        var open = false, editing = false
        for (_, reply) in broadcast(["command": .string("flush"), "path": .string(url.path)], timeout: 2) {
            if reply["open"]?.boolValue == true { open = true }
            if reply["editing"]?.boolValue == true { editing = true }
        }
        return (open, editing)
    }

    /// The first app that has `url` open, or the newest app.
    func target(for url: URL?) -> String? {
        guard let url else { return sockets.first }
        for path in sockets {
            let reply = send(["command": .string("status"), "path": .string(url.path)], to: path, timeout: 2)
            if reply?["open"]?.boolValue == true { return path }
        }
        return sockets.first
    }
}

extension CanvasJSON {
    /// JSON on one line, for the wire.
    func compact() -> Data {
        var out = ""
        writeCompact(into: &out)
        return Data(out.utf8)
    }

    private func writeCompact(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value): out += CanvasJSON.format(value)
        case .string(let value):
            // The pretty writer's escaping, without its newline.
            var text = CanvasJSON.string(value).text
            text.removeLast()
            out += text
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.writeCompact(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                CanvasJSON.string(key).writeCompact(into: &out)
                out += ":"
                members[key]!.writeCompact(into: &out)
            }
            out += "}"
        }
    }
}
