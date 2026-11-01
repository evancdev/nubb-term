import Foundation

/// Finds and edits nodes inside spec JSON by node id, using the same ids
/// layout gives them: a node's own `id`, or its parent's id and its index,
/// like `lesson.2.0`.
enum CanvasSpecTree {
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    typealias Path = [Step]

    private static let containerKinds: Set<String> = ["stack", "column", "row", "grid"]
    private static let parentKinds: Set<String> = ["box", "rect", "rectangle", "ellipse", "diamond", "frame", "panel"]

    /// The key holding a node's children, if it has any.
    static func childrenKey(of node: CanvasJSON) -> String? {
        guard let object = node.objectValue, object["type"] == nil else { return nil }
        if let key = object.keys.first(where: containerKinds.contains), object[key]?.arrayValue != nil { return key }
        if let key = object.keys.first(where: shapeKinds.contains), object[key]?.arrayValue != nil { return key }
        if object.keys.contains(where: parentKinds.contains), object["children"]?.arrayValue != nil { return "children" }
        return nil
    }

    private static let shapeKinds: Set<String> = ["box", "rect", "rectangle", "ellipse", "diamond"]

    /// Calls `visit` with every node's id and path, parents first.
    static func walk(_ node: CanvasJSON, id: String, path: Path = [], _ visit: (String, Path, CanvasJSON) -> Void) {
        visit(id, path, node)
        guard let key = childrenKey(of: node), let children = node[key]?.arrayValue else { return }
        for (index, child) in children.enumerated() {
            let childID = child["id"]?.stringValue ?? "\(id).\(index)"
            walk(child, id: childID, path: path + [.key(key), .index(index)], visit)
        }
    }

    /// The path of the node with id `target`.
    static func find(_ target: String, in node: CanvasJSON, rootID: String) -> Path? {
        var found: Path?
        walk(node, id: rootID) { id, path, _ in
            if found == nil, id == target { found = path }
        }
        return found
    }

    /// The ids of a node and everything inside it.
    static func subtreeIDs(_ node: CanvasJSON, id: String) -> Set<String> {
        var result = Set<String>()
        walk(node, id: id) { childID, _, _ in result.insert(childID) }
        return result
    }

    /// The ids the agent gave nodes explicitly, with their paths.
    static func explicitIDs(_ node: CanvasJSON, rootID: String) -> [String] {
        var result: [String] = []
        walk(node, id: rootID) { id, path, json in
            if path.isEmpty || json["id"] != nil { result.append(id) }
        }
        return result
    }

    static func get(_ path: Path, in node: CanvasJSON) -> CanvasJSON? {
        var current: CanvasJSON? = node
        for step in path {
            switch step {
            case .key(let key): current = current?[key]
            case .index(let index):
                guard let array = current?.arrayValue, array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    /// Replaces the node at `path`, or removes it when `value` is nil.
    static func set(_ path: Path, in node: inout CanvasJSON, to value: CanvasJSON?) {
        guard let step = path.first else {
            if let value { node = value }
            return
        }
        let rest = Array(path.dropFirst())
        switch step {
        case .key(let key):
            guard var object = node.objectValue else { return }
            if rest.isEmpty {
                object[key] = value
            } else if var child = object[key] {
                set(rest, in: &child, to: value)
                object[key] = child
            }
            node = .object(object)
        case .index(let index):
            guard var array = node.arrayValue, array.indices.contains(index) else { return }
            if rest.isEmpty {
                if let value { array[index] = value } else { array.remove(at: index) }
            } else {
                set(rest, in: &array[index], to: value)
            }
            node = .array(array)
        }
    }

    /// The node's kind key, like `box` or `frame`.
    static func kindKey(of node: CanvasJSON) -> String? {
        guard let object = node.objectValue else { return nil }
        let kinds = containerKinds.union(parentKinds).union(["text", "code", "arrow", "line"])
        return object.keys.sorted().first(where: kinds.contains)
    }

    /// Writes the ids layout derives into nodes without one, so they stay
    /// the same when siblings are added or removed later. A node without an
    /// id that matches a node of `previous` (same kind and content) keeps
    /// that node's id, so inserting a paragraph doesn't renumber the rest.
    static func pinIDs(_ node: inout CanvasJSON, id: String, previous: CanvasJSON? = nil) {
        var used = Set<String>([id])
        walkRaw(node) { child in if let explicit = child["id"]?.stringValue { used.insert(explicit) } }
        pin(&node, id: id, previous: previous, used: &used)
    }

    private static func walkRaw(_ node: CanvasJSON, _ visit: (CanvasJSON) -> Void) {
        visit(node)
        guard let key = childrenKey(of: node), let children = node[key]?.arrayValue else { return }
        for child in children { walkRaw(child, visit) }
    }

    /// What identifies a node without an id: its kind and content.
    private static func signature(_ node: CanvasJSON) -> String? {
        if let text = node.stringValue { return "text:" + CanvasJSON.string(text).compactText }
        guard let kind = kindKey(of: node), let value = node[kind] else { return nil }
        if childrenKey(of: node) == kind { return nil }
        return "\(kind == "rect" || kind == "rectangle" ? "box" : kind):" + value.compactText
    }

    private static func pin(_ node: inout CanvasJSON, id: String, previous: CanvasJSON?, used: inout Set<String>) {
        if node.stringValue != nil { node = .object(["text": node]) }
        guard var object = node.objectValue else { return }
        if object["id"] == nil { object["id"] = .string(id) }
        guard let key = childrenKey(of: .object(object)), var children = object[key]?.arrayValue else {
            node = .object(object)
            return
        }
        let oldChildren = previous.flatMap { old in childrenKey(of: old).flatMap { old[$0]?.arrayValue } } ?? []
        var oldByID: [String: CanvasJSON] = [:]
        var oldBySignature: [String: [String]] = [:]
        for child in oldChildren {
            guard let childID = child["id"]?.stringValue else { continue }
            oldByID[childID] = child
            if let signature = signature(child) { oldBySignature[signature, default: []].append(childID) }
        }
        // First the children that keep an id: given, or matched by content.
        var ids: [String?] = children.map { $0["id"]?.stringValue }
        for index in children.indices where ids[index] == nil {
            guard let signature = signature(children[index]),
                  let match = oldBySignature[signature]?.first(where: { !used.contains($0) }) else { continue }
            ids[index] = match
            used.insert(match)
        }
        // Then new ones by position, skipping ids taken.
        for index in children.indices where ids[index] == nil {
            var candidate = "\(id).\(index)"
            var n = 2
            while used.contains(candidate) {
                candidate = "\(id).\(index)-\(n)"
                n += 1
            }
            ids[index] = candidate
            used.insert(candidate)
        }
        for index in children.indices {
            let childID = ids[index]!
            pin(&children[index], id: childID, previous: oldByID[childID], used: &used)
        }
        object[key] = .array(children)
        node = .object(object)
    }
}
