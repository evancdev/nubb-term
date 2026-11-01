import CoreGraphics
import Foundation

// MARK: - Results

/// An arrow or line from a spec, routed after everything is placed so it can
/// follow shapes that moved.
struct CanvasPendingConnector {
    var id: String
    var path: String
    var isArrow: Bool
    var label: String
    var from: CanvasSpecEndpoint
    var to: CanvasSpecEndpoint
    var fromSide: CanvasSpecSide?
    var toSide: CanvasSpecSide?
    var elbow: Bool
    var style: CanvasLayout.Style
    var frameId: String?
    var groupIds: [String] = []
    var locked = false
    var link: String?
    var name: String?
}

/// Laid out elements of one node, at its own origin until the parent moves
/// them into place.
struct CanvasLayoutBlock {
    var elements: [CanvasElement] = []
    var connectors: [CanvasPendingConnector] = []
    var size: CGSize = .zero
    /// The box of every node with an id, for the report.
    var boxes: [String: CGRect] = [:]
    /// The elements and connectors each node made, its children's included.
    var nodeElements: [String: [String]] = [:]
    var issues: [CanvasSpecIssue] = []

    mutating func translate(by dx: Double, _ dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        for i in elements.indices {
            elements[i].x += dx
            elements[i].y += dy
        }
        for i in connectors.indices {
            if case .point(let p) = connectors[i].from { connectors[i].from = .point(CGPoint(x: p.x + dx, y: p.y + dy)) }
            if case .point(let p) = connectors[i].to { connectors[i].to = .point(CGPoint(x: p.x + dx, y: p.y + dy)) }
        }
        for (id, box) in boxes { boxes[id] = box.offsetBy(dx: dx, dy: dy) }
    }

    mutating func append(_ other: CanvasLayoutBlock) {
        elements.append(contentsOf: other.elements)
        connectors.append(contentsOf: other.connectors)
        boxes.merge(other.boxes) { _, new in new }
        nodeElements.merge(other.nodeElements) { _, new in new }
        issues.append(contentsOf: other.issues)
    }
}

/// Values from the drawing that layout uses instead of the spec's: text,
/// fonts, and sizes the user changed by hand, and how far they moved
/// things, so a new layout keeps them.
///
/// An edit to a value the spec gives (text, a font, a set width) lasts
/// while the spec still gives what it gave when the user made the edit.
/// When the agent changes that value too, the agent's new value wins.
struct CanvasLayoutOverrides {
    /// The user's value of each field they changed, by element id. `dx` and
    /// `dy` under a node id move the node and everything in it.
    var fields: [String: [String: CanvasJSON]] = [:]
    /// What each field was before the user changed it.
    var bases: [String: [String: CanvasJSON]] = [:]

    /// The user's value of a field, unless the spec's value (`spec`) moved
    /// on from the one they changed.
    func value(_ id: String, _ key: String, spec: CanvasJSON? = nil) -> CanvasJSON? {
        guard let value = fields[id]?[key] else { return nil }
        if let spec, let base = bases[id]?[key], !CanvasJSON.nearlyEqual(base, spec) { return nil }
        return value
    }

    func text(_ id: String, spec: String) -> String? {
        value(id, "originalText", spec: .string(spec))?.stringValue
    }

    func number(_ id: String, _ key: String, spec: Double? = nil) -> Double? {
        value(id, key, spec: spec.map(CanvasJSON.number))?.doubleValue
    }

    func shift(_ id: String) -> CGVector? {
        let dx = fields[id]?["dx"]?.doubleValue ?? 0, dy = fields[id]?["dy"]?.doubleValue ?? 0
        return dx == 0 && dy == 0 ? nil : CGVector(dx: dx, dy: dy)
    }
}

// MARK: - Layout

/// Turns spec nodes into Excalidraw elements: measures text with the real
/// fonts, wraps it to the space it has, sizes boxes and frames to their
/// contents, and arranges stacks, rows, and grids.
struct CanvasLayout {
    var overrides = CanvasLayoutOverrides()

    /// Spacing and sizes used when a spec doesn't give them.
    enum Defaults {
        static let stackGap = 16.0
        static let rowGap = 24.0
        static let gridGap = 24.0
        /// Between frames.
        static let frameGap = 48.0
        static let framePadding = CanvasSpecInsets(28)
        static let cardPadding = CanvasSpecInsets(16)
        static let cardGap = 12.0
        static let boxPadding = CanvasSpecInsets(vertical: 14, horizontal: 20)
        static let codePadding = CanvasSpecInsets(vertical: 12, horizontal: 16)
        static let emptyBox = CGSize(width: 160, height: 80)
        static let minBoxWidth = 40.0
        /// Text with no width from its node or parent wraps at this many
        /// times its font size: about 65 characters, a comfortable line.
        static let measure = 32.0
    }

    /// A node's style with every field filled in.
    struct Style: Equatable {
        var strokeColor = CanvasStyle.defaultStrokeColor
        var backgroundColor = CanvasColor.transparentName
        var fillStyle = "solid"
        var strokeWidth = 2.0
        var strokeStyle = "solid"
        var roughness = 1.0
        var opacity = 100.0
        var round = true
        var fontFamily = CanvasFont.Family.handDrawn.rawValue
        var fontSize = 20.0
        var textAlign = "left"
        var verticalAlign = "middle"
        var startArrowhead: String?
        var endArrowhead: String? = "arrow"

        init() {}

        init(_ spec: CanvasSpecStyle, kind: CanvasSpecNode.Kind) {
            switch kind {
            case .box, .ellipse, .diamond:
                textAlign = "center"
            case .code:
                fontFamily = CanvasFont.Family.cascadia.rawValue
                fontSize = 16
                backgroundColor = "#f8f9fa"
                strokeWidth = 1
                roughness = 0
            case .arrow, .line:
                fontSize = 16
                textAlign = "center"
                if kind == .line { endArrowhead = nil }
            default:
                break
            }
            if let value = spec.strokeColor { strokeColor = value }
            if let value = spec.backgroundColor { backgroundColor = value }
            if let value = spec.fillStyle { fillStyle = value }
            if let value = spec.strokeWidth { strokeWidth = value }
            if let value = spec.strokeStyle { strokeStyle = value }
            if let value = spec.roughness { roughness = value }
            if let value = spec.opacity { opacity = value }
            if let value = spec.round { round = value }
            if let value = spec.fontFamily { fontFamily = value }
            if let value = spec.fontSize { fontSize = value }
            if let value = spec.textAlign { textAlign = value }
            if let value = spec.verticalAlign { verticalAlign = value }
            if let value = spec.startArrowhead { startArrowhead = value == "none" ? nil : value }
            if let value = spec.endArrowhead { endArrowhead = value == "none" ? nil : value }
        }
    }

    private struct Constraint {
        /// The most width the node may use, if limited.
        var available: Double?
        /// The width the node must have, e.g. when stretched.
        var width: Double?
        /// The height the node must have, e.g. when stretched.
        var height: Double?
    }

    private struct Context {
        var frameId: String?
    }

    init(overrides: CanvasLayoutOverrides) {
        self.overrides = overrides
    }

    init() {}

    /// Lays out a top-level node with its top-left corner at `origin`.
    func layout(_ node: CanvasSpecNode, id: String, origin: CGPoint) -> CanvasLayoutBlock {
        var block = build(node, id: id, context: Context(), constraint: Constraint())
        block.translate(by: Double(origin.x), Double(origin.y))
        Self.round(&block)
        return block
    }

    /// The id of a node's child without its own id.
    static func childID(_ parent: String, _ index: Int) -> String { "\(parent).\(index)" }

    /// The id of an element a node makes besides its main one.
    static func partID(_ id: String, _ part: String) -> String { "\(id):\(part)" }

    // MARK: Nodes

    private func build(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var constraint = constraint
        if case .fixed(let width)? = node.width, !node.kind.isConnector {
            constraint.width = width
            constraint.available = width
        }
        if let maxWidth = node.maxWidth {
            constraint.available = min(constraint.available ?? .infinity, maxWidth)
        }

        var block: CanvasLayoutBlock
        switch node.kind {
        case .text: block = text(node, id: id, context: context, constraint: constraint)
        case .box, .ellipse, .diamond:
            block = node.children.isEmpty
                ? shape(node, id: id, context: context, constraint: constraint)
                : card(node, id: id, context: context, constraint: constraint)
        case .code: block = code(node, id: id, context: context, constraint: constraint)
        case .frame: block = frame(node, id: id, context: context, constraint: constraint)
        case .stack, .row, .grid:
            // Padding around a layout: less room inside, more size outside.
            let padding = node.padding ?? CanvasSpecInsets(0)
            var inner = constraint
            inner.available = constraint.available.map { max($0 - padding.horizontal, 0) }
            inner.width = constraint.width.map { max($0 - padding.horizontal, 0) }
            inner.height = constraint.height.map { max($0 - padding.vertical, 0) }
            switch node.kind {
            case .stack:
                block = stack(node.children, id: id, context: context, constraint: inner,
                              gap: node.gap, align: node.align ?? .start)
            case .row: block = row(node, id: id, context: context, constraint: inner)
            default: block = grid(node, id: id, context: context, constraint: inner)
            }
            if padding != CanvasSpecInsets(0) {
                block.translate(by: padding.left, padding.top)
                block.size = CGSize(width: Double(block.size.width) + padding.horizontal,
                                    height: Double(block.size.height) + padding.vertical)
            }
        case .arrow, .line: block = connector(node, id: id, context: context)
        case .raw: block = raw(node, id: id, context: context)
        }

        if node.group ?? (node.isCard || node.kind == .code), block.elements.count > 1 {
            let group = Self.partID(id, "group")
            for i in block.elements.indices { block.elements[i].groupIds.append(group) }
            for i in block.connectors.indices { block.connectors[i].groupIds.append(group) }
        }
        if node.locked || node.link != nil {
            for i in block.elements.indices {
                if node.locked { block.elements[i].locked = true }
                if let link = node.link, block.elements[i].containerId == nil { block.elements[i].link = link }
            }
        }
        // The hover name goes on the node's own element: the box, the
        // text, or the panel behind code, not on what's inside a card.
        if let name = node.name, let i = block.elements.firstIndex(where: { $0.id == id }) {
            block.elements[i].hoverName = name
        }
        if !node.kind.isConnector, node.kind != .raw || node.id != nil {
            block.boxes[id] = CGRect(origin: .zero, size: block.size)
        }
        block.nodeElements[id] = block.elements.map(\.id) + block.connectors.map(\.id)
        // Moves after layout: the spec's own, then the user's. The node keeps
        // its place in the flow.
        var dx = 0.0, dy = 0.0
        if let shift = node.shift {
            dx += Double(shift.dx)
            dy += Double(shift.dy)
        }
        if let shift = overrides.shift(id) {
            dx += Double(shift.dx)
            dy += Double(shift.dy)
        }
        if dx != 0 || dy != 0 {
            let size = block.size
            block.translate(by: dx, dy)
            block.size = size
        }
        return block
    }

    // MARK: Text

    private func text(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let style = Style(node.style, kind: .text)
        let source = overrides.text(id, spec: node.content) ?? node.content
        if source.isEmpty {
            block.issues.append(CanvasSpecIssue(path: node.path, message: "empty text is skipped"))
            return block
        }
        var element = makeElement(id, .text, style: style, context: context)
        applyFont(&element, style: style, id: id)
        element.textAlign = overrides.value(id, "textAlign", spec: .string(style.textAlign))?.stringValue ?? style.textAlign
        element.verticalAlign = "top"

        let natural = CanvasText.measure(source, family: element.fontFamily, fontSize: element.fontSize, lineHeight: element.lineHeight)
        let userWidth = overrides.number(id, "width", spec: node.width.flatMap(\.fixedValue))
        let fixed = userWidth ?? constraint.width
        let limit = constraint.available ?? (node.maxWidth ?? Defaults.measure * element.fontSize)
        element.originalText = source
        if let fixed, userWidth != nil || node.wrap != false {
            // A set width: wrap to it, like a text box resized by hand.
            element.width = fixed
            element.autoResize = false
            element.text = CanvasText.wrap(source, family: element.fontFamily, fontSize: element.fontSize, maxWidth: fixed)
        } else if Double(natural.width) > limit, limit.isFinite, node.wrap != false {
            element.width = limit
            element.autoResize = false
            element.text = CanvasText.wrap(source, family: element.fontFamily, fontSize: element.fontSize, maxWidth: limit)
        } else {
            element.text = source
            element.width = Double(natural.width)
            element.autoResize = true
        }
        element.height = Double(CanvasText.measure(element.text, family: element.fontFamily, fontSize: element.fontSize,
                                                   lineHeight: element.lineHeight).height)
        block.elements = [element]
        block.size = CGSize(width: element.width, height: element.height)
        return block
    }

    private func applyFont(_ element: inout CanvasElement, style: Style, id: String) {
        element.fontFamily = overrides.value(id, "fontFamily", spec: .number(Double(style.fontFamily)))?.intValue ?? style.fontFamily
        element.fontSize = overrides.number(id, "fontSize", spec: style.fontSize) ?? style.fontSize
        element.lineHeight = overrides.number(id, "lineHeight", spec: CanvasText.defaultLineHeight(family: element.fontFamily))
            ?? CanvasText.defaultLineHeight(family: element.fontFamily)
    }

    // MARK: Shapes

    private static func elementType(_ kind: CanvasSpecNode.Kind) -> CanvasElementType {
        switch kind {
        case .ellipse: .ellipse
        case .diamond: .diamond
        default: .rectangle
        }
    }

    /// How much bigger than its label a shape must be: the label area of an
    /// ellipse or diamond is a smaller box inside it.
    private static func labelFactor(_ kind: CanvasSpecNode.Kind) -> Double {
        switch kind {
        case .ellipse: 2.0.squareRoot()
        case .diamond: 2
        default: 1
        }
    }

    private func shape(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let style = Style(node.style, kind: node.kind)
        let padding = node.padding ?? Defaults.boxPadding
        let factor = Self.labelFactor(node.kind)
        var container = makeElement(id, Self.elementType(node.kind), style: style, context: context)
        applyShapeStyle(&container, style: style)

        let labelID = Self.partID(id, "label")
        let source = overrides.text(labelID, spec: node.content) ?? node.content
        var label: CanvasElement?
        var natural = CGSize.zero
        if !source.isEmpty {
            var text = makeElement(labelID, .text, style: style, context: context)
            applyFont(&text, style: style, id: labelID)
            text.textAlign = overrides.value(labelID, "textAlign", spec: .string(style.textAlign))?.stringValue ?? style.textAlign
            text.verticalAlign = overrides.value(labelID, "verticalAlign", spec: .string(style.verticalAlign))?.stringValue
                ?? style.verticalAlign
            text.originalText = source
            text.text = source
            text.containerId = id
            text.backgroundColor = CanvasColor.transparentName
            natural = CanvasText.measure(source, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight)
            label = text
        }

        // Width: set, stretched, or the label's width plus padding, but no
        // more than the space there is (the label wraps then).
        let width: Double
        if let fixed = overrides.number(id, "width", spec: node.width.flatMap(\.fixedValue)) ?? constraint.width {
            width = fixed
        } else if label != nil {
            let wanted = (Double(natural.width) + padding.horizontal) * factor
            let limit = constraint.available ?? .infinity
            width = max(min(wanted, limit), node.minWidth ?? 0, Defaults.minBoxWidth)
        } else {
            width = max(node.minWidth ?? Defaults.emptyBox.width, constraint.available.map { min($0, Defaults.emptyBox.width) } ?? Defaults.emptyBox.width)
        }
        container.width = width

        var labelHeight = 0.0
        if var text = label {
            let maxWidth = CanvasText.maxLabelWidth(container)
            text.text = CanvasText.wrap(source, family: text.fontFamily, fontSize: text.fontSize, maxWidth: maxWidth)
            labelHeight = Double(CanvasText.measure(text.text, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight).height)
            label = text
        }
        let height: Double
        if let fixed = overrides.number(id, "height", spec: node.height) ?? node.height ?? constraint.height {
            height = fixed
        } else if label != nil {
            height = max((labelHeight + padding.vertical) * factor, node.minHeight ?? 0)
        } else {
            height = node.minHeight ?? Defaults.emptyBox.height
        }
        container.height = height

        if var text = label {
            container.addBoundElement(id: labelID, type: "text")
            CanvasOps.layoutLabel(&text, container: container)
            block.elements = [container, text]
        } else {
            block.elements = [container]
        }
        block.size = CGSize(width: width, height: height)
        return block
    }

    private func applyShapeStyle(_ element: inout CanvasElement, style: Style) {
        element.backgroundColor = style.backgroundColor
        element.fillStyle = style.fillStyle
        element.strokeWidth = style.strokeWidth
        element.strokeStyle = style.strokeStyle
        element.roughness = style.roughness
        switch element.type {
        case .rectangle: element.roundness = style.round ? .adaptive : nil
        case .diamond: element.roundness = style.round ? .proportional : nil
        default: element.roundness = nil
        }
    }

    /// A shape with nodes inside it, arranged in a stack.
    private func card(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        let style = Style(node.style, kind: node.kind)
        var container = makeElement(id, Self.elementType(node.kind), style: style, context: context)
        applyShapeStyle(&container, style: style)
        let padding = node.padding ?? Defaults.cardPadding
        let fixedWidth = overrides.number(id, "width", spec: node.width.flatMap(\.fixedValue)) ?? constraint.width
        let fixedHeight = overrides.number(id, "height", spec: node.height) ?? node.height ?? constraint.height

        var inner = Constraint()
        if let fixedWidth {
            inner.width = max(fixedWidth - padding.horizontal, 0)
            inner.available = inner.width
        } else if let available = constraint.available {
            inner.available = max(available - padding.horizontal, 0)
        }
        var content = stack(node.children, id: id, context: context, constraint: inner,
                            gap: node.gap ?? Defaults.cardGap, align: node.align ?? .start)
        content.translate(by: padding.left, padding.top)

        container.width = fixedWidth ?? max(Double(content.size.width) + padding.horizontal, node.minWidth ?? 0)
        container.height = fixedHeight ?? max(Double(content.size.height) + padding.vertical, node.minHeight ?? 0)

        var block = CanvasLayoutBlock()
        block.elements = [container]
        block.append(content)
        block.size = CGSize(width: container.width, height: container.height)
        return block
    }

    // MARK: Code

    private func code(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let style = Style(node.style, kind: .code)
        let padding = node.padding ?? Defaults.codePadding
        var background = makeElement(id, .rectangle, style: style, context: context)
        applyShapeStyle(&background, style: style)
        background.strokeColor = "#ced4da"

        let textID = Self.partID(id, "code")
        var text = makeElement(textID, .text, style: style, context: context)
        text.backgroundColor = CanvasColor.transparentName
        applyFont(&text, style: style, id: textID)
        text.textAlign = "left"
        text.verticalAlign = "top"
        let source = overrides.text(textID, spec: node.content) ?? node.content
        text.originalText = source

        let fixedWidth = overrides.number(id, "width", spec: node.width.flatMap(\.fixedValue)) ?? constraint.width
        let wrapWidth: Double? = node.wrap == true ? (fixedWidth ?? constraint.available).map { $0 - padding.horizontal } : nil
        if let wrapWidth, wrapWidth > 0 {
            text.text = CanvasText.wrap(source, family: text.fontFamily, fontSize: text.fontSize, maxWidth: wrapWidth)
            text.width = wrapWidth
            text.autoResize = false
        } else {
            text.text = source
            text.width = Double(CanvasText.measure(source, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight).width)
            text.autoResize = true
        }
        text.height = Double(CanvasText.measure(text.text, family: text.fontFamily, fontSize: text.fontSize, lineHeight: text.lineHeight).height)
        text.x = padding.left
        text.y = padding.top

        background.width = fixedWidth ?? text.width + padding.horizontal
        background.height = overrides.number(id, "height") ?? constraint.height ?? (text.height + padding.vertical)
        block.elements = [background, text]
        block.size = CGSize(width: background.width, height: background.height)
        return block
    }

    // MARK: Frames

    private func frame(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        let style = Style(node.style, kind: .frame)
        let padding = node.padding ?? Defaults.framePadding
        let inside = Context(frameId: id)
        let fixedWidth = overrides.number(id, "width", spec: node.width.flatMap(\.fixedValue)) ?? constraint.width
        let fixedHeight = overrides.number(id, "height", spec: node.height) ?? node.height ?? constraint.height

        var inner = Constraint()
        if let fixedWidth {
            inner.width = max(fixedWidth - padding.horizontal, 0)
            inner.available = inner.width
        } else if let available = constraint.available {
            inner.available = max(available - padding.horizontal, 0)
        }
        var content = stack(node.children, id: id, context: inside, constraint: inner,
                            gap: node.gap, align: node.align ?? .start)
        content.translate(by: padding.left, padding.top)

        var frame = CanvasElement(id: id, type: .frame)
        frame.seed = CanvasRandom.stableSeed(id)
        frame.strokeColor = "#bbb"
        frame.roughness = 0
        frame.roundness = nil
        let name = node.content.isEmpty ? nil : node.content
        frame.frameName = overrides.value(id, "name", spec: name.map(CanvasJSON.string) ?? .null)?.stringValue ?? name
        frame.width = fixedWidth ?? max(Double(content.size.width) + padding.horizontal, node.minWidth ?? 0)
        frame.height = fixedHeight ?? max(Double(content.size.height) + padding.vertical, node.minHeight ?? 0)

        var block = CanvasLayoutBlock()
        if !CanvasColor.isTransparent(style.backgroundColor) {
            // Frames have no fill of their own: a locked shape behind the
            // contents gives the panel its color.
            var background = makeElement(Self.partID(id, "bg"), .rectangle, style: style, context: inside)
            applyShapeStyle(&background, style: style)
            background.strokeColor = CanvasColor.transparentName
            background.roughness = 0
            background.width = frame.width
            background.height = frame.height
            background.locked = true
            block.elements.append(background)
        }
        block.append(content)
        // Excalidraw keeps a frame above its elements.
        block.elements.append(frame)
        block.size = CGSize(width: frame.width, height: frame.height)
        return block
    }

    // MARK: Layout containers

    private static func isStretchable(_ node: CanvasSpecNode) -> Bool {
        !node.kind.isConnector && node.kind != .raw
    }

    private static func hasFrames(_ children: [CanvasSpecNode]) -> Bool {
        children.contains { $0.kind == .frame }
    }

    private func childID(_ child: CanvasSpecNode, parent: String, index: Int) -> String {
        child.id ?? Self.childID(parent, index)
    }

    /// Children placed with `at`, relative to the parent's corner, or
    /// connectors, which have no place in the flow.
    private static func isOutOfFlow(_ node: CanvasSpecNode) -> Bool {
        node.at != nil || node.kind.isConnector
    }

    private func outOfFlow(_ child: CanvasSpecNode, id: String, context: Context) -> CanvasLayoutBlock {
        var block = build(child, id: id, context: context, constraint: Constraint())
        if let at = child.at { block.translate(by: Double(at.x), Double(at.y)) }
        return block
    }

    private func stack(
        _ children: [CanvasSpecNode], id: String, context: Context,
        constraint: Constraint, gap: Double?, align: CanvasSpecAlign
    ) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let gap = gap ?? (Self.hasFrames(children) ? Defaults.frameGap : Defaults.stackGap)
        let space = constraint.width ?? constraint.available
        var built: [(block: CanvasLayoutBlock, index: Int)] = []
        var extent = CGSize.zero

        for (index, child) in children.enumerated() {
            let childID = childID(child, parent: id, index: index)
            if Self.isOutOfFlow(child) {
                let placed = outOfFlow(child, id: childID, context: context)
                extent.width = max(extent.width, placed.boxes[childID]?.maxX ?? 0)
                extent.height = max(extent.height, placed.boxes[childID]?.maxY ?? 0)
                block.append(placed)
                continue
            }
            var inner = Constraint(available: space)
            if Self.isStretchable(child), let space, align == .stretch || child.width == .fill {
                inner.width = space
            }
            built.append((build(child, id: childID, context: context, constraint: inner), index))
        }

        let widest = built.map { Double($0.block.size.width) }.max() ?? 0
        let alignWidth = constraint.width ?? (align == .start ? widest : max(space ?? widest, widest))
        var y = 0.0
        for (offset, item) in built.enumerated() {
            var child = item.block
            let width = Double(child.size.width)
            let x: Double
            switch align {
            case .center: x = (alignWidth - width) / 2
            case .end: x = alignWidth - width
            case .start, .stretch: x = 0
            }
            child.translate(by: x, y)
            y += Double(child.size.height)
            if offset < built.count - 1 { y += gap }
            block.append(child)
        }
        let flowWidth = built.isEmpty ? 0 : (align == .start ? widest : alignWidth)
        block.size = CGSize(width: max(constraint.width ?? flowWidth, extent.width), height: max(y, extent.height))
        return block
    }

    private func row(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let children = node.children
        let gap = node.gap ?? (Self.hasFrames(children) ? Defaults.frameGap : Defaults.rowGap)
        let align = node.align ?? .start
        let space = constraint.width ?? constraint.available
        var flow: [(child: CanvasSpecNode, id: String)] = []
        var extent = CGSize.zero

        for (index, child) in children.enumerated() {
            let childID = childID(child, parent: id, index: index)
            if Self.isOutOfFlow(child) {
                let placed = outOfFlow(child, id: childID, context: context)
                extent.width = max(extent.width, placed.boxes[childID]?.maxX ?? 0)
                extent.height = max(extent.height, placed.boxes[childID]?.maxY ?? 0)
                block.append(placed)
            } else {
                flow.append((child, childID))
            }
        }

        // Children that fill share what the others leave. Text and code
        // fill by default so paragraphs side by side wrap.
        func fills(_ child: CanvasSpecNode) -> Bool {
            if child.width == .fill { return true }
            return child.width == nil && (child.kind == .text || child.kind == .code)
        }
        var widths: [Double?] = Array(repeating: nil, count: flow.count)
        var built: [CanvasLayoutBlock?] = Array(repeating: nil, count: flow.count)
        if let space {
            var used = gap * Double(max(flow.count - 1, 0))
            var fillCount = 0
            for (i, item) in flow.enumerated() {
                if fills(item.child) {
                    fillCount += 1
                } else {
                    let child = build(item.child, id: item.id, context: context, constraint: Constraint())
                    used += Double(child.size.width)
                    built[i] = child
                }
            }
            if fillCount > 0 {
                let share = max((space - used) / Double(fillCount), Defaults.minBoxWidth)
                for (i, item) in flow.enumerated() where fills(item.child) { widths[i] = share }
            }
        }
        for (i, item) in flow.enumerated() where built[i] == nil {
            var inner = Constraint()
            if let width = widths[i] {
                inner.available = width
                if Self.isStretchable(item.child) { inner.width = width }
            }
            built[i] = build(item.child, id: item.id, context: context, constraint: inner)
        }

        var height = constraint.height ?? built.compactMap { $0.map { Double($0.size.height) } }.max() ?? 0
        if constraint.height == nil, align == .stretch {
            height = built.compactMap { $0.map { Double($0.size.height) } }.max() ?? 0
        }
        if align == .stretch {
            for (i, item) in flow.enumerated() where Self.isStretchable(item.child) {
                guard let child = built[i], Double(child.size.height) != height else { continue }
                built[i] = build(item.child, id: item.id, context: context,
                                 constraint: Constraint(available: widths[i] ?? Double(child.size.width),
                                                        width: Double(child.size.width), height: height))
            }
        }

        var x = 0.0
        for i in flow.indices {
            guard var child = built[i] else { continue }
            let childHeight = Double(child.size.height)
            let y: Double
            switch align {
            case .center: y = (height - childHeight) / 2
            case .end: y = height - childHeight
            case .start, .stretch: y = 0
            }
            child.translate(by: x, y)
            x += Double(child.size.width)
            if i < flow.count - 1 { x += gap }
            block.append(child)
        }
        block.size = CGSize(width: max(constraint.width ?? x, extent.width), height: max(height, extent.height))
        return block
    }

    private func grid(_ node: CanvasSpecNode, id: String, context: Context, constraint: Constraint) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        let columns = max(node.columns ?? 1, 1)
        let gap = node.gap ?? (Self.hasFrames(node.children) ? Defaults.frameGap : Defaults.gridGap)
        let rowGap = node.rowGap ?? gap
        let align = node.align ?? .stretch
        let space = constraint.width ?? constraint.available
        var flow: [(child: CanvasSpecNode, id: String)] = []
        var extent = CGSize.zero

        for (index, child) in node.children.enumerated() {
            let childID = childID(child, parent: id, index: index)
            if Self.isOutOfFlow(child) {
                let placed = outOfFlow(child, id: childID, context: context)
                extent.width = max(extent.width, placed.boxes[childID]?.maxX ?? 0)
                extent.height = max(extent.height, placed.boxes[childID]?.maxY ?? 0)
                block.append(placed)
            } else {
                flow.append((child, childID))
            }
        }

        var columnWidth = node.columnWidth ?? space.map { max(($0 - gap * Double(columns - 1)) / Double(columns), Defaults.minBoxWidth) }
        var built = flow.map { item in
            build(item.child, id: item.id, context: context, constraint: Constraint(
                available: columnWidth,
                width: columnWidth != nil && align == .stretch && Self.isStretchable(item.child) ? columnWidth : nil))
        }
        if columnWidth == nil {
            // Every column as wide as the widest cell.
            let widest = built.map { Double($0.size.width) }.max() ?? 0
            columnWidth = widest
            if align == .stretch {
                for (i, item) in flow.enumerated() where Self.isStretchable(item.child) && Double(built[i].size.width) != widest {
                    built[i] = build(item.child, id: item.id, context: context,
                                     constraint: Constraint(available: widest, width: widest))
                }
            }
        }
        let cellWidth = columnWidth ?? 0

        var y = 0.0
        var start = 0
        while start < flow.count {
            let end = min(start + columns, flow.count)
            let rowHeight = built[start..<end].map { Double($0.size.height) }.max() ?? 0
            for i in start..<end {
                if align == .stretch, Self.isStretchable(flow[i].child), Double(built[i].size.height) != rowHeight {
                    built[i] = build(flow[i].child, id: flow[i].id, context: context,
                                     constraint: Constraint(available: cellWidth, width: Double(built[i].size.width), height: rowHeight))
                }
                var child = built[i]
                let column = Double(i - start)
                var x = column * (cellWidth + gap)
                var dy = 0.0
                switch align {
                case .center:
                    x += (cellWidth - Double(child.size.width)) / 2
                    dy = (rowHeight - Double(child.size.height)) / 2
                case .end:
                    x += cellWidth - Double(child.size.width)
                    dy = rowHeight - Double(child.size.height)
                case .start, .stretch:
                    break
                }
                child.translate(by: x, y + dy)
                block.append(child)
            }
            y += rowHeight
            start = end
            if start < flow.count { y += rowGap }
        }
        let usedColumns = Double(min(columns, max(flow.count, 1)))
        let width = flow.isEmpty ? 0 : usedColumns * cellWidth + gap * (usedColumns - 1)
        block.size = CGSize(width: max(constraint.width ?? width, extent.width), height: max(y, extent.height))
        return block
    }

    // MARK: Connectors and raw elements

    private func connector(_ node: CanvasSpecNode, id: String, context: Context) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        guard let from = node.from, let to = node.to else { return block }
        block.connectors = [CanvasPendingConnector(
            id: id, path: node.path, isArrow: node.kind == .arrow, label: node.content,
            from: from, to: to, fromSide: node.fromSide, toSide: node.toSide, elbow: node.elbow,
            style: Style(node.style, kind: node.kind), frameId: context.frameId,
            locked: node.locked, link: node.link, name: node.name)]
        if let at = node.at { block.translate(by: Double(at.x), Double(at.y)) }
        return block
    }

    private func raw(_ node: CanvasSpecNode, id: String, context: Context) -> CanvasLayoutBlock {
        var block = CanvasLayoutBlock()
        guard let json = node.raw, var element = CanvasElement(json: json, fallbackID: id) else {
            block.issues.append(CanvasSpecIssue(path: node.path, message: "not a valid Excalidraw element"))
            return block
        }
        if json["seed"] == nil { element.seed = CanvasRandom.stableSeed(element.id) }
        if element.frameId == nil { element.frameId = context.frameId }
        if element.type == .text {
            if element.lineHeight <= 0 || json["lineHeight"] == nil {
                element.lineHeight = CanvasText.defaultLineHeight(family: element.fontFamily)
            }
            if element.originalText.isEmpty { element.originalText = element.text }
            if element.containerId == nil, json["width"] == nil || json["height"] == nil || element.autoResize {
                CanvasOps.remeasure(&element)
            }
        }
        if element.type.hasPoints, json["width"] == nil {
            CanvasOps.normalizePoints(&element)
        }
        block.elements = [element]
        let bounds = element.sceneBounds
        block.size = CGSize(width: max(bounds.maxX, 0), height: max(bounds.maxY, 0))
        return block
    }

    // MARK: Elements

    private func makeElement(_ id: String, _ type: CanvasElementType, style: Style, context: Context) -> CanvasElement {
        var element = CanvasElement(id: id, type: type)
        element.seed = CanvasRandom.stableSeed(id)
        element.versionNonce = 0
        element.updated = 0
        element.strokeColor = style.strokeColor
        element.opacity = style.opacity
        element.frameId = context.frameId
        element.roughness = style.roughness
        element.strokeWidth = style.strokeWidth
        element.strokeStyle = style.strokeStyle
        element.fillStyle = style.fillStyle
        if type == .text {
            element.backgroundColor = CanvasColor.transparentName
            element.roundness = nil
        }
        return element
    }

    /// Rounds positions to hundredths and sizes up to hundredths, so files
    /// stay short, the same spec writes the same numbers, and text never
    /// ends up narrower than it measures.
    private static func round(_ block: inout CanvasLayoutBlock) {
        func r(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        func up(_ value: Double) -> Double { (value * 100 - 1e-6).rounded(.up) / 100 }
        for i in block.elements.indices {
            block.elements[i].x = r(block.elements[i].x)
            block.elements[i].y = r(block.elements[i].y)
            guard !block.elements[i].type.hasPoints else { continue }
            block.elements[i].width = up(block.elements[i].width)
            block.elements[i].height = up(block.elements[i].height)
        }
    }
}
