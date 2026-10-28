import AppKit
import SwiftUI

// MARK: - Root

/// The terminal content plus the tab sidebar: docked on the left when pinned,
/// or a floating card that peeks out from the left edge when collapsed.
struct TabSidebarContainer<Content: View>: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var presentation: TabSidebarPresentation
    let content: Content

    init(model: TabSidebarModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.presentation = model.presentation
        self.content = content()
    }

    var body: some View {
        if model.isEnabled {
            sidebarLayout
        } else {
            content
        }
    }

    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            if !presentation.isCollapsed {
                TabSidebarView(model: model, style: .docked)
                    .frame(width: model.width)
                    .overlay(alignment: .trailing) {
                        TabSidebarResizeHandle(model: model)
                            .offset(x: 3)
                    }
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }

            content
        }
        .overlay(alignment: .leading) {
            if presentation.isCollapsed && presentation.isPeeking {
                // Pointer tracking for the edge and the card lives in
                // TabSidebarPointerMonitor so nothing covers the terminal.
                TabSidebarView(model: model, style: .floating)
                    .frame(width: model.width)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .padding(.leading, TabSidebarView.floatingInset)
                    .frame(maxHeight: .infinity, alignment: .leading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.9), value: presentation.isCollapsed)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: presentation.isPeeking)
    }
}

// MARK: - Sidebar

struct TabSidebarView: View {
    enum Style {
        case docked
        case floating
    }

    @ObservedObject var model: TabSidebarModel
    let style: Style

    @State private var drag: DragState?
    @State private var rowFrames: [ObjectIdentifier: CGRect] = [:]

    private struct DragState: Equatable {
        let id: ObjectIdentifier
        var translation: CGFloat
        var destination: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if style == .floating {
                floatingHeader
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, style == .docked ? 6 : 0)
                .padding(.bottom, 12)
                .coordinateSpace(name: Self.listSpace)
                .overlay(alignment: .topLeading) { dropIndicator }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: style == .floating ? 12 : 0, style: .continuous))
        .overlay {
            if style == .floating {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .overlay(alignment: .trailing) {
            if style == .docked {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
            }
        }
        .shadow(color: .black.opacity(style == .floating ? 0.35 : 0), radius: 16, x: 4, y: 6)
        .onPreferenceChange(TabSidebarRowFrameKey.self) { rowFrames = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private static let listSpace = "TabSidebarList"

    /// The gap between the window's left edge and the floating card.
    static let floatingInset: CGFloat = 6

    @ViewBuilder
    private var background: some View {
        switch style {
        case .docked:
            Rectangle().fill(.ultraThinMaterial)
        case .floating:
            Rectangle().fill(.regularMaterial)
        }
    }

    private var floatingHeader: some View {
        TabSidebarFloatingHeader { model.toggleCollapsed() }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: TabSidebarItem, index: Int) -> some View {
        let isDragging = drag?.id == item.id
        TabSidebarRow(
            item: item,
            isWindowKey: model.isWindowKey,
            canClose: model.items.count > 1,
            isRenaming: model.renamingID == item.id,
            initialTitle: model.renamingID == item.id ? model.currentTitle(for: item.id) : "",
            onSelect: { model.select(item.id) },
            onClose: { model.close(item.id) },
            onRename: { model.beginRename(item.id) },
            onCommitRename: { model.commitRename(item.id, title: $0) }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabSidebarRowFrameKey.self,
                    value: [item.id: proxy.frame(in: .named(Self.listSpace))])
            }
        )
        .offset(y: isDragging ? (drag?.translation ?? 0) : 0)
        .zIndex(isDragging ? 1 : 0)
        .opacity(isDragging ? 0.85 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.4 : 0), radius: 10, y: 4)
        .gesture(dragGesture(for: item, index: index))
        .contextMenu { contextMenu(for: item, index: index) }
    }

    private func dragGesture(for item: TabSidebarItem, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if drag == nil {
                    model.presentation.beginInteraction()
                }

                let frames = model.items.compactMap { rowFrames[$0.id] }
                let destination = frames.count == model.items.count
                    ? TabSidebarReorder.destinationIndex(
                        pointerY: value.location.y,
                        rowFrames: frames,
                        draggedIndex: index)
                    : index
                drag = DragState(id: item.id, translation: value.translation.height, destination: destination)
            }
            .onEnded { _ in
                if let drag, drag.destination != index {
                    model.move(drag.id, to: drag.destination)
                }
                drag = nil
                model.presentation.endInteraction()
            }
    }

    /// A line where the dragged tab will land.
    @ViewBuilder
    private var dropIndicator: some View {
        if let drag,
           let source = model.items.firstIndex(where: { $0.id == drag.id }),
           drag.destination != source {
            let others = model.items.filter { $0.id != drag.id }.compactMap { rowFrames[$0.id] }
            let y: CGFloat? = drag.destination < others.count
                ? others[drag.destination].minY - 1
                : others.last.map { $0.maxY + 1 }
            if let y {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: TabSidebarItem, index: Int) -> some View {
        Button("Rename Tab…") { model.beginRename(item.id) }

        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    model.setColor(color, for: item.id)
                } label: {
                    if color == item.tabColor {
                        Label(color.localizedName, systemImage: "checkmark")
                    } else {
                        Text(color.localizedName)
                    }
                }
            }
        }

        Divider()

        Button("Close Tab") { model.close(item.id) }
            .disabled(model.items.count < 2)
        Button("Close Other Tabs") { model.closeOthers(item.id) }
            .disabled(model.items.count < 2)
        Button("Close Tabs Below") { model.closeBelow(item.id) }
            .disabled(index >= model.items.count - 1)
    }
}

private struct TabSidebarRowFrameKey: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Row

struct TabSidebarRow: View {
    let item: TabSidebarItem
    let isWindowKey: Bool
    let canClose: Bool
    let isRenaming: Bool
    let initialTitle: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCommitRename: (String?) -> Void

    @State private var hovering = false

    private var showsAttention: Bool {
        (item.activity.needsAttention || item.hasBell) && !item.isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.isZoomed ? "rectangle.inset.filled" : "terminal")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 17)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    title
                    trailingAccessory
                }
                .frame(minHeight: 17)

                if let branch = item.branch {
                    metaLine(systemImage: "arrow.triangle.branch", text: branch)
                }

                if let directory = item.directory {
                    metaLine(systemImage: "folder", text: directory)
                }

                if let status = item.activity.status {
                    statusLine(status)
                }

                if let progress = item.progress {
                    SurfaceProgressBar(report: progress)
                        .frame(height: 3)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Capsule())
                        .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay {
            if showsAttention {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onRename() }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab") { onClose() }
        .accessibilityAction(named: "Rename Tab") { onRename() }
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TabSidebarRenameField(initialText: initialTitle, onCommit: onCommitRename)
                .frame(height: 17)
        } else {
            Text(item.title)
                .font(.system(size: 12.5, weight: item.isSelected ? .semibold : .regular))
                .foregroundStyle(item.isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if hovering && canClose && !isRenaming {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Tab")
        } else if let shortcut = item.shortcut, !isRenaming {
            Text(shortcut)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var iconColor: Color {
        if let color = item.tabColor.displayColor { return Color(nsColor: color) }
        return .secondary
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if item.isSelected {
            shape.fill(Color.primary.opacity(isWindowKey ? 0.10 : 0.07))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.05))
        } else {
            shape.fill(Color.clear)
        }
    }

    private func metaLine(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5))
                .frame(width: 11)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func statusLine(_ status: String) -> some View {
        let color: Color = item.activity.isError
            ? .red
            : (item.activity.needsAttention ? .accentColor : .secondary)
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .frame(width: 11)
            Text(status)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, weight: item.activity.needsAttention ? .medium : .regular))
        .foregroundStyle(color)
    }
}

// MARK: - Small views

/// The floating card's header: a label and a pin button that docks the card.
/// New tabs come from the + next to the sidebar toggle in the titlebar.
struct TabSidebarFloatingHeader: View {
    let onPin: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("TABS")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
            Spacer(minLength: 0)
            TabSidebarIconButton(systemImage: "pin", help: "Keep Sidebar Open", action: onPin)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

struct TabSidebarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Drag the sidebar's trailing edge to resize it.
struct TabSidebarResizeHandle: View {
    @ObservedObject var model: TabSidebarModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? model.width
                        startWidth = start
                        let windowWidth = NSApp.keyWindow?.frame.width ?? 1000
                        model.width = TabSidebarMetrics.clampedWidth(
                            start + value.translation.width,
                            windowWidth: windowWidth)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        model.commitWidth(model.width)
                    }
            )
            .accessibilityHidden(true)
    }
}

/// An AppKit text field for inline renaming: it selects all on appear, commits
/// on Return or focus loss, and cancels on Escape.
struct TabSidebarRenameField: NSViewRepresentable {
    let initialText: String
    let onCommit: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialText)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String?) -> Void
        private var finished = false

        init(onCommit: @escaping (String?) -> Void) {
            self.onCommit = onCommit
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish((obj.object as? NSTextField)?.stringValue)
        }

        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            onCommit(value)
        }
    }
}
