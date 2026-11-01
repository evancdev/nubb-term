import CoreGraphics
import Foundation

/// One problem lint found.
struct CanvasLintIssue: Equatable {
    enum Kind: String, CaseIterable {
        /// Text wider or taller than the shape or frame it's in.
        case overflow
        /// Text over other text.
        case overlap
        /// An arrow or line end near no shape.
        case looseArrow = "loose-arrow"
        /// An element outside every frame, in a drawing with frames.
        case outsideFrames = "outside-frames"
        /// Text too small to read when its frame fits the screen.
        case smallText = "small-text"
        /// Text whose stored size doesn't match its text, which Excalidraw
        /// shows differently.
        case staleSize = "stale-size"
        /// Ids that point at elements that aren't there.
        case brokenReference = "broken-ref"
    }

    var kind: Kind
    var id: String
    var message: String
    /// How far off, in scene pixels, when that applies.
    var amount: Double?
    /// The frame the element is in, by name.
    var frame: String?
}

/// Checks a drawing for the mistakes that make explainers hard to read,
/// using the same font metrics and wrapping as layout and the renderer, so
/// a clean lint means the drawing looks right in the viewer and in
/// Excalidraw.
enum CanvasLint {
    struct Options {
        /// Overlaps and overflows smaller than this are ignored.
        var tolerance = 1.0
        /// How far from a shape an arrow end may be and still touch it.
        var arrowSlack = 12.0
        /// The screen the frame fits, for `small-text`.
        var screen = CGSize(width: 1440, height: 900)
        /// The smallest text, in screen points at fit-to-frame zoom.
        var minReadable = 9.0
        /// Only check these kinds. Empty checks all.
        var kinds: Set<CanvasLintIssue.Kind> = []
        /// Only report on these elements and what's inside them. Nil
        /// checks everything.
        var only: Set<String>?
    }

    static func run(_ document: CanvasDocument, options: Options = Options()) -> [CanvasLintIssue] {
        let index = Index(document)
        var issues: [CanvasLintIssue] = []
        func wants(_ kind: CanvasLintIssue.Kind) -> Bool { options.kinds.isEmpty || options.kinds.contains(kind) }

        if wants(.brokenReference) { brokenReferences(index, into: &issues) }
        if wants(.staleSize) { staleSizes(index, into: &issues, options: options) }
        if wants(.overflow) { overflows(index, into: &issues, options: options) }
        if wants(.overlap) { overlaps(index, into: &issues, options: options) }
        if wants(.looseArrow) { looseArrows(index, into: &issues, options: options) }
        if wants(.outsideFrames) { outsideFrames(index, into: &issues) }
        if wants(.smallText) { smallText(index, into: &issues, options: options) }

        if let only = options.only {
            let ids = CanvasOps.withFrameChildren(CanvasOps.withBoundText(only, in: document), in: document)
            issues = issues.filter { ids.contains($0.id) }
        }
        for i in issues.indices where issues[i].frame == nil {
            issues[i].frame = index.frameName(of: issues[i].id)
        }
        return issues.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    /// Elements by id, frames, and labels, built once.
    struct Index {
        let document: CanvasDocument
        let byID: [String: CanvasElement]
        let frames: [CanvasElement]
        let membership: CanvasRenderer.FrameMembership

        init(_ document: CanvasDocument) {
            self.document = document
            var byID: [String: CanvasElement] = [:]
            for element in document.elements { byID[element.id] = element }
            self.byID = byID
            frames = document.elements.filter { $0.type == .frame }
            membership = CanvasRenderer.FrameMembership(document)
        }

        func frame(of id: String) -> CanvasElement? {
            byID[id].flatMap { membership.frame(of: $0) }
        }

        func frameName(of id: String) -> String? {
            if let element = byID[id], element.type == .frame { return CanvasRenderer.frameTitle(element) }
            return frame(of: id).map(CanvasRenderer.frameTitle)
        }

        func isLabel(_ element: CanvasElement) -> Bool {
            element.type == .text && element.containerId.map { byID[$0] != nil } == true
        }
    }

    private static func px(_ value: Double) -> String {
        CanvasJSON.format((value * 10).rounded() / 10)
    }

    // MARK: Broken references

    private static func brokenReferences(_ index: Index, into issues: inout [CanvasLintIssue]) {
        for element in index.document.elements {
            var missing: [String] = []
            if let container = element.containerId, index.byID[container] == nil { missing.append("containerId \"\(container)\"") }
            if let frame = element.frameId {
                if let target = index.byID[frame] {
                    if target.type != .frame { missing.append("frameId \"\(frame)\" (not a frame)") }
                } else {
                    missing.append("frameId \"\(frame)\"")
                }
            }
            if let binding = element.startBinding, index.byID[binding.elementId] == nil { missing.append("startBinding \"\(binding.elementId)\"") }
            if let binding = element.endBinding, index.byID[binding.elementId] == nil { missing.append("endBinding \"\(binding.elementId)\"") }
            for bound in element.boundElements ?? [] {
                guard let target = index.byID[bound.id] else {
                    missing.append("boundElements \"\(bound.id)\"")
                    continue
                }
                let pointsBack = target.containerId == element.id
                    || target.startBinding?.elementId == element.id || target.endBinding?.elementId == element.id
                if !pointsBack { missing.append("boundElements \"\(bound.id)\" (it isn't attached here)") }
            }
            if element.type == .text, let container = element.containerId, let target = index.byID[container],
               target.boundElements?.contains(where: { $0.id == element.id }) != true {
                missing.append("containerId \"\(container)\" (the container doesn't list this label)")
            }
            guard !missing.isEmpty else { continue }
            issues.append(CanvasLintIssue(
                kind: .brokenReference, id: element.id,
                message: "\(element.id) refers to what isn't there: \(missing.joined(separator: ", ")); Excalidraw drops these when it opens the file"))
        }
    }

    // MARK: Stale sizes

    /// Text whose width or height doesn't match its text and font. The
    /// viewer and Excalidraw lay text out from the stored size, so a stale
    /// size draws text cut off, or a box too big for it.
    private static func staleSizes(_ index: Index, into issues: inout [CanvasLintIssue], options: Options) {
        for element in index.document.elements where element.type == .text {
            let label = index.isLabel(element)
            var expected = element
            if let container = element.containerId.flatMap({ index.byID[$0] }) {
                CanvasOps.layoutLabel(&expected, container: container)
            } else {
                CanvasOps.remeasure(&expected)
            }
            let dw = expected.width - element.width, dh = expected.height - element.height
            let wrapChanged = label && expected.text != element.text
            let tolerance = max(options.tolerance, 0.5)
            guard abs(dh) > tolerance || (element.autoResize || label) && abs(dw) > tolerance || wrapChanged else { continue }
            var parts: [String] = []
            if abs(dw) > tolerance, element.autoResize || label { parts.append("width \(px(element.width)) should be \(px(expected.width))") }
            if abs(dh) > tolerance { parts.append("height \(px(element.height)) should be \(px(expected.height))") }
            if wrapChanged { parts.append("the label wraps differently in its container") }
            issues.append(CanvasLintIssue(
                kind: .staleSize, id: element.id,
                message: "\(element.id): stored size doesn't match its text (\(parts.joined(separator: ", "))); `nubb +canvas fix` remeasures it",
                amount: max(abs(dw), abs(dh))))
        }
    }

    // MARK: Overflow

    private static func overflows(_ index: Index, into issues: inout [CanvasLintIssue], options: Options) {
        let tolerance = options.tolerance
        for element in index.document.elements where element.type == .text {
            // The text as it draws: the stored lines, as the viewer and
            // Excalidraw show them, without wrapping again.
            let text = element
            let container = element.containerId.flatMap { index.byID[$0] }
            let inkWidth = longestLine(text)
            let inkHeight = inkHeight(text)

            if let container, container.type.isContainer {
                let maxWidth = CanvasText.maxLabelWidth(container)
                let maxHeight = CanvasText.maxLabelHeight(container)
                let over = inkWidth - maxWidth
                let overHeight = inkHeight - maxHeight
                if over > tolerance {
                    let words = CanvasText.lines(text.text).count == 1 && !text.text.contains(" ")
                    issues.append(CanvasLintIssue(
                        kind: .overflow, id: element.id,
                        message: "\(element.id): \(words ? "a word is" : "its longest line is") \(px(over)) px wider than \(container.id) can fit (\(px(inkWidth)) in \(px(maxWidth))); widen \(container.id), shorten the text, or use a smaller font",
                        amount: over))
                } else if overHeight > tolerance {
                    issues.append(CanvasLintIssue(
                        kind: .overflow, id: element.id,
                        message: "\(element.id): text is \(px(overHeight)) px taller than \(container.id) (\(px(inkHeight)) in \(px(maxHeight))); make \(container.id) taller",
                        amount: overHeight))
                }
            } else if container == nil, !text.autoResize {
                // Fixed-width text: a line longer than the width sticks out.
                let over = inkWidth - text.width
                if over > tolerance, index.membership.frame(of: element).map({ overhang(textBounds(text, inkWidth: inkWidth), outside: $0.sceneBounds) <= tolerance }) ?? true {
                    issues.append(CanvasLintIssue(
                        kind: .overflow, id: element.id,
                        message: "\(element.id): its longest line is \(px(over)) px wider than the text box (\(px(inkWidth)) in \(px(text.width))); `fix` rewraps it",
                        amount: over))
                }
            }

            // Inside a frame, or inside a shape it sits on top of.
            let bounds = textBounds(text, inkWidth: inkWidth)
            if let frame = index.membership.frame(of: element) {
                let frameBox = frame.sceneBounds
                let out = overhang(bounds, outside: frameBox)
                if out > tolerance {
                    issues.append(CanvasLintIssue(
                        kind: .overflow, id: element.id,
                        message: "\(element.id): sticks out of frame \"\(CanvasRenderer.frameTitle(frame))\" by \(px(out)) px and is cut off; make the frame bigger or the text narrower",
                        amount: out, frame: CanvasRenderer.frameTitle(frame)))
                    continue
                }
            }
            if container == nil, let host = hostShape(of: text, bounds: bounds, index: index) {
                let out = overhang(bounds, outside: host.sceneBounds)
                if out > tolerance {
                    issues.append(CanvasLintIssue(
                        kind: .overflow, id: element.id,
                        message: "\(element.id): sticks out of \(host.id) by \(px(out)) px",
                        amount: out))
                }
            }
        }
    }

    /// The widest line as drawn.
    static func longestLine(_ text: CanvasElement) -> Double {
        CanvasText.lines(text.text).map { CanvasText.width(of: $0, family: text.fontFamily, fontSize: text.fontSize) }.max() ?? 0
    }

    /// The height of the lines as drawn.
    static func inkHeight(_ text: CanvasElement) -> Double {
        Double(CanvasText.lines(text.text).count) * text.fontSize * text.lineHeight
    }

    /// Where the text's ink is: its box, grown to its longest line and to
    /// all its lines.
    static func textBounds(_ text: CanvasElement, inkWidth: Double) -> CGRect {
        var box = text.sceneBounds
        let extra = inkWidth - Double(box.width)
        if extra > 0 {
            switch text.textAlign {
            case "center": box = box.insetBy(dx: -extra / 2, dy: 0)
            case "right": box.origin.x -= extra; box.size.width += extra
            default: box.size.width += extra
            }
        }
        let taller = inkHeight(text) - Double(box.height)
        if taller > 0, text.angle == 0 { box.size.height += taller }
        return box
    }

    /// How far `box` reaches outside `outer`, at most.
    static func overhang(_ box: CGRect, outside outer: CGRect) -> Double {
        Double(max(outer.minX - box.minX, box.maxX - outer.maxX, outer.minY - box.minY, box.maxY - outer.maxY, 0))
    }

    /// The topmost filled or outlined shape below `text` that mostly holds
    /// it: free text placed on a card.
    private static func hostShape(of text: CanvasElement, bounds: CGRect, index: Index) -> CanvasElement? {
        guard let position = index.document.elements.firstIndex(where: { $0.id == text.id }) else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for element in index.document.elements[..<position].reversed() where element.type.isContainer {
            let box = element.sceneBounds
            guard box.contains(center), box.width > 0, box.height > 0 else { continue }
            let common = box.intersection(bounds)
            // Mostly inside: it's on the card, not crossing it.
            guard !common.isNull, common.width * common.height >= bounds.width * bounds.height * 0.5 else { continue }
            return element
        }
        return nil
    }

    // MARK: Overlap

    private static func overlaps(_ index: Index, into issues: inout [CanvasLintIssue], options: Options) {
        let texts = index.document.elements.filter { $0.type == .text && !$0.text.isEmpty }
        // Text as drawn, with the line height's leading taken off: ascenders
        // and descenders of neighbors may share that space.
        var boxes: [(element: CanvasElement, box: CGRect, frame: String?)] = []
        for element in texts {
            var box = textBounds(element, inkWidth: longestLine(element))
            let leading = max(0, element.fontSize * (element.lineHeight - 1)) / 2
            box = box.insetBy(dx: 0, dy: min(leading, box.height / 4))
            boxes.append((element, box, index.frame(of: element.id)?.id))
        }
        // Sweep by x so big drawings stay fast.
        let order = boxes.indices.sorted { boxes[$0].box.minX < boxes[$1].box.minX }
        var active: [Int] = []
        var reported = Set<String>()
        for i in order {
            let current = boxes[i]
            active.removeAll { boxes[$0].box.maxX <= current.box.minX }
            for j in active {
                let other = boxes[j]
                guard current.frame == other.frame else { continue }
                let common = current.box.intersection(other.box)
                guard !common.isNull, common.width > options.tolerance, common.height > options.tolerance else { continue }
                let pair = [current.element.id, other.element.id].sorted()
                guard reported.insert(pair.joined(separator: "|")).inserted else { continue }
                issues.append(CanvasLintIssue(
                    kind: .overlap, id: pair[0],
                    message: "\(pair[0]) and \(pair[1]) overlap by \(px(Double(common.width)))x\(px(Double(common.height))) px",
                    amount: Double(min(common.width, common.height))))
            }
            active.append(i)
        }
    }

    // MARK: Arrows

    private static func looseArrows(_ index: Index, into issues: inout [CanvasLintIssue], options: Options) {
        let shapes = index.document.elements.filter { $0.type.isBindable && $0.type != .frame && !index.isLabel($0) }
        for arrow in index.document.elements where arrow.type == .arrow && arrow.points.count >= 2 {
            let scene = arrow.points.map(arrow.toScene)
            var loose: [String] = []
            for (end, point, binding) in [("start", scene[0], arrow.startBinding), ("end", scene[scene.count - 1], arrow.endBinding)] {
                if let binding, let target = index.byID[binding.elementId] {
                    let gap = distance(from: point, to: target)
                    if gap > options.arrowSlack {
                        loose.append("its \(end) is bound to \(target.id) but \(px(gap)) px away from it")
                    }
                    continue
                }
                let nearest = shapes.map { (shape: $0, gap: distance(from: point, to: $0)) }.min { $0.gap < $1.gap }
                if let nearest, nearest.gap <= options.arrowSlack {
                    loose.append("its \(end) touches \(nearest.shape.id) but isn't bound, so it won't follow when \(nearest.shape.id) moves")
                } else {
                    let hint = nearest.map { "; the nearest shape is \($0.shape.id), \(px($0.gap)) px away" } ?? ""
                    loose.append("its \(end) touches no shape\(hint)")
                }
            }
            guard !loose.isEmpty else { continue }
            issues.append(CanvasLintIssue(kind: .looseArrow, id: arrow.id, message: "\(arrow.id): " + loose.joined(separator: "; ")))
        }
    }

    /// How far `point` is from the outline of `element`, 0 inside it.
    static func distance(from point: CGPoint, to element: CanvasElement) -> Double {
        let local = element.toLocal(point)
        if element.outlinePath.contains(local) { return 0 }
        let outline = element.outlinePath
        var best = Double.infinity
        var start: CGPoint?
        var previous: CGPoint?
        outline.applyWithBlock { pointer in
            let item = pointer.pointee
            switch item.type {
            case .moveToPoint:
                start = item.points[0]
                previous = item.points[0]
            case .addLineToPoint:
                if let p = previous { best = min(best, CanvasGeometry.distance(local, toSegment: p, item.points[0])) }
                previous = item.points[0]
            case .addQuadCurveToPoint:
                if let p = previous { best = min(best, CanvasGeometry.distance(local, toSegment: p, item.points[1])) }
                previous = item.points[1]
            case .addCurveToPoint:
                if let p = previous {
                    // Sample the curve.
                    let c1 = item.points[0], c2 = item.points[1], e = item.points[2]
                    var last = p
                    for step in 1...8 {
                        let t = CGFloat(step) / 8, u = 1 - t
                        let x = u * u * u * p.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x
                        let y = u * u * u * p.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y
                        let next = CGPoint(x: x, y: y)
                        best = min(best, CanvasGeometry.distance(local, toSegment: last, next))
                        last = next
                    }
                }
                previous = item.points[2]
            case .closeSubpath:
                if let p = previous, let s = start { best = min(best, CanvasGeometry.distance(local, toSegment: p, s)) }
                previous = start
            @unknown default:
                break
            }
        }
        return best
    }

    // MARK: Frames

    private static func outsideFrames(_ index: Index, into issues: inout [CanvasLintIssue]) {
        guard !index.frames.isEmpty else { return }
        for element in index.document.elements where element.type != .frame && index.membership.frame(of: element) == nil {
            if index.isLabel(element) { continue }
            // Arrows between frames are fine.
            if element.type.isLinear, element.startBinding != nil || element.endBinding != nil { continue }
            let box = element.sceneBounds
            let inside = index.frames.first { $0.sceneBounds.contains(box) }
            let hint = inside.map { "; it lies inside \"\(CanvasRenderer.frameTitle($0))\" but isn't part of it (no frameId)" } ?? ""
            issues.append(CanvasLintIssue(
                kind: .outsideFrames, id: element.id,
                message: "\(element.id) is outside every frame\(hint)"))
        }
    }

    // MARK: Small text

    /// Text that is less than `minReadable` points tall on a screen showing
    /// the whole frame (or the whole drawing, without frames).
    private static func smallText(_ index: Index, into issues: inout [CanvasLintIssue], options: Options) {
        let all = CanvasRenderer.sceneBounds(of: index.document.elements)
        for element in index.document.elements where element.type == .text && !element.text.isEmpty {
            let area = index.membership.frame(of: element)?.sceneBounds ?? (index.frames.isEmpty ? all : element.sceneBounds)
            guard !area.isNull, area.width > 0, area.height > 0 else { continue }
            let zoom = min(1, min(Double(options.screen.width) / Double(area.width + 120), Double(options.screen.height) / Double(area.height + 120)))
            let shown = element.fontSize * zoom
            guard shown < options.minReadable else { continue }
            let needed = options.minReadable / zoom
            issues.append(CanvasLintIssue(
                kind: .smallText, id: element.id,
                message: "\(element.id): \(px(element.fontSize)) px text shows at \(px(shown)) pt when its \(index.frame(of: element.id) == nil ? "drawing" : "frame") fits a \(Int(options.screen.width))x\(Int(options.screen.height)) screen; use \(px(needed.rounded(.up))) px or more, or split the frame",
                amount: needed - element.fontSize))
        }
    }

    // MARK: Fix

    /// Fixes what can be fixed without changing the design: remeasures
    /// text, rewraps labels, and drops references to missing elements.
    /// Returns the ids it changed.
    static func fix(_ document: inout CanvasDocument) -> [String] {
        let before = Dictionary(document.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        CanvasEngine.repairRelations(in: &document)
        let positions = CanvasOps.index(document)
        for i in document.elements.indices where document.elements[i].type == .text {
            var text = document.elements[i]
            if let container = text.containerId.flatMap({ positions[$0] }) {
                CanvasOps.layoutLabel(&text, container: document.elements[container])
            } else {
                CanvasOps.remeasure(&text)
            }
            document.elements[i] = text
        }
        CanvasOps.keepLabelsAboveContainers(in: &document)
        CanvasOps.keepFramesAboveMembers(in: &document)
        var changed: [String] = []
        for i in document.elements.indices {
            guard let old = before[document.elements[i].id], !CanvasDiff.sameContent(old, document.elements[i]) else { continue }
            CanvasOps.touch(&document.elements[i])
            changed.append(document.elements[i].id)
        }
        return changed.sorted()
    }
}
