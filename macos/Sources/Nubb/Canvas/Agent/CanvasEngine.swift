import CoreGraphics
import Foundation

/// What a change to a drawing did, for the report agents read.
struct CanvasApplyReport {
    var created: [String] = []
    var updated: [String] = []
    var deleted: [String] = []
    /// The box of every node, after layout, by id.
    var boxes: [String: CGRect] = [:]
    /// The top-level nodes applied, in order, with their boxes.
    var units: [(id: String, box: CGRect)] = []
    var warnings: [String] = []
    /// What the user changed by hand since the agent last looked.
    var userChanges: [CanvasElementChange] = []
    /// Elements layout made that stay hidden because the user deleted them.
    var hidden: [String] = []

    var changed: Bool { !created.isEmpty || !updated.isEmpty || !deleted.isEmpty }
}

/// Applies agent specs to a drawing: lays nodes out, routes arrows, keeps
/// the user's edits, and puts the elements into the file where Excalidraw
/// expects them.
///
/// Every change lays out all the agent's nodes again from their specs and
/// puts the user's edits back on top, so arrows between nodes always meet
/// their ends and a drawing never depends on the order changes came in.
enum CanvasEngine {
    /// Space between a new top-level node and what's already drawn.
    static let placementGap = 80.0

    // MARK: Apply

    /// Applies a spec: nodes to add or replace, and `set`, `move`, and
    /// `delete` changes.
    @discardableResult
    static func apply(_ json: CanvasJSON, to file: CanvasAgentDocument) throws -> CanvasApplyReport {
        var reader = CanvasSpecReader(theme: themeJSON(file.state))
        let spec = reader.read(json)
        guard reader.issues.isEmpty else { throw CanvasAgentError.spec(reader.issues) }

        file.absorbUserChanges()
        var report = CanvasApplyReport()
        report.userChanges = file.userChanges
        let before = file.document
        let owners = ownership(file.state)

        if let styles = json["styles"]?.objectValue {
            for (name, value) in styles { file.state.styles[name] = value }
        }
        if let defaults = json["defaults"]?.objectValue {
            for (name, value) in defaults { file.state.defaults[name] = value }
        }

        let raws = rawNodes(json)
        for (index, node) in spec.nodes.enumerated() {
            let unitID: String
            if let id = node.id {
                unitID = id
            } else {
                unitID = autoID(for: node, in: file)
                report.warnings.append("\(node.path): no id, so it was added as \"\(unitID)\"; "
                    + "give top-level nodes ids so applying again updates them instead of adding copies")
            }
            var raw = index < raws.count ? raws[index] : .null
            CanvasSpecTree.pinIDs(&raw, id: unitID, previous: file.state.units[unitID]?.spec)
            try upsertUnit(unitID, spec: raw, at: node.at, in: file)
        }
        for edit in spec.edits { try applySet(edit.id, fields: edit.fields, path: edit.path, in: file) }
        for move in spec.moves { try applyMove(move.id, by: move.delta, in: file) }
        for id in spec.deletions { try delete(id, in: file) }

        try relayout(file, owners: owners, report: &report)
        finish(file, before: before, report: &report)
        return report
    }

    /// Lays everything out again without changing any spec, picking up the
    /// user's latest edits.
    @discardableResult
    static func refresh(_ file: CanvasAgentDocument) throws -> CanvasApplyReport {
        file.absorbUserChanges()
        var report = CanvasApplyReport()
        report.userChanges = file.userChanges
        let before = file.document
        try relayout(file, owners: ownership(file.state), report: &report)
        finish(file, before: before, report: &report)
        return report
    }

    /// Forgets the user's edits to `ids` (every node when empty), so layout
    /// shows the specs as written again.
    @discardableResult
    static func reset(_ ids: [String], in file: CanvasAgentDocument) throws -> CanvasApplyReport {
        file.absorbUserChanges()
        var report = CanvasApplyReport()
        report.userChanges = file.userChanges
        let before = file.document
        let owners = ownership(file.state)
        if ids.isEmpty {
            file.state.userEdits = [:]
            file.state.userBases = [:]
            file.state.userDeleted = []
        } else {
            for id in ids {
                guard let unitID = file.state.unit(owning: id), let unit = file.state.units[unitID] else {
                    throw CanvasAgentError.failed("no node \"\(id)\" made by apply")
                }
                let elements = unit.nodes[id] ?? [id]
                let labels = elements.map { CanvasLayout.partID($0, "label") }
                for key in Set(elements + labels + [id]) {
                    file.state.userEdits[key] = nil
                    file.state.userBases[key] = nil
                    file.state.userDeleted.remove(key)
                }
                for node in unit.nodes.keys where unit.nodes[node].map({ Set($0).isSubset(of: Set(elements)) }) == true {
                    file.state.userEdits[node] = nil
                }
            }
        }
        try relayout(file, owners: owners, report: &report)
        finish(file, before: before, report: &report)
        return report
    }

    /// The nodes of a spec as JSON, in the order the reader reads them.
    private static func rawNodes(_ json: CanvasJSON) -> [CanvasJSON] {
        if let array = json.arrayValue { return array }
        guard let object = json.objectValue else { return [] }
        if object["type"] != nil || CanvasSpecTree.kindKey(of: json) != nil, object["nodes"] == nil { return [json] }
        if let nodes = object["nodes"] { return nodes.arrayValue ?? [nodes] }
        return []
    }

    /// An id for a top-level node without one: its kind and a number.
    private static func autoID(for node: CanvasSpecNode, in file: CanvasAgentDocument) -> String {
        let base = node.kind == .raw ? "element" : node.kind.rawValue
        var n = 1
        while file.state.unit(owning: "\(base)\(n)") != nil || file.document.element(id: "\(base)\(n)") != nil { n += 1 }
        return "\(base)\(n)"
    }

    private static func upsertUnit(_ id: String, spec: CanvasJSON, at: CGPoint?, in file: CanvasAgentDocument) throws {
        if var unit = file.state.units[id] {
            unit.spec = spec
            if let at {
                // A position from the agent replaces where the user put it.
                unit.origin = at
                file.state.userEdits[id]?["dx"] = nil
                file.state.userEdits[id]?["dy"] = nil
            }
            file.state.units[id] = unit
        } else {
            if let other = file.state.unit(owning: id) {
                throw CanvasAgentError.usage("id \"\(id)\" is already used inside \"\(other)\"; ids must be unique in a drawing")
            }
            file.state.units[id] = CanvasAgentState.Unit(spec: spec, origin: at ?? placement(in: file), elements: [])
            file.state.unitOrder.append(id)
        }
        let ids = CanvasSpecTree.subtreeIDs(spec, id: id)
        for other in file.state.unitOrder where other != id {
            guard let unit = file.state.units[other] else { continue }
            let taken = ids.intersection(CanvasSpecTree.subtreeIDs(unit.spec, id: other))
            if let first = taken.sorted().first {
                throw CanvasAgentError.usage("id \"\(first)\" is already used in \"\(other)\"; ids must be unique in a drawing")
            }
        }
    }

    /// Below everything already drawn, at its left edge.
    private static func placement(in file: CanvasAgentDocument) -> CGPoint {
        var bounds = CanvasRenderer.sceneBounds(of: file.document.elements)
        for (id, unit) in file.state.units {
            if let box = unit.boxes[id] { bounds = bounds.union(box) }
        }
        guard !bounds.isNull else { return .zero }
        return CGPoint(x: bounds.minX.rounded(), y: (bounds.maxY + placementGap).rounded())
    }

    // MARK: Set, move, delete

    /// The node an element id stands for: the node itself, or the node
    /// that made a part like `b1:label`.
    private static func node(for id: String, in state: CanvasAgentState) -> (unit: String, path: CanvasSpecTree.Path, id: String)? {
        for candidate in [id, CanvasSpecNames.nodeID(ofElement: id)] {
            guard let unitID = state.unit(owning: candidate), let unit = state.units[unitID],
                  let path = CanvasSpecTree.find(candidate, in: unit.spec, rootID: unitID) else { continue }
            return (unitID, path, candidate)
        }
        return nil
    }

    private static let textKeys: Set<String> = ["text", "label", "name", "code", "content"]
    private static let layoutKinds: Set<String> = ["stack", "column", "row", "grid"]

    /// Changes fields of a node, by id. Nodes made by apply change in their
    /// spec, so the change lasts; other elements change in the file.
    static func applySet(_ id: String, fields: [String: CanvasJSON], path: String, in file: CanvasAgentDocument) throws {
        if let target = node(for: id, in: file.state), var unit = file.state.units[target.unit] {
            guard var object = CanvasSpecTree.get(target.path, in: unit.spec)?.objectValue else {
                throw CanvasAgentError.failed("\(path): can't change \"\(id)\"")
            }
            let isRaw = object["type"] != nil
            let kind = CanvasSpecTree.kindKey(of: .object(object))
            for (key, value) in fields {
                if key == "id" { throw CanvasAgentError.usage("\(path).id: ids can't change; delete the node and add a new one") }
                if key == "name", kind != "frame", !isRaw {
                    // Everything but a frame: the name shown on hover.
                    object["name"] = value == .null || value.stringValue?.isEmpty == true ? nil : value
                    forgetEdit(target.id, CanvasAgentDocument.customDataKey("name"), in: file)
                    continue
                }
                if textKeys.contains(key), !isRaw {
                    guard let kind, !layoutKinds.contains(kind), object[kind]?.arrayValue == nil || kind == "code" || kind == "text" else {
                        throw CanvasAgentError.usage("\(path).\(key): \"\(target.id)\" holds other nodes and has no text of its own; set the text of a child")
                    }
                    object[kind] = value
                    // New text from the agent replaces the user's.
                    for part in [target.id, CanvasLayout.partID(target.id, "label"), CanvasLayout.partID(target.id, "code")] {
                        for field in ["originalText", "text", "name"] { forgetEdit(part, field, in: file) }
                    }
                } else if isRaw, key == "text" {
                    object["text"] = value
                    object["originalText"] = value
                    forgetEdit(target.id, "originalText", in: file)
                } else {
                    object[key] = value == .null ? nil : value
                    if ["width", "height"].contains(key) {
                        forgetEdit(target.id, key, in: file)
                    }
                }
            }
            CanvasSpecTree.set(target.path, in: &unit.spec, to: .object(object))
            var reader = CanvasSpecReader(theme: themeJSON(file.state))
            _ = reader.read(.array([unit.spec]))
            if !reader.issues.isEmpty {
                throw CanvasAgentError.spec(reader.issues.map {
                    CanvasSpecIssue(path: path, message: "\($0.message) (at \($0.path) of \"\(target.unit)\")")
                })
            }
            file.state.units[target.unit] = unit
            return
        }

        guard let index = file.document.elements.firstIndex(where: { $0.id == id }) else {
            throw CanvasAgentError.failed("\(path): no element or node \"\(id)\"" + hint(id, in: file))
        }
        var json = file.document.elements[index].json.objectValue ?? [:]
        for (key, value) in fields {
            switch key {
            case "id", "type":
                throw CanvasAgentError.usage("\(path).\(key): an element's \(key) can't change")
            case "name" where json["type"]?.stringValue != CanvasElementType.frame.rawValue:
                var element = CanvasElement(json: .object(json)) ?? file.document.elements[index]
                element.hoverName = value.stringValue
                json["customData"] = element.extra["customData"] ?? .null
            case "text", "label", "content":
                json["text"] = value
                json["originalText"] = value
            case "color":
                json["strokeColor"] = value.stringValue.flatMap { CanvasSpecNames.color($0, role: .stroke) }.map(CanvasJSON.string) ?? value
            case "fill":
                json["backgroundColor"] = value.stringValue.flatMap { CanvasSpecNames.color($0, role: .fill) }.map(CanvasJSON.string) ?? value
            default:
                json[key] = value
            }
        }
        guard var element = CanvasElement(json: .object(json)) else {
            throw CanvasAgentError.failed("\(path): that change makes \"\(id)\" invalid")
        }
        let positions = CanvasOps.index(file.document)
        if element.type == .text {
            if let container = element.containerId.flatMap({ positions[$0] }) {
                CanvasOps.layoutLabel(&element, container: file.document.elements[container])
            } else {
                CanvasOps.remeasure(&element)
            }
        }
        file.document.elements[index] = element
        if let label = element.boundTextID, let l = positions[label], fields["text"] ?? fields["label"] ?? fields["content"] != nil {
            var text = file.document.elements[l]
            text.originalText = (fields["text"] ?? fields["label"] ?? fields["content"])?.stringValue ?? text.originalText
            file.document.elements[l] = text
        }
        CanvasOps.updateRelations(changed: [id], in: &file.document)
    }

    private static func forgetEdit(_ id: String, _ key: String, in file: CanvasAgentDocument) {
        file.state.userEdits[id]?[key] = nil
        file.state.userBases[id]?[key] = nil
        if file.state.userEdits[id]?.isEmpty == true { file.state.userEdits[id] = nil }
        if file.state.userBases[id]?.isEmpty == true { file.state.userBases[id] = nil }
    }

    static func applyMove(_ id: String, by delta: CGVector, in file: CanvasAgentDocument) throws {
        if let target = node(for: id, in: file.state) {
            var edits = file.state.userEdits[target.id] ?? [:]
            let dx = (edits["dx"]?.doubleValue ?? 0) + Double(delta.dx)
            let dy = (edits["dy"]?.doubleValue ?? 0) + Double(delta.dy)
            edits["dx"] = abs(dx) < 0.001 ? nil : .number(dx)
            edits["dy"] = abs(dy) < 0.001 ? nil : .number(dy)
            file.state.userEdits[target.id] = edits.isEmpty ? nil : edits
            return
        }
        guard file.document.element(id: id) != nil else {
            throw CanvasAgentError.failed("move: no element or node \"\(id)\"" + hint(id, in: file))
        }
        let ids = CanvasOps.withFrameChildren(CanvasOps.expandGroups([id], in: file.document), in: file.document)
        for i in file.document.elements.indices where ids.contains(file.document.elements[i].id) {
            file.document.elements[i].x += Double(delta.dx)
            file.document.elements[i].y += Double(delta.dy)
        }
        CanvasOps.updateRelations(changed: ids, in: &file.document)
    }

    /// Deletes a node or element by id, with everything inside it.
    static func delete(_ id: String, in file: CanvasAgentDocument) throws {
        if file.state.units[id] != nil {
            CanvasOps.delete(Set(file.state.units[id]!.elements), in: &file.document)
            file.state.units[id] = nil
            file.state.unitOrder.removeAll { $0 == id }
            return
        }
        if let target = node(for: id, in: file.state), target.id == id, var unit = file.state.units[target.unit] {
            CanvasSpecTree.set(target.path, in: &unit.spec, to: nil)
            file.state.units[target.unit] = unit
            return
        }
        if let target = node(for: id, in: file.state) {
            throw CanvasAgentError.usage("delete: \"\(id)\" is part of \"\(target.id)\"; delete \"\(target.id)\" or `set` it")
        }
        guard file.document.element(id: id) != nil else {
            throw CanvasAgentError.failed("delete: no element or node \"\(id)\"" + hint(id, in: file))
        }
        CanvasOps.delete(CanvasOps.expandGroups([id], in: file.document), in: &file.document)
    }

    /// " (did you mean ...?)" for an id that doesn't exist.
    static func hint(_ id: String, in file: CanvasAgentDocument) -> String {
        var candidates = file.document.elements.map(\.id)
        for unit in file.state.units.values { candidates.append(contentsOf: unit.nodes.keys) }
        return CanvasSpecNames.suggestion(for: id, in: candidates).map { " (did you mean \"\($0)\"?)" } ?? ""
    }

    // MARK: Layout

    static func themeJSON(_ state: CanvasAgentState) -> CanvasJSON {
        .object(["styles": .object(state.styles), "defaults": .object(state.defaults)])
    }

    /// Which unit made each element, from the last layout.
    static func ownership(_ state: CanvasAgentState) -> [String: String] {
        var result: [String: String] = [:]
        for unitID in state.unitOrder {
            for id in state.units[unitID]?.elements ?? [] { result[id] = unitID }
        }
        return result
    }

    /// Lays out every unit, puts the user's edits on top, routes the
    /// connectors, and replaces the units' elements in the drawing.
    /// `owners` is which unit made each element in the drawing now.
    static func relayout(_ file: CanvasAgentDocument, owners: [String: String], report: inout CanvasApplyReport) throws {
        let theme = themeJSON(file.state)
        let overrides = CanvasLayoutOverrides(fields: file.state.userEdits, bases: file.state.userBases)
        let layout = CanvasLayout(overrides: overrides)

        var unitElements: [String: [CanvasElement]] = [:]
        var unitConnectors: [String: [CanvasPendingConnector]] = [:]
        var boxes: [String: CGRect] = [:]
        var owned: [String: String] = [:]

        for id in file.state.unitOrder {
            guard var unit = file.state.units[id] else { continue }
            var reader = CanvasSpecReader(theme: theme)
            let spec = reader.read(.array([unit.spec]))
            guard reader.issues.isEmpty, let node = spec.nodes.first else {
                throw CanvasAgentError.spec(reader.issues.map { CanvasSpecIssue(path: "\(id) \($0.path)", message: $0.message) })
            }
            var block = layout.layout(node, id: id, origin: unit.origin)
            // A node new to this drawing's records whose elements are in the
            // file already (its state was lost, or a script wrote it): keep
            // it where it is, and take its elements over.
            if unit.elements.isEmpty, unit.spec["at"] == nil,
               let match = block.elements.first(where: { !$0.type.isLinear && !($0.type == .text && $0.containerId != nil) && file.document.element(id: $0.id) != nil }),
               let existing = file.document.element(id: match.id) {
                let dx = existing.x - match.x, dy = existing.y - match.y
                if dx != 0 || dy != 0 {
                    unit.origin = CGPoint(x: Double(unit.origin.x) + dx, y: Double(unit.origin.y) + dy)
                    block = layout.layout(node, id: id, origin: unit.origin)
                }
            }
            report.warnings.append(contentsOf: block.issues.map { "\(id): \($0.description)" })
            var ids = block.elements.map(\.id)
            for connector in block.connectors {
                ids.append(connector.id)
                ids.append(CanvasLayout.partID(connector.id, "label"))
            }
            for elementID in ids {
                if let other = owned[elementID] {
                    throw CanvasAgentError.usage("\"\(id)\" and \"\(other)\" both make an element \"\(elementID)\"; ids must be unique")
                }
                owned[elementID] = id
            }
            unit.elements = ids
            unit.nodes = block.nodeElements
            unit.boxes = block.boxes
            file.state.units[id] = unit
            boxes.merge(block.boxes) { _, new in new }
            if let box = block.boxes[id] { report.units.append((id, box)) }

            var elements: [CanvasElement] = []
            for element in block.elements {
                if file.state.userDeleted.contains(element.id) {
                    report.hidden.append(element.id)
                    continue
                }
                elements.append(applyUserEdits(element, edits: file.state.userEdits[element.id], bases: file.state.userBases[element.id]))
            }
            unitElements[id] = elements
            unitConnectors[id] = block.connectors
        }
        report.boxes = boxes

        // Elements with the ids layout makes that apply has no record of,
        // from an apply whose state is gone or a file written by a script:
        // take them over and replace them in place. Excalidraw's own ids
        // are random, so these come from agents.
        var owners = owners
        let adopted = file.document.elements.filter { owners[$0.id] == nil && owned[$0.id] != nil }.map(\.id)
        for id in adopted { owners[id] = owned[id] }
        if !adopted.isEmpty {
            report.warnings.append("took over \(adopted.count) element\(adopted.count == 1 ? "" : "s") already in the drawing with the same ids ("
                + adopted.prefix(5).joined(separator: ", ") + (adopted.count > 5 ? ", ..." : "") + ")")
        }

        // Labels follow containers the user changed.
        for (unitID, elements) in unitElements {
            var list = elements
            let positions = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for i in list.indices {
                guard list[i].type == .text, let container = list[i].containerId.flatMap({ positions[$0] }),
                      file.state.userEdits[list[list.startIndex + container].id] != nil else { continue }
                CanvasOps.layoutLabel(&list[i], container: list[container])
            }
            unitElements[unitID] = list
        }

        // Connectors, between the new layout and the user's elements.
        var lookup: [String: CanvasElement] = [:]
        for element in file.document.elements where owners[element.id] == nil { lookup[element.id] = element }
        for elements in unitElements.values {
            for element in elements { lookup[element.id] = element }
        }
        var routed = Set<String>()
        var pinned = Set<String>()
        for unitID in file.state.unitOrder {
            for connector in unitConnectors[unitID] ?? [] {
                if file.state.userDeleted.contains(connector.id) {
                    report.hidden.append(connector.id)
                    continue
                }
                guard var built = CanvasConnectors.build(connector, elements: lookup, boxes: boxes,
                                                         overrides: overrides, warnings: &report.warnings) else { continue }
                built[0] = applyUserEdits(built[0], edits: file.state.userEdits[connector.id], bases: file.state.userBases[connector.id])
                if let line = pinnedLine(built[0], edits: file.state.userEdits[connector.id]) {
                    built[0] = line
                    pinned.insert(connector.id)
                } else {
                    routed.insert(connector.id)
                }
                if built.count > 1 {
                    if file.state.userDeleted.contains(built[1].id) {
                        report.hidden.append(built[1].id)
                        built[0].removeBoundElement(id: built[1].id)
                        built.removeLast()
                    } else {
                        built[1] = applyUserEdits(built[1], edits: file.state.userEdits[built[1].id], bases: file.state.userBases[built[1].id])
                        CanvasOps.layoutLabel(&built[1], container: built[0])
                    }
                }
                unitElements[unitID, default: []].append(contentsOf: built)
            }
        }

        let previous = Dictionary(file.document.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        splice(unitElements, owners: owners, order: file.state.unitOrder, into: &file.document)
        repairRelations(in: &file.document)
        var moved = Set<String>()
        for element in file.document.elements {
            guard let old = previous[element.id] else { continue }
            if old.x != element.x || old.y != element.y || old.width != element.width
                || old.height != element.height || old.angle != element.angle {
                moved.insert(element.id)
            }
        }
        follow(moved: moved, always: pinned, skip: routed, in: &file.document)
        pruneEdits(file, owned: owned)
    }

    /// Fields layout reads from the user's edits itself, or that stay as
    /// layout made them.
    private static let layoutFields: Set<String> = ["originalText", "text", "width", "height", "dx", "dy", "ox", "oy"]

    /// The element with the user's other field changes put back.
    private static func applyUserEdits(_ element: CanvasElement, edits: [String: CanvasJSON]?, bases: [String: CanvasJSON]? = nil) -> CanvasElement {
        guard let edits, !edits.isEmpty, var json = element.json.objectValue else { return element }
        let built = json["customData"]?.objectValue ?? [:]
        var customData = built
        var changed = false
        for (key, value) in edits where !layoutFields.contains(key) {
            if element.type.isLinear, ["x", "y", "points", "startBinding", "endBinding"].contains(key) { continue }
            if element.type == .text, element.containerId != nil, ["x", "y"].contains(key) { continue }
            if let sub = CanvasAgentDocument.customDataField(key) {
                // The person's value stands while the spec still says what
                // it said when they changed it; a change from the agent wins.
                if let base = bases?[key], !CanvasJSON.nearlyEqual(CanvasDiff.normalized(base), CanvasDiff.normalized(built[sub])) {
                    continue
                }
                customData[sub] = value == .null ? nil : value
                changed = true
                continue
            }
            json[key] = value
            changed = true
        }
        if customData != built { json["customData"] = customData.isEmpty ? .null : .object(customData) }
        let ox = edits["ox"]?.doubleValue ?? 0, oy = edits["oy"]?.doubleValue ?? 0
        let isLabel = element.type == .text && element.containerId != nil
        guard changed || (!element.type.isLinear && !isLabel && (ox != 0 || oy != 0)) else { return element }
        guard var result = CanvasElement(json: .object(json)) else { return element }
        result.version = element.version
        result.versionNonce = element.versionNonce
        result.updated = element.updated
        if !result.type.isLinear, !isLabel {
            result.x += ox
            result.y += oy
        }
        if changed, result.type == .text, result.containerId == nil {
            CanvasOps.remeasure(&result)
        }
        return result
    }

    /// A line the user moved or bent by hand, where they left it, attached
    /// to what they attached it to.
    private static func pinnedLine(_ element: CanvasElement, edits: [String: CanvasJSON]?) -> CanvasElement? {
        guard let edits, let x = edits["x"]?.doubleValue, let y = edits["y"]?.doubleValue,
              let points = edits["points"], var json = element.json.objectValue else { return nil }
        json["x"] = .number(x)
        json["y"] = .number(y)
        json["points"] = points
        json["startBinding"] = edits["startBinding"] ?? .null
        json["endBinding"] = edits["endBinding"] ?? .null
        guard var result = CanvasElement(json: .object(json)) else { return nil }
        CanvasOps.normalizePoints(&result)
        return result
    }

    // MARK: Splicing

    /// Replaces each unit's elements in the drawing where its old ones were,
    /// keeping the user's own elements and their order. New units go on
    /// top.
    private static func splice(
        _ units: [String: [CanvasElement]], owners: [String: String], order: [String], into document: inout CanvasDocument
    ) {
        var result: [CanvasElement] = []
        result.reserveCapacity(document.elements.count + units.values.reduce(0) { $0 + $1.count })
        var emitted = Set<String>()
        for element in document.elements {
            if let unit = owners[element.id] {
                if units[unit] != nil, emitted.insert(unit).inserted { result.append(contentsOf: units[unit]!) }
                continue
            }
            result.append(element)
        }
        for unit in order where !emitted.contains(unit) { result.append(contentsOf: units[unit] ?? []) }
        document.elements = result
    }

    /// Makes `boundElements`, `containerId`, bindings, and `frameId` agree
    /// across the drawing, as Excalidraw's restore does, keeping the order
    /// of entries that were right.
    static func repairRelations(in document: inout CanvasDocument) {
        let positions = CanvasOps.index(document)
        var bound: [String: [CanvasBoundElement]] = [:]
        for element in document.elements {
            if element.type == .text, let container = element.containerId, positions[container] != nil {
                bound[container, default: []].append(CanvasBoundElement(id: element.id, type: "text"))
            }
            if element.type.isLinear {
                for target in [element.startBinding?.elementId, element.endBinding?.elementId].compactMap({ $0 })
                where positions[target] != nil && bound[target]?.contains(where: { $0.id == element.id }) != true {
                    bound[target, default: []].append(CanvasBoundElement(id: element.id, type: element.type.rawValue))
                }
            }
        }
        for i in document.elements.indices {
            var element = document.elements[i]
            let wanted = bound[element.id] ?? []
            var list = (element.boundElements ?? []).filter { item in wanted.contains(item) }
            for item in wanted where !list.contains(item) { list.append(item) }
            // A container has one label: the first.
            var seenText = false
            list.removeAll { item in
                guard item.type == "text" else { return false }
                defer { seenText = true }
                return seenText
            }
            element.boundElements = list.isEmpty ? nil : list
            if let binding = element.startBinding, positions[binding.elementId] == nil { element.startBinding = nil }
            if let binding = element.endBinding, positions[binding.elementId] == nil { element.endBinding = nil }
            if element.type == .text, let container = element.containerId, positions[container] == nil {
                element.containerId = nil
            }
            if let frame = element.frameId, positions[frame].map({ document.elements[$0].type != .frame }) ?? true {
                element.frameId = nil
            }
            document.elements[i] = element
        }
    }

    /// Moves the ends of lines bound to elements that moved onto them: the
    /// user's own lines, and lines the user placed by hand (`always`).
    /// Lines layout just routed (`skip`) are right already.
    private static func follow(moved: Set<String>, always: Set<String>, skip: Set<String>, in document: inout CanvasDocument) {
        let positions = CanvasOps.index(document)
        for i in document.elements.indices {
            var arrow = document.elements[i]
            guard arrow.type.isLinear, !skip.contains(arrow.id) else { continue }
            let targets = [arrow.startBinding?.elementId, arrow.endBinding?.elementId].compactMap { $0 }
            guard always.contains(arrow.id) || targets.contains(where: moved.contains) else { continue }
            CanvasOps.updateBoundEnds(&arrow, in: document, positions: positions)
            document.elements[i] = arrow
            if let label = arrow.boundTextID, let l = positions[label] {
                CanvasOps.layoutLabel(&document.elements[l], container: arrow)
            }
        }
    }

    /// Drops the user's edits the layout no longer shows, because the
    /// agent changed what they were based on or the element is gone.
    private static func pruneEdits(_ file: CanvasAgentDocument, owned: [String: String]) {
        var nodes = Set<String>()
        for unit in file.state.units.values { nodes.formUnion(unit.nodes.keys) }
        let present = Dictionary(file.document.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, edits) in file.state.userEdits {
            guard owned[id] != nil || nodes.contains(id) else {
                file.state.userEdits[id] = nil
                file.state.userBases[id] = nil
                continue
            }
            guard let element = present[id], let json = element.json.objectValue else { continue }
            for (key, value) in edits where !["dx", "dy", "ox", "oy", "x", "y", "points", "text", "startBinding", "endBinding"].contains(key) {
                let current = CanvasAgentDocument.customDataField(key).map { json["customData"]?[$0] } ?? json[key]
                if !CanvasJSON.nearlyEqual(current ?? .null, value) { forgetEdit(id, key, in: file) }
            }
        }
        file.state.userDeleted = file.state.userDeleted.filter { owned[$0] != nil }
    }

    // MARK: Finishing

    /// Gives elements that changed new versions, so Excalidraw and an open
    /// viewer pick them up, keeps the old ones on elements that didn't,
    /// and fills in the report.
    static func finish(_ file: CanvasAgentDocument, before: CanvasDocument, report: inout CanvasApplyReport) {
        CanvasOps.keepLabelsAboveContainers(in: &file.document)
        CanvasOps.keepFramesAboveMembers(in: &file.document)
        let old = Dictionary(before.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(file.document.elements.map(\.id))
        let time = CanvasRandom.timestamp()
        for i in file.document.elements.indices {
            var element = file.document.elements[i]
            if let previous = old[element.id] {
                if CanvasDiff.sameContent(previous, element) {
                    element = previous
                } else {
                    element.version = previous.version + 1
                    element.versionNonce = CanvasRandom.seed()
                    element.updated = time
                    report.updated.append(element.id)
                }
            } else {
                element.version = max(element.version, 1)
                element.versionNonce = CanvasRandom.seed()
                element.updated = time
                report.created.append(element.id)
            }
            file.document.elements[i] = element
        }
        report.deleted = old.keys.filter { !now.contains($0) }.sorted()
    }
}
