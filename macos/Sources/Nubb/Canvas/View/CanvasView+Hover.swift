import AppKit

// MARK: - Hover names

/// Shows an element's name (`customData.name`) in a small label next to
/// the pointer once it rests on the element. The label keeps its screen
/// size at every zoom, so a zoomed-out drawing stays readable on hover.
extension CanvasView {
    /// How long the pointer rests before the name shows, and how long it
    /// takes moving to a neighbor while one is showing.
    static let hoverDelay: TimeInterval = 0.35
    static let hoverSwitchDelay: TimeInterval = 0.05

    /// The innermost named element under `scene`. Unnamed elements on top
    /// don't hide a name: the text in a named card or code block shows the
    /// card's name, and a label shows its container's. The inside of a
    /// shape counts even without a fill. Frames have a title instead.
    func namedElement(at scene: CGPoint) -> CanvasElement? {
        let document = editor.document
        let positions = CanvasOps.index(document)
        let threshold = hitThreshold
        for element in document.elements.reversed() {
            if hiddenElements.contains(element.id) || element.type == .frame { continue }
            guard Self.hoverHit(element, scene, threshold: threshold) else { continue }
            if let name = element.hoverName { return element }
            if let container = element.containerId, let index = positions[container],
               let name = document.elements[index].hoverName {
                return withName(document.elements[index], name)
            }
        }
        return nil
    }

    /// Whether `point` is on `element` for hovering: inside shapes and
    /// text boxes, on the stroke of lines.
    private static func hoverHit(_ element: CanvasElement, _ point: CGPoint, threshold: Double) -> Bool {
        let pad = CGFloat(threshold + element.strokeWidth)
        guard element.sceneBounds.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
        switch element.type {
        case .rectangle, .diamond, .ellipse:
            let local = element.toLocal(point)
            return element.outlinePath.contains(local) || element.hitTest(point, threshold: threshold)
        case .text, .image:
            return element.localBounds.contains(element.toLocal(point))
        default:
            return element.hitTest(point, threshold: threshold)
        }
    }

    private func withName(_ element: CanvasElement, _ name: String) -> CanvasElement {
        var element = element
        element.hoverName = name
        return element
    }

    /// Called as the pointer moves: shows, moves, or hides the name.
    func updateHover(at screen: CGPoint?) {
        guard let screen, hoverAllowed else {
            hideHover()
            return
        }
        let target = namedElement(at: viewport.toScene(screen))
        guard let target, let name = target.hoverName else {
            hideHover()
            return
        }
        if hover.shownID == target.id {
            if hover.label.text != name { hover.label.set(name, theme: theme) }
            hover.label.place(near: screen, in: bounds)
            return
        }
        hover.pendingID = target.id
        hover.timer?.invalidate()
        let delay = hover.shownID == nil ? Self.hoverDelay : Self.hoverSwitchDelay
        hover.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hover.pendingID == target.id, let pointer = self.lastPointer else { return }
                self.showHover(name, for: target.id, near: pointer)
            }
        }
    }

    func showHover(_ name: String, for id: String, near screen: CGPoint) {
        if hover.label.superview !== self { addSubview(hover.label) }
        hover.label.set(name, theme: theme)
        hover.label.place(near: screen, in: bounds)
        hover.label.isHidden = false
        hover.shownID = id
        hover.pendingID = nil
        overlay.needsDisplay = true
    }

    func hideHover() {
        let wasShown = hover.shownID != nil
        hover.timer?.invalidate()
        hover.timer = nil
        hover.pendingID = nil
        hover.shownID = nil
        hover.label.isHidden = true
        if wasShown { overlay.needsDisplay = true }
    }

    /// Checks the shown name again after the drawing changed.
    func refreshHover() {
        guard let pointer = lastPointer, let id = hover.shownID else { return }
        guard let target = namedElement(at: viewport.toScene(pointer)), target.id == id, let name = target.hoverName else {
            hideHover()
            return
        }
        if hover.label.text != name { hover.label.set(name, theme: theme) }
        hover.label.place(near: pointer, in: bounds)
        overlay.needsDisplay = true
    }

    /// Names show only while nothing else is going on: no drag, no text
    /// being typed, no line being drawn, and the selection tool in hand.
    private var hoverAllowed: Bool {
        guard textEditing == nil, multipoint == nil, !spaceHeld else { return false }
        guard editor.tool == .selection || editor.tool == .hand else { return false }
        if case .none = drag { return true }
        return false
    }

    /// The name of the element now shown, for tests.
    var shownHoverName: String? {
        hover.label.isHidden ? nil : hover.label.text
    }
}

/// What the hover name is doing.
final class CanvasHoverState {
    let label = CanvasHoverLabel()
    var timer: Timer?
    var pendingID: String?
    var shownID: String?

    deinit { timer?.invalidate() }
}

/// The floating label: a rounded panel with the name in the system font.
final class CanvasHoverLabel: NSView {
    private let field = NSTextField(wrappingLabelWithString: "")
    static let maxWidth: CGFloat = 320
    static let padding = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)

    private(set) var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 6
        field.lineBreakMode = .byWordWrapping
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    // The pointer passes through to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String, theme: CanvasTheme) {
        self.text = text
        field.stringValue = text
        let dark = theme == .dark
        layer?.backgroundColor = dark
            ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.97)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98)
        layer?.borderColor = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
        field.textColor = dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)

        let pad = Self.padding
        field.preferredMaxLayoutWidth = Self.maxWidth - pad.left - pad.right
        let size = field.fittingSize
        let width = min(ceil(size.width), Self.maxWidth - pad.left - pad.right)
        let height = ceil(field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        field.frame = NSRect(x: pad.left, y: pad.top, width: width, height: height)
        setFrameSize(NSSize(width: width + pad.left + pad.right, height: height + pad.top + pad.bottom))
    }

    /// Below and to the right of the pointer, flipped to stay in `bounds`.
    func place(near point: CGPoint, in bounds: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: point.x + 14, y: point.y + 20)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = point.x - 14 - size.width }
        if origin.y + size.height > bounds.maxY - 8 { origin.y = point.y - 12 - size.height }
        origin.x = max(bounds.minX + 8, origin.x)
        origin.y = max(bounds.minY + 8, origin.y)
        setFrameOrigin(origin)
    }
}
