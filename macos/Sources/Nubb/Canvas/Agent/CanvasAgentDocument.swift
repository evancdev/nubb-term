import CoreGraphics
import Foundation

// MARK: - Changes

/// One element that differs between two versions of a drawing.
struct CanvasElementChange {
    enum Kind: String {
        case added
        case deleted
        case modified
    }

    var id: String
    var kind: Kind
    /// The element now, or before it was deleted.
    var element: CanvasElement
    /// The element before, for modified elements.
    var previous: CanvasElement?
    /// Changed fields, old and new values.
    var fields: [String: (old: CanvasJSON?, new: CanvasJSON?)] = [:]
    /// The agent unit the element belongs to, if any.
    var unit: String?

    /// How far it moved, if it did.
    var moved: CGVector? {
        guard let previous, previous.x != element.x || previous.y != element.y else { return nil }
        return CGVector(dx: element.x - previous.x, dy: element.y - previous.y)
    }
}

extension CanvasJSON {
    /// Pretty JSON as text. The writer only makes UTF-8.
    var text: String { String(bytes: serialized(), encoding: .utf8) ?? "" }

    /// One-line JSON as text.
    var compactText: String { String(bytes: compact(), encoding: .utf8) ?? "" }

    /// Equal, with numbers within a hundredth: layout rounds to hundredths.
    static func nearlyEqual(_ a: CanvasJSON, _ b: CanvasJSON) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return abs(x - y) < 0.0101
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(nearlyEqual)
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { nearlyEqual(value, $0) } ?? false }
        default: return a == b
        }
    }
}

enum CanvasDiff {
    /// Fields that change on every edit without meaning anything.
    static let volatileKeys: Set<String> = ["version", "versionNonce", "updated", "index", "isDeleted", "seed", "created"]

    /// The fields whose values differ. A missing field, null, and an empty
    /// list are the same, as are numbers a hundredth apart: Excalidraw adds
    /// new fields as null, writes `[]` for no bound elements, and measures
    /// text in its own float math.
    static func changedKeys(_ old: [String: CanvasJSON], _ new: [String: CanvasJSON]) -> [String] {
        return Set(old.keys).union(new.keys)
            .filter { !volatileKeys.contains($0) && !CanvasJSON.nearlyEqual(normalized(old[$0]), normalized(new[$0])) }
            .sorted()
    }

    /// Missing, null, and an empty list or object all mean "none".
    static func normalized(_ value: CanvasJSON?) -> CanvasJSON {
        guard let value else { return .null }
        if case .array(let items) = value, items.isEmpty { return .null }
        if case .object(let fields) = value, fields.isEmpty { return .null }
        return value
    }

    /// Whether two elements are the same apart from version fields.
    static func sameContent(_ a: CanvasElement, _ b: CanvasElement) -> Bool {
        var a = a, b = b
        a.version = 0
        a.versionNonce = 0
        a.updated = 0
        a.seed = 0
        b.version = 0
        b.versionNonce = 0
        b.updated = 0
        b.seed = 0
        return a == b
    }

    /// Element changes from `old` (ids to element JSON) to `new`.
    static func changes(from old: [String: CanvasJSON], to new: CanvasDocument) -> [CanvasElementChange] {
        var result: [CanvasElementChange] = []
        var seen = Set<String>()
        for element in new.elements {
            seen.insert(element.id)
            guard let before = old[element.id] else {
                result.append(CanvasElementChange(id: element.id, kind: .added, element: element))
                continue
            }
            guard let fields = before.objectValue, let now = element.json.objectValue else { continue }
            let keys = changedKeys(fields, now)
            guard !keys.isEmpty else { continue }
            var change = CanvasElementChange(id: element.id, kind: .modified, element: element,
                                             previous: CanvasElement(json: before))
            for key in keys { change.fields[key] = (fields[key], now[key]) }
            result.append(change)
        }
        for (id, json) in old where !seen.contains(id) {
            guard let element = CanvasElement(json: json) else { continue }
            result.append(CanvasElementChange(id: id, kind: .deleted, element: element))
        }
        return result.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    /// Whether a change only follows another one: a label moving with its
    /// shape, or an arrow whose bound ends followed the shapes it connects.
    /// Lists for people leave these out.
    static func isFollower(_ change: CanvasElementChange) -> Bool {
        guard change.kind == .modified else { return false }
        let element = change.element
        let geometry: Set<String> = ["x", "y", "width", "height", "points", "angle", "startBinding", "endBinding"]
        guard Set(change.fields.keys).isSubset(of: geometry) else { return false }
        if element.type == .text, element.containerId != nil { return true }
        if element.type.isLinear, element.startBinding != nil || element.endBinding != nil {
            return !CanvasAgentDocument.userEditedLine(change)
        }
        return false
    }
}

// MARK: - Document

enum CanvasAgentError: LocalizedError {
    /// Bad arguments or input: exit code 2.
    case usage(String)
    /// The command couldn't do what was asked: exit code 1.
    case failed(String)
    /// Problems in a spec, all at once.
    case spec([CanvasSpecIssue])
    /// The file changed while the command ran.
    case conflict

    var errorDescription: String? {
        switch self {
        case .usage(let message), .failed(let message): message
        case .spec(let issues): issues.map(\.description).joined(separator: "\n")
        case .conflict: "the drawing changed while the command ran"
        }
    }
}

/// One drawing file as a CLI command sees it: the current contents, the
/// agent's memory of it, and the user's changes since the agent last looked.
final class CanvasAgentDocument {
    let url: URL
    var document: CanvasDocument
    var state: CanvasAgentState
    /// What the user changed since the agent last wrote or looked, found by
    /// `absorbUserChanges`.
    private(set) var userChanges: [CanvasElementChange] = []

    /// The bytes read, to notice other writers before saving.
    private let loadedData: Data?

    /// Reads the drawing. A missing file is an empty drawing when `create`
    /// is true and an error otherwise.
    init(url: URL, create: Bool) throws {
        self.url = url
        state = CanvasAgentStore.load(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            var isDirectory = ObjCBool(false)
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { throw CanvasAgentError.usage("\(url.path) is a folder, not a drawing") }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw CanvasAgentError.failed("can't read \(url.path): \(error.localizedDescription)")
            }
            do {
                document = try CanvasDocument.decode(data)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                throw CanvasAgentError.failed("can't read \(url.path): \(reason)")
            }
            loadedData = data
        } else if create {
            document = CanvasDocument()
            loadedData = nil
            // A new file has nothing the user did yet, even if an old one
            // by the same name left state behind.
            state = CanvasAgentState(path: CanvasAgentStore.canonicalPath(url))
        } else {
            throw CanvasAgentError.failed("no drawing at \(url.path); `apply` creates one")
        }
    }

    var exists: Bool { loadedData != nil }

    // MARK: User changes

    /// Finds what the user changed since the agent last wrote, remembers
    /// edits to elements the agent laid out so layouts keep them, and makes
    /// the current drawing the new baseline.
    func absorbUserChanges() {
        defer {
            state.written = Self.snapshot(document)
            state.hasBaseline = true
        }
        guard state.hasBaseline else { return }
        let changes = CanvasDiff.changes(from: state.written, to: document)
        userChanges = changes.map { change in
            var change = change
            change.unit = state.unit(owning: change.id)
            return change
        }
        guard !changes.isEmpty else { return }

        let byID = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for change in changes {
            guard let unitID = state.unit(owning: change.id), state.units[unitID]?.elements.contains(change.id) == true else { continue }
            switch change.kind {
            case .added:
                break
            case .deleted:
                state.userDeleted.insert(change.id)
                state.userEdits[change.id] = nil
            case .modified:
                recordFields(change)
            }
        }
        for unitID in state.unitOrder {
            if let unit = state.units[unitID] { recordMoves(in: unit, changes: byID) }
        }
    }

    /// Records how the user moved the elements of a unit, on the biggest
    /// nodes that moved as a whole: dragging a frame records one move on
    /// the frame, not one on each thing inside it.
    private func recordMoves(in unit: CanvasAgentState.Unit, changes: [String: CanvasElementChange]) {
        var moved: [String: CGVector] = [:]
        for id in unit.elements {
            if let change = changes[id], change.kind == .modified, let delta = change.moved { moved[id] = delta }
        }
        guard !moved.isEmpty else { return }
        let present = Dictionary(document.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func follows(_ element: CanvasElement) -> Bool {
            // Labels follow their shapes and arrows are routed again, so
            // neither says where a node went.
            (element.type == .text && element.containerId != nil) || element.type.isLinear
        }

        var handled: [String: CGVector] = [:]
        let order = unit.nodes.keys.sorted { a, b in
            let ca = unit.nodes[a]?.count ?? 0, cb = unit.nodes[b]?.count ?? 0
            return ca != cb ? ca > cb : a < b
        }
        for node in order {
            let all = (unit.nodes[node] ?? []).filter { present[$0] != nil }
            let members = all.filter { !follows(present[$0]!) }
            guard !members.isEmpty else { continue }
            var vector: CGVector?
            var uniform = true
            for id in members {
                let total = moved[id] ?? .zero, done = handled[id] ?? .zero
                let rest = CGVector(dx: total.dx - done.dx, dy: total.dy - done.dy)
                if let vector, abs(vector.dx - rest.dx) > 0.01 || abs(vector.dy - rest.dy) > 0.01 {
                    uniform = false
                    break
                }
                vector = rest
            }
            guard uniform, let vector, abs(vector.dx) > 0.001 || abs(vector.dy) > 0.001 else { continue }
            addShift(vector, to: node)
            for id in all {
                let done = handled[id] ?? .zero
                handled[id] = CGVector(dx: done.dx + vector.dx, dy: done.dy + vector.dy)
            }
        }

        // Parts of a node moved on their own, and lines and arrows moved
        // more than the nodes around them.
        for (id, total) in moved {
            guard let element = present[id] else { continue }
            let done = handled[id] ?? .zero
            let rest = CGVector(dx: total.dx - done.dx, dy: total.dy - done.dy)
            guard abs(rest.dx) > 0.001 || abs(rest.dy) > 0.001 else { continue }
            if element.type == .text && element.containerId != nil { continue }
            if element.type.isLinear {
                if let change = changes[id], Self.userEditedLine(change) { pinLine(element) }
            } else {
                addShift(rest, to: id, keys: ("ox", "oy"))
            }
        }
    }

    /// Whether the user changed a line themselves, rather than it following
    /// the shapes its ends are bound to: an end that isn't bound moved, the
    /// ends were bound to something else, or points were added or removed.
    static func userEditedLine(_ change: CanvasElementChange) -> Bool {
        guard let previous = change.previous else { return false }
        let element = change.element
        // Attached to something else. Excalidraw rewrites a binding's fixed
        // point when it moves an arrow along with a shape; that's following.
        if previous.startBinding?.elementId != element.startBinding?.elementId
            || previous.endBinding?.elementId != element.endBinding?.elementId { return true }
        if previous.points.count != element.points.count { return true }
        guard let first = element.points.first, let last = element.points.last,
              let oldFirst = previous.points.first, let oldLast = previous.points.last else { return false }
        func far(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.dx - b.dx, a.dy - b.dy) > 0.5 }
        if element.startBinding == nil, far(element.toScene(first), previous.toScene(oldFirst)) { return true }
        if element.endBinding == nil, far(element.toScene(last), previous.toScene(oldLast)) { return true }
        // Bent in the middle.
        if element.points.count > 2, !element.isElbowArrow {
            for i in 1..<(element.points.count - 1) where far(element.toScene(element.points[i]), previous.toScene(previous.points[i])) {
                return true
            }
        }
        return false
    }

    private func addShift(_ delta: CGVector, to id: String, keys: (String, String) = ("dx", "dy")) {
        var edits = state.userEdits[id] ?? [:]
        let dx = (edits[keys.0]?.doubleValue ?? 0) + Double(delta.dx)
        let dy = (edits[keys.1]?.doubleValue ?? 0) + Double(delta.dy)
        edits[keys.0] = abs(dx) < 0.001 ? nil : .number(dx)
        edits[keys.1] = abs(dy) < 0.001 ? nil : .number(dy)
        state.userEdits[id] = edits.isEmpty ? nil : edits
    }

    /// Keeps a line or arrow where the user put it, attached to what it
    /// was attached to then.
    private func pinLine(_ element: CanvasElement) {
        var edits = state.userEdits[element.id] ?? [:]
        Self.pin(element, into: &edits)
        state.userEdits[element.id] = edits
    }

    private static func pin(_ element: CanvasElement, into edits: inout [String: CanvasJSON]) {
        edits["x"] = .number(element.x)
        edits["y"] = .number(element.y)
        edits["points"] = element.json["points"] ?? .null
        edits["startBinding"] = element.startBinding?.json ?? .null
        edits["endBinding"] = element.endBinding?.json ?? .null
    }

    /// Whether `text` is `original` wrapped: the same apart from where the
    /// lines break.
    private static func isRewrap(_ text: String, of original: String) -> Bool {
        text.filter { !$0.isWhitespace } == original.filter { !$0.isWhitespace }
    }

    /// Remembers the fields the user changed on one laid-out element, other
    /// than its position, with what they were before.
    private func recordFields(_ change: CanvasElementChange) {
        let element = change.element
        let isLabel = element.type == .text && element.containerId != nil
        var edits = state.userEdits[change.id] ?? [:]
        var bases = state.userBases[change.id] ?? [:]
        func record(_ key: String, _ value: CanvasJSON?, old: CanvasJSON?) {
            if edits[key] == nil { bases[key] = old ?? .null }
            if let base = bases[key], let value, CanvasJSON.nearlyEqual(base, value) {
                // Changed back: no edit any more.
                edits[key] = nil
                bases[key] = nil
            } else {
                edits[key] = value ?? .null
            }
        }
        for (key, value) in change.fields {
            switch key {
            case "x", "y", "boundElements", "startBinding", "endBinding", "frameId", "groupIds", "version":
                continue
            case "text":
                // Layout wraps originalText into text, so text changing
                // alone is a rewrap, or someone writing the file by hand.
                if change.fields["originalText"] == nil, let new = value.new?.stringValue,
                   !Self.isRewrap(new, of: element.originalText) {
                    record("originalText", .string(new), old: change.previous.map { .string($0.originalText) })
                }
            case "width", "height":
                if isLabel || element.type.hasPoints { continue }
                if element.type == .text, element.autoResize { continue }
                record(key, value.new, old: value.old)
            case "points":
                if element.type.isLinear, Self.userEditedLine(change) { Self.pin(element, into: &edits) }
            case "autoResize", "containerId" where isLabel:
                continue
            case "customData":
                // Each key on its own, so the agent naming a box keeps
                // what else the person or Excalidraw stored there.
                let old = value.old?.objectValue ?? [:], new = value.new?.objectValue ?? [:]
                for sub in Set(old.keys).union(new.keys) where !CanvasJSON.nearlyEqual(old[sub] ?? .null, new[sub] ?? .null) {
                    record(Self.customDataKey(sub), new[sub] ?? .null, old: old[sub] ?? .null)
                }
            default:
                record(key, value.new, old: value.old)
            }
        }
        if element.type.isLinear, Self.userEditedLine(change) {
            Self.pin(element, into: &edits)
        }
        state.userEdits[change.id] = edits.isEmpty ? nil : edits
        state.userBases[change.id] = bases.isEmpty ? nil : bases
    }

    /// The edit key of one `customData` field: `customData.name`.
    static func customDataKey(_ sub: String) -> String { "customData." + sub }

    /// The `customData` field an edit key is for, if it is one.
    static func customDataField(_ key: String) -> String? {
        key.hasPrefix("customData.") ? String(key.dropFirst("customData.".count)) : nil
    }

    static func snapshot(_ document: CanvasDocument) -> [String: CanvasJSON] {
        var result: [String: CanvasJSON] = [:]
        result.reserveCapacity(document.elements.count)
        for element in document.elements { result[element.id] = element.json }
        return result
    }

    // MARK: Saving

    /// Writes the drawing and the agent state. Fails with `conflict` when
    /// another program changed the file since it was read, so the caller
    /// can start over with the new contents.
    func save(writeFile: Bool = true) throws {
        if writeFile {
            let current = try? Data(contentsOf: url)
            guard current == loadedData else { throw CanvasAgentError.conflict }
            let data = document.encoded()
            if data != loadedData {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    throw CanvasAgentError.failed("can't write \(url.path): \(error.localizedDescription)")
                }
            }
        }
        state.written = Self.snapshot(document)
        state.hasBaseline = true
        do {
            try CanvasAgentStore.save(state)
        } catch {
            throw CanvasAgentError.failed("can't save the agent state: \(error.localizedDescription)")
        }
    }

    /// Runs `body` on a fresh copy of the drawing, starting over when the
    /// file changes underneath it, while holding the drawing's lock.
    static func edit<T>(_ url: URL, create: Bool, _ body: (CanvasAgentDocument) throws -> T) throws -> T {
        try CanvasAgentStore.withLock(for: url) {
            var attempt = 0
            while true {
                let document = try CanvasAgentDocument(url: url, create: create)
                do {
                    return try body(document)
                } catch CanvasAgentError.conflict where attempt < 5 {
                    attempt += 1
                    usleep(useconds_t(50_000 * attempt))
                }
            }
        }
    }
}
