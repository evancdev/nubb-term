import CoreGraphics
import Foundation

/// Document edits that keep elements consistent with each other: bound
/// arrows follow their shapes, labels stay inside their containers, and
/// deleting or copying an element takes its label and bindings along.
enum CanvasOps {
    /// Marks an element as edited, the way Excalidraw's `mutateElement` does.
    static func touch(_ element: inout CanvasElement) {
        element.version += 1
        element.versionNonce = CanvasRandom.seed()
        element.updated = CanvasRandom.timestamp()
    }

    static func index(_ document: CanvasDocument) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(document.elements.count)
        for (i, element) in document.elements.enumerated() { result[element.id] = i }
        return result
    }

    /// Edits the element with `id`, if it exists, and marks it edited.
    @discardableResult
    static func update(_ id: String, in document: inout CanvasDocument, _ body: (inout CanvasElement) -> Void) -> Bool {
        guard let i = document.elements.firstIndex(where: { $0.id == id }) else { return false }
        var element = document.elements[i]
        body(&element)
        if element != document.elements[i] {
            touch(&element)
            document.elements[i] = element
        }
        return true
    }

    // MARK: Linear elements

    /// Puts the first point of a line at (0, 0), moves `x`/`y` to match, and
    /// sets `width`/`height` to the size of the points, as Excalidraw stores
    /// lines.
    static func normalizePoints(_ element: inout CanvasElement) {
        guard element.type.hasPoints, let first = element.points.first else { return }
        if first != .zero {
            let shifted = element.points.map { CGPoint(x: $0.x - first.x, y: $0.y - first.y) }
            // Rotation is about the center of the points, which moves with
            // them. Keep the drawing where it is on screen.
            let oldCenter = element.center
            element.points = shifted
            element.x += first.dx
            element.y += first.dy
            let newCenter = element.center
            if element.angle != 0 {
                let rotatedOld = CanvasGeometry.rotate(CGPoint(x: element.x, y: element.y), around: oldCenter, by: element.angle)
                let rotatedNew = CanvasGeometry.rotate(CGPoint(x: element.x, y: element.y), around: newCenter, by: element.angle)
                element.x += rotatedOld.dx - rotatedNew.dx
                element.y += rotatedOld.dy - rotatedNew.dy
            }
        }
        let box = CanvasGeometry.bounds(of: element.points)
        element.width = Double(box.width)
        element.height = Double(box.height)
    }

    /// Sets a line's points from scene coordinates. The line loses its
    /// rotation, which is baked into the points.
    static func setScenePoints(_ points: [CGPoint], of element: inout CanvasElement) {
        guard let first = points.first else { return }
        element.angle = 0
        element.x = first.dx
        element.y = first.dy
        element.points = points.map { CGPoint(x: $0.x - first.x, y: $0.y - first.y) }
        normalizePoints(&element)
    }

    // MARK: Relations

    /// Updates everything attached to the elements in `changed`: arrows
    /// bound to them and labels inside them. Arrows in `changed` get their
    /// bound ends and labels updated too.
    static func updateRelations(changed: Set<String>, in document: inout CanvasDocument) {
        guard !changed.isEmpty else { return }
        var positions = index(document)
        var arrows = Set<String>()
        var labels = Set<String>()

        for id in changed {
            guard let i = positions[id] else { continue }
            let element = document.elements[i]
            if element.type.isLinear { arrows.insert(id) }
            for bound in element.boundElements ?? [] {
                if bound.type == "text" { labels.insert(bound.id) } else { arrows.insert(bound.id) }
            }
            if let container = element.containerId, element.type == .text, positions[container] != nil {
                labels.insert(id)
            }
        }

        for id in arrows.sorted() {
            guard let i = positions[id] else { continue }
            var arrow = document.elements[i]
            guard arrow.startBinding != nil || arrow.endBinding != nil else {
                if let label = arrow.boundTextID { labels.insert(label) }
                continue
            }
            let before = arrow
            updateBoundEnds(&arrow, in: document, positions: positions)
            if arrow != before {
                touch(&arrow)
                document.elements[i] = arrow
            }
            if let label = arrow.boundTextID { labels.insert(label) }
        }

        for id in labels.sorted() {
            guard let i = positions[id] else { continue }
            var text = document.elements[i]
            guard let containerID = text.containerId, let c = positions[containerID] else { continue }
            let before = text
            layoutLabel(&text, container: document.elements[c])
            if text != before {
                touch(&text)
                document.elements[i] = text
            }
        }
        positions = [:]
    }

    /// Moves the bound ends of a line onto their shapes.
    static func updateBoundEnds(_ arrow: inout CanvasElement, in document: CanvasDocument, positions: [String: Int]? = nil) {
        guard arrow.type.isLinear, arrow.points.count >= 2 else { return }
        let positions = positions ?? index(document)
        func target(_ binding: CanvasBinding?) -> CanvasElement? {
            guard let binding, let i = positions[binding.elementId] else { return nil }
            return document.elements[i]
        }

        var scene = arrow.points.map(arrow.toScene)
        let last = scene.count - 1
        let startTarget = target(arrow.startBinding)
        let endTarget = target(arrow.endBinding)
        guard startTarget != nil || endTarget != nil else { return }

        if arrow.isElbowArrow {
            // Right angles all the way: route again between the bound ends.
            let start = startTarget.flatMap { target in arrow.startBinding.map { (target, $0) } }
            let end = endTarget.flatMap { target in arrow.endBinding.map { (target, $0) } }
            let from = start.map { CanvasBinder.endPoint(adjacent: scene[1], element: $0.0, binding: $0.1, elbow: true) } ?? scene[0]
            let to = end.map { CanvasBinder.endPoint(adjacent: scene[last - 1], element: $0.0, binding: $0.1, elbow: true) } ?? scene[last]
            let route = CanvasElbow.route(
                from: from, heading: start.flatMap { CanvasElbow.heading(of: $0.1, on: $0.0) },
                to: to, heading: end.flatMap { CanvasElbow.heading(of: $0.1, on: $0.0) })
            setScenePoints(route, of: &arrow)
            return
        }

        if let startTarget, let binding = arrow.startBinding {
            // With two points bound at both ends, aim at the other shape so
            // the arrow doesn't drift as both move.
            let adjacent = scene.count == 2 && endTarget != nil && arrow.endBinding != nil
                ? CanvasBinder.focusPoint(of: arrow.endBinding!, on: endTarget!)
                : scene[1]
            scene[0] = CanvasBinder.endPoint(adjacent: adjacent, element: startTarget, binding: binding)
        }
        if let endTarget, let binding = arrow.endBinding {
            // Excalidraw aims fixed-point ends at each other's focus points.
            let adjacent = scene.count == 2 && startTarget != nil && arrow.startBinding?.fixedPoint != nil
                ? CanvasBinder.focusPoint(of: arrow.startBinding!, on: startTarget!)
                : scene[last - 1]
            scene[last] = CanvasBinder.endPoint(adjacent: adjacent, element: endTarget, binding: binding)
        }
        setScenePoints(scene, of: &arrow)
    }

    /// Wraps and places a label inside its container.
    static func layoutLabel(_ text: inout CanvasElement, container: CanvasElement) {
        let source = text.originalText.isEmpty ? text.text : text.originalText
        if container.type.isLinear {
            text.text = source
        } else {
            text.text = CanvasText.wrap(
                source, family: text.fontFamily, fontSize: text.fontSize,
                maxWidth: CanvasText.maxLabelWidth(container))
        }
        let size = CanvasText.measure(text.text, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight)
        text.width = Double(size.width)
        text.height = Double(size.height)
        let origin = CanvasText.labelOrigin(text: text, container: container)
        text.x = origin.dx
        text.y = origin.dy
        text.angle = container.type.isLinear ? 0 : container.angle
    }

    /// Grows a container so its label fits, like Excalidraw does while
    /// typing. Returns whether the container changed.
    @discardableResult
    static func growToFit(_ container: inout CanvasElement, label: CanvasElement) -> Bool {
        guard container.type.isContainer else { return false }
        let padding = CanvasGeometry.boundTextPadding * 2
        let needed: Double
        switch container.type {
        case .ellipse: needed = (label.height + padding) * 2 / sqrt(2)
        case .diamond: needed = (label.height + padding) * 2
        default: needed = label.height + padding
        }
        guard needed > container.height else { return false }
        container.height = needed.rounded(.up)
        return true
    }

    /// Re-measures a free text element after its text or font changed. Text
    /// with a fixed width (`autoResize` off) wraps to that width instead.
    static func remeasure(_ text: inout CanvasElement) {
        guard text.type == .text else { return }
        if !text.autoResize, text.width > 0, text.containerId == nil {
            let source = text.originalText.isEmpty ? text.text : text.originalText
            text.text = CanvasText.wrap(source, family: text.fontFamily, fontSize: text.fontSize, maxWidth: text.width)
            text.height = Double(CanvasText.measure(text.text, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight).height)
            return
        }
        let size = CanvasText.measure(text.text, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight)
        text.width = Double(size.width)
        text.height = Double(size.height)
    }

    // MARK: Selection helpers

    /// The ids `ids` stand for: every member of their outermost groups.
    static func expandGroups(_ ids: Set<String>, in document: CanvasDocument) -> Set<String> {
        let groups = Set(document.elements.filter { ids.contains($0.id) }.compactMap(\.groupIds.last))
        guard !groups.isEmpty else { return ids }
        var result = ids
        for element in document.elements where element.groupIds.last.map(groups.contains) == true {
            result.insert(element.id)
        }
        return result
    }

    /// `ids` plus the labels inside them.
    static func withBoundText(_ ids: Set<String>, in document: CanvasDocument) -> Set<String> {
        var result = ids
        for element in document.elements where ids.contains(element.id) {
            if let text = element.boundTextID { result.insert(text) }
        }
        return result
    }

    /// `ids` plus the elements of the frames among them, with their labels.
    /// A frame moves, copies, and deletes together with its elements, as in
    /// Excalidraw.
    static func withFrameChildren(_ ids: Set<String>, in document: CanvasDocument) -> Set<String> {
        let frames = Set(document.elements.filter { $0.type == .frame && ids.contains($0.id) }.map(\.id))
        guard !frames.isEmpty else { return withBoundText(ids, in: document) }
        var result = ids
        for element in document.elements where element.frameId.map(frames.contains) == true {
            result.insert(element.id)
        }
        return withBoundText(result, in: document)
    }

    /// Whether `element` is a label inside an existing container.
    static func isBoundText(_ element: CanvasElement, positions: [String: Int]) -> Bool {
        guard element.type == .text, let container = element.containerId else { return false }
        return positions[container] != nil
    }

    // MARK: Frames

    /// The topmost frame whose box holds `point`, not counting `excluding`.
    static func frame(at point: CGPoint, in document: CanvasDocument, excluding: Set<String> = []) -> CanvasElement? {
        document.elements.last { $0.type == .frame && !excluding.contains($0.id) && $0.sceneBounds.contains(point) }
    }

    /// Updates which frame the elements in `ids` belong to after they were
    /// moved or drawn, as Excalidraw does: an element dropped with the
    /// pointer over a frame joins it, and one that no longer overlaps its
    /// frame leaves it. Frames moved along with their elements keep them.
    /// Labels follow their containers. Returns whether anything changed.
    @discardableResult
    static func updateFrameMembership(of ids: Set<String>, pointer: CGPoint?, in document: inout CanvasDocument) -> Bool {
        let movingFrames = Set(document.elements.filter { $0.type == .frame && ids.contains($0.id) }.map(\.id))
        let target = pointer.flatMap { frame(at: $0, in: document, excluding: movingFrames) }
        let positions = index(document)
        var changed = false
        for i in document.elements.indices {
            var element = document.elements[i]
            guard ids.contains(element.id), element.type != .frame, !isBoundText(element, positions: positions) else { continue }
            // Elements of a frame that moved with them stay in it.
            if let current = element.frameId, movingFrames.contains(current) { continue }
            var next = element.frameId
            if let target, overlaps(element, target) {
                next = target.id
            } else if let current = element.frameId, let frame = positions[current].map({ document.elements[$0] }),
                      !overlaps(element, frame) {
                next = nil
            }
            guard next != element.frameId else { continue }
            element.frameId = next
            touch(&element)
            document.elements[i] = element
            changed = true
            // The label goes where its container goes.
            if let label = element.boundTextID, let l = positions[label], document.elements[l].frameId != next {
                document.elements[l].frameId = next
                touch(&document.elements[l])
            }
        }
        if changed { keepFramesAboveMembers(in: &document) }
        return changed
    }

    /// Whether `element` touches or holds `frame`'s box, Excalidraw's
    /// `elementOverlapsWithFrame`.
    static func overlaps(_ element: CanvasElement, _ frame: CanvasElement) -> Bool {
        let box = element.sceneBounds, area = frame.sceneBounds
        return area.intersects(box) || area.contains(box) || box.contains(area)
    }

    /// Puts each frame's members right below it in the z-order, where
    /// Excalidraw expects them.
    static func keepFramesAboveMembers(in document: inout CanvasDocument) {
        let frames = Set(document.elements.filter { $0.type == .frame }.map(\.id))
        guard !frames.isEmpty else { return }
        let positions = index(document)
        var members: [String: [CanvasElement]] = [:]
        var rest: [CanvasElement] = []
        for element in document.elements {
            var frame = element.frameId
            if element.type == .text, let container = element.containerId.flatMap({ positions[$0] }) {
                frame = document.elements[container].frameId
            }
            if let frame, frames.contains(frame), element.type != .frame {
                members[frame, default: []].append(element)
            } else {
                rest.append(element)
            }
        }
        var result: [CanvasElement] = []
        result.reserveCapacity(document.elements.count)
        for element in rest {
            if element.type == .frame { result.append(contentsOf: members[element.id] ?? []) }
            result.append(element)
        }
        document.elements = result
    }

    // MARK: Delete

    static func delete(_ ids: Set<String>, in document: inout CanvasDocument) {
        guard !ids.isEmpty else { return }
        let removed = withFrameChildren(ids, in: document)
        document.elements.removeAll { removed.contains($0.id) }
        for i in document.elements.indices {
            var element = document.elements[i]
            if let binding = element.startBinding, removed.contains(binding.elementId) { element.startBinding = nil }
            if let binding = element.endBinding, removed.contains(binding.elementId) { element.endBinding = nil }
            if let list = element.boundElements, list.contains(where: { removed.contains($0.id) }) {
                let kept = list.filter { !removed.contains($0.id) }
                element.boundElements = kept.isEmpty ? nil : kept
            }
            if let frame = element.frameId, removed.contains(frame) { element.frameId = nil }
            if element != document.elements[i] {
                touch(&element)
                document.elements[i] = element
            }
        }
    }

    // MARK: Copy

    /// Copies of `sources` with new ids, seeds, and groups. Bindings and
    /// labels between copied elements point at the copies; others are
    /// dropped.
    static func copies(of sources: [CanvasElement], offset: CGVector) -> [CanvasElement] {
        var idMap: [String: String] = [:]
        var groupMap: [String: String] = [:]
        for element in sources { idMap[element.id] = CanvasRandom.id() }

        return sources.map { source in
            var copy = source
            copy.id = idMap[source.id]!
            copy.seed = CanvasRandom.seed()
            copy.version = 1
            copy.versionNonce = CanvasRandom.seed()
            copy.updated = CanvasRandom.timestamp()
            copy.x += Double(offset.dx)
            copy.y += Double(offset.dy)
            copy.groupIds = source.groupIds.map { group in
                if let mapped = groupMap[group] { return mapped }
                let fresh = CanvasRandom.id()
                groupMap[group] = fresh
                return fresh
            }
            copy.containerId = source.containerId.flatMap { idMap[$0] }
            // A copy stays in its frame unless the frame was copied too.
            copy.frameId = source.frameId.map { idMap[$0] ?? $0 }
            let bound = source.boundElements?.compactMap { item in
                idMap[item.id].map { CanvasBoundElement(id: $0, type: item.type) }
            }
            copy.boundElements = (bound?.isEmpty ?? true) ? nil : bound
            if var binding = source.startBinding, let mapped = idMap[binding.elementId] {
                binding.elementId = mapped
                copy.startBinding = binding
            } else {
                copy.startBinding = nil
            }
            if var binding = source.endBinding, let mapped = idMap[binding.elementId] {
                binding.elementId = mapped
                copy.endBinding = binding
            } else {
                copy.endBinding = nil
            }
            // A label copied without its container becomes free text.
            if copy.type == .text, copy.containerId == nil {
                copy.text = source.originalText.isEmpty ? source.text : source.originalText
                remeasure(&copy)
            }
            return copy
        }
    }

    /// Duplicates the elements in `ids` (with their labels) above the
    /// topmost of them. Returns the ids to select.
    static func duplicate(_ ids: Set<String>, in document: inout CanvasDocument, offset: CGVector) -> Set<String> {
        let all = withFrameChildren(ids, in: document)
        let sources = document.elements.filter { all.contains($0.id) }
        guard !sources.isEmpty else { return [] }
        let made = copies(of: sources, offset: offset)
        let insertAt = (document.elements.lastIndex { all.contains($0.id) } ?? document.elements.count - 1) + 1
        document.elements.insert(contentsOf: made, at: insertAt)
        let positions = index(document)
        return Set(made.filter { !isBoundText($0, positions: positions) }.map(\.id))
    }

    // MARK: Order

    enum Reorder {
        case forward
        case backward
        case front
        case back
    }

    /// Moves the elements in `ids` (with their labels) in the z-order.
    static func reorder(_ ids: Set<String>, _ direction: Reorder, in document: inout CanvasDocument) {
        let moving = withBoundText(ids, in: document)
        guard !moving.isEmpty else { return }
        var elements = document.elements
        switch direction {
        case .front:
            elements = elements.filter { !moving.contains($0.id) } + elements.filter { moving.contains($0.id) }
        case .back:
            elements = elements.filter { moving.contains($0.id) } + elements.filter { !moving.contains($0.id) }
        case .forward:
            var i = elements.count - 2
            while i >= 0 {
                if moving.contains(elements[i].id) {
                    // Jump over the next element that isn't moving.
                    var j = i
                    while j + 1 < elements.count, moving.contains(elements[j + 1].id) { j += 1 }
                    if j + 1 < elements.count {
                        let item = elements.remove(at: j + 1)
                        var start = i
                        while start > 0, moving.contains(elements[start - 1].id) { start -= 1 }
                        elements.insert(item, at: start)
                    }
                    i -= 1
                    while i >= 0, moving.contains(elements[i].id) { i -= 1 }
                } else {
                    i -= 1
                }
            }
        case .backward:
            var i = 1
            while i < elements.count {
                if moving.contains(elements[i].id) {
                    var j = i
                    while j + 1 < elements.count, moving.contains(elements[j + 1].id) { j += 1 }
                    var start = i
                    while start > 0, moving.contains(elements[start - 1].id) { start -= 1 }
                    if start > 0 {
                        let item = elements.remove(at: start - 1)
                        elements.insert(item, at: j)
                    }
                    i = j + 1
                } else {
                    i += 1
                }
            }
        }
        document.elements = elements
        keepLabelsAboveContainers(in: &document)
    }

    /// Puts every label right above its container, as Excalidraw expects.
    static func keepLabelsAboveContainers(in document: inout CanvasDocument) {
        let positions = index(document)
        let labels = document.elements.filter { isBoundText($0, positions: positions) }
        guard !labels.isEmpty else { return }
        let labelIDs = Set(labels.map(\.id))
        let byContainer = Dictionary(grouping: labels) { $0.containerId! }
        var result: [CanvasElement] = []
        result.reserveCapacity(document.elements.count)
        for element in document.elements where !labelIDs.contains(element.id) {
            result.append(element)
            result.append(contentsOf: byContainer[element.id] ?? [])
        }
        document.elements = result
    }

    // MARK: Groups

    static func group(_ ids: Set<String>, in document: inout CanvasDocument) {
        guard ids.count > 1 else { return }
        let group = CanvasRandom.id()
        let members = withBoundText(ids, in: document)
        for i in document.elements.indices where members.contains(document.elements[i].id) {
            var element = document.elements[i]
            element.groupIds.append(group)
            touch(&element)
            document.elements[i] = element
        }
    }

    static func ungroup(_ ids: Set<String>, in document: inout CanvasDocument) {
        let members = withBoundText(ids, in: document)
        let groups = Set(document.elements.filter { members.contains($0.id) }.compactMap(\.groupIds.last))
        guard !groups.isEmpty else { return }
        for i in document.elements.indices where members.contains(document.elements[i].id) {
            var element = document.elements[i]
            if let last = element.groupIds.last, groups.contains(last) {
                element.groupIds.removeLast()
                touch(&element)
                document.elements[i] = element
            }
        }
    }

    // MARK: Binding

    /// Attaches one end of a line to `target`, or detaches it when nil.
    static func bind(
        _ arrowID: String,
        end: CanvasShapeBuilder.ArrowEnd,
        to targetID: String?,
        focus: Double = 0,
        in document: inout CanvasDocument
    ) {
        guard let a = document.elements.firstIndex(where: { $0.id == arrowID }) else { return }
        var arrow = document.elements[a]
        let previous = end == .start ? arrow.startBinding?.elementId : arrow.endBinding?.elementId
        if previous == targetID {
            // Same shape: only the aim may change.
            guard targetID != nil else { return }
            if end == .start { arrow.startBinding?.focus = focus } else { arrow.endBinding?.focus = focus }
            if arrow != document.elements[a] {
                touch(&arrow)
                document.elements[a] = arrow
            }
            return
        }

        let binding = targetID.map { CanvasBinding(elementId: $0, focus: focus, gap: CanvasBinder.defaultGap) }
        if end == .start { arrow.startBinding = binding } else { arrow.endBinding = binding }
        touch(&arrow)
        document.elements[a] = arrow

        let stillBound = Set([arrow.startBinding?.elementId, arrow.endBinding?.elementId].compactMap { $0 })
        if let previous, !stillBound.contains(previous) {
            update(previous, in: &document) { $0.removeBoundElement(id: arrowID) }
        }
        if let targetID {
            update(targetID, in: &document) { $0.addBoundElement(id: arrowID, type: arrow.type.rawValue) }
        }
    }

    /// Drops bindings of moved lines whose shapes didn't move with them.
    static func unbindMovedLines(_ moved: Set<String>, in document: inout CanvasDocument) {
        for element in document.elements where moved.contains(element.id) && element.type.isLinear {
            if let target = element.startBinding?.elementId, !moved.contains(target) {
                bind(element.id, end: .start, to: nil, in: &document)
            }
            if let target = element.endBinding?.elementId, !moved.contains(target) {
                bind(element.id, end: .end, to: nil, in: &document)
            }
        }
    }
}
