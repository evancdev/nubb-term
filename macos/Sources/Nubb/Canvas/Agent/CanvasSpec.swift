import CoreGraphics
import Foundation

// MARK: - Spec

/// A drawing as an agent describes it for `nubb +canvas apply`: a tree of
/// nodes such as text, boxes, code blocks, frames, and arrows, arranged by
/// stacks, rows, and grids. Layout turns it into Excalidraw elements with
/// the ids the agent chose, so later applies update the same elements.
struct CanvasSpec {
    var nodes: [CanvasSpecNode] = []
    /// Element ids to delete.
    var deletions: [String] = []
    /// Field changes to existing elements, by id.
    var edits: [(id: String, path: String, fields: [String: CanvasJSON])] = []
    /// Moves of existing elements, by id.
    var moves: [(id: String, delta: CGVector)] = []
}

struct CanvasSpecIssue: Error, Equatable, CustomStringConvertible {
    var path: String
    var message: String

    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

enum CanvasSpecLength: Equatable {
    case fixed(Double)
    /// As wide as the parent allows.
    case fill

    var fixedValue: Double? {
        if case .fixed(let value) = self { return value }
        return nil
    }
}

enum CanvasSpecAlign: String {
    case start
    case center
    case end
    case stretch
}

enum CanvasSpecSide: String {
    case left
    case right
    case top
    case bottom
}

struct CanvasSpecInsets: Equatable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double

    init(_ all: Double) { self.init(vertical: all, horizontal: all) }
    init(vertical: Double, horizontal: Double) {
        top = vertical
        bottom = vertical
        left = horizontal
        right = horizontal
    }
    init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    var horizontal: Double { left + right }
    var vertical: Double { top + bottom }
}

enum CanvasSpecEndpoint: Equatable {
    case element(String)
    case point(CGPoint)
}

/// Style fields a node sets. Unset fields come from the defaults.
struct CanvasSpecStyle: Equatable {
    var strokeColor: String?
    var backgroundColor: String?
    var fillStyle: String?
    var strokeWidth: Double?
    var strokeStyle: String?
    var roughness: Double?
    var opacity: Double?
    var round: Bool?
    var fontFamily: Int?
    var fontSize: Double?
    var textAlign: String?
    var verticalAlign: String?
    /// "none" for no arrowhead.
    var startArrowhead: String?
    var endArrowhead: String?

    /// This style on top of `base`: fields set here win.
    func over(_ base: CanvasSpecStyle) -> CanvasSpecStyle {
        var result = base
        if let strokeColor { result.strokeColor = strokeColor }
        if let backgroundColor { result.backgroundColor = backgroundColor }
        if let fillStyle { result.fillStyle = fillStyle }
        if let strokeWidth { result.strokeWidth = strokeWidth }
        if let strokeStyle { result.strokeStyle = strokeStyle }
        if let roughness { result.roughness = roughness }
        if let opacity { result.opacity = opacity }
        if let round { result.round = round }
        if let fontFamily { result.fontFamily = fontFamily }
        if let fontSize { result.fontSize = fontSize }
        if let textAlign { result.textAlign = textAlign }
        if let verticalAlign { result.verticalAlign = verticalAlign }
        if let startArrowhead { result.startArrowhead = startArrowhead }
        if let endArrowhead { result.endArrowhead = endArrowhead }
        return result
    }
}

struct CanvasSpecNode {
    enum Kind: String, CaseIterable {
        case text
        case box
        case ellipse
        case diamond
        case code
        case frame
        case stack
        case row
        case grid
        case arrow
        case line
        /// An Excalidraw element written as is.
        case raw

        var isShape: Bool { self == .box || self == .ellipse || self == .diamond }
        var isLayout: Bool { self == .stack || self == .row || self == .grid }
        var isConnector: Bool { self == .arrow || self == .line }
    }

    var kind: Kind
    /// Where the node is in the spec, like `nodes[2].children[0]`.
    var path: String
    var id: String?
    /// The text, label, frame name, or code.
    var content = ""
    var children: [CanvasSpecNode] = []
    var style = CanvasSpecStyle()
    var at: CGPoint?
    var width: CanvasSpecLength?
    var height: Double?
    var minWidth: Double?
    var minHeight: Double?
    var maxWidth: Double?
    var gap: Double?
    var rowGap: Double?
    var padding: CanvasSpecInsets?
    var align: CanvasSpecAlign?
    var columns: Int?
    var columnWidth: Double?
    /// Whether the node's elements move together as an Excalidraw group.
    /// Cards and code blocks are grouped unless this is false.
    var group: Bool?
    var wrap: Bool?
    var from: CanvasSpecEndpoint?
    var to: CanvasSpecEndpoint?
    var fromSide: CanvasSpecSide?
    var toSide: CanvasSpecSide?
    var elbow = false
    var raw: CanvasJSON?
    var locked = false
    var link: String?
    /// Shown when the pointer rests on the node in the viewer.
    var name: String?
    /// Moves the node after layout without changing the space it takes.
    var shift: CGVector?

    /// A box with children: a background shape around a stack.
    var isCard: Bool { kind.isShape && !children.isEmpty }
}

// MARK: - Palette and names

/// Excalidraw's color palette (open-color), fonts, and sizes by name, so
/// specs can say `"fill": "blue"` and get the color Excalidraw's picker has.
enum CanvasSpecNames {
    static let palette: [String: [String]] = [
        "gray": ["#f8f9fa", "#e9ecef", "#ced4da", "#868e96", "#343a40"],
        "red": ["#fff5f5", "#ffc9c9", "#ff8787", "#fa5252", "#e03131"],
        "pink": ["#fff0f6", "#fcc2d7", "#f783ac", "#e64980", "#c2255c"],
        "grape": ["#f8f0fc", "#eebefa", "#da77f2", "#be4bdb", "#9c36b5"],
        "violet": ["#f3f0ff", "#d0bfff", "#9775fa", "#7950f2", "#6741d9"],
        "blue": ["#e7f5ff", "#a5d8ff", "#4dabf7", "#228be6", "#1971c2"],
        "cyan": ["#e3fafc", "#99e9f2", "#3bc9db", "#15aabf", "#0c8599"],
        "teal": ["#e6fcf5", "#96f2d7", "#38d9a9", "#12b886", "#099268"],
        "green": ["#ebfbee", "#b2f2bb", "#69db7c", "#40c057", "#2f9e44"],
        "yellow": ["#fff9db", "#ffec99", "#ffd43b", "#fab005", "#f08c00"],
        "orange": ["#fff4e6", "#ffd8a8", "#ffa94d", "#fd7e14", "#e8590c"],
        "bronze": ["#f8f1ee", "#eaddd7", "#d2bab0", "#a18072", "#846358"],
    ]

    enum ColorRole {
        case stroke
        case fill
    }

    /// A color for the file: `#hex`, `transparent`, `black`, `white`, a
    /// palette name (the stroke or fill shade Excalidraw picks by default),
    /// or a palette name with a shade from 0 to 4 like `blue.2`.
    static func color(_ name: String, role: ColorRole) -> String? {
        let value = name.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "transparent", "none": return CanvasColor.transparentName
        case "black": return "#1e1e1e"
        case "white": return "#ffffff"
        default: break
        }
        if value.hasPrefix("#") {
            return CanvasColor.parse(value) == nil ? nil : value
        }
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        if let shades = palette[parts[0]] {
            if parts.count == 2 {
                guard let index = Int(parts[1]), shades.indices.contains(index) else { return nil }
                return shades[index]
            }
            return role == .stroke ? shades[4] : shades[1]
        }
        return CanvasColor.parse(value) == nil ? nil : value
    }

    static let fonts: [String: Int] = [
        "hand": 5, "excalifont": 5, "hand-drawn": 5,
        "normal": 6, "sans": 6, "nunito": 6,
        "code": 3, "mono": 3, "monospace": 3, "cascadia": 3,
        "comic": 8, "comic-shanns": 8,
        "virgil": 1, "helvetica": 2, "lilita": 7, "liberation": 9,
    ]

    static func font(_ json: CanvasJSON) -> Int? {
        if let number = json.intValue, CanvasFont.Family(rawValue: number) != nil { return number }
        guard let name = json.stringValue?.lowercased() else { return nil }
        return fonts[name]
    }

    static func fontName(_ family: Int) -> String {
        switch CanvasFont.Family(rawValue: family) {
        case .handDrawn: "hand"
        case .nunito: "normal"
        case .cascadia: "code"
        case .comicShanns: "comic"
        case .virgil: "virgil"
        case .helvetica: "helvetica"
        case .lilitaOne: "lilita"
        case .liberationSans: "liberation"
        case .none: "\(family)"
        }
    }

    /// Excalidraw's S, M, L, and XL font sizes.
    static let fontSizes: [String: Double] = ["s": 16, "m": 20, "l": 28, "xl": 36]

    static let strokeWidths: [String: Double] = ["thin": 1, "bold": 2, "extra": 4, "extra-bold": 4]

    static let roughness: [String: Double] = ["architect": 0, "artist": 1, "cartoonist": 2]

    static let fillStyles: Set<String> = ["solid", "hachure", "cross-hatch", "zigzag"]

    static let strokeStyles: Set<String> = ["solid", "dashed", "dotted"]

    static let arrowheads: Set<String> = [
        "none", "arrow", "bar", "dot", "circle", "circle_outline", "triangle", "triangle_outline",
        "diamond", "diamond_outline", "crowfoot_one", "crowfoot_many", "crowfoot_one_or_many",
    ]

    /// Node ids agents may choose: letters, digits, and `_ - .`. Layout
    /// names the extra elements of a node `<id>:<part>`, like `b1:label`.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-.".unicodeScalars.contains(scalar))
        }
    }

    /// The node an element id belongs to: `b1` for `b1:label`.
    static func nodeID(ofElement id: String) -> String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    /// The closest of `candidates` to `word`, for "did you mean" hints.
    static func suggestion(for word: String, in candidates: [String]) -> String? {
        let lower = word.lowercased()
        var best: (String, Int)?
        for candidate in candidates {
            let distance = editDistance(lower, candidate.lowercased())
            if distance <= max(1, candidate.count / 3), best == nil || distance < best!.1 {
                best = (candidate, distance)
            }
        }
        return best?.0
    }

    /// Edits between two words, a swap of neighbors counting as one
    /// (optimal string alignment), so "bleu" is one edit from "blue".
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

// MARK: - Reading

/// Reads a spec from JSON, collecting every problem with its path so an
/// agent can fix them all at once.
struct CanvasSpecReader {
    private(set) var issues: [CanvasSpecIssue] = []
    private var styles: [String: CanvasSpecStyle] = [:]
    private var defaults: [CanvasSpecNode.Kind: CanvasSpecStyle] = [:]
    private var seenIDs: [String: String] = [:]

    /// Named styles and per-kind defaults from a theme file, used under the
    /// spec's own.
    var theme: CanvasJSON?

    static let styleKeys = [
        "color", "fill", "fillStyle", "stroke", "strokeWidth", "rough", "opacity", "round",
        "font", "size", "align", "textAlign", "valign", "startHead", "endHead",
    ]

    private static let commonKeys = ["id", "at", "shift", "style", "group", "locked", "link", "name"]

    private static let kindKeys: [CanvasSpecNode.Kind: [String]] = [
        .text: ["width", "maxWidth", "wrap"],
        .box: ["width", "height", "minWidth", "minHeight", "maxWidth", "padding", "children", "gap"],
        .ellipse: ["width", "height", "minWidth", "minHeight", "maxWidth", "padding", "children", "gap"],
        .diamond: ["width", "height", "minWidth", "minHeight", "maxWidth", "padding", "children", "gap"],
        .code: ["width", "padding", "wrap"],
        .frame: ["children", "width", "height", "minHeight", "maxWidth", "padding", "gap"],
        .stack: ["width", "gap", "padding"],
        .row: ["width", "gap", "padding"],
        .grid: ["columns", "columnWidth", "width", "gap", "rowGap", "padding"],
        .arrow: ["from", "to", "fromSide", "toSide", "route"],
        .line: ["from", "to", "fromSide", "toSide", "route"],
    ]

    private static let kindAliases: [String: CanvasSpecNode.Kind] = [
        "text": .text, "box": .box, "rect": .box, "rectangle": .box, "ellipse": .ellipse,
        "diamond": .diamond, "code": .code, "frame": .frame, "panel": .frame, "stack": .stack,
        "column": .stack, "row": .row, "grid": .grid, "arrow": .arrow, "line": .line,
    ]

    init(theme: CanvasJSON? = nil) {
        self.theme = theme
    }

    mutating func read(_ json: CanvasJSON) -> CanvasSpec {
        var spec = CanvasSpec()
        if let theme { readStyles(theme, path: "theme") }

        if let array = json.arrayValue {
            spec.nodes = readNodes(array, path: "nodes")
            return spec
        }
        guard let object = json.objectValue else {
            issue("", "expected an object with \"nodes\", an array of nodes, or one node")
            return spec
        }
        if Self.kindKey(of: object) != nil || object["type"] != nil {
            if let node = readNode(json, path: "nodes[0]") { spec.nodes = [node] }
            return spec
        }

        let known = ["nodes", "styles", "defaults", "delete", "set", "move"]
        for key in object.keys where !known.contains(key) {
            unknownKey(key, path: "", candidates: known)
        }
        readStyles(json, path: "")
        if let nodes = object["nodes"] {
            if let array = nodes.arrayValue {
                spec.nodes = readNodes(array, path: "nodes")
            } else if let node = readNode(nodes, path: "nodes") {
                spec.nodes = [node]
            }
        }
        if let list = object["delete"] {
            if let ids = list.arrayValue?.compactMap(\.stringValue), ids.count == list.arrayValue?.count {
                spec.deletions = ids
            } else {
                issue("delete", "expected an array of element ids")
            }
        }
        if let edits = object["set"] {
            if let map = edits.objectValue {
                for (id, fields) in map.sorted(by: { $0.key < $1.key }) {
                    guard let fields = fields.objectValue else {
                        issue("set.\(id)", "expected an object of fields to change")
                        continue
                    }
                    spec.edits.append((id, "set.\(id)", fields))
                }
            } else {
                issue("set", "expected an object like {\"id\": {\"text\": \"new text\"}}")
            }
        }
        if let moves = object["move"] {
            if let map = moves.objectValue {
                for (id, value) in map.sorted(by: { $0.key < $1.key }) {
                    guard let point = Self.point(value) else {
                        issue("move.\(id)", "expected [dx, dy]")
                        continue
                    }
                    spec.moves.append((id, CGVector(dx: point.x, dy: point.y)))
                }
            } else {
                issue("move", "expected an object like {\"id\": [dx, dy]}")
            }
        }
        return spec
    }

    // MARK: Styles

    private mutating func readStyles(_ json: CanvasJSON, path: String) {
        let prefix = path.isEmpty ? "" : path + "."
        if let named = json["styles"] {
            if let map = named.objectValue {
                for (name, value) in map {
                    guard let fields = value.objectValue else {
                        issue("\(prefix)styles.\(name)", "expected an object of style fields")
                        continue
                    }
                    var style = CanvasSpecStyle()
                    for (key, field) in fields where !readStyleField(key, field, into: &style, kind: nil, path: "\(prefix)styles.\(name).\(key)") {
                        unknownKey(key, path: "\(prefix)styles.\(name)", candidates: Self.styleKeys)
                    }
                    styles[name] = style
                }
            } else {
                issue("\(prefix)styles", "expected an object of named styles")
            }
        }
        if let kinds = json["defaults"] {
            if let map = kinds.objectValue {
                for (name, value) in map {
                    guard let kind = Self.kindAliases[name] else {
                        unknownKey(name, path: "\(prefix)defaults", candidates: Array(Self.kindAliases.keys))
                        continue
                    }
                    guard let fields = value.objectValue else {
                        issue("\(prefix)defaults.\(name)", "expected an object of style fields")
                        continue
                    }
                    var style = defaults[kind] ?? CanvasSpecStyle()
                    for (key, field) in fields where !readStyleField(key, field, into: &style, kind: kind, path: "\(prefix)defaults.\(name).\(key)") {
                        unknownKey(key, path: "\(prefix)defaults.\(name)", candidates: Self.styleKeys)
                    }
                    defaults[kind] = style
                }
            } else {
                issue("\(prefix)defaults", "expected an object like {\"text\": {\"size\": 18}}")
            }
        }
    }

    /// Reads one style field. Returns false when `key` isn't a style field.
    private mutating func readStyleField(
        _ key: String, _ value: CanvasJSON, into style: inout CanvasSpecStyle,
        kind: CanvasSpecNode.Kind?, path: String
    ) -> Bool {
        switch key {
        case "color":
            style.strokeColor = color(value, role: .stroke, path: path)
        case "fill":
            style.backgroundColor = color(value, role: .fill, path: path)
        case "fillStyle":
            style.fillStyle = choice(value, CanvasSpecNames.fillStyles, path: path)
        case "stroke":
            style.strokeStyle = choice(value, CanvasSpecNames.strokeStyles, path: path)
        case "strokeWidth":
            style.strokeWidth = number(value, names: CanvasSpecNames.strokeWidths, range: 0.5...40, path: path)
        case "rough":
            style.roughness = number(value, names: CanvasSpecNames.roughness, range: 0...4, path: path)
        case "opacity":
            style.opacity = number(value, names: [:], range: 0...100, path: path)
        case "round":
            if let flag = value.boolValue { style.round = flag } else { issue(path, "expected true or false") }
        case "font":
            if let family = CanvasSpecNames.font(value) {
                style.fontFamily = family
            } else {
                issue(path, "unknown font; use hand, normal, code, comic, or an Excalidraw font number")
            }
        case "size":
            style.fontSize = number(value, names: CanvasSpecNames.fontSizes, range: 1...500, path: path)
        case "align", "textAlign":
            style.textAlign = choice(value, ["left", "center", "right"], path: path)
        case "valign":
            style.verticalAlign = choice(value, ["top", "middle", "bottom"], path: path)
        case "startHead":
            style.startArrowhead = choice(value, CanvasSpecNames.arrowheads, path: path)
        case "endHead":
            style.endArrowhead = choice(value, CanvasSpecNames.arrowheads, path: path)
        default:
            return false
        }
        return true
    }

    // MARK: Nodes

    private mutating func readNodes(_ list: [CanvasJSON], path: String) -> [CanvasSpecNode] {
        list.enumerated().compactMap { index, item in readNode(item, path: "\(path)[\(index)]") }
    }

    private static func kindKey(of object: [String: CanvasJSON]) -> String? {
        object.keys.sorted().first { kindAliases[$0] != nil }
    }

    private mutating func readNode(_ json: CanvasJSON, path: String) -> CanvasSpecNode? {
        if let text = json.stringValue {
            // A bare string is a paragraph.
            var node = CanvasSpecNode(kind: .text, path: path)
            node.content = text
            node.style = defaults[.text] ?? CanvasSpecStyle()
            return node
        }
        guard let object = json.objectValue else {
            issue(path, "expected a node object like {\"text\": \"...\"} or {\"box\": \"Label\"}")
            return nil
        }

        if object["type"] != nil {
            return readRaw(object, path: path)
        }

        let kindKeys = object.keys.filter { Self.kindAliases[$0] != nil }.sorted()
        guard let kindName = kindKeys.first else {
            let hint = object.keys.compactMap { CanvasSpecNames.suggestion(for: $0, in: Array(Self.kindAliases.keys)) }.first
            issue(path, "no node kind: give one of text, box, ellipse, diamond, code, frame, stack, row, grid, arrow, line"
                + (hint.map { " (did you mean \"\($0)\"?)" } ?? ""))
            return nil
        }
        guard kindKeys.count == 1 else {
            issue(path, "a node has one kind, but this one has \(kindKeys.map { "\"\($0)\"" }.joined(separator: " and "))")
            return nil
        }
        let kind = Self.kindAliases[kindName]!
        var node = CanvasSpecNode(kind: kind, path: path)
        let value = object[kindName]!

        switch kind {
        case .stack, .row, .grid:
            guard let array = value.arrayValue else {
                issue("\(path).\(kindName)", "expected an array of nodes")
                return nil
            }
            node.children = readNodes(array, path: "\(path).\(kindName)")
        case .arrow, .line:
            if let text = value.stringValue {
                node.content = text
            } else if value != .bool(true), value != .null {
                issue("\(path).\(kindName)", "expected the label text (\"\" for none)")
            }
        case _ where kind.isShape && value.arrayValue != nil:
            // {"box": [...]}: a card with these children.
            node.children = readNodes(value.arrayValue ?? [], path: "\(path).\(kindName)")
            if object["children"] != nil {
                issue("\(path).children", "give the children in \"\(kindName)\" or in \"children\", not both")
            }
        default:
            if let text = value.stringValue {
                node.content = text
            } else if let lines = value.arrayValue, kind == .code || kind == .text,
                      lines.allSatisfy({ $0.stringValue != nil }) {
                node.content = lines.compactMap(\.stringValue).joined(separator: "\n")
            } else if value == .null || value == .bool(true), kind.isShape || kind == .frame {
                // {"box": null, "children": [...]}: no label.
            } else {
                issue("\(path).\(kindName)", kind.isShape ? "expected the label text, or an array of child nodes" : "expected a string")
            }
        }

        // Styles: built-in defaults < spec defaults < named styles < inline.
        var style = defaults[kind] ?? CanvasSpecStyle()
        if let names = object["style"] {
            let list = names.arrayValue?.compactMap(\.stringValue) ?? names.stringValue.map { [$0] } ?? []
            if list.isEmpty { issue("\(path).style", "expected a style name or a list of names") }
            for name in list {
                if let named = styles[name] {
                    style = named.over(style)
                } else {
                    let hint = CanvasSpecNames.suggestion(for: name, in: Array(styles.keys))
                    issue("\(path).style", "no style named \"\(name)\""
                        + (hint.map { " (did you mean \"\($0)\"?)" } ?? (styles.isEmpty ? "; define it under \"styles\"" : "")))
                }
            }
        }

        var inline = CanvasSpecStyle()
        let allowed = Self.commonKeys + Self.styleKeys + (Self.kindKeys[kind] ?? []) + [kindName]
        for (key, field) in object.sorted(by: { $0.key < $1.key }) where key != kindName {
            let fieldPath = "\(path).\(key)"
            // `align` arranges the children of layouts and frames, and
            // aligns the text of everything else.
            if key == "align", kind.isLayout || kind == .frame || (kind.isShape && object["children"] != nil) {
                node.align = choice(field, ["start", "center", "end", "stretch"], path: fieldPath).flatMap(CanvasSpecAlign.init)
                continue
            }
            if readStyleField(key, field, into: &inline, kind: kind, path: fieldPath) { continue }
            switch key {
            case "id":
                readID(field, into: &node, path: fieldPath)
            case "at":
                node.at = Self.point(field)
                if node.at == nil { issue(fieldPath, "expected [x, y]") }
            case "shift":
                if let point = Self.point(field) {
                    node.shift = CGVector(dx: point.x, dy: point.y)
                } else {
                    issue(fieldPath, "expected [dx, dy]")
                }
            case "style":
                break
            case "group":
                if let flag = field.boolValue { node.group = flag } else { issue(fieldPath, "expected true or false") }
            case "locked":
                if let flag = field.boolValue { node.locked = flag } else { issue(fieldPath, "expected true or false") }
            case "link":
                node.link = field.stringValue
                if node.link == nil { issue(fieldPath, "expected a URL string") }
            case "name":
                if kind == .frame {
                    issue(fieldPath, "a frame's name is its title: {\"frame\": \"Title\"}")
                } else if kind.isLayout {
                    issue(fieldPath, "a \(kindName) isn't drawn, so nothing shows its name; name the boxes in it")
                } else if let text = field.stringValue {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    node.name = trimmed.isEmpty ? nil : trimmed
                } else if field != .null {
                    issue(fieldPath, "expected the text to show on hover")
                }
            case "width" where allowed.contains("width"):
                if field.stringValue == "fill" {
                    node.width = .fill
                } else if let value = positive(field, path: fieldPath) {
                    node.width = .fixed(value)
                }
            case "height" where allowed.contains(key):
                node.height = positive(field, path: fieldPath)
            case "minWidth" where allowed.contains(key):
                node.minWidth = positive(field, path: fieldPath)
            case "minHeight" where allowed.contains(key):
                node.minHeight = positive(field, path: fieldPath)
            case "maxWidth" where allowed.contains(key):
                node.maxWidth = positive(field, path: fieldPath)
            case "gap" where allowed.contains(key):
                if let pair = field.arrayValue, pair.count == 2, let x = pair[0].doubleValue, let y = pair[1].doubleValue {
                    node.gap = x
                    node.rowGap = y
                } else {
                    node.gap = nonNegative(field, path: fieldPath)
                }
            case "rowGap" where allowed.contains(key):
                node.rowGap = nonNegative(field, path: fieldPath)
            case "padding" where allowed.contains(key):
                node.padding = insets(field, path: fieldPath)
            case "columns" where allowed.contains(key):
                if let count = field.intValue, count >= 1, count <= 100 {
                    node.columns = count
                } else {
                    issue(fieldPath, "expected a whole number from 1 to 100")
                }
            case "columnWidth" where allowed.contains(key):
                node.columnWidth = positive(field, path: fieldPath)
            case "wrap" where allowed.contains(key):
                if let flag = field.boolValue { node.wrap = flag } else { issue(fieldPath, "expected true or false") }
            case "children" where allowed.contains(key):
                if let array = field.arrayValue {
                    node.children = readNodes(array, path: fieldPath)
                } else {
                    issue(fieldPath, "expected an array of nodes")
                }
            case "from" where allowed.contains(key):
                node.from = endpoint(field, path: fieldPath)
            case "to" where allowed.contains(key):
                node.to = endpoint(field, path: fieldPath)
            case "fromSide" where allowed.contains(key):
                node.fromSide = choice(field, ["left", "right", "top", "bottom"], path: fieldPath).flatMap(CanvasSpecSide.init)
            case "toSide" where allowed.contains(key):
                node.toSide = choice(field, ["left", "right", "top", "bottom"], path: fieldPath).flatMap(CanvasSpecSide.init)
            case "route" where allowed.contains(key):
                node.elbow = choice(field, ["straight", "elbow"], path: fieldPath) == "elbow"
            default:
                if kind.isShape, kindKeys.isEmpty == false, key == "label" {
                    issue(fieldPath, "put the label in \"\(kindName)\": {\"\(kindName)\": \"Label\"}")
                } else {
                    unknownKey(key, path: path, candidates: allowed)
                }
            }
        }
        node.style = inline.over(style)

        validate(&node, kindName: kindName)
        return node
    }

    private mutating func validate(_ node: inout CanvasSpecNode, kindName: String) {
        let path = node.path
        if node.kind.isConnector {
            if node.from == nil { issue(path, "an \(kindName) needs \"from\": an element id or [x, y]") }
            if node.to == nil { issue(path, "an \(kindName) needs \"to\": an element id or [x, y]") }
            if node.fromSide != nil || node.toSide != nil { node.elbow = true }
        }
        if node.kind.isShape, !node.children.isEmpty, !node.content.isEmpty {
            issue(path, "a \(kindName) has a label or children, not both; put the text in a child")
        }
        if node.kind == .grid, node.columns == nil {
            issue(path, "a grid needs \"columns\"")
        }
        if node.kind == .frame {
            for child in node.children where Self.containsFrame(child) {
                issue(child.path, "frames can't contain frames")
            }
        }
    }

    private static func containsFrame(_ node: CanvasSpecNode) -> Bool {
        node.kind == .frame || node.children.contains(where: containsFrame)
    }

    private mutating func readRaw(_ object: [String: CanvasJSON], path: String) -> CanvasSpecNode? {
        var node = CanvasSpecNode(kind: .raw, path: path)
        guard let type = object["type"]?.stringValue, !type.isEmpty else {
            issue("\(path).type", "expected an Excalidraw element type such as \"rectangle\"")
            return nil
        }
        if let kind = Self.kindAliases[type], type != "rectangle", type != "ellipse", type != "diamond",
           type != "arrow", type != "line", type != "text", type != "frame" {
            issue("\(path).type", "\"type\" marks a raw Excalidraw element; for a \(kind.rawValue) node write {\"\(type)\": ...}")
            return nil
        }
        if let id = object["id"] {
            readID(id, into: &node, path: "\(path).id")
        }
        node.raw = .object(object)
        return node
    }

    private mutating func readID(_ value: CanvasJSON, into node: inout CanvasSpecNode, path: String) {
        guard let id = value.stringValue, CanvasSpecNames.isValidID(id) else {
            issue(path, "ids are strings of letters, digits, and _ - . (up to 128 characters)")
            return
        }
        if let first = seenIDs[id] {
            issue(path, "id \"\(id)\" is already used at \(first)")
            return
        }
        seenIDs[id] = path
        node.id = id
    }

    // MARK: Values

    static func point(_ value: CanvasJSON) -> CGPoint? {
        guard let pair = value.arrayValue, pair.count == 2,
              let x = pair[0].doubleValue, let y = pair[1].doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    private mutating func endpoint(_ value: CanvasJSON, path: String) -> CanvasSpecEndpoint? {
        if let id = value.stringValue { return .element(id) }
        if let point = Self.point(value) { return .point(point) }
        issue(path, "expected an element id or [x, y]")
        return nil
    }

    private mutating func color(_ value: CanvasJSON, role: CanvasSpecNames.ColorRole, path: String) -> String? {
        guard let name = value.stringValue, let color = CanvasSpecNames.color(name, role: role) else {
            let word = value.stringValue?.split(separator: ".").first.map(String.init)
            let hint = word.flatMap { CanvasSpecNames.suggestion(for: $0, in: Array(CanvasSpecNames.palette.keys) + ["black", "white", "transparent"]) }
            issue(path, "unknown color; use #rrggbb, transparent, black, white, or a palette name like blue or blue.2"
                + (hint.map { " (did you mean \"\($0)\"?)" } ?? ""))
            return nil
        }
        return color
    }

    private mutating func choice(_ value: CanvasJSON, _ options: some Collection<String>, path: String) -> String? {
        guard let text = value.stringValue, options.contains(text) else {
            issue(path, "expected one of \(options.sorted().joined(separator: ", "))")
            return nil
        }
        return text
    }

    private mutating func number(_ value: CanvasJSON, names: [String: Double], range: ClosedRange<Double>, path: String) -> Double? {
        if let name = value.stringValue, let number = names[name.lowercased()] { return number }
        guard let number = value.doubleValue, range.contains(number) else {
            let words = names.keys.sorted().joined(separator: ", ")
            issue(path, "expected a number from \(CanvasJSON.format(range.lowerBound)) to \(CanvasJSON.format(range.upperBound))"
                + (words.isEmpty ? "" : " or one of \(words)"))
            return nil
        }
        return number
    }

    private mutating func positive(_ value: CanvasJSON, path: String) -> Double? {
        guard let number = value.doubleValue, number > 0, number < 1_000_000 else {
            issue(path, "expected a positive number")
            return nil
        }
        return number
    }

    private mutating func nonNegative(_ value: CanvasJSON, path: String) -> Double? {
        guard let number = value.doubleValue, number >= 0, number < 1_000_000 else {
            issue(path, "expected a number of 0 or more")
            return nil
        }
        return number
    }

    private mutating func insets(_ value: CanvasJSON, path: String) -> CanvasSpecInsets? {
        if let all = value.doubleValue, all >= 0 { return CanvasSpecInsets(all) }
        if let list = value.arrayValue?.compactMap(\.doubleValue), list.count == value.arrayValue?.count {
            switch list.count {
            case 2: return CanvasSpecInsets(vertical: list[0], horizontal: list[1])
            case 4: return CanvasSpecInsets(top: list[0], right: list[1], bottom: list[2], left: list[3])
            default: break
            }
        }
        issue(path, "expected a number, [vertical, horizontal], or [top, right, bottom, left]")
        return nil
    }

    private mutating func unknownKey(_ key: String, path: String, candidates: [String]) {
        let hint = CanvasSpecNames.suggestion(for: key, in: candidates)
        issue(path.isEmpty ? key : "\(path).\(key)", "unknown field"
            + (hint.map { " (did you mean \"\($0)\"?)" } ?? ""))
    }

    private mutating func issue(_ path: String, _ message: String) {
        issues.append(CanvasSpecIssue(path: path, message: message))
    }
}
