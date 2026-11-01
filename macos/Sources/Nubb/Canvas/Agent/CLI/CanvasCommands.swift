import AppKit
import Foundation

/// The commands of `nubb +canvas`. Everything but the viewer commands runs
/// in the CLI process on the file itself; the viewer commands talk to the
/// running app.
enum CanvasCommands {
    static func run(_ args: [String], context: CanvasCommandContext) -> CanvasCommandResult {
        guard let command = args.first, !["help", "--help", "-h"].contains(command) else {
            let topic = args.dropFirst().first
            return .ok(topic == "spec" ? CanvasManual.spec : CanvasManual.text)
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "new": return try new(rest, context)
            case "apply": return try apply(rest, context)
            case "set": return try set(rest, context)
            case "move": return try move(rest, context)
            case "delete", "rm": return try delete(rest, context)
            case "reset": return try reset(rest, context)
            case "info": return try info(rest, context)
            case "list", "ls": return try list(rest, context)
            case "get": return try get(rest, context)
            case "frames": return try frames(rest, context)
            case "spec": return try spec(rest, context)
            case "measure": return try measure(rest, context)
            case "changes": return try changes(rest, context)
            case "render", "export": return try render(rest, context)
            case "lint": return try lint(rest, context)
            case "fix": return try fix(rest, context)
            case "open": return try open(rest, context)
            case "view": return try view(rest, context)
            case "status": return try status(rest, context)
            case "copy": return try copy(rest, context)
            default:
                let commands = ["new", "apply", "set", "move", "delete", "reset", "info", "list", "get", "frames", "spec",
                                "measure", "changes", "render", "lint", "fix", "open", "view", "status", "copy", "help"]
                let hint = CanvasSpecNames.suggestion(for: command, in: commands).map { " (did you mean \"\($0)\"?)" } ?? ""
                throw CanvasAgentError.usage("unknown command \"\(command)\"\(hint); run `nubb +canvas help`")
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: Helpers

    private static func file(_ args: CanvasArguments, _ context: CanvasCommandContext, command: String) throws -> URL {
        guard let path = args.positional.first else {
            throw CanvasAgentError.usage("\(command) needs a drawing: nubb +canvas \(command) <file.excalidraw> ...")
        }
        let url = context.url(path)
        if url.pathExtension.lowercased() != CanvasDocument.fileExtension, url.pathExtension.lowercased() != "json" {
            throw CanvasAgentError.usage("\(path) isn't a .excalidraw file")
        }
        return url
    }

    /// The drawing as it is now, with the viewer's unsaved edits written
    /// first.
    private static func read(_ url: URL, _ context: CanvasCommandContext) throws -> CanvasAgentDocument {
        context.live?.flush(url)
        return try CanvasAgentDocument(url: url, create: false)
    }

    private static func display(_ url: URL, _ context: CanvasCommandContext) -> String {
        let path = url.path
        let cwd = context.cwd.standardizedFileURL.path + "/"
        return path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
    }

    private static func json(_ value: CanvasJSON) -> CanvasCommandResult {
        .ok(value.text)
    }

    /// `x,y,w,h` as a rectangle.
    private static func region(_ text: String) throws -> CGRect {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
            throw CanvasAgentError.usage("--region takes x,y,width,height like 0,0,800,600")
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func ids(_ values: [String]) -> [String] {
        values.flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    }

    // MARK: Writing

    private static func new(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "new")
        let force = args.flag("force")
        try args.finish(command: "new", maxPositional: 1)
        if FileManager.default.fileExists(atPath: url.path), !force {
            throw CanvasAgentError.failed("\(display(url, context)) exists; use --force to replace it")
        }
        try CanvasAgentStore.withLock(for: url) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CanvasDocument().encoded().write(to: url, options: .atomic)
            CanvasAgentStore.remove(for: url)
        }
        return .ok("created \(display(url, context))")
    }

    private static func apply(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "apply")
        guard args.positional.count >= 2 else {
            throw CanvasAgentError.usage("apply needs a spec: a file, - for stdin, or inline JSON; see `nubb +canvas help spec`")
        }
        let spec = try context.json(from: args.positional[1], what: "the spec")
        let dryRun = args.flag("dry-run")
        let asJSON = args.flag("json")
        let runLint = args.flag("lint")
        let openViewer = args.flag("open")
        let quiet = args.flag("quiet")
        try args.finish(command: "apply", maxPositional: 2)
        return try write(url, context, dryRun: dryRun, asJSON: asJSON, runLint: runLint, open: openViewer, quiet: quiet) { file in
            try CanvasEngine.apply(spec, to: file)
        }
    }

    /// Runs a change on the drawing, saves it, and reports it.
    private static func write(
        _ url: URL, _ context: CanvasCommandContext, dryRun: Bool = false, asJSON: Bool = false, runLint: Bool = false,
        open: Bool = false, quiet: Bool = false, create: Bool = true, _ change: (CanvasAgentDocument) throws -> CanvasApplyReport
    ) throws -> CanvasCommandResult {
        let viewer = context.live?.flush(url)
        let (report, document) = try CanvasAgentDocument.edit(url, create: create) { file -> (CanvasApplyReport, CanvasDocument) in
            let report = try change(file)
            if !dryRun { try file.save() }
            return (report, file.document)
        }
        var lintIssues: [CanvasLintIssue] = []
        if runLint { lintIssues = CanvasLint.run(document) }
        var viewerNote: String?
        if open, !dryRun {
            viewerNote = try openInViewer(url, context, request: ["fit": .bool(viewer?.open != true)])
        }
        if asJSON {
            var object = reportJSON(report, url: url, context: context)
            object["dryRun"] = .bool(dryRun)
            if runLint { object["lint"] = .array(lintIssues.map(issueJSON)) }
            return json(.object(object))
        }
        var lines: [String] = []
        let verb = dryRun ? "would change" : "updated"
        if report.changed {
            lines.append("\(verb) \(display(url, context)): \(report.created.count) created, \(report.updated.count) updated, \(report.deleted.count) deleted")
        } else {
            lines.append("\(display(url, context)): no changes")
        }
        if !quiet {
            for unit in report.units { lines.append("  \(unit.id)  \(CanvasQuery.rect(unit.box))") }
        }
        let userChanges = report.userChanges.filter { !CanvasDiff.isFollower($0) }
        if !userChanges.isEmpty {
            lines.append("kept \(userChanges.count) change\(userChanges.count == 1 ? "" : "s") made by hand since the last write:")
            for change in userChanges.prefix(30) { lines.append("  \(change.id)  \(CanvasQuery.describe(change))") }
            if userChanges.count > 30 { lines.append("  ... and \(userChanges.count - 30) more (see `changes`)") }
        }
        if !report.hidden.isEmpty {
            lines.append("not drawn, deleted by hand: \(report.hidden.sorted().joined(separator: ", ")) (`reset` brings them back)")
        }
        if !report.warnings.isEmpty {
            lines.append("warnings:")
            lines.append(contentsOf: report.warnings.map { "  \($0)" })
        }
        if runLint {
            lines.append(lintIssues.isEmpty ? "lint: no problems" : "lint: \(lintIssues.count) problem\(lintIssues.count == 1 ? "" : "s"):")
            lines.append(contentsOf: lintIssues.map { "  \($0.kind.rawValue)  \($0.message)" })
        }
        if viewer?.editing == true {
            lines.append("note: the user is editing text in the viewer; the change shows when they finish")
        }
        if let viewerNote { lines.append(viewerNote) }
        var result = CanvasCommandResult.ok(lines.joined(separator: "\n"))
        if runLint, !lintIssues.isEmpty { result.exit = 1 }
        return result
    }

    private static func reportJSON(_ report: CanvasApplyReport, url: URL, context: CanvasCommandContext) -> [String: CanvasJSON] {
        [
            "file": .string(url.path),
            "created": .array(report.created.sorted().map(CanvasJSON.string)),
            "updated": .array(report.updated.sorted().map(CanvasJSON.string)),
            "deleted": .array(report.deleted.map(CanvasJSON.string)),
            "units": .array(report.units.map { .object(["id": .string($0.id), "box": CanvasQuery.rectJSON($0.box)]) }),
            "boxes": .object(report.boxes.mapValues(CanvasQuery.rectJSON)),
            "warnings": .array(report.warnings.map(CanvasJSON.string)),
            "hidden": .array(report.hidden.sorted().map(CanvasJSON.string)),
            "userChanges": .array(report.userChanges.map(changeJSON)),
        ]
    }

    private static func changeJSON(_ change: CanvasElementChange) -> CanvasJSON {
        var object: [String: CanvasJSON] = [
            "id": .string(change.id),
            "kind": .string(change.kind.rawValue),
            "type": .string(change.element.type.rawValue),
            "summary": .string(CanvasQuery.describe(change)),
        ]
        if let unit = change.unit { object["node"] = .string(unit) }
        if let moved = change.moved { object["moved"] = .array([.number(Double(moved.dx)), .number(Double(moved.dy))]) }
        if change.kind == .modified {
            var fields: [String: CanvasJSON] = [:]
            for (key, value) in change.fields where !["version", "versionNonce", "updated", "seed"].contains(key) {
                fields[key] = .object(["old": value.old ?? .null, "new": value.new ?? .null])
            }
            object["fields"] = .object(fields)
        }
        return .object(object)
    }

    private static let stringKeys: Set<String> = ["text", "label", "name", "code", "content", "link", "id"]

    /// `key=value` pairs, or one JSON object.
    private static func fields(_ words: [String], _ context: CanvasCommandContext) throws -> [String: CanvasJSON] {
        if words.count == 1, words[0].trimmingCharacters(in: .whitespaces).hasPrefix("{") || words[0] == "-" {
            guard let object = try context.json(from: words[0], what: "the fields").objectValue else {
                throw CanvasAgentError.usage("set takes key=value pairs or a JSON object")
            }
            return object
        }
        var result: [String: CanvasJSON] = [:]
        for word in words {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
                throw CanvasAgentError.usage("set takes key=value pairs like text=\"New title\" size=28, or a JSON object; got \"\(word)\"")
            }
            let key = String(word[..<equals])
            let text = String(word[word.index(after: equals)...])
            if stringKeys.contains(key) {
                result[key] = .string(text.replacingOccurrences(of: "\\n", with: "\n"))
            } else if let value = try? CanvasJSON.parse(Data(text.utf8)) {
                result[key] = value
            } else {
                result[key] = .string(text)
            }
        }
        return result
    }

    private static func set(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "set")
        guard args.positional.count >= 3 else {
            throw CanvasAgentError.usage("set needs an id and fields: nubb +canvas set <file> <id> text=\"New text\"")
        }
        let id = args.positional[1]
        let fields = try fields(Array(args.positional[2...]), context)
        let asJSON = args.flag("json"), runLint = args.flag("lint"), quiet = args.flag("quiet")
        try args.finish(command: "set", maxPositional: args.positional.count)
        let spec = CanvasJSON.object(["set": .object([id: .object(fields)])])
        return try write(url, context, asJSON: asJSON, runLint: runLint, quiet: quiet, create: false) { file in
            try CanvasEngine.apply(spec, to: file)
        }
    }

    private static func move(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "move")
        guard args.positional.count == 4, let dx = Double(args.positional[2]), let dy = Double(args.positional[3]) else {
            throw CanvasAgentError.usage("move needs an id and how far: nubb +canvas move <file> <id> <dx> <dy>")
        }
        let id = args.positional[1]
        let asJSON = args.flag("json"), quiet = args.flag("quiet")
        try args.finish(command: "move", maxPositional: 4)
        let spec = CanvasJSON.object(["move": .object([id: .array([.number(dx), .number(dy)])])])
        return try write(url, context, asJSON: asJSON, quiet: quiet, create: false) { file in
            try CanvasEngine.apply(spec, to: file)
        }
    }

    private static func delete(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "delete")
        let targets = ids(Array(args.positional.dropFirst()))
        guard !targets.isEmpty else { throw CanvasAgentError.usage("delete needs ids: nubb +canvas delete <file> <id>...") }
        let asJSON = args.flag("json"), quiet = args.flag("quiet")
        try args.finish(command: "delete", maxPositional: args.positional.count)
        let spec = CanvasJSON.object(["delete": .array(targets.map(CanvasJSON.string))])
        return try write(url, context, asJSON: asJSON, quiet: quiet, create: false) { file in
            try CanvasEngine.apply(spec, to: file)
        }
    }

    private static func reset(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "reset")
        let targets = ids(Array(args.positional.dropFirst()))
        let all = args.flag("all")
        let asJSON = args.flag("json"), quiet = args.flag("quiet")
        try args.finish(command: "reset", maxPositional: args.positional.count)
        guard all || !targets.isEmpty else {
            throw CanvasAgentError.usage("reset needs ids, or --all to drop every change made by hand to what apply drew")
        }
        return try write(url, context, asJSON: asJSON, quiet: quiet, create: false) { file in
            try CanvasEngine.reset(all ? [] : targets, in: file)
        }
    }

    private static func fix(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "fix")
        let dryRun = args.flag("dry-run"), asJSON = args.flag("json")
        try args.finish(command: "fix", maxPositional: 1)
        var fixed: [String] = []
        let result = try write(url, context, dryRun: dryRun, asJSON: asJSON, quiet: true, create: false) { file in
            var report = try CanvasEngine.refresh(file)
            fixed = CanvasLint.fix(&file.document)
            report.updated = Array(Set(report.updated).union(fixed)).sorted()
            return report
        }
        guard !asJSON else { return result }
        let remaining = try CanvasAgentDocument(url: url, create: false)
        let issues = CanvasLint.run(remaining.document)
        var text = result.stdout
        text += fixed.isEmpty ? "nothing to fix by remeasuring\n" : "remeasured \(fixed.count) element\(fixed.count == 1 ? "" : "s"): \(fixed.prefix(20).joined(separator: ", "))\n"
        text += issues.isEmpty ? "lint: no problems\n" : "lint: \(issues.count) problem\(issues.count == 1 ? "" : "s") left to fix by hand (run `lint`)\n"
        return .ok(text)
    }

    // MARK: Reading

    private static func info(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "info")
        let asJSON = args.flag("json")
        try args.finish(command: "info", maxPositional: 1)
        let file = try read(url, context)
        let document = file.document
        var counts: [String: Int] = [:]
        for element in document.elements { counts[element.type.rawValue, default: 0] += 1 }
        let bounds = CanvasRenderer.sceneBounds(of: document.elements)
        let frames = CanvasQuery.frames(in: document)
        let changes = file.state.hasBaseline ? CanvasDiff.changes(from: file.state.written, to: document) : []
        if asJSON {
            return json(.object([
                "file": .string(url.path),
                "elements": .number(Double(document.elements.count)),
                "types": .object(counts.mapValues { .number(Double($0)) }),
                "bounds": bounds.isNull ? .null : CanvasQuery.rectJSON(bounds),
                "frames": .array(frames.map { .object(["id": .string($0.id), "name": .string(CanvasRenderer.frameTitle($0)), "box": CanvasQuery.rectJSON($0.sceneBounds)]) }),
                "nodes": .array(file.state.unitOrder.map { id in
                    .object(["id": .string(id), "box": file.state.units[id]?.boxes[id].map(CanvasQuery.rectJSON) ?? .null])
                }),
                "changesByHand": .number(Double(changes.count)),
            ]))
        }
        var lines = ["\(display(url, context)): \(document.elements.count) elements"
            + (counts.isEmpty ? "" : " (" + counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ")")]
        if !bounds.isNull { lines.append("bounds \(CanvasQuery.rect(bounds))") }
        if !frames.isEmpty {
            lines.append("\(frames.count) frame\(frames.count == 1 ? "" : "s"):")
            for frame in frames { lines.append("  \(frame.id)  \(CanvasQuery.rect(frame.sceneBounds))  \"\(CanvasRenderer.frameTitle(frame))\"") }
        }
        if !file.state.unitOrder.isEmpty {
            lines.append("\(file.state.unitOrder.count) top-level node\(file.state.unitOrder.count == 1 ? "" : "s") from apply: "
                + file.state.unitOrder.prefix(40).joined(separator: ", "))
        }
        if !changes.isEmpty { lines.append("\(changes.count) change\(changes.count == 1 ? "" : "s") by hand since the last write (see `changes`)") }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func list(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: ["frame", "type", "near", "limit"])
        let url = try file(args, context, command: "list")
        let frameName = args.value("frame")
        let types = Set(ids(args.values("type")))
        let near = try args.value("near").map(region)
        let limit = Int(try args.number("limit", range: 1...1_000_000) ?? 2000)
        let asJSON = args.flag("json"), idsOnly = args.flag("ids")
        try args.finish(command: "list", maxPositional: 1)
        let document = try read(url, context).document
        var elements = document.elements
        let membership = CanvasRenderer.FrameMembership(document)
        if let frameName {
            guard let frame = CanvasQuery.frame(named: frameName, in: document) else {
                throw CanvasAgentError.failed("no frame named \"\(frameName)\"" + CanvasQuery.frameHint(frameName, in: document))
            }
            elements = elements.filter { $0.id == frame.id || membership.frame(of: $0)?.id == frame.id }
        }
        if !types.isEmpty { elements = elements.filter { types.contains($0.type.rawValue) } }
        if let near { elements = elements.filter { $0.sceneBounds.intersects(near) } }
        let total = elements.count
        elements = Array(elements.prefix(limit))
        if asJSON {
            return json(.array(elements.map { element in
                var object: [String: CanvasJSON] = [
                    "id": .string(element.id), "type": .string(element.type.rawValue), "box": CanvasQuery.rectJSON(element.sceneBounds),
                ]
                if element.type == .text { object["text"] = .string(element.originalText.isEmpty ? element.text : element.originalText) }
                if let label = element.boundTextID { object["label"] = .string(label) }
                if let container = element.containerId { object["container"] = .string(container) }
                if let frame = membership.frame(of: element) { object["frame"] = .string(frame.id) }
                if element.type == .frame { object["name"] = .string(CanvasRenderer.frameTitle(element)) }
                if let name = element.hoverName { object["name"] = .string(name) }
                if element.type.isLinear {
                    object["from"] = element.startBinding.map { .string($0.elementId) } ?? .null
                    object["to"] = element.endBinding.map { .string($0.elementId) } ?? .null
                }
                return .object(object)
            }))
        }
        if idsOnly { return .ok(elements.map(\.id).joined(separator: "\n")) }
        var lines = elements.map { CanvasQuery.summary($0, in: document, frames: membership) }
        if total > elements.count { lines.append("... \(total - elements.count) more (use --limit or --frame)") }
        if lines.isEmpty { lines.append("no elements") }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func get(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "get")
        let targets = ids(Array(args.positional.dropFirst()))
        guard !targets.isEmpty else { throw CanvasAgentError.usage("get needs ids: nubb +canvas get <file> <id>...") }
        try args.finish(command: "get", maxPositional: args.positional.count)
        let file = try read(url, context)
        var results: [CanvasJSON] = []
        for id in targets {
            if let element = file.document.element(id: id) {
                results.append(element.json)
            } else if let unitID = file.state.unit(owning: id), let unit = file.state.units[unitID] {
                let path = CanvasSpecTree.find(id, in: unit.spec, rootID: unitID)
                var object: [String: CanvasJSON] = [
                    "node": .string(id),
                    "elements": .array((unit.nodes[id] ?? []).map(CanvasJSON.string)),
                    "box": unit.boxes[id].map(CanvasQuery.rectJSON) ?? .null,
                ]
                if let path, let spec = CanvasSpecTree.get(path, in: unit.spec) { object["spec"] = spec }
                results.append(.object(object))
            } else {
                throw CanvasAgentError.failed("no element or node \"\(id)\"" + CanvasEngine.hint(id, in: file))
            }
        }
        return json(results.count == 1 ? results[0] : .array(results))
    }

    private static func spec(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "spec")
        let targets = ids(Array(args.positional.dropFirst()))
        try args.finish(command: "spec", maxPositional: args.positional.count)
        let state = CanvasAgentStore.load(for: url)
        var nodes: [CanvasJSON] = []
        for id in targets.isEmpty ? state.unitOrder : targets {
            guard let unitID = state.unit(owning: id), let unit = state.units[unitID],
                  let path = CanvasSpecTree.find(id, in: unit.spec, rootID: unitID),
                  let node = CanvasSpecTree.get(path, in: unit.spec) else {
                throw CanvasAgentError.failed("no node \"\(id)\" made by apply")
            }
            nodes.append(node)
        }
        var object: [String: CanvasJSON] = ["nodes": .array(nodes)]
        if targets.isEmpty {
            if !state.styles.isEmpty { object["styles"] = .object(state.styles) }
            if !state.defaults.isEmpty { object["defaults"] = .object(state.defaults) }
        }
        return json(.object(object))
    }

    private static func frames(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "frames")
        let asJSON = args.flag("json")
        try args.finish(command: "frames", maxPositional: 1)
        let document = try read(url, context).document
        let membership = CanvasRenderer.FrameMembership(document)
        var counts: [String: Int] = [:]
        for element in document.elements { if let frame = membership.frame(of: element) { counts[frame.id, default: 0] += 1 } }
        let frames = CanvasQuery.frames(in: document)
        if asJSON {
            return json(.array(frames.map { frame in
                .object([
                    "id": .string(frame.id), "name": .string(CanvasRenderer.frameTitle(frame)),
                    "box": CanvasQuery.rectJSON(frame.sceneBounds), "elements": .number(Double(counts[frame.id] ?? 0)),
                ])
            }))
        }
        guard !frames.isEmpty else { return .ok("no frames") }
        return .ok(frames.map { "\($0.id)  \(CanvasQuery.rect($0.sceneBounds))  \(counts[$0.id] ?? 0) elements  \"\(CanvasRenderer.frameTitle($0))\"" }
            .joined(separator: "\n"))
    }

    private static func measure(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: ["font", "size", "width", "line-height", "spec", "in"])
        let asJSON = args.flag("json")
        if let source = args.value("spec") {
            let theme = try args.value("in").map { CanvasEngine.themeJSON(CanvasAgentStore.load(for: context.url($0))) }
            try args.finish(command: "measure", maxPositional: 0)
            return try measureSpec(try context.json(from: source, what: "the spec"), theme: theme, asJSON: asJSON)
        }
        guard let text = args.positional.first else {
            throw CanvasAgentError.usage("measure needs text, or --spec <json>: nubb +canvas measure \"Some text\" --size 20 --width 300")
        }
        let family = try args.value("font").map { name -> Int in
            guard let family = CanvasSpecNames.font(.string(name)) ?? Int(name).flatMap({ CanvasFont.Family(rawValue: $0)?.rawValue }) else {
                throw CanvasAgentError.usage("unknown font \"\(name)\"; use hand, normal, code, comic, or a font number")
            }
            return family
        } ?? CanvasFont.Family.handDrawn.rawValue
        let sizeText = args.value("size")
        let size = try sizeText.map { value -> Double in
            if let named = CanvasSpecNames.fontSizes[value.lowercased()] { return named }
            guard let number = Double(value), number > 0 else { throw CanvasAgentError.usage("--size takes a number or s, m, l, xl") }
            return number
        } ?? 20
        let width = try args.number("width", range: 1...1_000_000)
        let lineHeight = try args.number("line-height", range: 0.5...5) ?? CanvasText.defaultLineHeight(family: family)
        try args.finish(command: "measure", maxPositional: 1)
        let source = text.replacingOccurrences(of: "\\n", with: "\n")
        let wrapped = width.map { CanvasText.wrap(source, family: family, fontSize: size, maxWidth: $0) } ?? source
        let box = CanvasText.measure(wrapped, family: family, fontSize: size, lineHeight: lineHeight)
        let lines = CanvasText.lines(wrapped)
        if asJSON {
            return json(.object([
                "width": .number((Double(box.width) * 100).rounded(.up) / 100),
                "height": .number((Double(box.height) * 100).rounded(.up) / 100),
                "lines": .array(lines.map(CanvasJSON.string)),
                "font": .number(Double(family)), "size": .number(size), "lineHeight": .number(lineHeight),
            ]))
        }
        var out = "\(CanvasQuery.n(box.width)) x \(CanvasQuery.n(box.height))  (\(lines.count) line\(lines.count == 1 ? "" : "s"), \(CanvasSpecNames.fontName(family)) \(CanvasJSON.format(size)))"
        if width != nil, lines.count > 1 { out += "\n" + lines.map { "  " + $0 }.joined(separator: "\n") }
        return .ok(out)
    }

    /// Lays out spec nodes without writing them, and prints their boxes.
    private static func measureSpec(_ json: CanvasJSON, theme: CanvasJSON?, asJSON: Bool) throws -> CanvasCommandResult {
        var reader = CanvasSpecReader(theme: theme)
        let spec = reader.read(json)
        guard reader.issues.isEmpty else { throw CanvasAgentError.spec(reader.issues) }
        let layout = CanvasLayout()
        var boxes: [(String, CGRect)] = []
        var all: [String: CGRect] = [:]
        var warnings: [String] = []
        for (index, node) in spec.nodes.enumerated() {
            let id = node.id ?? "node\(index + 1)"
            let block = layout.layout(node, id: id, origin: node.at ?? .zero)
            boxes.append((id, block.boxes[id] ?? CGRect(origin: node.at ?? .zero, size: block.size)))
            all.merge(block.boxes) { _, new in new }
            warnings.append(contentsOf: block.issues.map(\.description))
        }
        if asJSON {
            return Self.json(.object([
                "nodes": .array(boxes.map { .object(["id": .string($0.0), "box": CanvasQuery.rectJSON($0.1)]) }),
                "boxes": .object(all.mapValues(CanvasQuery.rectJSON)),
                "warnings": .array(warnings.map(CanvasJSON.string)),
            ]))
        }
        var lines = boxes.map { "\($0.0)  \(CanvasQuery.n($0.1.width)) x \(CanvasQuery.n($0.1.height))" }
        let explicit = all.keys.filter { key in !boxes.contains { $0.0 == key } && !key.contains(".") }.sorted()
        for key in explicit { lines.append("  \(key)  \(CanvasQuery.rect(all[key]!))") }
        lines.append(contentsOf: warnings.map { "warning: \($0)" })
        return .ok(lines.joined(separator: "\n"))
    }

    private static func changes(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "changes")
        let asJSON = args.flag("json"), acknowledge = args.flag("ack")
        try args.finish(command: "changes", maxPositional: 1)
        context.live?.flush(url)
        let found: (changes: [CanvasElementChange], baseline: Bool) = try CanvasAgentDocument.edit(url, create: false) { file in
            guard file.state.hasBaseline else { return ([], false) }
            if acknowledge {
                file.absorbUserChanges()
                let changes = file.userChanges
                try file.save(writeFile: false)
                return (changes, true)
            }
            return (CanvasDiff.changes(from: file.state.written, to: file.document).map { change in
                var change = change
                change.unit = file.state.unit(owning: change.id)
                return change
            }, true)
        }
        if asJSON {
            return json(.object(["baseline": .bool(found.baseline), "changes": .array(found.changes.map(changeJSON))]))
        }
        guard found.baseline else {
            return .ok("no changes recorded: nothing was written to \(display(url, context)) with `apply` yet")
        }
        let shown = found.changes.filter { !CanvasDiff.isFollower($0) }
        guard !shown.isEmpty else { return .ok("no changes by hand since the last write") }
        var lines = ["\(shown.count) change\(shown.count == 1 ? "" : "s") by hand since the last write"
            + (acknowledge ? " (marked as seen)" : "") + ":"]
        for change in shown {
            var line = "  \(change.id)  \(CanvasQuery.describe(change))"
            if let unit = change.unit, unit != change.id { line += "  (part of \(unit))" }
            lines.append(line)
        }
        if !acknowledge { lines.append("the next apply keeps these; `reset <id>` drops them") }
        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: Render and lint

    private static func render(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: ["out", "frame", "region", "ids", "scale", "padding", "format"])
        let url = try file(args, context, command: "render")
        var options = CanvasExport.Options()
        options.scale = try args.number("scale", range: 0.05...16) ?? 1
        options.padding = try args.number("padding", range: 0...10_000) ?? 20
        options.theme = args.flag("dark") ? .dark : .light
        options.background = !args.flag("transparent")
        let frameNames = args.values("frame")
        let allFrames = args.flag("all-frames")
        let regionText = args.value("region")
        let only = ids(args.values("ids"))
        let out = args.value("out")
        let formatName = args.value("format")
        let asJSON = args.flag("json")
        try args.finish(command: "render", maxPositional: 1)

        let document = try read(url, context).document
        if let regionText { options.region = try region(regionText) }
        if !only.isEmpty {
            let missing = only.filter { document.element(id: $0) == nil }
            if !missing.isEmpty { throw CanvasAgentError.failed("no elements \(missing.joined(separator: ", "))") }
            options.only = CanvasOps.withFrameChildren(Set(only), in: document)
        }

        var targets: [(name: String?, options: CanvasExport.Options)] = []
        let frames = allFrames ? CanvasQuery.frames(in: document) : try frameNames.map { name in
            guard let frame = CanvasQuery.frame(named: name, in: document) else {
                throw CanvasAgentError.failed("no frame named \"\(name)\"" + CanvasQuery.frameHint(name, in: document))
            }
            return frame
        }
        if allFrames, frames.isEmpty { throw CanvasAgentError.failed("the drawing has no frames") }
        if frames.isEmpty {
            targets.append((nil, options))
        } else {
            for frame in frames {
                var frameOptions = options
                frameOptions.only = CanvasOps.withFrameChildren([frame.id], in: document).union(options.only ?? [])
                if options.region == nil {
                    frameOptions.region = frame.sceneBounds.insetBy(dx: -options.padding, dy: -options.padding)
                }
                targets.append((CanvasRenderer.frameTitle(frame), frameOptions))
            }
        }

        let format: CanvasExport.Format
        if let formatName {
            guard let value = CanvasExport.Format(rawValue: formatName.lowercased()) else {
                throw CanvasAgentError.usage("--format takes png, svg, or pdf")
            }
            format = value
        } else if let out, let value = CanvasExport.Format(path: out) {
            format = value
        } else {
            format = .png
        }

        var written: [CanvasJSON] = []
        var lines: [String] = []
        let stem = url.deletingPathExtension().lastPathComponent
        for (index, target) in targets.enumerated() {
            let destination = try outputURL(out, name: OutputName(stem: stem, frame: target.name, index: index, count: targets.count), format: format, context: context)
            _ = try CanvasExport.write(document, to: destination, format: format, options: target.options)
            let area = CanvasExport.area(of: document, options: target.options) ?? .zero
            let pixels = format == .png ? try CanvasExport.pixelSize(of: area, scale: target.options.scale) : (Int(area.width), Int(area.height))
            written.append(.object([
                "path": .string(destination.path), "frame": target.name.map(CanvasJSON.string) ?? .null,
                "area": CanvasQuery.rectJSON(area), "width": .number(Double(pixels.0)), "height": .number(Double(pixels.1)),
            ]))
            lines.append("\(destination.path)  \(pixels.0)x\(pixels.1)\(format == .png ? " px" : "")"
                + (target.name.map { "  \"\($0)\"" } ?? "") + "  area \(CanvasQuery.rect(area))")
        }
        if asJSON { return json(written.count == 1 ? written[0] : .array(written)) }
        return .ok(lines.joined(separator: "\n"))
    }

    /// What a render's file is named after.
    private struct OutputName {
        var stem: String
        var frame: String?
        var index: Int
        var count: Int
    }

    private static func outputURL(
        _ out: String?, name output: OutputName, format: CanvasExport.Format, context: CanvasCommandContext
    ) throws -> URL {
        let (stem, frame, index, count) = (output.stem, output.frame, output.index, output.count)
        func slug(_ text: String) -> String {
            let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return String(allowed).split(separator: "-").joined(separator: "-").prefix(60).description
        }
        let name = stem + (frame.map { "-" + slug($0) } ?? "") + "." + format.rawValue
        if let out {
            let url = context.url(out)
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if (exists && isDirectory.boolValue) || out.hasSuffix("/") {
                return url.appendingPathComponent(name)
            }
            if count > 1 {
                let base = url.deletingPathExtension().lastPathComponent
                return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(index + 1)-\(slug(frame ?? "")).\(format.rawValue)")
            }
            return url
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nubb-canvas", isDirectory: true)
        return directory.appendingPathComponent(name)
    }

    private static func issueJSON(_ issue: CanvasLintIssue) -> CanvasJSON {
        var object: [String: CanvasJSON] = [
            "kind": .string(issue.kind.rawValue), "id": .string(issue.id), "message": .string(issue.message),
        ]
        if let amount = issue.amount { object["px"] = .number((amount * 10).rounded() / 10) }
        if let frame = issue.frame { object["frame"] = .string(frame) }
        return .object(object)
    }

    private static func lint(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: ["only", "skip", "ids", "frame", "min-size", "screen", "tolerance"])
        let url = try file(args, context, command: "lint")
        var options = CanvasLint.Options()
        let only = ids(args.values("only")), skip = ids(args.values("skip"))
        for name in only + skip where CanvasLintIssue.Kind(rawValue: name) == nil {
            throw CanvasAgentError.usage("unknown check \"\(name)\"; checks: " + CanvasLintIssue.Kind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        options.kinds = Set((only.isEmpty ? CanvasLintIssue.Kind.allCases.map(\.rawValue) : only).compactMap(CanvasLintIssue.Kind.init))
            .subtracting(skip.compactMap(CanvasLintIssue.Kind.init))
        let targetIDs = ids(args.values("ids"))
        let frameName = args.value("frame")
        options.minReadable = try args.number("min-size", range: 1...100) ?? options.minReadable
        options.tolerance = try args.number("tolerance", range: 0...100) ?? options.tolerance
        if let screen = args.value("screen") {
            let parts = screen.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw CanvasAgentError.usage("--screen takes WIDTHxHEIGHT like 1440x900") }
            options.screen = CGSize(width: parts[0], height: parts[1])
        }
        let asJSON = args.flag("json")
        try args.finish(command: "lint", maxPositional: 1)
        let document = try read(url, context).document
        var scope = Set(targetIDs)
        if let frameName {
            guard let frame = CanvasQuery.frame(named: frameName, in: document) else {
                throw CanvasAgentError.failed("no frame named \"\(frameName)\"" + CanvasQuery.frameHint(frameName, in: document))
            }
            scope.insert(frame.id)
        }
        if !scope.isEmpty { options.only = scope }
        let started = Date()
        let issues = CanvasLint.run(document, options: options)
        let elapsed = Date().timeIntervalSince(started)
        if asJSON {
            var result = json(.object(["file": .string(url.path), "issues": .array(issues.map(issueJSON))]))
            if !issues.isEmpty { result.exit = 1 }
            return result
        }
        guard !issues.isEmpty else {
            return .ok("no problems in \(document.elements.count) elements (\(Int((elapsed * 1000).rounded())) ms)")
        }
        var lines = ["\(issues.count) problem\(issues.count == 1 ? "" : "s"):"]
        var lastFrame: String??
        for issue in issues.sorted(by: { ($0.frame ?? "", $0.kind.rawValue, $0.id) < ($1.frame ?? "", $1.kind.rawValue, $1.id) }) {
            if lastFrame == nil || lastFrame! != issue.frame {
                lines.append(issue.frame.map { "[\($0)]" } ?? "[outside frames]")
                lastFrame = .some(issue.frame)
            }
            lines.append("  \(issue.kind.rawValue)  \(issue.message)")
        }
        var result = CanvasCommandResult.ok(lines.joined(separator: "\n"))
        result.exit = 1
        return result
    }

    // MARK: Viewer

    private static func viewRequest(_ args: inout CanvasArguments) throws -> [String: CanvasJSON] {
        var request: [String: CanvasJSON] = [:]
        if let frame = args.value("frame") { request["frame"] = .string(frame) }
        let selected = ids(args.values("ids"))
        if !selected.isEmpty { request["ids"] = .array(selected.map(CanvasJSON.string)) }
        if let regionText = args.value("region") {
            let box = try region(regionText)
            request["region"] = .array([box.minX, box.minY, box.width, box.height].map { .number(Double($0)) })
        }
        if args.flag("fit") { request["fit"] = .bool(true) }
        if let zoom = try args.number("zoom", range: CanvasViewport.minZoom...CanvasViewport.maxZoom) { request["zoom"] = .number(zoom) }
        if let padding = try args.number("padding", range: 0...2000) { request["padding"] = .number(padding) }
        if args.flag("select") { request["select"] = .bool(true) }
        if let hover = args.value("hover") { request["hover"] = .string(hover) }
        return request
    }

    private static let viewOptions: Set<String> = ["frame", "ids", "region", "zoom", "padding", "hover"]

    private static func open(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: viewOptions)
        let url = try file(args, context, command: "open")
        var request = try viewRequest(&args)
        if args.flag("background") { request["background"] = .bool(true) }
        let asJSON = args.flag("json")
        try args.finish(command: "open", maxPositional: 1)
        if !FileManager.default.fileExists(atPath: url.path) {
            try CanvasAgentStore.withLock(for: url) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CanvasDocument().encoded().write(to: url, options: .atomic)
            }
        }
        let reply = try live(url, context, command: "open", request: request, launch: true)
        return asJSON ? json(reply) : .ok("opened \(display(url, context)) in Nubb" + describeView(reply))
    }

    private static func view(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: viewOptions)
        let url = try file(args, context, command: "view")
        let request = try viewRequest(&args)
        let asJSON = args.flag("json")
        try args.finish(command: "view", maxPositional: 1)
        guard !request.isEmpty else {
            throw CanvasAgentError.usage("view needs where to look: --frame <name>, --ids a,b, --region x,y,w,h, --fit, --zoom <z>, or --hover <id>")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CanvasAgentError.failed("no drawing at \(url.path)") }
        let reply = try live(url, context, command: "view", request: request, launch: true)
        return asJSON ? json(reply) : .ok("showing" + describeView(reply))
    }

    private static func status(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: [])
        let url = try file(args, context, command: "status")
        let asJSON = args.flag("json")
        try args.finish(command: "status", maxPositional: 1)
        guard let client = context.live, let socket = client.target(for: url),
              let reply = client.send(["command": .string("status"), "path": .string(url.path)], to: socket) else {
            return asJSON ? json(.object(["running": .bool(false), "open": .bool(false)])) : .ok("Nubb isn't running")
        }
        if asJSON { return json(reply) }
        guard reply["open"]?.boolValue == true else { return .ok("\(display(url, context)) isn't open in Nubb (`open` opens it)") }
        var text = "\(display(url, context)) is open" + describeView(reply)
        if reply["editing"]?.boolValue == true { text += "\nthe user is editing text" }
        if let selected = reply["selected"]?.arrayValue?.compactMap(\.stringValue), !selected.isEmpty {
            text += "\nselected: " + selected.joined(separator: ", ")
        }
        return .ok(text)
    }

    private static func describeView(_ reply: CanvasJSON) -> String {
        guard let zoom = reply["zoom"]?.doubleValue, let visible = reply["visible"]?.arrayValue?.compactMap(\.doubleValue), visible.count == 4 else {
            return ""
        }
        return ": zoom \(CanvasJSON.format((zoom * 100).rounded() / 100)), showing \(CanvasQuery.rect(CGRect(x: visible[0], y: visible[1], width: visible[2], height: visible[3])))"
    }

    /// Sends a viewer command, launching Nubb with the file when it isn't
    /// running.
    private static func live(_ url: URL, _ context: CanvasCommandContext, command: String, request: [String: CanvasJSON], launch: Bool) throws -> CanvasJSON {
        var message = request
        message["command"] = .string(command)
        message["path"] = .string(url.path)
        if let client = context.live, let socket = client.target(for: url), let reply = client.send(message, to: socket) {
            if reply["ok"]?.boolValue == false {
                throw CanvasAgentError.failed(reply["error"]?.stringValue ?? "Nubb couldn't do that")
            }
            return reply
        }
        guard launch else { throw CanvasAgentError.failed("Nubb isn't running") }
        try launchApp(with: url)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            usleep(200_000)
            guard let client = CanvasLiveClient.fromEnvironment(), let socket = client.target(for: url) else { continue }
            if let reply = client.send(message, to: socket), reply["ok"]?.boolValue == true { return reply }
        }
        throw CanvasAgentError.failed("started Nubb, but it didn't answer within 15 s")
    }

    private static func launchApp(with url: URL) throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw CanvasAgentError.failed("Nubb isn't running, and this nubb isn't inside Nubb.app to start it") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", bundle.path, url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CanvasAgentError.failed("can't start Nubb: \(error.localizedDescription)")
        }
    }

    private static func openInViewer(_ url: URL, _ context: CanvasCommandContext, request: [String: CanvasJSON]) throws -> String {
        let reply = try live(url, context, command: "open", request: request, launch: true)
        return "opened in Nubb" + describeView(reply)
    }

    // MARK: Clipboard

    private static func copy(_ raw: [String], _ context: CanvasCommandContext) throws -> CanvasCommandResult {
        var args = try CanvasArguments(raw, valued: ["frame", "ids"])
        let url = try file(args, context, command: "copy")
        let frameName = args.value("frame")
        let selected = ids(args.values("ids"))
        try args.finish(command: "copy", maxPositional: 1)
        let document = try read(url, context).document
        var wanted: Set<String>?
        if let frameName {
            guard let frame = CanvasQuery.frame(named: frameName, in: document) else {
                throw CanvasAgentError.failed("no frame named \"\(frameName)\"" + CanvasQuery.frameHint(frameName, in: document))
            }
            wanted = [frame.id]
        }
        if !selected.isEmpty { wanted = (wanted ?? []).union(selected) }
        var elements = document.elements
        if let wanted {
            let ids = CanvasOps.withFrameChildren(CanvasOps.withBoundText(wanted, in: document), in: document)
            elements = elements.filter { ids.contains($0.id) }
        }
        guard !elements.isEmpty else { throw CanvasAgentError.failed("nothing to copy") }
        let data = CanvasDocument.clipboardData(elements: elements, files: document.files)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(bytes: data, encoding: .utf8) ?? "", forType: .string)
        return .ok("copied \(elements.count) elements; paste them into excalidraw.com or a Nubb canvas")
    }
}
