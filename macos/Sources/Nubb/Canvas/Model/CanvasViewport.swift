import CoreGraphics
import Foundation

/// The visible part of the canvas: `screen = scene * zoom + offset`.
struct CanvasViewport: Equatable {
    static let minZoom = 0.1
    static let maxZoom = 30.0

    var zoom: Double = 1
    var offset: CGPoint = .zero

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.dx * zoom + offset.dx, y: point.dy * zoom + offset.dy)
    }

    func toScene(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.dx - offset.dx) / zoom, y: (point.dy - offset.dy) / zoom)
    }

    func toScreen(_ rect: CGRect) -> CGRect {
        let origin = toScreen(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    func toScene(_ rect: CGRect) -> CGRect {
        let origin = toScene(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width / zoom, height: rect.height / zoom)
    }

    /// The scene-to-screen transform.
    var transform: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.dx, ty: offset.dy)
    }

    static func clamp(_ zoom: Double) -> Double {
        min(max(zoom, minZoom), maxZoom)
    }

    /// Zooms to `newZoom`, keeping the scene point under `anchor` (screen
    /// coordinates) in place.
    mutating func zoom(to newZoom: Double, around anchor: CGPoint) {
        let scenePoint = toScene(anchor)
        zoom = Self.clamp(newZoom)
        offset = CGPoint(x: anchor.dx - scenePoint.dx * zoom, y: anchor.dy - scenePoint.dy * zoom)
    }

    /// Excalidraw's zoom steps: 10% at a time, snapped to the step.
    static func steppedZoom(from zoom: Double, in zoomIn: Bool) -> Double {
        let step = 0.1
        let next = zoomIn ? zoom + step : zoom - step
        return clamp((next / step).rounded() * step)
    }

    /// A viewport that shows `content` centered in a view of `size`, zoomed
    /// out to fit but never zoomed in past 100%.
    static func fitting(_ content: CGRect, in size: CGSize, padding: Double = 40, maxZoom: Double = 1) -> CanvasViewport {
        guard !content.isNull, !content.isEmpty || content.width > 0 || content.height > 0,
              size.width > 0, size.height > 0 else {
            return CanvasViewport()
        }
        let availableWidth = max(Double(size.width) - padding * 2, 1)
        let availableHeight = max(Double(size.height) - padding * 2, 1)
        let zoomX = content.width > 0 ? availableWidth / Double(content.width) : maxZoom
        let zoomY = content.height > 0 ? availableHeight / Double(content.height) : maxZoom
        let zoom = clamp(min(zoomX, zoomY, maxZoom))
        let offset = CGPoint(
            x: Double(size.width) / 2 - Double(content.midX) * zoom,
            y: Double(size.height) / 2 - Double(content.midY) * zoom)
        return CanvasViewport(zoom: zoom, offset: offset)
    }
}
