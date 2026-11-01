import CoreGraphics
import Foundation

/// Reading drawings for the CLI: frames by name, element summaries, and
/// descriptions of what changed.
enum CanvasQuery {
    // MARK: Frames

    static func frames(in document: CanvasDocument) -> [CanvasElement] {
        document.elements.filter { $0.type == .frame }
    }

    /// A frame by id, by exact name, by name ignoring case, or by a name
    /// that starts with `name` when only one does. `6` finds "6. Why".
    static func frame(named name: String, in document: CanvasDocument) -> CanvasElement? {
        let frames = frames(in: document)
        if let byID = frames.first(where: { $0.id == name }) { return byID }
        if let exact = frames.first(where: { CanvasRenderer.frameTitle($0) == name }) { return exact }
        let lower = name.lowercased()
        let caseless = frames.filter { CanvasRenderer.frameTitle($0).lowercased() == lower }
        if caseless.count == 1 { return caseless[0] }
        let prefixed = frames.filter {
            let title = CanvasRenderer.frameTitle($0).lowercased()
            guard title.hasPrefix(lower) else { return false }
            // "6" matches "6. Why" but not "60. Later".
            let rest = title.dropFirst(lower.count)
            return rest.first.map { !$0.isNumber && !$0.isLetter } ?? true
        }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    static func frameHint(_ name: String, in document: CanvasDocument) -> String {
        let names = frames(in: document).map(CanvasRenderer.frameTitle)
        guard !names.isEmpty else { return "; the drawing has no frames" }
        if let hint = CanvasSpecNames.suggestion(for: name, in: names) { return " (did you mean \"\(hint)\"?)" }
        return "; frames: " + names.prefix(12).map { "\"\($0)\"" }.joined(separator: ", ") + (names.count > 12 ? ", ..." : "")
    }

    // MARK: Elements

    /// One line about an element: id, type, box, and its text.
    static func summary(_ element: CanvasElement, in document: CanvasDocument, frames: CanvasRenderer.FrameMembership) -> String {
        let box = element.sceneBounds
        var line = "\(element.id)  \(element.type.rawValue)  \(rect(box))"
        if element.type == .frame {
            line += "  \"\(CanvasRenderer.frameTitle(element))\""
        } else if element.type == .text {
            line += "  " + quote(element.originalText.isEmpty ? element.text : element.originalText)
            if let container = element.containerId { line += "  in \(container)" }
        } else if let label = element.boundTextID, let text = document.element(id: label) {
            line += "  " + quote(text.originalText.isEmpty ? text.text : text.originalText)
        }
        if element.type.isLinear {
            let from = element.startBinding?.elementId ?? "-"
            let to = element.endBinding?.elementId ?? "-"
            line += "  \(from) -> \(to)"
        }
        if let name = element.hoverName { line += "  name " + quote(name) }
        if let frame = frames.frame(of: element), element.type != .frame {
            line += "  [\(CanvasRenderer.frameTitle(frame))]"
        }
        return line
    }

    static func quote(_ text: String, limit: Int = 60) -> String {
        var flat = text.replacingOccurrences(of: "\n", with: "\\n")
        if flat.count > limit { flat = String(flat.prefix(limit - 3)) + "..." }
        return "\"" + flat + "\""
    }

    static func rect(_ box: CGRect) -> String {
        "\(n(box.minX)),\(n(box.minY)) \(n(box.width))x\(n(box.height))"
    }

    static func n(_ value: CGFloat) -> String {
        CanvasJSON.format((Double(value) * 10).rounded() / 10)
    }

    static func n(_ value: Double) -> String {
        CanvasJSON.format((value * 10).rounded() / 10)
    }

    static func rectJSON(_ box: CGRect) -> CanvasJSON {
        .array([box.minX, box.minY, box.width, box.height].map { .number((Double($0) * 100).rounded() / 100) })
    }

    // MARK: Changes

    /// What changed about one element, in a few words: "moved by 40,0",
    /// "text: \"Old\" -> \"New\"".
    static func describe(_ change: CanvasElementChange) -> String {
        switch change.kind {
        case .added:
            return "added \(change.element.type.rawValue)" + text(of: change.element)
        case .deleted:
            return "deleted \(change.element.type.rawValue)" + text(of: change.element)
        case .modified:
            var parts: [String] = []
            if let moved = change.moved, !(change.element.type == .text && change.element.containerId != nil) {
                parts.append("moved by \(n(moved.dx)),\(n(moved.dy))")
            }
            for key in change.fields.keys.sorted() where !["x", "y", "version", "versionNonce", "updated"].contains(key) {
                let value = change.fields[key]!
                switch key {
                case "text":
                    if change.fields["originalText"] == nil { parts.append("text: " + textDiff(value.old, value.new)) }
                case "originalText":
                    parts.append("text: " + textDiff(value.old, value.new))
                case "points", "boundElements", "startBinding", "endBinding", "seed":
                    if key == "points", change.moved == nil { parts.append("reshaped") }
                case "customData":
                    let old = value.old?["name"]?.stringValue, new = value.new?["name"]?.stringValue
                    if old != new {
                        parts.append("name: " + show(old.map(CanvasJSON.string)) + " -> " + show(new.map(CanvasJSON.string)))
                    } else {
                        parts.append("customData changed")
                    }
                case "width", "height":
                    if key == "width" || change.fields["width"] == nil {
                        let previous = change.previous
                        parts.append("resized \(n(previous?.width ?? 0))x\(n(previous?.height ?? 0)) -> \(n(change.element.width))x\(n(change.element.height))")
                    }
                default:
                    parts.append("\(key): \(show(value.old)) -> \(show(value.new))")
                }
            }
            if parts.isEmpty { parts.append("changed") }
            return Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: ", ")
        }
    }

    private static func text(of element: CanvasElement) -> String {
        guard element.type == .text else { return "" }
        return " " + quote(element.originalText.isEmpty ? element.text : element.originalText)
    }

    /// Old and new text, cut to the part that changed when they're long.
    static func textDiff(_ old: CanvasJSON?, _ new: CanvasJSON?) -> String {
        let a = Array(old?.stringValue ?? ""), b = Array(new?.stringValue ?? "")
        guard a.count > 40 || b.count > 40 else { return "\(show(old)) -> \(show(new))" }
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        let from = max(0, start - 12)
        func cut(_ chars: [Character], _ end: Int) -> String {
            var middle = String(chars[from..<min(chars.count, max(end, start) + 12)])
            if middle.count > 70 { middle = String(middle.prefix(67)) + "..." }
            let prefix = from > 0 ? "..." : ""
            let suffix = min(chars.count, max(end, start) + 12) < chars.count ? "..." : ""
            return "\"" + prefix + middle.replacingOccurrences(of: "\n", with: "\\n") + suffix + "\""
        }
        return cut(a, endA) + " -> " + cut(b, endB)
    }

    private static func show(_ value: CanvasJSON?) -> String {
        guard let value else { return "none" }
        switch value {
        case .string(let text): return quote(text, limit: 40)
        case .number(let number): return n(number)
        case .null: return "none"
        default:
            let text = value.compactText
            return text.count > 40 ? String(text.prefix(37)) + "..." : text
        }
    }
}
