import CoreGraphics
import Foundation

/// Excalidraw's geometry rules for elements: local boxes, rotation about the
/// center, corner radii, and the outlines used for hit testing.
enum CanvasGeometry {
    static let proportionalRadius = 0.25
    static let adaptiveRadius = 32.0
    static let boundTextPadding = 5.0
    static let lineConfirmThreshold = 8.0

    /// Excalidraw's `getCornerRadius`.
    static func cornerRadius(_ size: Double, roundness: CanvasRoundness?) -> Double {
        guard let roundness else { return 0 }
        switch roundness.type {
        case 1, 2:
            return size * proportionalRadius
        case 3:
            let fixed = roundness.value ?? adaptiveRadius
            let cutoff = fixed / proportionalRadius
            return size <= cutoff ? size * proportionalRadius : fixed
        default:
            return 0
        }
    }

    /// Excalidraw's `isPathALoop`: a line whose ends meet is closed.
    static func isLoop(_ points: [CGPoint]) -> Bool {
        guard points.count >= 3, let first = points.first, let last = points.last else { return false }
        return hypot(first.dx - last.dx, first.dy - last.dy) <= lineConfirmThreshold
    }

    /// Excalidraw's `getDiamondPoints`: top, right, bottom, left.
    static func diamondPoints(width: Double, height: Double) -> [CGPoint] {
        let topX = floor(width / 2) + 1
        let rightY = floor(height / 2) + 1
        return [
            CGPoint(x: topX, y: 0),
            CGPoint(x: width, y: rightY),
            CGPoint(x: topX, y: height),
            CGPoint(x: 0, y: rightY),
        ]
    }

    static func rotate(_ point: CGPoint, around center: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return point }
        let c = cos(angle), s = sin(angle)
        let dx = point.dx - center.dx, dy = point.dy - center.dy
        return CGPoint(x: center.dx + dx * c - dy * s, y: center.dy + dx * s + dy * c)
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The distance from `p` to the segment `a`-`b`.
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.dx - a.dx, dy = b.dy - a.dy
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(p.dx - a.dx, p.dy - a.dy) }
        let t = max(0, min(1, ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lengthSq))
        return hypot(p.dx - (a.dx + t * dx), p.dy - (a.dy + t * dy))
    }

    static func snapAngle(_ angle: Double, step: Double = Double.pi / 12) -> Double {
        (angle / step).rounded() * step
    }

    /// An angle in 0..<2π.
    static func normalizedAngle(_ angle: Double) -> Double {
        let full = Double.pi * 2
        let value = angle.truncatingRemainder(dividingBy: full)
        return value < 0 ? value + full : value
    }
}

// MARK: - Element geometry

extension CanvasElement {
    /// The element's box in its own coordinates, where (0, 0) is (`x`, `y`).
    /// Points-based elements can extend left of or above their origin.
    var localBounds: CGRect {
        if type.hasPoints {
            return CanvasGeometry.bounds(of: points.isEmpty ? [.zero] : points)
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// The rotation center in scene coordinates.
    var center: CGPoint {
        let box = localBounds
        return CGPoint(x: x + Double(box.midX), y: y + Double(box.midY))
    }

    /// Converts a scene point to this element's unrotated local coordinates.
    func toLocal(_ point: CGPoint) -> CGPoint {
        let unrotated = CanvasGeometry.rotate(point, around: center, by: -angle)
        return CGPoint(x: unrotated.dx - x, y: unrotated.dy - y)
    }

    /// Converts a local point to scene coordinates.
    func toScene(_ point: CGPoint) -> CGPoint {
        CanvasGeometry.rotate(CGPoint(x: point.dx + x, y: point.dy + y), around: center, by: angle)
    }

    /// The four corners of the local box in scene coordinates.
    var sceneCorners: [CGPoint] {
        let box = localBounds
        return [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ].map(toScene)
    }

    /// The axis-aligned box around the rotated element in scene coordinates.
    var sceneBounds: CGRect {
        if type.hasPoints && angle != 0 {
            return CanvasGeometry.bounds(of: points.map(toScene))
        }
        if angle == 0 {
            return localBounds.offsetBy(dx: x, dy: y)
        }
        return CanvasGeometry.bounds(of: sceneCorners)
    }

    /// Whether arrows can attach to this element.
    var isBindable: Bool { type.isBindable && containerId == nil }

    /// Whether the element has a visible background that counts for clicks.
    var hasFill: Bool {
        if type == .text || type == .image { return true }
        if isTransparentBackground { return false }
        if type.isContainer { return true }
        if type.hasPoints { return CanvasGeometry.isLoop(points) }
        return false
    }

    /// The element's outline without the hand-drawn jitter, in local
    /// coordinates. Used for hit testing and binding.
    var outlinePath: CGPath {
        let path = CGMutablePath()
        let box = localBounds
        switch type {
        case .rectangle:
            let radius = CanvasGeometry.cornerRadius(min(width, height), roundness: roundness)
            let r = CGFloat(max(0, min(radius, min(abs(width), abs(height)) / 2)))
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: abs(width), height: abs(height)), cornerWidth: r, cornerHeight: r)
        case .ellipse:
            path.addEllipse(in: CGRect(x: 0, y: 0, width: width, height: height))
        case .diamond:
            path.addLines(between: CanvasGeometry.diamondPoints(width: width, height: height))
            path.closeSubpath()
        case .line, .arrow, .freedraw:
            let pts = points.isEmpty ? [CGPoint.zero] : points
            path.addLines(between: pts)
            if hasFill { path.closeSubpath() }
        default:
            path.addRect(box)
        }
        return path
    }

    /// Whether `point` (scene coordinates) hits this element. `threshold` is
    /// the click tolerance in scene units.
    func hitTest(_ point: CGPoint, threshold: Double) -> Bool {
        let pad = CGFloat(threshold + strokeWidth)
        guard sceneBounds.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
        let local = toLocal(point)

        switch type {
        case .text, .image:
            return localBounds.insetBy(dx: -CGFloat(threshold), dy: -CGFloat(threshold)).contains(local)
        case .frame:
            // Frames are picked by their border, so clicks inside reach
            // what the frame holds.
            let box = localBounds
            return box.insetBy(dx: -CGFloat(threshold), dy: -CGFloat(threshold)).contains(local)
                && !box.insetBy(dx: CGFloat(threshold), dy: CGFloat(threshold)).contains(local)
        case .other:
            return localBounds.contains(local)
        default:
            break
        }

        let outline = outlinePath
        if hasFill && outline.contains(local, using: .evenOdd) {
            return true
        }
        let width = CGFloat(max(threshold * 2, 1) + strokeWidth)
        let stroked = outline.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return stroked.contains(local)
    }

    /// Whether the element lies fully inside `rect` (scene coordinates).
    func isInside(_ rect: CGRect) -> Bool {
        rect.contains(sceneBounds)
    }
}
