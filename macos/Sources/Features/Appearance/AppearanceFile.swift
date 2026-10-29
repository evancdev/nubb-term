import Foundation

/// An sRGB color as written in Nubb config files.
struct ThemeRGB: Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

extension ThemeRGB {
    /// Parses `#rrggbb`, `rrggbb`, `#rgb`, or `rgb`.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    /// Lowercase `#rrggbb`.
    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// The single-value color options a theme or the Appearance window can set.
enum ThemeColorKey: String, CaseIterable, Identifiable {
    case background
    case foreground
    case cursorColor = "cursor-color"
    case cursorText = "cursor-text"
    case selectionBackground = "selection-background"
    case selectionForeground = "selection-foreground"

    var id: String { rawValue }
}

/// One row in the Appearance window's color list: a single option or one of
/// the 16 palette colors.
enum ColorSlot: Hashable, Identifiable {
    case key(ThemeColorKey)
    case palette(Int)

    /// Every editable color in the order the window lists them: what Nubb
    /// draws on its own first, then the palette by how often it shows up.
    static let all: [ColorSlot] = [
        .key(.background), .key(.foreground),
        .key(.cursorColor), .key(.cursorText),
        .key(.selectionBackground), .key(.selectionForeground),
        .palette(1), .palette(2), .palette(3), .palette(4), .palette(5), .palette(6),
        .palette(8), .palette(7), .palette(0),
        .palette(9), .palette(10), .palette(11), .palette(12), .palette(13), .palette(14), .palette(15),
    ]

    var id: String {
        switch self {
        case .key(let key): key.rawValue
        case .palette(let index): "palette-\(index)"
        }
    }

    var name: String {
        switch self {
        case .key(.background): "Background"
        case .key(.foreground): "Text"
        case .key(.cursorColor): "Cursor"
        case .key(.cursorText): "Cursor text"
        case .key(.selectionBackground): "Selection"
        case .key(.selectionForeground): "Selection text"
        case .palette(let index): Self.paletteNames[index] ?? "Color \(index)"
        }
    }

    /// Where the color typically shows up. Programs choose which colors
    /// they use, so these are examples, not rules.
    var usage: String {
        switch self {
        case .key(.background): "Behind everything"
        case .key(.foreground): "Plain text"
        case .key(.cursorColor): "The block cursor"
        case .key(.cursorText): "The letter under the cursor"
        case .key(.selectionBackground): "Behind text you select"
        case .key(.selectionForeground): "Text you select"
        case .palette(let index): Self.paletteUsage[index] ?? ""
        }
    }

    private static let paletteNames: [Int: String] = [
        0: "Black", 1: "Red", 2: "Green", 3: "Yellow",
        4: "Blue", 5: "Magenta", 6: "Cyan", 7: "White",
        8: "Gray", 9: "Bright red", 10: "Bright green", 11: "Bright yellow",
        12: "Bright blue", 13: "Bright magenta", 14: "Bright cyan", 15: "Bright white",
    ]

    private static let paletteUsage: [Int: String] = [
        0: "Text on colored labels", 1: "Removed lines, errors",
        2: "Added lines, prompts", 3: "Warnings, commit hashes",
        4: "Folders and paths", 5: "Git branch, symlinks",
        6: "Diff headers, git refs", 7: "Light text",
        8: "Dim text, timings", 9: "Failure counts",
        10: "Passed tests", 11: "Skipped tests, notices",
        12: "Info logs", 13: "Debug logs",
        14: "Links", 15: "Bold text, labels on red",
    ]
}

/// A set of colors from a theme file or from the user's overrides. Missing
/// entries fall through to whatever is underneath.
struct ThemeColors: Equatable {
    var values: [ThemeColorKey: ThemeRGB] = [:]
    var palette: [Int: ThemeRGB] = [:]

    var isEmpty: Bool { values.isEmpty && palette.isEmpty }

    /// Applies one config entry. Returns false if it isn't a color this type
    /// tracks or the value doesn't parse.
    @discardableResult
    mutating func apply(key: String, value: String) -> Bool {
        if key == "palette" {
            guard let eq = value.firstIndex(of: "=") else { return false }
            let index = value[..<eq].trimmingCharacters(in: .whitespaces)
            guard let idx = Int(index), (0...255).contains(idx),
                  let rgb = ThemeRGB(hex: String(value[value.index(after: eq)...])) else { return false }
            palette[idx] = rgb
            return true
        }

        guard let colorKey = ThemeColorKey(rawValue: key), let rgb = ThemeRGB(hex: value) else { return false }
        values[colorKey] = rgb
        return true
    }

    /// These colors with `top` layered over them.
    func merged(with top: ThemeColors) -> ThemeColors {
        var result = self
        result.values.merge(top.values) { _, new in new }
        result.palette.merge(top.palette) { _, new in new }
        return result
    }

    /// Parses the colors out of a theme or config file.
    init(parsing text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = NubbConfigLine.parse(String(line)) else { continue }
            apply(key: entry.key, value: entry.value)
        }
    }

    init() {}

    /// Nubb's built-in colors, used when nothing else sets one.
    static let nubbDefaults: ThemeColors = {
        var colors = ThemeColors()
        colors.values[.background] = ThemeRGB(r: 0x28, g: 0x2C, b: 0x34)
        colors.values[.foreground] = ThemeRGB(r: 0xFF, g: 0xFF, b: 0xFF)
        let palette: [UInt32] = [
            0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
            0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
        ]
        for (i, v) in palette.enumerated() {
            colors.palette[i] = ThemeRGB(r: UInt8(v >> 16), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
        }
        return colors
    }()
}

/// Every color the preview needs, with Nubb's fallbacks filled in.
struct ResolvedColors: Equatable {
    let background: ThemeRGB
    let foreground: ThemeRGB
    let cursor: ThemeRGB
    let cursorText: ThemeRGB
    let selectionBackground: ThemeRGB
    let selectionForeground: ThemeRGB
    let palette: [ThemeRGB]

    /// Resolves `colors` layered over Nubb's defaults. An unset cursor uses
    /// the text color, and an unset selection swaps text and background.
    init(_ colors: ThemeColors) {
        let full = ThemeColors.nubbDefaults.merged(with: colors)
        let bg = full.values[.background] ?? ThemeRGB(r: 0, g: 0, b: 0)
        let fg = full.values[.foreground] ?? ThemeRGB(r: 255, g: 255, b: 255)
        background = bg
        foreground = fg
        cursor = full.values[.cursorColor] ?? fg
        cursorText = full.values[.cursorText] ?? bg
        selectionBackground = full.values[.selectionBackground] ?? fg
        selectionForeground = full.values[.selectionForeground] ?? bg
        palette = (0..<16).map { full.palette[$0] ?? fg }
    }

    func value(for key: ThemeColorKey) -> ThemeRGB {
        switch key {
        case .background: background
        case .foreground: foreground
        case .cursorColor: cursor
        case .cursorText: cursorText
        case .selectionBackground: selectionBackground
        case .selectionForeground: selectionForeground
        }
    }

    subscript(slot: ColorSlot) -> ThemeRGB {
        switch slot {
        case .key(let key): value(for: key)
        case .palette(let index): palette[index]
        }
    }
}

extension ThemeColors {
    /// Sets one slot's color.
    mutating func set(_ slot: ColorSlot, _ color: ThemeRGB) {
        switch slot {
        case .key(let key): values[key] = color
        case .palette(let index): palette[index] = color
        }
    }
}

enum NubbConfigLine {
    /// Splits a `key = value` line. Returns nil for blank lines, comments,
    /// and lines without a key.
    static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}

/// The `theme` option: one theme, or separate light and dark themes.
/// A nil name means Nubb's default colors.
struct ThemeChoice: Equatable {
    var light: String?
    var dark: String?

    static let none = ThemeChoice(light: nil, dark: nil)

    init(light: String?, dark: String?) {
        self.light = light
        self.dark = dark
    }

    init(single name: String?) {
        self.init(light: name, dark: name)
    }

    /// True when light and dark mode use different themes.
    var isPair: Bool { light != dark }

    /// Parses a `theme` value such as `Nord` or `light:Nord Light,dark:Nord`.
    init?(configValue: String) {
        let value = configValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        guard value.contains(",") || value.contains(":") else {
            self.init(single: value)
            return
        }

        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let mode = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let name = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            switch mode {
            case "light": light = name
            case "dark": dark = name
            default: return nil
            }
        }
        guard let lightName = light, let darkName = dark else { return nil }
        self.init(light: lightName, dark: darkName)
    }

    /// The value to write for `theme`, or nil to write nothing.
    var configValue: String? {
        switch (light, dark) {
        case (nil, nil): nil
        case let (light?, dark?) where light == dark: light
        case let (light?, dark?): "light:\(light),dark:\(dark)"
        case let (light?, nil): light
        case let (nil, dark?): dark
        }
    }
}

/// What the Appearance menu and Edit Colors window manage: the `theme` line,
/// the shader effect, plus any color lines an older version of the window
/// wrote. Stored in `appearance.nubb` next to the main config file.
struct AppearanceSettings: Equatable {
    var theme: ThemeChoice = .none

    /// The path of the `custom-shader` file to use, or nil for no effect.
    var effect: String?

    /// False writes `custom-shader-animation = false`, so a shader that
    /// doesn't use the clock doesn't make terminals redraw every frame.
    var effectAnimates = true

    /// Colors set on top of the theme. The window no longer writes these.
    /// When it finds some, it folds them into a theme of your own.
    var overrides = ThemeColors()

    init() {}

    init(parsing text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = NubbConfigLine.parse(String(line)) else { continue }
            switch entry.key {
            case "theme":
                if let choice = ThemeChoice(configValue: entry.value) { theme = choice }
            case "custom-shader":
                // An empty value clears the shaders set so far.
                effect = entry.value.isEmpty ? nil : entry.value
            case "custom-shader-animation":
                // Match the config loader: an empty value resets to the
                // default, and a value it rejects leaves the last one.
                switch entry.value {
                case "", "true", "always": effectAnimates = true
                case "false": effectAnimates = false
                default: break
                }
            default:
                overrides.apply(key: entry.key, value: entry.value)
            }
        }
    }

    func serialized() -> String {
        var lines = [
            "# Written by the Nubb Appearance window. It replaces this file on each change.",
            "",
        ]
        if let value = theme.configValue { lines.append("theme = \(value)") }
        // A path with a line break can't be written as one config line.
        if let effect, !effect.contains(where: \.isNewline) {
            // The empty line drops any shader the main config set, so the
            // window's choice is the only effect.
            lines.append("custom-shader =")
            lines.append("custom-shader = \(effect)")
            if !effectAnimates { lines.append("custom-shader-animation = false") }
        }
        for key in ThemeColorKey.allCases {
            guard let color = overrides.values[key] else { continue }
            lines.append("\(key.rawValue) = \(color.hex)")
        }
        for (index, color) in overrides.palette.sorted(by: { $0.key < $1.key }) {
            lines.append("palette = \(index)=\(color.hex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A color theme as a file, in the same format as the bundled themes.
enum ThemeFile {
    /// Theme file text that sets every color, with Nubb's fallbacks filled
    /// in for anything `colors` leaves unset.
    static func text(for colors: ThemeColors) -> String {
        let resolved = ResolvedColors(colors)
        var lines: [String] = []
        for index in 0..<16 {
            lines.append("palette = \(index)=\(resolved.palette[index].hex)")
        }
        for (index, color) in colors.palette.sorted(by: { $0.key < $1.key }) where index >= 16 {
            lines.append("palette = \(index)=\(color.hex)")
        }
        for key in ThemeColorKey.allCases {
            lines.append("\(key.rawValue) = \(resolved.value(for: key).hex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    enum NameError: Error, Equatable, LocalizedError {
        case empty
        case invalidCharacter
        case taken

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a name."
            case .invalidCharacter: "Names can't start with a dot or contain / \\ : , or =."
            case .taken: "A theme with this name already exists."
            }
        }
    }

    /// Checks a name for a new theme file. Theme names become file names
    /// and `theme =` values, so they can't hold path separators or the
    /// characters that mark a light/dark pair.
    static func validate(name raw: String, existing: Set<String>) -> Result<String, NameError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty) }
        let banned = CharacterSet(charactersIn: "/\\:,=").union(.newlines)
        guard !name.hasPrefix("."), name.rangeOfCharacter(from: banned) == nil else {
            return .failure(.invalidCharacter)
        }
        guard !existing.contains(name) else { return .failure(.taken) }
        return .success(name)
    }

    /// A name like "Nord Custom" or "Nord Custom 2" that isn't taken.
    static func suggestedName(basedOn base: String?, existing: Set<String>) -> String {
        let stem = "\(base ?? "Nubb") Custom"
        if !existing.contains(stem) { return stem }
        var n = 2
        while existing.contains("\(stem) \(n)") { n += 1 }
        return "\(stem) \(n)"
    }
}

/// The include line that makes the main config load `appearance.nubb`.
enum AppearanceInclude {
    static let fileName = "appearance.nubb"
    static let directive = "config-file = ?\(fileName)"

    /// True if `config` already includes the appearance file.
    static func isPresent(in config: String) -> Bool {
        config.split(whereSeparator: \.isNewline).contains { line in
            guard let entry = NubbConfigLine.parse(String(line)), entry.key == "config-file" else { return false }
            var path = entry.value
            if path.hasPrefix("?") { path.removeFirst() }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (path as NSString).lastPathComponent == fileName
        }
    }

    /// The text to append to a config file that doesn't include it yet.
    static func appendText(after config: String) -> String {
        let lead = config.isEmpty || config.hasSuffix("\n") ? "" : "\n"
        return "\(lead)\n# Colors from the Nubb Appearance window.\n\(directive)\n"
    }
}
