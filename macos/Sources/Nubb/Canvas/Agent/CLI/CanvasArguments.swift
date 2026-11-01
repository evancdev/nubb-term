import Foundation

/// Parsed command-line arguments: positional words and `--options`.
///
/// Options take a value with a space or `=` (`--frame Intro`,
/// `--frame=Intro`). Flags take none. Anything after `--` is positional,
/// and `-` names stdin.
struct CanvasArguments {
    var positional: [String] = []
    private(set) var options: [String: [String]] = [:]
    private(set) var flags: Set<String> = []
    /// Options and flags never asked for, reported as unknown at the end.
    private var unread: Set<String> = []

    /// Short options and the long names they stand for.
    static let shortOptions: [String: String] = ["-o": "out", "-h": "help", "-j": "json"]

    /// Reads `args` given which options take values. Unknown `--words`
    /// count as flags, so `finish` can name them.
    init(_ args: [String], valued: Set<String>) throws {
        var index = 0
        var onlyPositional = false
        while index < args.count {
            var arg = args[index]
            index += 1
            if !onlyPositional, let long = Self.shortOptions[arg] { arg = "--" + long }
            if onlyPositional || !arg.hasPrefix("--") || arg == "-" {
                positional.append(arg)
                continue
            }
            if arg == "--" {
                onlyPositional = true
                continue
            }
            var name = String(arg.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if valued.contains(name) {
                if value == nil {
                    guard index < args.count else { throw CanvasAgentError.usage("--\(name) needs a value") }
                    value = args[index]
                    index += 1
                }
                options[name, default: []].append(value!)
            } else {
                if value != nil { throw CanvasAgentError.usage("--\(name) takes no value") }
                flags.insert(name)
            }
            unread.insert(name)
        }
    }

    mutating func flag(_ name: String) -> Bool {
        unread.remove(name)
        return flags.contains(name)
    }

    mutating func value(_ name: String) -> String? {
        unread.remove(name)
        return options[name]?.last
    }

    mutating func values(_ name: String) -> [String] {
        unread.remove(name)
        return options[name] ?? []
    }

    mutating func number(_ name: String, range: ClosedRange<Double>) throws -> Double? {
        guard let text = value(name) else { return nil }
        guard let number = Double(text), range.contains(number) else {
            throw CanvasAgentError.usage("--\(name) takes a number from \(CanvasJSON.format(range.lowerBound)) to \(CanvasJSON.format(range.upperBound))")
        }
        return number
    }

    /// Fails on options nobody asked for, and on extra positional words.
    func finish(command: String, maxPositional: Int) throws {
        if let name = unread.sorted().first {
            throw CanvasAgentError.usage("\(command): unknown option --\(name); see `nubb +canvas help`")
        }
        if positional.count > maxPositional {
            throw CanvasAgentError.usage("\(command): unexpected argument \"\(positional[maxPositional])\"; see `nubb +canvas help`")
        }
    }
}

/// Text a command prints, and its exit code.
struct CanvasCommandResult {
    var stdout = ""
    var stderr = ""
    var exit: Int32 = 0

    static func ok(_ text: String) -> CanvasCommandResult {
        CanvasCommandResult(stdout: text.isEmpty || text.hasSuffix("\n") ? text : text + "\n")
    }

    static func failure(_ error: Error) -> CanvasCommandResult {
        let message: String
        let code: Int32
        switch error {
        case CanvasAgentError.usage(let text):
            message = text
            code = 2
        case CanvasAgentError.spec(let issues):
            let lines = issues.prefix(40).map { "  \($0.description)" }
            let more = issues.count > 40 ? ["  ... and \(issues.count - 40) more"] : []
            message = "the spec has \(issues.count) problem\(issues.count == 1 ? "" : "s"):\n" + (lines + more).joined(separator: "\n")
            code = 2
        case CanvasAgentError.conflict:
            message = "the drawing kept changing while the command ran; try again"
            code = 1
        default:
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            code = 1
        }
        return CanvasCommandResult(stderr: "nubb +canvas: " + message + "\n", exit: code)
    }
}

/// Where a command's input comes from and where relative paths start.
struct CanvasCommandContext {
    var cwd: URL
    var readStdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    /// Talks to the running app, for the commands that need the viewer.
    var live: CanvasLiveClient? = CanvasLiveClient.fromEnvironment()

    func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
    }

    /// The JSON in a file, `-` for stdin, or given inline.
    func json(from source: String, what: String) throws -> CanvasJSON {
        let data: Data
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == "-" {
            data = readStdin()
        } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            data = Data(source.utf8)
        } else {
            let url = url(source)
            guard let contents = try? Data(contentsOf: url) else {
                throw CanvasAgentError.usage("can't read \(what) from \(url.path)")
            }
            data = contents
        }
        do {
            return try CanvasJSON.parse(data)
        } catch let error as CanvasJSON.ParseError {
            let (line, column) = Self.position(of: error.offset, in: data)
            throw CanvasAgentError.usage("\(what) isn't valid JSON: \(error.message) at line \(line), column \(column)")
        } catch {
            throw CanvasAgentError.usage("\(what) isn't valid JSON")
        }
    }

    private static func position(of offset: Int, in data: Data) -> (Int, Int) {
        var line = 1, column = 1
        for byte in data.prefix(offset) {
            if byte == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }
}
