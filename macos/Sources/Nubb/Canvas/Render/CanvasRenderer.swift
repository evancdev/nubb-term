import CoreGraphics
import Foundation

/// Draws a drawing into a CoreGraphics context.
///
/// Element shapes are built once per element version and cached, so a
/// redraw while panning or zooming only replays cached paths. Elements
/// outside the visible area are skipped.
final class CanvasRenderer {
    private struct CacheEntry {
        var version: Int
        var versionNonce: Int
        var fingerprint: Int
        var shape: CanvasShape
    }

    private var cache: [String: CacheEntry] = [:]

    private struct BoundsEntry {
        var version: Int
        var versionNonce: Int
        var bounds: CGRect
    }

    private var boundsCache: [String: BoundsEntry] = [:]

    var theme: CanvasTheme = .light

    /// Screen points per scene unit. Frame outlines keep the same width on
    /// screen at every zoom, as in Excalidraw. Exports use 1.
    var zoom: Double = 1

    /// The number of shapes built since creation. Tests use it to check
    /// that redraws hit the cache.
    private(set) var buildCount = 0

    init() {}

    /// The cached shape for `element`, built if missing or stale.
    ///
    /// An unchanged version is a hit. A new version is still a hit when the
    /// fields that shape the element are the same, so moving, rotating, or
    /// recoloring never rebuilds the hand-drawn paths. Callers invalidate
    /// elements replaced from the file, whose versions may not change.
    func shape(for element: CanvasElement) -> CanvasShape {
        if var entry = cache[element.id] {
            if entry.version == element.version && entry.versionNonce == element.versionNonce {
                return entry.shape
            }
            let fingerprint = Self.fingerprint(element)
            if fingerprint == entry.fingerprint {
                entry.version = element.version
                entry.versionNonce = element.versionNonce
                cache[element.id] = entry
                return entry.shape
            }
            return build(element, fingerprint: fingerprint)
        }
        return build(element, fingerprint: Self.fingerprint(element))
    }

    private func build(_ element: CanvasElement, fingerprint: Int) -> CanvasShape {
        let shape = CanvasShapeBuilder.shape(for: element)
        buildCount += 1
        cache[element.id] = CacheEntry(
            version: element.version, versionNonce: element.versionNonce,
            fingerprint: fingerprint, shape: shape)
        return shape
    }

    var cachedCount: Int { cache.count }

    /// Drops cached shapes of elements that no longer exist.
    func prune(keeping ids: Set<String>) {
        if cache.count > ids.count {
            cache = cache.filter { ids.contains($0.key) }
        }
        if boundsCache.count > ids.count {
            boundsCache = boundsCache.filter { ids.contains($0.key) }
        }
    }

    func invalidate(_ ids: Set<String>) {
        for id in ids {
            cache.removeValue(forKey: id)
            boundsCache.removeValue(forKey: id)
        }
    }

    func invalidateAll() {
        cache.removeAll()
        boundsCache.removeAll()
    }

    /// The area an element may paint, in scene coordinates: its box plus
    /// room for the stroke, the hand-drawn jitter, and glyph overhang.
    func paintBounds(of element: CanvasElement) -> CGRect {
        if element.type == .frame {
            // The outline keeps its screen width, so its room depends on the
            // zoom rather than the element version.
            let pad = CGFloat((FrameStyle.strokeWidth + 2) / zoom)
            return element.sceneBounds.insetBy(dx: -pad, dy: -pad)
        }
        if let entry = boundsCache[element.id],
           entry.version == element.version, entry.versionNonce == element.versionNonce {
            return entry.bounds
        }
        var pad = element.strokeWidth * 2 + element.roughness * 4 + 4
        if element.type == .text { pad += element.fontSize * 0.3 }
        if element.type == .arrow { pad += 4 }
        let bounds = element.sceneBounds.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad))
        boundsCache[element.id] = BoundsEntry(version: element.version, versionNonce: element.versionNonce, bounds: bounds)
        return bounds
    }

    private static func fingerprint(_ element: CanvasElement) -> Int {
        var hasher = Hasher()
        hasher.combine(element.type)
        hasher.combine(element.width)
        hasher.combine(element.height)
        hasher.combine(element.seed)
        hasher.combine(element.roughness)
        hasher.combine(element.strokeWidth)
        hasher.combine(element.strokeStyle)
        hasher.combine(element.fillStyle)
        hasher.combine(element.isTransparentBackground)
        hasher.combine(element.roundness?.type)
        hasher.combine(element.roundness?.value)
        hasher.combine(element.points.count)
        for point in element.points {
            hasher.combine(point.x)
            hasher.combine(point.y)
        }
        if element.type == .text {
            hasher.combine(element.text)
            hasher.combine(element.fontSize)
            hasher.combine(element.fontFamily)
            hasher.combine(element.textAlign)
            hasher.combine(element.lineHeight)
        }
        if element.type == .arrow {
            hasher.combine(element.startArrowhead)
            hasher.combine(element.endArrowhead)
        }
        if element.type == .freedraw {
            hasher.combine(element.simulatePressure)
            hasher.combine(element.pressures)
        }
        return hasher.finalize()
    }

    // MARK: Drawing

    /// Draws the elements that intersect `visible` (scene coordinates). The
    /// context must already map scene coordinates to its device space.
    /// Elements in `hidden` are skipped, e.g. text being edited. Elements in
    /// a frame are clipped to it.
    func draw(
        _ document: CanvasDocument,
        in context: CGContext,
        visible: CGRect,
        hidden: Set<String> = [],
        dimmed: Set<String> = []
    ) {
        let canvasColor = CanvasColor.cgColor(document.viewBackgroundColor, theme: theme)
        let membership = FrameMembership(document)
        let labels = ArrowLabels(document)
        for element in document.elements where !hidden.contains(element.id) {
            guard paintBounds(of: element).intersects(visible) else { continue }
            let alphaScale = dimmed.contains(element.id) ? 0.3 : 1
            if element.type == .frame {
                drawFrame(element, in: context, alphaScale: alphaScale)
                continue
            }
            let frame = membership.frame(of: element)
            let hole = labels.hole(for: element, hidden: hidden)
            if frame != nil || hole != nil {
                context.saveGState()
                if let frame {
                    context.addPath(Self.frameClipPath(frame, zoom: zoom))
                    context.clip()
                }
                if let hole {
                    // Excalidraw leaves a gap in an arrow where its label is.
                    let outer = paintBounds(of: element).union(hole).insetBy(dx: -8, dy: -8)
                    context.addRect(outer)
                    context.addRect(hole)
                    context.clip(using: .evenOdd)
                }
                draw(element, in: context, canvasColor: canvasColor, alphaScale: alphaScale)
                context.restoreGState()
            } else {
                draw(element, in: context, canvasColor: canvasColor, alphaScale: alphaScale)
            }
        }
    }

    /// The labels of arrows, for cutting the gap they sit in.
    struct ArrowLabels {
        private var labels: [String: CanvasElement] = [:]

        init(_ document: CanvasDocument) {
            var arrows = Set<String>()
            for element in document.elements where element.type == .arrow && element.boundTextID != nil {
                arrows.insert(element.id)
            }
            guard !arrows.isEmpty else { return }
            for element in document.elements where element.type == .text {
                if let container = element.containerId, arrows.contains(container), !element.text.isEmpty {
                    labels[container] = element
                }
            }
        }

        /// The area of `arrow` its label covers, padded as Excalidraw does.
        func hole(for arrow: CanvasElement, hidden: Set<String> = []) -> CGRect? {
            guard arrow.type == .arrow, let label = labels[arrow.id], !hidden.contains(label.id) else { return nil }
            let padding = CanvasGeometry.boundTextPadding
            let center = label.center
            return CGRect(
                x: center.x - label.width / 2 - padding, y: center.y - label.height / 2 - padding,
                width: label.width + padding * 2, height: label.height + padding * 2)
        }
    }

    func draw(_ element: CanvasElement, in context: CGContext, canvasColor: CGColor, alphaScale: Double = 1) {
        let shape = shape(for: element)
        let alpha = CGFloat(max(0, min(100, element.opacity)) / 100 * alphaScale)
        guard alpha > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Rotate about the element's center, then move to its origin.
        let center = element.center
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(element.angle))
        context.translateBy(x: CGFloat(element.x) - center.x, y: CGFloat(element.y) - center.y)

        context.setAlpha(alpha)
        if alpha < 1 {
            // Draw overlapping strokes as one layer, like a canvas with
            // globalAlpha does per element. The layer is as big as the
            // clip, so clip to the element first.
            let pad = CGFloat(element.strokeWidth * 2 + element.roughness * 4 + 4)
            context.clip(to: element.localBounds.insetBy(dx: -pad, dy: -pad))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if alpha < 1 { context.endTransparencyLayer() } }

        let stroke = CanvasColor.cgColor(element.strokeColor, theme: theme)
        let background = CanvasColor.cgColor(element.backgroundColor, theme: theme)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for part in shape.parts {
            let color: CGColor
            switch part.paint {
            case .stroke: color = stroke
            case .background: color = background
            case .canvas: color = canvasColor
            }
            context.addPath(part.path)
            if let width = part.lineWidth {
                context.setStrokeColor(color)
                context.setLineWidth(CGFloat(width))
                if let dash = part.dash {
                    context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
                } else {
                    context.setLineDash(phase: 0, lengths: [])
                }
                context.strokePath()
            } else {
                context.setFillColor(color)
                context.fillPath(using: part.evenOdd ? .evenOdd : .winding)
            }
        }

    }

    // MARK: Frames

    /// Excalidraw's `FRAME_STYLE` for the outline. Frame names aren't drawn:
    /// a frame's contents carry their own title.
    enum FrameStyle {
        static let strokeColor = "#bbbbbb"
        static let strokeWidth = 2.0
        static let radius = 8.0
    }

    /// The frame each element is clipped to: its own `frameId`, or for a
    /// label its container's.
    struct FrameMembership {
        private var frames: [String: CanvasElement] = [:]
        private var frameOf: [String: String] = [:]

        init(_ document: CanvasDocument) {
            for element in document.elements {
                if element.type == .frame { frames[element.id] = element }
                if let frameId = element.frameId { frameOf[element.id] = frameId }
            }
        }

        func frame(of element: CanvasElement) -> CanvasElement? {
            guard !frames.isEmpty else { return nil }
            let id = element.frameId ?? element.containerId.flatMap { frameOf[$0] }
            return id.flatMap { frames[$0] }
        }
    }

    static func frameClipPath(_ frame: CanvasElement, zoom: Double) -> CGPath {
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).standardized
        let radius = CGFloat(min(FrameStyle.radius / zoom, Double(min(rect.width, rect.height)) / 2))
        return CGPath(roundedRect: rect, cornerWidth: max(radius, 0), cornerHeight: max(radius, 0), transform: nil)
    }

    /// The frame's outline.
    private func drawFrame(_ frame: CanvasElement, in context: CGContext, alphaScale: Double) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(max(0, min(100, frame.opacity)) / 100 * alphaScale))
        context.addPath(Self.frameClipPath(frame, zoom: zoom))
        context.setStrokeColor(CanvasColor.cgColor(FrameStyle.strokeColor, theme: theme))
        context.setLineWidth(CGFloat(FrameStyle.strokeWidth / zoom))
        context.strokePath()
    }

    /// The name a frame is found by, in commands and lint messages: its
    /// `name`, or "Frame" as Excalidraw calls an unnamed one.
    static func frameTitle(_ frame: CanvasElement) -> String {
        frame.frameName ?? "Frame"
    }
}

// MARK: - Export

extension CanvasRenderer {
    /// Renders `document` to an image at `scale` pixels per scene unit,
    /// with `padding` around the drawing. Used by tests and export.
    static func image(
        of document: CanvasDocument,
        scale: CGFloat = 2,
        padding: CGFloat = 20,
        theme: CanvasTheme = .light,
        background: Bool = true
    ) -> CGImage? {
        let bounds = sceneBounds(of: document.elements)
        guard !bounds.isNull, bounds.width > 0 || bounds.height > 0 else { return nil }
        let frame = bounds.insetBy(dx: -padding, dy: -padding)
        let width = Int(ceil(frame.width * scale)), height = Int(ceil(frame.height * scale))
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Flip to y-down scene coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.setShouldAntialias(true)

        if background {
            context.setFillColor(CanvasColor.cgColor(document.viewBackgroundColor, theme: theme))
            context.fill(frame)
        }

        let renderer = CanvasRenderer()
        renderer.theme = theme
        renderer.draw(document, in: context, visible: frame)
        return context.makeImage()
    }

    /// The box around all `elements` in scene coordinates.
    static func sceneBounds(of elements: [CanvasElement]) -> CGRect {
        elements.reduce(CGRect.null) { $0.union($1.sceneBounds) }
    }
}
