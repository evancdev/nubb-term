import AppKit

// MARK: - Text editing

/// The text field shown while a text element or label is edited.
final class CanvasTextView: NSTextView {
    /// Undo inside the field stays separate from the drawing's undo.
    let localUndoManager = UndoManager()

    override var undoManager: UndoManager? { localUndoManager }
    override var acceptsFirstResponder: Bool { true }
}

extension CanvasView {
    struct TextEditing {
        var id: String
        /// The shape or line the text is a label of.
        var containerID: String?
    }

    // MARK: Begin

    /// Starts a new free text element at `scene`, centered on the line.
    func beginTextEditing(newAt scene: CGPoint) {
        guard editor.isEditable else { return }
        var text = CanvasElement(type: .text)
        editor.style.apply(to: &text)
        text.lineHeight = CanvasText.defaultLineHeight(family: text.fontFamily)
        text.x = Double(scene.x)
        text.y = Double(scene.y) - text.fontSize * text.lineHeight / 2
        text.height = text.fontSize * text.lineHeight
        text.width = 1
        editor.beginInteraction()
        editor.setInteractionSelection([])
        editor.updateInteraction { $0.elements.append(text) }
        startEditing(TextEditing(id: text.id, containerID: nil))
    }

    /// Edits an existing text element, or the label it belongs to.
    func beginTextEditing(existing id: String) {
        guard editor.isEditable, let text = editor.element(id), !text.locked else { return }
        if let container = text.containerId, editor.element(container) != nil {
            beginTextEditing(container: container, at: nil)
            return
        }
        editor.beginInteraction()
        startEditing(TextEditing(id: id, containerID: nil))
    }

    /// Edits the label of a shape or line, creating it when missing.
    func beginTextEditing(container containerID: String, at scene: CGPoint?) {
        guard editor.isEditable, let container = editor.element(containerID), !container.locked else { return }
        editor.beginInteraction()
        if let labelID = container.boundTextID, editor.element(labelID) != nil {
            startEditing(TextEditing(id: labelID, containerID: containerID))
            return
        }

        var text = CanvasElement(type: .text)
        editor.style.apply(to: &text)
        text.lineHeight = CanvasText.defaultLineHeight(family: text.fontFamily)
        text.textAlign = "center"
        text.verticalAlign = "middle"
        text.containerId = containerID
        text.strokeColor = container.strokeColor
        text.height = text.fontSize * text.lineHeight
        editor.updateInteraction { document in
            CanvasOps.update(containerID, in: &document) { $0.addBoundElement(id: text.id, type: "text") }
            guard let index = document.elements.firstIndex(where: { $0.id == containerID }) else { return }
            CanvasOps.layoutLabel(&text, container: document.elements[index])
            document.elements.insert(text, at: index + 1)
        }
        startEditing(TextEditing(id: text.id, containerID: containerID))
    }

    private func startEditing(_ editing: TextEditing) {
        guard let element = editor.element(editing.id) else {
            editor.cancelInteraction()
            return
        }
        textEditing = editing
        hiddenElements = [editing.id]

        let field = textView ?? makeTextView()
        textView = field
        field.string = element.originalText.isEmpty ? element.text : element.originalText
        field.localUndoManager.removeAllActions()
        updateTextEditorStyle()
        if field.superview == nil { addSubview(field) }
        field.isHidden = false
        layoutTextEditor()
        window?.makeFirstResponder(field)
        field.selectAll(nil)
        overlay.needsDisplay = true
    }

    private func makeTextView() -> CanvasTextView {
        let field = CanvasTextView(frame: .zero)
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.drawsBackground = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.isGrammarCheckingEnabled = false
        field.smartInsertDeleteEnabled = false
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = false
        field.focusRingType = .none
        field.delegate = self
        return field
    }

    // MARK: Style and layout

    /// Matches the field's font, color, and line height to the element.
    func updateTextEditorStyle() {
        guard let editing = textEditing, let field = textView, let element = editor.element(editing.id) else { return }
        let zoom = viewport.zoom
        let font = CanvasText.font(family: element.fontFamily, size: element.fontSize * zoom) as NSFont
        let lineHeight = element.fontSize * element.lineHeight * zoom
        let ascent = Double(font.ascender), descent = Double(-font.descender)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        switch element.textAlign {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        // TextKit puts extra line height above the glyphs. Excalidraw
        // centers them in the line, so raise the baseline by half of it.
        let baselineOffset = max(0, (lineHeight - ascent - descent) / 2)
        let color = NSColor(cgColor: CanvasColor.cgColor(element.strokeColor, theme: theme)) ?? .textColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset,
        ]
        field.typingAttributes = attributes
        field.defaultParagraphStyle = paragraph
        field.insertionPointColor = color
        if let storage = field.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Places the field over the element being edited.
    func layoutTextEditor() {
        guard let editing = textEditing, let field = textView, let element = editor.element(editing.id) else { return }
        let zoom = viewport.zoom
        let origin = viewport.toScreen(CGPoint(x: element.x, y: element.y))
        let lineHeight = element.fontSize * element.lineHeight * zoom
        var width = max(element.width * zoom, 1)
        let height = max(element.height * zoom, lineHeight)
        var x = origin.x

        if let containerID = editing.containerID, let container = editor.element(containerID) {
            if !container.type.isLinear {
                width = max(CanvasText.maxLabelWidth(container) * zoom, 1)
                x = viewport.toScreen(CanvasText.containerTextOrigin(container)).x
            }
        } else {
            // Room for the caret and the next character before the
            // element is measured again.
            width += element.fontSize * zoom
            switch element.textAlign {
            case "center": x -= element.fontSize * zoom / 2
            case "right": x -= element.fontSize * zoom
            default: break
            }
        }

        field.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        field.textContainer?.widthTracksTextView = false
        field.frame = NSRect(x: x, y: origin.y, width: width, height: height + lineHeight)
    }

    // MARK: Changes

    /// Puts the field's text into the element, re-measuring it and growing
    /// its container.
    func textEditorDidChange() {
        guard let editing = textEditing, let field = textView else { return }
        let value = field.string
        editor.updateInteraction { document in
            CanvasOps.update(editing.id, in: &document) { text in
                text.originalText = value
                text.text = value
                if editing.containerID == nil { CanvasOps.remeasure(&text) }
            }
            guard let containerID = editing.containerID,
                  let c = document.elements.firstIndex(where: { $0.id == containerID }),
                  let t = document.elements.firstIndex(where: { $0.id == editing.id }) else { return }
            var text = document.elements[t]
            CanvasOps.layoutLabel(&text, container: document.elements[c])
            var container = document.elements[c]
            if CanvasOps.growToFit(&container, label: text) {
                CanvasOps.touch(&container)
                document.elements[c] = container
                CanvasOps.updateRelations(changed: [containerID], in: &document)
            } else {
                CanvasOps.touch(&text)
                document.elements[t] = text
            }
        }
        layoutTextEditor()
    }

    /// Finishes editing. Empty text is removed.
    func commitTextEditing() {
        guard let editing = textEditing else { return }
        textEditorDidChange()
        textEditing = nil
        hiddenElements = []
        textView?.isHidden = true
        textView?.string = ""

        let text = editor.element(editing.id)
        let isEmpty = text?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if isEmpty {
            editor.updateInteraction { document in CanvasOps.delete([editing.id], in: &document) }
            editor.setInteractionSelection(editing.containerID.map { [$0] } ?? [])
        } else {
            editor.setInteractionSelection([editing.containerID ?? editing.id])
        }
        editor.endInteraction()
        window?.makeFirstResponder(self)
        if !editor.toolLocked, editor.tool == .text { editor.tool = .selection }
        overlay.needsDisplay = true
    }
}

extension CanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        textEditorDidChange()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            commitTextEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Return adds a line; Command-Return finishes, like Excalidraw.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                commitTextEditing()
                return true
            }
            return false
        default:
            return false
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        (view as? CanvasTextView)?.localUndoManager
    }
}
