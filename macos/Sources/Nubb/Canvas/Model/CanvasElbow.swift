import CoreGraphics
import Foundation

/// Right-angled routes for elbow arrows: out of the start shape along a
/// side, across, and into the end shape along a side. Excalidraw routes
/// around obstacles when it edits one; these routes only need to be valid
/// elbow paths it accepts, with every segment horizontal or vertical.
enum CanvasElbow {
    enum Heading: Equatable {
        case up
        case down
        case left
        case right

        var vector: CGVector {
            switch self {
            case .up: CGVector(dx: 0, dy: -1)
            case .down: CGVector(dx: 0, dy: 1)
            case .left: CGVector(dx: -1, dy: 0)
            case .right: CGVector(dx: 1, dy: 0)
            }
        }

        var isHorizontal: Bool { self == .left || self == .right }

        var opposite: Heading {
            switch self {
            case .up: .down
            case .down: .up
            case .left: .right
            case .right: .left
            }
        }
    }

    /// How far a route leaves a shape before it turns.
    static let padding = 24.0

    /// The side of `element` a binding's fixed point is on, as the
    /// direction out of the shape.
    static func heading(of binding: CanvasBinding, on element: CanvasElement) -> Heading? {
        guard let fixed = binding.fixedPoint else { return nil }
        let px = Double(fixed.x) * element.width, py = Double(fixed.y) * element.height
        let sides: [(Heading, Double)] = [
            (.left, abs(px)), (.right, abs(px - element.width)),
            (.up, abs(py)), (.down, abs(py - element.height)),
        ]
        return sides.min { $0.1 < $1.1 }?.0
    }

    /// The heading from `a` toward `b` along the axis they differ most on.
    static func heading(from a: CGPoint, to b: CGPoint) -> Heading {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .down : .up
    }

    /// A route from `a`, leaving along `startHeading`, to `b`, arriving
    /// against `endHeading` (the direction out of the end shape). Missing
    /// headings face each other along the axis the ends differ most on.
    static func route(from a: CGPoint, heading startHeading: Heading?, to b: CGPoint, heading endHeading: Heading?) -> [CGPoint] {
        let ha = startHeading ?? endHeading?.opposite ?? heading(from: a, to: b)
        let hb = endHeading ?? ha.opposite
        let sa = CGPoint(x: a.x + ha.vector.dx * padding, y: a.y + ha.vector.dy * padding)
        let eb = CGPoint(x: b.x + hb.vector.dx * padding, y: b.y + hb.vector.dy * padding)
        var points: [CGPoint]

        if ha.isHorizontal == hb.isHorizontal {
            // Both ends on the same axis: a Z, a U, or around.
            let horizontal = ha.isHorizontal
            func along(_ p: CGPoint) -> Double { Double(horizontal ? p.x : p.y) }
            func across(_ p: CGPoint) -> Double { Double(horizontal ? p.y : p.x) }
            func point(_ main: Double, _ cross: Double) -> CGPoint {
                horizontal ? CGPoint(x: main, y: cross) : CGPoint(x: cross, y: main)
            }
            let sign = Double(horizontal ? ha.vector.dx : ha.vector.dy)
            let ahead = (along(b) - along(a)) * sign > 0
            if hb == ha.opposite, ahead {
                let mid = (along(a) + along(b)) / 2
                points = [a, point(mid, across(a)), point(mid, across(b)), b]
            } else if hb == ha {
                let out = sign > 0 ? max(along(sa), along(eb)) : min(along(sa), along(eb))
                points = [a, point(out, across(a)), point(out, across(b)), b]
            } else {
                let mid = (across(a) + across(b)) / 2
                points = [a, sa, point(along(sa), mid), point(along(eb), mid), eb, b]
            }
        } else if ha.isHorizontal {
            // Across, then down or up into the end.
            let corner = CGPoint(x: b.x, y: a.y)
            let leaves = Double(b.x - a.x) * Double(ha.vector.dx) > 0
            let arrives = Double(a.y - b.y) * Double(hb.vector.dy) > 0
            points = leaves && arrives ? [a, corner, b] : [a, sa, CGPoint(x: sa.x, y: eb.y), eb, b]
        } else {
            let corner = CGPoint(x: a.x, y: b.y)
            let leaves = Double(b.y - a.y) * Double(ha.vector.dy) > 0
            let arrives = Double(a.x - b.x) * Double(hb.vector.dx) > 0
            points = leaves && arrives ? [a, corner, b] : [a, sa, CGPoint(x: eb.x, y: sa.y), eb, b]
        }
        return simplify(points)
    }

    /// Drops repeated points and points in the middle of straight runs.
    static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, same(last.x, point.x), same(last.y, point.y) { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if (same(a.x, b.x) && same(b.x, point.x)) || (same(a.y, b.y) && same(b.y, point.y)) {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        if result.count == 1 { result.append(result[0]) }
        return result
    }
}
