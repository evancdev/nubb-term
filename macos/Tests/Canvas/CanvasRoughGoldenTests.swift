import CoreGraphics
import Foundation
import Testing
@testable import Nubb

/// Compares the rough.js and perfect-freehand ports with output of the
/// JavaScript libraries. `Fixtures/rough-golden.json` was produced by
/// `Fixtures/rough-golden.mjs` with roughjs 4.6.6 and perfect-freehand
/// 1.2.3, the versions Excalidraw 0.18 ships.
@Suite
struct CanvasRoughGoldenTests {
    /// Read from the test bundle, which Xcode copies the fixture into.
    /// Reading the source tree instead can block the run on a macOS prompt
    /// for access to ~/Documents.
    private static let golden: CanvasJSON = {
        let bundled = Bundle(for: BundleToken.self).url(forResource: "rough-golden", withExtension: "json")
        let url = bundled ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/rough-golden.json")
        // swiftlint:disable:next force_try
        return try! CanvasJSON.parse(Data(contentsOf: url))
    }()

    private final class BundleToken {}

    /// Converts op sets to the fixture's form: `[kind, [op, ...numbers]]`.
    private static func flatten(_ drawable: RoughDrawable) -> [(String, [[Double]])] {
        drawable.sets.map { set in
            let kind: String
            switch set.kind {
            case .path: kind = "path"
            case .fillPath: kind = "fillPath"
            case .fillSketch: kind = "fillSketch"
            }
            let ops: [[Double]] = set.ops.map { op in
                switch op {
                case .move(let p): [0, p.dx, p.dy]
                case .lineTo(let p): [1, p.dx, p.dy]
                case let .curveTo(a, b, c): [2, a.dx, a.dy, b.dx, b.dy, c.dx, c.dy]
                }
            }
            return (kind, ops)
        }
    }

    private static func expected(_ key: String) throws -> [(String, [[Double]])] {
        let sets = try #require(golden[key]?.arrayValue)
        return try sets.map { set in
            let kind = try #require(set["type"]?.stringValue)
            let ops = try #require(set["ops"]?.arrayValue).map { op -> [Double] in
                let items = try #require(op.arrayValue)
                let name = try #require(items.first?.stringValue)
                let code: Double = name == "move" ? 0 : (name == "lineTo" ? 1 : 2)
                return [code] + items.dropFirst().compactMap(\.doubleValue)
            }
            return (kind, ops)
        }
    }

    private static func check(_ drawable: RoughDrawable, against key: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actual = flatten(drawable)
        let wanted = try expected(key)
        #expect(actual.count == wanted.count, "\(key): set count", sourceLocation: sourceLocation)
        for (a, w) in zip(actual, wanted) {
            #expect(a.0 == w.0, "\(key): set kind", sourceLocation: sourceLocation)
            #expect(a.1.count == w.1.count, "\(key): op count \(a.1.count) vs \(w.1.count)", sourceLocation: sourceLocation)
            for (index, (op, wantedOp)) in zip(a.1, w.1).enumerated() {
                #expect(op.count == wantedOp.count, "\(key): op \(index) arity", sourceLocation: sourceLocation)
                for (value, wantedValue) in zip(op, wantedOp) where abs(value - wantedValue) > 1e-4 {
                    Issue.record("\(key): op \(index) is \(op), expected \(wantedOp)", sourceLocation: sourceLocation)
                    return
                }
            }
        }
    }

    private static func options(_ configure: (RoughOptions) -> Void) -> RoughOptions {
        let o = RoughOptions()
        configure(o)
        return o
    }

    private static func points(_ list: [(Double, Double)]) -> [CGPoint] {
        list.map { CGPoint(x: $0.0, y: $0.1) }
    }

    @Test func line() throws {
        try Self.check(RoughGenerator.line(10, 20, 200, 80, Self.options { $0.seed = 42 }), against: "line")
    }

    @Test func rectangle() throws {
        let o = Self.options {
            $0.seed = 7; $0.preserveVertices = true; $0.fillWeight = 1; $0.hachureGap = 8; $0.strokeWidth = 2
        }
        try Self.check(RoughGenerator.rectangle(0, 0, 120, 80, o), against: "rectangle")
    }

    @Test func ellipse() throws {
        let o = Self.options { $0.seed = 99; $0.curveFitting = 1; $0.strokeWidth = 2 }
        try Self.check(RoughGenerator.ellipse(50, 40, 100, 80, o), against: "ellipse")
    }

    @Test func ellipseSolidFill() throws {
        let o = Self.options {
            $0.seed = 99; $0.curveFitting = 1; $0.strokeWidth = 2; $0.fill = true; $0.fillStyle = "solid"
        }
        try Self.check(RoughGenerator.ellipse(50, 40, 100, 80, o), against: "ellipseFillSolid")
    }

    @Test func rectangleHachure() throws {
        let o = Self.options {
            $0.seed = 3; $0.preserveVertices = true; $0.fill = true; $0.fillStyle = "hachure"
            $0.fillWeight = 1; $0.hachureGap = 8; $0.strokeWidth = 2
        }
        try Self.check(RoughGenerator.rectangle(0, 0, 100, 60, o), against: "rectHachure")
    }

    @Test func curve() throws {
        let o = Self.options { $0.seed = 11; $0.strokeWidth = 2; $0.preserveVertices = true }
        try Self.check(RoughGenerator.curve(Self.points([(0, 0), (50, 30), (100, 0), (150, 40)]), o), against: "curve")
    }

    @Test func linearPath() throws {
        let o = Self.options { $0.seed = 5; $0.strokeWidth = 2; $0.preserveVertices = true }
        try Self.check(RoughGenerator.linearPath(Self.points([(0, 0), (60, 20), (120, -10)]), o), against: "linearPath")
    }

    @Test func polygonCrossHatch() throws {
        let o = Self.options {
            $0.seed = 8; $0.strokeWidth = 2; $0.fill = true; $0.fillStyle = "cross-hatch"
            $0.fillWeight = 1; $0.hachureGap = 8
        }
        try Self.check(RoughGenerator.polygon(Self.points([(51, 0), (100, 41), (51, 80), (0, 41)]), o), against: "polygon")
    }

    @Test func roundedRectanglePath() throws {
        var b = RoughPathBuilder()
        b.move(32, 0); b.line(168, 0); b.quad(200, 0, 200, 32)
        b.line(200, 88); b.quad(200, 120, 168, 120)
        b.line(32, 120); b.quad(0, 120, 0, 88)
        b.line(0, 32); b.quad(0, 0, 32, 0)
        let o = Self.options {
            $0.seed = 21; $0.strokeWidth = 2; $0.preserveVertices = true; $0.fill = true; $0.fillStyle = "solid"
        }
        try Self.check(RoughGenerator.path(b.segments, o), against: "path")
    }

    @Test func architectRectangle() throws {
        let o = Self.options { $0.seed = 2; $0.roughness = 0; $0.strokeWidth = 2; $0.preserveVertices = true }
        try Self.check(RoughGenerator.rectangle(0, 0, 80, 40, o), against: "architect")
    }

    @Test func architectEllipse() throws {
        let o = Self.options { $0.seed = 2; $0.roughness = 0; $0.curveFitting = 1; $0.strokeWidth = 2 }
        try Self.check(RoughGenerator.ellipse(20, 20, 40, 40, o), against: "ellipseArchitect")
    }

    @Test func zigzagFill() throws {
        let o = Self.options {
            $0.seed = 13; $0.preserveVertices = true; $0.fill = true; $0.fillStyle = "zigzag"
            $0.fillWeight = 1; $0.hachureGap = 8; $0.strokeWidth = 2
        }
        try Self.check(RoughGenerator.rectangle(0, 0, 60, 40, o), against: "zigzag")
    }

    @Test func dashedRectangle() throws {
        let o = Self.options {
            $0.seed = 17; $0.preserveVertices = true; $0.strokeWidth = 2.5; $0.disableMultiStroke = true
        }
        try Self.check(RoughGenerator.rectangle(0, 0, 90, 50, o), against: "dashedRect")
    }

    // MARK: perfect-freehand

    private static let strokePoints: [(Double, Double)] = [
        (0, 0), (5, 2), (12, 6), (20, 12), (30, 15), (42, 14), (55, 10), (66, 4), (75, 0), (80, -3),
    ]

    private static func checkOutline(_ outline: [CGPoint], against key: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let wanted = try #require(golden[key]?.arrayValue).map { item in
            item.arrayValue?.compactMap(\.doubleValue) ?? []
        }
        #expect(outline.count == wanted.count, "\(key): point count \(outline.count) vs \(wanted.count)", sourceLocation: sourceLocation)
        for (index, (point, w)) in zip(outline, wanted).enumerated() where w.count == 2 {
            if abs(point.dx - w[0]) > 1e-4 || abs(point.dy - w[1]) > 1e-4 {
                Issue.record("\(key): point \(index) is \(point), expected \(w)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test func freehandSimulatedPressure() throws {
        let outline = Freehand.outline(
            points: Self.points(Self.strokePoints), pressures: nil,
            options: .excalidraw(strokeWidth: 2, simulatePressure: true))
        try Self.checkOutline(outline, against: "freehand")
    }

    @Test func freehandRealPressure() throws {
        let pressures = Self.strokePoints.indices.map { 0.2 + Double($0) * 0.07 }
        let outline = Freehand.outline(
            points: Self.points(Self.strokePoints), pressures: pressures,
            options: .excalidraw(strokeWidth: 4, simulatePressure: false))
        try Self.checkOutline(outline, against: "freehandPressure")
    }

    @Test func freehandDot() throws {
        let outline = Freehand.outline(
            points: [CGPoint(x: 3, y: 4)], pressures: nil,
            options: .excalidraw(strokeWidth: 2, simulatePressure: true))
        try Self.checkOutline(outline, against: "freehandDot")
    }
}
