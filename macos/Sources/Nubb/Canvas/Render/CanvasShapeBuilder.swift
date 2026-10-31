import CoreGraphics
import Foundation

/// The drawable form of one element: paths in the element's local
/// coordinates with their paint. Built once per element version and cached,
/// so redraws while panning or zooming reuse it.
struct CanvasShape {
    enum Paint: Equatable {
        /// The element's stroke color.
        case stroke
        /// The element's background color.
        case background
        /// The canvas background, for outlined arrowheads.
        case canvas
    }

    struct Part {
        var path: CGPath
        var paint: Paint
        /// Filled when nil, stroked with this width otherwise.
        var lineWidth: Double?
        var dash: [Double]?
        var evenOdd = false
    }

    var parts: [Part] = []
}

/// Builds shapes the way Excalidraw's `_generateElementShape` does, using
/// the rough.js port with the element's seed.
enum CanvasShapeBuilder {
    static func shape(for element: CanvasElement) -> CanvasShape {
        switch element.type {
        case .rectangle: return rectangle(element)
        case .diamond: return diamond(element)
        case .ellipse: return ellipse(element)
        case .line, .arrow: return linear(element)
        case .freedraw: return freedraw(element)
        case .text: return text(element)
        case .image, .frame, .other: return placeholder(element)
        }
    }

    // MARK: Options

    private static func dashArray(_ element: CanvasElement) -> [Double]? {
        switch element.strokeStyle {
        case "dashed": [8, 8 + element.strokeWidth]
        case "dotted": [1.5, 6 + element.strokeWidth]
        default: nil
        }
    }

    /// Excalidraw's `adjustRoughness`: small shapes get less jitter.
    static func adjustedRoughness(_ element: CanvasElement) -> Double {
        let size = element.type.hasPoints ? element.localBounds.size : CGSize(width: element.width, height: element.height)
        let maxSize = max(abs(size.width), abs(size.height))
        let minSize = min(abs(size.width), abs(size.height))
        if (minSize >= 20 && maxSize >= 50)
            || (minSize >= 15 && element.roundness != nil && element.type.supportsRoundness && element.type != .arrow)
            || (element.type.isLinear && maxSize >= 50) {
            return element.roughness
        }
        return min(element.roughness / (maxSize < 10 ? 3 : 2), 2.5)
    }

    /// Excalidraw's `generateRoughOptions`.
    static func options(_ element: CanvasElement, continuousPath: Bool = false) -> RoughOptions {
        let o = RoughOptions()
        o.seed = element.seed
        let solid = element.strokeStyle == "solid"
        o.disableMultiStroke = !solid
        o.strokeWidth = solid ? element.strokeWidth : element.strokeWidth + 0.5
        o.fillWeight = element.strokeWidth / 2
        o.hachureGap = element.strokeWidth * 4
        o.roughness = adjustedRoughness(element)
        o.preserveVertices = continuousPath || element.roughness < 2

        switch element.type {
        case .rectangle, .diamond, .ellipse:
            o.fillStyle = element.fillStyle
            o.fill = !element.isTransparentBackground
            if element.type == .ellipse { o.curveFitting = 1 }
        case .line, .freedraw:
            if CanvasGeometry.isLoop(element.points) {
                o.fillStyle = element.fillStyle
                o.fill = !element.isTransparentBackground
            }
        default:
            break
        }
        return o
    }

    /// Converts rough.js op sets into shape parts.
    private static func parts(_ drawable: RoughDrawable, element: CanvasElement, strokeDash: [Double]?, fill: CanvasShape.Paint = .background) -> [CanvasShape.Part] {
        let o = drawable.options
        return drawable.sets.compactMap { set in
            guard !set.ops.isEmpty else { return nil }
            switch set.kind {
            case .path:
                return CanvasShape.Part(path: set.ops.cgPath(), paint: .stroke, lineWidth: o.strokeWidth, dash: strokeDash)
            case .fillPath:
                return CanvasShape.Part(path: set.ops.cgPath(), paint: fill, lineWidth: nil, evenOdd: drawable.usesEvenOddFill)
            case .fillSketch:
                let weight = o.fillWeight < 0 ? o.strokeWidth / 2 : o.fillWeight
                return CanvasShape.Part(path: set.ops.cgPath(), paint: fill, lineWidth: weight)
            }
        }
    }

    // MARK: Shapes

    private static func rectangle(_ element: CanvasElement) -> CanvasShape {
        let w = element.width, h = element.height
        let drawable: RoughDrawable
        if element.roundness != nil {
            let r = CanvasGeometry.cornerRadius(min(w, h), roundness: element.roundness)
            var b = RoughPathBuilder()
            b.move(r, 0)
            b.line(w - r, 0)
            b.quad(w, 0, w, r)
            b.line(w, h - r)
            b.quad(w, h, w - r, h)
            b.line(r, h)
            b.quad(0, h, 0, h - r)
            b.line(0, r)
            b.quad(0, 0, r, 0)
            drawable = RoughGenerator.path(b.segments, options(element, continuousPath: true))
        } else {
            drawable = RoughGenerator.rectangle(0, 0, w, h, options(element))
        }
        return CanvasShape(parts: parts(drawable, element: element, strokeDash: dashArray(element)))
    }

    private static func diamond(_ element: CanvasElement) -> CanvasShape {
        let p = CanvasGeometry.diamondPoints(width: element.width, height: element.height)
        let (top, right, bottom, left) = (p[0], p[1], p[2], p[3])
        let drawable: RoughDrawable
        if element.roundness != nil {
            let vr = CanvasGeometry.cornerRadius(abs(top.dx - left.dx), roundness: element.roundness)
            let hr = CanvasGeometry.cornerRadius(abs(right.dy - top.dy), roundness: element.roundness)
            var b = RoughPathBuilder()
            b.move(top.dx + vr, top.dy + hr)
            b.line(right.dx - vr, right.dy - hr)
            b.cubic(right.dx, right.dy, right.dx, right.dy, right.dx - vr, right.dy + hr)
            b.line(bottom.dx + vr, bottom.dy - hr)
            b.cubic(bottom.dx, bottom.dy, bottom.dx, bottom.dy, bottom.dx - vr, bottom.dy - hr)
            b.line(left.dx + vr, left.dy + hr)
            b.cubic(left.dx, left.dy, left.dx, left.dy, left.dx + vr, left.dy - hr)
            b.line(top.dx - vr, top.dy + hr)
            b.cubic(top.dx, top.dy, top.dx, top.dy, top.dx + vr, top.dy + hr)
            drawable = RoughGenerator.path(b.segments, options(element, continuousPath: true))
        } else {
            drawable = RoughGenerator.polygon(p, options(element))
        }
        return CanvasShape(parts: parts(drawable, element: element, strokeDash: dashArray(element)))
    }

    private static func ellipse(_ element: CanvasElement) -> CanvasShape {
        let drawable = RoughGenerator.ellipse(
            element.width / 2, element.height / 2, element.width, element.height, options(element))
        return CanvasShape(parts: parts(drawable, element: element, strokeDash: dashArray(element)))
    }

    private static func linear(_ element: CanvasElement) -> CanvasShape {
        let o = options(element)
        let points = element.points.isEmpty ? [CGPoint.zero] : element.points
        let body: RoughDrawable
        if element.roundness == nil {
            body = o.fill ? RoughGenerator.polygon(points, o) : RoughGenerator.linearPath(points, o)
        } else {
            body = RoughGenerator.curve(points, o)
        }

        var shape = CanvasShape(parts: parts(body, element: element, strokeDash: dashArray(element)))
        guard element.type == .arrow else { return shape }

        // Arrowheads follow the first stroke of the body, like Excalidraw's
        // `getArrowheadPoints`.
        let bodyOps = body.sets.first { $0.kind == .path }?.ops ?? body.sets.first?.ops ?? []
        if let head = element.startArrowhead {
            shape.parts += arrowhead(element, ops: bodyOps, position: .start, kind: head, options: o)
        }
        if let head = element.endArrowhead {
            shape.parts += arrowhead(element, ops: bodyOps, position: .end, kind: head, options: o)
        }
        return shape
    }

    private static func freedraw(_ element: CanvasElement) -> CanvasShape {
        var shape = CanvasShape()

        if CanvasGeometry.isLoop(element.points) && !element.isTransparentBackground {
            let simplified = RoughCurve.simplify(element.points, 0.75)
            let o = options(element)
            o.stroke = false
            let fill = RoughGenerator.curve(simplified, o)
            shape.parts += parts(fill, element: element, strokeDash: nil)
        }

        let outline = Freehand.outline(
            points: element.points.isEmpty ? [.zero] : element.points,
            pressures: element.simulatePressure ? nil : element.pressures,
            options: .excalidraw(strokeWidth: element.strokeWidth, simulatePressure: element.simulatePressure))
        shape.parts.append(CanvasShape.Part(path: Freehand.path(outline: outline), paint: .stroke, lineWidth: nil))
        return shape
    }

    private static func text(_ element: CanvasElement) -> CanvasShape {
        CanvasShape(parts: [CanvasShape.Part(path: CanvasText.path(for: element), paint: .stroke, lineWidth: nil)])
    }

    /// Images and frames aren't drawn yet: show their box so they can still
    /// be selected and moved.
    private static func placeholder(_ element: CanvasElement) -> CanvasShape {
        let path = CGPath(rect: element.localBounds, transform: nil)
        return CanvasShape(parts: [CanvasShape.Part(path: path, paint: .stroke, lineWidth: 1, dash: [6, 4])])
    }

    // MARK: Arrowheads

    enum ArrowEnd {
        case start
        case end
    }

    static func arrowheadSize(_ kind: String) -> Double {
        switch kind {
        case "arrow": 25
        case "diamond", "diamond_outline": 12
        case "crowfoot_many", "crowfoot_one", "crowfoot_one_or_many": 20
        default: 15
        }
    }

    static func arrowheadAngle(_ kind: String) -> Double {
        switch kind {
        case "bar": 90
        case "arrow": 20
        default: 25
        }
    }

    /// Excalidraw's `getArrowheadPoints`.
    static func arrowheadPoints(_ element: CanvasElement, ops: [RoughOp], position: ArrowEnd, kind: String) -> [Double]? {
        guard ops.count >= 2 else { return nil }
        let index = position == .start ? 1 : ops.count - 1
        guard case let .curveTo(p1, p2, p3) = ops[index] else { return nil }
        let p0: CGPoint
        switch ops[index - 1] {
        case .move(let p), .lineTo(let p): p0 = p
        case .curveTo(_, _, let p): p0 = p
        }

        func equation(_ t: Double, _ value: (CGPoint) -> Double) -> Double {
            pow(1 - t, 3) * value(p3) + 3 * t * pow(1 - t, 2) * value(p2)
                + 3 * pow(t, 2) * (1 - t) * value(p1) + value(p0) * pow(t, 3)
        }

        let tip = position == .start ? p0 : p3
        let x2 = tip.dx, y2 = tip.dy
        let x1 = equation(0.3, \.dx), y1 = equation(0.3, \.dy)
        let distance = hypot(x2 - x1, y2 - y1)
        guard distance > 0 else { return nil }
        let nx = (x2 - x1) / distance
        let ny = (y2 - y1) / distance

        let size = arrowheadSize(kind)
        let pts = element.points
        let (c, p): (CGPoint, CGPoint) = {
            guard let last = pts.last, let first = pts.first else { return (.zero, .zero) }
            if position == .end {
                return (last, pts.count > 1 ? pts[pts.count - 2] : .zero)
            }
            return (first, pts.count > 1 ? pts[1] : .zero)
        }()
        let length = hypot(c.dx - p.dx, c.dy - p.dy)
        let multiplier = kind == "diamond" || kind == "diamond_outline" ? 0.25 : 0.5
        let minSize = min(size, length * multiplier)
        let xs = x2 - nx * minSize
        let ys = y2 - ny * minSize

        if kind == "dot" || kind == "circle" || kind == "circle_outline" {
            let diameter = hypot(ys - y2, xs - x2) + element.strokeWidth - 2
            return [x2, y2, diameter]
        }

        let angle = arrowheadAngle(kind) * Double.pi / 180
        let tipPoint = CGPoint(x: x2, y: y2)
        let basePoint = CGPoint(x: xs, y: ys)

        if kind == "crowfoot_many" || kind == "crowfoot_one_or_many" {
            let a = CanvasGeometry.rotate(tipPoint, around: basePoint, by: -angle)
            let b = CanvasGeometry.rotate(tipPoint, around: basePoint, by: angle)
            return [xs, ys, a.dx, a.dy, b.dx, b.dy]
        }

        let a = CanvasGeometry.rotate(basePoint, around: tipPoint, by: -angle)
        let b = CanvasGeometry.rotate(basePoint, around: tipPoint, by: angle)

        if kind == "diamond" || kind == "diamond_outline" {
            let opposite: CGPoint
            if position == .start {
                let q = pts.count > 1 ? pts[1] : .zero
                opposite = CanvasGeometry.rotate(
                    CGPoint(x: x2 + minSize * 2, y: y2), around: tipPoint, by: atan2(q.dy - y2, q.dx - x2))
            } else {
                let q = pts.count > 1 ? pts[pts.count - 2] : .zero
                opposite = CanvasGeometry.rotate(
                    CGPoint(x: x2 - minSize * 2, y: y2), around: tipPoint, by: atan2(y2 - q.dy, x2 - q.dx))
            }
            return [x2, y2, a.dx, a.dy, opposite.dx, opposite.dy, b.dx, b.dy]
        }

        return [x2, y2, a.dx, a.dy, b.dx, b.dy]
    }

    /// Excalidraw's `getArrowheadShapes`.
    private static func arrowhead(_ element: CanvasElement, ops: [RoughOp], position: ArrowEnd, kind: String, options base: RoughOptions) -> [CanvasShape.Part] {
        guard let points = arrowheadPoints(element, ops: ops, position: position, kind: kind) else { return [] }

        func crowfootOne(_ values: [Double]?, _ o: RoughOptions) -> [CanvasShape.Part] {
            guard let values else { return [] }
            let line = RoughGenerator.line(values[2], values[3], values[4], values[5], o)
            return parts(line, element: element, strokeDash: nil)
        }

        switch kind {
        case "dot", "circle", "circle_outline":
            let o = base.copy()
            o.fill = true
            o.fillStyle = "solid"
            o.stroke = true
            o.roughness = min(0.5, base.roughness)
            let circle = RoughGenerator.circle(points[0], points[1], points[2], o)
            return parts(circle, element: element, strokeDash: nil, fill: kind == "circle_outline" ? .canvas : .stroke)

        case "triangle", "triangle_outline":
            let o = base.copy()
            o.fill = true
            o.fillStyle = "solid"
            o.roughness = min(1, base.roughness)
            let tri = [
                CGPoint(x: points[0], y: points[1]), CGPoint(x: points[2], y: points[3]),
                CGPoint(x: points[4], y: points[5]), CGPoint(x: points[0], y: points[1]),
            ]
            let polygon = RoughGenerator.polygon(tri, o)
            return parts(polygon, element: element, strokeDash: nil, fill: kind == "triangle_outline" ? .canvas : .stroke)

        case "diamond", "diamond_outline":
            let o = base.copy()
            o.fill = true
            o.fillStyle = "solid"
            o.roughness = min(1, base.roughness)
            let quad = [
                CGPoint(x: points[0], y: points[1]), CGPoint(x: points[2], y: points[3]),
                CGPoint(x: points[4], y: points[5]), CGPoint(x: points[6], y: points[7]),
                CGPoint(x: points[0], y: points[1]),
            ]
            let polygon = RoughGenerator.polygon(quad, o)
            return parts(polygon, element: element, strokeDash: nil, fill: kind == "diamond_outline" ? .canvas : .stroke)

        case "crowfoot_one":
            return crowfootOne(points, base)

        default:
            let o = base.copy()
            var dash: [Double]?
            if element.strokeStyle == "dotted" {
                dash = [1.5, 6 + element.strokeWidth - 1 - 1]
            }
            o.roughness = min(1, base.roughness)
            let (x2, y2, x3, y3, x4, y4) = (points[0], points[1], points[2], points[3], points[4], points[5])
            var result = parts(RoughGenerator.line(x3, y3, x2, y2, o), element: element, strokeDash: dash)
            result += parts(RoughGenerator.line(x4, y4, x2, y2, o), element: element, strokeDash: dash)
            if kind == "crowfoot_one_or_many" {
                result += crowfootOne(arrowheadPoints(element, ops: ops, position: position, kind: "crowfoot_one"), o)
            }
            return result
        }
    }
}
