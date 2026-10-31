import CoreGraphics
import CoreText
import Foundation

/// Text layout for canvas text elements, using Excalidraw's rules: each line
/// is `fontSize * lineHeight` tall and glyphs sit centered in that box.
enum CanvasText {
    /// Excalidraw's default line height for a font family (`getLineHeight`).
    static func defaultLineHeight(family: Int) -> Double {
        switch CanvasFont.Family(rawValue: family) {
        case .lilitaOne, .helvetica, .liberationSans: 1.15
        case .cascadia: 1.2
        default: 1.25
        }
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The size Excalidraw stores for a text element (`measureText`): the
    /// widest line's advance width by the number of lines times the line
    /// height.
    static func measure(_ text: String, family: Int, fontSize: Double, lineHeight: Double) -> CGSize {
        let font = font(family: family, size: fontSize)
        let lineList = lines(text)
        var width = 0.0
        for line in lineList {
            width = max(width, lineWidth(line.isEmpty ? " " : line, font: font))
        }
        let height = fontSize * lineHeight * Double(lineList.count)
        return CGSize(width: width, height: height)
    }

    /// The advance width of one line of text.
    static func width(of line: String, family: Int, fontSize: Double) -> Double {
        lineWidth(line, font: font(family: family, size: fontSize))
    }

    /// Breaks `text` into lines no wider than `maxWidth`, as Excalidraw's
    /// `wrapText` does: lines break after spaces and hyphens and around CJK
    /// characters, and a word longer than a line is split between
    /// characters. Existing line breaks are kept.
    static func wrap(_ text: String, family: Int, fontSize: Double, maxWidth: Double) -> String {
        guard maxWidth.isFinite, maxWidth >= 0 else { return text }
        let font = font(family: family, size: fontSize)
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            if lineWidth(line, font: font) <= maxWidth {
                result.append(line)
            } else {
                result.append(contentsOf: wrapLine(line, font: font, maxWidth: maxWidth))
            }
        }
        return result.joined(separator: "\n")
    }

    private static func wrapLine(_ line: String, font: CTFont, maxWidth: Double) -> [String] {
        var lines: [String] = []
        var current = ""
        var currentWidth = 0.0
        let tokens = Self.tokens(line)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let test = current + token
            let testWidth = token.count == 1 ? currentWidth + lineWidth(token, font: font) : lineWidth(test, font: font)
            if token.allSatisfy(\.isWhitespace) || testWidth <= maxWidth {
                current = test
                currentWidth = testWidth
                index += 1
                continue
            }
            if current.isEmpty {
                // One word wider than the line: split it between characters.
                var pieces = wrapWord(token, font: font, maxWidth: maxWidth)
                current = pieces.popLast() ?? ""
                lines.append(contentsOf: pieces)
                currentWidth = lineWidth(current, font: font)
                index += 1
            } else {
                lines.append(trimmingTrailingWhitespace(current))
                current = ""
                currentWidth = 0
            }
        }
        if !current.isEmpty {
            lines.append(trimTrailingLine(current, font: font, maxWidth: maxWidth))
        }
        return lines
    }

    private static func wrapWord(_ word: String, font: CTFont, maxWidth: Double) -> [String] {
        var lines: [String] = []
        var current = ""
        var currentWidth = 0.0
        for character in word {
            let width = lineWidth(String(character), font: font)
            if currentWidth + width <= maxWidth {
                current.append(character)
                currentWidth += width
                continue
            }
            if !current.isEmpty { lines.append(current) }
            current = String(character)
            currentWidth = width
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Keeps as much trailing whitespace as fits, like Excalidraw's `trimLine`.
    private static func trimTrailingLine(_ line: String, font: CTFont, maxWidth: Double) -> String {
        guard lineWidth(line, font: font) > maxWidth else { return line }
        var trimmed = trimmingTrailingWhitespace(line)
        let whitespace = line.dropFirst(trimmed.count)
        var width = lineWidth(trimmed, font: font)
        for character in whitespace {
            let next = width + lineWidth(String(character), font: font)
            if next > maxWidth { break }
            trimmed.append(character)
            width = next
        }
        return trimmed
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }

    /// Splits a line where Excalidraw may break it: before and after each
    /// whitespace character, after hyphens, and around CJK characters and
    /// emoji. Concatenating the tokens gives the line back.
    static func tokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in line.precomposedStringWithCanonicalMapping {
            if character.isWhitespace || isCJK(character) || isEmoji(character) {
                flush()
                tokens.append(String(character))
            } else if character == "-" {
                current.append(character)
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3130...0x318F, 0x3190...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (character.unicodeScalars.count > 1 && character.unicodeScalars.first?.properties.isEmoji == true)
    }

    /// The glyph outlines of a text element in its local coordinates. Text
    /// is drawn as paths so it stays sharp at every zoom level.
    static func path(for element: CanvasElement) -> CGPath {
        let result = CGMutablePath()
        guard !element.text.isEmpty, element.fontSize > 0 else { return result }
        let font = font(family: element.fontFamily, size: element.fontSize)
        let lineHeightPx = element.fontSize * element.lineHeight
        let baselineOffset = baseline(family: element.fontFamily, fontSize: element.fontSize, lineHeightPx: lineHeightPx)
        let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]

        for (index, line) in lines(element.text).enumerated() where !line.isEmpty {
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            let lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let originX: Double
            switch element.textAlign {
            case "center": originX = (element.width - lineWidth) / 2
            case "right": originX = element.width - lineWidth
            default: originX = 0
            }
            let baseline = Double(index) * lineHeightPx + baselineOffset
            appendGlyphs(of: ctLine, to: result, origin: CGPoint(x: originX, y: baseline))
        }
        return result
    }

    private static func appendGlyphs(of line: CTLine, to path: CGMutablePath, origin: CGPoint) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // Fallback fonts (emoji, CJK) come back per run.
            guard let value = attributes[kCTFontAttributeName as String],
                  CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { continue }
            let runFont = value as! CTFont // swiftlint:disable:this force_cast
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // CoreText is y-up. Flip each glyph onto the y-down baseline.
                var transform = CGAffineTransform(
                    a: 1, b: 0, c: 0, d: -1,
                    tx: origin.x + positions[i].x,
                    ty: origin.y - positions[i].y)
                if let placed = glyph.copy(using: &transform) {
                    path.addPath(placed)
                }
            }
        }
    }

    /// Where the first baseline sits below the top of the text, Excalidraw's
    /// `getVerticalOffset`: glyphs centered in the line using Excalidraw's
    /// metrics for the family.
    static func baseline(family: Int, fontSize: Double, lineHeightPx: Double) -> Double {
        let metrics = CanvasFont.metrics(family: family)
        let em = fontSize / metrics.unitsPerEm
        let lineGap = (lineHeightPx - em * metrics.ascender + em * metrics.descender) / 2
        return em * metrics.ascender + lineGap
    }

    // MARK: Fonts

    private static let fontCache = NSCache<NSString, CTFont>()

    static func font(family: Int, size: Double) -> CTFont {
        let key = "\(family):\(size)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        let font = CanvasFont.ctFont(family: family, size: size)
        fontCache.setObject(font, forKey: key)
        return font
    }

    private static func lineWidth(_ line: String, font: CTFont) -> Double {
        let attributed = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}

// MARK: - Bound text

extension CanvasText {
    /// Excalidraw's `getContainerCoords`: the top-left corner of the area a
    /// label may use inside its container.
    static func containerTextOrigin(_ container: CanvasElement) -> CGPoint {
        var offsetX = CanvasGeometry.boundTextPadding
        var offsetY = CanvasGeometry.boundTextPadding
        if container.type == .ellipse {
            offsetX += (container.width / 2) * (1 - sqrt(2) / 2)
            offsetY += (container.height / 2) * (1 - sqrt(2) / 2)
        }
        if container.type == .diamond {
            offsetX += container.width / 4
            offsetY += container.height / 4
        }
        return CGPoint(x: container.x + offsetX, y: container.y + offsetY)
    }

    /// Excalidraw's `getBoundTextMaxWidth`.
    static func maxLabelWidth(_ container: CanvasElement) -> Double {
        let padding = CanvasGeometry.boundTextPadding * 2
        switch container.type {
        case .ellipse: return (container.width / 2 * sqrt(2)).rounded() - padding
        case .diamond: return (container.width / 2).rounded() - padding
        case .arrow, .line: return max(0.7 * container.localBounds.width, 20 * 4.5)
        default: return container.width - padding
        }
    }

    /// Excalidraw's `getBoundTextMaxHeight`.
    static func maxLabelHeight(_ container: CanvasElement) -> Double {
        let padding = CanvasGeometry.boundTextPadding * 2
        switch container.type {
        case .ellipse: return (container.height / 2 * sqrt(2)).rounded() - padding
        case .diamond: return (container.height / 2).rounded() - padding
        default: return container.height - padding
        }
    }

    /// Where a label sits inside its container (Excalidraw's
    /// `computeBoundTextPosition`), or at the middle of a line or arrow.
    static func labelOrigin(text: CanvasElement, container: CanvasElement) -> CGPoint {
        if container.type.isLinear {
            let mid = midpoint(of: container)
            return CGPoint(x: mid.dx - text.width / 2, y: mid.dy - text.height / 2)
        }

        let origin = containerTextOrigin(container)
        let maxWidth = maxLabelWidth(container)
        let maxHeight = maxLabelHeight(container)
        let x: Double
        switch text.textAlign {
        case "left": x = origin.dx
        case "right": x = origin.dx + (maxWidth - text.width)
        default: x = origin.dx + (maxWidth / 2 - text.width / 2)
        }
        let y: Double
        switch text.verticalAlign {
        case "top": y = origin.dy
        case "bottom": y = origin.dy + (maxHeight - text.height)
        default: y = origin.dy + (maxHeight / 2 - text.height / 2)
        }
        return CGPoint(x: x, y: y)
    }

    /// The point halfway along a line or arrow, in scene coordinates.
    static func midpoint(of element: CanvasElement) -> CGPoint {
        let points = element.points
        guard points.count > 1 else {
            return element.toScene(points.first ?? .zero)
        }
        var total = 0.0
        for i in 1..<points.count {
            total += hypot(points[i].dx - points[i - 1].dx, points[i].dy - points[i - 1].dy)
        }
        var remaining = total / 2
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let length = hypot(b.dx - a.dx, b.dy - a.dy)
            if remaining <= length, length > 0 {
                let t = remaining / length
                return element.toScene(CGPoint(x: a.dx + (b.dx - a.dx) * t, y: a.dy + (b.dy - a.dy) * t))
            }
            remaining -= length
        }
        return element.toScene(points[points.count - 1])
    }
}
