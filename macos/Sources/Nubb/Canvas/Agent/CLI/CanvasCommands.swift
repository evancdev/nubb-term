import CoreGraphics
import Foundation

/// The commands of `nubb +canvas`. They run in the CLI process on the file
/// itself.
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
            default:
                let commands = ["new", "apply", "set", "move", "delete", "reset", "info", "list", "get", "frames", "spec",
                                "measure", "changes", "help"]
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

    /// The drawing as it is now.
    private static func read(_ url: URL, _ context: CanvasCommandContext) throws -> CanvasAgentDocument {
        try CanvasAgentDocument(url: url, create: false)
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
        let quiet = args.flag("quiet")
        try args.finish(command: "apply", maxPositional: 2)
        return try write(url, context, dryRun: dryRun, asJSON: asJSON, quiet: quiet) { file in
            try CanvasEngine.apply(spec, to: file)
        }
    }

    /// Runs a change on the drawing, saves it, and reports it.
    private static func write(
        _ url: URL, _ context: CanvasCommandContext, dryRun: Bool = false, asJSON: Bool = false,
        quiet: Bool = false, create: Bool = true, _ change: (CanvasAgentDocument) throws -> CanvasApplyReport
    ) throws -> CanvasCommandResult {
        let report = try CanvasAgentDocument.edit(url, create: create) { file -> CanvasApplyReport in
            let report = try change(file)
            if !dryRun { try file.save() }
            return report
        }
        if asJSON {
            var object = reportJSON(report, url: url, context: context)
            object["dryRun"] = .bool(dryRun)
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
        return .ok(lines.joined(separator: "\n"))
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
        let asJSON = args.flag("json"), quiet = args.flag("quiet")
        try args.finish(command: "set", maxPositional: args.positional.count)
        let spec = CanvasJSON.object(["set": .object([id: .object(fields)])])
        return try write(url, context, asJSON: asJSON, quiet: quiet, create: false) { file in
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
}
