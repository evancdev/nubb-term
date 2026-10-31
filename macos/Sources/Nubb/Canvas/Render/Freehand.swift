// A Swift port of perfect-freehand 1.2 (MIT, Copyright (c) 2021 Stephen
// Ruiz Ltd), which Excalidraw uses to turn freehand points into a filled
// outline. Only the options Excalidraw sets are supported.

import CoreGraphics
import Foundation

enum Freehand {
    struct Options {
        var size: Double = 16
        var thinning: Double = 0.5
        var smoothing: Double = 0.5
        var streamline: Double = 0.5
        var simulatePressure = true
        var easing: (Double) -> Double = { $0 }
        /// Whether the stroke is finished. The last point is then used as is.
        var last = false

        /// What Excalidraw uses for a freehand element.
        static func excalidraw(strokeWidth: Double, simulatePressure: Bool) -> Options {
            var options = Options()
            options.size = strokeWidth * 4.25
            options.thinning = 0.6
            options.smoothing = 0.5
            options.streamline = 0.5
            options.simulatePressure = simulatePressure
            options.easing = { sin(($0 * Double.pi) / 2) }
            options.last = true
            return options
        }
    }

    struct StrokePoint {
        var point: CGPoint
        var pressure: Double
        var vector: CGPoint
        var distance: Double
        var runningLength: Double
    }

    private static let rateOfPressureChange = 0.275
    private static let fixedPi = Double.pi + 0.0001
    private static let startCapSegments = 13.0
    private static let endCapSegments = 29.0
    private static let cornerCapSegments = 13.0
    private static let endNoiseThreshold = 3.0
    private static let minStreamlineT = 0.15
    private static let streamlineTRange = 0.85
    private static let minRadius = 0.01
    private static let defaultFirstPressure = 0.25
    private static let defaultPressure = 0.5

    /// The outline polygon of a stroke through `points` with optional
    /// per-point `pressures` (0...1).
    static func outline(points: [CGPoint], pressures: [Double]?, options: Options) -> [CGPoint] {
        let input: [(CGPoint, Double?)] = points.enumerated().map { index, point in
            (point, pressures.flatMap { $0.indices.contains(index) ? $0[index] : nil })
        }
        return outlinePoints(strokePoints(input, options), options)
    }

    // MARK: Vector math

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func mul(_ a: CGPoint, _ n: Double) -> CGPoint { CGPoint(x: a.dx * n, y: a.dy * n) }
    private static func div(_ a: CGPoint, _ n: Double) -> CGPoint { CGPoint(x: a.dx / n, y: a.dy / n) }
    private static func per(_ a: CGPoint) -> CGPoint { CGPoint(x: a.y, y: -a.x) }
    private static func neg(_ a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    private static func dpr(_ a: CGPoint, _ b: CGPoint) -> Double { a.dx * b.dx + a.dy * b.dy }
    private static func len(_ a: CGPoint) -> Double { hypot(a.dx, a.dy) }
    private static func uni(_ a: CGPoint) -> CGPoint { div(a, len(a)) }
    private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.dy - b.dy, a.dx - b.dx) }
    private static func dist2(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.dx - b.dx, dy = a.dy - b.dy
        return dx * dx + dy * dy
    }
    private static func lrp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { add(a, mul(sub(b, a), t)) }
    private static func prj(_ a: CGPoint, _ b: CGPoint, _ c: Double) -> CGPoint { add(a, mul(b, c)) }
    private static func rotAround(_ a: CGPoint, _ c: CGPoint, _ r: Double) -> CGPoint {
        let s = sin(r), co = cos(r)
        let px = a.dx - c.dx, py = a.dy - c.dy
        return CGPoint(x: px * co - py * s + c.dx, y: px * s + py * co + c.dy)
    }

    private static func strokeRadius(_ size: Double, _ thinning: Double, _ pressure: Double, _ easing: (Double) -> Double) -> Double {
        size * easing(0.5 - thinning * (0.5 - pressure))
    }

    private static func simulate(_ prevPressure: Double, _ distance: Double, _ size: Double) -> Double {
        let sp = min(1, distance / size)
        let rp = min(1, 1 - sp)
        return min(1, prevPressure + (rp - prevPressure) * (sp * rateOfPressureChange))
    }

    // MARK: Stroke points

    private static func strokePoints(_ input: [(CGPoint, Double?)], _ options: Options) -> [StrokePoint] {
        guard !input.isEmpty else { return [] }
        let t = minStreamlineT + (1 - options.streamline) * streamlineTRange
        var pts = input

        if pts.count == 2 {
            let last = pts[1]
            pts = [pts[0]]
            for i in 1..<5 {
                pts.append((lrp(pts[0].0, last.0, Double(i) / 4), last.1))
            }
        }
        if pts.count == 1 {
            pts.append((add(pts[0].0, CGPoint(x: 1, y: 1)), pts[0].1))
        }

        func validPressure(_ value: Double?) -> Double? {
            guard let value, value >= 0 else { return nil }
            return value
        }

        var result: [StrokePoint] = [StrokePoint(
            point: pts[0].0,
            pressure: validPressure(pts[0].1) ?? defaultFirstPressure,
            vector: CGPoint(x: 1, y: 1),
            distance: 0,
            runningLength: 0)]

        var hasReachedMinimumLength = false
        var runningLength = 0.0
        var prev = result[0]
        let maxIndex = pts.count - 1

        for i in 1..<pts.count {
            let point = options.last && i == maxIndex ? pts[i].0 : lrp(prev.point, pts[i].0, t)
            if point == prev.point { continue }
            let distance = dist(point, prev.point)
            runningLength += distance
            if i < maxIndex && !hasReachedMinimumLength {
                if runningLength < options.size { continue }
                hasReachedMinimumLength = true
            }
            prev = StrokePoint(
                point: point,
                pressure: validPressure(pts[i].1) ?? defaultPressure,
                vector: uni(sub(prev.point, point)),
                distance: distance,
                runningLength: runningLength)
            result.append(prev)
        }

        result[0].vector = result.count > 1 ? result[1].vector : .zero
        return result
    }

    // MARK: Outline

    private static func outlinePoints(_ points: [StrokePoint], _ options: Options) -> [CGPoint] {
        let size = options.size
        guard !points.isEmpty, size > 0 else { return [] }

        let thinning = options.thinning
        let easing = options.easing
        let totalLength = points[points.count - 1].runningLength
        let minDistance = pow(size * options.smoothing, 2)

        var leftPts: [CGPoint] = []
        var rightPts: [CGPoint] = []

        var prevPressure = points.prefix(10).reduce(points[0].pressure) { acc, curr in
            var pressure = curr.pressure
            if options.simulatePressure {
                pressure = simulate(acc, curr.distance, size)
            }
            return (acc + pressure) / 2
        }

        var radius = strokeRadius(size, thinning, points[points.count - 1].pressure, easing)
        var firstRadius: Double?
        var prevVector = points[0].vector
        var prevLeftPoint = points[0].point
        var prevRightPoint = prevLeftPoint
        var tempLeftPoint = prevLeftPoint
        var tempRightPoint = prevRightPoint
        var isPrevPointSharpCorner = false

        for i in 0..<points.count {
            var pressure = points[i].pressure
            let point = points[i].point
            let vector = points[i].vector
            let distance = points[i].distance
            let runningLength = points[i].runningLength
            let isLastPoint = i == points.count - 1

            if !isLastPoint && totalLength - runningLength < endNoiseThreshold { continue }

            if thinning != 0 {
                if options.simulatePressure {
                    pressure = simulate(prevPressure, distance, size)
                }
                radius = strokeRadius(size, thinning, pressure, easing)
            } else {
                radius = size / 2
            }
            if firstRadius == nil { firstRadius = radius }

            // Excalidraw doesn't taper, so both taper strengths are 1.
            radius = max(minRadius, radius)

            let nextVector = (!isLastPoint ? points[i + 1] : points[i]).vector
            let nextDpr = !isLastPoint ? dpr(vector, nextVector) : 1.0
            let prevDpr = dpr(vector, prevVector)
            let isPointSharpCorner = prevDpr < 0 && !isPrevPointSharpCorner
            let isNextPointSharpCorner = nextDpr < 0

            if isPointSharpCorner || isNextPointSharpCorner {
                let offset = mul(per(prevVector), radius)
                let step = 1 / cornerCapSegments
                var t = 0.0
                while t <= 1 {
                    tempLeftPoint = rotAround(sub(point, offset), point, fixedPi * t)
                    leftPts.append(tempLeftPoint)
                    tempRightPoint = rotAround(add(point, offset), point, fixedPi * -t)
                    rightPts.append(tempRightPoint)
                    t += step
                }
                prevLeftPoint = tempLeftPoint
                prevRightPoint = tempRightPoint
                if isNextPointSharpCorner { isPrevPointSharpCorner = true }
                continue
            }

            isPrevPointSharpCorner = false

            if isLastPoint {
                let offset = mul(per(vector), radius)
                leftPts.append(sub(point, offset))
                rightPts.append(add(point, offset))
                continue
            }

            let offset = mul(per(lrp(nextVector, vector, nextDpr)), radius)
            tempLeftPoint = sub(point, offset)
            if i <= 1 || dist2(prevLeftPoint, tempLeftPoint) > minDistance {
                leftPts.append(tempLeftPoint)
                prevLeftPoint = tempLeftPoint
            }
            tempRightPoint = add(point, offset)
            if i <= 1 || dist2(prevRightPoint, tempRightPoint) > minDistance {
                rightPts.append(tempRightPoint)
                prevRightPoint = tempRightPoint
            }

            prevPressure = pressure
            prevVector = vector
        }

        let firstPoint = points[0].point
        let lastPoint = points.count > 1 ? points[points.count - 1].point : add(points[0].point, CGPoint(x: 1, y: 1))

        if points.count == 1 {
            return drawDot(firstPoint, firstRadius ?? radius)
        }

        var startCap: [CGPoint] = []
        if let right = rightPts.first {
            let step = 1 / startCapSegments
            var t = step
            while t <= 1 {
                startCap.append(rotAround(right, firstPoint, fixedPi * t))
                t += step
            }
        }

        var endCap: [CGPoint] = []
        let direction = per(neg(points[points.count - 1].vector))
        let start = prj(lastPoint, direction, radius)
        let step = 1 / endCapSegments
        var t = step
        while t < 1 {
            endCap.append(rotAround(start, lastPoint, fixedPi * 3 * t))
            t += step
        }

        return leftPts + endCap + rightPts.reversed() + startCap
    }

    private static func drawDot(_ center: CGPoint, _ radius: Double) -> [CGPoint] {
        let offsetPoint = add(center, CGPoint(x: 1, y: 1))
        let start = prj(center, uni(per(sub(center, offsetPoint))), -radius)
        var points: [CGPoint] = []
        let step = 1 / startCapSegments
        var t = step
        while t <= 1 {
            points.append(rotAround(start, center, fixedPi * 2 * t))
            t += step
        }
        return points
    }

    /// The closed path Excalidraw fills: quadratic curves through the
    /// midpoints of the outline.
    static func path(outline points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 0..<points.count {
            let point = points[i]
            let next = i == points.count - 1 ? points[0] : points[i + 1]
            let mid = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: point)
        }
        path.addLine(to: first)
        path.closeSubpath()
        return path
    }
}
