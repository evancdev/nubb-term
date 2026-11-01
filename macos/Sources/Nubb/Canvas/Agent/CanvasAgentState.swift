import Darwin
import Foundation

/// What the agent CLI remembers about one drawing between runs.
///
/// - Units: each top-level node an agent applied, with its spec, so a later
///   apply, `set`, or `delete` can lay it out again.
/// - The drawing as the agent last wrote or acknowledged it, so the next run
///   can tell what the user changed since.
/// - The user's edits to elements the agent laid out: fields they changed
///   and how far they moved things. Layout applies them on top of every
///   new layout, so the agent never undoes them.
///
/// It is kept outside the drawing, under Application Support, so files stay
/// plain Excalidraw files that diff cleanly.
struct CanvasAgentState {
    struct Unit: Equatable {
        /// The node as the agent gave it, with its id filled in.
        var spec: CanvasJSON
        /// Where the node's top-left corner was placed.
        var origin: CGPoint
        /// The ids of the elements it made, in layout order.
        var elements: [String]
        /// The elements each node made, its children's included, by node id.
        var nodes: [String: [String]] = [:]
        /// The boxes of nodes with ids, including layouts that have no
        /// element of their own, so arrows can point at them.
        var boxes: [String: CGRect] = [:]
    }

    static let formatVersion = 2

    var path: String
    var units: [String: Unit] = [:]
    /// Units in the order they were first applied.
    var unitOrder: [String] = []
    /// The `styles` and `defaults` of the specs applied, so a unit laid out
    /// again on its own looks the same.
    var styles: [String: CanvasJSON] = [:]
    var defaults: [String: CanvasJSON] = [:]
    /// Every element as the agent last wrote or acknowledged it, by id.
    var written: [String: CanvasJSON] = [:]
    /// Whether `written` holds a baseline yet.
    var hasBaseline = false
    /// The user's changes to laid-out elements: field values by element id.
    /// `dx` and `dy` under a node id hold how far they moved the node;
    /// `ox` and `oy` how far they moved one element of it on its own.
    var userEdits: [String: [String: CanvasJSON]] = [:]
    /// What each edited field was before the user changed it, so an agent
    /// change to the same field can win over the user's.
    var userBases: [String: [String: CanvasJSON]] = [:]
    /// Laid-out elements the user deleted. Layout doesn't bring them back.
    var userDeleted: Set<String> = []

    init(path: String) {
        self.path = path
    }

    /// The unit that made element `id`, or has a node `id`, if any.
    func unit(owning id: String) -> String? {
        if units[id] != nil { return id }
        for unitID in unitOrder {
            guard let unit = units[unitID] else { continue }
            if unit.elements.contains(id) || unit.nodes[id] != nil { return unitID }
        }
        return nil
    }

    // MARK: Coding

    init?(json: CanvasJSON) {
        guard let object = json.objectValue, object["version"]?.intValue == Self.formatVersion,
              let path = object["path"]?.stringValue else { return nil }
        self.path = path
        for (id, value) in object["units"]?.objectValue ?? [:] {
            guard let spec = value["spec"], let origin = value["origin"].flatMap(CanvasSpecReader.point) else { continue }
            var unit = Unit(spec: spec, origin: origin, elements: value["elements"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for (node, elements) in value["nodes"]?.objectValue ?? [:] {
                unit.nodes[node] = elements.arrayValue?.compactMap(\.stringValue) ?? []
            }
            for (node, box) in value["boxes"]?.objectValue ?? [:] {
                if let list = box.arrayValue?.compactMap(\.doubleValue), list.count == 4 {
                    unit.boxes[node] = CGRect(x: list[0], y: list[1], width: list[2], height: list[3])
                }
            }
            units[id] = unit
        }
        unitOrder = (object["unitOrder"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { units[$0] != nil }
        for id in units.keys.sorted() where !unitOrder.contains(id) { unitOrder.append(id) }
        styles = object["styles"]?.objectValue ?? [:]
        defaults = object["defaults"]?.objectValue ?? [:]
        written = object["written"]?.objectValue ?? [:]
        hasBaseline = object["hasBaseline"]?.boolValue ?? !written.isEmpty
        for (id, fields) in object["userEdits"]?.objectValue ?? [:] {
            if let fields = fields.objectValue, !fields.isEmpty { userEdits[id] = fields }
        }
        for (id, fields) in object["userBases"]?.objectValue ?? [:] {
            if let fields = fields.objectValue, !fields.isEmpty { userBases[id] = fields }
        }
        userDeleted = Set(object["userDeleted"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    var json: CanvasJSON {
        var unitsJSON: [String: CanvasJSON] = [:]
        for (id, unit) in units {
            var boxes: [String: CanvasJSON] = [:]
            for (node, box) in unit.boxes {
                boxes[node] = .array([box.minX, box.minY, box.width, box.height].map { .number(Double($0)) })
            }
            unitsJSON[id] = .object([
                "spec": unit.spec,
                "origin": .array([.number(Double(unit.origin.x)), .number(Double(unit.origin.y))]),
                "elements": .array(unit.elements.map(CanvasJSON.string)),
                "nodes": .object(unit.nodes.mapValues { .array($0.map(CanvasJSON.string)) }),
                "boxes": .object(boxes),
            ])
        }
        return .object([
            "version": .number(Double(Self.formatVersion)),
            "path": .string(path),
            "units": .object(unitsJSON),
            "unitOrder": .array(unitOrder.map(CanvasJSON.string)),
            "styles": .object(styles),
            "defaults": .object(defaults),
            "written": .object(written),
            "hasBaseline": .bool(hasBaseline),
            "userEdits": .object(userEdits.mapValues(CanvasJSON.object)),
            "userBases": .object(userBases.mapValues(CanvasJSON.object)),
            "userDeleted": .array(userDeleted.sorted().map(CanvasJSON.string)),
        ])
    }
}

// MARK: - Storage

/// Reads and writes agent state, and serializes CLI runs on the same file.
enum CanvasAgentStore {
    /// Where state goes instead, set by tests. Tests can't use the
    /// environment variable: changing the environment of a running app
    /// frees the block the terminal core still reads.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// `NUBB_CANVAS_STATE_DIR` overrides it, for tests.
    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        if let override = ProcessInfo.processInfo.environment["NUBB_CANVAS_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.evancdev.nubb/CanvasAgent", isDirectory: true)
    }

    /// The canonical path of a drawing: absolute, symlinks resolved.
    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func baseName(for path: String) -> String {
        String(format: "%016llx", CanvasRandom.stableHash(path))
    }

    static func stateURL(for path: String) -> URL {
        directory.appendingPathComponent(baseName(for: path) + ".json")
    }

    static func load(for url: URL) -> CanvasAgentState {
        let path = canonicalPath(url)
        guard let data = try? Data(contentsOf: stateURL(for: path)),
              let json = try? CanvasJSON.parse(data),
              let state = CanvasAgentState(json: json), state.path == path else {
            return CanvasAgentState(path: path)
        }
        return state
    }

    static func save(_ state: CanvasAgentState) throws {
        let url = stateURL(for: state.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try state.json.serialized().write(to: url, options: .atomic)
    }

    static func remove(for url: URL) {
        try? FileManager.default.removeItem(at: stateURL(for: canonicalPath(url)))
    }

    /// Runs `body` while holding a lock for the drawing, so agents working
    /// on the same file at once take turns.
    static func withLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(baseName(for: canonicalPath(url)) + ".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
