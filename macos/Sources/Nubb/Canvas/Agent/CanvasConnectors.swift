import CoreGraphics
import Foundation

/// Builds the arrows and lines of specs once everything else is placed:
/// finds what each end points at, routes a straight or elbow path between
/// them, binds the ends the way current Excalidraw does, and lays out the
/// label.
enum CanvasConnectors {
    /// What one end of a connector points at.
    struct End {
        /// The element to bind to, for arrows.
        var element: CanvasElement?
        /// The shape to stop at: the element, or a layout node's box.
        var outline: CanvasElement?
        /// Where the end aims.
        var center: CGPoint
    }

    /// Resolves an endpoint: an element, a layout node's box, or a point.
    static func resolve(
        _ endpoint: CanvasSpecEndpoint, elements: [String: CanvasElement], boxes: [String: CGRect]
    ) -> End? {
        switch endpoint {
        case .point(let point):
            return End(center: point)
        case .element(let id):
            if let element = elements[id], !(element.type == .text && element.containerId != nil), !element.type.isLinear {
                return End(element: element.type.isBindable ? element : nil, outline: element, center: element.center)
            }
            if let box = boxes[id] {
                var outline = CanvasElement(id: id, type: .rectangle)
                outline.x = Double(box.minX)
                outline.y = Double(box.minY)
                outline.width = Double(box.width)
                outline.height = Double(box.height)
                return End(outline: outline, center: CGPoint(x: box.midX, y: box.midY))
            }
            return nil
        }
    }

    /// The arrow or line for `connector` and its label, or nil with a
    /// warning when an end points at nothing.
    static func build(
        _ connector: CanvasPendingConnector, elements: [String: CanvasElement], boxes: [String: CGRect],
        overrides: CanvasLayoutOverrides, warnings: inout [String]
    ) -> [CanvasElement]? {
        let label = "\(connector.isArrow ? "arrow" : "line") \"\(connector.id)\""
        guard let from = resolve(connector.from, elements: elements, boxes: boxes) else {
            warnings.append("\(connector.path): \(label) not drawn: nothing has id \(describe(connector.from))")
            return nil
        }
        guard let to = resolve(connector.to, elements: elements, boxes: boxes) else {
            warnings.append("\(connector.path): \(label) not drawn: nothing has id \(describe(connector.to))")
            return nil
        }
        if case .element(let a) = connector.from, case .element(let b) = connector.to, a == b {
            warnings.append("\(connector.path): \(label) not drawn: it starts and ends at \"\(a)\"")
            return nil
        }

        let style = connector.style
        var arrow = CanvasElement(id: connector.id, type: connector.isArrow ? .arrow : .line)
        arrow.seed = CanvasRandom.stableSeed(connector.id)
        arrow.versionNonce = 0
        arrow.updated = 0
        arrow.strokeColor = style.strokeColor
        arrow.backgroundColor = CanvasColor.transparentName
        arrow.fillStyle = style.fillStyle
        arrow.strokeWidth = style.strokeWidth
        arrow.strokeStyle = style.strokeStyle
        arrow.roughness = style.roughness
        arrow.opacity = style.opacity
        arrow.frameId = connector.frameId
        arrow.groupIds = connector.groupIds
        arrow.locked = connector.locked
        arrow.link = connector.link
        arrow.hoverName = connector.name
        arrow.startArrowhead = style.startArrowhead
        arrow.endArrowhead = connector.isArrow ? style.endArrowhead : style.endArrowhead == "arrow" ? nil : style.endArrowhead

        // Excalidraw only binds arrows; lines are left free.
        let bind = connector.isArrow
        if connector.elbow && connector.isArrow {
            route(elbow: &arrow, connector: connector, from: from, to: to, bind: bind)
        } else {
            route(straight: &arrow, from: from, to: to, bind: bind, round: style.round)
        }
        round(&arrow)

        var result = [arrow]
        let labelID = CanvasLayout.partID(connector.id, "label")
        let text = overrides.text(labelID, spec: connector.label) ?? connector.label
        if !text.isEmpty {
            var element = CanvasElement(id: labelID, type: .text)
            element.seed = CanvasRandom.stableSeed(labelID)
            element.versionNonce = 0
            element.updated = 0
            element.strokeColor = style.strokeColor
            element.backgroundColor = CanvasColor.transparentName
            element.opacity = style.opacity
            element.roughness = style.roughness
            element.frameId = connector.frameId
            element.groupIds = connector.groupIds
            element.locked = connector.locked
            element.fontFamily = overrides.value(labelID, "fontFamily", spec: .number(Double(style.fontFamily)))?.intValue ?? style.fontFamily
            element.fontSize = overrides.number(labelID, "fontSize", spec: style.fontSize) ?? style.fontSize
            let lineHeight = CanvasText.defaultLineHeight(family: element.fontFamily)
            element.lineHeight = overrides.number(labelID, "lineHeight", spec: lineHeight) ?? lineHeight
            element.textAlign = "center"
            element.verticalAlign = "middle"
            element.containerId = connector.id
            element.originalText = text
            element.text = text
            result[0].addBoundElement(id: labelID, type: "text")
            CanvasOps.layoutLabel(&element, container: result[0])
            result.append(element)
        }
        return result
    }

    private static func describe(_ endpoint: CanvasSpecEndpoint) -> String {
        switch endpoint {
        case .element(let id): "\"\(id)\""
        case .point(let point): "[\(CanvasJSON.format(Double(point.x))), \(CanvasJSON.format(Double(point.y)))]"
        }
    }

    // MARK: Straight

    /// A straight connector from outline to outline, aimed center to
    /// center, with ends bound as Excalidraw's `orbit` bindings.
    private static func route(straight arrow: inout CanvasElement, from: End, to: End, bind: Bool, round: Bool) {
        let start = endPoint(of: from, toward: to.center)
        let end = endPoint(of: to, toward: from.center)
        CanvasOps.setScenePoints([start, end], of: &arrow)
        arrow.roundness = round ? .proportional : nil
        arrow.extra["elbowed"] = .bool(false)
        if bind {
            arrow.startBinding = from.element.map { binding(to: $0, aim: $0.center) }
            arrow.endBinding = to.element.map { binding(to: $0, aim: $0.center) }
        }
    }

    /// Where an end touches its shape when the connector comes from
    /// `other`: outside the outline, or the point itself.
    private static func endPoint(of end: End, toward other: CGPoint) -> CGPoint {
        guard let outline = end.outline else { return end.center }
        let gap = end.element.map(CanvasBinding.orbitGap) ?? 4
        return CanvasBinder.outlinePoint(toward: end.center, from: other, element: outline, gap: gap)
    }

    private static func binding(to element: CanvasElement, aim: CGPoint) -> CanvasBinding {
        let local = element.toLocal(aim)
        let fixed = CGPoint(
            x: element.width > 0 ? Double(local.x) / max(element.width, CanvasBinding.orbitGap(for: element)) : 0.5,
            y: element.height > 0 ? Double(local.y) / max(element.height, CanvasBinding.orbitGap(for: element)) : 0.5)
        return .orbit(element.id, fixedPoint: CanvasBinding.normalizedFixedPoint(fixed))
    }

    // MARK: Elbow

    private static func heading(_ side: CanvasSpecSide) -> CanvasElbow.Heading {
        switch side {
        case .left: .left
        case .right: .right
        case .top: .up
        case .bottom: .down
        }
    }

    /// A right-angled connector leaving and entering shapes through the
    /// middle of a side: the sides the spec names, or those facing the
    /// other end.
    private static func route(elbow arrow: inout CanvasElement, connector: CanvasPendingConnector, from: End, to: End, bind: Bool) {
        let fromHeading = connector.fromSide.map(heading)
            ?? (from.outline != nil ? CanvasElbow.heading(from: from.center, to: to.center) : nil)
        let toHeading = connector.toSide.map(heading)
            ?? (to.outline != nil ? CanvasElbow.heading(from: to.center, to: from.center) : nil)
        let start = sidePoint(of: from, heading: fromHeading)
        let end = sidePoint(of: to, heading: toHeading)
        let points = CanvasElbow.route(from: start.point, heading: fromHeading, to: end.point, heading: toHeading)
        CanvasOps.setScenePoints(points, of: &arrow)
        arrow.roundness = nil
        arrow.extra["elbowed"] = .bool(true)
        arrow.extra["fixedSegments"] = .null
        arrow.extra["startIsSpecial"] = .null
        arrow.extra["endIsSpecial"] = .null
        if bind {
            arrow.startBinding = from.element.flatMap { element in start.fixed.map { .orbit(element.id, fixedPoint: $0) } }
            arrow.endBinding = to.element.flatMap { element in end.fixed.map { .orbit(element.id, fixedPoint: $0) } }
        }
    }

    /// The middle of the side of an end's shape that `heading` leaves
    /// through, just outside it, with the fixed point that names it.
    private static func sidePoint(of end: End, heading: CanvasElbow.Heading?) -> (point: CGPoint, fixed: CGPoint?) {
        guard let outline = end.outline, let heading else { return (end.center, nil) }
        let gap = end.element.map(CanvasBinding.orbitGap) ?? 4
        let w = max(outline.width, 1), h = max(outline.height, 1)
        let fixed: CGPoint
        switch heading {
        case .left: fixed = CGPoint(x: -gap / w, y: 0.5001)
        case .right: fixed = CGPoint(x: 1 + gap / w, y: 0.5001)
        case .up: fixed = CGPoint(x: 0.5001, y: -gap / h)
        case .down: fixed = CGPoint(x: 0.5001, y: 1 + gap / h)
        }
        let normalized = CanvasBinding.normalizedFixedPoint(fixed)
        let point = outline.toScene(CGPoint(x: Double(normalized.x) * outline.width, y: Double(normalized.y) * outline.height))
        return (point, normalized)
    }

    /// Rounds a connector's position and points to hundredths, so files
    /// stay short and the same spec writes the same numbers.
    private static func round(_ arrow: inout CanvasElement) {
        func r(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        arrow.x = r(arrow.x)
        arrow.y = r(arrow.y)
        arrow.points = arrow.points.map { CGPoint(x: r(Double($0.x)), y: r(Double($0.y))) }
        let box = CanvasGeometry.bounds(of: arrow.points)
        arrow.width = r(Double(box.width))
        arrow.height = r(Double(box.height))
    }
}
