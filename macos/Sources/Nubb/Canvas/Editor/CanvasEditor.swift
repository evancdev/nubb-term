import Combine
import CoreGraphics
import Foundation

// MARK: - Tools

enum CanvasTool: String, CaseIterable, Identifiable {
    case hand
    case selection
    case rectangle
    case diamond
    case ellipse
    case arrow
    case line
    case freedraw
    case text
    case eraser

    var id: String { rawValue }

    /// The tools in toolbar order.
    static let toolbar: [CanvasTool] = [.hand, .selection, .rectangle, .diamond, .ellipse, .arrow, .line, .freedraw, .text, .eraser]

    var elementType: CanvasElementType? {
        switch self {
        case .rectangle: .rectangle
        case .diamond: .diamond
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .freedraw: .freedraw
        case .text: .text
        default: nil
        }
    }

    /// Excalidraw's letter shortcut.
    var letter: Character {
        switch self {
        case .hand: "h"
        case .selection: "v"
        case .rectangle: "r"
        case .diamond: "d"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        case .freedraw: "p"
        case .text: "t"
        case .eraser: "e"
        }
    }

    /// Excalidraw's number shortcut.
    var number: Character? {
        switch self {
        case .selection: "1"
        case .rectangle: "2"
        case .diamond: "3"
        case .ellipse: "4"
        case .arrow: "5"
        case .line: "6"
        case .freedraw: "7"
        case .text: "8"
        case .eraser: "0"
        case .hand: nil
        }
    }

    var title: String {
        switch self {
        case .hand: "Hand"
        case .selection: "Selection"
        case .rectangle: "Rectangle"
        case .diamond: "Diamond"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .line: "Line"
        case .freedraw: "Draw"
        case .text: "Text"
        case .eraser: "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .hand: "hand.raised"
        case .selection: "cursorarrow"
        case .rectangle: "square"
        case .diamond: "diamond"
        case .ellipse: "circle"
        case .arrow: "arrow.right"
        case .line: "line.diagonal"
        case .freedraw: "pencil"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    static func forKey(_ key: Character) -> CanvasTool? {
        allCases.first { $0.letter == key || $0.number == key }
    }
}

// MARK: - UI state

/// What the toolbar and style panel show. Updated only when it changes, so
/// SwiftUI doesn't re-render while shapes are dragged.
final class CanvasUIState: ObservableObject {
    struct SelectionKinds: Equatable {
        var count = 0
        var hasFillable = false
        var hasRoundable = false
        var hasArrow = false
        var hasText = false
        var hasStroke = false
    }

    @Published var tool: CanvasTool = .selection
    @Published var toolLocked = false
    @Published var style = CanvasStyle()
    @Published var kinds = SelectionKinds()
    @Published var zoom: Double = 1
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var fileName = ""
    @Published var isEmpty = true
    @Published var loadError: String?
    /// The canvas theme, so the style panel shows colors as they are drawn.
    @Published var theme: CanvasTheme = .light

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<CanvasUIState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Whether the style panel has anything to show.
    var showsStylePanel: Bool {
        kinds.count > 0 || (tool.elementType != nil)
    }
}

// MARK: - Editor

/// The drawing being edited: document, selection, current tool and style,
/// and undo history. Views call it to change the drawing; it tells them
/// what changed.
@MainActor
final class CanvasEditor {
    private(set) var document: CanvasDocument
    private(set) var selection: Set<String> = []
    private(set) var history = CanvasHistory()

    var tool: CanvasTool = .selection {
        didSet { syncUI() }
    }

    var toolLocked = false {
        didSet { syncUI() }
    }

    /// The style new elements get.
    var style = CanvasStyle() {
        didSet { syncUI() }
    }

    let ui = CanvasUIState()

    /// Called after the document changes. The view finds what changed by
    /// comparing element versions.
    var onDocumentChange: (() -> Void)?

    /// Called before `onDocumentChange` when elements were replaced by a
    /// version from the file, which may not have new version numbers.
    var onExternalChange: ((Set<String>) -> Void)?

    /// Called after the selection changes.
    var onSelectionChange: (() -> Void)?

    /// Called after a change is complete and should be saved.
    var onCommit: ((CanvasDocument) -> Void)?

    /// Called when an interaction ends or is cancelled.
    var onInteractionEnd: (() -> Void)?

    /// False while the file couldn't be read: nothing may change it then.
    var isEditable = true

    private var interactionStart: (document: CanvasDocument, selection: Set<String>)?

    var isInteracting: Bool { interactionStart != nil }

    init(document: CanvasDocument = CanvasDocument()) {
        self.document = document
        syncUI()
    }

    // MARK: Lookup

    func element(_ id: String) -> CanvasElement? {
        document.elements.first { $0.id == id }
    }

    var selectedElements: [CanvasElement] {
        document.elements.filter { selection.contains($0.id) }
    }

    // MARK: Selection

    func select(_ ids: Set<String>) {
        let valid = ids.filter { id in document.elements.contains { $0.id == id } }
        guard valid != selection else { return }
        selection = valid
        history.breakCoalescing()
        onSelectionChange?()
        syncUI()
    }

    func selectAll() {
        let positions = CanvasOps.index(document)
        select(Set(document.elements.filter { !CanvasOps.isBoundText($0, positions: positions) }.map(\.id)))
    }

    func clearSelection() { select([]) }

    // MARK: Changes

    /// Starts a change that spans several updates, such as a drag. It
    /// becomes one undo step when it ends.
    func beginInteraction() {
        guard interactionStart == nil else { return }
        interactionStart = (document, selection)
    }

    /// Changes the document during an interaction.
    func updateInteraction(_ body: (inout CanvasDocument) -> Void) {
        guard isEditable else { return }
        if interactionStart == nil { beginInteraction() }
        body(&document)
        onDocumentChange?()
    }

    /// Sets the selection during an interaction, without notifying until
    /// it ends.
    func setInteractionSelection(_ ids: Set<String>) {
        selection = ids
        onSelectionChange?()
    }

    /// Ends an interaction, recording one undo step if anything changed.
    /// Steps with the same `coalescing` key in quick succession merge into
    /// one, so dragging a slider is undone at once.
    func endInteraction(coalescing key: String? = nil) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        // Drop selected ids whose elements were removed.
        let ids = Set(document.elements.map(\.id))
        selection = selection.filter(ids.contains)
        if let entry = CanvasHistory.diff(
            from: start.document, to: document,
            selectionBefore: start.selection, selectionAfter: selection) {
            history.record(entry, coalescing: key)
            onCommit?(document)
        } else if key == nil {
            history.breakCoalescing()
        }
        onSelectionChange?()
        syncUI()
        onInteractionEnd?()
    }

    /// Ends an interaction and puts the document back as it was.
    func cancelInteraction() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        document = start.document
        selection = start.selection
        onDocumentChange?()
        onSelectionChange?()
        syncUI()
        onInteractionEnd?()
    }

    /// A change that happens at once, recorded as one undo step.
    func perform(
        select newSelection: Set<String>? = nil,
        coalescing key: String? = nil,
        _ body: (inout CanvasDocument) -> Void
    ) {
        guard isEditable else { return }
        let nested = interactionStart != nil
        if !nested { beginInteraction() }
        body(&document)
        if let newSelection { selection = newSelection }
        onDocumentChange?()
        if !nested { endInteraction(coalescing: key) }
    }

    // MARK: Undo

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        guard isEditable, interactionStart == nil, let entry = history.popUndo() else { return }
        CanvasHistory.apply(entry.before, order: entry.orderBefore, appState: entry.appStateBefore, to: &document)
        restoreSelection(entry.selectionBefore)
    }

    func redo() {
        guard isEditable, interactionStart == nil, let entry = history.popRedo() else { return }
        CanvasHistory.apply(entry.after, order: entry.orderAfter, appState: entry.appStateAfter, to: &document)
        restoreSelection(entry.selectionAfter)
    }

    private func restoreSelection(_ ids: Set<String>) {
        let existing = Set(document.elements.map(\.id))
        selection = ids.filter(existing.contains)
        onDocumentChange?()
        onSelectionChange?()
        onCommit?(document)
        syncUI()
    }

    // MARK: External changes

    /// Replaces the document with a version merged from the file. This is
    /// not an undo step. Callers wait for interactions to end first.
    func applyExternal(_ merged: CanvasDocument) {
        precondition(interactionStart == nil, "merge file changes after the interaction ends")
        history.breakCoalescing()
        let changed = CanvasHistory.diff(from: document, to: merged, selectionBefore: [], selectionAfter: [])
        document = merged
        let before = selection
        let existing = Set(merged.elements.map(\.id))
        selection = selection.filter(existing.contains)
        onExternalChange?(changed.map { Set($0.before.keys) } ?? [])
        onDocumentChange?()
        if selection != before { onSelectionChange?() }
        syncUI()
    }

    /// Replaces everything, e.g. after reading the file for the first time.
    func load(_ document: CanvasDocument) {
        self.document = document
        selection = []
        history.clear()
        interactionStart = nil
        onExternalChange?(Set(document.elements.map(\.id)))
        onDocumentChange?()
        onSelectionChange?()
        syncUI()
    }

    // MARK: UI

    func syncUI() {
        ui.set(\.tool, tool)
        ui.set(\.toolLocked, toolLocked)
        ui.set(\.canUndo, history.canUndo)
        ui.set(\.canRedo, history.canRedo)
        ui.set(\.isEmpty, document.elements.isEmpty)

        let selected = selectedElements
        var kinds = CanvasUIState.SelectionKinds()
        kinds.count = selected.count
        for element in selected {
            if element.type.isContainer || (element.type.hasPoints && CanvasGeometry.isLoop(element.points)) {
                kinds.hasFillable = true
            }
            if element.type.supportsRoundness { kinds.hasRoundable = true }
            if element.type == .arrow { kinds.hasArrow = true }
            if element.type == .text || element.boundTextID != nil { kinds.hasText = true }
            if element.type != .text && element.type != .image { kinds.hasStroke = true }
        }
        if selected.isEmpty, let type = tool.elementType {
            kinds.hasFillable = type.isContainer
            kinds.hasRoundable = type.supportsRoundness
            kinds.hasArrow = type == .arrow
            kinds.hasText = type == .text
            kinds.hasStroke = type != .text
        }
        ui.set(\.kinds, kinds)

        // The panel shows the first selected element's style, or the
        // style new elements will get.
        if let first = selected.first {
            var shown = CanvasStyle(element: first)
            if first.type != .text, let labelID = first.boundTextID, let label = element(labelID) {
                shown.fontFamily = label.fontFamily
                shown.fontSize = label.fontSize
                shown.textAlign = label.textAlign
            }
            ui.set(\.style, shown)
        } else {
            ui.set(\.style, style)
        }
    }
}

// MARK: - Editing operations

extension CanvasEditor {
    /// Changes the style of the selection, and of new elements. Changes
    /// with the same `coalescing` key in quick succession, such as a slider
    /// drag, are one undo step.
    func applyStyle(coalescing key: String? = nil, _ change: (inout CanvasStyle) -> Void) {
        change(&style)
        let selected = selection
        guard !selected.isEmpty else {
            syncUI()
            return
        }

        let targets = CanvasOps.withBoundText(selected, in: document)
        perform(coalescing: key) { document in
            for i in document.elements.indices where targets.contains(document.elements[i].id) {
                var element = document.elements[i]
                var current = CanvasStyle(element: element)
                change(&current)
                Self.apply(current, to: &element)
                if element != document.elements[i] {
                    CanvasOps.touch(&element)
                    document.elements[i] = element
                }
            }
            CanvasOps.updateRelations(changed: targets, in: &document)
        }
    }

    /// Copies style fields onto an existing element, keeping fields that
    /// don't apply to its type.
    private static func apply(_ style: CanvasStyle, to element: inout CanvasElement) {
        element.strokeColor = style.strokeColor
        element.opacity = style.opacity
        if element.type != .text {
            element.backgroundColor = style.backgroundColor
            element.fillStyle = style.fillStyle
            element.strokeWidth = style.strokeWidth
            element.strokeStyle = style.strokeStyle
            element.roughness = style.roughness
        }
        if element.type.supportsRoundness {
            let wantsRound = style.roundEdges
            if wantsRound != (element.roundness != nil) {
                element.roundness = wantsRound ? (element.type == .rectangle ? .adaptive : .proportional) : nil
            }
        }
        if element.type == .arrow {
            element.startArrowhead = style.startArrowhead
            element.endArrowhead = style.endArrowhead
        }
        if element.type == .text {
            let fontChanged = element.fontFamily != style.fontFamily || element.fontSize != style.fontSize
            element.fontFamily = style.fontFamily
            element.fontSize = style.fontSize
            element.textAlign = style.textAlign
            if fontChanged {
                element.lineHeight = CanvasText.defaultLineHeight(family: style.fontFamily)
                if element.containerId == nil { CanvasOps.remeasure(&element) }
            }
        }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform(select: []) { document in
            CanvasOps.delete(ids, in: &document)
        }
    }

    func duplicateSelection(offset: CGVector = CGVector(dx: 10, dy: 10)) {
        guard !selection.isEmpty else { return }
        let ids = selection
        var made: Set<String> = []
        beginInteraction()
        updateInteraction { document in
            made = CanvasOps.duplicate(ids, in: &document, offset: offset)
        }
        setInteractionSelection(made)
        endInteraction()
    }

    func reorderSelection(_ direction: CanvasOps.Reorder) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { document in
            CanvasOps.reorder(ids, direction, in: &document)
        }
    }

    func groupSelection() {
        guard selection.count > 1 else { return }
        let ids = selection
        perform { document in CanvasOps.group(ids, in: &document) }
    }

    func ungroupSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { document in CanvasOps.ungroup(ids, in: &document) }
    }

    /// Whether any selected element is in a group.
    var selectionHasGroup: Bool {
        selectedElements.contains { !$0.groupIds.isEmpty }
    }

    /// Moves the selection by `delta` scene units as one undo step.
    func nudgeSelection(by delta: CGVector) {
        guard !selection.isEmpty else { return }
        let ids = CanvasOps.withFrameChildren(selection, in: document)
        perform { document in
            for i in document.elements.indices where ids.contains(document.elements[i].id) {
                document.elements[i].x += Double(delta.dx)
                document.elements[i].y += Double(delta.dy)
                CanvasOps.touch(&document.elements[i])
            }
            CanvasOps.unbindMovedLines(ids, in: &document)
            CanvasOps.updateRelations(changed: ids, in: &document)
        }
    }

    /// Inserts elements, e.g. from the clipboard, on top and selects them.
    /// They join the frame they land in, or leave the one they came from,
    /// as in Excalidraw.
    func insert(_ elements: [CanvasElement], files: [String: CanvasJSON] = [:]) {
        guard !elements.isEmpty else { return }
        let labels = Set(elements.filter { $0.type == .text && $0.containerId != nil }.map(\.id))
        let selected = Set(elements.map(\.id)).subtracting(labels)
        let box = CanvasRenderer.sceneBounds(of: elements)
        perform(select: selected) { document in
            document.elements.append(contentsOf: elements)
            for (id, file) in files where document.files[id] == nil {
                document.files[id] = file
            }
            CanvasOps.keepLabelsAboveContainers(in: &document)
            if !box.isNull {
                CanvasOps.updateFrameMembership(of: Set(elements.map(\.id)), pointer: CGPoint(x: box.midX, y: box.midY), in: &document)
            }
        }
    }

    /// Changes the canvas background color.
    func setViewBackgroundColor(_ color: String) {
        guard document.viewBackgroundColor != color else { return }
        perform { document in document.viewBackgroundColor = color }
    }

    /// The canvas background color from the file.
    var viewBackgroundColor: String { document.viewBackgroundColor }
}
