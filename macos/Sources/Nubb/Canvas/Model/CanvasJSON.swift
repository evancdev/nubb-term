import Foundation

/// A JSON value. Canvas elements keep every field Nubb doesn't model as one of
/// these, so opening and saving a file never drops data that Excalidraw or
/// another tool wrote.
enum CanvasJSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CanvasJSON])
    case object([String: CanvasJSON])
}

// MARK: - Accessors

extension CanvasJSON {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }

    var intValue: Int? {
        guard let value = doubleValue, abs(value) < 9.0e18 else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [CanvasJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: CanvasJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> CanvasJSON? {
        objectValue?[key]
    }

    /// True for values that print on one line inside an array.
    fileprivate var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }
}

// MARK: - Parsing

extension CanvasJSON {
    struct ParseError: Error, Equatable {
        var offset: Int
        var message: String
    }

    /// Parses JSON text. Numbers go through Swift's correctly rounded
    /// `Double(_:)`, so a file read back after saving compares equal.
    static func parse(_ data: Data) throws -> CanvasJSON {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            parser.skipBOM()
            let value = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.isAtEnd else { throw parser.error("unexpected text after the JSON value") }
            return value
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        /// Deeper nesting than any drawing needs, and well under the stack limit.
        static let maxDepth = 512

        var isAtEnd: Bool { index >= bytes.count }

        func error(_ message: String) -> ParseError {
            ParseError(offset: index, message: message)
        }

        mutating func skipBOM() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x0A, 0x0D, 0x09: index += 1
                default: return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> CanvasJSON {
            guard depth < Self.maxDepth else { throw error("nesting is too deep") }
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func expect(_ word: String) throws {
            for byte in word.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw error("invalid literal") }
                index += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> CanvasJSON {
            index += 1
            var members: [String: CanvasJSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                // Like JavaScript, a repeated key keeps its last value.
                members[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw error("expected ',' or '}'")
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> CanvasJSON {
            index += 1
            var values: [CanvasJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                values.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(values)
                } else {
                    throw error("expected ',' or ']'")
                }
            }
        }

        mutating func parseNumber() throws -> Double {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    digits += 1
                } else if byte != UInt8(ascii: ".") && byte != UInt8(ascii: "e") && byte != UInt8(ascii: "E")
                            && byte != UInt8(ascii: "+") && byte != UInt8(ascii: "-") {
                    break
                }
                index += 1
            }
            guard digits > 0,
                  let text = String(bytes: bytes[start..<index], encoding: .ascii),
                  let value = Double(text) else {
                index = start
                throw error("invalid number")
            }
            return value
        }

        mutating func parseString() throws -> String {
            index += 1
            var buffer: [UInt8] = []
            var chunkStart = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    buffer.append(contentsOf: bytes[chunkStart..<index])
                    index += 1
                    guard let string = String(bytes: buffer, encoding: .utf8) else {
                        throw error("invalid UTF-8 in string")
                    }
                    return string
                }
                if byte == UInt8(ascii: "\\") {
                    buffer.append(contentsOf: bytes[chunkStart..<index])
                    index += 1
                    try parseEscape(into: &buffer)
                    chunkStart = index
                    continue
                }
                index += 1
            }
            throw error("unterminated string")
        }

        mutating func parseEscape(into buffer: inout [UInt8]) throws {
            guard index < bytes.count else { throw error("unterminated escape") }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try parseHex4()
                // A surrogate pair encodes one character outside the BMP.
                if (0xD800...0xDBFF).contains(scalar),
                   index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"),
                   bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                    }
                }
                let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(character).utf8))
            default:
                throw error("invalid escape")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw error("invalid unicode escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw error("invalid unicode escape")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }
    }
}

// MARK: - Writing

extension CanvasJSON {
    /// Pretty JSON with sorted keys and two-space indents. Arrays of scalars
    /// such as points stay on one line, so files diff well and are easy for
    /// people and agents to read.
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out.append("\n")
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null:
            out.append("null")
        case .bool(let value):
            out.append(value ? "true" : "false")
        case .number(let value):
            out.append(Self.format(value))
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let values):
            writeArray(values, into: &out, indent: indent)
        case .object(let members):
            writeObject(members, into: &out, indent: indent)
        }
    }

    private func writeArray(_ values: [CanvasJSON], into out: inout String, indent: Int) {
        guard !values.isEmpty else {
            out.append("[]")
            return
        }

        if values.allSatisfy(\.isScalar) {
            out.append("[")
            for (index, value) in values.enumerated() {
                if index > 0 { out.append(", ") }
                value.write(into: &out, indent: indent)
            }
            out.append("]")
            return
        }

        let inner = String(repeating: " ", count: indent + 2)
        out.append("[\n")
        for (index, value) in values.enumerated() {
            out.append(inner)
            value.write(into: &out, indent: indent + 2)
            out.append(index < values.count - 1 ? ",\n" : "\n")
        }
        out.append(String(repeating: " ", count: indent))
        out.append("]")
    }

    private func writeObject(_ members: [String: CanvasJSON], into out: inout String, indent: Int) {
        guard !members.isEmpty else {
            out.append("{}")
            return
        }

        let inner = String(repeating: " ", count: indent + 2)
        let keys = members.keys.sorted()
        out.append("{\n")
        for (index, key) in keys.enumerated() {
            out.append(inner)
            Self.writeString(key, into: &out)
            out.append(": ")
            members[key]?.write(into: &out, indent: indent + 2)
            out.append(index < keys.count - 1 ? ",\n" : "\n")
        }
        out.append(String(repeating: " ", count: indent))
        out.append("}")
    }

    /// Whole numbers print without a fraction, others in Swift's shortest
    /// round-trip form. JSON has no NaN or infinity, so those become null.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    private static func writeString(_ value: String, into out: inout String) {
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                // Control characters must be escaped. U+2028 and U+2029 are
                // valid JSON but break JavaScript string literals.
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}
