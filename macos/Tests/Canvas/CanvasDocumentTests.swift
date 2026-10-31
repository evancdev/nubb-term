import CoreGraphics
import Foundation
import Testing
@testable import Nubb

/// Reading and writing `.excalidraw` files.
@Suite
struct CanvasDocumentTests {
    /// A file as Excalidraw 0.18 writes it, with fields Nubb doesn't model.
    static let excalidrawFile = """
    {
      "type": "excalidraw",
      "version": 2,
      "source": "https://excalidraw.com",
      "elements": [
        {
          "id": "rect-1", "type": "rectangle", "x": 100.5, "y": 200.25, "width": 180, "height": 90,
          "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "#a5d8ff", "fillStyle": "hachure",
          "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100,
          "groupIds": [], "frameId": null, "index": "a0", "roundness": {"type": 3},
          "seed": 1968410350, "version": 12, "versionNonce": 361174001, "isDeleted": false,
          "boundElements": [{"type": "text", "id": "label-1"}, {"type": "arrow", "id": "arrow-1"}],
          "updated": 1700000000000, "link": null, "locked": false, "customData": {"owner": "agent"}
        },
        {
          "id": "label-1", "type": "text", "x": 150, "y": 232.5, "width": 80, "height": 25,
          "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
          "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100,
          "groupIds": [], "frameId": null, "index": "a1", "roundness": null, "seed": 1, "version": 3,
          "versionNonce": 2, "isDeleted": false, "boundElements": null, "updated": 1, "link": null,
          "locked": false, "text": "Hello", "fontSize": 20, "fontFamily": 5, "textAlign": "center",
          "verticalAlign": "middle", "containerId": "rect-1", "originalText": "Hello",
          "autoResize": true, "lineHeight": 1.25
        },
        {
          "id": "arrow-1", "type": "arrow", "x": 290, "y": 245, "width": 120, "height": 0.0000001,
          "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
          "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [],
          "roundness": {"type": 2}, "seed": 7, "version": 4, "versionNonce": 9, "isDeleted": false,
          "boundElements": null, "updated": 1, "link": null, "locked": false,
          "points": [[0, 0], [120, 0.0000001]], "lastCommittedPoint": null,
          "startBinding": {"elementId": "rect-1", "focus": 0.1, "gap": 6, "fixedPoint": null},
          "endBinding": null, "startArrowhead": null, "endArrowhead": "arrow", "elbowed": false
        },
        {
          "id": "gone", "type": "ellipse", "x": 0, "y": 0, "width": 10, "height": 10, "isDeleted": true
        }
      ],
      "appState": {"gridSize": 20, "viewBackgroundColor": "#fdf6e3", "gridStep": 5},
      "files": {"f1": {"mimeType": "image/png", "id": "f1", "dataURL": "data:image/png;base64,AAAA"}},
      "libraryItems": []
    }
    """

    @Test func readsExcalidrawFile() throws {
        let document = try CanvasDocument.decode(Data(Self.excalidrawFile.utf8))
        #expect(document.elements.map(\.id) == ["rect-1", "label-1", "arrow-1"])
        #expect(document.viewBackgroundColor == "#fdf6e3")
        #expect(document.files["f1"] != nil)
        #expect(document.extra["libraryItems"] != nil)

        let rect = try #require(document.element(id: "rect-1"))
        #expect(rect.type == .rectangle)
        #expect(rect.x == 100.5 && rect.y == 200.25)
        #expect(rect.fillStyle == "hachure")
        #expect(rect.roundness == .adaptive)
        #expect(rect.seed == 1_968_410_350)
        #expect(rect.boundTextID == "label-1")
        #expect(rect.extra["customData"]?["owner"]?.stringValue == "agent")
        #expect(rect.extra["index"] == nil, "fractional indexes are rebuilt by Excalidraw")

        let label = try #require(document.element(id: "label-1"))
        #expect(label.containerId == "rect-1")
        #expect(label.textAlign == "center")

        let arrow = try #require(document.element(id: "arrow-1"))
        #expect(arrow.points.count == 2)
        #expect(arrow.startBinding?.elementId == "rect-1")
        #expect(arrow.startBinding?.focus == 0.1)
        #expect(arrow.endArrowhead == "arrow")
        #expect(arrow.extra["elbowed"]?.boolValue == false)
    }

    @Test func roundTripKeepsEveryField() throws {
        let document = try CanvasDocument.decode(Data(Self.excalidrawFile.utf8))
        let written = document.encoded()
        let again = try CanvasDocument.decode(written)
        #expect(again == document)
        // Writing twice gives the same bytes, so saving an unchanged drawing
        // never touches the file.
        #expect(again.encoded() == written)

        let json = try CanvasJSON.parse(written)
        #expect(json["type"]?.stringValue == "excalidraw")
        #expect(json["version"]?.doubleValue == 2)
        let elements = try #require(json["elements"]?.arrayValue)
        #expect(elements.count == 3)
        #expect(elements[0]["customData"]?["owner"]?.stringValue == "agent")
        #expect(elements[2]["startBinding"]?["fixedPoint"] == .null)
        #expect(elements[2]["lastCommittedPoint"] == .null)
    }

    @Test func numbersRoundTripExactly() throws {
        let document = try CanvasDocument.decode(Data(Self.excalidrawFile.utf8))
        let arrow = try #require(document.element(id: "arrow-1"))
        #expect(arrow.points[1].y == 0.0000001)
        let written = try #require(String(bytes: document.encoded(), encoding: .utf8))
        #expect(written.contains("1e-07") || written.contains("0.0000001"))
        #expect(written.contains("1968410350"))
        #expect(!written.contains("1968410350.0"))
    }

    @Test func emptyAndBareArrayFilesOpen() throws {
        #expect(try CanvasDocument.decode(Data()).elements.isEmpty)
        #expect(try CanvasDocument.decode(Data("  \n".utf8)).elements.isEmpty)

        let bare = """
        [{"type": "rectangle", "x": 1, "y": 2, "width": 3, "height": 4}]
        """
        let document = try CanvasDocument.decode(Data(bare.utf8))
        #expect(document.elements.count == 1)
        #expect(document.elements[0].id == "element-0")
    }

    @Test func missingIDsAndSeedsAreStable() throws {
        let file = """
        {"elements": [{"type": "ellipse", "x": 0, "y": 0, "width": 50, "height": 30}]}
        """
        let a = try CanvasDocument.decode(Data(file.utf8))
        let b = try CanvasDocument.decode(Data(file.utf8))
        #expect(a == b, "decoding the same hand-written file twice gives the same drawing")
        #expect(a.elements[0].seed == CanvasRandom.stableSeed("element-0"))
    }

    @Test func duplicateIDsAreRenamed() throws {
        let file = """
        {"elements": [
          {"id": "x", "type": "rectangle"},
          {"id": "x", "type": "ellipse"}
        ]}
        """
        let document = try CanvasDocument.decode(Data(file.utf8))
        #expect(Set(document.elements.map(\.id)).count == 2)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: CanvasDocumentError.notJSON) { try CanvasDocument.decode(Data("{nope".utf8)) }
        #expect(throws: CanvasDocumentError.notAnObject) { try CanvasDocument.decode(Data("42".utf8)) }
        #expect(throws: CanvasDocumentError.wrongType("excalidrawlib")) {
            try CanvasDocument.decode(Data(#"{"type": "excalidrawlib"}"#.utf8))
        }
        #expect(throws: CanvasDocumentError.elementsNotAnArray) {
            try CanvasDocument.decode(Data(#"{"elements": {}}"#.utf8))
        }
    }

    @Test func clipboardDataIsExcalidrawClipboard() throws {
        let document = try CanvasDocument.decode(Data(Self.excalidrawFile.utf8))
        let data = CanvasDocument.clipboardData(elements: document.elements, files: document.files)
        let json = try CanvasJSON.parse(data)
        #expect(json["type"]?.stringValue == "excalidraw/clipboard")
        #expect(json["elements"]?.arrayValue?.count == 3)
        // Only files that pasted elements use are included.
        #expect(json["files"]?.objectValue?.isEmpty == true)
        // The clipboard decodes as a drawing.
        #expect(try CanvasDocument.decode(data).elements.count == 3)
    }

    @Test func outputIsReadableJSON() throws {
        var element = CanvasElement(id: "a", type: .line)
        element.points = [.zero, CGPoint(x: 10, y: 5)]
        let data = CanvasDocument(elements: [element]).encoded()
        let text = try #require(String(bytes: data, encoding: .utf8))
        // Sorted keys and points on one line each keep diffs small.
        #expect(text.contains("[0, 0]") || text.contains("[0,0]"))
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    }
}

// MARK: - Colors

@Suite
struct CanvasColorTests {
    @Test func parsesCSSColors() {
        #expect(CanvasColor.parse("#fff") == CanvasRGBA(red: 1, green: 1, blue: 1))
        #expect(CanvasColor.parse("#ff000080")?.alpha ?? 0 > 0.5)
        #expect(CanvasColor.parse("red") == CanvasRGBA(red: 1, green: 0, blue: 0))
        #expect(CanvasColor.parse("transparent")?.alpha == 0)
        #expect(CanvasColor.parse("nonsense") == nil)
        #expect(CanvasColor.isTransparent("transparent"))
        #expect(!CanvasColor.isTransparent("#000"))
    }

    @Test func darkModeMatchesExcalidrawFilter() {
        // invert(93%) hue-rotate(180deg): white becomes a dark gray and the
        // default stroke becomes light.
        let white = CanvasColor.resolve("#ffffff", theme: .dark)
        #expect(abs(white.red - 0.07) < 0.01 && abs(white.green - 0.07) < 0.01 && abs(white.blue - 0.07) < 0.01)
        let stroke = CanvasColor.resolve("#1e1e1e", theme: .dark)
        #expect(stroke.red > 0.8 && stroke.green > 0.8)
        #expect(CanvasColor.resolve("#1971c2", theme: .light) == CanvasColor.parse("#1971c2"))
    }
}
