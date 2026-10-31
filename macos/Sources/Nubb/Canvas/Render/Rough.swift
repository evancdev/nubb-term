// A Swift port of the parts of rough.js 4.6 (MIT, Copyright (c) 2019 Preet
// Shihn) and its hachure-fill and points-on-curve dependencies that
// Excalidraw uses. It follows the JavaScript closely, including the order of
// random draws, so a shape with the same seed comes out the same as in
// Excalidraw. Tests compare it with output from rough.js itself.
//
// Functions keep rough.js's parameter lists so the port can be checked
// against the source line by line.

import CoreGraphics
import Foundation

// MARK: - Random

/// rough.js's seeded generator: Park-Miller with 32-bit wraparound.
final class RoughRandom {
    private var seed: Int32

    init(seed: Int) {
        // A zero seed means Math.random() in rough.js. Use a fixed seed so
        // shapes don't change every time they are drawn.
        let value = Int32(truncatingIfNeeded: seed)
        self.seed = value == 0 ? 1 : value
    }

    func next() -> Double {
        seed = 48271 &* seed
        return Double(Int32.max & seed) / 2_147_483_648
    }
}

// MARK: - Options

/// rough.js options. A class because rough.js shares one options object, and
/// the random generator stored on it, across the helpers of one call.
final class RoughOptions {
    var maxRandomnessOffset: Double = 2
    var roughness: Double = 1
    var bowing: Double = 1
    var stroke = true
    var strokeWidth: Double = 1
    var curveTightness: Double = 0
    var curveFitting: Double = 0.95
    var curveStepCount: Double = 9
    var fillStyle = "hachure"
    var fillWeight: Double = -1
    var hachureAngle: Double = -41
    var hachureGap: Double = -1
    var seed = 0
    var disableMultiStroke = false
    var disableMultiStrokeFill = false
    var preserveVertices = false
    var fillShapeRoughnessGain: Double = 0.8
    var fill = false
    var randomizer: RoughRandom?

    init() {}

    /// `Object.assign({}, o)`: the copy shares the random generator.
    func copy() -> RoughOptions {
        let o = RoughOptions()
        o.maxRandomnessOffset = maxRandomnessOffset
        o.roughness = roughness
        o.bowing = bowing
        o.stroke = stroke
        o.strokeWidth = strokeWidth
        o.curveTightness = curveTightness
        o.curveFitting = curveFitting
        o.curveStepCount = curveStepCount
        o.fillStyle = fillStyle
        o.fillWeight = fillWeight
        o.hachureAngle = hachureAngle
        o.hachureGap = hachureGap
        o.seed = seed
        o.disableMultiStroke = disableMultiStroke
        o.disableMultiStrokeFill = disableMultiStrokeFill
        o.preserveVertices = preserveVertices
        o.fillShapeRoughnessGain = fillShapeRoughnessGain
        o.fill = fill
        o.randomizer = randomizer
        return o
    }

    func random() -> Double {
        if randomizer == nil { randomizer = RoughRandom(seed: seed) }
        return randomizer!.next()
    }
}

// MARK: - Output

enum RoughOp: Equatable {
    case move(CGPoint)
    case lineTo(CGPoint)
    case curveTo(CGPoint, CGPoint, CGPoint)
}

struct RoughOpSet: Equatable {
    enum Kind: Equatable {
        /// Stroked with the stroke width.
        case path
        /// Filled with the fill color.
        case fillPath
        /// Hachure lines, stroked in the fill color with the fill weight.
        case fillSketch
    }

    var kind: Kind
    var ops: [RoughOp]
}

struct RoughDrawable {
    enum Shape {
        case line, rectangle, ellipse, linearPath, curve, polygon, path
    }

    var shape: Shape
    var sets: [RoughOpSet]
    var options: RoughOptions

    /// rough.js fills curves, polygons, and paths even-odd.
    var usesEvenOddFill: Bool {
        shape == .curve || shape == .polygon || shape == .path
    }
}

/// A path in the normalized form rough.js works on: absolute moves, lines,
/// cubic curves, and closes.
enum RoughSegment: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case close
}

/// Builds normalized segments the way path-data-parser normalizes SVG path
/// data, converting quadratic curves to cubic ones.
struct RoughPathBuilder {
    private(set) var segments: [RoughSegment] = []
    private var current = CGPoint.zero

    mutating func move(_ x: Double, _ y: Double) {
        current = CGPoint(x: x, y: y)
        segments.append(.move(current))
    }

    mutating func line(_ x: Double, _ y: Double) {
        current = CGPoint(x: x, y: y)
        segments.append(.line(current))
    }

    mutating func quad(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) {
        let cx = Double(current.x), cy = Double(current.y)
        let c1 = CGPoint(x: cx + 2 * (x1 - cx) / 3, y: cy + 2 * (y1 - cy) / 3)
        let c2 = CGPoint(x: x + 2 * (x1 - x) / 3, y: y + 2 * (y1 - y) / 3)
        current = CGPoint(x: x, y: y)
        segments.append(.cubic(c1, c2, current))
    }

    mutating func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        current = CGPoint(x: x, y: y)
        segments.append(.cubic(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), current))
    }

    mutating func close() {
        segments.append(.close)
    }
}

// MARK: - Generator

enum RoughGenerator {
    /// A fresh options object with rough.js's defaults.
    static func options() -> RoughOptions { RoughOptions() }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ options: RoughOptions) -> RoughDrawable {
        let o = options.copy()
        o.randomizer = nil
        return RoughDrawable(shape: .line, sets: [RoughRenderer.line(x1, y1, x2, y2, o)], options: o)
    }

    static func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        var sets: [RoughOpSet] = []
        let outline = RoughRenderer.rectangle(x, y, width, height, o)
        if o.fill {
            let points = [
                CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
                CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height),
            ]
            if o.fillStyle == "solid" {
                sets.append(RoughRenderer.solidFillPolygon([points], o))
            } else {
                sets.append(RoughRenderer.patternFillPolygons([points], o))
            }
        }
        if o.stroke { sets.append(outline) }
        return RoughDrawable(shape: .rectangle, sets: sets, options: o)
    }

    static func ellipse(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        var sets: [RoughOpSet] = []
        let params = RoughRenderer.generateEllipseParams(width, height, o)
        let response = RoughRenderer.ellipseWithParams(x, y, o, params)
        if o.fill {
            if o.fillStyle == "solid" {
                var shape = RoughRenderer.ellipseWithParams(x, y, o, params).opset
                shape.kind = .fillPath
                sets.append(shape)
            } else {
                sets.append(RoughRenderer.patternFillPolygons([response.estimatedPoints], o))
            }
        }
        if o.stroke { sets.append(response.opset) }
        return RoughDrawable(shape: .ellipse, sets: sets, options: o)
    }

    static func circle(_ x: Double, _ y: Double, _ diameter: Double, _ options: RoughOptions) -> RoughDrawable {
        ellipse(x, y, diameter, diameter, options)
    }

    static func linearPath(_ points: [CGPoint], _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        return RoughDrawable(shape: .linearPath, sets: [RoughRenderer.linearPath(points, false, o)], options: o)
    }

    static func curve(_ points: [CGPoint], _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        var sets: [RoughOpSet] = []
        let outline = RoughRenderer.curve(points, o)
        if o.fill {
            if o.fillStyle == "solid" {
                let fillOptions = o.copy()
                fillOptions.disableMultiStroke = true
                fillOptions.roughness = o.roughness != 0 ? o.roughness + o.fillShapeRoughnessGain : 0
                let fillShape = RoughRenderer.curve(points, fillOptions)
                sets.append(RoughOpSet(kind: .fillPath, ops: mergedShape(fillShape.ops)))
            } else {
                var polyPoints: [CGPoint] = []
                if points.count < 3 {
                    polyPoints.append(contentsOf: points)
                } else if points.count == 3 {
                    polyPoints.append(contentsOf: RoughCurve.pointsOnBezierCurves(
                        RoughCurve.curveToBezier([points[0], points[0], points[1], points[2]]),
                        tolerance: 10, distance: (1 + o.roughness) / 2))
                } else {
                    polyPoints.append(contentsOf: RoughCurve.pointsOnBezierCurves(
                        RoughCurve.curveToBezier(points),
                        tolerance: 10, distance: (1 + o.roughness) / 2))
                }
                if !polyPoints.isEmpty {
                    sets.append(RoughRenderer.patternFillPolygons([polyPoints], o))
                }
            }
        }
        if o.stroke { sets.append(outline) }
        return RoughDrawable(shape: .curve, sets: sets, options: o)
    }

    static func polygon(_ points: [CGPoint], _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        var sets: [RoughOpSet] = []
        let outline = RoughRenderer.linearPath(points, true, o)
        if o.fill {
            if o.fillStyle == "solid" {
                sets.append(RoughRenderer.solidFillPolygon([points], o))
            } else {
                sets.append(RoughRenderer.patternFillPolygons([points], o))
            }
        }
        if o.stroke { sets.append(outline) }
        return RoughDrawable(shape: .polygon, sets: sets, options: o)
    }

    static func path(_ segments: [RoughSegment], _ options: RoughOptions) -> RoughDrawable {
        let o = fresh(options)
        var sets: [RoughOpSet] = []
        guard !segments.isEmpty else { return RoughDrawable(shape: .path, sets: [], options: o) }

        let distance = (1 + o.roughness) / 2
        let pointSets = RoughCurve.pointsOnPath(segments, tolerance: 1, distance: distance)
        let shape = RoughRenderer.svgPath(segments, o)
        if o.fill {
            if o.fillStyle == "solid" {
                if pointSets.count == 1 {
                    let fillOptions = o.copy()
                    fillOptions.disableMultiStroke = true
                    fillOptions.roughness = o.roughness != 0 ? o.roughness + o.fillShapeRoughnessGain : 0
                    let fillShape = RoughRenderer.svgPath(segments, fillOptions)
                    sets.append(RoughOpSet(kind: .fillPath, ops: mergedShape(fillShape.ops)))
                } else {
                    sets.append(RoughRenderer.solidFillPolygon(pointSets, o))
                }
            } else {
                sets.append(RoughRenderer.patternFillPolygons(pointSets, o))
            }
        }
        if o.stroke { sets.append(shape) }
        return RoughDrawable(shape: .path, sets: sets, options: o)
    }

    /// `this._o(options)`: a new object, so a new random generator.
    private static func fresh(_ options: RoughOptions) -> RoughOptions {
        let o = options.copy()
        o.randomizer = nil
        return o
    }

    private static func mergedShape(_ ops: [RoughOp]) -> [RoughOp] {
        ops.enumerated().compactMap { index, op in
            if index == 0 { return op }
            if case .move = op { return nil }
            return op
        }
    }
}

// MARK: - Renderer

enum RoughRenderer {
    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ o: RoughOptions) -> RoughOpSet {
        RoughOpSet(kind: .path, ops: doubleLine(x1, y1, x2, y2, o))
    }

    static func linearPath(_ points: [CGPoint], _ close: Bool, _ o: RoughOptions) -> RoughOpSet {
        let count = points.count
        if count > 2 {
            var ops: [RoughOp] = []
            for i in 0..<(count - 1) {
                ops += doubleLine(points[i].dx, points[i].dy, points[i + 1].dx, points[i + 1].dy, o)
            }
            if close {
                ops += doubleLine(points[count - 1].dx, points[count - 1].dy, points[0].dx, points[0].dy, o)
            }
            return RoughOpSet(kind: .path, ops: ops)
        } else if count == 2 {
            return line(points[0].dx, points[0].dy, points[1].dx, points[1].dy, o)
        }
        return RoughOpSet(kind: .path, ops: [])
    }

    static func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ o: RoughOptions) -> RoughOpSet {
        let points = [
            CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
            CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height),
        ]
        return linearPath(points, true, o)
    }

    static func curve(_ points: [CGPoint], _ o: RoughOptions) -> RoughOpSet {
        guard !points.isEmpty else { return RoughOpSet(kind: .path, ops: []) }
        let o1 = curveWithOffset(points, 1 * (1 + o.roughness * 0.2), o)
        let o2 = o.disableMultiStroke ? [] : curveWithOffset(points, 1.5 * (1 + o.roughness * 0.22), cloneOptionsAlterSeed(o))
        return RoughOpSet(kind: .path, ops: o1 + o2)
    }

    struct EllipseParams {
        var increment: Double
        var rx: Double
        var ry: Double
    }

    static func generateEllipseParams(_ width: Double, _ height: Double, _ o: RoughOptions) -> EllipseParams {
        let psq = sqrt(Double.pi * 2 * sqrt((pow(width / 2, 2) + pow(height / 2, 2)) / 2))
        let stepCount = ceil(max(o.curveStepCount, (o.curveStepCount / sqrt(200)) * psq))
        let increment = (Double.pi * 2) / stepCount
        var rx = abs(width / 2)
        var ry = abs(height / 2)
        let curveFitRandomness = 1 - o.curveFitting
        rx += offsetOpt(rx * curveFitRandomness, o)
        ry += offsetOpt(ry * curveFitRandomness, o)
        return EllipseParams(increment: increment, rx: rx, ry: ry)
    }

    static func ellipseWithParams(_ x: Double, _ y: Double, _ o: RoughOptions, _ params: EllipseParams) -> (estimatedPoints: [CGPoint], opset: RoughOpSet) {
        let (ap1, cp1) = computeEllipsePoints(
            params.increment, x, y, params.rx, params.ry, 1,
            params.increment * offset(0.1, offset(0.4, 1, o), o), o)
        var o1 = curveOps(ap1, nil, o)
        if !o.disableMultiStroke && o.roughness != 0 {
            let (ap2, _) = computeEllipsePoints(params.increment, x, y, params.rx, params.ry, 1.5, 0, o)
            o1 += curveOps(ap2, nil, o)
        }
        return (cp1, RoughOpSet(kind: .path, ops: o1))
    }

    static func svgPath(_ segments: [RoughSegment], _ o: RoughOptions) -> RoughOpSet {
        var ops: [RoughOp] = []
        var first = CGPoint.zero
        var current = CGPoint.zero
        for segment in segments {
            switch segment {
            case .move(let p):
                current = p
                first = p
            case .line(let p):
                ops += doubleLine(current.dx, current.dy, p.dx, p.dy, o)
                current = p
            case .cubic(let c1, let c2, let p):
                ops += bezierTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy, current, o)
                current = p
            case .close:
                ops += doubleLine(current.dx, current.dy, first.dx, first.dy, o)
                current = first
            }
        }
        return RoughOpSet(kind: .path, ops: ops)
    }

    static func solidFillPolygon(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> RoughOpSet {
        var ops: [RoughOp] = []
        for points in polygonList where points.count > 2 {
            let off = o.maxRandomnessOffset
            ops.append(.move(CGPoint(x: points[0].dx + offsetOpt(off, o), y: points[0].dy + offsetOpt(off, o))))
            for i in 1..<points.count {
                ops.append(.lineTo(CGPoint(x: points[i].dx + offsetOpt(off, o), y: points[i].dy + offsetOpt(off, o))))
            }
        }
        return RoughOpSet(kind: .fillPath, ops: ops)
    }

    static func patternFillPolygons(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> RoughOpSet {
        RoughFiller.fillPolygons(polygonList, o)
    }

    static func doubleLineFillOps(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ o: RoughOptions) -> [RoughOp] {
        doubleLine(x1, y1, x2, y2, o, filling: true)
    }

    // MARK: Private helpers

    private static func cloneOptionsAlterSeed(_ o: RoughOptions) -> RoughOptions {
        let result = o.copy()
        result.randomizer = nil
        if o.seed != 0 { result.seed = o.seed + 1 }
        return result
    }

    static func offset(_ min: Double, _ max: Double, _ o: RoughOptions, _ roughnessGain: Double = 1) -> Double {
        o.roughness * roughnessGain * ((o.random() * (max - min)) + min)
    }

    static func offsetOpt(_ x: Double, _ o: RoughOptions, _ roughnessGain: Double = 1) -> Double {
        offset(-x, x, o, roughnessGain)
    }

    private static func doubleLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ o: RoughOptions, filling: Bool = false) -> [RoughOp] {
        let singleStroke = filling ? o.disableMultiStrokeFill : o.disableMultiStroke
        let o1 = lineOps(x1, y1, x2, y2, o, move: true, overlay: false)
        if singleStroke { return o1 }
        let o2 = lineOps(x1, y1, x2, y2, o, move: true, overlay: true)
        return o1 + o2
    }

    // swiftlint:disable:next function_parameter_count
    private static func lineOps(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ o: RoughOptions, move: Bool, overlay: Bool) -> [RoughOp] {
        let lengthSq = pow(x1 - x2, 2) + pow(y1 - y2, 2)
        let length = sqrt(lengthSq)
        let roughnessGain: Double
        if length < 200 {
            roughnessGain = 1
        } else if length > 500 {
            roughnessGain = 0.4
        } else {
            roughnessGain = -0.0016668 * length + 1.233334
        }

        var off = o.maxRandomnessOffset
        if off * off * 100 > lengthSq {
            off = length / 10
        }
        let halfOffset = off / 2
        let divergePoint = 0.2 + o.random() * 0.2
        var midDispX = o.bowing * o.maxRandomnessOffset * (y2 - y1) / 200
        var midDispY = o.bowing * o.maxRandomnessOffset * (x1 - x2) / 200
        midDispX = offsetOpt(midDispX, o, roughnessGain)
        midDispY = offsetOpt(midDispY, o, roughnessGain)

        var ops: [RoughOp] = []
        let randomHalf = { offsetOpt(halfOffset, o, roughnessGain) }
        let randomFull = { offsetOpt(off, o, roughnessGain) }
        let preserve = o.preserveVertices

        if move {
            if overlay {
                let px = x1 + (preserve ? 0 : randomHalf())
                let py = y1 + (preserve ? 0 : randomHalf())
                ops.append(.move(CGPoint(x: px, y: py)))
            } else {
                let px = x1 + (preserve ? 0 : offsetOpt(off, o, roughnessGain))
                let py = y1 + (preserve ? 0 : offsetOpt(off, o, roughnessGain))
                ops.append(.move(CGPoint(x: px, y: py)))
            }
        }

        let random = overlay ? randomHalf : randomFull
        let c1x = midDispX + x1 + (x2 - x1) * divergePoint + random()
        let c1y = midDispY + y1 + (y2 - y1) * divergePoint + random()
        let c2x = midDispX + x1 + 2 * (x2 - x1) * divergePoint + random()
        let c2y = midDispY + y1 + 2 * (y2 - y1) * divergePoint + random()
        let ex = x2 + (preserve ? 0 : random())
        let ey = y2 + (preserve ? 0 : random())
        ops.append(.curveTo(CGPoint(x: c1x, y: c1y), CGPoint(x: c2x, y: c2y), CGPoint(x: ex, y: ey)))
        return ops
    }

    private static func curveWithOffset(_ points: [CGPoint], _ off: Double, _ o: RoughOptions) -> [RoughOp] {
        guard !points.isEmpty else { return [] }
        var ps: [CGPoint] = []
        func jittered(_ p: CGPoint) -> CGPoint {
            let x = p.dx + offsetOpt(off, o)
            let y = p.dy + offsetOpt(off, o)
            return CGPoint(x: x, y: y)
        }
        ps.append(jittered(points[0]))
        ps.append(jittered(points[0]))
        for i in 1..<max(points.count, 1) where points.count > 1 {
            ps.append(jittered(points[i]))
            if i == points.count - 1 {
                ps.append(jittered(points[i]))
            }
        }
        return curveOps(ps, nil, o)
    }

    private static func curveOps(_ points: [CGPoint], _ closePoint: CGPoint?, _ o: RoughOptions) -> [RoughOp] {
        let count = points.count
        var ops: [RoughOp] = []
        if count > 3 {
            let s = 1 - o.curveTightness
            ops.append(.move(points[1]))
            var i = 1
            while i + 2 < count {
                let p = points[i]
                let b1 = CGPoint(
                    x: p.dx + (s * points[i + 1].dx - s * points[i - 1].dx) / 6,
                    y: p.dy + (s * points[i + 1].dy - s * points[i - 1].dy) / 6)
                let b2 = CGPoint(
                    x: points[i + 1].dx + (s * points[i].dx - s * points[i + 2].dx) / 6,
                    y: points[i + 1].dy + (s * points[i].dy - s * points[i + 2].dy) / 6)
                ops.append(.curveTo(b1, b2, points[i + 1]))
                i += 1
            }
            if let closePoint {
                let ro = o.maxRandomnessOffset
                let x = closePoint.dx + offsetOpt(ro, o)
                let y = closePoint.dy + offsetOpt(ro, o)
                ops.append(.lineTo(CGPoint(x: x, y: y)))
            }
        } else if count == 3 {
            ops.append(.move(points[1]))
            ops.append(.curveTo(points[1], points[2], points[2]))
        } else if count == 2 {
            ops += lineOps(points[0].dx, points[0].dy, points[1].dx, points[1].dy, o, move: true, overlay: true)
        }
        return ops
    }

    // swiftlint:disable:next function_parameter_count
    private static func computeEllipsePoints(
        _ incrementIn: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
        _ off: Double, _ overlap: Double, _ o: RoughOptions
    ) -> ([CGPoint], [CGPoint]) {
        var increment = incrementIn
        var corePoints: [CGPoint] = []
        var allPoints: [CGPoint] = []

        if o.roughness == 0 {
            increment /= 4
            allPoints.append(CGPoint(x: cx + rx * cos(-increment), y: cy + ry * sin(-increment)))
            var angle = 0.0
            while angle <= Double.pi * 2 {
                let p = CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle))
                corePoints.append(p)
                allPoints.append(p)
                angle += increment
            }
            allPoints.append(CGPoint(x: cx + rx * cos(0), y: cy + ry * sin(0)))
            allPoints.append(CGPoint(x: cx + rx * cos(increment), y: cy + ry * sin(increment)))
        } else {
            let radOffset = offsetOpt(0.5, o) - Double.pi / 2
            do {
                let x = offsetOpt(off, o) + cx + 0.9 * rx * cos(radOffset - increment)
                let y = offsetOpt(off, o) + cy + 0.9 * ry * sin(radOffset - increment)
                allPoints.append(CGPoint(x: x, y: y))
            }
            let endAngle = Double.pi * 2 + radOffset - 0.01
            var angle = radOffset
            while angle < endAngle {
                let x = offsetOpt(off, o) + cx + rx * cos(angle)
                let y = offsetOpt(off, o) + cy + ry * sin(angle)
                let p = CGPoint(x: x, y: y)
                corePoints.append(p)
                allPoints.append(p)
                angle += increment
            }
            do {
                let x = offsetOpt(off, o) + cx + rx * cos(radOffset + Double.pi * 2 + overlap * 0.5)
                let y = offsetOpt(off, o) + cy + ry * sin(radOffset + Double.pi * 2 + overlap * 0.5)
                allPoints.append(CGPoint(x: x, y: y))
            }
            do {
                let x = offsetOpt(off, o) + cx + 0.98 * rx * cos(radOffset + overlap)
                let y = offsetOpt(off, o) + cy + 0.98 * ry * sin(radOffset + overlap)
                allPoints.append(CGPoint(x: x, y: y))
            }
            do {
                let x = offsetOpt(off, o) + cx + 0.9 * rx * cos(radOffset + overlap * 0.5)
                let y = offsetOpt(off, o) + cy + 0.9 * ry * sin(radOffset + overlap * 0.5)
                allPoints.append(CGPoint(x: x, y: y))
            }
        }
        return (allPoints, corePoints)
    }

    // swiftlint:disable:next function_parameter_count
    private static func bezierTo(
        _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double,
        _ current: CGPoint, _ o: RoughOptions
    ) -> [RoughOp] {
        var ops: [RoughOp] = []
        let base = o.maxRandomnessOffset != 0 ? o.maxRandomnessOffset : 1
        let ros = [base, base + 0.3]
        let iterations = o.disableMultiStroke ? 1 : 2
        let preserve = o.preserveVertices
        for i in 0..<iterations {
            if i == 0 {
                ops.append(.move(current))
            } else {
                let px = current.dx + (preserve ? 0 : offsetOpt(ros[0], o))
                let py = current.dy + (preserve ? 0 : offsetOpt(ros[0], o))
                ops.append(.move(CGPoint(x: px, y: py)))
            }
            let f: CGPoint
            if preserve {
                f = CGPoint(x: x, y: y)
            } else {
                let fx = x + offsetOpt(ros[i], o)
                let fy = y + offsetOpt(ros[i], o)
                f = CGPoint(x: fx, y: fy)
            }
            let c1x = x1 + offsetOpt(ros[i], o)
            let c1y = y1 + offsetOpt(ros[i], o)
            let c2x = x2 + offsetOpt(ros[i], o)
            let c2y = y2 + offsetOpt(ros[i], o)
            ops.append(.curveTo(CGPoint(x: c1x, y: c1y), CGPoint(x: c2x, y: c2y), f))
        }
        return ops
    }
}

// MARK: - Fillers

enum RoughFiller {
    static func fillPolygons(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> RoughOpSet {
        switch o.fillStyle {
        case "cross-hatch":
            var set = hachure(polygonList, o)
            let o2 = o.copy()
            o2.hachureAngle = o.hachureAngle + 90
            set.ops += hachure(polygonList, o2).ops
            return set
        case "zigzag":
            return zigzag(polygonList, o)
        default:
            return hachure(polygonList, o)
        }
    }

    private static func hachure(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> RoughOpSet {
        let lines = polygonHachureLines(polygonList, o)
        return RoughOpSet(kind: .fillSketch, ops: renderLines(lines, o))
    }

    private static func zigzag(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> RoughOpSet {
        var gap = o.hachureGap
        if gap < 0 { gap = o.strokeWidth * 4 }
        gap = max(gap, 0.1)
        let o2 = o.copy()
        o2.hachureGap = gap
        let lines = polygonHachureLines(polygonList, o2)
        let zigZagAngle = (Double.pi / 180) * o.hachureAngle
        var zigzagLines: [(CGPoint, CGPoint)] = []
        let dgx = gap * 0.5 * cos(zigZagAngle)
        let dgy = gap * 0.5 * sin(zigZagAngle)
        for (p1, p2) in lines where hypot(p1.dx - p2.dx, p1.dy - p2.dy) != 0 {
            zigzagLines.append((CGPoint(x: p1.dx - dgx, y: p1.dy + dgy), p2))
            zigzagLines.append((CGPoint(x: p1.dx + dgx, y: p1.dy - dgy), p2))
        }
        return RoughOpSet(kind: .fillSketch, ops: renderLines(zigzagLines, o))
    }

    private static func renderLines(_ lines: [(CGPoint, CGPoint)], _ o: RoughOptions) -> [RoughOp] {
        var ops: [RoughOp] = []
        for (a, b) in lines {
            ops += RoughRenderer.doubleLineFillOps(a.dx, a.dy, b.dx, b.dy, o)
        }
        return ops
    }

    static func polygonHachureLines(_ polygonList: [[CGPoint]], _ o: RoughOptions) -> [(CGPoint, CGPoint)] {
        let angle = o.hachureAngle + 90
        var gap = o.hachureGap
        if gap < 0 { gap = o.strokeWidth * 4 }
        gap = (max(gap, 0.1)).rounded(.toNearestOrAwayFromZero)
        var skipOffset = 1.0
        if o.roughness >= 1 {
            // rough.js falls back to Math.random() without a generator.
            // Using the seeded one keeps the fill stable between redraws.
            if o.random() > 0.7 {
                skipOffset = gap
            }
        }
        return RoughHachure.lines(polygonList, gap: gap, angle: angle, stepOffset: skipOffset != 0 ? skipOffset : 1)
    }
}

/// hachure-fill 0.5: horizontal scan lines across rotated polygons.
enum RoughHachure {
    private struct Edge {
        var ymin: Double
        var ymax: Double
        var x: Double
        var islope: Double
    }

    static func lines(_ polygons: [[CGPoint]], gap gapIn: Double, angle: Double, stepOffset: Double) -> [(CGPoint, CGPoint)] {
        let gap = max(gapIn, 0.1)
        var polygonList = polygons
        if angle != 0 {
            polygonList = polygonList.map { rotate($0, by: angle) }
        }
        var lines = straightLines(polygonList, gap: gap, stepOffset: stepOffset)
        if angle != 0 {
            lines = lines.map { line in
                let rotated = rotate([line.0, line.1], by: -angle)
                return (rotated[0], rotated[1])
            }
        }
        return lines
    }

    private static func rotate(_ points: [CGPoint], by degrees: Double) -> [CGPoint] {
        let a = (Double.pi / 180) * degrees
        let c = cos(a)
        let s = sin(a)
        return points.map { p in
            CGPoint(x: p.dx * c - p.dy * s, y: p.dx * s + p.dy * c)
        }
    }

    private static func straightLines(_ polygons: [[CGPoint]], gap: Double, stepOffset: Double) -> [(CGPoint, CGPoint)] {
        var vertexArray: [[CGPoint]] = []
        for polygon in polygons where !polygon.isEmpty {
            var vertices = polygon
            if vertices[0] != vertices[vertices.count - 1] {
                vertices.append(vertices[0])
            }
            if vertices.count > 2 { vertexArray.append(vertices) }
        }

        var edges: [Edge] = []
        for vertices in vertexArray {
            for i in 0..<(vertices.count - 1) {
                let p1 = vertices[i]
                let p2 = vertices[i + 1]
                if p1.dy != p2.dy {
                    let ymin = min(p1.dy, p2.dy)
                    edges.append(Edge(
                        ymin: ymin,
                        ymax: max(p1.dy, p2.dy),
                        x: ymin == p1.dy ? p1.dx : p2.dx,
                        islope: (p2.dx - p1.dx) / (p2.dy - p1.dy)))
                }
            }
        }

        edges.sort { a, b in
            if a.ymin != b.ymin { return a.ymin < b.ymin }
            if a.x != b.x { return a.x < b.x }
            return a.ymax < b.ymax
        }

        var lines: [(CGPoint, CGPoint)] = []
        guard !edges.isEmpty else { return lines }

        var active: [Edge] = []
        var y = edges[0].ymin
        var iteration = 0.0
        var pending = edges[...]
        while !active.isEmpty || !pending.isEmpty {
            if !pending.isEmpty {
                while let first = pending.first, first.ymin <= y {
                    active.append(first)
                    pending = pending.dropFirst()
                }
            }

            active.removeAll { $0.ymax <= y }
            active.sort { $0.x < $1.x }

            if stepOffset != 1 || iteration.truncatingRemainder(dividingBy: gap) == 0 {
                if active.count > 1 {
                    var i = 0
                    while i + 1 < active.count {
                        let ce = active[i]
                        let ne = active[i + 1]
                        lines.append((
                            CGPoint(x: ce.x.rounded(.toNearestOrAwayFromZero), y: y),
                            CGPoint(x: ne.x.rounded(.toNearestOrAwayFromZero), y: y)))
                        i += 2
                    }
                }
            }

            y += stepOffset
            for index in active.indices {
                active[index].x += stepOffset * active[index].islope
            }
            iteration += 1

            // A polygon with NaN coordinates never empties the active list.
            if !y.isFinite || iteration > 1_000_000 { break }
        }
        return lines
    }
}

// MARK: - Curves

/// points-on-curve 0.2 and points-on-path 0.2.
enum RoughCurve {
    static func curveToBezier(_ pointsIn: [CGPoint], curveTightness: Double = 0) -> [CGPoint] {
        let count = pointsIn.count
        guard count >= 3 else { return pointsIn }
        var out: [CGPoint] = []
        if count == 3 {
            out = [pointsIn[0], pointsIn[1], pointsIn[2], pointsIn[2]]
        } else {
            var points: [CGPoint] = [pointsIn[0], pointsIn[0]]
            for i in 1..<count {
                points.append(pointsIn[i])
                if i == count - 1 { points.append(pointsIn[i]) }
            }
            let s = 1 - curveTightness
            out.append(points[0])
            var i = 1
            while i + 2 < points.count {
                let p = points[i]
                out.append(CGPoint(
                    x: p.dx + (s * points[i + 1].dx - s * points[i - 1].dx) / 6,
                    y: p.dy + (s * points[i + 1].dy - s * points[i - 1].dy) / 6))
                out.append(CGPoint(
                    x: points[i + 1].dx + (s * points[i].dx - s * points[i + 2].dx) / 6,
                    y: points[i + 1].dy + (s * points[i].dy - s * points[i + 2].dy) / 6))
                out.append(points[i + 1])
                i += 1
            }
        }
        return out
    }

    static func pointsOnBezierCurves(_ points: [CGPoint], tolerance: Double = 0.15, distance: Double? = nil) -> [CGPoint] {
        var newPoints: [CGPoint] = []
        let segments = (points.count - 1) / 3
        for i in 0..<max(segments, 0) {
            pointsOnBezierCurveWithSplitting(Array(points[(i * 3)...(i * 3 + 3)]), tolerance, &newPoints, depth: 0)
        }
        if let distance, distance > 0 {
            return simplify(newPoints, distance)
        }
        return newPoints
    }

    static func simplify(_ points: [CGPoint], _ distance: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        var out: [CGPoint] = []
        simplifyPoints(points, 0, points.count, distance, &out)
        return out
    }

    static func pointsOnPath(_ segments: [RoughSegment], tolerance: Double, distance: Double?) -> [[CGPoint]] {
        var sets: [[CGPoint]] = []
        var currentPoints: [CGPoint] = []
        var start = CGPoint.zero
        var pendingCurve: [CGPoint] = []

        func appendPendingCurve() {
            if pendingCurve.count >= 4 {
                currentPoints += pointsOnBezierCurves(pendingCurve, tolerance: tolerance)
            }
            pendingCurve = []
        }

        func appendPendingPoints() {
            appendPendingCurve()
            if !currentPoints.isEmpty {
                sets.append(currentPoints)
                currentPoints = []
            }
        }

        for segment in segments {
            switch segment {
            case .move(let p):
                appendPendingPoints()
                start = p
                currentPoints.append(p)
            case .line(let p):
                appendPendingCurve()
                currentPoints.append(p)
            case .cubic(let c1, let c2, let p):
                if pendingCurve.isEmpty {
                    pendingCurve.append(currentPoints.last ?? start)
                }
                pendingCurve += [c1, c2, p]
            case .close:
                appendPendingCurve()
                currentPoints.append(start)
            }
        }
        appendPendingPoints()

        guard let distance, distance > 0 else { return sets }
        return sets.map { simplify($0, distance) }.filter { !$0.isEmpty }
    }

    private static func distanceSq(_ a: CGPoint, _ b: CGPoint) -> Double {
        pow(a.dx - b.dx, 2) + pow(a.dy - b.dy, 2)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.dx + (b.dx - a.dx) * t, y: a.dy + (b.dy - a.dy) * t)
    }

    private static func distanceToSegmentSq(_ p: CGPoint, _ v: CGPoint, _ w: CGPoint) -> Double {
        let l2 = distanceSq(v, w)
        if l2 == 0 { return distanceSq(p, v) }
        var t = ((p.dx - v.dx) * (w.dx - v.dx) + (p.dy - v.dy) * (w.dy - v.dy)) / l2
        t = max(0, min(1, t))
        return distanceSq(p, lerp(v, w, t))
    }

    private static func flatness(_ points: [CGPoint]) -> Double {
        let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]
        var ux = 3 * p2.dx - 2 * p1.dx - p4.dx
        ux *= ux
        var uy = 3 * p2.dy - 2 * p1.dy - p4.dy
        uy *= uy
        var vx = 3 * p3.dx - 2 * p4.dx - p1.dx
        vx *= vx
        var vy = 3 * p3.dy - 2 * p4.dy - p1.dy
        vy *= vy
        if ux < vx { ux = vx }
        if uy < vy { uy = vy }
        return ux + uy
    }

    private static func pointsOnBezierCurveWithSplitting(_ points: [CGPoint], _ tolerance: Double, _ out: inout [CGPoint], depth: Int) {
        // NaN coordinates never become flat. Cap the recursion instead.
        if flatness(points) < tolerance || depth > 24 {
            let p0 = points[0]
            if let last = out.last {
                if sqrt(distanceSq(last, p0)) > 1 { out.append(p0) }
            } else {
                out.append(p0)
            }
            out.append(points[3])
        } else {
            let t = 0.5
            let p1 = points[0], p2 = points[1], p3 = points[2], p4 = points[3]
            let q1 = lerp(p1, p2, t)
            let q2 = lerp(p2, p3, t)
            let q3 = lerp(p3, p4, t)
            let r1 = lerp(q1, q2, t)
            let r2 = lerp(q2, q3, t)
            let red = lerp(r1, r2, t)
            pointsOnBezierCurveWithSplitting([p1, q1, r1, red], tolerance, &out, depth: depth + 1)
            pointsOnBezierCurveWithSplitting([red, r2, q3, p4], tolerance, &out, depth: depth + 1)
        }
    }

    /// Ramer-Douglas-Peucker, as written in points-on-curve.
    private static func simplifyPoints(_ points: [CGPoint], _ start: Int, _ end: Int, _ epsilon: Double, _ out: inout [CGPoint]) {
        let s = points[start]
        let e = points[end - 1]
        var maxDistSq = 0.0
        var maxIndex = 1
        if start + 1 < end - 1 {
            for i in (start + 1)..<(end - 1) {
                let distSq = distanceToSegmentSq(points[i], s, e)
                if distSq > maxDistSq {
                    maxDistSq = distSq
                    maxIndex = i
                }
            }
        }
        if sqrt(maxDistSq) > epsilon {
            simplifyPoints(points, start, maxIndex + 1, epsilon, &out)
            simplifyPoints(points, maxIndex, end, epsilon, &out)
        } else {
            if out.isEmpty { out.append(s) }
            out.append(e)
        }
    }
}

// MARK: - Helpers

extension CGPoint {
    /// The coordinates as Double, for formulas ported from JavaScript.
    var dx: Double { Double(x) }
    var dy: Double { Double(y) }
}

extension Array where Element == RoughOp {
    func cgPath() -> CGPath {
        let path = CGMutablePath()
        for op in self {
            switch op {
            case .move(let p): path.move(to: p)
            case .lineTo(let p): path.addLine(to: p)
            case .curveTo(let c1, let c2, let p): path.addCurve(to: p, control1: c1, control2: c2)
            }
        }
        return path
    }
}
