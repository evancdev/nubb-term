import AppKit

// MARK: - Keyboard

extension CanvasView {
    override func keyDown(with event: NSEvent) {
        if keyBindingHandler?(event) == true { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 0x35: // Escape
            escape()
            return
        case 0x33, 0x75: // Delete, Forward Delete
            if !command { editor.deleteSelection() }
            return
        case 0x24, 0x4C: // Return, Enter
            if let id = multipoint {
                finishLinear(id)
            } else if let only = transformTargets.first, transformTargets.count == 1, !command {
                if only.type == .text {
                    beginTextEditing(existing: only.id)
                } else if only.type.isContainer || only.type.isLinear {
                    beginTextEditing(container: only.id, at: nil)
                }
            }
            return
        case 0x7B, 0x7C, 0x7D, 0x7E: // Arrows
            let step: CGFloat = shift ? 5 : 1
            let delta: CGVector
            switch event.keyCode {
            case 0x7B: delta = CGVector(dx: -step, dy: 0)
            case 0x7C: delta = CGVector(dx: step, dy: 0)
            case 0x7D: delta = CGVector(dx: 0, dy: step)
            default: delta = CGVector(dx: 0, dy: -step)
            }
            if editor.selection.isEmpty {
                var next = viewport
                next.offset = CGPoint(x: viewport.offset.x - delta.dx * 20, y: viewport.offset.y - delta.dy * 20)
                viewport = next
            } else {
                editor.nudgeSelection(by: delta)
            }
            return
        case 0x31 where !command: // Space
            if !spaceHeld {
                spaceHeld = true
                NSCursor.openHand.set()
            }
            return
        default:
            break
        }

        if command {
            switch (characters, shift, option) {
            case ("d", false, false): editor.duplicateSelection()
            case ("g", false, false): editor.groupSelection()
            case ("g", true, false): editor.ungroupSelection()
            case ("[", false, false): editor.reorderSelection(.backward)
            case ("]", false, false): editor.reorderSelection(.forward)
            case ("[", false, true), ("{", true, false): editor.reorderSelection(.back)
            case ("]", false, true), ("}", true, false): editor.reorderSelection(.front)
            case ("0", false, false): resetZoom()
            case ("=", _, false), ("+", _, false): zoomStep(in: true)
            case ("-", false, false): zoomStep(in: false)
            case ("l", true, false): toggleLock()
            default: super.keyDown(with: event)
            }
            return
        }

        // Option-Shift-D switches light and dark, as in Excalidraw.
        if option && shift && !control && event.keyCode == 0x02 {
            CanvasAppearance.toggle(from: self)
            return
        }

        if control || option {
            super.keyDown(with: event)
            return
        }

        if shift {
            switch characters {
            case "1": fitToContent(maxZoom: CanvasViewport.maxZoom)
            case "2": zoomToSelection()
            default: super.keyDown(with: event)
            }
            return
        }

        if characters == "q" {
            editor.toolLocked.toggle()
            return
        }

        if let key = characters.first, let tool = CanvasTool.forKey(key) {
            setTool(tool)
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 0x31, spaceHeld {
            spaceHeld = false
            if case .pan = drag { return }
            updateCursor(at: lastPointer ?? .zero)
            return
        }
        super.keyUp(with: event)
    }

    func setTool(_ tool: CanvasTool) {
        guard tool != editor.tool else { return }
        toolWillChange()
        editor.tool = tool
        if tool != .selection && tool != .hand { editor.clearSelection() }
        updateCursor(at: lastPointer ?? .zero)
        overlay.needsDisplay = true
    }

    private func escape() {
        if let id = multipoint {
            finishLinear(id)
            return
        }
        switch drag {
        case .none:
            break
        default:
            drag = .none
            editor.cancelInteraction()
            erasing = []
            bindingHighlight = nil
            overlay.needsDisplay = true
            return
        }
        if !editor.selection.isEmpty {
            editor.clearSelection()
        } else if editor.tool != .selection {
            setTool(.selection)
        }
    }

    func toggleLock() {
        let targets = transformTargets
        guard !targets.isEmpty else { return }
        let lock = !targets.allSatisfy(\.locked)
        let ids = CanvasOps.withBoundText(Set(targets.map(\.id)), in: editor.document)
        editor.perform { document in
            for id in ids { CanvasOps.update(id, in: &document) { $0.locked = lock } }
        }
    }
}

// MARK: - Menu actions

extension CanvasView: NSMenuItemValidation {
    @IBAction func undo(_ sender: Any?) {
        guard textEditing == nil else { return }
        if multipoint != nil || editor.isInteracting {
            escape()
            return
        }
        editor.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        guard textEditing == nil, !editor.isInteracting else { return }
        editor.redo()
    }

    @IBAction override func selectAll(_ sender: Any?) {
        toolWillChange()
        if editor.tool != .selection { editor.tool = .selection }
        editor.selectAll()
    }

    @IBAction func delete(_ sender: Any?) {
        editor.deleteSelection()
    }

    @IBAction func duplicate(_ sender: Any?) {
        editor.duplicateSelection()
    }

    @IBAction func copy(_ sender: Any?) {
        copySelection(to: .general)
    }

    @IBAction func cut(_ sender: Any?) {
        copySelection(to: .general)
        editor.deleteSelection()
    }

    @IBAction func paste(_ sender: Any?) {
        paste(from: .general)
    }

    @IBAction func copyAsPNG(_ sender: Any?) {
        let elements = editor.selectedElements.isEmpty ? editor.document.elements : selectionWithLabels
        var document = editor.document
        document.elements = elements
        guard let image = CanvasRenderer.image(of: document, scale: 2, theme: .light),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    @IBAction func bringForward(_ sender: Any?) { editor.reorderSelection(.forward) }
    @IBAction func sendBackward(_ sender: Any?) { editor.reorderSelection(.backward) }
    @IBAction func bringToFront(_ sender: Any?) { editor.reorderSelection(.front) }
    @IBAction func sendToBack(_ sender: Any?) { editor.reorderSelection(.back) }
    @IBAction func groupSelection(_ sender: Any?) { editor.groupSelection() }
    @IBAction func ungroupSelection(_ sender: Any?) { editor.ungroupSelection() }
    @IBAction func toggleLockSelection(_ sender: Any?) { toggleLock() }

    /// Asks for the name shown when the pointer rests on the selected
    /// element. An empty name removes it.
    @IBAction func nameSelection(_ sender: Any?) {
        guard let target = nameTarget, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Name"
        alert.informativeText = "Shown when the pointer rests on it. Leave empty for none."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = target.hoverName ?? ""
        field.placeholderString = "What this is"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setName(field.stringValue, of: target.id)
        }
    }

    /// Sets the hover name of `id` as one undo step.
    func setName(_ name: String, of id: String) {
        editor.perform { document in
            CanvasOps.update(id, in: &document) { $0.hoverName = name }
        }
    }

    /// The one selected element that can have a name: not a frame, which
    /// has a title, and not a label, which names its container.
    var nameTarget: CanvasElement? {
        let targets = transformTargets
        guard targets.count == 1, targets[0].type != .frame else { return nil }
        return targets[0]
    }
    @IBAction func zoomToFit(_ sender: Any?) { fitToContent(maxZoom: CanvasViewport.maxZoom) }

    // Nubb's View menu font size items zoom the canvas.
    @IBAction func increaseFontSize(_ sender: Any?) { zoomStep(in: true) }
    @IBAction func decreaseFontSize(_ sender: Any?) { zoomStep(in: false) }
    @IBAction func resetFontSize(_ sender: Any?) { resetZoom() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSelection = !editor.selection.isEmpty
        let editable = editor.isEditable && textEditing == nil
        switch item.action {
        case #selector(undo(_:)):
            return editable && (editor.canUndo || multipoint != nil)
        case #selector(redo(_:)):
            return editable && editor.canRedo
        case #selector(copy(_:)):
            return hasSelection
        case #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)),
             #selector(bringForward(_:)), #selector(sendBackward(_:)),
             #selector(bringToFront(_:)), #selector(sendToBack(_:)),
             #selector(toggleLockSelection(_:)):
            return editable && hasSelection
        case #selector(groupSelection(_:)):
            return editable && transformTargets.count > 1
        case #selector(ungroupSelection(_:)):
            return editable && editor.selectionHasGroup
        case #selector(paste(_:)):
            return editable && Self.canPaste(from: .general)
        case #selector(selectAll(_:)):
            return !editor.document.elements.isEmpty
        case #selector(copyAsPNG(_:)):
            return !editor.document.elements.isEmpty
        case #selector(nameSelection(_:)):
            return editable && nameTarget != nil
        default:
            return true
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if editor.selection.isEmpty {
            add("Paste", #selector(paste(_:)))
            add("Select All", #selector(selectAll(_:)))
            menu.addItem(.separator())
            add("Zoom to Fit", #selector(zoomToFit(_:)))
            add("Copy as PNG", #selector(copyAsPNG(_:)))
            menu.addItem(.separator())
            menu.addItem(CanvasAppearanceMenu.shared.makeItem(title: "Theme"))
        } else {
            add("Cut", #selector(cut(_:)))
            add("Copy", #selector(copy(_:)))
            add("Paste", #selector(paste(_:)))
            add("Copy as PNG", #selector(copyAsPNG(_:)))
            menu.addItem(.separator())
            add("Duplicate", #selector(duplicate(_:)))
            add("Delete", #selector(delete(_:)))
            if let target = nameTarget {
                add(target.hoverName == nil ? "Add Name…" : "Edit Name…", #selector(nameSelection(_:)))
            }
            menu.addItem(.separator())
            add("Bring to Front", #selector(bringToFront(_:)))
            add("Bring Forward", #selector(bringForward(_:)))
            add("Send Backward", #selector(sendBackward(_:)))
            add("Send to Back", #selector(sendToBack(_:)))
            menu.addItem(.separator())
            if transformTargets.count > 1 { add("Group", #selector(groupSelection(_:))) }
            if editor.selectionHasGroup { add("Ungroup", #selector(ungroupSelection(_:))) }
            let locked = transformTargets.allSatisfy(\.locked)
            add(locked ? "Unlock" : "Lock", #selector(toggleLockSelection(_:)))
        }
        return menu
    }
}

// MARK: - Clipboard

extension CanvasView {
    static let clipboardType = NSPasteboard.PasteboardType("com.evancdev.nubb.excalidraw-clipboard")

    /// The selection with the labels of selected containers and the
    /// elements of selected frames.
    var selectionWithLabels: [CanvasElement] {
        let ids = CanvasOps.withFrameChildren(editor.selection, in: editor.document)
        return editor.document.elements.filter { ids.contains($0.id) }
    }

    func copySelection(to pasteboard: NSPasteboard) {
        let elements = selectionWithLabels
        guard !elements.isEmpty else { return }
        let data = CanvasDocument.clipboardData(elements: elements, files: editor.document.files)
        pasteboard.declareTypes([.string, Self.clipboardType], owner: nil)
        // Excalidraw reads its clipboard format from plain text, so the
        // JSON goes there too. Pasting it in a terminal gives the JSON,
        // which is what an agent would want.
        if let text = String(bytes: data, encoding: .utf8) {
            pasteboard.setString(text, forType: .string)
        }
        pasteboard.setData(data, forType: Self.clipboardType)
    }

    static func canPaste(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [clipboardType, .string]) != nil
    }

    func paste(from pasteboard: NSPasteboard) {
        guard editor.isEditable else { return }
        let data = pasteboard.data(forType: Self.clipboardType)
            ?? pasteboard.string(forType: .string).map { Data($0.utf8) }
        guard let data else { return }

        if let document = try? CanvasDocument.decode(data), !document.elements.isEmpty,
           Self.looksLikeDrawing(data) {
            pasteElements(document.elements, files: document.files)
            return
        }

        // Plain text becomes a text element at the pointer.
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .newlines), !text.isEmpty else { return }
        var element = CanvasElement(type: .text)
        editor.style.apply(to: &element)
        element.lineHeight = CanvasText.defaultLineHeight(family: element.fontFamily)
        element.text = text
        element.originalText = text
        CanvasOps.remeasure(&element)
        let center = pasteCenter
        element.x = Double(center.x) - element.width / 2
        element.y = Double(center.y) - element.height / 2
        editor.insert([element])
    }

    /// Whether pasted JSON is a drawing rather than any JSON text.
    private static func looksLikeDrawing(_ data: Data) -> Bool {
        guard let json = try? CanvasJSON.parse(data) else { return false }
        if let type = json["type"]?.stringValue {
            return type == CanvasDocument.clipboardType || type == CanvasDocument.fileType
        }
        return json["elements"]?.arrayValue != nil
    }

    /// Where pasted elements go: under the pointer, or the view center.
    private var pasteCenter: CGPoint {
        if let pointer = lastPointer, bounds.contains(pointer) {
            return viewport.toScene(pointer)
        }
        return viewport.toScene(CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func pasteElements(_ elements: [CanvasElement], files: [String: CanvasJSON]) {
        let box = CanvasRenderer.sceneBounds(of: elements)
        let center = pasteCenter
        let offset = box.isNull ? .zero : CGVector(dx: center.x - box.midX, dy: center.y - box.midY)
        let copies = CanvasOps.copies(of: elements, offset: offset)
        toolWillChange()
        editor.tool = .selection
        editor.insert(copies, files: files)
    }
}
