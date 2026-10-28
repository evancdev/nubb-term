import AppKit

/// Feeds a window's pointer position into its sidebar presentation: the thin
/// strip on the left edge reveals a collapsed sidebar, and the floating card
/// keeps it open. This watches events instead of placing a view over the
/// terminal so clicks and selections at the left edge still reach it.
final class TabSidebarPointerMonitor {
    private weak var window: NSWindow?
    private weak var model: TabSidebarModel?
    private var monitor: Any?

    private var inEdge = false
    private var inCard = false

    init(window: NSWindow, model: TabSidebarModel) {
        self.window = window
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .mouseExited, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, let model, event.window === window else { return false }
        let presentation = model.presentation

        if event.type == .keyDown {
            // Escape dismisses a peek instead of reaching the terminal.
            guard event.keyCode == 53, presentation.isPeeking, model.renamingID == nil else { return false }
            presentation.dismissPeek()
            return true
        }

        guard presentation.isCollapsed else {
            reset()
            return false
        }

        let content = window.contentLayoutRect
        let point: NSPoint
        if event.type == .mouseExited {
            // Tracking areas report exits from inner views too, so check
            // where the pointer actually is.
            point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        } else {
            point = event.locationInWindow
        }

        let x = point.x - content.minX
        let insideVertically = point.y >= content.minY && point.y <= content.maxY
        let insideWindow = window.frame.contains(window.convertPoint(toScreen: point))

        let nowInEdge = insideWindow && insideVertically && x < TabSidebarMetrics.edgeZoneWidth
        let nowInCard = presentation.isPeeking && insideWindow && insideVertically &&
            x >= 0 && x <= model.width + TabSidebarView.floatingInset

        if nowInEdge != inEdge {
            inEdge = nowInEdge
            if nowInEdge {
                // Don't reveal the sidebar while a selection is being dragged.
                if NSEvent.pressedMouseButtons == 0 { presentation.pointerEnteredEdge() }
            } else {
                presentation.pointerExitedEdge()
            }
        }

        if nowInCard != inCard {
            inCard = nowInCard
            if nowInCard {
                presentation.pointerEnteredCard()
            } else {
                presentation.pointerExitedCard()
            }
        }

        return false
    }

    private func reset() {
        inEdge = false
        inCard = false
    }
}
