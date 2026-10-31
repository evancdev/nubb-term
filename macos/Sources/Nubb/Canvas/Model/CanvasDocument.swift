import Foundation

/// A drawing in Excalidraw's file format (`.excalidraw`, JSON).
///
/// `elements` is in z-order, back to front. Top-level keys and `appState`
/// fields Nubb doesn't use are kept and written back unchanged.
struct CanvasDocument: Equatable {
    static let fileExtension = "excalidraw"
    static let fileType = "excalidraw"
    static let clipboardType = "excalidraw/clipboard"
    static let source = "https://github.com/evancdev/nubb"

    var elements: [CanvasElement] = []

    /// Excalidraw's `appState`, minus the per-user view state it doesn't
    /// save either. Nubb reads `viewBackgroundColor` from it.
    var appState: [String: CanvasJSON] = [
        "viewBackgroundColor": .string(CanvasPalette.canvasBackground),
        "gridSize": .number(20),
    ]

    /// Image data by file id (`dataURL`, `mimeType`, ...), kept as is.
    var files: [String: CanvasJSON] = [:]

    /// Other top-level keys.
    var extra: [String: CanvasJSON] = [:]

    var viewBackgroundColor: String {
        get { appState["viewBackgroundColor"]?.stringValue ?? CanvasPalette.canvasBackground }
        set { appState["viewBackgroundColor"] = .string(newValue) }
    }

    init(elements: [CanvasElement] = []) {
        self.elements = elements
    }

    func element(id: String) -> CanvasElement? {
        elements.first { $0.id == id }
    }
}

// MARK: - Errors

enum CanvasDocumentError: LocalizedError, Equatable {
    case notJSON
    case notAnObject
    case wrongType(String)
    case elementsNotAnArray

    var errorDescription: String? {
        switch self {
        case .notJSON: "The file is not valid JSON."
        case .notAnObject: "The file is not an Excalidraw drawing."
        case .wrongType(let type): "The file is a \"\(type)\" file, not an Excalidraw drawing."
        case .elementsNotAnArray: "The drawing's \"elements\" is not an array."
        }
    }
}

// MARK: - Coding

extension CanvasDocument {
    /// Reads a drawing. An empty file is an empty drawing, so a new file
    /// created with `touch` opens fine.
    static func decode(_ data: Data) throws -> CanvasDocument {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return CanvasDocument()
        }

        let json: CanvasJSON
        do {
            json = try CanvasJSON.parse(data)
        } catch {
            throw CanvasDocumentError.notJSON
        }
        return try decode(json)
    }

    static func decode(_ json: CanvasJSON) throws -> CanvasDocument {
        // A bare array of elements is accepted too, which is handy when an
        // agent writes the file by hand.
        if let array = json.arrayValue {
            return try decode(.object(["elements": .array(array)]))
        }

        guard var fields = json.objectValue else { throw CanvasDocumentError.notAnObject }

        if let type = fields["type"]?.stringValue, type != fileType, type != clipboardType {
            throw CanvasDocumentError.wrongType(type)
        }

        var document = CanvasDocument()
        if let elements = fields.removeValue(forKey: "elements") {
            guard let list = elements.arrayValue else { throw CanvasDocumentError.elementsNotAnArray }
            document.elements = decodeElements(list)
        }

        if let appState = fields.removeValue(forKey: "appState")?.objectValue {
            document.appState = appState
        }

        if let files = fields.removeValue(forKey: "files")?.objectValue {
            document.files = files
        }

        // These are rewritten on save.
        for key in ["type", "version", "source"] {
            fields.removeValue(forKey: key)
        }
        document.extra = fields
        return document
    }

    /// Decodes elements, dropping deleted and malformed ones, naming
    /// elements without an id, and renaming duplicate ids.
    private static func decodeElements(_ list: [CanvasJSON]) -> [CanvasElement] {
        var seen = Set<String>()
        var result: [CanvasElement] = []
        result.reserveCapacity(list.count)
        for (index, item) in list.enumerated() where !CanvasElement.isDeleted(item) {
            guard var element = CanvasElement(json: item, fallbackID: "element-\(index)") else { continue }
            if seen.contains(element.id) {
                element.id = "\(element.id)-\(index)"
            }
            seen.insert(element.id)
            result.append(element)
        }
        return result
    }

    var json: CanvasJSON {
        var object = extra
        object["type"] = .string(Self.fileType)
        object["version"] = .number(2)
        object["source"] = .string(Self.source)
        object["elements"] = .array(elements.map(\.json))
        object["appState"] = .object(appState)
        object["files"] = .object(files)
        return .object(object)
    }

    func encoded() -> Data {
        json.serialized()
    }

    /// The clipboard format Excalidraw reads when pasting.
    static func clipboardData(elements: [CanvasElement], files: [String: CanvasJSON]) -> Data {
        let usedFiles = Set(elements.compactMap { $0.extra["fileId"]?.stringValue })
        let object: [String: CanvasJSON] = [
            "type": .string(clipboardType),
            "elements": .array(elements.map(\.json)),
            "files": .object(files.filter { usedFiles.contains($0.key) }),
        ]
        return CanvasJSON.object(object).serialized()
    }
}
