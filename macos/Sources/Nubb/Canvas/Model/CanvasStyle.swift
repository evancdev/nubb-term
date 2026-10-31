import CoreGraphics
import CoreText
import Foundation

// MARK: - Theme

/// Light or dark canvas. Dark mode transforms every color the same way
/// Excalidraw does (`invert(93%) hue-rotate(180deg)`), so the file keeps the
/// light colors and drawings look the same in both apps.
enum CanvasTheme: Equatable {
    case light
    case dark
}

// MARK: - Colors

struct CanvasRGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#rrggbb`, or `#rrggbbaa` when not opaque.
    var hexString: String {
        func byte(_ value: Double) -> String {
            String(format: "%02x", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha < 1 ? rgb + byte(alpha) : rgb
    }
}

enum CanvasColor {
    static let transparentName = "transparent"

    /// Parses `transparent`, `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, and
    /// common CSS color names.
    static func parse(_ text: String) -> CanvasRGBA? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == transparentName { return CanvasRGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        if let named = namedColors[value] { return parse(named) }
        guard value.hasPrefix("#") else { return nil }

        let digits = Array(value.dropFirst())
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        func component(_ slice: ArraySlice<Character>) -> Double {
            var text = String(slice)
            if text.count == 1 { text += text }
            return Double(Int(text, radix: 16) ?? 0) / 255
        }

        switch digits.count {
        case 3, 4:
            return CanvasRGBA(
                red: component(digits[0...0]),
                green: component(digits[1...1]),
                blue: component(digits[2...2]),
                alpha: digits.count == 4 ? component(digits[3...3]) : 1)
        case 6, 8:
            return CanvasRGBA(
                red: component(digits[0...1]),
                green: component(digits[2...3]),
                blue: component(digits[4...5]),
                alpha: digits.count == 8 ? component(digits[6...7]) : 1)
        default:
            return nil
        }
    }

    static func isTransparent(_ text: String) -> Bool {
        guard let color = parse(text) else { return text.isEmpty }
        return color.alpha == 0
    }

    /// The color to draw, transformed for the theme. Unknown colors draw as
    /// the default stroke so a typo in a file stays visible.
    static func resolve(_ text: String, theme: CanvasTheme) -> CanvasRGBA {
        let color = parse(text) ?? parse(CanvasStyle.defaultStrokeColor)!
        return theme == .dark ? darkModeTransform(color) : color
    }

    static func cgColor(_ text: String, theme: CanvasTheme) -> CGColor {
        resolve(text, theme: theme).cgColor
    }

    /// CSS `invert(93%) hue-rotate(180deg)`, which Excalidraw applies to the
    /// whole canvas in dark mode.
    static func darkModeTransform(_ color: CanvasRGBA) -> CanvasRGBA {
        func invert(_ value: Double) -> Double { 0.93 - 0.86 * value }
        let r = invert(color.red)
        let g = invert(color.green)
        let b = invert(color.blue)
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        return CanvasRGBA(
            red: clamp(-0.574 * r + 1.430 * g + 0.144 * b),
            green: clamp(0.426 * r + 0.430 * g + 0.144 * b),
            blue: clamp(0.426 * r + 1.430 * g - 0.856 * b),
            alpha: color.alpha)
    }

    private static let namedColors: [String: String] = {
        var colors = [
            "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000",
            "blue": "#0000ff", "yellow": "#ffff00", "orange": "#ffa500", "purple": "#800080",
            "pink": "#ffc0cb", "gray": "#808080", "brown": "#a52a2a",
            "cyan": "#00ffff", "magenta": "#ff00ff", "lime": "#00ff00", "navy": "#000080",
            "teal": "#008080", "violet": "#ee82ee", "indigo": "#4b0082", "gold": "#ffd700",
            "silver": "#c0c0c0", "maroon": "#800000", "olive": "#808000", "aqua": "#00ffff",
            "lightgray": "#d3d3d3", "darkgray": "#a9a9a9",
            "lightblue": "#add8e6", "lightgreen": "#90ee90", "salmon": "#fa8072", "coral": "#ff7f50",
        ]
        // CSS accepts the British spelling for every gray name too.
        for (name, value) in colors where name.hasSuffix("gray") {
            colors[name.dropLast(3) + "ey"] = value
        }
        return colors
    }()
}

// MARK: - Palette

/// The quick-pick colors of Excalidraw's style panel.
enum CanvasPalette {
    static let strokes = ["#1e1e1e", "#e03131", "#2f9e44", "#1971c2", "#f08c00", "#6741d9"]
    static let backgrounds = [CanvasColor.transparentName, "#ffc9c9", "#b2f2bb", "#a5d8ff", "#ffec99", "#d0bfff"]
    static let canvasBackground = "#ffffff"
}

// MARK: - Fonts

enum CanvasFont {
    /// Excalidraw's font family ids.
    enum Family: Int, CaseIterable {
        case virgil = 1
        case helvetica = 2
        case cascadia = 3
        case handDrawn = 5
        case nunito = 6
        case lilitaOne = 7
        case comicShanns = 8
        case liberationSans = 9

        /// The three choices the style panel offers.
        static let choices: [Family] = [.handDrawn, .nunito, .comicShanns]
    }

    enum Kind {
        case handDrawn
        case normal
        case code
    }

    static func kind(of family: Int) -> Kind {
        switch Family(rawValue: family) {
        case .virgil, .handDrawn, .none: .handDrawn
        case .cascadia, .comicShanns: .code
        case .helvetica, .nunito, .lilitaOne, .liberationSans: .normal
        }
    }

    /// Excalidraw's font metrics (`FONT_METADATA`): units per em, ascender,
    /// and descender. Text is placed in its line with these, as Excalidraw
    /// does, rather than with the font file's own values.
    struct Metrics {
        var unitsPerEm: Double
        var ascender: Double
        var descender: Double
    }

    static func metrics(family: Int) -> Metrics {
        switch Family(rawValue: family) {
        case .nunito: Metrics(unitsPerEm: 1000, ascender: 1011, descender: -353)
        case .lilitaOne: Metrics(unitsPerEm: 1000, ascender: 923, descender: -220)
        case .comicShanns: Metrics(unitsPerEm: 1000, ascender: 750, descender: -250)
        case .helvetica: Metrics(unitsPerEm: 2048, ascender: 1577, descender: -471)
        case .cascadia: Metrics(unitsPerEm: 2048, ascender: 1900, descender: -480)
        case .liberationSans: Metrics(unitsPerEm: 2048, ascender: 1854, descender: -434)
        case .virgil, .handDrawn, .none: Metrics(unitsPerEm: 1000, ascender: 886, descender: -374)
        }
    }

    /// The font for an Excalidraw font family: the family's own font when
    /// bundled, else a system font of the same kind.
    static func ctFont(family: Int, size: Double) -> CTFont {
        let size = CGFloat(max(size, 1))
        let known = Family(rawValue: family) ?? .handDrawn
        if let descriptor = CanvasFontFiles.descriptor(for: known) {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        if known == .helvetica {
            return CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        switch kind(of: family) {
        case .handDrawn:
            return CTFontCreateWithName("ChalkboardSE-Regular" as CFString, size, nil)
        case .normal:
            return CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        case .code:
            return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
                ?? CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        }
    }
}

// MARK: - Element style

/// The style the next new element gets, like Excalidraw's `currentItem*`
/// app state. The style panel edits this and the selection together.
struct CanvasStyle: Equatable {
    static let defaultStrokeColor = "#1e1e1e"

    var strokeColor = defaultStrokeColor
    var backgroundColor = CanvasColor.transparentName
    var fillStyle = "solid"
    var strokeWidth: Double = 2
    var strokeStyle = "solid"
    var roughness: Double = 1
    var opacity: Double = 100
    var roundEdges = true
    var fontFamily = CanvasFont.Family.handDrawn.rawValue
    var fontSize: Double = 20
    var textAlign = "left"
    var startArrowhead: String?
    var endArrowhead: String? = "arrow"

    /// Applies this style to a new element of the element's type.
    func apply(to element: inout CanvasElement) {
        element.strokeColor = strokeColor
        element.backgroundColor = element.type == .text ? CanvasColor.transparentName : backgroundColor
        element.fillStyle = fillStyle
        element.strokeWidth = strokeWidth
        element.strokeStyle = strokeStyle
        element.roughness = roughness
        element.opacity = opacity

        switch element.type {
        case .rectangle:
            element.roundness = roundEdges ? .adaptive : nil
        case .diamond, .line, .arrow:
            element.roundness = roundEdges ? .proportional : nil
        default:
            element.roundness = nil
        }

        if element.type == .arrow {
            element.startArrowhead = startArrowhead
            element.endArrowhead = endArrowhead
        }

        if element.type == .text {
            element.fontFamily = fontFamily
            element.fontSize = fontSize
            element.textAlign = textAlign
        }
    }

    /// Reads the style of an existing element, e.g. to show it in the panel.
    init(element: CanvasElement) {
        strokeColor = element.strokeColor
        backgroundColor = element.backgroundColor
        fillStyle = element.fillStyle
        strokeWidth = element.strokeWidth
        strokeStyle = element.strokeStyle
        roughness = element.roughness
        opacity = element.opacity
        roundEdges = element.roundness != nil
        if element.type == .text {
            fontFamily = element.fontFamily
            fontSize = element.fontSize
            textAlign = element.textAlign
        }
        if element.type == .arrow {
            startArrowhead = element.startArrowhead
            endArrowhead = element.endArrowhead
        }
    }

    init() {}
}
