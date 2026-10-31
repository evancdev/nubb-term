import CoreText
import Foundation

/// Excalidraw's own fonts, bundled as the WOFF2 subsets excalidraw.com
/// serves, so text measures, wraps, and draws as it does there. Licenses are
/// in `Fonts/CanvasFonts-LICENSES.md`.
///
/// The fonts are read from the app bundle on first use and never registered
/// with the system, so they don't show up in other apps and the command line
/// tool can use them without a window server.
enum CanvasFontFiles {
    /// The resource names of a family's subsets, Latin first. CoreText falls
    /// back to the later subsets for characters the first one lacks.
    static func resources(for family: CanvasFont.Family) -> [String] {
        switch family {
        case .handDrawn: (1...7).map { "CanvasFont-Excalifont-\($0)" }
        case .nunito: (1...5).map { "CanvasFont-Nunito-\($0)" }
        case .comicShanns: (1...4).map { "CanvasFont-ComicShanns-\($0)" }
        case .lilitaOne: (1...2).map { "CanvasFont-Lilita-\($0)" }
        case .cascadia: ["CanvasFont-Cascadia-1"]
        case .virgil: ["CanvasFont-Virgil-1"]
        case .liberationSans: ["CanvasFont-Liberation-1"]
        case .helvetica: []
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: CTFontDescriptor] = [:]
    nonisolated(unsafe) private static var missing: Set<Int> = []

    /// The family's font with its other subsets as fallbacks, or nil when the
    /// files aren't in the bundle.
    static func descriptor(for family: CanvasFont.Family) -> CTFontDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[family.rawValue] { return cached }
        if missing.contains(family.rawValue) { return nil }

        let descriptors = resources(for: family).compactMap(load)
        guard let first = descriptors.first else {
            missing.insert(family.rawValue)
            return nil
        }
        let result: CTFontDescriptor
        if descriptors.count > 1 {
            let attributes = [kCTFontCascadeListAttribute: Array(descriptors.dropFirst())] as CFDictionary
            result = CTFontDescriptorCreateCopyWithAttributes(first, attributes)
        } else {
            result = first
        }
        cache[family.rawValue] = result
        return result
    }

    private static func load(_ name: String) -> CTFontDescriptor? {
        for bundle in bundles {
            guard let url = bundle.url(forResource: name, withExtension: "woff2"),
                  let data = try? Data(contentsOf: url) else { continue }
            return CTFontManagerCreateFontDescriptorFromData(data as CFData)
        }
        return nil
    }

    /// The app bundle. Debug builds keep the code in a dylib, so look up the
    /// bundle of this code too.
    private static let bundles: [Bundle] = {
        let own = Bundle(for: BundleToken.self)
        return own == Bundle.main ? [Bundle.main] : [Bundle.main, own]
    }()
}

private final class BundleToken {}
