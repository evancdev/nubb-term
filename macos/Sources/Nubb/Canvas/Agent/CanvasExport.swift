import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders drawings to PNG, PDF, and SVG with the same shapes, fonts, and
/// frame clipping the viewer draws, so a render shows what the engineer
/// sees.
enum CanvasExport {
    enum Format: String {
        case png
        case svg
        case pdf

        init?(path: String) {
            self.init(rawValue: (path as NSString).pathExtension.lowercased())
        }
    }

    struct Options {
        var scale = 2.0
        var padding = 20.0
        var theme: CanvasTheme = .light
        var background = true
        /// The scene area to show. Nil shows everything drawn.
        var region: CGRect?
        /// Only draw these elements (with their labels). Nil draws all.
        var only: Set<String>?
    }

    /// The largest image side, in pixels.
    static let maxPixels = 16384.0

    /// The area a render covers: the region, or everything drawn, with
    /// padding.
    static func area(of document: CanvasDocument, options: Options) -> CGRect? {
        if let region = options.region { return region }
        let elements = visibleElements(document, options: options)
        let bounds = CanvasRenderer.sceneBounds(of: elements)
        guard !bounds.isNull else { return nil }
        return bounds.insetBy(dx: -options.padding, dy: -options.padding)
    }

    static func visibleElements(_ document: CanvasDocument, options: Options) -> [CanvasElement] {
        guard let only = options.only else { return document.elements }
        let ids = CanvasOps.withBoundText(only, in: document)
        return document.elements.filter { ids.contains($0.id) }
    }

    private static func filtered(_ document: CanvasDocument, options: Options) -> CanvasDocument {
        guard options.only != nil else { return document }
        var copy = document
        copy.elements = visibleElements(document, options: options)
        return copy
    }

    /// The pixel size of a render, or an error saying how to make it fit.
    static func pixelSize(of area: CGRect, scale: Double) throws -> (width: Int, height: Int) {
        let width = (Double(area.width) * scale).rounded(.up), height = (Double(area.height) * scale).rounded(.up)
        guard width >= 1, height >= 1 else { throw CanvasAgentError.failed("nothing to render: the area is empty") }
        guard width <= maxPixels, height <= maxPixels else {
            let fit = min(maxPixels / Double(area.width), maxPixels / Double(area.height))
            throw CanvasAgentError.usage(
                "the render would be \(Int(width))x\(Int(height)) px, more than \(Int(maxPixels)) on a side; "
                    + "use --scale \(CanvasJSON.format((fit * 100).rounded(.down) / 100)) or less, or --frame/--region")
        }
        return (Int(width), Int(height))
    }

    // MARK: PNG

    static func image(_ document: CanvasDocument, options: Options) throws -> CGImage {
        guard let area = area(of: document, options: options) else {
            throw CanvasAgentError.failed("nothing to render: the drawing is empty")
        }
        let (width, height) = try pixelSize(of: area, scale: options.scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasAgentError.failed("can't make a \(width)x\(height) image")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(options.scale), y: -CGFloat(options.scale))
        context.translateBy(x: -area.minX, y: -area.minY)
        draw(document, in: context, area: area, options: options)
        guard let image = context.makeImage() else { throw CanvasAgentError.failed("can't make the image") }
        return image
    }

    static func pngData(_ document: CanvasDocument, options: Options) throws -> Data {
        let image = try image(document, options: options)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CanvasAgentError.failed("can't encode PNG")
        }
        // 72 dpi per scene unit, so the PNG opens at the drawing's size.
        let dpi = 72 * options.scale
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CanvasAgentError.failed("can't encode PNG") }
        return data as Data
    }

    private static func draw(_ document: CanvasDocument, in context: CGContext, area: CGRect, options: Options) {
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        if options.background {
            context.setFillColor(CanvasColor.cgColor(document.viewBackgroundColor, theme: options.theme))
            context.fill(area)
        }
        let renderer = CanvasRenderer()
        renderer.theme = options.theme
        renderer.zoom = 1
        renderer.draw(filtered(document, options: options), in: context, visible: area)
    }

    // MARK: PDF

    static func pdfData(_ document: CanvasDocument, options: Options) throws -> Data {
        guard let area = area(of: document, options: options) else {
            throw CanvasAgentError.failed("nothing to render: the drawing is empty")
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: area.width, height: area.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CanvasAgentError.failed("can't make a PDF")
        }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: area.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        draw(document, in: context, area: area, options: options)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: SVG

    /// The drawing as SVG paths: text is glyph outlines, so it looks the
    /// same without the fonts installed.
    static func svg(_ document: CanvasDocument, options: Options) throws -> String {
        guard let area = area(of: document, options: options) else {
            throw CanvasAgentError.failed("nothing to render: the drawing is empty")
        }
        let document = filtered(document, options: options)
        let theme = options.theme
        let renderer = CanvasRenderer()
        renderer.theme = theme
        let membership = CanvasRenderer.FrameMembership(document)
        let canvasColor = CanvasColor.resolve(document.viewBackgroundColor, theme: theme)

        var out = ""
        let width = Double(area.width), height = Double(area.height)
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" "
        out += "width=\"\(num(width * options.scale))\" height=\"\(num(height * options.scale))\" "
        out += "viewBox=\"\(num(Double(area.minX))) \(num(Double(area.minY))) \(num(width)) \(num(height))\">\n"
        out += "<!-- svg-source:nubb -->\n"
        var defs = ""
        var body = ""
        if options.background {
            body += "<rect x=\"\(num(Double(area.minX)))\" y=\"\(num(Double(area.minY)))\" width=\"\(num(width))\" height=\"\(num(height))\" fill=\"\(color(canvasColor))\"/>\n"
        }
        var clips = Set<String>()
        let labels = CanvasRenderer.ArrowLabels(document)
        for element in document.elements {
            guard renderer.paintBounds(of: element).intersects(area) else { continue }
            if element.type == .frame {
                body += frameSVG(element, theme: theme)
                continue
            }
            var group = elementSVG(element, renderer: renderer, theme: theme, canvasColor: canvasColor)
            guard !group.isEmpty else { continue }
            if let hole = labels.hole(for: element) {
                // The gap Excalidraw leaves in an arrow under its label.
                let clipID = "label-" + escapeID(element.id)
                let outer = renderer.paintBounds(of: element).union(hole).insetBy(dx: -8, dy: -8)
                let d = "M\(num(Double(outer.minX))) \(num(Double(outer.minY)))h\(num(Double(outer.width)))v\(num(Double(outer.height)))h\(num(-Double(outer.width)))Z"
                    + "M\(num(Double(hole.minX))) \(num(Double(hole.minY)))h\(num(Double(hole.width)))v\(num(Double(hole.height)))h\(num(-Double(hole.width)))Z"
                defs += "<clipPath id=\"\(clipID)\"><path clip-rule=\"evenodd\" d=\"\(d)\"/></clipPath>\n"
                group = "<g clip-path=\"url(#\(clipID))\">\n" + group + "</g>\n"
            }
            if let frame = membership.frame(of: element) {
                let clipID = "clip-" + escapeID(frame.id)
                if clips.insert(clipID).inserted {
                    defs += "<clipPath id=\"\(clipID)\"><path d=\"\(pathData(CanvasRenderer.frameClipPath(frame, zoom: 1)))\"/></clipPath>\n"
                }
                group = "<g clip-path=\"url(#\(clipID))\">\n" + group + "</g>\n"
            }
            body += group
        }
        if !defs.isEmpty { out += "<defs>\n" + defs + "</defs>\n" }
        out += body
        out += "</svg>\n"
        return out
    }

    private static func elementSVG(_ element: CanvasElement, renderer: CanvasRenderer, theme: CanvasTheme, canvasColor: CanvasRGBA) -> String {
        let opacity = max(0, min(100, element.opacity)) / 100
        guard opacity > 0 else { return "" }
        let shape = renderer.shape(for: element)
        let stroke = CanvasColor.resolve(element.strokeColor, theme: theme)
        let background = CanvasColor.resolve(element.backgroundColor, theme: theme)
        let center = element.center
        var transform = ""
        if element.angle != 0 {
            transform += "rotate(\(num(element.angle * 180 / .pi)) \(num(Double(center.x))) \(num(Double(center.y)))) "
        }
        transform += "translate(\(num(element.x)) \(num(element.y)))"
        var out = "<g transform=\"\(transform)\"" + (opacity < 1 ? " opacity=\"\(num(opacity))\"" : "") + ">\n"
        // Browsers show a group's title on hover, like the viewer does.
        if let name = element.hoverName { out += "<title>\(xmlEscape(name))</title>\n" }
        for part in shape.parts {
            let paint: CanvasRGBA
            switch part.paint {
            case .stroke: paint = stroke
            case .background: paint = background
            case .canvas: paint = canvasColor
            }
            let d = pathData(part.path)
            guard !d.isEmpty else { continue }
            if let width = part.lineWidth {
                var attributes = "fill=\"none\" stroke=\"\(color(paint))\" stroke-width=\"\(num(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
                if paint.alpha < 1 { attributes += " stroke-opacity=\"\(num(paint.alpha))\"" }
                if let dash = part.dash { attributes += " stroke-dasharray=\"\(dash.map(num).joined(separator: " "))\"" }
                out += "<path d=\"\(d)\" \(attributes)/>\n"
            } else {
                var attributes = "fill=\"\(color(paint))\""
                if paint.alpha < 1 { attributes += " fill-opacity=\"\(num(paint.alpha))\"" }
                if part.evenOdd { attributes += " fill-rule=\"evenodd\"" }
                out += "<path d=\"\(d)\" \(attributes)/>\n"
            }
        }
        out += "</g>\n"
        return out
    }

    private static func frameSVG(_ frame: CanvasElement, theme: CanvasTheme) -> String {
        let style = CanvasRenderer.FrameStyle.self
        var out = "<path d=\"\(pathData(CanvasRenderer.frameClipPath(frame, zoom: 1)))\" fill=\"none\" "
        out += "stroke=\"\(color(CanvasColor.resolve(style.strokeColor, theme: theme)))\" stroke-width=\"\(num(style.strokeWidth))\"/>\n"
        return out
    }

    // MARK: SVG helpers

    static func pathData(_ path: CGPath) -> String {
        var out = ""
        out.reserveCapacity(256)
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint:
                out += "M\(num(Double(p[0].x))) \(num(Double(p[0].y)))"
            case .addLineToPoint:
                out += "L\(num(Double(p[0].x))) \(num(Double(p[0].y)))"
            case .addQuadCurveToPoint:
                out += "Q\(num(Double(p[0].x))) \(num(Double(p[0].y))) \(num(Double(p[1].x))) \(num(Double(p[1].y)))"
            case .addCurveToPoint:
                out += "C\(num(Double(p[0].x))) \(num(Double(p[0].y))) \(num(Double(p[1].x))) \(num(Double(p[1].y))) "
                    + "\(num(Double(p[2].x))) \(num(Double(p[2].y)))"
            case .closeSubpath:
                out += "Z"
            @unknown default:
                break
            }
        }
        return out
    }

    /// A number with at most two decimals, for short SVG files.
    private static func num(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return CanvasJSON.format(rounded == 0 ? 0 : rounded)
    }

    private static func color(_ rgba: CanvasRGBA) -> String {
        String(rgba.hexString.prefix(7))
    }

    private static func escapeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func xmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Writing

    /// Renders and writes to `url` in the format its extension names.
    static func write(_ document: CanvasDocument, to url: URL, format: Format, options: Options) throws -> Data {
        let data: Data
        switch format {
        case .png: data = try pngData(document, options: options)
        case .pdf: data = try pdfData(document, options: options)
        case .svg: data = Data(try svg(document, options: options).utf8)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw CanvasAgentError.failed("can't write \(url.path): \(error.localizedDescription)")
        }
        return data
    }
}
