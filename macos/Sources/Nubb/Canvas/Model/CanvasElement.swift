import CoreGraphics
import Foundation

/// The kind of a canvas element, named as in Excalidraw files.
enum CanvasElementType: Hashable {
    case rectangle
    case diamond
    case ellipse
    case line
    case arrow
    case freedraw
    case text
    case image
    case frame
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "rectangle": self = .rectangle
        case "diamond": self = .diamond
        case "ellipse": self = .ellipse
        case "line": self = .line
        case "arrow": self = .arrow
        case "freedraw": self = .freedraw
        case "text": self = .text
        case "image": self = .image
        case "frame": self = .frame
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .rectangle: "rectangle"
        case .diamond: "diamond"
        case .ellipse: "ellipse"
        case .line: "line"
        case .arrow: "arrow"
        case .freedraw: "freedraw"
        case .text: "text"
        case .image: "image"
        case .frame: "frame"
        case .other(let name): name
        }
    }

    /// Lines and arrows, drawn through `points`.
    var isLinear: Bool { self == .line || self == .arrow }

    /// Elements whose geometry is `points` rather than a box.
    var hasPoints: Bool { isLinear || self == .freedraw }

    /// Shapes that can hold a text label.
    var isContainer: Bool { self == .rectangle || self == .diamond || self == .ellipse }

    /// Elements arrows can attach to.
    var isBindable: Bool { isContainer || self == .text || self == .image || self == .frame }

    /// Elements with a sharp or round edges choice.
    var supportsRoundness: Bool { self == .rectangle || self == .diamond || isLinear }
}

/// Corner rounding of a shape, or curving of a line. Excalidraw's types:
/// 1 legacy, 2 proportional, 3 adaptive.
struct CanvasRoundness: Equatable {
    var type: Int
    var value: Double?

    static let proportional = CanvasRoundness(type: 2)
    static let adaptive = CanvasRoundness(type: 3)

    init(type: Int, value: Double? = nil) {
        self.type = type
        self.value = value
    }

    init?(json: CanvasJSON?) {
        guard let json, let type = json["type"]?.intValue else { return nil }
        self.type = type
        self.value = json["value"]?.doubleValue
    }

    var json: CanvasJSON {
        var object: [String: CanvasJSON] = ["type": .number(Double(type))]
        if let value { object["value"] = .number(value) }
        return .object(object)
    }
}

/// An element attached to another one: an arrow bound to a shape, or the
/// label inside a container.
struct CanvasBoundElement: Equatable {
    var id: String
    var type: String

    init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    init?(json: CanvasJSON) {
        guard let id = json["id"]?.stringValue, let type = json["type"]?.stringValue else { return nil }
        self.id = id
        self.type = type
    }

    var json: CanvasJSON {
        .object(["id": .string(id), "type": .string(type)])
    }
}

/// The shape one end of an arrow is attached to. A focus of 0 aims the
/// arrow at the shape's center. `fixedPoint`, written by newer Excalidraw
/// versions, pins the end to a spot in the shape's box instead.
struct CanvasBinding: Equatable {
    var elementId: String
    var focus: Double = 0
    var gap: Double = 0
    var extra: [String: CanvasJSON] = [:]
    /// Whether to write `focus` and `gap`. Files with neither keep it that
    /// way.
    var writesFocus = true

    init(elementId: String, focus: Double = 0, gap: Double = 0) {
        self.elementId = elementId
        self.focus = focus
        self.gap = gap
    }

    init?(json: CanvasJSON?) {
        guard var fields = json?.objectValue,
              let elementId = fields.removeValue(forKey: "elementId")?.stringValue else { return nil }
        self.elementId = elementId
        let focus = fields.removeValue(forKey: "focus")
        let gap = fields.removeValue(forKey: "gap")
        self.focus = focus?.doubleValue ?? 0
        self.gap = gap?.doubleValue ?? 0
        self.extra = fields
        writesFocus = focus != nil || gap != nil
    }

    /// The pinned spot as fractions of the bound element's box, if any.
    var fixedPoint: CGPoint? {
        guard let pair = extra["fixedPoint"]?.arrayValue, pair.count == 2,
              let x = pair[0].doubleValue, let y = pair[1].doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Excalidraw's binding mode, from files it wrote since 2025: `orbit`
    /// aims the end at `fixedPoint` and stops it outside the outline,
    /// `inside` puts it on `fixedPoint`.
    var mode: String? { extra["mode"]?.stringValue }

    /// A binding in Excalidraw's current format, which it reads without
    /// converting: the end aims at `fixedPoint` (fractions of the target's
    /// box) and stops outside the outline. Excalidraw writes these with
    /// focus and gap 0; the gap comes from the target's stroke instead.
    static func orbit(_ elementId: String, fixedPoint: CGPoint) -> CanvasBinding {
        var binding = CanvasBinding(elementId: elementId, focus: 0, gap: 0)
        binding.extra["mode"] = .string("orbit")
        binding.extra["fixedPoint"] = .array([.number(Double(fixedPoint.x)), .number(Double(fixedPoint.y))])
        return binding
    }

    /// Excalidraw nudges fixed points off exactly 0.5, which makes arrow
    /// headings jump, and keeps them within 10 box sizes.
    static func normalizedFixedPoint(_ point: CGPoint) -> CGPoint {
        func fix(_ value: Double) -> Double {
            let clamped = min(max(value, -10), 10)
            let rounded = (clamped * 10_000).rounded() / 10_000
            return abs(rounded - 0.5) < 0.0001 ? 0.5001 : rounded
        }
        return CGPoint(x: fix(Double(point.x)), y: fix(Double(point.y)))
    }

    /// Excalidraw's gap between a bound end and the outline it orbits.
    static func orbitGap(for element: CanvasElement) -> Double {
        5 + element.strokeWidth / 2
    }

    var json: CanvasJSON {
        var object = extra
        object["elementId"] = .string(elementId)
        if writesFocus {
            object["focus"] = .number(focus)
            object["gap"] = .number(gap)
        }
        return .object(object)
    }
}

/// One element of a drawing, in Excalidraw's file format.
///
/// Fields Nubb uses are typed. Every other field is kept in `extra` and
/// written back unchanged, so files from Excalidraw or other tools survive
/// a round trip. Style fields stay strings so values Nubb doesn't know are
/// kept too.
struct CanvasElement: Equatable {
    var id: String
    var type: CanvasElementType
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var angle: Double = 0
    var strokeColor: String = CanvasStyle.defaultStrokeColor
    var backgroundColor: String = CanvasColor.transparentName
    var fillStyle: String = "solid"
    var strokeWidth: Double = 2
    var strokeStyle: String = "solid"
    var roughness: Double = 1
    var opacity: Double = 100
    var roundness: CanvasRoundness?
    var seed: Int = 1
    var version: Int = 1
    var versionNonce: Int = 0
    var groupIds: [String] = []
    var boundElements: [CanvasBoundElement]?
    var updated: Double = 0
    var locked: Bool = false
    var link: String?
    /// The frame this element belongs to. Frames clip their elements.
    var frameId: String?

    // Text
    var text: String = ""
    var originalText: String = ""
    var fontSize: Double = 20
    var fontFamily: Int = CanvasFont.Family.handDrawn.rawValue
    var textAlign: String = "left"
    var verticalAlign: String = "top"
    var containerId: String?
    var lineHeight: Double = 1.25
    var autoResize: Bool = true

    // Lines, arrows and freehand strokes
    var points: [CGPoint] = []
    var pressures: [Double] = []
    var simulatePressure: Bool = true
    var startBinding: CanvasBinding?
    var endBinding: CanvasBinding?
    var startArrowhead: String?
    var endArrowhead: String?

    /// Fields Nubb doesn't model, written back unchanged.
    var extra: [String: CanvasJSON] = [:]

    init(id: String = CanvasRandom.id(), type: CanvasElementType) {
        self.id = id
        self.type = type
        self.seed = CanvasRandom.seed()
        self.versionNonce = CanvasRandom.seed()
        self.updated = CanvasRandom.timestamp()
    }
}

// MARK: - Style accessors

extension CanvasElement {
    var isTransparentBackground: Bool {
        CanvasColor.isTransparent(backgroundColor)
    }

    /// The label inside this container, if any.
    var boundTextID: String? {
        boundElements?.first { $0.type == "text" }?.id
    }

    /// A frame's name. Nubb doesn't draw it, but finds frames by it;
    /// Excalidraw shows it above the frame, or "Frame" when unset.
    var frameName: String? {
        get { extra["name"]?.stringValue }
        set { extra["name"] = newValue.map(CanvasJSON.string) ?? .null }
    }

    /// A name shown when the pointer rests on the element. It's kept in
    /// `customData`, which Excalidraw saves as is, so the name survives
    /// editing the file in Excalidraw or Obsidian.
    var hoverName: String? {
        get {
            guard let name = extra["customData"]?["name"]?.stringValue else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        set {
            var data = extra["customData"]?.objectValue ?? [:]
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            data["name"] = trimmed.isEmpty ? nil : .string(trimmed)
            extra["customData"] = data.isEmpty ? nil : .object(data)
        }
    }

    /// An arrow drawn with right angles that Excalidraw routes around shapes.
    var isElbowArrow: Bool {
        type == .arrow && extra["elbowed"]?.boolValue == true
    }

    mutating func addBoundElement(id: String, type: String) {
        var list = boundElements ?? []
        guard !list.contains(where: { $0.id == id }) else { return }
        list.append(CanvasBoundElement(id: id, type: type))
        boundElements = list
    }

    mutating func removeBoundElement(id: String) {
        guard var list = boundElements else { return }
        list.removeAll { $0.id == id }
        boundElements = list.isEmpty ? nil : list
    }
}

// MARK: - JSON

extension CanvasElement {
    /// Decodes an element. `fallbackID` names elements written without an id,
    /// which hand-written and agent-written files often omit.
    init?(json: CanvasJSON, fallbackID: String? = nil) {
        guard var fields = json.objectValue,
              let typeName = fields.removeValue(forKey: "type")?.stringValue, !typeName.isEmpty else { return nil }
        let decodedID = fields.removeValue(forKey: "id")?.stringValue ?? ""
        guard let id = decodedID.isEmpty ? fallbackID : decodedID else { return nil }

        func take(_ key: String) -> CanvasJSON? { fields.removeValue(forKey: key) }

        self.init(id: id, type: CanvasElementType(rawValue: typeName))

        // Missing random fields get values derived from the id, so reading
        // the same file twice yields equal elements that draw the same way.
        seed = CanvasRandom.stableSeed(id)
        versionNonce = 0
        updated = 0

        // The array order is the z-order. Fractional `index` keys from newer
        // Excalidraw versions go stale as soon as elements move, and
        // Excalidraw rebuilds them from the order when they are missing.
        _ = take("index")
        _ = take("isDeleted")

        x = take("x")?.doubleValue ?? 0
        y = take("y")?.doubleValue ?? 0
        width = take("width")?.doubleValue ?? 0
        height = take("height")?.doubleValue ?? 0
        angle = take("angle")?.doubleValue ?? 0
        strokeColor = take("strokeColor")?.stringValue ?? CanvasStyle.defaultStrokeColor
        backgroundColor = take("backgroundColor")?.stringValue ?? CanvasColor.transparentName
        fillStyle = take("fillStyle")?.stringValue ?? "solid"
        strokeWidth = take("strokeWidth")?.doubleValue ?? 2
        strokeStyle = take("strokeStyle")?.stringValue ?? "solid"
        roughness = take("roughness")?.doubleValue ?? 1
        opacity = take("opacity")?.doubleValue ?? 100
        roundness = CanvasRoundness(json: take("roundness"))
        if let value = take("seed")?.intValue { seed = value }
        version = take("version")?.intValue ?? 1
        if let value = take("versionNonce")?.intValue { versionNonce = value }
        groupIds = take("groupIds")?.arrayValue?.compactMap(\.stringValue) ?? []
        boundElements = take("boundElements")?.arrayValue?.compactMap(CanvasBoundElement.init(json:))
        if let value = take("updated")?.doubleValue { updated = value }
        locked = take("locked")?.boolValue ?? false
        link = take("link")?.stringValue
        frameId = take("frameId")?.stringValue

        switch type {
        case .text:
            text = take("text")?.stringValue ?? ""
            originalText = take("originalText")?.stringValue ?? text
            fontSize = take("fontSize")?.doubleValue ?? 20
            fontFamily = take("fontFamily")?.intValue ?? CanvasFont.Family.handDrawn.rawValue
            textAlign = take("textAlign")?.stringValue ?? "left"
            verticalAlign = take("verticalAlign")?.stringValue ?? "top"
            containerId = take("containerId")?.stringValue
            lineHeight = take("lineHeight")?.doubleValue ?? 1.25
            autoResize = take("autoResize")?.boolValue ?? true

        case .line, .arrow:
            points = Self.decodePoints(take("points"))
            startBinding = CanvasBinding(json: take("startBinding"))
            endBinding = CanvasBinding(json: take("endBinding"))
            startArrowhead = take("startArrowhead")?.stringValue
            endArrowhead = take("endArrowhead")?.stringValue

        case .freedraw:
            points = Self.decodePoints(take("points"))
            pressures = take("pressures")?.arrayValue?.compactMap(\.doubleValue) ?? []
            simulatePressure = take("simulatePressure")?.boolValue ?? true

        default:
            break
        }

        extra = fields
    }

    var json: CanvasJSON {
        var object = extra
        object["id"] = .string(id)
        object["type"] = .string(type.rawValue)
        object["x"] = .number(x)
        object["y"] = .number(y)
        object["width"] = .number(width)
        object["height"] = .number(height)
        object["angle"] = .number(angle)
        object["strokeColor"] = .string(strokeColor)
        object["backgroundColor"] = .string(backgroundColor)
        object["fillStyle"] = .string(fillStyle)
        object["strokeWidth"] = .number(strokeWidth)
        object["strokeStyle"] = .string(strokeStyle)
        object["roughness"] = .number(roughness)
        object["opacity"] = .number(opacity)
        object["roundness"] = roundness?.json ?? .null
        object["seed"] = .number(Double(seed))
        object["version"] = .number(Double(version))
        object["versionNonce"] = .number(Double(versionNonce))
        object["isDeleted"] = .bool(false)
        object["groupIds"] = .array(groupIds.map(CanvasJSON.string))
        object["boundElements"] = boundElements.map { .array($0.map(\.json)) } ?? .null
        object["updated"] = .number(updated)
        object["locked"] = .bool(locked)
        object["link"] = link.map(CanvasJSON.string) ?? .null
        object["frameId"] = frameId.map(CanvasJSON.string) ?? .null

        switch type {
        case .text:
            object["text"] = .string(text)
            object["originalText"] = .string(originalText)
            object["fontSize"] = .number(fontSize)
            object["fontFamily"] = .number(Double(fontFamily))
            object["textAlign"] = .string(textAlign)
            object["verticalAlign"] = .string(verticalAlign)
            object["containerId"] = containerId.map(CanvasJSON.string) ?? .null
            object["lineHeight"] = .number(lineHeight)
            object["autoResize"] = .bool(autoResize)

        case .line, .arrow:
            object["points"] = Self.encodePoints(points)
            object["startBinding"] = startBinding?.json ?? .null
            object["endBinding"] = endBinding?.json ?? .null
            object["startArrowhead"] = startArrowhead.map(CanvasJSON.string) ?? .null
            object["endArrowhead"] = endArrowhead.map(CanvasJSON.string) ?? .null

        case .freedraw:
            object["points"] = Self.encodePoints(points)
            object["pressures"] = .array(pressures.map(CanvasJSON.number))
            object["simulatePressure"] = .bool(simulatePressure)

        default:
            break
        }

        return .object(object)
    }

    /// Whether `json` describes a deleted element. Deleted elements are
    /// dropped when a file is read.
    static func isDeleted(_ json: CanvasJSON) -> Bool {
        json["isDeleted"]?.boolValue ?? false
    }

    private static func decodePoints(_ json: CanvasJSON?) -> [CGPoint] {
        json?.arrayValue?.compactMap { item in
            guard let pair = item.arrayValue, pair.count >= 2,
                  let x = pair[0].doubleValue, let y = pair[1].doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        } ?? []
    }

    private static func encodePoints(_ points: [CGPoint]) -> CanvasJSON {
        .array(points.map { .array([.number(Double($0.x)), .number(Double($0.y))]) })
    }
}

// MARK: - Random values

enum CanvasRandom {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")

    /// A 21 character id, the length Excalidraw's nanoid ids use.
    static func id() -> String {
        String((0..<21).map { _ in alphabet.randomElement()! })
    }

    /// A positive 31-bit integer, as Excalidraw uses for seeds and nonces.
    static func seed() -> Int {
        Int.random(in: 1..<(1 << 31))
    }

    /// A positive 31-bit integer derived from `text` (FNV-1a), stable across
    /// launches unlike `hashValue`.
    static func stableSeed(_ text: String) -> Int {
        Int(stableHash(text) % 0x7FFF_FFFE) + 1
    }

    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Milliseconds since 1970, Excalidraw's `updated` field.
    static func timestamp() -> Double {
        (Date().timeIntervalSince1970 * 1000).rounded()
    }
}
