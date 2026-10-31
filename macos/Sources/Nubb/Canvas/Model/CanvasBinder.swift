import CoreGraphics
import Foundation

/// Attaching arrow ends to shapes, a simplified version of Excalidraw's
/// binding. A bound end points at the shape's focus point and stops `gap`
/// units outside its outline, and follows the shape when it moves.
enum CanvasBinder {
    static let defaultGap = 6.0

    /// How close an arrow end must be to a shape to attach to it, in scene
    /// units (Excalidraw's `maxBindingGap`).
    static func bindingDistance(for element: CanvasElement, zoom: Double) -> Double {
        let ratio = element.type == .diamond ? 1 / sqrt(2) : 1
        let smaller = ratio * min(abs(element.width), abs(element.height))
        let zoomValue = zoom < 1 ? zoom : 1
        return max(16, min(0.25 * smaller, 32), 10 / zoomValue + 4)
    }

    /// The topmost shape an arrow end at `point` would attach to.
    static func target(at point: CGPoint, in document: CanvasDocument, excluding: Set<String>, zoom: Double) -> CanvasElement? {
        for element in document.elements.reversed() where element.isBindable && !excluding.contains(element.id) {
            let distance = bindingDistance(for: element, zoom: zoom)
            if element.hitTest(point, threshold: distance) || element.sceneBounds.contains(point) {
                return element
            }
        }
        return nil
    }

    /// Where an arrow end bound to `element` goes when the arrow's next point
    /// is `adjacent` (scene coordinates). Ends of elbow arrows and `inside`
    /// bindings sit on their fixed point; `orbit` bindings aim at it and
    /// stop outside the outline, as in Excalidraw.
    static func endPoint(adjacent: CGPoint, element: CanvasElement, binding: CanvasBinding, elbow: Bool = false) -> CGPoint {
        if binding.fixedPoint != nil {
            let target = focusPoint(of: binding, on: element)
            guard binding.mode == "orbit", !elbow else { return target }
            return outlinePoint(toward: target, from: adjacent, element: element, gap: CanvasBinding.orbitGap(for: element))
        }

        let focus = focusPoint(element: element, focus: binding.focus, adjacent: adjacent)
        return outlinePoint(toward: focus, from: adjacent, element: element, gap: binding.gap)
    }

    /// The point a binding aims at: its fixed point, or the center.
    static func focusPoint(of binding: CanvasBinding, on element: CanvasElement) -> CGPoint {
        guard let fixed = binding.fixedPoint else { return element.center }
        return element.toScene(CGPoint(x: fixed.dx * element.width, y: fixed.dy * element.height))
    }

    /// Where the line from `adjacent` to `focus` crosses the outline, `gap`
    /// units outside it. An adjacent point inside the shape can't reach the
    /// outline from outside, so it gets the focus itself.
    static func outlinePoint(toward focus: CGPoint, from adjacent: CGPoint, element: CanvasElement, gap: Double) -> CGPoint {
        if element.outlinePath.contains(element.toLocal(adjacent)) {
            return focus
        }
        let center = element.center
        let direction = CGPoint(x: focus.dx - adjacent.dx, y: focus.dy - adjacent.dy)
        let length = hypot(direction.dx, direction.dy)
        guard length > 0.001 else { return focus }
        let unit = CGPoint(x: direction.dx / length, y: direction.dy / length)
        let reach = length + hypot(adjacent.dx - center.dx, adjacent.dy - center.dy)
            + max(abs(element.width), abs(element.height)) * 2
        let far = CGPoint(x: adjacent.dx + unit.dx * reach, y: adjacent.dy + unit.dy * reach)

        guard let hit = firstIntersection(element: element, from: adjacent, to: far) else { return focus }
        let gap = max(gap, 0)
        return CGPoint(x: hit.dx - unit.dx * gap, y: hit.dy - unit.dy * gap)
    }

    /// The point inside the shape the arrow aims at. Focus 0 is the center;
    /// other values shift the aim sideways, perpendicular to the arrow.
    static func focusPoint(element: CanvasElement, focus: Double, adjacent: CGPoint) -> CGPoint {
        let center = element.center
        guard focus != 0 else { return center }
        let dx = center.dx - adjacent.dx, dy = center.dy - adjacent.dy
        let length = hypot(dx, dy)
        guard length > 0 else { return center }
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let half = min(abs(element.width), abs(element.height)) / 2
        let offset = max(-1, min(1, focus)) * half
        return CGPoint(x: center.dx + normal.dx * offset, y: center.dy + normal.dy * offset)
    }

    /// The focus that keeps an arrow aimed where it was drawn: the arrow
    /// runs from `adjacent` through `end`, and the focus is how far that
    /// line passes beside the center (the inverse of `focusPoint`).
    static func focus(element: CanvasElement, adjacent: CGPoint, end: CGPoint) -> Double {
        let center = element.center
        let ux = center.dx - adjacent.dx, uy = center.dy - adjacent.dy
        let vx = end.dx - adjacent.dx, vy = end.dy - adjacent.dy
        let uu = ux * ux + uy * uy
        let vu = vx * ux + vy * uy
        let half = min(abs(element.width), abs(element.height)) / 2
        guard uu > 0, vu > 0, half > 0 else { return 0 }
        // Where the arrow line crosses the line through the center
        // perpendicular to the direction from `adjacent` to the center.
        let t = uu / vu
        let px = adjacent.dx + t * vx, py = adjacent.dy + t * vy
        let length = sqrt(uu)
        let offset = (px - center.dx) * (-uy / length) + (py - center.dy) * (ux / length)
        return max(-1, min(1, offset / half))
    }

    /// The first point where the segment `a`-`b` crosses the element's
    /// outline (scene coordinates).
    static func firstIntersection(element: CanvasElement, from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let la = element.toLocal(a), lb = element.toLocal(b)
        var best: (t: Double, point: CGPoint)?

        func consider(_ t: Double) {
            guard t >= 0, t <= 1 else { return }
            if best == nil || t < best!.t {
                best = (t, CGPoint(x: la.dx + (lb.dx - la.dx) * t, y: la.dy + (lb.dy - la.dy) * t))
            }
        }

        switch element.type {
        case .ellipse:
            let rx = abs(element.width) / 2, ry = abs(element.height) / 2
            guard rx > 0, ry > 0 else { return nil }
            let ox = la.dx - rx, oy = la.dy - ry
            let dx = lb.dx - la.dx, dy = lb.dy - la.dy
            let qa = dx * dx / (rx * rx) + dy * dy / (ry * ry)
            let qb = 2 * (ox * dx / (rx * rx) + oy * dy / (ry * ry))
            let qc = ox * ox / (rx * rx) + oy * oy / (ry * ry) - 1
            let disc = qb * qb - 4 * qa * qc
            guard qa > 0, disc >= 0 else { return nil }
            let root = sqrt(disc)
            consider((-qb - root) / (2 * qa))
            consider((-qb + root) / (2 * qa))
        default:
            let polygon: [CGPoint]
            if element.type == .diamond {
                polygon = CanvasGeometry.diamondPoints(width: element.width, height: element.height)
            } else {
                let box = element.localBounds
                polygon = [
                    CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                ]
            }
            for i in 0..<polygon.count {
                if let t = segmentIntersection(la, lb, polygon[i], polygon[(i + 1) % polygon.count]) {
                    consider(t)
                }
            }
        }

        guard let best else { return nil }
        return element.toScene(best.point)
    }

    /// The parameter along `p1`-`p2` where it crosses `p3`-`p4`.
    static func segmentIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Double? {
        let d = (p2.dx - p1.dx) * (p4.dy - p3.dy) - (p2.dy - p1.dy) * (p4.dx - p3.dx)
        guard abs(d) > 1e-12 else { return nil }
        let t = ((p3.dx - p1.dx) * (p4.dy - p3.dy) - (p3.dy - p1.dy) * (p4.dx - p3.dx)) / d
        let u = ((p3.dx - p1.dx) * (p2.dy - p1.dy) - (p3.dy - p1.dy) * (p2.dx - p1.dx)) / d
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return t
    }
}
